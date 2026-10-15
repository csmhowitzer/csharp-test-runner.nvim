-- Tests covering production methods, found through LSP references, counted like Visual Studio's "Tested By":
-- tests that call a method directly, one per test case (theory rows count separately). Like Visual Studio, tests
-- declared in an abstract base class are not counted (they still get their own results in the test file).
--
-- For each non-test method in a buffer, the language server is asked for references; references inside test
-- projects are mapped to the test method that contains them. The counts are drawn at the end of the method line:
-- "19 tests" until any of them has run, then "16 ✓ | 3 ✗". Answers are cached per method; saving production
-- code only queries new or renamed methods, saving a test file re-queries everything, and test runs only redraw.

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
---@field cases integer Cases known before running (data rows), replaced by the real number once it has run

---Per buffer, by method id: the tests that call the method. `stale` is set after a test file changed.
---@class CSTestCoverageEntry
---@field direct table<string, CSTestCoveringTest[]>
---@field stale boolean|nil

---@type table<integer, CSTestCoverageEntry>
M.cache = {}

---Requests in flight per buffer, so a newer refresh can discard older answers
---@type table<integer, integer>
local generation = {}

---Directory -> test project (false when the directory is not in a test project)
---@type table<string, CSTestProject|false>
local project_cache = {}

---File path -> { mtime, members } for files that are not loaded
---@type table<string, { mtime: integer, members: CSTestLocation[] }>
local file_cache = {}

---Parsed members per loaded buffer, reused until the buffer text changes
---@type table<integer, { tick: integer, methods: CSTestLocation[], members: CSTestLocation[] }>
local parse_cache = {}

---@param bufnr integer
---@return { methods: CSTestLocation[], members: CSTestLocation[] }
local function parsed(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = parse_cache[bufnr]
  if not cached or cached.tick ~= tick then
    local members = locator.members(bufnr)
    cached = {
      tick = tick,
      members = members,
      methods = vim.tbl_filter(function(m)
        return m.kind == "method" and not m.is_test
      end, members),
    }
    parse_cache[bufnr] = cached
  end
  return cached
end

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

---@param bufnr integer
---@return CSTestLocation[]
local function production_methods(bufnr)
  return parsed(bufnr).methods
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

---Members (methods, constructors, properties) of a file, preferring the loaded buffer (it may have unsaved edits)
---@param path string
---@return CSTestLocation[]
local function members_in(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return parsed(bufnr).members
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}
  end
  local cached = file_cache[path]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.members
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  local members = ok and locator.members(table.concat(lines, "\n")) or {}
  file_cache[path] = { mtime = stat.mtime.sec, members = members }
  return members
end

---The innermost member of a file containing a row
---@param path string
---@param row integer 0-based
---@return CSTestLocation|nil
local function member_at(path, row)
  local best
  for _, m in ipairs(members_in(path)) do
    if row >= m.start_row and row <= m.end_row then
      if not best or (m.end_row - m.start_row) < (best.end_row - best.start_row) then
        best = m
      end
    end
  end
  return best
end

---Adds a test (once per class it runs under) to a list
---@param found CSTestCoveringTest[]
---@param seen table<string, boolean>
---@param t CSTestLocation
---@param path string
local function add_test(found, seen, t, path)
  -- an inherited test counts once per class it runs under
  for _, class in ipairs(t.classes) do
    local k = result.key(class, t.method)
    if not seen[k] then
      seen[k] = true
      table.insert(found, { class = class, method = t.method, file = path, line = t.line, cases = t.cases or 1 })
    end
  end
end

---Maps LSP locations to the distinct test methods that contain them
---@param locations table[] LSP Location[]
---@return CSTestCoveringTest[]
function M.tests_from_locations(locations)
  local found, seen = {}, {}
  for _, loc in ipairs(locations or {}) do
    local path = vim.uri_to_fname(loc.uri)
    if test_project(path) then
      local caller = member_at(path, loc.range.start.line)
      if caller and caller.is_test and not caller.in_abstract then
        add_test(found, seen, caller, path)
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

---Asks the language server for references at a position in any file (replaced in tests)
---@param bufnr integer Buffer whose client is used
---@param uri string Document of the position
---@param line integer
---@param col integer
---@param cb fun(locations: table[]|nil)
function M.references_at(bufnr, uri, line, col, cb)
  local client = client_for(bufnr)
  if not client then
    return cb(nil)
  end
  client.request("textDocument/references", {
    textDocument = { uri = uri },
    position = { line = line, character = col },
    context = { includeDeclaration = false },
  }, function(err, res)
    cb(not err and res or nil)
  end, bufnr)
end

---Asks for references to a method of a buffer
---@param bufnr integer
---@param m CSTestLocation
---@param cb fun(locations: table[]|nil)
function M.references(bufnr, m, cb)
  M.references_at(bufnr, vim.uri_from_bufnr(bufnr), m.line, m.col, cb)
end

---Counts the test cases of covering tests by their latest status. A theory counts once per data row, like
---Visual Studio's "Tested By": rows declared with [InlineData]/[DataRow] before it runs, the actual cases after.
---@param tests CSTestCoveringTest[]
---@return { total: integer, passed: integer, failed: integer, skipped: integer, running: integer, not_run: integer }
function M.counts(tests)
  local c = { total = 0, passed = 0, failed = 0, skipped = 0, running = 0, not_run = 0 }
  for _, t in ipairs(tests) do
    local key = result.key(t.class, t.method)
    local cases = state.results[key]
    local n = (cases and #cases > 0) and #cases or (t.cases or 1)
    c.total = c.total + n
    if state.running[key] then
      c.running = c.running + n
    elseif cases and #cases > 0 then
      for _, r in ipairs(cases) do
        c[r.status] = c[r.status] + 1
      end
    else
      c.not_run = c.not_run + n
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

---@param entry CSTestCoverageEntry
---@param id string
---@return CSTestCoveringTest[]|nil
local function best(entry, id)
  return entry.direct[id]
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
  local methods = production_methods(bufnr)
  local ids = M.method_ids(methods)
  for _, m in ipairs(methods) do
    local tests = best(entry, ids[m])
    if tests and #tests > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, m.line, 0, {
        virt_text = M.chunks(M.counts(tests)),
        hl_mode = "combine",
      })
    end
  end
end

---Buffers waiting for a redraw; answers arrive in bursts, so redraws are batched
---@type table<integer, boolean>
local render_pending = {}

---Redraws a buffer's counts shortly, once for any number of answers in between
---@param bufnr integer
function M.schedule_render(bufnr)
  if render_pending[bufnr] then
    return
  end
  render_pending[bufnr] = true
  vim.defer_fn(function()
    render_pending[bufnr] = nil
    M.render(bufnr)
  end, 150)
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

---@param bufnr integer
---@return CSTestCoverageEntry
local function entry_for(bufnr)
  M.cache[bufnr] = M.cache[bufnr] or { direct = {} }
  return M.cache[bufnr]
end

---Finds covering tests for the methods of a buffer, a few requests at a time.
---Only methods without a cached answer are queried unless `force` is set: editing a method body does not change
---which tests call it, so saving production code only queries new or renamed methods. Cached counts stay visible
---until their new answer arrives. Methods nearest the cursor are queried first.
---@param bufnr integer
---@param opts { force: boolean|nil, done: fun()|nil }|nil `done` runs when every request has answered
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
  local methods = production_methods(bufnr)
  local ids = M.method_ids(methods)

  local entry = entry_for(bufnr)
  entry.stale = nil
  -- forget methods that were removed or renamed
  local live = {}
  for _, id in pairs(ids) do
    live[id] = true
  end
  for id in pairs(entry.direct) do
    if not live[id] then
      entry.direct[id] = nil
    end
  end

  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] - 1 or 0
  local function nearest_first(list)
    table.sort(list, function(a, b)
      return math.abs(a.line - cursor) < math.abs(b.line - cursor)
    end)
    return list
  end
  local direct_queue = nearest_first(vim.tbl_filter(function(m)
    return opts.force or entry.direct[ids[m]] == nil
  end, methods))

  M.render(bufnr)
  generation[bufnr] = (generation[bufnr] or 0) + 1
  local my_gen = generation[bufnr]
  local function current()
    return generation[bufnr] == my_gen and M.cache[bufnr] == entry
  end

  if #direct_queue == 0 then
    return finish()
  end
  local next_index, in_flight = 1, 0
  local function pump()
    if not current() then
      return
    end
    if next_index > #direct_queue and in_flight == 0 then
      return finish()
    end
    while in_flight < config.options.coverage.concurrency and next_index <= #direct_queue do
      local m = direct_queue[next_index]
      next_index = next_index + 1
      in_flight = in_flight + 1
      M.references(bufnr, m, function(locations)
        vim.schedule(function()
          in_flight = in_flight - 1
          if not current() then
            return
          end
          if locations then
            entry.direct[ids[m]] = M.tests_from_locations(locations)
            M.schedule_render(bufnr)
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
  local id
  for x, i in pairs(M.method_ids(production_methods(bufnr))) do
    if x.line == m.line and x.method == m.method then
      id = i
    end
  end
  local entry = M.cache[bufnr]
  if id and entry and entry.direct[id] then
    return cb(entry.direct[id])
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
        entry_for(bufnr).direct[id] = tests
        M.render(bufnr)
      end
      cb(tests)
    end)
  end)
end

---Covering tests already known for every method of a buffer (deduplicated)
---@param bufnr integer
---@return CSTestCoveringTest[]
function M.known_tests(bufnr)
  local entry = M.cache[bufnr]
  local all, seen = {}, {}
  if not entry then
    return all
  end
  for id in pairs(entry.direct) do
    for _, t in ipairs(best(entry, id) or {}) do
      local k = result.key(t.class, t.method)
      if not seen[k] then
        seen[k] = true
        table.insert(all, t)
      end
    end
  end
  return all
end

---After production code is saved: new or renamed methods are queried (answers for unchanged methods are kept,
---since editing a method body does not change which tests call it)
---@param bufnr integer
function M.on_production_save(bufnr)
  M.refresh(bufnr)
end

---Drops cached results (all buffers, or one)
---@param bufnr integer|nil
function M.clear(bufnr)
  if bufnr then
    M.cache[bufnr] = nil
    parse_cache[bufnr] = nil
    generation[bufnr] = (generation[bufnr] or 0) + 1
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    end
    return
  end
  for b in pairs(M.cache) do
    M.clear(b)
  end
  M.invalidate_files()
end

---Whether a file belongs to a test project
---@param path string
---@return boolean
function M.in_test_project(path)
  return path ~= "" and test_project(path) ~= nil
end

---Forgets cached files and projects (after a test file changes, which tests call what may have changed)
function M.invalidate_files()
  project_cache, file_cache = {}, {}
end

return M
