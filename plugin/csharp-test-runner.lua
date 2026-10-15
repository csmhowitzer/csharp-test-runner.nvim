-- csharp-test-runner.nvim plugin entry point
-- This file is automatically loaded by Neovim when the plugin is installed

-- Prevent loading the plugin multiple times
if vim.g.loaded_csharp_test_runner then
  return
end
vim.g.loaded_csharp_test_runner = 1

-- The plugin will be set up when the user calls require("csharp-test-runner").setup()
-- This allows for user configuration before initialization
