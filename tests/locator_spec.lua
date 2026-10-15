-- Tree-sitter test discovery

local h = require("tests.helpers")
local config = require("csharp-test-runner.config")
local locator = require("csharp-test-runner.locator")

describe("locator", function()
  before_each(function()
    config.setup()
  end)

  it("finds xunit facts and theories, including async tests", function()
    local tests = locator.tests(h.cs_buffer("Calc_tests.cs"))
    local names = vim.tbl_map(function(t)
      return t.method
    end, tests)
    assert.same({ "Adds", "FailsEqual", "AsyncThrows", "TheoryMixed", "Skipped" }, names)
    assert.equals("Sample.XUnit.CalcTests", tests[1].class)
  end)

  it("finds mstest methods with a file-scoped namespace", function()
    local tests = locator.tests(h.cs_buffer("CalcTests.cs"))
    assert.equals(5, #tests)
    assert.equals("Sample.MSTest.CalcTests", tests[1].class)
  end)

  it("puts marks on the method name line, not the attribute line", function()
    local bufnr = h.cs_buffer("Calc_tests.cs")
    local t = locator.tests(bufnr)[2]
    assert.truthy(vim.api.nvim_buf_get_lines(bufnr, t.line, t.line + 1, false)[1]:find("FailsEqual", 1, true))
  end)

  it("handles block namespaces, nested classes and qualified attributes", function()
    local tests = locator.tests(h.cs_buffer("Nested.cs"))
    assert.equals(1, #tests)
    assert.equals("Outer.Ns.Shell+Inner", tests[1].class)
    assert.equals("Deep", tests[1].method)
  end)

  it("finds the test around the cursor, including its attributes", function()
    local bufnr = h.cs_buffer("Calc_tests.cs")
    -- row 20 is the [Theory] attribute, row 26 is inside the body
    assert.equals("TheoryMixed", locator.nearest(bufnr, 20).method)
    assert.equals("TheoryMixed", locator.nearest(bufnr, 26).method)
    assert.is_nil(locator.nearest(bufnr, 0))
  end)

  it("respects configured attributes", function()
    config.setup({ test_attributes = { "Theory" } })
    local tests = locator.tests(h.cs_buffer("Calc_tests.cs"))
    assert.equals(1, #tests)
    assert.equals("TheoryMixed", tests[1].method)
  end)
end)

describe("run_smart", function()
  local cst = require("csharp-test-runner")
  local orig_nearest, orig_file

  before_each(function()
    config.setup()
    orig_nearest, orig_file = cst.run_nearest, cst.run_file
  end)

  after_each(function()
    cst.run_nearest, cst.run_file = orig_nearest, orig_file
  end)

  ---@param row integer 1-based cursor line
  ---@return string|nil which
  local function smart_at(row)
    local bufnr = h.cs_buffer("Calc_tests.cs")
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local which
    cst.run_nearest = function()
      which = "nearest"
    end
    cst.run_file = function()
      which = "file"
    end
    cst.run_smart()
    return which
  end

  it("runs the method when the cursor is inside a test", function()
    assert.equals("nearest", smart_at(11)) -- FailsEqual body
    assert.equals("nearest", smart_at(21)) -- [Theory] attribute
  end)

  it("runs the file when the cursor is outside any test", function()
    assert.equals("file", smart_at(1)) -- namespace line
    assert.equals("file", smart_at(7)) -- blank line between tests
  end)
end)
