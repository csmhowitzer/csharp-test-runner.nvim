-- Runs test projects and feeds results to the store and UI

local config = require("csharp-test-runner.config")
local state = require("csharp-test-runner.state")
local ui = require("csharp-test-runner.ui")

local M = {}

M.adapters = {
  xunit = require("csharp-test-runner.adapters.xunit"),
  mstest = require("csharp-test-runner.adapters.mstest"),
}

---@class CSTestRunSpec
---@field project CSTestProject
---@field selection CSTestSelection

---Only one run is active at a time; a newer run cancels the older one
local generation = 0
---@type integer|nil
local current_job = nil
---@type string[]
local current_keys = {}

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

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "cstest" })
end

---Whether a run is in progress
---@return boolean
function M.is_running()
  return current_job ~= nil
end

---Stops the active run, keeping previous results
function M.stop()
  generation = generation + 1
  if current_job then
    pcall(vim.fn.jobstop, current_job)
    current_job = nil
  end
  state.cancel(current_keys)
  current_keys = {}
  ui.render_all()
end

---@param results CSTestResult[]
---@return integer passed
---@return integer failed
---@return integer skipped
local function counts(results)
  local p, f, s = 0, 0, 0
  for _, r in ipairs(results) do
    if r.status == "passed" then
      p = p + 1
    elseif r.status == "failed" then
      f = f + 1
    else
      s = s + 1
    end
  end
  return p, f, s
end

---Runs one or more projects in sequence
---@param specs CSTestRunSpec[]
---@param keys string[] Methods shown as running until the run ends
---@param label string Description for notifications
function M.run(specs, keys, label)
  if M.is_running() then
    M.stop()
  end
  generation = generation + 1
  local my_gen = generation
  current_keys = keys
  state.mark_running(keys)
  ui.render_all()

  local all_results, produced = {}, {}
  local build_failed = false
  local started = vim.uv.hrtime()

  local function finish()
    current_job = nil
    current_keys = {}
    if build_failed and #all_results == 0 then
      -- keep previous results visible; the build output is in quickfix
      state.cancel(keys)
      ui.render_all()
      return
    end
    state.finish(keys, produced)
    state.last_run = all_results
    ui.render_all()
    if not build_failed then
      ui.quickfix(all_results)
    end
    local p, f, s = counts(all_results)
    local secs = (vim.uv.hrtime() - started) / 1e9
    if #all_results == 0 then
      notify(label .. ": no tests ran", vim.log.levels.WARN)
    else
      local msg = string.format("%s: %d passed, %d failed", label, p, f)
      if s > 0 then
        msg = msg .. string.format(", %d skipped", s)
      end
      notify(string.format("%s (%.1fs)", msg, secs), f > 0 and vim.log.levels.ERROR or vim.log.levels.INFO)
    end
  end

  local function step(i)
    if my_gen ~= generation then
      return
    end
    local spec = specs[i]
    if not spec then
      return finish()
    end
    local adapter = M.adapters[spec.project.framework]
    local report = vim.fn.tempname() .. adapter.report_ext
    local cmd = adapter.command(spec.project.csproj, spec.selection, report, {
      build = config.options.build,
      extra_args = config.options.extra_args[adapter.name],
    })
    if config.options.debug then
      notify(table.concat(cmd, " "), vim.log.levels.DEBUG)
    end

    local output = {}
    local function collect(_, data)
      for _, l in ipairs(data or {}) do
        if l ~= "" then
          table.insert(output, (l:gsub("\r$", "")))
        end
      end
    end

    local ok, job = pcall(vim.fn.jobstart, cmd, {
      cwd = spec.project.dir,
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = collect,
      on_stderr = collect,
      on_exit = function(_, code)
        local text = read(report)
        os.remove(report)
        if my_gen ~= generation then
          return
        end
        local results, err
        if text then
          results, err = adapter.parse(text)
        end
        if results then
          vim.list_extend(all_results, results)
          for k in pairs(state.store(results)) do
            produced[k] = true
          end
          ui.render_all()
        else
          build_failed = true
          local n = ui.build_errors(output)
          local detail = n > 0 and string.format("%d build error(s) in quickfix", n)
            or (err or ("exit code " .. code)) .. "\n" .. table.concat(vim.list_slice(output, math.max(1, #output - 8)), "\n")
          notify(spec.project.name .. ": run failed - " .. detail, vim.log.levels.ERROR)
        end
        step(i + 1)
      end,
    })
    if not ok or job <= 0 then
      notify("failed to start: " .. table.concat(cmd, " "), vim.log.levels.ERROR)
      build_failed = true
      return step(i + 1)
    end
    current_job = job
  end

  step(1)
end

return M
