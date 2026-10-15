-- Tests covering production methods, found through LSP references (direct callers only)
--
-- For each non-test method in a buffer, the language server is asked for references. References inside
-- test projects are mapped to the test method that contains them, and the counts are drawn at the end of
-- the method line: "19 tests" until any of them has run, then "16 ✓ | 3 ✗". Answers are cached per method;
-- saving production code only queries new or renamed methods, saving a test file re-queries everything,
-- and test runs only redraw the counts.

local config = require("csharp-test-runner.config")
local locator = require("csharp-test-runner.locator")
local project = require("csharp-test-runner.project")
local result = require("csharp-test-runner.result")
local state = require("csharp-test-runner.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("csharp-test-runner-coverage")

---@class CSTestCoveringTest
---@field class string
---@field method string
---@field file string
---@field line integer 0-based line of the test method name

---Per buffer: method id -> covering tests (nil until answered); `stale` after a test file changed
---@type table<integer, { stale: boolean|nil, methods: table<string, CSTestCoveringTest[]> }>
M.cache = {}

---Requests in flight per buffer, so a newer refresh can discard older answers
---@type table<integer, integer>
local generation = {}

---Directory -> test project (false when the directory is not in a test project)
---@type table<string, CSTestProject|false>
local project_cache = {}

---Test file path -> { mtime, tests }
---@type table<string, { mtime: integer, tests: CSTestLocation[] }>
local test_file_cache = {}

---Identifies a method across edits: class, name and position among overloads with the same name
---@param methods CSTestLocation[]
---@return table<CSTestLocation, string>
function M.method_ids(methods)
  local ids, seen = {}, {}
  for _, m in ipairs(methods) do
    local base = m.class .. "::" .. m.method
    seen[base] = (seen[base] or 0) + 1
    ids[m] = base .. "#" .. seen[base]
  end
  return ids
end

---Test project of a file, cached by directory
---@param path string
---@return CSTestProject|nil
local function test_project(path)
  local dir = vim.fs.dirname(path)
  if project_cache[dir] == nil then
    project_cache[dir] = project.for_file(path) or false
  end
  return project_cache[dir] or nil
end

---Test methods of a file, preferring the loaded buffer (it may have unsaved edits)
---@param path string
---@return CSTestLocation[]
local function tests_in(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return locator.tests(bufnr)
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}
  end
  local cached = test_file_cache[path]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.tests
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  local tests = ok and locator.tests(table.concat(lines, "\n")) or {}
  test_file_cache[path] = { mtime = stat.mtime.sec, tests = tests }
  return tests
end

---Maps LSP locations to the distinct test methods that contain them
---@param locations table[] LSP Location[]
---@return CSTestCoveringTest[]
function M.tests_from_locations(locations)
  local found, seen = {}, {}
  for _, loc in ipairs(locations or {}) do
    local path = vim.uri_to_fname(loc.uri)
    if test_project(path) then
      local row = loc.range.start.line
      for _, t in ipairs(tests_in(path)) do
        if row >= t.start_row and row <= t.end_row then
          -- an inherited test counts once per class it runs under
          for _, class in ipairs(t.classes) do
            local k = result.key(class, t.method)
            if not seen[k] then
              seen[k] = true
              table.insert(found, { class = class, method = t.method, file = path, line = t.line })
            end
          end
          break
        end
      end
    end
  end
  return found
end

---The language server client used for references
---@param bufnr integer
---@return vim.lsp.Client|nil
local function client_for(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c.supports_method("textDocument/references") then
      return c
    end
  end
  return nil
end

---Whether the language server has finished loading the solution
---@param bufnr integer
---@return boolean
function M.server_ready(bufnr)
  -- roslyn.nvim sets _G.roslyn_initialized once the solution has loaded; references before that are incomplete
  if #vim.lsp.get_clients({ bufnr = bufnr, name = "roslyn" }) > 0 then
    return _G.roslyn_initialized == true
  end
  return true
end

---Asks the language server for references (replaced in tests)
---@param bufnr integer
---@param m CSTestLocation
---@param cb fun(locations: table[]|nil)
function M.references(bufnr, m, cb)
  local client = client_for(bufnr)
  if not client then
    return cb(nil)
  end
  client.request("textDocument/references", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = m.line, character = m.col },
    context = { includeDeclaration = false },
  }, function(err, res)
    cb(not err and res or nil)
  end, bufnr)
end

---Counts covering tests by their latest status
---@param tests CSTestCoveringTest[]
---@return { total: integer, passed: integer, failed: integer, skipped: integer, running: integer, not_run: integer }
function M.counts(tests)
  local c = { total = #tests, passed = 0, failed = 0, skipped = 0, running = 0, not_run = 0 }
  for _, t in ipairs(tests) do
    local agg = state.get(t.class, t.method)
    if not agg then
      c.not_run = c.not_run + 1
    elseif agg.status == "running" then
      c.running = c.running + 1
    else
      c[agg.status] = c[agg.status] + 1
    end
  end
  return c
end

---Virtual text chunks for a method's counts: "19 tests" until any covering test has a result,
---then only the results, e.g. "16 ✓ | 3 ✗"
---@param c table counts from M.counts
---@return table[] chunks
function M.chunks(c)
  local icons = config.options.icons
  if c.passed + c.failed + c.skipped + c.running == 0 then
    return { { "  " .. c.total .. (c.total == 1 and " test" or " tests"), "CSTestCoverage" } }
  end
  local chunks = { { "  ", "CSTestCoverage" } }
  local function add(n, icon, hl)
    if n > 0 then
      if #chunks > 1 then
        table.insert(chunks, { " | ", "CSTestCoverage" })
      end
      table.insert(chunks, { n .. " " .. icon, hl })
    end
  end
  add(c.passed, icons.passed, "CSTestPassed")
  add(c.failed, icons.failed, "CSTestFailed")
  add(c.skipped, icons.skipped, "CSTestSkipped")
  add(c.running, icons.running, "CSTestRunning")
  return chunks
end

---Draws counts for every method with cached results
---@param bufnr integer
function M.render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local entry = M.cache[bufnr]
  if not entry or not config.options.coverage.enabled then
    return
  end
  local methods = vim.tbl_filter(function(m)
    return not m.is_test
  end, locator.methods(bufnr))
  local ids = M.method_ids(methods)
  for _, m in ipairs(methods) do
    local tests = entry.methods[ids[m]]
    if tests and #tests > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, m.line, 0, {
        virt_text = M.chunks(M.counts(tests)),
        hl_mode = "combine",
      })
    end
  end
end

---Redraws counts in every buffer with cached results (no new requests)
function M.render_all()
  for bufnr in pairs(M.cache) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.render(bufnr)
    else
      M.cache[bufnr] = nil
    end
  end
end

---Finds covering tests for the methods of a buffer, a few requests at a time.
---Only methods without a cached answer are queried unless `force` is set: editing a method body does not change
---which tests call it, so saving production code only queries new or renamed methods. Cached counts stay visible
---until their new answer arrives. Methods nearest the cursor are queried first.
---@param bufnr integer
---@param opts { force: boolean|nil, done: fun()|nil }|nil
function M.refresh(bufnr, opts)
  opts = opts or {}
  local function finish()
    if opts.done then
      opts.done()
    end
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or not client_for(bufnr) or not M.server_ready(bufnr) then
    return finish()
  end
  local methods = vim.tbl_filter(function(m)
    return not m.is_test
  end, locator.methods(bufnr))
  local ids = M.method_ids(methods)

  local entry = M.cache[bufnr] or { methods = {} }
  M.cache[bufnr] = entry
  entry.stale = nil
  -- forget methods that were removed or renamed
  local live = {}
  for _, id in pairs(ids) do
    live[id] = true
  end
  for id in pairs(entry.methods) do
    if not live[id] then
      entry.methods[id] = nil
    end
  end

  local queue = {}
  for _, m in ipairs(methods) do
    if opts.force or entry.methods[ids[m]] == nil then
      table.insert(queue, m)
    end
  end
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] - 1 or 0
  table.sort(queue, function(a, b)
    return math.abs(a.line - cursor) < math.abs(b.line - cursor)
  end)

  M.render(bufnr)
  if #queue == 0 then
    return finish()
  end

  generation[bufnr] = (generation[bufnr] or 0) + 1
  local my_gen = generation[bufnr]
  local next_index, in_flight = 1, 0
  local function pump()
    if generation[bufnr] ~= my_gen then
      return
    end
    if next_index > #queue and in_flight == 0 then
      return finish()
    end
    while in_flight < config.options.coverage.concurrency and next_index <= #queue do
      local m = queue[next_index]
      next_index = next_index + 1
      in_flight = in_flight + 1
      M.references(bufnr, m, function(locations)
        vim.schedule(function()
          in_flight = in_flight - 1
          if generation[bufnr] ~= my_gen or M.cache[bufnr] ~= entry then
            return
          end
          if locations then
            entry.methods[ids[m]] = M.tests_from_locations(locations)
            M.render(bufnr)
          end
          pump()
        end)
      end)
    end
  end
  pump()
end

---Marks a buffer's cached counts as outdated (a test file changed); it is re-queried in full when next shown
---@param bufnr integer
function M.mark_stale(bufnr)
  if M.cache[bufnr] then
    M.cache[bufnr].stale = true
  end
end

---Covering tests for one method, from the cache or a fresh request
---@param bufnr integer
---@param m CSTestLocation
---@param cb fun(tests: CSTestCoveringTest[]|nil)
function M.tests_for(bufnr, m, cb)
  local methods = vim.tbl_filter(function(x)
    return not x.is_test
  end, locator.methods(bufnr))
  local id
  for x, i in pairs(M.method_ids(methods)) do
    if x.line == m.line and x.method == m.method then
      id = i
    end
  end
  local entry = M.cache[bufnr]
  if id and entry and entry.methods[id] then
    return cb(entry.methods[id])
  end
  if not client_for(bufnr) or not M.server_ready(bufnr) then
    return cb(nil)
  end
  M.references(bufnr, m, function(locations)
    vim.schedule(function()
      if not locations then
        return cb(nil)
      end
      local tests = M.tests_from_locations(locations)
      if id then
        M.cache[bufnr] = M.cache[bufnr] or { methods = {} }
        M.cache[bufnr].methods[id] = tests
        M.render(bufnr)
      end
      cb(tests)
    end)
  end)
end

---Drops cached results (all buffers, or one)
---@param bufnr integer|nil
function M.clear(bufnr)
  if bufnr then
    M.cache[bufnr] = nil
    generation[bufnr] = (generation[bufnr] or 0) + 1
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    end
    return
  end
  for b in pairs(M.cache) do
    M.clear(b)
  end
  project_cache, test_file_cache = {}, {}
end

---Whether a file belongs to a test project
---@param path string
---@return boolean
function M.in_test_project(path)
  return path ~= "" and test_project(path) ~= nil
end

---Forgets cached test files and projects (after a test file or project file changes)
function M.invalidate_files()
  project_cache, test_file_cache = {}, {}
end

return M
