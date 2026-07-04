local graph = require("clangd-preamble.graph")

local M = {}

M.MARKER = "// __NSC_PREAMBLE_END__"

-- ====================================================================
-- helpers
-- ====================================================================

local function uri_to_path(uri) return vim.uri_to_fname(uri) end

local function is_header_path(path)
  return path:match("%.h$")   or path:match("%.hh$")  or path:match("%.hpp$")
      or path:match("%.hxx$") or path:match("%.inl$") or path:match("%.inc$")
      or path:match("%.ipp$") or path:match("%.tcc$") or path:match("%.tpp$")
end
M.is_header_path = is_header_path

local function is_tu_path(path)
  return path:match("%.cpp$") or path:match("%.cc$") or path:match("%.cxx$")
      or path:match("%.c$")   or path:match("%.C$")  or path:match("%.mm$")
end
M.is_tu_path = is_tu_path

local function shift_pos(p, n) if p and p.line then p.line = p.line + n end end
local function shift_range(r, n)
  if not r then return end
  shift_pos(r.start, n)
  shift_pos(r["end"], n)
end

local function same_uri(a, b)
  if not a or not b then return false end
  if a == b then return true end
  local ok_a, path_a = pcall(vim.uri_to_fname, a)
  local ok_b, path_b = pcall(vim.uri_to_fname, b)
  return ok_a and ok_b and path_a == path_b
end

-- Drop or clip a range against a preamble boundary. Returns true if fully dropped.
local function clip_to_user(r, n)
  if not r then return false end
  if r["end"].line < n then return true end
  if r.start.line < n then
    r.start.line = n
    r.start.character = 0
  end
  return false
end

-- ====================================================================
-- WorkspaceEdit walker
-- ====================================================================
local function walk_workspace_edit(we, header_uri, n, dir)
  if not we then return 0 end
  local shifted = 0
  local function process_edits(edits)
    if not edits then return edits end
    if dir < 0 then
      local out = {}
      for _, e in ipairs(edits) do
        if e.range and not clip_to_user(e.range, n) then
          shift_range(e.range, dir * n)
          shifted = shifted + 1
          table.insert(out, e)
        elseif not e.range then
          table.insert(out, e)
        end
      end
      return out
    else
      for _, e in ipairs(edits) do
        if e.range then
          shift_range(e.range, dir * n)
          shifted = shifted + 1
        end
      end
      return edits
    end
  end
  if we.changes then
    for uri, edits in pairs(we.changes) do
      if same_uri(uri, header_uri) then we.changes[uri] = process_edits(edits) end
    end
  end
  if we.documentChanges then
    for _, dc in ipairs(we.documentChanges) do
      if dc.textDocument and same_uri(dc.textDocument.uri, header_uri) and dc.edits then
        dc.edits = process_edits(dc.edits)
      end
    end
  end
  return shifted
end

local function shift_workspace_edit_for_states(we, states, dir)
  local shifted = 0
  if not states then return shifted end
  for _, st in pairs(states) do
    if st.active then
      shifted = shifted + walk_workspace_edit(we, st.header_uri, st.preamble_lines, dir)
    end
  end
  return shifted
end

local function shift_code_action_edits_for_states(actions, states)
  local shifted = 0
  if type(actions) ~= "table" then return shifted end
  for _, action in ipairs(actions) do
    if action.edit then
      shifted = shifted + shift_workspace_edit_for_states(action.edit, states, -1)
    end
  end
  return shifted
end

local function shift_code_action_diagnostics(actions, st)
  if type(actions) ~= "table" then return end
  for _, action in ipairs(actions) do
    if action.diagnostics then
      for _, d in ipairs(action.diagnostics) do shift_range(d.range, -st.preamble_lines) end
    end
  end
end

local function remap_workspace_edit_result(result, ctx)
  if result and ctx.all_states then
    shift_workspace_edit_for_states(result, ctx.all_states(), -1)
  end
  return result
end

local function remap_code_action_result(result, ctx, st)
  if result and ctx.all_states then
    shift_code_action_edits_for_states(result, ctx.all_states())
  end
  if result and st then shift_code_action_diagnostics(result, st) end
  return result
end

-- ====================================================================
-- Diagnostics processor (also exposes dropped diags for debug)
-- ====================================================================
M._dropped_diags = {}

local function process_diagnostics(diags, st)
  local kept, dropped = {}, {}
  for _, d in ipairs(diags) do
    if d.range["end"].line < st.preamble_lines then
      table.insert(dropped, d)
    else
      if d.range.start.line < st.preamble_lines then
        d.range.start.line = st.preamble_lines
        d.range.start.character = 0
      end
      shift_range(d.range, -st.preamble_lines)
      if d.relatedInformation then
        local rel = {}
        for _, ri in ipairs(d.relatedInformation) do
          if ri.location and same_uri(ri.location.uri, st.header_uri) then
            if not clip_to_user(ri.location.range, st.preamble_lines) then
              shift_range(ri.location.range, -st.preamble_lines)
              table.insert(rel, ri)
            end
          else
            table.insert(rel, ri)
          end
        end
        d.relatedInformation = rel
      end
      table.insert(kept, d)
    end
  end
  M._dropped_diags[st.bufnr] = dropped
  return kept
end
M.process_diagnostics = process_diagnostics

-- ====================================================================
-- Definition/References family — shifting Locations / LocationLinks
-- ====================================================================
local function shift_locations(result, n, header_uri)
  if not result then return result end
  local function one(loc)
    if loc.uri then
      if same_uri(loc.uri, header_uri) then shift_range(loc.range, n) end
    elseif loc.targetUri then
      if same_uri(loc.targetUri, header_uri) then
        shift_range(loc.targetRange, n)
        shift_range(loc.targetSelectionRange, n)
      end
      shift_range(loc.originSelectionRange, n)
    end
  end
  if result.uri or result.targetUri then
    one(result)
  else
    for _, loc in ipairs(result) do one(loc) end
  end
  return result
end

-- ====================================================================
-- Completion textEdit shifter
-- ====================================================================
local function shift_completion_item(item, n)
  if item.textEdit then
    shift_range(item.textEdit.range, n)
    shift_range(item.textEdit.insert, n)
    shift_range(item.textEdit.replace, n)
  end
  if item.additionalTextEdits then
    for _, te in ipairs(item.additionalTextEdits) do shift_range(te.range, n) end
  end
end

-- ====================================================================
-- Document symbols (recursive, hierarchical or flat)
-- ====================================================================
local function shift_doc_symbols(syms, st)
  if not syms then return syms end
  local out = {}
  for _, s in ipairs(syms) do
    if s.location then
      if same_uri(s.location.uri, st.header_uri) then
        if not clip_to_user(s.location.range, st.preamble_lines) then
          shift_range(s.location.range, -st.preamble_lines)
          table.insert(out, s)
        end
      else
        table.insert(out, s)
      end
    else
      if not clip_to_user(s.range, st.preamble_lines) then
        shift_range(s.range, -st.preamble_lines)
        if s.selectionRange then
          if clip_to_user(s.selectionRange, st.preamble_lines) then
            s.selectionRange = vim.deepcopy(s.range)
          else
            shift_range(s.selectionRange, -st.preamble_lines)
          end
        end
        if s.children then s.children = shift_doc_symbols(s.children, st) end
        table.insert(out, s)
      end
    end
  end
  return out
end

-- ====================================================================
-- FoldingRange — flat ints, NOT a Range
-- ====================================================================
local function shift_folding_ranges(ranges, n)
  local out = {}
  for _, fr in ipairs(ranges) do
    local sl, el = fr.startLine or 0, fr.endLine or 0
    if el >= n then
      if sl < n then
        sl = n
        fr.startCharacter = nil
      end
      fr.startLine = sl - n
      fr.endLine   = el - n
      table.insert(out, fr)
    end
  end
  return out
end

-- ====================================================================
-- Semantic tokens encoder/decoder + delta application
-- ====================================================================
local function decode_full(data)
  local out = {}
  local cl, cc = 0, 0
  for i = 1, #data, 5 do
    local dl, ds = data[i], data[i+1]
    if dl > 0 then cl = cl + dl; cc = ds else cc = cc + ds end
    table.insert(out, { line = cl, col = cc, len = data[i+2], typ = data[i+3], mods = data[i+4] })
  end
  return out
end

local function encode_full(tokens)
  local out = {}
  local pl, pc = 0, 0
  local first = true
  for _, t in ipairs(tokens) do
    local dl, ds
    if first then
      dl, ds = t.line, t.col
      first = false
    else
      dl = t.line - pl
      ds = (dl > 0) and t.col or (t.col - pc)
    end
    out[#out+1] = dl
    out[#out+1] = ds
    out[#out+1] = t.len
    out[#out+1] = t.typ
    out[#out+1] = t.mods
    pl, pc = t.line, t.col
  end
  return out
end

local function shift_semtok_full(server_data, n)
  if not server_data or #server_data == 0 then return {} end
  local toks = decode_full(server_data)
  local kept = {}
  for _, t in ipairs(toks) do
    if t.line >= n then
      kept[#kept+1] = { line = t.line - n, col = t.col, len = t.len, typ = t.typ, mods = t.mods }
    end
  end
  return encode_full(kept)
end
M._test_shift_full = shift_semtok_full

local function apply_semtok_edits(data_server, edits)
  local result = data_server
  local sorted = {}
  for i, e in ipairs(edits) do sorted[i] = e end
  table.sort(sorted, function(a, b) return a.start > b.start end)
  for _, e in ipairs(sorted) do
    local merged = {}
    for i = 1, e.start do merged[#merged+1] = result[i] end
    for _, v in ipairs(e.data or {}) do merged[#merged+1] = v end
    for i = e.start + (e.deleteCount or 0) + 1, #result do merged[#merged+1] = result[i] end
    result = merged
  end
  return result
end
M._test_apply_edits = apply_semtok_edits

M._semtok_states = {}
local function semtok_state(bufnr)
  local s = M._semtok_states[bufnr]
  if not s then s = {}; M._semtok_states[bufnr] = s end
  return s
end
function M.clear_semtok(bufnr) M._semtok_states[bufnr] = nil end

local function semtok_full_response(result, st)
  if not result or not result.data then return result end
  local user = shift_semtok_full(result.data, st.preamble_lines)
  local sem = semtok_state(st.bufnr)
  sem.data_server = result.data
  sem.data_user   = user
  sem.result_id_server = result.resultId
  sem.result_id_user   = ("nsc-%s-%d"):format(tostring(result.resultId or "0"), vim.uv.hrtime())
  return { resultId = sem.result_id_user, data = user }
end

-- ====================================================================
-- TextEdit list with preamble-drop (formatting et al.)
-- ====================================================================
local function process_text_edits(edits, n)
  if not edits then return edits end
  local out = {}
  for _, te in ipairs(edits) do
    if not clip_to_user(te.range, n) then
      shift_range(te.range, -n)
      table.insert(out, te)
    end
  end
  return out
end

-- ====================================================================
-- CallHierarchy / TypeHierarchy items
-- ====================================================================
local function shift_hierarchy_items(items, st)
  if not items then return items end
  for _, it in ipairs(items) do
    if same_uri(it.uri, st.header_uri) then
      shift_range(it.range, -st.preamble_lines)
      shift_range(it.selectionRange, -st.preamble_lines)
    end
  end
  return items
end

-- ====================================================================
-- Outgoing dispatch — mutates request params before they hit the wire
-- ====================================================================
local OUT = {}

local function out_position(params, st) shift_pos(params.position, st.preamble_lines) end
local function out_range(params, st) shift_range(params.range, st.preamble_lines) end

OUT["textDocument/hover"]                = out_position
OUT["textDocument/definition"]           = out_position
OUT["textDocument/declaration"]          = out_position
OUT["textDocument/typeDefinition"]       = out_position
OUT["textDocument/implementation"]       = out_position
OUT["textDocument/references"]           = out_position
OUT["textDocument/documentHighlight"]    = out_position
OUT["textDocument/signatureHelp"]        = out_position
OUT["textDocument/prepareRename"]        = out_position
OUT["textDocument/rename"]               = out_position
OUT["textDocument/prepareCallHierarchy"] = out_position
OUT["textDocument/prepareTypeHierarchy"] = out_position
OUT["textDocument/linkedEditingRange"]   = out_position
OUT["textDocument/onTypeFormatting"]     = out_position
OUT["textDocument/completion"]           = out_position

OUT["textDocument/semanticTokens/range"] = out_range
OUT["textDocument/rangeFormatting"]      = out_range
OUT["textDocument/inlayHint"]            = out_range

OUT["textDocument/codeAction"] = function(params, st)
  shift_range(params.range, st.preamble_lines)
  if params.context and params.context.diagnostics then
    for _, d in ipairs(params.context.diagnostics) do
      shift_range(d.range, st.preamble_lines)
    end
  end
end

OUT["textDocument/selectionRange"] = function(params, st)
  if params.positions then
    for _, p in ipairs(params.positions) do shift_pos(p, st.preamble_lines) end
  end
end

OUT["completionItem/resolve"] = function(params, st)
  shift_completion_item(params, st.preamble_lines)
end

OUT["codeLens/resolve"] = function(params, st)
  shift_range(params.range, st.preamble_lines)
end

OUT["textDocument/semanticTokens/full/delta"] = function(params, st)
  local sem = semtok_state(st.bufnr)
  if sem.result_id_user and params.previousResultId == sem.result_id_user then
    params.previousResultId = sem.result_id_server
  end
end

OUT["callHierarchy/incomingCalls"] = function(params, st)
  if params.item and same_uri(params.item.uri, st.header_uri) then
    shift_range(params.item.range, st.preamble_lines)
    shift_range(params.item.selectionRange, st.preamble_lines)
  end
end
OUT["callHierarchy/outgoingCalls"] = OUT["callHierarchy/incomingCalls"]
OUT["typeHierarchy/supertypes"]    = OUT["callHierarchy/incomingCalls"]
OUT["typeHierarchy/subtypes"]      = OUT["callHierarchy/incomingCalls"]

-- ====================================================================
-- Incoming dispatch — mutates response before user handler
-- ====================================================================
local IN = {}

IN["textDocument/hover"] = function(r, st)
  if r and r.range then shift_range(r.range, -st.preamble_lines) end
  return r
end

local function in_locations(r, st) return shift_locations(r, -st.preamble_lines, st.header_uri) end
IN["textDocument/definition"]     = in_locations
IN["textDocument/declaration"]    = in_locations
IN["textDocument/typeDefinition"] = in_locations
IN["textDocument/implementation"] = in_locations
IN["textDocument/references"]     = in_locations

IN["textDocument/documentHighlight"] = function(r, st)
  if not r then return r end
  for _, h in ipairs(r) do shift_range(h.range, -st.preamble_lines) end
  return r
end

IN["textDocument/semanticTokens/full"] = semtok_full_response
IN["textDocument/semanticTokens/range"] = function(r, st)
  if not r or not r.data then return r end
  return { resultId = r.resultId, data = shift_semtok_full(r.data, st.preamble_lines) }
end

IN["textDocument/semanticTokens/full/delta"] = function(r, st)
  if not r then return r end
  local sem = semtok_state(st.bufnr)
  if r.data then return semtok_full_response(r, st) end
  if r.edits and sem.data_server then
    sem.data_server = apply_semtok_edits(sem.data_server, r.edits)
    sem.data_user   = shift_semtok_full(sem.data_server, st.preamble_lines)
    sem.result_id_server = r.resultId
    sem.result_id_user   = ("nsc-%s-%d"):format(tostring(r.resultId or "0"), vim.uv.hrtime())
    return { resultId = sem.result_id_user, data = sem.data_user }
  end
  return r
end

IN["textDocument/inlayHint"] = function(r, st)
  if not r then return r end
  local out = {}
  for _, h in ipairs(r) do
    if h.position and h.position.line >= st.preamble_lines then
      shift_pos(h.position, -st.preamble_lines)
      if h.textEdits then
        for _, te in ipairs(h.textEdits) do shift_range(te.range, -st.preamble_lines) end
      end
      if type(h.label) == "table" then
        for _, lp in ipairs(h.label) do
          if lp.location and same_uri(lp.location.uri, st.header_uri) then
            shift_range(lp.location.range, -st.preamble_lines)
          end
        end
      end
      table.insert(out, h)
    end
  end
  return out
end

IN["textDocument/completion"] = function(r, st)
  if not r then return r end
  local items = r.items or r
  for _, item in ipairs(items) do shift_completion_item(item, -st.preamble_lines) end
  return r
end

IN["completionItem/resolve"] = function(r, st)
  if r then shift_completion_item(r, -st.preamble_lines) end
  return r
end

IN["textDocument/codeAction"] = function(r, st)
  if not r then return r end
  for _, a in ipairs(r) do
    if a.edit then walk_workspace_edit(a.edit, st.header_uri, st.preamble_lines, -1) end
    if a.diagnostics then
      for _, d in ipairs(a.diagnostics) do shift_range(d.range, -st.preamble_lines) end
    end
  end
  return r
end

IN["textDocument/documentSymbol"] = function(r, st) return shift_doc_symbols(r, st) end
IN["textDocument/foldingRange"]   = function(r, st)
  if not r then return r end
  return shift_folding_ranges(r, st.preamble_lines)
end

IN["textDocument/documentLink"] = function(r, st)
  if not r then return r end
  local out = {}
  for _, dl in ipairs(r) do
    if not clip_to_user(dl.range, st.preamble_lines) then
      shift_range(dl.range, -st.preamble_lines)
      table.insert(out, dl)
    end
  end
  return out
end

IN["textDocument/formatting"]        = function(r, st) return process_text_edits(r, st.preamble_lines) end
IN["textDocument/rangeFormatting"]   = IN["textDocument/formatting"]
IN["textDocument/onTypeFormatting"]  = IN["textDocument/formatting"]
IN["textDocument/willSaveWaitUntil"] = IN["textDocument/formatting"]

IN["textDocument/prepareRename"] = function(r, st)
  if not r then return r end
  if r.range then shift_range(r.range, -st.preamble_lines)
  elseif r.start and r["end"] then shift_range(r, -st.preamble_lines) end
  return r
end

IN["textDocument/rename"] = function(r, st)
  if r then walk_workspace_edit(r, st.header_uri, st.preamble_lines, -1) end
  return r
end

IN["textDocument/codeLens"] = function(r, st)
  if not r then return r end
  local out = {}
  for _, cl in ipairs(r) do
    if not clip_to_user(cl.range, st.preamble_lines) then
      shift_range(cl.range, -st.preamble_lines)
      table.insert(out, cl)
    end
  end
  return out
end
IN["codeLens/resolve"] = function(r, st)
  if r and r.range then shift_range(r.range, -st.preamble_lines) end
  return r
end

local function shift_selection_range_tree(sr, n)
  if not sr then return nil end
  if clip_to_user(sr.range, n) then return nil end
  shift_range(sr.range, -n)
  if sr.parent then sr.parent = shift_selection_range_tree(sr.parent, n) end
  return sr
end
IN["textDocument/selectionRange"] = function(r, st)
  if not r then return r end
  local out = {}
  for _, sr in ipairs(r) do
    local kept = shift_selection_range_tree(sr, st.preamble_lines)
    if kept then table.insert(out, kept) end
  end
  return out
end

IN["textDocument/linkedEditingRange"] = function(r, st)
  if not r or not r.ranges then return r end
  local out = {}
  for _, rng in ipairs(r.ranges) do
    if not clip_to_user(rng, st.preamble_lines) then
      shift_range(rng, -st.preamble_lines)
      table.insert(out, rng)
    end
  end
  r.ranges = out
  return r
end

IN["textDocument/prepareCallHierarchy"] = shift_hierarchy_items
IN["textDocument/prepareTypeHierarchy"] = shift_hierarchy_items
IN["typeHierarchy/supertypes"]          = shift_hierarchy_items
IN["typeHierarchy/subtypes"]            = shift_hierarchy_items

IN["callHierarchy/incomingCalls"] = function(r, st)
  if not r then return r end
  for _, c in ipairs(r) do
    if c.from and same_uri(c.from.uri, st.header_uri) then
      shift_range(c.from.range, -st.preamble_lines)
      shift_range(c.from.selectionRange, -st.preamble_lines)
      if c.fromRanges then
        for _, rng in ipairs(c.fromRanges) do shift_range(rng, -st.preamble_lines) end
      end
    end
  end
  return r
end

IN["callHierarchy/outgoingCalls"] = function(r, st)
  if not r then return r end
  for _, c in ipairs(r) do
    if c.to and same_uri(c.to.uri, st.header_uri) then
      shift_range(c.to.range, -st.preamble_lines)
      shift_range(c.to.selectionRange, -st.preamble_lines)
    end
    if c.fromRanges then
      for _, rng in ipairs(c.fromRanges) do shift_range(rng, -st.preamble_lines) end
    end
  end
  return r
end

-- ====================================================================
-- didOpen / didChange synthesis
-- ====================================================================

local INCLUDE_PAT = "^%s*#%s*include%s*([\"<])([^\">]+)[\">]"

local function header_include_set(bufnr)
  local set = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return set end
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local _, name = l:match(INCLUDE_PAT)
    if name then set[name] = true end
  end
  return set
end

local function dedup_prefix_lines(prefix_lines, header_set)
  local seen, out = {}, {}
  for _, raw in ipairs(prefix_lines) do
    local _, name = raw:match(INCLUDE_PAT)
    if name then
      if not (header_set[name] or seen[name]) then
        seen[name] = true
        table.insert(out, raw)
      end
    else
      table.insert(out, raw)
    end
  end
  return out
end

-- Preamble is gated by __INCLUDE_LEVEL__ so it only fires when clangd is
-- parsing the header as the translation root (standalone view in the editor).
-- When another TU `#include`s this header, level >= 1 and the preamble is
-- silently skipped — preventing redefinition cascades in the includer.
local function build_preamble_text(prefix_lines)
  local body = table.concat(prefix_lines, "\n")
  if #body > 0 then body = body .. "\n" end
  return "#if __INCLUDE_LEVEL__ == 0\n" .. body .. M.MARKER .. "\n#endif\n"
end

function M.synth_didopen(params, st)
  params.textDocument.text = st.preamble_text .. (params.textDocument.text or "")
end

function M.shift_did_change(params, st)
  if not params.contentChanges then return end
  for _, c in ipairs(params.contentChanges) do
    if c.range then
      shift_range(c.range, st.preamble_lines)
    elseif c.text ~= nil then
      c.text = st.preamble_text .. c.text
    end
  end
end

function M.build_state(bufnr, header_uri, header_path, includer)
  local deduped = dedup_prefix_lines(includer.prefix_lines, header_include_set(bufnr))
  local preamble = build_preamble_text(deduped)
  local n = 0
  for _ in preamble:gmatch("\n") do n = n + 1 end
  return {
    bufnr           = bufnr,
    active          = true,
    header_path     = header_path,
    header_uri      = header_uri,
    preamble_text   = preamble,
    preamble_lines  = n,
    includer_tu     = includer.tu_path,
    includer_direct = includer.direct,
    includer_stale  = false,
    user_line_count = vim.api.nvim_buf_line_count(bufnr),
  }
end

-- ====================================================================
-- Server-pushed handler installation
-- ====================================================================
local handlers_installed = false

function M.install_handlers(get_state_for_uri, all_states, on_unattached_diagnostics)
  if handlers_installed then return end
  handlers_installed = true

  local orig_publish = vim.lsp.handlers["textDocument/publishDiagnostics"]
  vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
    if result and result.uri and ctx and ctx.client_id then
      local cli = vim.lsp.get_client_by_id(ctx.client_id)
      if cli and cli.name == "clangd" then
        local path = uri_to_path(result.uri)
        local st = get_state_for_uri(result.uri)
        if st then
          result.diagnostics = process_diagnostics(result.diagnostics or {}, st)
        elseif on_unattached_diagnostics
            and is_header_path(path)
            and graph.is_self_contained_header(path)
            and #(result.diagnostics or {}) > 0 then
          vim.schedule(function()
            on_unattached_diagnostics(cli, path, result.uri)
          end)
        end
        -- Companion's first publishDiagnostics means its PCH is ready.
        -- Fire the callback once so init.lua can re-issue any header that
        -- was analyzed before the PCH was available.
        local vt = M._virtual_tus[path]
        if vt and not vt.pch_ready then
          vt.pch_ready = true
          local cb = M._on_virtual_tu_ready
          if cb then vim.schedule(function() cb(cli, path) end) end
        end
      end
    end
    if orig_publish then return orig_publish(err, result, ctx, config) end
  end

  local orig_apply = vim.lsp.handlers["workspace/applyEdit"]
  vim.lsp.handlers["workspace/applyEdit"] = function(err, result, ctx, config)
    if ctx and ctx.client_id and result and result.edit then
      local cli = vim.lsp.get_client_by_id(ctx.client_id)
      if cli and cli.name == "clangd" then
        shift_workspace_edit_for_states(result.edit, all_states(), -1)
      end
    end
    if orig_apply then return orig_apply(err, result, ctx, config) end
  end

  local orig_show = vim.lsp.handlers["window/showDocument"]
  vim.lsp.handlers["window/showDocument"] = function(err, result, ctx, config)
    if result and result.uri and result.selection then
      local st = get_state_for_uri(result.uri)
      if st then shift_range(result.selection, -st.preamble_lines) end
    end
    if orig_show then return orig_show(err, result, ctx, config) end
  end
end

-- ====================================================================
-- Virtual companion TU open.
-- When a header's companion is found from disk (not yet open in the editor),
-- we open it in clangd via orig_notify so clangd builds its PCH and applies
-- the companion's compile_commands flags to the header analysis.
-- We track virtual opens so the real didOpen from the user is suppressed.
-- ====================================================================

-- tu_path -> { uri, client_self, orig_notify, pch_ready }
-- pch_ready becomes true after the first publishDiagnostics arrives for the
-- companion, which signals clangd has finished its analysis and the PCH is
-- usable.  The on_virtual_tu_ready callback fires exactly once per companion.
M._virtual_tus = {}
M._on_virtual_tu_ready = nil  -- set from init.lua

function M.open_tu_virtually(client_self, orig_notify_fn, tu_path)
  if M._virtual_tus[tu_path] then return end
  local f = io.open(tu_path, "r")
  if not f then return end
  local text = f:read("*a"); f:close()
  local uri = vim.uri_from_fname(tu_path)
  local ext = tu_path:match("%.([^.]+)$") or "cpp"
  local lang = (ext == "c" or ext == "C") and "c" or "cpp"
  orig_notify_fn(client_self, "textDocument/didOpen", {
    textDocument = { uri = uri, languageId = lang, version = 0, text = text },
  })
  M._virtual_tus[tu_path] = {
    uri = uri, client_self = client_self, orig_notify = orig_notify_fn, pch_ready = false,
  }
end

function M.close_tu_virtually(tu_path)
  local vt = M._virtual_tus[tu_path]
  if not vt then return end
  vt.orig_notify(vt.client_self, "textDocument/didClose", { textDocument = { uri = vt.uri } })
  M._virtual_tus[tu_path] = nil
end

-- Returns true and drops the virtual record when the user opens the same TU
-- for real — clangd already has it open, so the caller must skip orig_notify.
function M.promote_virtual_tu(tu_path)
  if not M._virtual_tus[tu_path] then return false end
  M._virtual_tus[tu_path] = nil
  return true
end

-- Track a TU as virtually open without sending didOpen — clangd already has
-- the file open from the user's prior didOpen. Caller must suppress the
-- matching didClose so clangd keeps its PCH alive for active headers.
function M.demote_to_virtual(client_self, orig_notify_fn, tu_path, uri)
  if M._virtual_tus[tu_path] then return end
  M._virtual_tus[tu_path] = {
    uri = uri,
    client_self = client_self,
    orig_notify = orig_notify_fn,
    pch_ready = true,
  }
end

-- ====================================================================
-- Fake didChange — force clangd to push fresh publishDiagnostics after
-- a preamble injection (didClose + didOpen alone may not trigger a push).
-- ====================================================================
function M.send_fake_change(client, bufnr, uri)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local eol   = vim.bo[bufnr].endofline and "\n" or ""
  local ver   = (vim.lsp.util.buf_versions[bufnr] or 0) + 1
  vim.lsp.util.buf_versions[bufnr] = ver
  client:notify("textDocument/didChange", {
    textDocument   = { uri = uri, version = ver },
    contentChanges = { { text = table.concat(lines, "\n") .. eol } },
  })
end

local function find_header_includer(ctx, header_path, header_uri, force)
  if ctx.find_includer then return ctx.find_includer(header_path, header_uri, force) end
  return graph.find_includer(header_path, { force = force })
end

-- ====================================================================
-- Per-client wrapping
-- ====================================================================
function M.wrap_client(client, ctx)
  if client._nsc_wrapped then return end
  client._nsc_wrapped = true

  local orig_request = client.request
  local orig_notify  = client.notify

  client.request = function(self, method, params, handler, bufnr)
    if not ctx.is_enabled() then
      return orig_request(self, method, params, handler, bufnr)
    end

    local function wrap_response(user_handler, mapper)
      return function(err, result, ctx2, config)
        if err == nil and result ~= nil then
          result = mapper(result)
        end
        if user_handler then return user_handler(err, result, ctx2, config) end
      end
    end

    local st
    if bufnr and bufnr ~= 0 then st = ctx.get_state_for_bufnr(bufnr) end
    if not st and params and params.textDocument and params.textDocument.uri then
      st = ctx.get_state_for_uri(params.textDocument.uri)
    end
    if not st or not st.active then
      if method == "textDocument/codeAction" then
        return orig_request(self, method, params, wrap_response(handler, function(result)
          return remap_code_action_result(result, ctx, nil)
        end), bufnr)
      elseif method == "textDocument/rename" then
        return orig_request(self, method, params, wrap_response(handler, function(result)
          return remap_workspace_edit_result(result, ctx)
        end), bufnr)
      end
      return orig_request(self, method, params, handler, bufnr)
    end

    local out_fn = OUT[method]
    if out_fn then
      params = vim.deepcopy(params)
      out_fn(params, st)
    end

    local in_fn = IN[method]
    local user_handler = handler
    local wrapped = user_handler
    if method == "textDocument/codeAction" then
      wrapped = wrap_response(user_handler, function(result)
        return remap_code_action_result(result, ctx, st)
      end)
    elseif method == "textDocument/rename" then
      wrapped = wrap_response(user_handler, function(result)
        return remap_workspace_edit_result(result, ctx)
      end)
    elseif in_fn then
      wrapped = wrap_response(user_handler, function(result)
        return in_fn(result, st)
      end)
    end
    return orig_request(self, method, params, wrapped, bufnr)
  end

  client.notify = function(self, method, params)
    if not ctx.is_enabled() then return orig_notify(self, method, params) end

    if method == "textDocument/didOpen" then
      local td = params and params.textDocument
      if td and td.uri then
        local path = uri_to_path(td.uri)
        if is_header_path(path) then
          if ctx.is_disabled and ctx.is_disabled(td.uri) then
            local st = ctx.get_state_for_uri(td.uri)
            if st and ctx.on_header_detached then ctx.on_header_detached(st) end
            return params and orig_notify(self, method, params)
          end
          local force = ctx.consume_forced and ctx.consume_forced(td.uri) or false
          local diagnostic_retry = ctx.is_diagnostic_self_contained and ctx.is_diagnostic_self_contained(td.uri)
          if not force and not diagnostic_retry and graph.is_self_contained_header(path) then
            local st = ctx.get_state_for_uri(td.uri)
            if st and ctx.on_header_detached then ctx.on_header_detached(st) end
            return params and orig_notify(self, method, params)
          end
          local includer = find_header_includer(ctx, path, td.uri, force or diagnostic_retry)
          if includer then
            local bn = vim.fn.bufnr(path)
            if bn > 0 then
              -- Open the companion TU in clangd before the header so clangd
              -- builds its PCH and applies the companion's compile flags to
              -- the header analysis. Only needed when companion was found
              -- from disk (not already live in the editor).
              if vim.fn.bufnr(includer.tu_path) <= 0 then
                M.open_tu_virtually(self, orig_notify, includer.tu_path)
              end
              local st = M.build_state(bn, td.uri, path, includer)
              ctx.on_header_attached(st)
              params = vim.deepcopy(params)
              M.synth_didopen(params, st)
            end
          end
        elseif is_tu_path(path) and td.text then
          -- If this TU was virtually opened by us, clangd already has it —
          -- skip orig_notify but still observe the live text and notify.
          local already_open = M.promote_virtual_tu(path)
          graph.observe_tu(path, td.text)
          if ctx.on_tu_observed then ctx.on_tu_observed(self, path) end
          if already_open then
            orig_notify(self, "textDocument/didChange", {
              textDocument = { uri = td.uri, version = td.version or 0 },
              contentChanges = { { text = td.text } },
            })
            return
          end
        end
      end
    elseif method == "textDocument/didChange" then
      local td = params and params.textDocument
      if td and td.uri then
        local st = ctx.get_state_for_uri(td.uri)
        if st and st.active then
          params = vim.deepcopy(params)
          M.shift_did_change(params, st)
        end
        local path = uri_to_path(td.uri)
        if is_tu_path(path) then
          local changes = params.contentChanges
          local full_text_change = changes and #changes == 1 and not changes[1].range and type(changes[1].text) == "string"
          if full_text_change then
            graph.observe_tu(path, changes[1].text)
          else
            graph.invalidate(path)
          end
        end
      end
    elseif method == "textDocument/didClose" then
      local td = params and params.textDocument
      if td and td.uri then
        local path = uri_to_path(td.uri)
        if is_tu_path(path) then
          -- If any active header still uses this TU as its includer, keep it
          -- open in clangd virtually — header diagnostics depend on the
          -- companion's PCH, which clangd would drop on didClose.
          local has_user = false
          if ctx.all_states then
            for _, st in pairs(ctx.all_states()) do
              if st.includer_tu == path then has_user = true; break end
            end
          end
          if has_user then
            M.demote_to_virtual(self, orig_notify, path, td.uri)
            return
          end
        else
          local st = ctx.get_state_for_uri(td.uri)
          if st then ctx.on_header_detached(st) end
        end
      end
    end

    return orig_notify(self, method, params)
  end
end

return M
