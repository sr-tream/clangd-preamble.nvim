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

local root = vim.fn.tempname() .. "-clangd-preamble"
vim.fn.mkdir(root, "p")

local function write(path, lines)
  vim.fn.writefile(lines, path)
end

local widget_h = root .. "/widget.h"
local use_h = root .. "/use.h"
local main_cpp = root .. "/main.cpp"

write(widget_h, {
  "#pragma once",
  "",
  "struct Widget {",
  "  int value;",
  "};",
})

write(use_h, {
  "#pragma once",
  "",
  "inline int get_value(Widget* w) {",
  "  return w->value;",
  "}",
})

write(main_cpp, {
  "#include \"widget.h\"",
  "#include \"use.h\"",
  "",
  "void touch() {",
  "  Widget w;",
  "  w.value = 1;",
  "  (void)get_value(&w);",
  "}",
})

write(root .. "/compile_commands.json", {
  "[",
  ('  {"directory": %q, "command": "clang++ -std=c++17 -I. -c main.cpp", "file": %q}'):format(root, main_cpp),
  "]",
})

local function assert_true(value, label)
  if not value then error(label) end
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
  end
end

local function open_buffer(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "cpp"
  return vim.api.nvim_get_current_buf()
end

vim.cmd("cd " .. vim.fn.fnameescape(root))
local preamble = require("clangd-preamble")

open_buffer(main_cpp)
local client_id = vim.lsp.start({
  name = "clangd",
  cmd = { clangd, "--background-index=false", "--clang-tidy=false", "--log=error" },
  root_dir = root,
  on_attach = function(client, bufnr)
    preamble.attach(client, bufnr)
  end,
})
assert_true(client_id, "failed to start clangd")

assert_true(vim.wait(10000, function()
  local client = vim.lsp.get_client_by_id(client_id)
  return client and client.initialized
end, 20), "clangd did not initialize")

local client = vim.lsp.get_client_by_id(client_id)
assert_true(client, "missing clangd client")

local function did_open(path, bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  client:notify("textDocument/didOpen", {
    textDocument = {
      uri = vim.uri_from_fname(path),
      languageId = "cpp",
      version = vim.lsp.util.buf_versions[bufnr] or 0,
      text = table.concat(lines, "\n") .. "\n",
    },
  })
end

-- use.h relies on widget.h from main.cpp's include prefix. The plugin injects
-- #include "widget.h" into use.h's synthetic standalone preamble.
local use_buf = open_buffer(use_h)
did_open(use_h, use_buf)
assert_true(vim.wait(3000, function()
  return preamble.includer_for(use_buf) == main_cpp
end, 20), "use.h did not get a synthetic preamble")

local widget_buf = open_buffer(widget_h)
did_open(widget_h, widget_buf)

vim.wait(1000, function() return false end, 20)

local rename = client:request_sync("textDocument/rename", {
  textDocument = { uri = vim.uri_from_fname(widget_h) },
  position = { line = 3, character = 7 },
  newName = "renamed_value",
}, 10000, widget_buf)

assert_true(rename, "rename request timed out")
assert_true(not rename.err, "rename returned error: " .. vim.inspect(rename.err))
local result = rename.result
assert_true(result and result.changes, "rename returned no WorkspaceEdit changes")

local widget_uri = vim.uri_from_fname(widget_h)
local use_uri = vim.uri_from_fname(use_h)
local main_uri = vim.uri_from_fname(main_cpp)

assert_true(result.changes[widget_uri], "widget.h declaration edit missing")
assert_true(result.changes[use_uri], "use.h reference edit missing")
assert_true(result.changes[main_uri], "main.cpp reference edit missing")

-- These are user-buffer coordinates. Without active-header remapping, use.h's
-- edit is shifted down by the synthetic preamble and targets the wrong line.
assert_eq(result.changes[widget_uri][1].range.start.line, 3, "widget.h field declaration line")
assert_eq(result.changes[use_uri][1].range.start.line, 3, "use.h field reference line")
assert_eq(result.changes[main_uri][1].range.start.line, 5, "main.cpp field reference line")

client:stop(true)
if vim.env.CLANGD_PREAMBLE_KEEP_TEST_ROOT ~= "1" then
  vim.fn.delete(root, "rf")
end

print("real clangd rename preamble regression passed")
