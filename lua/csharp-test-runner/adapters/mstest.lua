-- MSTest adapter
-- MSTest (VSTest) projects run through `dotnet test` with the built-in TRX logger. TRX has no source locations;
-- failures are located through their stack trace and passing tests are matched to open buffers by name.

local M = {}

M.name = "mstest"
M.report_ext = ".trx"

---Escapes a value for use in a VSTest --filter expression
---@param value string
---@return string
local function filter_escape(value)
  return (value:gsub("[\\%(%)&|=!~]", "\\%0"))
end

---Builds the command for a run
---@param csproj string Path to the test project
---@param selection CSTestSelection
---@param report string Path the report should be written to
---@param opts { build: boolean, extra_args: string[] }
---@return string[]
function M.command(csproj, selection, report, opts)
  local cmd = { "dotnet", "test", csproj, "--logger", "trx;LogFileName=" .. report }
  if not opts.build then
    table.insert(cmd, "--no-build")
  end
  local filter
  if selection.kind == "method" then
    -- FullyQualifiedName excludes DataRow arguments, so this matches every row of the method
    filter = "FullyQualifiedName=" .. filter_escape(selection.class .. "." .. selection.method)
  elseif selection.kind == "classes" then
    local parts = {}
    for _, class in ipairs(selection.classes) do
      table.insert(parts, "ClassName=" .. filter_escape(class))
    end
    filter = table.concat(parts, "|")
  end
  if filter then
    vim.list_extend(cmd, { "--filter", filter })
  end
  vim.list_extend(cmd, opts.extra_args or {})
  return cmd
end

local entities = { lt = "<", gt = ">", quot = '"', apos = "'" }

---Decodes XML entities (including numeric ones)
---@param s string|nil
---@return string|nil
function M.decode(s)
  if not s then
    return nil
  end
  s = s:gsub("&#[xX](%x+);", function(h)
    return vim.fn.nr2char(tonumber(h, 16))
  end)
  s = s:gsub("&#(%d+);", function(d)
    return vim.fn.nr2char(tonumber(d))
  end)
  s = s:gsub("&(%a+);", function(name)
    if name == "amp" then
      return nil -- handled last so "&amp;lt;" stays "&lt;"
    end
    return entities[name]
  end)
  s = s:gsub("&amp;", "&")
  return s
end

---Parses the attributes of a tag into a table
---@param attrs string
---@return table<string, string>
local function parse_attrs(attrs)
  local t = {}
  for k, v in attrs:gmatch('([%w_:]+)="([^"]*)"') do
    t[k] = M.decode(v)
  end
  return t
end

---Converts a TRX duration (hh:mm:ss.fffffff) to milliseconds
---@param d string|nil
---@return number
function M.parse_duration(d)
  if not d then
    return 0
  end
  local h, m, s = d:match("^(%d+):(%d+):([%d%.]+)$")
  if not h then
    return 0
  end
  return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * 1000
end

---@param body string
---@param tag string
---@return string|nil
local function inner(body, tag)
  local v = body:match("<" .. tag .. ">(.-)</" .. tag .. ">")
  return M.decode(v)
end

local outcome_map = {
  Passed = "passed",
  Failed = "failed",
  Error = "failed",
  Timeout = "failed",
  Aborted = "failed",
  NotExecuted = "skipped",
  Inconclusive = "skipped",
}

---Parses a TRX report into results
---@param text string
---@return CSTestResult[]|nil results
---@return string|nil err
function M.parse(text)
  if not text:find("<TestRun", 1, true) then
    return nil, "not a TRX report"
  end

  -- test id -> { class, method }
  local defs = {}
  for attrs, body in text:gmatch("<UnitTest%s([^>]*)>(.-)</UnitTest>") do
    local id = parse_attrs(attrs).id
    local tm = body:match("<TestMethod%s([^>]*)/?>")
    if id and tm then
      local a = parse_attrs(tm)
      defs[id] = { class = a.className, method = a.name }
    end
  end

  local results = {}
  local pos = 1
  while true do
    local s, e, attrs, selfclose = text:find("<UnitTestResult%s([^>]-)(/?)>", pos)
    if not s then
      break
    end
    local body = ""
    if selfclose == "" then
      local cs, ce = text:find("</UnitTestResult>", e + 1, true)
      if cs then
        body = text:sub(e + 1, cs - 1)
        e = ce
      end
    end
    pos = e + 1

    local a = parse_attrs(attrs)
    local def = defs[a.testId]
    if def and def.class and def.method then
      table.insert(results, {
        class = def.class,
        method = def.method,
        name = a.testName or def.method,
        status = outcome_map[a.outcome] or "skipped",
        duration = M.parse_duration(a.duration),
        message = inner(body, "Message"),
        trace = inner(body, "StackTrace"),
        stdout = inner(body, "StdOut"),
      })
    end
  end
  return results, nil
end

return M
