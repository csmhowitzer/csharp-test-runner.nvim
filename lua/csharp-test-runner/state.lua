-- Result store shared by the runner and the UI

local result = require("csharp-test-runner.result")

local M = {}

---Latest cases for each test method, keyed by result.key(class, method)
---@type table<string, CSTestResult[]>
M.results = {}

---Methods currently being run
---@type table<string, boolean>
M.running = {}

---Results of the most recent run (all projects), used for the quickfix list and summary output
---@type CSTestResult[]
M.last_run = {}

---Marks methods as running
---@param keys string[]
function M.mark_running(keys)
  for _, k in ipairs(keys) do
    M.running[k] = true
  end
end

---Stores results from one project, replacing every method they cover
---@param results CSTestResult[]
---@return table<string, boolean> produced Keys of the methods that got results
function M.store(results)
  local produced = {}
  for _, r in ipairs(results) do
    local k = result.key(r.class, r.method)
    if not produced[k] then
      produced[k] = true
      M.results[k] = {}
    end
    M.running[k] = nil
    table.insert(M.results[k], r)
  end
  return produced
end

---Ends a run: clears running markers and drops stale results for methods that produced none
---(e.g. a renamed or deleted test)
---@param keys string[] Methods that were expected to run
---@param produced table<string, boolean>
function M.finish(keys, produced)
  for _, k in ipairs(keys) do
    M.running[k] = nil
    if not produced[k] then
      M.results[k] = nil
    end
  end
end

---Clears running markers without storing results (cancelled or failed runs)
---@param keys string[]
function M.cancel(keys)
  for _, k in ipairs(keys) do
    M.running[k] = nil
  end
end

---Aggregated state for a method, or nil when there is nothing to show
---@param class string
---@param method string
---@return CSTestAggregate|nil
function M.get(class, method)
  local k = result.key(class, method)
  if M.running[k] then
    return { status = "running", duration = 0, total = 0, failed = 0, cases = M.results[k] or {} }
  end
  local cases = M.results[k]
  if not cases or #cases == 0 then
    return nil
  end
  return result.aggregate(cases)
end

function M.reset()
  M.results = {}
  M.running = {}
  M.last_run = {}
end

return M
