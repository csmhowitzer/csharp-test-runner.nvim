-- Test project discovery and framework detection

local config = require("csharp-test-runner.config")

local M = {}

---@class CSTestProject
---@field csproj string Absolute path to the .csproj
---@field dir string Directory containing the .csproj
---@field name string Project file name without extension
---@field framework CSTestFramework

---@param path string
---@return string|nil
local function read(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

---Detects the test framework from a project file's contents
---@param text string
---@return CSTestFramework|nil
function M.detect_framework(text)
  if text:find('Include="xunit%.v3[%."]') then
    return "xunit"
  end
  if text:find('Include="MSTest[%."]') or text:find('Sdk="MSTest%.Sdk') then
    return "mstest"
  end
  return nil
end

---Loads a project, returning nil when it is not a supported test project
---@param csproj string
---@return CSTestProject|nil
---@return string|nil err
function M.load(csproj)
  csproj = vim.fs.normalize(vim.fn.fnamemodify(csproj, ":p"))
  local name = vim.fn.fnamemodify(csproj, ":t:r")
  local framework = config.options.framework_overrides[vim.fn.fnamemodify(csproj, ":t")]
  if not framework then
    local text = read(csproj)
    if not text then
      return nil, "cannot read " .. csproj
    end
    framework = M.detect_framework(text)
  end
  if not framework then
    return nil, name .. " does not reference xunit.v3 or MSTest"
  end
  return {
    csproj = csproj,
    dir = vim.fs.dirname(csproj),
    name = name,
    framework = framework,
  }
end

---Finds the test project that owns a file
---@param path string
---@return CSTestProject|nil
---@return string|nil err
function M.for_file(path)
  if path == "" then
    return nil, "buffer has no file"
  end
  local found = vim.fs.find(function(name)
    return name:match("%.csproj$") ~= nil
  end, { upward = true, path = vim.fs.dirname(vim.fs.normalize(path)), type = "file", limit = 1 })
  if not found[1] then
    return nil, "no .csproj found above " .. path
  end
  return M.load(found[1])
end

---Finds the solution root (directory with a .sln/.slnx), falling back to the git root
---@param path string
---@return string|nil
function M.solution_root(path)
  local dir = vim.fs.dirname(vim.fs.normalize(path))
  return vim.fs.root(dir, function(name)
    return name:match("%.slnx?$") ~= nil
  end) or vim.fs.root(dir, ".git")
end

---Lists every supported test project under a directory
---@param root string
---@return CSTestProject[]
function M.all_under(root)
  local projects = {}
  local files = vim.fs.find(function(name, dir)
    return name:match("%.csproj$") ~= nil and not dir:match("[/\\]bin[/\\]") and not dir:match("[/\\]obj[/\\]")
  end, { path = root, type = "file", limit = math.huge })
  table.sort(files)
  for _, f in ipairs(files) do
    local p = M.load(f)
    if p then
      table.insert(projects, p)
    end
  end
  return projects
end

---Whether a file belongs to the given project
---@param project CSTestProject
---@param path string
---@return boolean
function M.contains(project, path)
  path = vim.fs.normalize(path)
  return path:sub(1, #project.dir + 1) == project.dir .. "/"
end

return M
