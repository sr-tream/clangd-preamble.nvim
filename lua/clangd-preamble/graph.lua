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
local build_prefix
local header_is_self_contained

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

local function observed_candidate_tus(header_path)
  local basename = basename_of(header_path)
  local candidates = M.header_users[basename]
  local out = {}
  if not candidates then return out end
  for _, tu in ipairs(candidates) do
    if M.tu_includes[tu] then table.insert(out, tu) end
  end
  return out
end

local function include_index(tu_path, header_basename)
  local tu_inc = M.tu_includes[tu_path]
  if not tu_inc then return math.huge end
  for i, e in ipairs(tu_inc) do
    if basename_of(e.name) == header_basename then return i - 1 end
  end
  return #tu_inc
end

local function project_root_for_tu(tu_path)
  local root = vim.fs.dirname(tu_path) or vim.fn.getcwd()
  for _ = 1, 5 do
    local up = vim.fs.dirname(root)
    if not up or up == root then break end
    if vim.uv.fs_stat(root .. "/.git") or vim.uv.fs_stat(root .. "/compile_commands.json") then break end
    root = up
  end
  return root
end

local function candidate_from_tu(tu_path, header_path, companion)
  local header_basename = basename_of(header_path)
  local lines, direct = build_prefix(tu_path, header_basename, project_root_for_tu(tu_path))
  if not lines or #lines == 0 then return nil end
  return {
    tu_path = tu_path,
    prefix_lines = lines,
    direct = direct,
    include_index = include_index(tu_path, header_basename),
    observed_order = M.tu_mtime[tu_path] or 0,
    companion = companion,
  }
end

local function sort_candidates(candidates)
  table.sort(candidates, function(a, b)
    if a.include_index ~= b.include_index then return a.include_index < b.include_index end
    if a.observed_order ~= b.observed_order then return a.observed_order > b.observed_order end
    return a.tu_path < b.tu_path
  end)
  return candidates
end

local function companion_candidate(header_path)
  local comp = companion_tu(header_path)
  if not comp then return nil end
  if not M.tu_includes[comp] and not M.observe_tu_from_disk(comp) then return nil end
  return candidate_from_tu(comp, header_path, true)
end

local function observed_candidates(header_path)
  local out = {}
  for _, tu in ipairs(observed_candidate_tus(header_path)) do
    local candidate = candidate_from_tu(tu, header_path, false)
    if candidate then table.insert(out, candidate) end
  end
  return sort_candidates(out)
end

local function normalize_find_options(options)
  if type(options) == "table" then return options end
  return { force = options == true }
end

-- Manual commands pass { force = true } to bypass the self-contained heuristic.
function M.find_includer(header_path, options)
  options = normalize_find_options(options)
  if not options.force and header_is_self_contained(header_path) then return nil end
  if options.preferred_tu then
    for _, candidate in ipairs(M.list_includers(header_path, { force = true })) do
      if candidate.tu_path == options.preferred_tu then return candidate end
    end
  end
  local observed = observed_candidates(header_path)
  if #observed > 0 then return observed[1] end
  return companion_candidate(header_path)
end

function M.find_recent_includer(header_path, options)
  options = normalize_find_options(options)
  if not options.force and header_is_self_contained(header_path) then return nil end
  local observed = observed_candidates(header_path)
  table.sort(observed, function(a, b)
    if a.observed_order ~= b.observed_order then return a.observed_order > b.observed_order end
    if a.include_index ~= b.include_index then return a.include_index < b.include_index end
    return a.tu_path < b.tu_path
  end)
  return observed[1]
end

function M.list_includers(header_path, options)
  options = normalize_find_options(options)
  if not options.force and header_is_self_contained(header_path) then return {} end
  local out = observed_candidates(header_path)
  local comp = companion_candidate(header_path)
  if comp then
    local seen = false
    for _, candidate in ipairs(out) do
      if candidate.tu_path == comp.tu_path then seen = true; break end
    end
    if not seen then table.insert(out, comp) end
  end
  return sort_candidates(out)
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

build_prefix = function(tu_path, header_basename, root)
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

header_is_self_contained = function(path)
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
