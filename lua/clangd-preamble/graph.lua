local M = {}

local INCLUDE_PAT = "^%s*#%s*include%s*([\"<])([^\">]+)[\">]"
local MAX_PREAMBLE_LINES = 1500
local MAX_PREAMBLE_BYTES = 64 * 1024
local PROJECT_SCAN_LIMIT = 2000
local CYCLE_CHECK_DEPTH = 1
local INDIRECT_INCLUDE_DEPTH = 2
local HEADER_EXTS = {
  h = true, hh = true, hpp = true, hxx = true,
  inl = true, inc = true, ipp = true, tcc = true, tpp = true,
}
local TU_EXTS = {
  cpp = true, cc = true, cxx = true, c = true, C = true, mm = true,
}

M.tu_includes  = {}
M.header_users = {}
M.tu_mtime     = {}
M._path_cache  = {}
M._file_include_cache = {}
local lru_seq = 0
local change_listeners = {}
local build_prefix
local header_is_self_contained
local find_header_path
local file_includes
local indirect_candidates

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

local function ext_of(path)
  return basename_of(path):match("%.([^.]+)$") or ""
end

local function is_tu_path(path)
  return TU_EXTS[ext_of(path)] == true
end

local function is_header_path(path)
  return HEADER_EXTS[ext_of(path)] == true
end

local function emit_change()
  for _, cb in ipairs(change_listeners) do pcall(cb) end
end

function M.on_change(cb)
  table.insert(change_listeners, cb)
  local active = true
  return {
    dispose = function()
      if not active then return end
      active = false
      for i, listener in ipairs(change_listeners) do
        if listener == cb then table.remove(change_listeners, i); break end
      end
    end,
  }
end

function M.set_indirect_include_depth(value)
  local n = tonumber(value)
  if not n then return end
  INDIRECT_INCLUDE_DEPTH = math.max(0, math.floor(n))
end

local function clone_includes(incs)
  local out = {}
  for _, e in ipairs(incs or {}) do
    table.insert(out, { name = e.name, kind = e.kind, line = e.line, raw = e.raw })
  end
  return out
end

local function unindex_tu(tu_path)
  local old = M.tu_includes[tu_path]
  if not old then return end
  for _, e in ipairs(old) do
    local bn = basename_of(e.name)
    local list = M.header_users[bn]
    if list then
      for i = #list, 1, -1 do
        if list[i] == tu_path then table.remove(list, i) end
      end
      if #list == 0 then M.header_users[bn] = nil end
    end
  end
end

local function set_tu_includes(tu_path, incs, observed_order)
  unindex_tu(tu_path)
  M._file_include_cache[tu_path] = nil
  M.tu_includes[tu_path] = incs
  M.tu_mtime[tu_path] = observed_order
  for _, e in ipairs(incs) do
    local bn = basename_of(e.name)
    local list = M.header_users[bn]
    if not list then list = {}; M.header_users[bn] = list end
    local found = false
    for _, p in ipairs(list) do if p == tu_path then found = true; break end end
    if not found then table.insert(list, tu_path) end
  end
  if observed_order > lru_seq then lru_seq = observed_order end
end

function M.observe_tu(tu_path, source_text)
  local incs = parse_text(source_text)
  lru_seq = lru_seq + 1
  set_tu_includes(tu_path, incs, lru_seq)
  emit_change()
end

function M.observe_tu_from_disk(tu_path)
  local f = io.open(tu_path, "r")
  if not f then return false end
  local text = f:read("*a"); f:close()
  M.observe_tu(tu_path, text)
  return true
end

function M.invalidate(tu_path)
  local had_persisted_entry = is_tu_path(tu_path) and M.tu_includes[tu_path] ~= nil
  unindex_tu(tu_path)
  M.tu_includes[tu_path] = nil
  M.tu_mtime[tu_path] = nil
  M._file_include_cache[tu_path] = nil
  if is_header_path(tu_path) then
    local basename = basename_of(tu_path)
    for key, _ in pairs(M._path_cache) do
      if key:sub(-#basename - 1) == "\0" .. basename then M._path_cache[key] = nil end
    end
  end
  if had_persisted_entry then emit_change() end
end

local function stat_signature(path)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" then return nil end
  return {
    size = st.size,
    mtime_sec = st.mtime and st.mtime.sec or 0,
    mtime_nsec = st.mtime and st.mtime.nsec or 0,
  }
end

function M.snapshot()
  local tus = {}
  for tu, incs in pairs(M.tu_includes) do
    if is_tu_path(tu) then
      table.insert(tus, {
        path = tu,
        includes = incs,
        observed_order = M.tu_mtime[tu] or 0,
      })
    end
  end
  table.sort(tus, function(a, b) return a.observed_order > b.observed_order end)
  local entries = {}
  for i, tu in ipairs(tus) do
    if i > PROJECT_SCAN_LIMIT then break end
    local sig = stat_signature(tu.path)
    if sig then
      table.insert(entries, {
        path = tu.path,
        includes = clone_includes(tu.includes),
        size = sig.size,
        mtime_sec = sig.mtime_sec,
        mtime_nsec = sig.mtime_nsec,
        observed_order = tu.observed_order,
      })
    end
  end
  return { version = 1, created_at = os.time(), lru_seq = lru_seq, tus = entries }
end

local function valid_include(e)
  return type(e) == "table"
      and type(e.name) == "string"
      and (e.kind == '"' or e.kind == "<")
      and type(e.line) == "number"
      and type(e.raw) == "string"
end

local function valid_cache_entry(entry)
  if type(entry) ~= "table"
      or type(entry.path) ~= "string"
      or type(entry.size) ~= "number"
      or type(entry.mtime_sec) ~= "number"
      or type(entry.mtime_nsec) ~= "number"
      or type(entry.observed_order) ~= "number"
      or type(entry.includes) ~= "table" then
    return false
  end
  for _, inc in ipairs(entry.includes) do
    if not valid_include(inc) then return false end
  end
  return true
end

function M.restore_snapshot(snapshot)
  if type(snapshot) ~= "table"
      or snapshot.version ~= 1
      or type(snapshot.lru_seq) ~= "number"
      or type(snapshot.tus) ~= "table" then
    return { loaded = 0, dropped = 0, unsupported = snapshot ~= nil }
  end
  local loaded, dropped = 0, 0
  for _, entry in ipairs(snapshot.tus) do
    if not valid_cache_entry(entry) then
      dropped = dropped + 1
    else
      local sig = stat_signature(entry.path)
      if not sig
          or sig.size ~= entry.size
          or sig.mtime_sec ~= entry.mtime_sec
          or sig.mtime_nsec ~= entry.mtime_nsec then
        dropped = dropped + 1
      else
        set_tu_includes(entry.path, clone_includes(entry.includes), entry.observed_order)
        loaded = loaded + 1
      end
    end
  end
  if snapshot.lru_seq > lru_seq then lru_seq = snapshot.lru_seq end
  return { loaded = loaded, dropped = dropped, unsupported = false }
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

local function path_cache_key(basename, root)
  return root .. "\0" .. basename
end

find_header_path = function(basename, root)
  local key = path_cache_key(basename, root)
  local cached = M._path_cache[key]
  if cached ~= nil then return cached or nil end
  local found = vim.fs.find(basename, { path = root, type = "file", limit = 1 })
  local path = (found and found[1]) or false
  M._path_cache[key] = path
  return path or nil
end

file_includes = function(path)
  if M.tu_includes[path] then return M.tu_includes[path] end
  if M._file_include_cache[path] then return M._file_include_cache[path] end
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a"); f:close()
  local incs = parse_text(text)
  M._file_include_cache[path] = incs
  return incs
end

local function resolve_include_path(from_path, entry, root)
  if entry.kind == '"' then
    local dir = vim.fs.dirname(from_path) or "."
    local local_path = entry.name:sub(1, 1) == "/" and entry.name or (dir .. "/" .. entry.name)
    local st = vim.uv.fs_stat(local_path)
    if st and st.type == "file" then return local_path end
  end
  if not is_header_path(entry.name) then return nil end
  return find_header_path(basename_of(entry.name), root)
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function same_path(a, b)
  return normalize_path(a) == normalize_path(b)
end

local function include_entry_matches_header(from_path, entry, header_path, root)
  local resolved = resolve_include_path(from_path, entry, root)
  if resolved then return same_path(resolved, header_path) end
  return basename_of(entry.name) == basename_of(header_path)
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
  local comp = companion_candidate(header_path)
  if comp then return comp end
  return indirect_candidates(header_path)[1]
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
  local only_companion = #out > 0
  for _, candidate in ipairs(out) do
    if candidate.companion ~= true then only_companion = false; break end
  end
  if #out == 0 or only_companion then
    for _, c in ipairs(indirect_candidates(header_path)) do
      local seen = false
      for _, candidate in ipairs(out) do
        if candidate.tu_path == c.tu_path then seen = true; break end
      end
      if not seen then table.insert(out, c) end
    end
  end
  return sort_candidates(out)
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

local function append_filtered_prefix(includes, stop, header_basename, root, state)
  for i = 1, stop do
    local e = includes[i]
    local prefix_bn = basename_of(e.name)
    if prefix_bn ~= header_basename
       and not transitively_includes(prefix_bn, header_basename, root, CYCLE_CHECK_DEPTH, {}) then
      local raw = e.raw
      local next_bytes = state.bytes + #raw + 1
      if #state.lines >= MAX_PREAMBLE_LINES or next_bytes > MAX_PREAMBLE_BYTES then break end
      state.bytes = next_bytes
      table.insert(state.lines, raw)
    end
  end
end

local function clone_prefix_state(state)
  return { lines = vim.list_extend({}, state.lines), bytes = state.bytes }
end

local function find_indirect_match_in_file(current_path, includes, header_path, root, depth_remaining, prefix, seen, root_index, current_depth)
  local header_basename = basename_of(header_path)
  for i, entry in ipairs(includes) do
    local next_prefix = clone_prefix_state(prefix)
    append_filtered_prefix(includes, i - 1, header_basename, root, next_prefix)
    local include_index = root_index or (i - 1)
    local matches_target = include_entry_matches_header(current_path, entry, header_path, root)
    if matches_target then
      if root_index ~= nil then
        return {
          prefix_lines = next_prefix.lines,
          include_index = include_index,
          include_depth = current_depth + 1,
        }
      end
    elseif depth_remaining > 1 then
      local resolved = resolve_include_path(current_path, entry, root)
      if resolved and is_header_path(resolved) and not seen[resolved] then
        local child_includes = file_includes(resolved)
        if child_includes then
          seen[resolved] = true
          local found = find_indirect_match_in_file(
            resolved,
            child_includes,
            header_path,
            root,
            depth_remaining - 1,
            next_prefix,
            seen,
            include_index,
            current_depth + 1
          )
          seen[resolved] = nil
          if found then return found end
        end
      end
    end
  end
  return nil
end

local function indirect_candidate_from_tu(tu_path, header_path)
  if INDIRECT_INCLUDE_DEPTH < 2 or not is_tu_path(tu_path) then return nil end
  local tu_inc = M.tu_includes[tu_path]
  if not tu_inc then return nil end
  local root = project_root_for_tu(tu_path)
  local found = find_indirect_match_in_file(
    tu_path,
    tu_inc,
    header_path,
    root,
    INDIRECT_INCLUDE_DEPTH,
    { lines = {}, bytes = 0 },
    { [tu_path] = true },
    nil,
    0
  )
  if not found or #found.prefix_lines == 0 then return nil end
  return {
    tu_path = tu_path,
    prefix_lines = found.prefix_lines,
    direct = false,
    include_index = found.include_index,
    observed_order = M.tu_mtime[tu_path] or 0,
    companion = false,
    include_depth = found.include_depth,
  }
end

indirect_candidates = function(header_path)
  local out = {}
  for tu, _ in pairs(M.tu_includes) do
    local candidate = indirect_candidate_from_tu(tu, header_path)
    if candidate then table.insert(out, candidate) end
  end
  return sort_candidates(out)
end

build_prefix = function(tu_path, header_basename, root)
  local tu_inc = M.tu_includes[tu_path]
  if not tu_inc then return nil, false end
  local cut = nil
  for i, e in ipairs(tu_inc) do
    if basename_of(e.name) == header_basename then cut = i; break end
  end
  local stop = cut and (cut - 1) or #tu_inc
  local state = { lines = {}, bytes = 0 }
  append_filtered_prefix(tu_inc, stop, header_basename, root, state)
  return state.lines, cut ~= nil
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

function M.is_self_contained_header(path)
  return header_is_self_contained(path)
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
