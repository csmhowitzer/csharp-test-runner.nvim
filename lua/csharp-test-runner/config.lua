-- Configuration defaults and merging for csharp-test-runner.nvim

local M = {}

---@alias CSTestFramework "xunit"|"mstest"

---@class CSTestIcons
---@field passed string
---@field failed string
---@field skipped string
---@field running string

---@class CSTestKeymaps
---@field smart string|false
---@field nearest string|false
---@field file string|false
---@field project string|false
---@field all string|false
---@field output string|false
---@field watch string|false
---@field stop string|false
---@field covering string|false
---@field coverage string|false

---@class CSTestCoverageConfig
---@field enabled boolean
---@field concurrency integer Reference requests sent at once

---@class CSTestConfig
---@field build boolean Build before running (false adds --no-build)
---@field icons CSTestIcons Glyphs used in virtual text
---@field show_duration boolean Show test durations next to the result icon
---@field diagnostics boolean Publish failed tests as vim.diagnostic errors
---@field quickfix { enabled: boolean, open: boolean } Failures to quickfix, auto-open when there are failures
---@field watch_scope "file"|"project" What a watched buffer runs on save
---@field test_attributes string[] Attribute names that mark a test method
---@field framework_overrides table<string, CSTestFramework> csproj filename -> framework, when detection is wrong
---@field extra_args { xunit: string[], mstest: string[] } Extra arguments appended to each runner command
---@field float { border: string, width: number, height: number } Failure output window (fractions of the editor)
---@field coverage CSTestCoverageConfig Test counts on production methods (uses LSP references)
---@field keymaps CSTestKeymaps|false Opt-in keymaps (false disables all)
---@field debug boolean Notify the command line of every run

---@type CSTestConfig
M.defaults = {
  build = true,
  icons = {
    passed = "✓",
    failed = "✗",
    skipped = "○",
    running = "⋯",
  },
  show_duration = true,
  diagnostics = true,
  quickfix = {
    enabled = true,
    open = true,
  },
  watch_scope = "file",
  test_attributes = { "Fact", "Theory", "TestMethod", "DataTestMethod" },
  framework_overrides = {},
  extra_args = {
    xunit = {},
    mstest = {},
  },
  float = {
    border = "rounded",
    width = 0.8,
    height = 0.6,
  },
  coverage = {
    enabled = false,
    concurrency = 4,
  },
  keymaps = false,
  debug = false,
}

---@type CSTestConfig
M.options = vim.deepcopy(M.defaults)

---Default keymaps applied when the user passes `keymaps = true`
---@type CSTestKeymaps
M.default_keymaps = {
  smart = "<leader>ty",
  nearest = "<leader>tn",
  file = "<leader>tf",
  project = "<leader>tp",
  all = "<leader>ta",
  output = "<leader>to",
  watch = "<leader>tw",
  stop = "<leader>ts",
  covering = "<leader>tl",
  coverage = "<leader>tc",
}

---Merges user options over the defaults
---@param opts table|nil
---@return CSTestConfig
function M.setup(opts)
  opts = opts or {}
  if opts.keymaps == true then
    opts.keymaps = vim.deepcopy(M.default_keymaps)
  elseif type(opts.keymaps) == "table" then
    opts.keymaps = vim.tbl_extend("force", vim.deepcopy(M.default_keymaps), opts.keymaps)
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- lists should replace, not merge by index
  if opts.test_attributes then
    M.options.test_attributes = opts.test_attributes
  end
  return M.options
end

return M
