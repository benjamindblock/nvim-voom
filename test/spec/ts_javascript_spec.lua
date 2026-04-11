-- Tests for the Treesitter JavaScript query definition.

local H = dofile("test/helpers.lua")

local T = MiniTest.new_set()

local function get_mode()
  return require("voom.ts").build_mode("javascript")
end

-- ==============================================================================
-- Smoke tests
-- ==============================================================================

T["javascript ts mode"] = MiniTest.new_set()

T["javascript ts mode"]["query module loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom.ts.queries.javascript")
  end)
end

T["javascript ts mode"]["build_mode returns table with make_outline"] = function()
  local mode = get_mode()
  MiniTest.expect.equality(type(mode), "table")
  MiniTest.expect.equality(type(mode.make_outline), "function")
end

-- ==============================================================================
-- Outline extraction from sample.js
-- ==============================================================================

T["javascript ts mode"]["sample.js"] = MiniTest.new_set()

local lines = nil
local result = nil

T["javascript ts mode"]["sample.js"]["before"] = function()
  lines = H.load_fixture("sample.js")
  result = get_mode().make_outline(lines, "sample.js")
end

T["javascript ts mode"]["sample.js"]["produces six entries"] = function()
  -- class Animal, speak(), run(), greet, helper, util
  MiniTest.expect.equality(#result.bnodes, 6)
end

T["javascript ts mode"]["sample.js"]["levels are correct"] = function()
  -- Animal(1), speak(2), run(2), greet(1), helper(1), util(1)
  MiniTest.expect.equality(result.levels, { 1, 2, 2, 1, 1, 1 })
end

T["javascript ts mode"]["sample.js"]["line numbers are correct"] = function()
  -- Animal=1, speak=2, run=6, greet=11, helper=15, util=19
  MiniTest.expect.equality(result.bnodes, { 1, 2, 6, 11, 15, 19 })
end

T["javascript ts mode"]["sample.js"]["display names are correct"] = function()
  MiniTest.expect.equality(result.tlines[1]:find("class Animal",    1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[2]:find("speak()",         1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[3]:find("run()",           1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[4]:find("function greet",  1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[5]:find("helper()",        1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[6]:find("util()",          1, true) ~= nil, true)
end

-- ==============================================================================
-- Edge cases
-- ==============================================================================

T["javascript ts mode"]["edge cases"] = MiniTest.new_set()

T["javascript ts mode"]["edge cases"]["empty document"] = function()
  local r = get_mode().make_outline({}, "empty.js")
  MiniTest.expect.equality(#r.bnodes, 0)
end

T["javascript ts mode"]["edge cases"]["no definitions"] = function()
  local r = get_mode().make_outline({ 'console.log("hi");' }, "flat.js")
  MiniTest.expect.equality(#r.bnodes, 0)
end

return T
