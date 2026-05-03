local M = {}

local INCLUDE_PAT = "^%s*#%s*include%s*([\"<])([^\">]+)[\">]"
local MAX_PREAMBLE_LINES = 1500
local MAX_PREAMBLE_BYTES = 64 * 1024
local PROJECT_SCAN_LIMIT = 2000
local CYCLE_CHECK_DEPTH = 1

M.tu_includes  = {}
M.header_users = {}
M.tu_mtime     = {}
M._path_cache  = {}
local lru_seq = 0

local function parse_text(text)
  local out = {}
  local lineno = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local kind, name = line:match(INCLUDE_PAT)
    if kind then
      table.insert(out, { name = name, kind = kind, line = lineno, raw = line })
    end
    lineno = lineno + 1
  end
  return out
end

local function basename_of(path)
  return path:match("([^/\\]+)$") or path
end

local function record_users(tu_path, incs)
  for _, e in ipairs(incs) do
    local bn = basename_of(e.name)
    local list = M.header_users[bn]
    if not list then list = {}; M.header_users[bn] = list end
    local found = false
    for _, p in ipairs(list) do if p == tu_path then found = true; break end end
    if not found then table.insert(list, tu_path) end
  end
end

function M.observe_tu(tu_path, source_text)
  local incs = parse_text(source_text)
  M.tu_includes[tu_path] = incs
  lru_seq = lru_seq + 1
  M.tu_mtime[tu_path] = lru_seq
  record_users(tu_path, incs)
end

function M.observe_tu_from_disk(tu_path)
  local f = io.open(tu_path, "r")
  if not f then return false end
  local text = f:read("*a"); f:close()
  M.observe_tu(tu_path, text)
  return true
end

function M.invalidate(tu_path)
  M.tu_includes[tu_path] = nil
end

local function companion_tu(header_path)
  local dir = vim.fs.dirname(header_path)
  local stem = basename_of(header_path):gsub("%.[^.]+$", "")
  for _, ext in ipairs({ "cpp", "cc", "cxx", "c", "C", "mm" }) do
    local p = dir .. "/" .. stem .. "." .. ext
    if vim.uv.fs_stat(p) then return p end
  end
  return nil
end
M.companion_tu = companion_tu

local function pick_includer_tu(header_path)
  local basename = basename_of(header_path)
  local candidates = M.header_users[basename]
  if candidates and #candidates > 0 then
    -- Prefer the TU with the shortest prefix-before-this-header. A polluting
    -- TU (e.g. CEF wrapper that puts common.h after several framework headers)
    -- would inject macros that conflict with the header's own includes — pick
    -- the most "neutral" includer instead. Tie-break: most recent observation.
    local best, best_pos, best_mt = nil, math.huge, -1
    for _, tu in ipairs(candidates) do
      local tu_inc = M.tu_includes[tu]
      if tu_inc then
        local pos = #tu_inc
        for i, e in ipairs(tu_inc) do
          if basename_of(e.name) == basename then pos = i - 1; break end
        end
        local mt = M.tu_mtime[tu] or 0
        if pos < best_pos or (pos == best_pos and mt > best_mt) then
          best, best_pos, best_mt = tu, pos, mt
        end
      end
    end
    if best then return best end
  end
  local comp = companion_tu(header_path)
  if comp and M.observe_tu_from_disk(comp) then
    return comp
  end
  return nil
end

local function find_header_path(basename, root)
  local cached = M._path_cache[basename]
  if cached ~= nil then return cached or nil end
  local found = vim.fs.find(basename, { path = root, type = "file", limit = 1 })
  local path = (found and found[1]) or false
  M._path_cache[basename] = path
  return path or nil
end

local function file_includes(path)
  if M.tu_includes[path] then return M.tu_includes[path] end
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a"); f:close()
  local incs = parse_text(text)
  M.tu_includes[path] = incs
  return incs
end

-- True if a header named `start_bn` (transitively, up to depth) #include's `target_bn`.
local function transitively_includes(start_bn, target_bn, root, depth, seen)
  if depth <= 0 then return false end
  local path = find_header_path(start_bn, root)
  if not path or seen[path] then return false end
  seen[path] = true
  local incs = file_includes(path)
  if not incs then return false end
  for _, e in ipairs(incs) do
    if basename_of(e.name) == target_bn then return true end
  end
  for _, e in ipairs(incs) do
    if transitively_includes(basename_of(e.name), target_bn, root, depth - 1, seen) then
      return true
    end
  end
  return false
end

local function build_prefix(tu_path, header_basename, root)
  local tu_inc = M.tu_includes[tu_path]
  if not tu_inc then return nil, false end
  local cut = nil
  for i, e in ipairs(tu_inc) do
    if basename_of(e.name) == header_basename then cut = i; break end
  end
  local lines = {}
  local total_bytes = 0
  local stop = cut and (cut - 1) or #tu_inc
  for i = 1, stop do
    local e = tu_inc[i]
    local prefix_bn = basename_of(e.name)
    if prefix_bn ~= header_basename
       and not transitively_includes(prefix_bn, header_basename, root, CYCLE_CHECK_DEPTH, {}) then
      local raw = e.raw
      total_bytes = total_bytes + #raw + 1
      if #lines >= MAX_PREAMBLE_LINES or total_bytes > MAX_PREAMBLE_BYTES then break end
      table.insert(lines, raw)
    end
  end
  return lines, cut ~= nil
end

-- A header with many own #includes is likely making a deliberate effort to be
-- self-contained, and our preamble can only introduce conflicts in that case.
-- Headers with very few includes (like DamageManager.h with just "common.h"
-- and a forward-decl for `enum eLights`) genuinely rely on the includer's
-- transitive context — they need the preamble.
local SELF_CONTAINED_INCLUDE_THRESHOLD = 3

local function header_is_self_contained(path)
  local f = io.open(path, "r")
  if not f then return true end
  local count = 0
  for line in f:lines() do
    if line:match(INCLUDE_PAT) then
      count = count + 1
      if count >= SELF_CONTAINED_INCLUDE_THRESHOLD then f:close(); return true end
    end
  end
  f:close()
  return false
end

-- Manual commands pass force=true to bypass the self-contained heuristic.
function M.find_includer(header_path, force)
  if not force and header_is_self_contained(header_path) then return nil end
  local tu = pick_includer_tu(header_path)
  if not tu then return nil end
  local root = vim.fs.dirname(tu) or vim.fn.getcwd()
  for _ = 1, 5 do
    local up = vim.fs.dirname(root)
    if not up or up == root then break end
    if vim.uv.fs_stat(root .. "/.git") or vim.uv.fs_stat(root .. "/compile_commands.json") then break end
    root = up
  end
  local lines, direct = build_prefix(tu, basename_of(header_path), root)
  if not lines or #lines == 0 then return nil end
  return { tu_path = tu, prefix_lines = lines, direct = direct }
end

function M.scan_project_for_includers(root)
  if not root or root == "" then return 0 end
  local files = vim.fs.find(
    function(name)
      return name:match("%.cpp$") or name:match("%.cc$") or name:match("%.cxx$")
          or name:match("%.c$")   or name:match("%.C$")  or name:match("%.mm$")
    end,
    { path = root, type = "file", limit = PROJECT_SCAN_LIMIT }
  )
  local count = 0
  for _, p in ipairs(files) do
    if not M.tu_includes[p] then
      if M.observe_tu_from_disk(p) then count = count + 1 end
    end
  end
  return count
end

function M.dump()
  local lines = { ("TUs observed: %d"):format(vim.tbl_count(M.tu_includes)) }
  local sorted_tus = {}
  for tu, _ in pairs(M.tu_includes) do table.insert(sorted_tus, tu) end
  table.sort(sorted_tus, function(a, b) return (M.tu_mtime[a] or 0) > (M.tu_mtime[b] or 0) end)
  for _, tu in ipairs(sorted_tus) do
    table.insert(lines, ("  [%s]  %s  (%d includes)"):format(M.tu_mtime[tu] or "?", tu, #M.tu_includes[tu]))
  end
  table.insert(lines, ("Header basenames indexed: %d"):format(vim.tbl_count(M.header_users)))
  return table.concat(lines, "\n")
end

return M
