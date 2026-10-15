-- Finds test methods in C# buffers with tree-sitter

local config = require("csharp-test-runner.config")

local M = {}

---@class CSTestLocation
---@field class string Fully qualified class name (nested classes joined with "+")
---@field method string
---@field line integer 0-based line of the method name
---@field start_row integer 0-based first row of the method (including attributes)
---@field end_row integer 0-based last row of the method

local type_nodes = {
  class_declaration = true,
  record_declaration = true,
  struct_declaration = true,
}

---@param node TSNode
---@param bufnr integer
---@return string
local function text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

---Whether a method has one of the configured test attributes
---@param method TSNode
---@param bufnr integer
---@return boolean
local function is_test(method, bufnr)
  local wanted = {}
  for _, a in ipairs(config.options.test_attributes) do
    wanted[a] = true
  end
  for child in method:iter_children() do
    if child:type() == "attribute_list" then
      for attr in child:iter_children() do
        if attr:type() == "attribute" then
          local name_node = attr:field("name")[1]
          if name_node then
            local name = text(name_node, bufnr):match("([%w_]+)$") or ""
            name = name:gsub("Attribute$", "")
            if wanted[name] then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

---Finds the file-scoped namespace of the file, if any (its classes are siblings, not children)
---@param root TSNode
---@param bufnr integer
---@return string|nil
local function file_scoped_namespace(root, bufnr)
  for child in root:iter_children() do
    if child:type() == "file_scoped_namespace_declaration" then
      local name = child:field("name")[1]
      return name and text(name, bufnr) or nil
    end
  end
  return nil
end

---Builds the fully qualified class name for a method node
---@param method TSNode
---@param bufnr integer
---@param file_ns string|nil
---@return string|nil
local function qualified_class(method, bufnr, file_ns)
  local types, namespaces = {}, {}
  local node = method:parent()
  while node do
    local t = node:type()
    if type_nodes[t] then
      local name = node:field("name")[1]
      if name then
        table.insert(types, 1, text(name, bufnr))
      end
    elseif t == "namespace_declaration" then
      local name = node:field("name")[1]
      if name then
        table.insert(namespaces, 1, text(name, bufnr))
      end
    end
    node = node:parent()
  end
  if #types == 0 then
    return nil
  end
  if file_ns then
    table.insert(namespaces, 1, file_ns)
  end
  local class = table.concat(types, "+")
  if #namespaces > 0 then
    return table.concat(namespaces, ".") .. "." .. class
  end
  return class
end

---Returns every test method in a buffer
---@param bufnr integer
---@return CSTestLocation[]
function M.tests(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c_sharp")
  if not ok or not parser then
    return {}
  end
  local tree = parser:parse()[1]
  if not tree then
    return {}
  end
  local root = tree:root()
  local file_ns = file_scoped_namespace(root, bufnr)
  local found = {}

  local function walk(node)
    for child in node:iter_children() do
      if child:type() == "method_declaration" then
        if is_test(child, bufnr) then
          local name = child:field("name")[1]
          local class = qualified_class(child, bufnr, file_ns)
          if name and class then
            local start_row, _, end_row = child:range()
            table.insert(found, {
              class = class,
              method = text(name, bufnr),
              line = (name:range()),
              start_row = start_row,
              end_row = end_row,
            })
          end
        end
      else
        walk(child)
      end
    end
  end
  walk(root)
  return found
end

---Returns the test method containing the cursor row
---@param bufnr integer
---@param row integer 0-based
---@return CSTestLocation|nil
function M.nearest(bufnr, row)
  for _, t in ipairs(M.tests(bufnr)) do
    if row >= t.start_row and row <= t.end_row then
      return t
    end
  end
  return nil
end

---Returns the distinct classes that contain tests in a buffer
---@param bufnr integer
---@return string[]
function M.classes(bufnr)
  local seen, classes = {}, {}
  for _, t in ipairs(M.tests(bufnr)) do
    if not seen[t.class] then
      seen[t.class] = true
      table.insert(classes, t.class)
    end
  end
  return classes
end

return M
