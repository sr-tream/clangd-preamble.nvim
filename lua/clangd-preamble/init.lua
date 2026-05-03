local lsp = require("clangd-preamble.lsp")
local graph = require("clangd-preamble.graph")

local M = {}

M._enabled = true
M._buf_state = {}
M._attached_clients = {}
M._autogroup = vim.api.nvim_create_augroup("ClangdPreamble", { clear = true })

local function get_state_for_bufnr(bufnr) return M._buf_state[bufnr] end
local function get_state_for_uri(uri)
  for _, st in pairs(M._buf_state) do
    if st.header_uri == uri then return st end
  end
end
local function all_states() return M._buf_state end
local function is_enabled() return M._enabled end

local function on_header_attached(st)
  M._buf_state[st.bufnr] = st
end

local function on_header_detached(st)
  M._buf_state[st.bufnr] = nil
  lsp.clear_semtok(st.bufnr)
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
        local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bn })
        for _, c in ipairs(clients) do
          if c.id == client.id then
            if graph.find_includer(path) then
              local uri = vim.uri_from_fname(path)
              reissue_open(c, bn, path, uri)
            end
            break
          end
        end
      end
    end
  end
end

CTX.is_enabled            = is_enabled
CTX.get_state_for_bufnr   = get_state_for_bufnr
CTX.get_state_for_uri     = get_state_for_uri
CTX.on_header_attached    = on_header_attached
CTX.on_header_detached    = on_header_detached
-- Promotion can be heavy (disk I/O for every pending header), so defer it
-- off the wrapped-notify path to keep didOpen responsive.
CTX.on_tu_observed        = function(client) vim.schedule(function() try_promote_pending(client) end) end

function M.includer_for(bufnr)
  local st = M._buf_state[bufnr or vim.api.nvim_get_current_buf()]
  return st and st.includer_tu or nil
end

function M.attach(client, bufnr)
  if client.name ~= "clangd" then return end
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
      graph.observe_tu_from_disk(path)
    end
  end
end

local function force_reopen_header(st)
  local clients = vim.lsp.get_clients({ name = "clangd", bufnr = st.bufnr })
  if #clients == 0 then return end
  M._buf_state[st.bufnr] = nil
  lsp.clear_semtok(st.bufnr)
  reissue_open(clients[1], st.bufnr, st.header_path, st.header_uri)
end

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
    if M._buf_state[args.buf] then
      M._buf_state[args.buf] = nil
      lsp.clear_semtok(args.buf)
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
  local bn = vim.api.nvim_get_current_buf()
  local st = M._buf_state[bn]
  if not st then
    vim.notify("clangd-preamble: no state for current buffer", vim.log.levels.WARN)
    return
  end
  st.active = false
  force_reopen_header(st)
  M._buf_state[bn] = nil
end, {})

vim.api.nvim_create_user_command("NoSelfContainedEnableBuf", function()
  local bn = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bn)
  local includer = graph.find_includer(path, true)
  if not includer then
    vim.notify("clangd-preamble: no includer found for " .. path, vim.log.levels.WARN)
    return
  end
  local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bn })
  if #clients == 0 then
    vim.notify("clangd-preamble: no clangd client attached", vim.log.levels.WARN)
    return
  end
  local cli = clients[1]
  local uri = vim.uri_from_fname(path)
  cli:notify("textDocument/didClose", { textDocument = { uri = uri } })
  local st = lsp.build_state(bn, uri, path, includer)
  on_header_attached(st)
  local lines = vim.api.nvim_buf_get_lines(bn, 0, -1, false)
  cli:notify("textDocument/didOpen", {
    textDocument = {
      uri = uri,
      languageId = vim.bo[bn].filetype,
      version = vim.lsp.util.buf_versions[bn] or 0,
      text = table.concat(lines, "\n") .. (vim.bo[bn].endofline and "\n" or ""),
    },
  })
end, {})

vim.api.nvim_create_user_command("NoSelfContainedStatus", function()
  local bn = vim.api.nvim_get_current_buf()
  local st = M._buf_state[bn]
  local lines = { ("global enabled: %s"):format(tostring(M._enabled)) }
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
  local bn = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bn)
  if not lsp.is_header_path(path) then
    vim.notify("clangd-preamble: not a header", vim.log.levels.WARN)
    return
  end
  local existing = M._buf_state[bn]
  if existing then graph.invalidate(existing.includer_tu) end
  local includer = graph.find_includer(path, true)
  if not includer then
    vim.notify("clangd-preamble: no includer found", vim.log.levels.WARN)
    return
  end
  local clients = vim.lsp.get_clients({ name = "clangd", bufnr = bn })
  if #clients == 0 then return end
  local cli = clients[1]
  local uri = vim.uri_from_fname(path)
  cli:notify("textDocument/didClose", { textDocument = { uri = uri } })
  local st = lsp.build_state(bn, uri, path, includer)
  on_header_attached(st)
  local lines = vim.api.nvim_buf_get_lines(bn, 0, -1, false)
  cli:notify("textDocument/didOpen", {
    textDocument = {
      uri = uri,
      languageId = vim.bo[bn].filetype,
      version = vim.lsp.util.buf_versions[bn] or 0,
      text = table.concat(lines, "\n") .. (vim.bo[bn].endofline and "\n" or ""),
    },
  })
  vim.notify(("clangd-preamble: refreshed (TU=%s, %d preamble lines)"):format(
    includer.tu_path, st.preamble_lines), vim.log.levels.INFO)
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
  local root = vim.fn.getcwd()
  local n = graph.scan_project_for_includers(root)
  vim.notify(("clangd-preamble: scanned %d TUs under %s"):format(n, root), vim.log.levels.INFO)
end, {})

return M
