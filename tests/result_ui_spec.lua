-- Result helpers, the store, rendering and quickfix

local h = require("tests.helpers")
local config = require("csharp-test-runner.config")
local result = require("csharp-test-runner.result")
local state = require("csharp-test-runner.state")
local ui = require("csharp-test-runner.ui")
local xunit = require("csharp-test-runner.adapters.xunit")
local mstest = require("csharp-test-runner.adapters.mstest")

describe("result", function()
  it("extracts file and line from stack frames", function()
    local frames = result.parse_trace("   at A.B.C() in /src/x.cs:line 12\n   at System.Foo()")
    assert.same({ text = "at A.B.C()", file = "/src/x.cs", line = 12 }, frames[1])
    assert.same({ text = "at System.Foo()" }, frames[2])
  end)

  it("locates the failing line through the test method's frame", function()
    local r = h.find(assert(mstest.parse(h.read("mstest.trx"))), "AsyncThrows")
    local f = assert(result.test_frame(r))
    assert.equals("/src/MProj/CalcTests.cs", f.file)
    assert.equals(19, f.line)
  end)

  it("aggregates cases: any failure fails the method", function()
    local agg = result.aggregate({
      { status = "passed", duration = 1 },
      { status = "failed", duration = 2 },
    })
    assert.equals("failed", agg.status)
    assert.equals(1, agg.failed)
    assert.equals(2, agg.total)
    assert.equals(3, agg.duration)
    assert.equals("skipped", result.aggregate({ { status = "skipped", duration = 0 } }).status)
  end)

  it("formats durations", function()
    assert.equals("12ms", result.format_duration(12.4))
    assert.equals("1.50s", result.format_duration(1500))
  end)
end)

describe("state", function()
  before_each(state.reset)

  it("replaces a method's cases and drops stale results on finish", function()
    state.results["A::Gone"] = { { status = "passed" } }
    state.mark_running({ "A::M", "A::Gone" })
    assert.equals("running", state.get("A", "M").status)
    local produced = state.store({ { class = "A", method = "M", name = "M", status = "passed", duration = 5 } })
    state.finish({ "A::M", "A::Gone" }, produced)
    assert.equals("passed", state.get("A", "M").status)
    assert.is_nil(state.get("A", "Gone"))
  end)

  it("keeps previous results when a run is cancelled", function()
    state.store({ { class = "A", method = "M", name = "M", status = "failed", duration = 5 } })
    state.mark_running({ "A::M" })
    state.cancel({ "A::M" })
    assert.equals("failed", state.get("A", "M").status)
  end)
end)

describe("ui", function()
  before_each(function()
    config.setup()
    state.reset()
    vim.fn.setqflist({}, "f")
  end)

  it("labels results", function()
    assert.equals("✓ 12ms", ui.label({ status = "passed", duration = 12, total = 1, failed = 0 }))
    assert.equals("✗ 1/2 failed 3ms", ui.label({ status = "failed", duration = 3, total = 2, failed = 1 }))
    assert.equals("✓ 2 cases 3ms", ui.label({ status = "passed", duration = 3, total = 2, failed = 0 }))
    assert.equals("○ skipped", ui.label({ status = "skipped", duration = 0, total = 1, failed = 0 }))
    assert.equals("⋯ running", ui.label({ status = "running", duration = 0, total = 0, failed = 0 }))
  end)

  it("renders virtual text and diagnostics on the method lines", function()
    local bufnr = h.cs_buffer("Calc_tests.cs")
    state.store(assert(xunit.parse(h.read("xunit.ctrf.json"))))
    ui.render(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ui.ns, 0, -1, { details = true })
    assert.equals(5, #marks)
    local by_line = {}
    for _, m in ipairs(marks) do
      by_line[m[2]] = m[4].virt_text[1][1]
    end
    local rows = {}
    for _, t in ipairs(require("csharp-test-runner.locator").tests(bufnr)) do
      rows[t.method] = t.line
    end
    assert.truthy(by_line[rows.Adds]:find("✓", 1, true))
    assert.truthy(by_line[rows.TheoryMixed]:find("1/2 failed", 1, true))
    assert.truthy(by_line[rows.Skipped]:find("skipped", 1, true))
    local diags = vim.diagnostic.get(bufnr, { namespace = ui.ns })
    assert.equals(3, #diags)
  end)

  it("sends failures to quickfix at the failing line", function()
    config.setup({ quickfix = { enabled = true, open = false } })
    ui.quickfix(assert(mstest.parse(h.read("mstest.trx"))))
    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("CSTest", qf.title)
    assert.equals(3, #qf.items)
    local lines = vim.tbl_map(function(i)
      return i.lnum
    end, qf.items)
    table.sort(lines)
    assert.same({ 12, 19, 28 }, lines)
  end)

  it("replaces its own quickfix list instead of stacking", function()
    config.setup({ quickfix = { enabled = true, open = false } })
    local results = assert(mstest.parse(h.read("mstest.trx")))
    ui.quickfix(results)
    ui.quickfix(results)
    assert.equals(1, vim.fn.getqflist({ nr = "$" }).nr)
  end)

  it("parses build errors into quickfix", function()
    local n = ui.build_errors({
      "/src/A.cs(10,5): error CS1002: ; expected [/src/A.csproj]",
      "/src/A.cs(10,5): error CS1002: ; expected [/src/A.csproj]",
      "Build FAILED.",
    })
    vim.cmd("cclose")
    assert.equals(1, n)
    local item = vim.fn.getqflist()[1]
    assert.equals(10, item.lnum)
    assert.equals("CS1002: ; expected", item.text)
  end)

  it("builds output lines with jump targets for frames", function()
    local r = h.find(assert(mstest.parse(h.read("mstest.trx"))), "RowsMixed (2,False)")
    local lines, jumps = ui.output_lines({ r })
    assert.truthy(lines[1]:find("RowsMixed (2,False)", 1, true))
    assert.truthy(vim.tbl_contains(lines, "Output:"))
    local target
    for _, j in pairs(jumps) do
      if j.file == "/src/MProj/CalcTests.cs" then
        target = j
      end
    end
    assert.equals(28, target.line)
  end)
end)
