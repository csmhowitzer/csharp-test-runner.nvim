-- Minimal init for testing csharp-test-runner.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"

local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local lazy = vim.fn.stdpath("data") .. "/lazy"

vim.opt.runtimepath:append(plugin_dir)
-- LUA_PATH (see HOWTOPLUGIN.md) replaces the default search path, so make the plugin root and lua/ explicit
package.path = table.concat({ plugin_dir .. "/?.lua", plugin_dir .. "/lua/?.lua", plugin_dir .. "/lua/?/init.lua", package.path }, ";")
vim.opt.runtimepath:append(lazy .. "/plenary.nvim")
-- provides the c_sharp parser
vim.opt.runtimepath:append(lazy .. "/nvim-treesitter")

vim.cmd("runtime plugin/plenary.vim")

local ok = pcall(require, "plenary")
if not ok then
  error("plenary.nvim is required for testing")
end
