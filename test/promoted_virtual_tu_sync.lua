local repo_root = vim.fn.getcwd()
package.path = table.concat({
  repo_root .. "/lua/?.lua",
  repo_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local lsp = require("clangd-preamble.lsp")

local root = vim.fn.tempname() .. "-clangd-preamble-promote"
vim.fn.mkdir(root, "p")

local function write(path, lines)
  vim.fn.writefile(lines, path)
end

local dep_h = root .. "/dep.h"
local use_h = root .. "/use.h"
local use_cpp = root .. "/use.cpp"

write(dep_h, {
  "#pragma once",
  "struct Dep {};",
})

write(use_h, {
  "#pragma once",
  "inline Dep make_dep();",
})

write(use_cpp, {
  "#include \"dep.h\"",
  "#include \"use.h\"",
  "Dep make_dep() { return {}; }",
})

local notifications = {}
local client = {
  name = "clangd",
  notify = function(_, method, params)
    table.insert(notifications, { method = method, params = vim.deepcopy(params) })
    return true
  end,
  request = function() return true, 1 end,
}

local states = {}
local ctx = {
  is_enabled = function() return true end,
  get_state_for_uri = function(uri)
    for _, st in pairs(states) do
      if st.header_uri == uri then return st end
    end
  end,
  get_state_for_bufnr = function(bufnr) return states[bufnr] end,
  all_states = function() return states end,
  on_header_attached = function(st) states[st.bufnr] = st end,
  on_header_detached = function(st) states[st.bufnr] = nil end,
  on_tu_observed = function() end,
}

lsp.wrap_client(client, ctx)

vim.cmd("edit " .. vim.fn.fnameescape(use_h))
vim.bo.filetype = "cpp"
local use_buf = vim.api.nvim_get_current_buf()
client:notify("textDocument/didOpen", {
  textDocument = {
    uri = vim.uri_from_fname(use_h),
    languageId = "cpp",
    version = 0,
    text = table.concat(vim.api.nvim_buf_get_lines(use_buf, 0, -1, false), "\n") .. "\n",
  },
})

local dirty_text = table.concat({
  "#include \"dep.h\"",
  "#include \"use.h\"",
  "Dep make_dep() { Dep d; return d; }",
  "",
}, "\n")

client:notify("textDocument/didOpen", {
  textDocument = {
    uri = vim.uri_from_fname(use_cpp),
    languageId = "cpp",
    version = 7,
    text = dirty_text,
  },
})

local saw_virtual_open = false
local saw_dirty_change = false
for _, n in ipairs(notifications) do
  if n.method == "textDocument/didOpen" and n.params.textDocument.uri == vim.uri_from_fname(use_cpp) then
    saw_virtual_open = true
  end
  if n.method == "textDocument/didChange" and n.params.textDocument.uri == vim.uri_from_fname(use_cpp) then
    saw_dirty_change = n.params.contentChanges[1].text == dirty_text
  end
end

if not saw_virtual_open then error("virtual companion didOpen was not sent") end
if not saw_dirty_change then error("promoted virtual TU did not sync editor text via didChange") end

vim.fn.delete(root, "rf")
print("promoted virtual TU sync regression passed")
