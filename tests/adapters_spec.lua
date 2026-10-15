-- Parser and command tests for the xUnit (CTRF) and MSTest (TRX) adapters
-- Fixtures were captured from real xUnit v3 4.0.2 and MSTest 4.3.2 runs on .NET 10

local h = require("tests.helpers")
local xunit = require("csharp-test-runner.adapters.xunit")
local mstest = require("csharp-test-runner.adapters.mstest")

describe("xunit adapter", function()
  local results = assert(xunit.parse(h.read("xunit.ctrf.json")))

  it("parses every test case", function()
    assert.equals(6, #results)
  end)

  it("maps class, method and status", function()
    local r = h.find(results, "Sample.XUnit.CalcTests.FailsEqual")
    assert.equals("Sample.XUnit.CalcTests", r.class)
    assert.equals("FailsEqual", r.method)
    assert.equals("failed", r.status)
    assert.equals("/src/XProj/Calc_tests.cs", r.file)
    assert.equals(8, r.line)
    assert.truthy(r.message:find("Expected: 5", 1, true))
    assert.truthy(r.message:find("\n", 1, true), "message keeps real newlines")
  end)

  it("keeps each theory case separately under the same method", function()
    local pass = h.find(results, "Sample.XUnit.CalcTests.TheoryMixed(n: 1, expected: True)")
    local fail = h.find(results, "Sample.XUnit.CalcTests.TheoryMixed(n: 2, expected: False)")
    assert.equals("TheoryMixed", pass.method)
    assert.equals("passed", pass.status)
    assert.equals("TheoryMixed", fail.method)
    assert.equals("failed", fail.status)
  end)

  it("maps skipped tests", function()
    assert.equals("skipped", h.find(results, "Sample.XUnit.CalcTests.Skipped").status)
  end)

  it("rejects output that is not CTRF", function()
    local r, err = xunit.parse("Build FAILED.")
    assert.is_nil(r)
    assert.is_string(err)
  end)

  it("builds commands for each selection", function()
    local opts = { build = true, extra_args = {} }
    local all = xunit.command("/p/X.csproj", { kind = "project" }, "/tmp/r.json", opts)
    assert.same({ "dotnet", "run", "--project", "/p/X.csproj", "--", "-noColor", "-result-ctrf", "/tmp/r.json" }, all)

    local one = xunit.command("/p/X.csproj", { kind = "method", class = "A.B", method = "M" }, "/tmp/r.json", opts)
    assert.same({ "-method", "A.B.M" }, vim.list_slice(one, #one - 1))

    local cls = xunit.command("/p/X.csproj", { kind = "classes", classes = { "A.B", "A.C" } }, "/tmp/r.json", opts)
    assert.same({ "-class", "A.B", "-class", "A.C" }, vim.list_slice(cls, #cls - 3))

    local nb = xunit.command("/p/X.csproj", { kind = "project" }, "/tmp/r.json", { build = false, extra_args = {} })
    assert.equals("--no-build", nb[5])
  end)
end)

describe("mstest adapter", function()
  local results = assert(mstest.parse(h.read("mstest.trx")))

  it("parses every test case", function()
    assert.equals(6, #results)
  end)

  it("maps class, method, status and duration", function()
    local r = h.find(results, "FailsEqual")
    assert.equals("Sample.MSTest.CalcTests", r.class)
    assert.equals("FailsEqual", r.method)
    assert.equals("failed", r.status)
    assert.is_true(r.duration > 0)
    assert.truthy(r.message:find("expected: 5", 1, true))
    assert.truthy(r.trace:find("CalcTests.cs:line 12", 1, true))
  end)

  it("maps data rows to their method and keeps stdout", function()
    local r = h.find(results, "RowsMixed (2,False)")
    assert.equals("RowsMixed", r.method)
    assert.equals("failed", r.status)
    assert.equals("checking 2", r.stdout)
  end)

  it("maps NotExecuted to skipped", function()
    assert.equals("skipped", h.find(results, "Skipped").status)
  end)

  it("decodes xml entities", function()
    assert.equals([[<a href="x">&lt;'</a>]], mstest.decode("&lt;a href=&quot;x&quot;&gt;&amp;lt;&apos;&lt;/a&gt;"))
    assert.equals("a\r\nb", mstest.decode("a&#xD;&#xA;b"))
  end)

  it("parses durations", function()
    assert.equals(11.2754, mstest.parse_duration("00:00:00.0112754"))
    assert.equals(61500, mstest.parse_duration("00:01:01.5"))
    assert.equals(0, mstest.parse_duration(nil))
  end)

  it("rejects output that is not TRX", function()
    assert.is_nil((mstest.parse("<html/>")))
  end)

  it("builds filters for each selection", function()
    local opts = { build = true, extra_args = {} }
    local one = mstest.command("/p/M.csproj", { kind = "method", class = "A.B", method = "M" }, "/tmp/r.trx", opts)
    assert.same({ "--filter", "FullyQualifiedName=A.B.M" }, vim.list_slice(one, #one - 1))
    local cls = mstest.command("/p/M.csproj", { kind = "classes", classes = { "A.B", "A.C" } }, "/tmp/r.trx", opts)
    assert.same({ "--filter", "ClassName=A.B|ClassName=A.C" }, vim.list_slice(cls, #cls - 1))
    local all = mstest.command("/p/M.csproj", { kind = "project" }, "/tmp/r.trx", opts)
    assert.same({ "dotnet", "test", "/p/M.csproj", "--logger", "trx;LogFileName=/tmp/r.trx" }, all)
  end)
end)
