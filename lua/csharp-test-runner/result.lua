-- Shared result model and helpers used by every adapter

local M = {}

---@alias CSTestStatus "passed"|"failed"|"skipped"

---One executed test case. Theories / DataRows produce one result per case.
---@class CSTestResult
---@field class string Fully qualified class name (nested classes joined with "+")
---@field method string Method name without arguments
---@field name string Display name (may include case arguments)
---@field status CSTestStatus
---@field duration number Milliseconds
---@field file string|nil Source file, when the report or stack trace provides it
---@field line integer|nil 1-based line, when known
---@field message string|nil Failure or skip message
---@field trace string|nil Stack trace
---@field stdout string|nil Captured output

---Key used to match results with methods found in a buffer
---@param class string
---@param method string
---@return string
function M.key(class, method)
  return class .. "::" .. method
end

---@class CSTestFrame
---@field text string The frame text ("at Ns.Class.Method(...)")
---@field file string|nil
---@field line integer|nil

---Splits a .NET stack trace into frames, extracting "in <file>:line N"
---@param trace string|nil
---@return CSTestFrame[]
function M.parse_trace(trace)
  local frames = {}
  if not trace or trace == "" then
    return frames
  end
  for raw in vim.gsplit(trace, "\r?\n") do
    local line = vim.trim(raw)
    if line ~= "" then
      local text, file, lnum = line:match("^(.-)%s+in%s+(.+):line%s+(%d+)$")
      if text then
        table.insert(frames, { text = text, file = file, line = tonumber(lnum) })
      else
        table.insert(frames, { text = line })
      end
    end
  end
  return frames
end

---Finds the stack frame that belongs to the test method itself, which points at the failing line
---@param r CSTestResult
---@return CSTestFrame|nil
function M.test_frame(r)
  local frames = M.parse_trace(r.trace)
  local needle = (r.class:gsub("%+", ".")) .. "." .. r.method .. "("
  for _, f in ipairs(frames) do
    if f.file and f.text:find(needle, 1, true) then
      return f
    end
  end
  -- inherited tests: the frame names the base class (e.g. "Ns.BaseTests`1.Method("), not the class that ran it
  local method_needle = "." .. r.method .. "("
  for _, f in ipairs(frames) do
    if f.file and f.text:find(method_needle, 1, true) then
      return f
    end
  end
  return nil
end

---Best location to jump to for a result: the failing line if known, else the report location
---@param r CSTestResult
---@return string|nil file
---@return integer|nil line
function M.location(r)
  local f = M.test_frame(r)
  if f and vim.fn.filereadable(f.file) == 1 then
    return f.file, f.line
  end
  if r.file then
    return r.file, r.line
  end
  if f then
    return f.file, f.line
  end
  return nil, nil
end

---@class CSTestAggregate
---@field status CSTestStatus|"running"
---@field duration number
---@field total integer
---@field failed integer
---@field cases CSTestResult[]

---Combines every case of a method into one status: any failure fails the method
---@param cases CSTestResult[]
---@return CSTestAggregate
function M.aggregate(cases)
  local agg = { status = "skipped", duration = 0, total = #cases, failed = 0, cases = cases }
  local passed = 0
  for _, c in ipairs(cases) do
    agg.duration = agg.duration + (c.duration or 0)
    if c.status == "failed" then
      agg.failed = agg.failed + 1
    elseif c.status == "passed" then
      passed = passed + 1
    end
  end
  if agg.failed > 0 then
    agg.status = "failed"
  elseif passed > 0 then
    agg.status = "passed"
  end
  return agg
end

---Formats milliseconds for display
---@param ms number
---@return string
function M.format_duration(ms)
  if ms >= 1000 then
    return string.format("%.2fs", ms / 1000)
  end
  return string.format("%dms", math.floor(ms + 0.5))
end

return M
