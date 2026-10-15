-- Project discovery and framework detection

local h = require("tests.helpers")
local config = require("csharp-test-runner.config")
local project = require("csharp-test-runner.project")

describe("project", function()
  before_each(function()
    config.setup()
  end)

  it("detects xunit v3 and mstest", function()
    assert.equals("xunit", project.detect_framework(h.read("XProj.csproj")))
    assert.equals("mstest", project.detect_framework(h.read("MProj.csproj")))
    assert.equals("mstest", project.detect_framework('<Project Sdk="MSTest.Sdk/3.6.0">'))
  end)

  it("ignores xunit v2 and non-test projects", function()
    assert.is_nil(project.detect_framework('<PackageReference Include="xunit" Version="2.9.0" />'))
    assert.is_nil(project.detect_framework('<Project Sdk="Microsoft.NET.Sdk"></Project>'))
  end)

  it("honors framework overrides", function()
    config.setup({ framework_overrides = { ["Weird.csproj"] = "xunit" } })
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "<Project/>" }, dir .. "/Weird.csproj")
    local p = assert(project.load(dir .. "/Weird.csproj"))
    assert.equals("xunit", p.framework)
  end)

  it("finds the owning project of a file and checks containment", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/Tests/Sub", "p")
    vim.fn.writefile(vim.split(h.read("MProj.csproj"), "\n"), dir .. "/Tests/Tests.csproj")
    local p = assert(project.for_file(dir .. "/Tests/Sub/FooTests.cs"))
    assert.equals("Tests", p.name)
    assert.equals("mstest", p.framework)
    assert.is_true(project.contains(p, dir .. "/Tests/Sub/FooTests.cs"))
    assert.is_false(project.contains(p, dir .. "/TestsOther/x.cs"))
  end)

  it("lists test projects under a root, skipping bin and obj", function()
    local dir = vim.fn.tempname()
    for _, d in ipairs({ "A", "B", "C", "A/bin/Debug" }) do
      vim.fn.mkdir(dir .. "/" .. d, "p")
    end
    vim.fn.writefile(vim.split(h.read("XProj.csproj"), "\n"), dir .. "/A/A.csproj")
    vim.fn.writefile(vim.split(h.read("MProj.csproj"), "\n"), dir .. "/B/B.csproj")
    vim.fn.writefile({ '<Project Sdk="Microsoft.NET.Sdk"/>' }, dir .. "/C/C.csproj")
    vim.fn.writefile(vim.split(h.read("XProj.csproj"), "\n"), dir .. "/A/bin/Debug/Copy.csproj")
    local names = vim.tbl_map(function(p)
      return p.name
    end, project.all_under(dir))
    assert.same({ "A", "B" }, names)
  end)
end)

describe("config keymaps", function()
  it("are off by default", function()
    assert.is_false(config.setup().keymaps)
  end)

  it("use lowercase <leader>t defaults when enabled", function()
    local km = config.setup({ keymaps = true }).keymaps
    assert.equals("<leader>ty", km.smart)
    assert.equals("<leader>ta", km.all)
    for _, lhs in pairs(km) do
      assert.truthy(lhs:match("^<leader>t%l$"), lhs)
    end
  end)

  it("override individual keys and disable others", function()
    local km = config.setup({ keymaps = { smart = "<leader>cy", nearest = false } }).keymaps
    assert.equals("<leader>cy", km.smart)
    assert.is_false(km.nearest)
    assert.equals("<leader>tf", km.file)
  end)
end)
