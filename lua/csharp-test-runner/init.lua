-- csharp-test-runner.nvim
-- Run xUnit v3 and MSTest tests from Neovim with inline results, diagnostics and quickfix

local config = require("csharp-test-runner.config")
local locator = require("csharp-test-runner.locator")
local project = require("csharp-test-runner.project")
local result = require("csharp-test-runner.result")
local runner = require("csharp-test-runner.runner")
local state = require("csharp-test-runner.state")
local ui = require("csharp-test-runner.ui")

local M = {}

local group = vim.api.nvim_create_augroup("CSharpTestRunner", { clear = true })

---Buffers with run-on-save enabled -> autocmd id
---@type table<integer, integer>
M.watching = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.WARN, { title = "cstest" })
end

---Keys of every test in loaded C# buffers that satisfy a predicate on the buffer path
---@param include fun(path: string): boolean
---@return string[]
local function loaded_keys(include)
  local keys = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "cs" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" and include(path) then
        for _, t in ipairs(locator.tests(bufnr)) do
          table.insert(keys, result.key(t.class, t.method))
        end
      end
    end
  end
  return keys
end

---Resolves the test project of a buffer, notifying on failure
---@param bufnr integer
---@return CSTestProject|nil
local function buffer_project(bufnr)
  local p, err = project.for_file(vim.api.nvim_buf_get_name(bufnr))
  if not p then
    notify(err or "not in a test project")
  end
  return p
end

---Runs the test method under the cursor
function M.run_nearest()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local t = locator.nearest(bufnr, row)
  if not t then
    return notify("no test method under the cursor")
  end
  local p = buffer_project(bufnr)
  if not p then
    return
  end
  runner.run(
    { { project = p, selection = { kind = "method", class = t.class, method = t.method } } },
    { result.key(t.class, t.method) },
    t.method
  )
end

---Runs the test method under the cursor, or the whole file when the cursor is not inside a test method
function M.run_smart()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if locator.nearest(bufnr, row) then
    M.run_nearest()
  else
    M.run_file(bufnr)
  end
end

---Runs every test class in the current file
---@param bufnr integer|nil
function M.run_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local classes = locator.classes(bufnr)
  if #classes == 0 then
    return notify("no test methods in this file")
  end
  local p = buffer_project(bufnr)
  if not p then
    return
  end
  local keys = {}
  for _, t in ipairs(locator.tests(bufnr)) do
    table.insert(keys, result.key(t.class, t.method))
  end
  runner.run(
    { { project = p, selection = { kind = "classes", classes = classes } } },
    keys,
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  )
end

---Runs every test in the current file's test project
---@param bufnr integer|nil
function M.run_project(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local p = buffer_project(bufnr)
  if not p then
    return
  end
  local keys = loaded_keys(function(path)
    return project.contains(p, path)
  end)
  runner.run({ { project = p, selection = { kind = "project" } } }, keys, p.name)
end

---Runs every test project in the solution, one after another
function M.run_all()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    path = vim.fn.getcwd() .. "/_"
  end
  local root = project.solution_root(path) or vim.fn.getcwd()
  local projects = project.all_under(root)
  if #projects == 0 then
    return notify("no xunit.v3 or MSTest projects under " .. root)
  end
  local specs = {}
  for _, p in ipairs(projects) do
    table.insert(specs, { project = p, selection = { kind = "project" } })
  end
  local keys = loaded_keys(function(file)
    return vim.startswith(vim.fs.normalize(file), vim.fs.normalize(root) .. "/")
  end)
  runner.run(specs, keys, string.format("all (%d projects)", #projects))
end

---Shows failure output for the test under the cursor, or every failure of the last run
---@param as_split boolean|nil
function M.output(as_split)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local t = vim.bo[bufnr].filetype == "cs" and locator.nearest(bufnr, row) or nil
  if t then
    local cases = state.results[result.key(t.class, t.method)]
    if cases and #cases > 0 then
      -- failures first
      local sorted = vim.deepcopy(cases)
      table.sort(sorted, function(a, b)
        return (a.status == "failed" and 0 or 1) < (b.status == "failed" and 0 or 1)
      end)
      return ui.open_output(sorted, t.method, as_split)
    end
  end
  local failed = vim.tbl_filter(function(r)
    return r.status == "failed"
  end, state.last_run)
  if #failed > 0 then
    return ui.open_output(failed, string.format("%d failed test(s)", #failed), as_split)
  end
  notify(t and "no results for " .. t.method .. " yet" or "no failures in the last run", vim.log.levels.INFO)
end

---Toggles run-on-save for a buffer
---@param bufnr integer|nil
function M.toggle_watch(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.watching[bufnr] then
    pcall(vim.api.nvim_del_autocmd, M.watching[bufnr])
    M.watching[bufnr] = nil
    return notify("watch off", vim.log.levels.INFO)
  end
  if not buffer_project(bufnr) then
    return
  end
  M.watching[bufnr] = vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function()
      if config.options.watch_scope == "project" then
        M.run_project(bufnr)
      else
        M.run_file(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      M.watching[bufnr] = nil
    end,
  })
  notify("watch on (runs " .. config.options.watch_scope .. " on save)", vim.log.levels.INFO)
end

---Clears all results, marks and our quickfix list
function M.clear()
  runner.stop()
  state.reset()
  ui.clear_all()
  ui.quickfix({})
end

M.subcommands = {
  smart = function()
    M.run_smart()
  end,
  nearest = function()
    M.run_nearest()
  end,
  file = function()
    M.run_file()
  end,
  project = function()
    M.run_project()
  end,
  all = M.run_all,
  output = function()
    M.output(false)
  end,
  watch = function()
    M.toggle_watch()
  end,
  stop = runner.stop,
  clear = M.clear,
}

---Sets up the plugin
---@param opts CSTestConfig|table|nil
function M.setup(opts)
  config.setup(opts)
  ui.define_highlights()

  vim.api.nvim_create_user_command("CSTest", function(cmd)
    local sub = cmd.fargs[1] or "smart"
    local fn = M.subcommands[sub]
    if not fn then
      return notify("unknown subcommand: " .. sub, vim.log.levels.ERROR)
    end
    fn()
  end, {
    nargs = "?",
    desc = "C# test runner",
    complete = function(lead)
      return vim.tbl_filter(function(s)
        return vim.startswith(s, lead)
      end, vim.tbl_keys(M.subcommands))
    end,
  })

  -- results from project/solution runs appear when a file is opened later
  vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
    group = group,
    pattern = { "*.cs", "cs" },
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "cs" and next(state.results) then
        ui.render(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = ui.define_highlights,
  })

  local km = config.options.keymaps
  if km then
    local maps = {
      { km.smart, M.subcommands.smart, "Run test under cursor, else file" },
      { km.nearest, M.subcommands.nearest, "Run nearest test" },
      { km.file, M.subcommands.file, "Run tests in file" },
      { km.project, M.subcommands.project, "Run tests in project" },
      { km.all, M.subcommands.all, "Run all tests" },
      { km.output, M.subcommands.output, "Show test output" },
      { km.watch, M.subcommands.watch, "Toggle run tests on save" },
      { km.stop, M.subcommands.stop, "Stop test run" },
    }
    for _, m in ipairs(maps) do
      if m[1] then
        vim.keymap.set("n", m[1], m[2], { desc = "CSTest: " .. m[3] })
      end
    end
  end
end

return M
