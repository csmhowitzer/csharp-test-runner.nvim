-- Shared helpers for specs

local M = {}

M.fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fixtures"

---@param name string
---@return string
function M.read(name)
  local fd = assert(io.open(M.fixtures .. "/" .. name, "r"))
  local text = fd:read("*a")
  fd:close()
  return text
end

---Loads a fixture into a C# buffer
---@param name string
---@return integer bufnr
function M.cs_buffer(name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(M.read(name), "\n"))
  vim.bo[bufnr].filetype = "cs"
  return bufnr
end

---@param results CSTestResult[]
---@param name string
---@return CSTestResult|nil
function M.find(results, name)
  for _, r in ipairs(results) do
    if r.name == name then
      return r
    end
  end
end

return M
