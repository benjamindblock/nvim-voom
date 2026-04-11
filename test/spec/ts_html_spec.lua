-- Tests for the Treesitter HTML query definition.

local H = dofile("test/helpers.lua")

local T = MiniTest.new_set()

local function get_mode()
  return require("voom.ts").build_mode("html")
end

-- ==============================================================================
-- Smoke tests
-- ==============================================================================

T["html ts mode"] = MiniTest.new_set()

T["html ts mode"]["query module loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom.ts.queries.html")
  end)
end

T["html ts mode"]["build_mode returns table with make_outline"] = function()
  local mode = get_mode()
  MiniTest.expect.equality(type(mode), "table")
  MiniTest.expect.equality(type(mode.make_outline), "function")
end

-- ==============================================================================
-- Outline extraction from sample.html
-- ==============================================================================

T["html ts mode"]["sample.html"] = MiniTest.new_set()

local lines = nil
local result = nil

T["html ts mode"]["sample.html"]["before"] = function()
  lines = H.load_fixture("sample.html")
  result = get_mode().make_outline(lines, "sample.html")
end

T["html ts mode"]["sample.html"]["produces six entries"] = function()
  -- h1 Main Title, h2 First Section, h3 Subsection,
  -- h2 Second Section, h3 Another Sub, h4 Deep Heading
  MiniTest.expect.equality(#result.bnodes, 6)
end

T["html ts mode"]["sample.html"]["levels match heading rank"] = function()
  MiniTest.expect.equality(result.levels, { 1, 2, 3, 2, 3, 4 })
end

T["html ts mode"]["sample.html"]["line numbers are correct"] = function()
  -- h1=3, h2=5, h3=7, h2=9, h3=10, h4=11
  MiniTest.expect.equality(result.bnodes, { 3, 5, 7, 9, 10, 11 })
end

T["html ts mode"]["sample.html"]["display names are correct"] = function()
  MiniTest.expect.equality(result.tlines[1]:find("Main Title",      1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[2]:find("First Section",   1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[3]:find("Subsection",      1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[4]:find("Second Section",  1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[5]:find("Another Sub",     1, true) ~= nil, true)
  MiniTest.expect.equality(result.tlines[6]:find("Deep Heading",    1, true) ~= nil, true)
end

-- ==============================================================================
-- Edge cases
-- ==============================================================================

T["html ts mode"]["edge cases"] = MiniTest.new_set()

T["html ts mode"]["edge cases"]["empty document"] = function()
  local r = get_mode().make_outline({}, "empty.html")
  MiniTest.expect.equality(#r.bnodes, 0)
end

T["html ts mode"]["edge cases"]["no headings"] = function()
  local r = get_mode().make_outline({ "<p>Hello</p>" }, "flat.html")
  MiniTest.expect.equality(#r.bnodes, 0)
end

return T
