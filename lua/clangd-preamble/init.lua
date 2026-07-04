local lsp = require("clangd-preamble.lsp")
local graph = require("clangd-preamble.graph")

local M = {}

M._enabled = true
M._buf_state = {}
M._attached_clients = {}
M._disabled_uris = {}
M._forced_uris = {}
M._preferred_includers = {}
M._recent_includer_uris = {}
M._config = { default_selector = "preamble_size", graph_cache = true }
M._autogroup = vim.api.nvim_create_augroup("ClangdPreamble", { clear = true })
local last_active_tu_path = nil
local graph_cache_restored_for = nil
local graph_cache_save_pending = false
local buf_paths = {}

local function normalize_default_selector(value)
  if value == "last_seen" or value == "lastSeen" or value == "recent" then
    return "last_seen"
  end
  return "preamble_size"
end

local function default_selector_label()
  return M._config.default_selector == "last_seen" and "last seen" or "preamble size"
end

local function graph_cache_enabled()
  return M._config.graph_cache ~= false
end

local function graph_cache_dir()
  return vim.fn.stdpath("cache") .. "/clangd-preamble"
end

local function graph_cache_path()
  local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  return graph_cache_dir() .. "/graph-" .. vim.fn.sha256(cwd) .. ".json"
end

local function json_encode(value)
  if vim.json and vim.json.encode then return vim.json.encode(value) end
  return vim.fn.json_encode(value)
end

local function json_decode(text)
  if vim.json and vim.json.decode then return vim.json.decode(text) end
  return vim.fn.json_decode(text)
end

local function save_graph_cache_now()
  if not graph_cache_enabled() then return end
  local ok_mkdir = pcall(vim.fn.mkdir, graph_cache_dir(), "p")
  if not ok_mkdir then return end
  local ok_json, text = pcall(json_encode, graph.snapshot())
  if not ok_json or type(text) ~= "string" then return end
  local f = io.open(graph_cache_path(), "w")
  if not f then return end
  f:write(text)
  f:close()
end

local function schedule_graph_cache_save(delay_ms)
  if not graph_cache_enabled() or graph_cache_save_pending then return end
  graph_cache_save_pending = true
  vim.defer_fn(function()
    graph_cache_save_pending = false
    save_graph_cache_now()
  end, delay_ms or 1000)
end

local function restore_graph_cache()
  local path = graph_cache_path()
  if graph_cache_restored_for == path or not graph_cache_enabled() then return end
  graph_cache_restored_for = path
  local f = io.open(path, "r")
  if not f then return end
  local text = f:read("*a")
  f:close()
  local ok, snapshot = pcall(json_decode, text)
  if not ok then
    os.remove(path)
    return
  end
  local result = graph.restore_snapshot(snapshot)
  if result.unsupported then
    os.remove(path)
  elseif result.dropped and result.dropped > 0 then
    schedule_graph_cache_save(5000)
  end
end

local function ensure_graph_cache_restored()
  if graph_cache_enabled() then restore_graph_cache() end
end

graph.on_change(function() schedule_graph_cache_save() end)

local function get_state_for_bufnr(bufnr) return M._buf_state[bufnr] end
local function get_state_for_uri(uri)
  for _, st in pairs(M._buf_state) do
    if st.header_uri == uri then return st end
  end
end
local function all_states() return M._buf_state end
local function is_enabled() return M._enabled end
local function is_disabled(uri) return M._disabled_uris[uri] == true end

local function uri_for_bufnr(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return nil, nil end
  return vim.uri_from_fname(path), path
end

local function mark_forced(uri) M._forced_uris[uri] = true end
local function consume_forced(uri)
  local forced = M._forced_uris[uri] == true
  M._forced_uris[uri] = nil
  return forced
end

local function clear_selection(uri)
  M._preferred_includers[uri] = nil
  M._recent_includer_uris[uri] = nil
end

local function mark_disabled(uri)
  M._disabled_uris[uri] = true
  M._forced_uris[uri] = nil
  clear_selection(uri)
end

local function clear_disabled(uri) M._disabled_uris[uri] = nil end

local function uses_recent_selector(uri)
  if M._preferred_includers[uri] then return false end
  return M._recent_includer_uris[uri] == true or M._config.default_selector == "last_seen"
end

local function find_header_includer(path, uri, force)
  local preferred = M._preferred_includers[uri]
  if preferred then
    return graph.find_includer(path, { force = true, preferred_tu = preferred })
  end
  if M._recent_includer_uris[uri] then
    return graph.find_recent_includer(path, { force = true })
        or graph.find_includer(path, { force = true })
  end
  if M._config.default_selector == "last_seen" then
    return graph.find_recent_includer(path, { force = force })
        or graph.find_includer(path, { force = force })
  end
  return graph.find_includer(path, { force = force })
end

local function on_header_attached(st)
  M._buf_state[st.bufnr] = st
end

local function on_header_detached(st)
  M._buf_state[st.bufnr] = nil
  lsp.clear_semtok(st.bufnr)
  -- Virtual companion cleanup is handled by BufWipeout/BufUnload so that
  -- reissue_open (didClose + didOpen) doesn't close and re-open the companion
  -- mid-cycle, which would reset the pch_ready flag and loop.
end

local function reissue_open(client, bufnr, path, uri)
  client:notify("textDocument/didClose", { textDocument = { uri = uri } })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  client:notify("textDocument/didOpen", {
    textDocument = {
      uri = uri,
      languageId = vim.bo[bufnr].filetype,
      version = vim.lsp.util.buf_versions[bufnr] or 0,
      text = table.concat(lines, "\n") .. (vim.bo[bufnr].endofline and "\n" or ""),
    },
  })
end

local CTX = {}

local function try_promote_pending(client)
  for _, bn in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bn) and vim.api.nvim_buf_is_loaded(bn)
       and not M._buf_state[bn] then
      local path = vim.api.nvim_buf_get_name(bn)
      if path ~= "" and lsp.is_header_path(path) then
        local uri = vim.uri_from_fname(path)
        if not M._disabled_uris[uri] then
          local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bn })
          for _, c in ipairs(clients) do
            if c.id == client.id then
              local inc = find_header_includer(path, uri, false)
              if inc then
                reissue_open(c, bn, path, uri)
                lsp.send_fake_change(c, bn, uri)
              end
              break
            end
          end
        end
      end
    end
  end
end

local function try_promote_pending_for_attached_clients()
  for id, attached in pairs(M._attached_clients) do
    if attached then
      local client = vim.lsp.get_client_by_id(id)
      if client and client.name == "clangd" then try_promote_pending(client) end
    end
  end
end

-- Re-issue didOpen for headers that already have state but whose includer
-- just became live in clangd (editor open). The companion-from-disk path
-- builds the preamble before clangd has a PCH for the TU, leaving residual
-- diagnostics. Reissuing after the TU's didOpen lets clangd re-analyze the
-- header with its freshly compiled PCH context.
local function try_refresh_existing(client, tu_path)
  for bn, st in pairs(M._buf_state) do
    if st.includer_tu == tu_path then
      local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bn })
      for _, c in ipairs(clients) do
        if c.id == client.id then
          reissue_open(c, bn, st.header_path, st.header_uri)
          lsp.send_fake_change(c, bn, st.header_uri)
          break
        end
      end
    end
  end
end

local function observe_tu_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or not lsp.is_tu_path(path) then return nil end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n") .. (vim.bo[bufnr].endofline and "\n" or "")
  graph.observe_tu(path, text)
  return path
end

local function observe_tu_from_current_source(path)
  if not path or path == "" or not lsp.is_tu_path(path) then return nil end
  local bufnr = vim.fn.bufnr(path)
  local observed
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    observed = observe_tu_buffer(bufnr)
  else
    graph.invalidate(path)
    if graph.observe_tu_from_disk(path) then observed = path end
  end
  if observed then try_promote_pending_for_attached_clients() end
  return observed
end

local function reissue_recent_header_if_changed(bufnr)
  local uri, path = uri_for_bufnr(bufnr)
  if not uri or not path or M._disabled_uris[uri] or not uses_recent_selector(uri) then return false end
  local recent = graph.find_recent_includer(path, { force = true })
  if not recent then return false end
  local st = M._buf_state[bufnr]
  if st and st.includer_tu == recent.tu_path then return false end
  local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bufnr })
  if #clients == 0 then return false end
  mark_forced(uri)
  reissue_open(clients[1], bufnr, path, uri)
  lsp.send_fake_change(clients[1], bufnr, uri)
  return true
end

local function reissue_recent_headers_for_tu(tu_path)
  for _, bn in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bn) and vim.api.nvim_buf_is_loaded(bn) then
      local uri, path = uri_for_bufnr(bn)
      if uri and path and lsp.is_header_path(path) and uses_recent_selector(uri) then
        local recent = graph.find_recent_includer(path, { force = true })
        if recent and recent.tu_path == tu_path then reissue_recent_header_if_changed(bn) end
      end
    end
  end
end

local function handle_active_buffer_change(bufnr)
  ensure_graph_cache_restored()
  local last_bn = last_active_tu_path and vim.fn.bufnr(last_active_tu_path) or -1
  local left_tu = last_bn > 0 and observe_tu_buffer(last_bn) or nil
  last_active_tu_path = nil
  if left_tu then reissue_recent_headers_for_tu(left_tu) end

  local current_tu = observe_tu_buffer(bufnr)
  if current_tu then
    last_active_tu_path = current_tu
    reissue_recent_headers_for_tu(current_tu)
  elseif bufnr and bufnr ~= 0 then
    reissue_recent_header_if_changed(bufnr)
  end
end

local function current_buf_path(bufnr)
  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return nil end
  return path
end

local function remember_buf_path(bufnr)
  local path = current_buf_path(bufnr)
  if path then buf_paths[bufnr] = path end
  return path
end

local function refresh_or_invalidate_path(path)
  if not path or path == "" then return end
  ensure_graph_cache_restored()
  if lsp.is_tu_path(path) then
    observe_tu_from_current_source(path)
  elseif lsp.is_header_path(path) then
    graph.invalidate(path)
  end
end

CTX.is_enabled            = is_enabled
CTX.get_state_for_bufnr   = get_state_for_bufnr
CTX.get_state_for_uri     = get_state_for_uri
CTX.all_states            = all_states
CTX.is_disabled           = is_disabled
CTX.consume_forced        = consume_forced
CTX.find_includer         = find_header_includer
CTX.on_header_attached    = on_header_attached
CTX.on_header_detached    = on_header_detached
-- Promotion can be heavy (disk I/O for every pending header), so defer it
-- off the wrapped-notify path to keep didOpen responsive.
CTX.on_tu_observed        = function(client, tu_path)
  vim.schedule(function()
    try_promote_pending(client)
    if tu_path then try_refresh_existing(client, tu_path) end
  end)
end

-- Called by lsp.lua when the companion's first publishDiagnostics arrives,
-- meaning clangd has built its PCH. Re-issue all headers that were analyzed
-- before that PCH was ready.
lsp._on_virtual_tu_ready = function(client, tu_path)
  try_refresh_existing(client, tu_path)
end

function M.setup(opts)
  opts = opts or {}
  if opts.default_selector ~= nil then
    M._config.default_selector = normalize_default_selector(opts.default_selector)
  end
  if opts.graph_cache ~= nil then
    M._config.graph_cache = opts.graph_cache ~= false
  end
  ensure_graph_cache_restored()
end

function M.default_selector()
  return M._config.default_selector
end

function M.includer_for(bufnr)
  local st = M._buf_state[bufnr or vim.api.nvim_get_current_buf()]
  return st and st.includer_tu or nil
end

function M.selection_for(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local uri = uri_for_bufnr(bufnr)
  if not uri then return "auto" end
  if M._preferred_includers[uri] then return "fixed", M._preferred_includers[uri] end
  if M._recent_includer_uris[uri] then return "recent" end
  return "auto"
end

function M.is_disabled(bufnr)
  local uri = uri_for_bufnr(bufnr or vim.api.nvim_get_current_buf())
  return uri and M._disabled_uris[uri] == true or false
end

function M.list_includers(bufnr)
  local _, path = uri_for_bufnr(bufnr or vim.api.nvim_get_current_buf())
  if not path then return {} end
  return graph.list_includers(path, { force = true })
end

local function reissue_selected_header(bufnr)
  local uri, path = uri_for_bufnr(bufnr)
  if not uri or not path or not lsp.is_header_path(path) then return false end
  local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bufnr })
  if #clients == 0 then return false end
  mark_forced(uri)
  reissue_open(clients[1], bufnr, path, uri)
  lsp.send_fake_change(clients[1], bufnr, uri)
  return true
end

local function active_header()
  local bufnr = vim.api.nvim_get_current_buf()
  local uri, path = uri_for_bufnr(bufnr)
  if not uri or not path or not lsp.is_header_path(path) then
    vim.notify("clangd-preamble: current file is not a header", vim.log.levels.WARN)
    return nil, nil, nil
  end
  return bufnr, uri, path
end

local function workspace_relative(path)
  local cwd = vim.fn.getcwd()
  local rel = vim.fn.fnamemodify(path, ":.")
  if rel ~= path then return rel end
  if path:sub(1, #cwd + 1) == cwd .. "/" then return path:sub(#cwd + 2) end
  return path
end

function M.use_auto_includer(bufnr)
  local uri = uri_for_bufnr(bufnr or vim.api.nvim_get_current_buf())
  if not uri then return false end
  clear_disabled(uri)
  clear_selection(uri)
  return reissue_selected_header(bufnr or vim.api.nvim_get_current_buf())
end

function M.use_recent_includer(bufnr)
  local uri = uri_for_bufnr(bufnr or vim.api.nvim_get_current_buf())
  if not uri then return false end
  clear_disabled(uri)
  M._recent_includer_uris[uri] = true
  M._preferred_includers[uri] = nil
  return reissue_selected_header(bufnr or vim.api.nvim_get_current_buf())
end

function M.use_includer(bufnr, tu_path)
  local uri = uri_for_bufnr(bufnr or vim.api.nvim_get_current_buf())
  if not uri or not tu_path then return false end
  clear_disabled(uri)
  M._preferred_includers[uri] = tu_path
  M._recent_includer_uris[uri] = nil
  return reissue_selected_header(bufnr or vim.api.nvim_get_current_buf())
end

function M.attach(client, bufnr)
  if client.name ~= "clangd" then return end
  ensure_graph_cache_restored()
  lsp.install_handlers(get_state_for_uri, all_states)
  if M._attached_clients[client.id] then return end
  M._attached_clients[client.id] = true
  lsp.wrap_client(client, CTX)

  -- Neovim sends didOpen synchronously during buf_attach_client, BEFORE on_attach
  -- runs. The first buffer attached to this client therefore went through the
  -- unwrapped notify. Re-issue it now that the wrapper is in place so headers
  -- get their preamble and TUs get observed into the graph.
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path ~= "" then
    local uri = vim.uri_from_fname(path)
    if lsp.is_header_path(path) then
      reissue_open(client, bufnr, path, uri)
    elseif lsp.is_tu_path(path) then
      observe_tu_buffer(bufnr)
    end
  end
end

vim.api.nvim_create_autocmd({ "BufEnter", "BufLeave" }, {
  group = M._autogroup,
  callback = function(args)
    remember_buf_path(args.buf)
    if M._enabled then handle_active_buffer_change(args.buf) end
  end,
})

vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
  group = M._autogroup,
  callback = function(args)
    local path = remember_buf_path(args.buf)
    refresh_or_invalidate_path(path)
  end,
})

vim.api.nvim_create_autocmd("BufFilePost", {
  group = M._autogroup,
  callback = function(args)
    local old_path = buf_paths[args.buf]
    local new_path = remember_buf_path(args.buf)
    if old_path and old_path ~= new_path then graph.invalidate(old_path) end
    refresh_or_invalidate_path(new_path)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = M._autogroup,
  callback = function() save_graph_cache_now() end,
})

vim.api.nvim_create_autocmd("LspDetach", {
  group = M._autogroup,
  callback = function(args)
    local cli = args.data and args.data.client_id and vim.lsp.get_client_by_id(args.data.client_id)
    if not cli or cli.name ~= "clangd" then return end
    M._attached_clients[args.data.client_id] = nil
    local st = M._buf_state[args.buf]
    if st then
      lsp.clear_semtok(args.buf)
      st.includer_stale = true
    end
  end,
})

vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
  group = M._autogroup,
  callback = function(args)
    buf_paths[args.buf] = nil
    local st = M._buf_state[args.buf]
    if st then
      M._buf_state[args.buf] = nil
      lsp.clear_semtok(args.buf)
      -- Close virtual companion if no other header still uses it.
      local tu = st.includer_tu
      if tu and lsp._virtual_tus[tu] then
        local still_used = false
        for _, other in pairs(M._buf_state) do
          if other.includer_tu == tu then still_used = true; break end
        end
        if not still_used then lsp.close_tu_virtually(tu) end
      end
    end
  end,
})

-- ====================================================================
-- Commands
-- ====================================================================

vim.api.nvim_create_user_command("NoSelfContainedDisable", function()
  M._enabled = false
  vim.notify("clangd-preamble: globally disabled", vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("NoSelfContainedEnable", function()
  M._enabled = true
  vim.notify("clangd-preamble: globally enabled", vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("NoSelfContainedDisableBuf", function()
  local bn, uri, path = active_header()
  if not bn then return end
  local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bn })
  if #clients == 0 then
    vim.notify("clangd-preamble: no clangd client attached", vim.log.levels.WARN)
    return
  end
  mark_disabled(uri)
  local st = M._buf_state[bn]
  if st then on_header_detached(st) end
  reissue_open(clients[1], bn, path, uri)
  vim.notify("clangd-preamble: disabled for current file", vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("NoSelfContainedEnableBuf", function()
  local bn, uri = active_header()
  if not bn then return end
  clear_disabled(uri)
  mark_forced(uri)
  if reissue_selected_header(bn) then
    local st = M._buf_state[bn]
    if st then
      vim.notify(("clangd-preamble: enabled (TU=%s, %d preamble lines)"):format(
        vim.fn.fnamemodify(st.includer_tu, ":t"), st.preamble_lines), vim.log.levels.INFO)
    end
  else
    vim.notify("clangd-preamble: no clangd client attached", vim.log.levels.WARN)
  end
end, {})

vim.api.nvim_create_user_command("NoSelfContainedSelectIncluder", function()
  local bn, uri, path = active_header()
  if not bn then return end
  local candidates = graph.list_includers(path, { force = true })
  if #candidates == 0 then
    vim.notify("clangd-preamble: no includer candidates found for current file", vim.log.levels.WARN)
    return
  end

  local mode, preferred = M.selection_for(bn)
  local current = M.includer_for(bn)
  local auto = graph.find_includer(path, { force = true })
  local recent = graph.find_recent_includer(path, { force = true })
  local configured_default = M._config.default_selector == "last_seen" and (recent or auto) or auto
  local items = {
    {
      kind = "auto",
      label = ("%sUse configured default (%s)%s"):format(
        mode == "auto" and "* " or "  ",
        default_selector_label(),
        configured_default and (" (" .. workspace_relative(configured_default.tu_path) .. ")") or ""),
    },
    {
      kind = "recent",
      label = ("%sUse last seen includer%s"):format(
        mode == "recent" and "* " or "  ",
        recent and (" (" .. workspace_relative(recent.tu_path) .. ")") or ""),
    },
  }

  for _, c in ipairs(candidates) do
    local suffix = c.tu_path == current and ", current" or ""
    table.insert(items, {
      kind = "fixed",
      tu_path = c.tu_path,
      label = ("%s%s - %d preamble line(s), include #%d, direct=%s%s%s"):format(
        preferred == c.tu_path and "* " or "  ",
        workspace_relative(c.tu_path),
        #c.prefix_lines,
        c.include_index + 1,
        tostring(c.direct),
        c.companion and ", companion" or "",
        suffix),
    })
  end

  vim.ui.select(items, {
    prompt = "Select preamble source translation unit",
    format_item = function(item) return item.label end,
  }, function(item)
    if not item then return end
    local ok = false
    if item.kind == "auto" then
      ok = M.use_auto_includer(bn)
    elseif item.kind == "recent" then
      ok = M.use_recent_includer(bn)
    elseif item.tu_path then
      ok = M.use_includer(bn, item.tu_path)
    end
    if not ok then
      vim.notify("clangd-preamble: no clangd client attached", vim.log.levels.WARN)
      return
    end
    local st = M._buf_state[bn]
    if st then
      vim.notify(("clangd-preamble: using %s (%d preamble lines)"):format(
        vim.fn.fnamemodify(st.includer_tu, ":t"), st.preamble_lines), vim.log.levels.INFO)
    end
  end)
end, {})

vim.api.nvim_create_user_command("NoSelfContainedStatus", function()
  local bn = vim.api.nvim_get_current_buf()
  local uri, path = uri_for_bufnr(bn)
  local st = M._buf_state[bn]
  local lines = { ("global enabled: %s"):format(tostring(M._enabled)) }
  if path and lsp.is_header_path(path) then
    local mode, preferred = M.selection_for(bn)
    table.insert(lines, ("buffer disabled: %s"):format(tostring(uri and M._disabled_uris[uri] == true)))
    if mode == "fixed" then
      table.insert(lines, ("selection: fixed (%s)"):format(preferred))
    else
      table.insert(lines, ("selection: %s"):format(
        mode == "recent" and "last seen" or ("default (" .. default_selector_label() .. ")")))
    end
    table.insert(lines, ("includer candidates: %d"):format(#graph.list_includers(path, { force = true })))
  end
  if st then
    table.insert(lines, ("buffer %d  active=%s  preamble_lines=%d  stale=%s"):format(
      bn, tostring(st.active), st.preamble_lines, tostring(st.includer_stale)))
    table.insert(lines, ("includer TU:    %s  (direct=%s)"):format(st.includer_tu, tostring(st.includer_direct)))
    table.insert(lines, "preamble:")
    for line in st.preamble_text:gmatch("[^\n]+") do
      table.insert(lines, "  " .. line)
    end
  else
    table.insert(lines, "no state for current buffer")
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("NoSelfContainedRefresh", function()
  local bn, uri = active_header()
  if not bn then return end
  local existing = M._buf_state[bn]
  if existing then observe_tu_from_current_source(existing.includer_tu) end
  clear_disabled(uri)
  mark_forced(uri)
  if not reissue_selected_header(bn) then
    vim.notify("clangd-preamble: no clangd client attached", vim.log.levels.WARN)
    return
  end
  local st = M._buf_state[bn]
  if st then
    vim.notify(("clangd-preamble: refreshed (TU=%s, %d preamble lines)"):format(
      vim.fn.fnamemodify(st.includer_tu, ":t"), st.preamble_lines), vim.log.levels.INFO)
  else
    vim.notify("clangd-preamble: no includer found", vim.log.levels.WARN)
  end
end, {})

vim.api.nvim_create_user_command("NoSelfContainedDumpGraph", function()
  vim.notify(graph.dump(), vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("NoSelfContainedDumpDiagnostics", function()
  local bn = vim.api.nvim_get_current_buf()
  local diags = lsp._dropped_diags[bn] or {}
  local lines = { ("dropped diagnostics for buf %d (in preamble): %d"):format(bn, #diags) }
  for i, d in ipairs(diags) do
    table.insert(lines, ("  [%d] sev=%s line=%d msg=%s"):format(
      i, tostring(d.severity), d.range.start.line, (d.message or ""):sub(1, 200)))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, {})

vim.api.nvim_create_user_command("NoSelfContainedScanProject", function()
  ensure_graph_cache_restored()
  local root = vim.fn.getcwd()
  local n = graph.scan_project_for_includers(root)
  try_promote_pending_for_attached_clients()
  vim.notify(("clangd-preamble: scanned %d TUs under %s"):format(n, root), vim.log.levels.INFO)
end, {})

return M
