-- xUnit v3 adapter
-- xUnit v3 test projects are Microsoft.Testing.Platform executables, which the .NET 10 SDK will not run through
-- `dotnet test` in VSTest mode, so they are launched with `dotnet run` and report through the in-process
-- runner's CTRF output. CTRF includes the source file and line of every test.

local M = {}

M.name = "xunit"
M.report_ext = ".json"

---@class CSTestSelection
---@field kind "project"|"classes"|"method"|"methods"
---@field classes string[]|nil Fully qualified class names (kind = "classes")
---@field class string|nil (kind = "method")
---@field method string|nil (kind = "method")
---@field methods { class: string, method: string }[]|nil (kind = "methods")

---Builds the command for a run
---@param csproj string Path to the test project
---@param selection CSTestSelection
---@param report string Path the report should be written to
---@param opts { build: boolean, extra_args: string[] }
---@return string[]
function M.command(csproj, selection, report, opts)
  local cmd = { "dotnet", "run", "--project", csproj }
  if not opts.build then
    table.insert(cmd, "--no-build")
  end
  vim.list_extend(cmd, { "--", "-noColor", "-result-ctrf", report })
  if selection.kind == "method" then
    vim.list_extend(cmd, { "-method", selection.class .. "." .. selection.method })
  elseif selection.kind == "methods" then
    for _, m in ipairs(selection.methods) do
      vim.list_extend(cmd, { "-method", m.class .. "." .. m.method })
    end
  elseif selection.kind == "classes" then
    for _, class in ipairs(selection.classes) do
      vim.list_extend(cmd, { "-class", class })
    end
  end
  vim.list_extend(cmd, opts.extra_args or {})
  return cmd
end

local status_map = {
  passed = "passed",
  failed = "failed",
  skipped = "skipped",
  pending = "skipped",
  other = "skipped",
}

---Parses a CTRF report into results
---@param text string
---@return CSTestResult[]|nil results
---@return string|nil err
function M.parse(text)
  local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" or type(decoded.results) ~= "table" then
    return nil, "could not decode CTRF report"
  end
  local results = {}
  for _, t in ipairs(decoded.results.tests or {}) do
    local extra = t.extra or {}
    local class, method = extra.type, extra.method
    if not (class and method) then
      -- fall back to splitting the display name: Ns.Class.Method(args)
      local base = (t.name or ""):gsub("%b()$", "")
      class, method = base:match("^(.*)%.([^%.]+)$")
    end
    if class and method then
      local stdout = t.stdout
      if type(stdout) == "table" then
        stdout = table.concat(stdout, "\n")
      end
      table.insert(results, {
        class = class,
        method = method,
        name = t.name or (class .. "." .. method),
        status = status_map[t.status] or "skipped",
        duration = tonumber(t.duration) or 0,
        file = t.filePath,
        line = tonumber(t.line),
        message = t.message,
        trace = t.trace,
        stdout = stdout,
      })
    end
  end
  return results, nil
end

return M
