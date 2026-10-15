-- Finds methods and test methods in C# buffers or files with tree-sitter

local config = require("csharp-test-runner.config")

local M = {}

---@class CSTestLocation
---@field class string Fully qualified class name (nested classes joined with "+")
---@field method string
---@field line integer 0-based line of the method name
---@field col integer 0-based column of the method name
---@field start_row integer 0-based first row of the method (including attributes)
---@field end_row integer 0-based last row of the method
---@field is_test boolean Whether the method has a test attribute
---@field kind "method"|"constructor"|"property"|"local_function"
---@field cases integer Test cases known before running: the number of [InlineData]/[DataRow] rows, else 1
---@field in_abstract boolean Declared in an abstract class (an inherited test: it runs under the subclasses)
---@field classes string[] Classes the test runs under: the class itself, or for a test declared in an abstract
---class, every concrete subclass in the same file (the test runner reports inherited tests under those)

---A buffer number, or the text of a file
---@alias CSTestSource integer|string

local type_nodes = {
  class_declaration = true,
  record_declaration = true,
  struct_declaration = true,
  interface_declaration = true,
}

---@param node TSNode
---@param source CSTestSource
---@return string
local function text(node, source)
  return vim.treesitter.get_node_text(node, source)
end

local row_attributes = { InlineData = true, DataRow = true }

---Whether a method has one of the configured test attributes, and how many data rows it declares
---@param method TSNode
---@param source CSTestSource
---@return boolean is_test
---@return integer rows Number of [InlineData]/[DataRow] attributes
local function test_info(method, source)
  local wanted = {}
  for _, a in ipairs(config.options.test_attributes) do
    wanted[a] = true
  end
  local found, rows = false, 0
  for child in method:iter_children() do
    if child:type() == "attribute_list" then
      for attr in child:iter_children() do
        if attr:type() == "attribute" then
          local name_node = attr:field("name")[1]
          if name_node then
            local name = text(name_node, source):match("([%w_]+)$") or ""
            name = name:gsub("Attribute$", "")
            if wanted[name] then
              found = true
            elseif row_attributes[name] then
              rows = rows + 1
            end
          end
        end
      end
    end
  end
  return found, rows
end

---Finds the file-scoped namespace of the file, if any (its classes are siblings, not children)
---@param root TSNode
---@param source CSTestSource
---@return string|nil
local function file_scoped_namespace(root, source)
  for child in root:iter_children() do
    if child:type() == "file_scoped_namespace_declaration" then
      local name = child:field("name")[1]
      return name and text(name, source) or nil
    end
  end
  return nil
end

---Builds the fully qualified name of the type containing a node (or of the node itself, when it is a type)
---@param start TSNode
---@param source CSTestSource
---@param file_ns string|nil
---@return string|nil
local function qualified_class(start, source, file_ns)
  local types, namespaces = {}, {}
  local node = type_nodes[start:type()] and start or start:parent()
  while node do
    local t = node:type()
    if type_nodes[t] then
      local name = node:field("name")[1]
      if name then
        table.insert(types, 1, text(name, source))
      end
    elseif t == "namespace_declaration" then
      local name = node:field("name")[1]
      if name then
        table.insert(namespaces, 1, text(name, source))
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

---Parses a source and returns its root node
---@param source CSTestSource
---@return TSNode|nil
local function root_of(source)
  local ok, parser
  if type(source) == "string" then
    ok, parser = pcall(vim.treesitter.get_string_parser, source, "c_sharp")
  else
    ok, parser = pcall(vim.treesitter.get_parser, source, "c_sharp")
  end
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  return tree and tree:root() or nil
end

---@class CSTestTypeInfo
---@field name string Simple name
---@field fqn string
---@field abstract boolean
---@field bases string[] Simple names of base types

---Collects the types declared in a file with their modifiers and base types
---@param root TSNode
---@param source CSTestSource
---@param file_ns string|nil
---@return table<string, CSTestTypeInfo> by fully qualified name
local function collect_types(root, source, file_ns)
  local types = {}
  local function walk(node)
    for child in node:iter_children() do
      if type_nodes[child:type()] then
        local name_node = child:field("name")[1]
        local fqn = qualified_class(child, source, file_ns)
        if name_node and fqn then
          local info = { name = text(name_node, source), fqn = fqn, abstract = false, bases = {} }
          for part in child:iter_children() do
            if part:type() == "modifier" and text(part, source) == "abstract" then
              info.abstract = true
            elseif part:type() == "base_list" then
              for base in part:iter_children() do
                if base:named() then
                  -- "N.Base<int>" -> "Base"
                  local simple = text(base, source):gsub("%b<>", ""):match("([%w_]+)%s*$")
                  if simple then
                    table.insert(info.bases, simple)
                  end
                end
              end
            end
          end
          types[fqn] = info
        end
      end
      if child:type() ~= "method_declaration" then
        walk(child)
      end
    end
  end
  walk(root)
  return types
end

---Classes a test declared in `fqn` runs under: itself, or for an abstract class its concrete descendants in the file
---@param fqn string
---@param types table<string, CSTestTypeInfo>
---@return string[]
local function runtime_classes(fqn, types)
  local info = types[fqn]
  if not info or not info.abstract then
    return { fqn }
  end
  local concrete, seen = {}, { [info.name] = true }
  local frontier = { info.name }
  while #frontier > 0 do
    local next_frontier = {}
    for _, t in pairs(types) do
      if not seen[t.name] then
        for _, b in ipairs(t.bases) do
          if vim.tbl_contains(frontier, b) then
            seen[t.name] = true
            table.insert(next_frontier, t.name)
            if not t.abstract then
              table.insert(concrete, t.fqn)
            end
            break
          end
        end
      end
    end
    frontier = next_frontier
  end
  table.sort(concrete)
  -- no subclass in this file: keep the declaring class (subclasses in other files are not followed)
  return #concrete > 0 and concrete or { fqn }
end

local member_kinds = {
  method_declaration = "method",
  constructor_declaration = "constructor",
  property_declaration = "property",
}

---Collects members of a source
---@param source CSTestSource
---@param include_other boolean Include constructors and properties (callers can live there), not only methods
---@return CSTestLocation[]
local function collect(source, include_other)
  local root = root_of(source)
  if not root then
    return {}
  end
  local file_ns = file_scoped_namespace(root, source)
  local types = collect_types(root, source, file_ns)
  local runtime = {}
  local found = {}

  local function walk(node)
    for child in node:iter_children() do
      local kind = member_kinds[child:type()]
      if kind and (kind == "method" or include_other) then
        local name = child:field("name")[1]
        local class = qualified_class(child, source, file_ns)
        if name and class then
          local start_row, _, end_row = child:range()
          local line, col = name:range()
          runtime[class] = runtime[class] or runtime_classes(class, types)
          local test, rows = false, 0
          if kind == "method" then
            test, rows = test_info(child, source)
          end
          local entry = {
            class = class,
            method = text(name, source),
            line = line,
            col = col,
            start_row = start_row,
            end_row = end_row,
            is_test = test,
            cases = math.max(rows, 1),
            in_abstract = types[class] ~= nil and types[class].abstract,
            kind = kind,
            classes = runtime[class],
          }
          table.insert(found, entry)
          if include_other then
            -- local functions are their own callers: Visual Studio does not credit their calls to the enclosing test
            local function locals(node)
              for inner in node:iter_children() do
                if inner:type() == "local_function_statement" then
                  local lname = inner:field("name")[1]
                  if lname then
                    local ls, _, le = inner:range()
                    local ll, lc = lname:range()
                    table.insert(found, {
                      class = class,
                      method = text(lname, source),
                      line = ll,
                      col = lc,
                      start_row = ls,
                      end_row = le,
                      is_test = false,
                      cases = 1,
                      in_abstract = false,
                      kind = "local_function",
                      classes = runtime[class],
                    })
                  end
                end
                locals(inner)
              end
            end
            locals(child)
          end
        end
        -- lambdas are attributed to the member that contains them
      elseif not kind then
        walk(child)
      end
    end
  end
  walk(root)
  return found
end

---Returns every method in a source, test or not
---@param source CSTestSource
---@return CSTestLocation[]
function M.methods(source)
  return collect(source, false)
end

---Returns every method, constructor, property and local function in a source (the places a call can come from)
---@param source CSTestSource
---@return CSTestLocation[]
function M.members(source)
  return collect(source, true)
end

---Returns every test method in a source
---@param source CSTestSource
---@return CSTestLocation[]
function M.tests(source)
  return vim.tbl_filter(function(m)
    return m.is_test
  end, M.methods(source))
end

---Returns the innermost method in a list that contains a row
---@param list CSTestLocation[]
---@param row integer 0-based
---@return CSTestLocation|nil
local function containing(list, row)
  local best
  for _, m in ipairs(list) do
    if row >= m.start_row and row <= m.end_row then
      if not best or (m.end_row - m.start_row) < (best.end_row - best.start_row) then
        best = m
      end
    end
  end
  return best
end

---Returns the test method containing a row
---@param source CSTestSource
---@param row integer 0-based
---@return CSTestLocation|nil
function M.nearest(source, row)
  return containing(M.tests(source), row)
end

---Returns the method (test or not) containing a row
---@param source CSTestSource
---@param row integer 0-based
---@return CSTestLocation|nil
function M.method_at(source, row)
  return containing(M.methods(source), row)
end

---Returns the distinct classes that tests in a source run under
---@param source CSTestSource
---@return string[]
function M.classes(source)
  local seen, classes = {}, {}
  for _, t in ipairs(M.tests(source)) do
    for _, c in ipairs(t.classes) do
      if not seen[c] then
        seen[c] = true
        table.insert(classes, c)
      end
    end
  end
  return classes
end

---Result keys a test location stands for (one per runtime class)
---@param t CSTestLocation
---@return string[]
function M.keys(t)
  local keys = {}
  for _, c in ipairs(t.classes) do
    table.insert(keys, require("csharp-test-runner.result").key(c, t.method))
  end
  return keys
end

return M
