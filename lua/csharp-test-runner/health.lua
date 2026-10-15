-- Health check module for csharp-test-runner.nvim
-- Provides diagnostics via :checkhealth csharp-test-runner

local M = {}

---Check Neovim and external tools
local function check_environment()
  vim.health.start("Environment")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10+ is required (vim.fs.root, vim.uv)")
  end

  if vim.fn.executable("dotnet") == 0 then
    vim.health.error("`dotnet` not found on PATH", { "Install the .NET SDK and make sure `dotnet` is on PATH" })
    return
  end
  local out = vim.fn.systemlist({ "dotnet", "--list-sdks" })
  if vim.v.shell_error ~= 0 or #out == 0 then
    vim.health.warn("`dotnet --list-sdks` returned nothing")
  else
    vim.health.ok("dotnet SDKs: " .. table.concat(
      vim.tbl_map(function(l)
        return (l:match("^(%S+)"))
      end, out),
      ", "
    ))
  end
end

---Check the C# tree-sitter parser, which finds test methods in buffers
local function check_treesitter()
  vim.health.start("Tree-sitter")
  local ok = pcall(vim.treesitter.language.inspect, "c_sharp")
  if ok then
    vim.health.ok("c_sharp parser is installed")
  else
    vim.health.error("c_sharp parser is missing", { ":TSInstall c_sharp" })
  end
end

---Check setup and configuration
local function check_config()
  vim.health.start("Configuration")
  if vim.fn.exists(":CSTest") == 2 then
    vim.health.ok(":CSTest command is registered")
  else
    vim.health.warn("setup() has not been called", { 'require("csharp-test-runner").setup()' })
  end
  local opts = require("csharp-test-runner.config").options
  if type(opts.test_attributes) ~= "table" or #opts.test_attributes == 0 then
    vim.health.error("test_attributes must be a non-empty list")
  else
    vim.health.ok("test attributes: " .. table.concat(opts.test_attributes, ", "))
  end
  if opts.watch_scope ~= "file" and opts.watch_scope ~= "project" then
    vim.health.error("watch_scope must be 'file' or 'project', got " .. tostring(opts.watch_scope))
  end
  for name, fw in pairs(opts.framework_overrides) do
    if fw ~= "xunit" and fw ~= "mstest" then
      vim.health.error(string.format("framework_overrides[%s] must be 'xunit' or 'mstest'", name))
    end
  end
end

---Check what test counts on production methods need
local function check_coverage()
  vim.health.start("Coverage (test counts on methods)")
  local opts = require("csharp-test-runner.config").options
  if not opts.coverage.enabled then
    vim.health.info("disabled (coverage = { enabled = true } to turn on)")
    return
  end
  vim.health.ok("enabled, " .. opts.coverage.concurrency .. " concurrent reference requests")
  local clients = vim.tbl_filter(function(c)
    return c.supports_method("textDocument/references")
  end, vim.lsp.get_clients({ bufnr = 0 }))
  if #clients == 0 then
    vim.health.warn("no language server with references is attached to this buffer")
  else
    vim.health.ok("references from: " .. table.concat(vim.tbl_map(function(c)
      return c.name
    end, clients), ", "))
  end
  if #vim.lsp.get_clients({ bufnr = 0, name = "roslyn" }) > 0 then
    if _G.roslyn_initialized then
      vim.health.ok("roslyn has finished loading the solution")
    else
      vim.health.warn("roslyn is still loading the solution; counts appear when it finishes")
    end
  end
end

---Check the project of the current buffer
local function check_current_project()
  vim.health.start("Current buffer")
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or not path:match("%.cs$") then
    vim.health.info("open a C# test file to check its project")
    return
  end
  local p, err = require("csharp-test-runner.project").for_file(path)
  if not p then
    vim.health.warn(err or "not a test project")
    return
  end
  vim.health.ok(string.format("%s uses %s", p.name, p.framework))
  local tests = require("csharp-test-runner.locator").tests(0)
  vim.health.info(string.format("%d test method(s) found in this buffer", #tests))
end

M.check = function()
  check_environment()
  check_treesitter()
  check_config()
  check_coverage()
  check_current_project()
end

return M
