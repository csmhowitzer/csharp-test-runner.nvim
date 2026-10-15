-- Virtual text, diagnostics, quickfix and the failure output window

local config = require("csharp-test-runner.config")
local locator = require("csharp-test-runner.locator")
local result = require("csharp-test-runner.result")
local state = require("csharp-test-runner.state")

local M = {}

M.ns = vim.api.nvim_create_namespace("csharp-test-runner")

local QF_TITLE = "CSTest"

local hl_for = {
  passed = "CSTestPassed",
  failed = "CSTestFailed",
  skipped = "CSTestSkipped",
  running = "CSTestRunning",
}

---Defines highlight groups (linked by default so colorschemes apply)
function M.define_highlights()
  vim.api.nvim_set_hl(0, "CSTestPassed", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "CSTestFailed", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "CSTestSkipped", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "CSTestRunning", { link = "Comment", default = true })
end

---Virtual text for one method
---@param agg CSTestAggregate
---@return string
function M.label(agg)
  local opts = config.options
  local icon = opts.icons[agg.status]
  if agg.status == "running" then
    return icon .. " running"
  end
  local parts = { icon }
  if agg.status == "failed" and agg.total > 1 then
    table.insert(parts, string.format("%d/%d failed", agg.failed, agg.total))
  elseif agg.status == "skipped" then
    table.insert(parts, "skipped")
  elseif agg.total > 1 then
    table.insert(parts, string.format("%d cases", agg.total))
  end
  if opts.show_duration and agg.status ~= "skipped" then
    table.insert(parts, result.format_duration(agg.duration))
  end
  return table.concat(parts, " ")
end

---First informative line of a message (skips MSTest's "Test method X threw exception:" preamble)
---@param msg string|nil
---@return string
local function first_line(msg)
  for line in vim.gsplit(msg or "", "\r?\n") do
    line = vim.trim(line)
    if line ~= "" and not line:match("^Test method .* threw exception:$") then
      return line
    end
  end
  return "test failed"
end

---Full message without blank lines, for diagnostics
---@param msg string|nil
---@return string
local function full_message(msg)
  local lines = {}
  for line in vim.gsplit(msg or "", "\r?\n") do
    line = vim.trim(line)
    if line ~= "" and not line:match("^Test method .* threw exception:$") then
      table.insert(lines, line)
    end
  end
  return #lines > 0 and table.concat(lines, "\n") or "test failed"
end

---Draws results for every test in a buffer
---@param bufnr integer
function M.render(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local diags = {}
  for _, t in ipairs(locator.tests(bufnr)) do
    local agg = state.get(t.class, t.method)
    if agg then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, t.line, 0, {
        virt_text = { { "  " .. M.label(agg), hl_for[agg.status] } },
        hl_mode = "combine",
      })
      if agg.status == "failed" then
        local msg
        for _, c in ipairs(agg.cases) do
          if c.status == "failed" then
            msg = full_message(c.message)
            break
          end
        end
        if agg.total > 1 then
          msg = string.format("%d/%d cases failed: %s", agg.failed, agg.total, msg)
        end
        table.insert(diags, {
          lnum = t.line,
          col = 0,
          severity = vim.diagnostic.severity.ERROR,
          source = "cstest",
          message = msg,
        })
      end
    end
  end
  if config.options.diagnostics then
    vim.diagnostic.set(M.ns, bufnr, diags)
  else
    vim.diagnostic.reset(M.ns, bufnr)
  end
end

---Redraws every loaded C# buffer
function M.render_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "cs" then
      M.render(bufnr)
    end
  end
end

---Removes all marks and diagnostics
function M.clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
      vim.diagnostic.reset(M.ns, bufnr)
    end
  end
end

---Writes a list to quickfix, replacing our previous list instead of stacking new ones
---@param items table[]
local function set_qf(items)
  local action = vim.fn.getqflist({ title = 0 }).title == QF_TITLE and "r" or " "
  vim.fn.setqflist({}, action, { title = QF_TITLE, items = items })
end

---Publishes failures of the last run to quickfix
---@param results CSTestResult[]
function M.quickfix(results)
  if not config.options.quickfix.enabled then
    return
  end
  local items = {}
  for _, r in ipairs(results) do
    if r.status == "failed" then
      local file, line = result.location(r)
      table.insert(items, {
        filename = file,
        lnum = line or 1,
        col = 1,
        type = "E",
        text = r.name .. ": " .. first_line(r.message),
      })
    end
  end
  local ours = vim.fn.getqflist({ title = 0 }).title == QF_TITLE
  if #items == 0 then
    if ours then
      set_qf({})
      vim.cmd("cclose")
    end
    return
  end
  set_qf(items)
  if config.options.quickfix.open then
    vim.cmd("botright copen")
    vim.cmd("wincmd p")
  end
end

---Publishes build errors to quickfix
---@param output string[] Combined stdout/stderr of the run
---@return integer count
function M.build_errors(output)
  local items, seen = {}, {}
  for _, line in ipairs(output) do
    local file, lnum, col, code, msg = line:match("^%s*(.-)%((%d+),(%d+)%): error (%w+): (.-)%s*%[[^%]]*%]%s*$")
    if not file then
      file, lnum, col, code, msg = line:match("^%s*(.-)%((%d+),(%d+)%): error (%w+): (.*)$")
    end
    if file and not seen[line] then
      seen[line] = true
      table.insert(items, {
        filename = file,
        lnum = tonumber(lnum),
        col = tonumber(col),
        type = "E",
        text = code .. ": " .. msg,
      })
    end
  end
  if #items > 0 then
    set_qf(items)
    vim.cmd("botright copen")
    vim.cmd("wincmd p")
  end
  return #items
end

---Builds the lines shown in the output window for a set of cases
---@param cases CSTestResult[]
---@return string[] lines
---@return table<integer, { file: string, line: integer }> jumps 1-based line -> location
function M.output_lines(cases)
  local lines, jumps = {}, {}
  local icons = config.options.icons
  for i, c in ipairs(cases) do
    if i > 1 then
      vim.list_extend(lines, { "", string.rep("─", 60), "" })
    end
    table.insert(lines, string.format("%s %s (%s)", icons[c.status], c.name, result.format_duration(c.duration)))
    if c.message and c.message ~= "" then
      table.insert(lines, "")
      for l in vim.gsplit(c.message, "\r?\n") do
        table.insert(lines, "  " .. l)
      end
    end
    local frames = result.parse_trace(c.trace)
    if #frames > 0 then
      vim.list_extend(lines, { "", "Stack trace:" })
      for _, f in ipairs(frames) do
        table.insert(lines, "  " .. f.text)
        if f.file then
          table.insert(lines, string.format("    --> %s:%d", f.file, f.line))
          jumps[#lines] = { file = f.file, line = f.line }
        end
      end
    end
    if c.stdout and c.stdout ~= "" then
      vim.list_extend(lines, { "", "Output:" })
      for l in vim.gsplit(c.stdout, "\r?\n") do
        table.insert(lines, "  " .. l)
      end
    end
  end
  return lines, jumps
end

---Opens the output for some cases in a float (or a split)
---@param cases CSTestResult[]
---@param title string
---@param as_split boolean|nil
function M.open_output(cases, title, as_split)
  local lines, jumps = M.output_lines(cases)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "cstest-output"

  local win
  if as_split then
    vim.cmd("botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.min(#lines + 1, math.floor(vim.o.lines * 0.4)))
  else
    local fo = config.options.float
    local width = math.floor(vim.o.columns * fo.width)
    local height = math.min(math.max(#lines, 3), math.floor(vim.o.lines * fo.height))
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = fo.border,
      title = " " .. title .. " ",
      title_pos = "center",
      footer = " <CR> jump  s split  q close ",
      footer_pos = "center",
    })
  end
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true

  -- highlight the status lines and jump targets
  for i, l in ipairs(lines) do
    for status, icon in pairs(config.options.icons) do
      if vim.startswith(l, icon .. " ") then
        vim.api.nvim_buf_add_highlight(buf, M.ns, hl_for[status], i - 1, 0, -1)
      end
    end
    if jumps[i] then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "Directory", i - 1, 0, -1)
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("s", function()
    close()
    M.open_output(cases, title, true)
  end)
  map("<CR>", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    -- a frame line jumps through its location line just below it
    local target = jumps[row] or jumps[row + 1]
    if not target then
      return
    end
    close()
    if vim.fn.filereadable(target.file) == 0 then
      vim.notify("cstest: " .. target.file .. " not found", vim.log.levels.WARN)
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(target.file))
    pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
    vim.cmd("normal! zz")
  end)
end

return M
