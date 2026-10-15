# csharp-test-runner.nvim

Run C# tests from Neovim and see results where the tests are: a green `✓ 12ms` or a red `✗ 340ms` beside each test method, failures as diagnostics and in the quickfix list, and a window with the full failure detail.

Supports **xUnit v3** and **MSTest**, each through the runner that framework actually needs on .NET 10, picked automatically per project.

## ✨ Features

- 🎯 **Run nearest / file / project / all**: the test under the cursor, every class in the file, the file's test project, or every test project in the solution
- ✅ **Inline results**: `✓ 12ms`, `✗ 340ms`, `✗ 1/3 failed` for theories and DataRows, `○ skipped`, `⋯ running`
- 🩺 **Diagnostics** on failed test methods (`]d` / `[d` work as usual)
- 📋 **Quickfix** list of failures, pointing at the **failing assertion line**, opened automatically
- 🔍 **Failure detail window**: message, stack trace and captured output. `<CR>` on a frame jumps to it
- 👀 **Watch mode**: rerun the file (or project) each time a buffer is saved
- 🧪 **Test counts on production methods**: `19 tests` at the end of each method that tests call, becoming `16 ✓ | 3 ✗` once they have run, through LSP references (opt-in)
- ▶️ **Run from production code**: `<leader>ty` on a production method runs the tests that call it
- 🧱 **Build errors** go to quickfix, and the previous results stay visible
- 🔎 **Automatic framework detection** from the `.csproj`
- 🏥 `:checkhealth csharp-test-runner`

## 🔧 How it runs tests

| Framework | Detected by | Command | Report |
|---|---|---|---|
| xUnit v3 | `PackageReference Include="xunit.v3"` | `dotnet run --project X -- -result-ctrf <tmp>` | CTRF (JSON) |
| MSTest | `MSTest.*` package or `MSTest.Sdk` | `dotnet test X --logger trx;LogFileName=<tmp>` | TRX (XML) |

xUnit v3 projects run on Microsoft.Testing.Platform, which the .NET 10 SDK will not run through `dotnet test` in VSTest mode, so they are launched with `dotnet run`. MSTest (VSTest) projects use `dotnet test`. Both commands run from the project directory, and the report is written to a temp file that is removed after parsing.

Test methods are found with tree-sitter (`[Fact]`, `[Theory]`, `[TestMethod]`, `[DataTestMethod]`, configurable), including `async Task` tests, nested classes and file-scoped namespaces.

## 📦 Installation

Requires Neovim 0.10+, the .NET SDK on `PATH`, and the `c_sharp` tree-sitter parser (`:TSInstall c_sharp`).

**lazy.nvim**

```lua
{
  "csmhowitzer/csharp-test-runner.nvim",
  ft = "cs",
  cmd = "CSTest",
  config = function()
    require("csharp-test-runner").setup({ keymaps = true })
  end,
}
```

Local development:

```lua
{
  dir = "~/plugins/csharp-test-runner.nvim",
  name = "csharp-test-runner",
  ft = "cs",
  cmd = "CSTest",
  build = ":helptags doc",
  config = function()
    require("csharp-test-runner").setup({ keymaps = true })
  end,
}
```

**packer.nvim**

```lua
use({
  "csmhowitzer/csharp-test-runner.nvim",
  config = function()
    require("csharp-test-runner").setup()
  end,
})
```

**vim-plug**

```vim
Plug 'csmhowitzer/csharp-test-runner.nvim'
lua require("csharp-test-runner").setup()
```

## 🚀 Usage

| Command | Keymap (`keymaps = true`) | Does |
|---|---|---|
| `:CSTest smart` | `<leader>ty` | Run the test method under the cursor, or the whole file when the cursor is not inside a test method |
| `:CSTest nearest` | `<leader>tn` | Run the test method under the cursor (all theory/DataRow cases) |
| `:CSTest file` | `<leader>tf` | Run every test class in the current file |
| `:CSTest project` | `<leader>tp` | Run the current file's test project |
| `:CSTest all` | `<leader>ta` | Run every xUnit v3 / MSTest project under the solution root, one after another |
| `:CSTest output` | `<leader>to` | Show failure detail for the test under the cursor (or every failure of the last run) |
| `:CSTest watch` | `<leader>tw` | Toggle run-on-save for the current buffer |
| `:CSTest stop` | `<leader>ts` | Stop the active run |
| `:CSTest covering` | `<leader>tl` | List the tests covering the production method under the cursor (location list, failures first) |
| `:CSTest coverage` | `<leader>tc` | Toggle test counts on production methods |
| `:CSTest clear` |  | Clear all results, marks and the CSTest quickfix list |

`:CSTest` with no argument runs `smart`. In production code (a file outside any test project), `smart` runs the tests that call the method under the cursor, or that call any method in the file when the cursor is outside a method. Starting a new run cancels one that is still going.

In the output window: `<CR>` on a stack frame (or its `-->` line) jumps to that file and line, `s` reopens the output in a split, and `q` / `<Esc>` closes it.

## 🧪 Test counts on production methods

With `coverage = { enabled = true }`, each production method that tests call gets its counts at the end of its line, next to your LSP code lens if you show one:

```
public Option<T> Some(T value)   12 tests      (before any covering test has run)
public Option<T> Some(T value)   11 ✓ | 1 ✗    (after)
```

- Counts come from your language server's **references** (Roslyn, via roslyn.nvim, or any server with `textDocument/references`). References inside xUnit v3 / MSTest projects are mapped to the test method that contains them.
- They are **direct** only: a test that reaches the method through another method is not counted (yet).
- Before any covering test has run, the total is shown (`12 tests`). Once results exist only they are shown: passed, failed, and skipped or running when there are any.
- Requests run in the background a few at a time (`coverage.concurrency`) when a file is shown and after it is saved. Test runs only redraw the numbers. With roslyn.nvim, counting waits until the solution has finished loading.
- Code lens (e.g. LazyVim's `<leader>cC`) is unaffected. The counts are separate marks.

## ⚙️ Configuration

Defaults:

```lua
require("csharp-test-runner").setup({
  build = true,                 -- false adds --no-build
  icons = { passed = "✓", failed = "✗", skipped = "○", running = "⋯" },
  show_duration = true,
  diagnostics = true,
  quickfix = { enabled = true, open = true },
  watch_scope = "file",         -- or "project"
  test_attributes = { "Fact", "Theory", "TestMethod", "DataTestMethod" },
  framework_overrides = {},     -- { ["Odd.Tests.csproj"] = "xunit" }
  extra_args = { xunit = {}, mstest = {} },
  float = { border = "rounded", width = 0.8, height = 0.6 },
  coverage = { enabled = false, concurrency = 4 },
  keymaps = false,              -- true for the defaults above, or a table to override some
  debug = false,                -- notify the command of every run
})
```

Override individual keymaps (others keep their defaults, `false` disables one):

```lua
require("csharp-test-runner").setup({
  keymaps = { smart = "<leader>cy", nearest = false },
})
```

### Highlights

| Group | Default link |
|---|---|
| `CSTestPassed` | `DiagnosticOk` |
| `CSTestFailed` | `DiagnosticError` |
| `CSTestSkipped` | `DiagnosticWarn` |
| `CSTestRunning` | `Comment` |
| `CSTestCoverage` | `LspCodeLens` |

## 🧩 API

```lua
local cst = require("csharp-test-runner")
cst.run_smart()
cst.run_nearest()
cst.run_file(bufnr?)
cst.run_project(bufnr?)
cst.run_all()
cst.output(as_split?)
cst.toggle_watch(bufnr?)
cst.list_covering()
cst.toggle_coverage()
cst.clear()
```

## 💡 Examples

Rerun the whole project on every save of a test file:

```lua
require("csharp-test-runner").setup({ keymaps = true, watch_scope = "project" })
```

Skip the build when iterating on a test you just built:

```lua
require("csharp-test-runner").setup({ build = false })
```

Pass extra runner arguments, e.g. an xUnit trait filter:

```lua
require("csharp-test-runner").setup({ extra_args = { xunit = { "-trait-", "Category=Integration" } } })
```

## 🩹 Troubleshooting

- **"does not reference xunit.v3 or MSTest"**: the nearest `.csproj` isn't a supported test project. xUnit v2 is not supported. Use `framework_overrides` if detection is wrong.
- **No marks appear**: check `:checkhealth csharp-test-runner`. The `c_sharp` parser is required, and test methods need one of `test_attributes`.
- **"run failed"**: the build failed (errors are in quickfix) or the runner printed no report. Set `debug = true` to see the exact command and run it in a terminal.
- **`Console.WriteLine` output is missing for xUnit**: xUnit v3 does not capture console output by default. Use `ITestOutputHelper`.
- **No test counts on production methods**: counts need `coverage.enabled`, an attached language server with references, and (with roslyn.nvim) a fully loaded solution. Only methods called directly from test methods get counts.
- **Runs are slow**: most of the time is the build. `build = false` skips it when nothing changed.

## 🧪 Development

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua', sequential = true }"
```

The fixtures in `tests/fixtures` are real CTRF and TRX reports, captured from xUnit v3 4.0.2 and MSTest 4.3.2 on .NET 10.
