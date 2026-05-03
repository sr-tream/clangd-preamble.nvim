if vim.g.loaded_clangd_preamble then return end
vim.g.loaded_clangd_preamble = true

require("clangd-preamble")
