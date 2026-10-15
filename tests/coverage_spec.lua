-- Coverage counts on production methods (LSP answers are simulated through the cache and stubs)

local h = require("tests.helpers")
local config = require("csharp-test-runner.config")
local coverage = require("csharp-test-runner.coverage")
local locator = require("csharp-test-runner.locator")
local state = require("csharp-test-runner.state")

---Builds a temp solution: Tests/ (xunit project with Calc_tests.cs) and App/ (plain project with Calc.cs)
---@return string root
local function make_solution()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/Tests", "p")
  vim.fn.mkdir(root .. "/App", "p")
  vim.fn.writefile(vim.split(h.read("XProj.csproj"), "\n"), root .. "/Tests/Tests.csproj")
  vim.fn.writefile(vim.split(h.read("Calc_tests.cs"), "\n"), root .. "/Tests/Calc_tests.cs")
  vim.fn.writefile({ '<Project Sdk="Microsoft.NET.Sdk"/>' }, root .. "/App/App.csproj")
  vim.fn.writefile(vim.split(h.read("Calc.cs"), "\n"), root .. "/App/Calc.cs")
  return root
end

---LSP location at a 0-based row of a file
local function loc(path, row)
  return { uri = vim.uri_from_fname(path), range = { start = { line = row, character = 8 }, ["end"] = { line = row, character = 12 } } }
end

describe("coverage", function()
  local root

  before_each(function()
    config.setup({ coverage = { enabled = true } })
    state.reset()
    coverage.clear()
    root = make_solution()
  end)

  it("tells test projects from production projects", function()
    assert.is_true(coverage.in_test_project(root .. "/Tests/Calc_tests.cs"))
    assert.is_false(coverage.in_test_project(root .. "/App/Calc.cs"))
  end)

  it("identifies overloads separately", function()
    local methods = locator.methods(h.read("Calc.cs"))
    local ids = coverage.method_ids(methods)
    assert.equals("Sample.App.Calc::Add#1", ids[methods[1]])
    assert.equals("Sample.App.Calc::Add#2", ids[methods[2]])
    assert.equals("Sample.App.Calc::Untested#1", ids[methods[3]])
  end)

  it("maps references to distinct test methods, ignoring production callers", function()
    local test_file = root .. "/Tests/Calc_tests.cs"
    local tests = coverage.tests_from_locations({
      loc(test_file, 10), -- inside FailsEqual
      loc(test_file, 11), -- FailsEqual again: counted once
      loc(test_file, 26), -- inside TheoryMixed
      loc(root .. "/App/Calc.cs", 4), -- production caller: ignored
      loc(test_file, 0), -- outside any test: ignored
    })
    local names = vim.tbl_map(function(t)
      return t.method
    end, tests)
    assert.same({ "FailsEqual", "TheoryMixed" }, names)
    assert.equals("Sample.XUnit.CalcTests", tests[1].class)
  end)

  it("counts covering test cases by their latest result", function()
    state.store({
      { class = "A", method = "P", name = "P", status = "passed", duration = 1 },
      { class = "A", method = "F", name = "F", status = "failed", duration = 1 },
    })
    local c = coverage.counts({
      { class = "A", method = "P" },
      { class = "A", method = "F" },
      { class = "A", method = "Never" },
    })
    assert.same({ total = 3, passed = 1, failed = 1, skipped = 0, running = 0, not_run = 1 }, c)
    local text = table.concat(vim.tbl_map(function(ch)
      return ch[1]
    end, coverage.chunks(c)))
    assert.equals("  1 ✓ | 1 ✗", text) -- once anything has a result, only results are shown
    local fresh = table.concat(vim.tbl_map(function(ch)
      return ch[1]
    end, coverage.chunks(coverage.counts({ { class = "A", method = "Never" }, { class = "A", method = "Also" } }))))
    assert.equals("  2 tests", fresh)
  end)

  it("draws counts at the end of covered method lines and skips uncovered ones", function()
    local test_file = root .. "/Tests/Calc_tests.cs"
    vim.cmd("edit " .. root .. "/App/Calc.cs")
    local bufnr = vim.api.nvim_get_current_buf()
    local methods = locator.methods(bufnr)
    local ids = coverage.method_ids(methods)
    -- what refresh() stores once references answer: both Add overloads are called from two tests
    coverage.cache[bufnr] = { direct = {} }
    for _, m in ipairs(methods) do
      local locs = m.method == "Add" and { loc(test_file, 10), loc(test_file, 26) } or {}
      coverage.cache[bufnr].direct[ids[m]] = coverage.tests_from_locations(locs)
    end
    coverage.render(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, coverage.ns, 0, -1, { details = true })
    assert.equals(2, #marks) -- both Add overloads, not Untested
    assert.equals(methods[1].line, marks[1][2])
    local text = table.concat(vim.tbl_map(function(ch)
      return ch[1]
    end, marks[1][4].virt_text))
    assert.equals("  3 tests", text) -- FailsEqual (1 case) + TheoryMixed (2 [InlineData] rows)
  end)

  it("hides counts when coverage is disabled", function()
    vim.cmd("edit " .. root .. "/App/Calc.cs")
    local bufnr = vim.api.nvim_get_current_buf()
    coverage.cache[bufnr] = { direct = { ["Sample.App.Calc::Add#1"] = { { class = "A", method = "B" } } } }
    config.options.coverage.enabled = false
    coverage.render(bufnr)
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, coverage.ns, 0, -1, {}))
  end)
end)

describe("run_smart in production code", function()
  local cst = require("csharp-test-runner")
  local runner = require("csharp-test-runner.runner")
  local orig_run, orig_tests_for

  before_each(function()
    config.setup({ coverage = { enabled = true } })
    coverage.clear()
    orig_run, orig_tests_for = runner.run, coverage.tests_for
  end)

  after_each(function()
    runner.run, coverage.tests_for = orig_run, orig_tests_for
  end)

  it("runs the tests that cover the method under the cursor", function()
    local root = make_solution()
    local test_file = root .. "/Tests/Calc_tests.cs"
    coverage.tests_for = function(_, m, cb)
      assert.equals("Add", m.method)
      cb({
        { class = "Sample.XUnit.CalcTests", method = "FailsEqual", file = test_file, line = 9 },
        { class = "Sample.XUnit.CalcTests", method = "TheoryMixed", file = test_file, line = 23 },
      })
    end
    local captured
    runner.run = function(specs, keys, label)
      captured = { specs = specs, keys = keys, label = label }
    end
    vim.cmd("edit " .. root .. "/App/Calc.cs")
    vim.api.nvim_win_set_cursor(0, { 5, 20 }) -- inside the first Add
    cst.run_smart()
    assert.is_not_nil(captured)
    assert.equals(1, #captured.specs)
    assert.equals("xunit", captured.specs[1].project.framework)
    assert.same({
      kind = "methods",
      methods = {
        { class = "Sample.XUnit.CalcTests", method = "FailsEqual" },
        { class = "Sample.XUnit.CalcTests", method = "TheoryMixed" },
      },
    }, captured.specs[1].selection)
    assert.equals(2, #captured.keys)
  end)
end)

describe("coverage refresh", function()
  local orig_refs, orig_ready, orig_client

  before_each(function()
    config.setup({ coverage = { enabled = true, concurrency = 2 } })
    coverage.clear()
    orig_refs, orig_ready = coverage.references, coverage.server_ready
    coverage.server_ready = function()
      return true
    end
    -- pretend an LSP client with references is attached
    orig_client = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return { { name = "fake", supports_method = function() return true end } }
    end
  end)

  after_each(function()
    coverage.references, coverage.server_ready = orig_refs, orig_ready
    vim.lsp.get_clients = orig_client
  end)

  ---@return integer bufnr, string[] queried
  local function open_and_track()
    local root = make_solution()
    vim.cmd("edit " .. root .. "/App/Calc.cs")
    local queried = {}
    coverage.references = function(_, m, cb)
      table.insert(queried, m.method .. "@" .. m.line)
      cb({})
    end
    return vim.api.nvim_get_current_buf(), queried
  end

  it("queries every method the first time, nearest the cursor first", function()
    local bufnr, queried = open_and_track()
    vim.api.nvim_win_set_cursor(0, { 9, 0 }) -- on Untested (0-based line 8)
    local finished = false
    coverage.refresh(bufnr, { done = function() finished = true end })
    vim.wait(1000, function() return finished end)
    assert.same({ "Untested@8", "Add@6", "Add@4" }, queried)
  end)

  it("only queries new methods on later refreshes, unless forced", function()
    local bufnr, queried = open_and_track()
    local finished = false
    coverage.refresh(bufnr, { done = function() finished = true end })
    vim.wait(1000, function() return finished end)
    assert.equals(3, #queried)

    -- add a method, as if the user typed it and saved
    vim.api.nvim_buf_set_lines(bufnr, 8, 8, false, { "    public int Twice(int a) => a * 2;", "" })
    finished = false
    coverage.refresh(bufnr, { done = function() finished = true end })
    vim.wait(1000, function() return finished end)
    assert.equals(4, #queried)
    assert.equals("Twice@8", queried[4])

    finished = false
    coverage.refresh(bufnr, { force = true, done = function() finished = true end })
    vim.wait(1000, function() return finished end)
    assert.equals(8, #queried)
  end)

  it("forgets counts of removed methods", function()
    local bufnr = open_and_track()
    local finished = false
    coverage.refresh(bufnr, { done = function() finished = true end })
    vim.wait(1000, function() return finished end)
    assert.is_not_nil(coverage.cache[bufnr].direct["Sample.App.Calc::Untested#1"])
    vim.api.nvim_buf_set_lines(bufnr, 8, 9, false, {}) -- delete Untested
    finished = false
    coverage.refresh(bufnr, { done = function() finished = true end })
    vim.wait(1000, function() return finished end)
    assert.is_nil(coverage.cache[bufnr].direct["Sample.App.Calc::Untested#1"])
  end)
end)

describe("case counting", function()
  before_each(function()
    config.setup({ coverage = { enabled = true } })
    state.reset()
  end)

  it("counts data rows before a theory has run, and real cases after", function()
    local tests = locator.tests(h.read("Calc_tests.cs"))
    local theory
    for _, t in ipairs(tests) do
      if t.method == "TheoryMixed" then theory = t end
    end
    assert.equals(2, theory.cases) -- two [InlineData] rows
    local covering = { { class = "Sample.XUnit.CalcTests", method = "TheoryMixed", cases = 2 },
      { class = "Sample.XUnit.CalcTests", method = "Adds", cases = 1 } }
    assert.equals(3, coverage.counts(covering).total)
    state.store({
      { class = "Sample.XUnit.CalcTests", method = "TheoryMixed", name = "a", status = "passed", duration = 1 },
      { class = "Sample.XUnit.CalcTests", method = "TheoryMixed", name = "b", status = "failed", duration = 1 },
      { class = "Sample.XUnit.CalcTests", method = "TheoryMixed", name = "c", status = "passed", duration = 1 },
    })
    local c = coverage.counts(covering)
    assert.equals(4, c.total) -- 3 real cases (e.g. [MemberData]) + Adds not yet run
    assert.equals(2, c.passed)
    assert.equals(1, c.failed)
  end)

  it("counts DataRow rows for MSTest", function()
    local rows
    for _, t in ipairs(locator.tests(h.read("CalcTests.cs"))) do
      if t.method == "RowsMixed" then rows = t.cases end
    end
    assert.equals(2, rows)
  end)
end)

describe("abstract base tests", function()
  it("are not counted on production methods, like Visual Studio", function()
    config.setup({ coverage = { enabled = true } })
    coverage.clear()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(h.read("XProj.csproj"), "\n"), dir .. "/T.csproj")
    vim.fn.writefile(vim.split(h.read("Inherit.cs"), "\n"), dir .. "/Inherit.cs")
    -- a reference inside Base<T>.A (row 3) and one inside a concrete class that is not a test (row 5)
    local tests = coverage.tests_from_locations({ loc(dir .. "/Inherit.cs", 3), loc(dir .. "/Inherit.cs", 5) })
    assert.same({}, tests)
  end)
end)

describe("local functions", function()
  it("do not credit their calls to the enclosing test, like Visual Studio", function()
    config.setup({ coverage = { enabled = true } })
    coverage.clear()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(h.read("XProj.csproj"), "\n"), dir .. "/T.csproj")
    vim.fn.writefile({
      "namespace N;",
      "public class LocalTests",
      "{",
      "    [Fact]",
      "    public void UsesLocal()",
      "    {",
      "        int Helper(int x) => Calc.Add(x, 1);",
      "        Assert.Equal(2, Helper(1));",
      "        Assert.Equal(3, Calc.Add(1, 2));",
      "    }",
      "}",
    }, dir .. "/LocalTests.cs")
    -- row 6: inside the local function; row 8: in the test body itself
    assert.same({}, coverage.tests_from_locations({ loc(dir .. "/LocalTests.cs", 6) }))
    local direct = coverage.tests_from_locations({ loc(dir .. "/LocalTests.cs", 8) })
    assert.equals("UsesLocal", direct[1].method)
  end)
end)
