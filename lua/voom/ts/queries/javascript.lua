-- Treesitter query definition for JavaScript outlines.
--
-- Captures class declarations, function declarations, method definitions,
-- and arrow/function expressions assigned to named variables.

local M = {}

M.lang = "javascript"

-- We capture:
--   • class_declaration         — class Foo { ... }
--   • function_declaration      — function bar() { ... }
--   • method_definition         — methods inside class bodies
--   • variable_declarator nodes whose value is an arrow_function or
--     function_expression       — const fn = () => {} / const fn = function() {}
--
-- The variable_declarator query needs lexical_declaration as an anchor
-- because bare variable_declarator isn't a top-level statement.
M.query_string = [[
(class_declaration) @class
(function_declaration) @function
(method_definition) @method
(lexical_declaration
  (variable_declarator
    value: (arrow_function)) @arrow_var)
(lexical_declaration
  (variable_declarator
    value: (function_expression)) @func_var)
]]

-- ===========================================================================
-- Private helpers
-- ===========================================================================

local CONTAINER_TYPES = {
  class_declaration = true,
  function_declaration = true,
  method_definition = true,
  arrow_function = true,
  function_expression = true,
}

local function structural_depth(node)
  local count = 0
  local parent = node:parent()
  while parent do
    if CONTAINER_TYPES[parent:type()] then
      count = count + 1
    end
    parent = parent:parent()
  end
  return count
end

local function find_child(node, child_type, bufnr)
  for i = 0, node:child_count() - 1 do
    local child = node:child(i)
    if child:type() == child_type then
      return vim.treesitter.get_node_text(child, bufnr)
    end
  end
  return "?"
end

-- ===========================================================================
-- extract
-- ===========================================================================

function M.extract(captures, query, bufnr)
  local entries = {}

  for _, cap in ipairs(captures) do
    local capture_name = query.captures[cap.id]
    local node = cap.node
    local start_row = node:range()
    local lnum = start_row + 1

    local name, level

    if capture_name == "class" then
      name = "class " .. find_child(node, "identifier", bufnr)
      level = structural_depth(node) + 1

    elseif capture_name == "function" then
      name = "function " .. find_child(node, "identifier", bufnr)
      level = structural_depth(node) + 1

    elseif capture_name == "method" then
      -- Method name is a property_identifier child.
      local mname = find_child(node, "property_identifier", bufnr)
      name = mname .. "()"
      level = structural_depth(node) + 1

    elseif capture_name == "arrow_var" or capture_name == "func_var" then
      -- variable_declarator: name is the identifier child
      local vname = find_child(node, "identifier", bufnr)
      name = vname .. "()"
      level = structural_depth(node) + 1

    else
      goto continue
    end

    table.insert(entries, { level = level, name = name, lnum = lnum })

    ::continue::
  end

  return entries
end

-- ===========================================================================
-- outline_state
-- ===========================================================================

function M.outline_state(_entries, _lines)
  return { use_hash = false, use_close_hash = false }
end

return M
