local clangd = vim.env.CLANGD or "clangd"
if vim.fn.executable(clangd) ~= 1 then
  error(("clangd executable not found: %s"):format(clangd))
end

local repo_root = vim.fn.getcwd()
package.path = table.concat({
  repo_root .. "/lua/?.lua",
  repo_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local root = "/tmp/clangd-preamble-selector-test"
if vim.fn.isdirectory(root) ~= 1 then
  error("fixture not found: " .. root)
end

local graph = require("clangd-preamble.graph")
local preamble = require("clangd-preamble")

local consumer_a = root .. "/consumer_a.cpp"
local consumer_b = root .. "/consumer_b.cpp"
local widget_h = root .. "/include/shared/Widget.h"

local function assert_true(value, label)
  if not value then error(label) end
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
  end
end

local function assert_contains(text, needle, label)
  if not text or not text:find(needle, 1, true) then
    error(("%s: missing %q in %s"):format(label, needle, tostring(text)))
  end
end

local function candidate_by_tu(candidates, tu)
  for _, c in ipairs(candidates) do
    if c.tu_path == tu then return c end
  end
  return nil
end

local function reset_graph()
  graph.tu_includes = {}
  graph.header_users = {}
  graph.tu_mtime = {}
  graph._path_cache = {}
end

local function state_for(bufnr)
  return preamble._buf_state[bufnr]
end

local function state_text(bufnr)
  local st = state_for(bufnr)
  return st and st.preamble_text or nil
end

local function wait_for(label, fn)
  assert_true(vim.wait(10000, fn, 20), label)
end

reset_graph()
vim.cmd("cd " .. vim.fn.fnameescape(root))

local scanned = graph.scan_project_for_includers(root)
assert_eq(scanned, 2, "fixture TU scan count")

local candidates = graph.list_includers(widget_h, { force = true })
assert_eq(#candidates, 2, "candidate count")

local a_candidate = candidate_by_tu(candidates, consumer_a)
local b_candidate = candidate_by_tu(candidates, consumer_b)
assert_true(a_candidate, "consumer_a candidate")
assert_true(b_candidate, "consumer_b candidate")
assert_eq(#a_candidate.prefix_lines, 1, "consumer_a preamble length")
assert_eq(a_candidate.prefix_lines[1], '#include "preamble_a.h"', "consumer_a preamble line")
assert_eq(#b_candidate.prefix_lines, 2, "consumer_b preamble length")
assert_eq(b_candidate.prefix_lines[1], '#include "config_b.h"', "consumer_b config line")
assert_eq(b_candidate.prefix_lines[2], '#include "preamble_b.h"', "consumer_b preamble line")
assert_eq(graph.find_includer(widget_h, { force = true }).tu_path, consumer_a, "auto includer")
assert_eq(graph.find_includer(widget_h, { force = true, preferred_tu = consumer_b }).tu_path, consumer_b, "preferred includer")

graph.observe_tu_from_disk(consumer_a)
graph.observe_tu_from_disk(consumer_b)
assert_eq(graph.find_recent_includer(widget_h, { force = true }).tu_path, consumer_b, "recent includer")

local function open_buffer(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "cpp"
  return vim.api.nvim_get_current_buf()
end

local a_buf = open_buffer(consumer_a)
local client_id = vim.lsp.start({
  name = "clangd",
  cmd = { clangd, "--background-index=false", "--clang-tidy=false", "--log=error" },
  root_dir = root,
  on_attach = function(client, bufnr)
    preamble.attach(client, bufnr)
  end,
})
assert_true(client_id, "failed to start clangd")

wait_for("clangd did not initialize", function()
  local client = vim.lsp.get_client_by_id(client_id)
  return client and client.initialized
end)

local b_buf = open_buffer(consumer_b)
vim.lsp.buf_attach_client(b_buf, client_id)

wait_for("consumer_b was not observed", function()
  return graph.tu_includes[consumer_b] ~= nil
end)

local widget_buf = open_buffer(widget_h)
vim.lsp.buf_attach_client(widget_buf, client_id)

wait_for("Widget.h did not get auto preamble", function()
  return preamble.includer_for(widget_buf) == consumer_a
end)
assert_contains(state_text(widget_buf), '#include "preamble_a.h"', "auto preamble")

assert_true(preamble.use_includer(widget_buf, consumer_b), "fixed includer reissue")
wait_for("Widget.h did not switch to fixed consumer_b", function()
  return preamble.includer_for(widget_buf) == consumer_b
end)
assert_contains(state_text(widget_buf), '#include "config_b.h"', "fixed config preamble")
assert_contains(state_text(widget_buf), '#include "preamble_b.h"', "fixed b preamble")

assert_true(preamble.use_recent_includer(widget_buf), "recent includer reissue")
wait_for("Widget.h did not switch to recent consumer_b", function()
  return preamble.includer_for(widget_buf) == consumer_b
end)

vim.cmd("buffer " .. a_buf)
wait_for("recent mode did not switch to consumer_a", function()
  return preamble.includer_for(widget_buf) == consumer_a
end)
assert_contains(state_text(widget_buf), '#include "preamble_a.h"', "recent a preamble")

vim.cmd("buffer " .. b_buf)
wait_for("recent mode did not switch to consumer_b", function()
  return preamble.includer_for(widget_buf) == consumer_b
end)
assert_contains(state_text(widget_buf), '#include "preamble_b.h"', "recent b preamble")

vim.cmd("buffer " .. widget_buf)
vim.cmd("NoSelfContainedDisableBuf")
assert_true(preamble.is_disabled(widget_buf), "header was not marked disabled")
assert_eq(preamble.includer_for(widget_buf), nil, "disabled header still has state")

local client = vim.lsp.get_client_by_id(client_id)
assert_true(client, "missing clangd client")
client:notify("textDocument/didOpen", {
  textDocument = {
    uri = vim.uri_from_fname(widget_h),
    languageId = "cpp",
    version = vim.lsp.util.buf_versions[widget_buf] or 0,
    text = table.concat(vim.api.nvim_buf_get_lines(widget_buf, 0, -1, false), "\n") .. "\n",
  },
})
vim.wait(300, function() return false end, 20)
assert_eq(preamble.includer_for(widget_buf), nil, "disabled header was reinjected after didOpen")

vim.cmd("NoSelfContainedEnableBuf")
wait_for("enabled header did not regain preamble", function()
  return preamble.includer_for(widget_buf) == consumer_a
end)
assert_true(not preamble.is_disabled(widget_buf), "header stayed disabled after enable")

client:stop(true)

print("selector fixture preamble regression passed")
