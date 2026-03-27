local H = dofile("test/helpers.lua")

local T = MiniTest.new_set()

-- ==============================================================================
-- Module loading
-- ==============================================================================

T["loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom.modes.asciidoc")
  end)
end

-- ==============================================================================
-- make_outline: return shape
-- ==============================================================================

T["make_outline"] = MiniTest.new_set()

T["make_outline"]["returns table with required keys"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({}, "test.adoc")
  MiniTest.expect.equality(type(result.tlines), "table")
  MiniTest.expect.equality(type(result.bnodes), "table")
  MiniTest.expect.equality(type(result.levels), "table")
  MiniTest.expect.equality(type(result.use_hash), "boolean")
  MiniTest.expect.equality(type(result.use_close_hash), "boolean")
end

T["make_outline"]["empty buffer produces empty outline"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({}, "empty.adoc")
  MiniTest.expect.equality(#result.tlines, 0)
  MiniTest.expect.equality(#result.bnodes, 0)
  MiniTest.expect.equality(#result.levels, 0)
end

-- ==============================================================================
-- make_outline: heading detection
-- ==============================================================================

T["make_outline"]["level 1 detected"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({ "= Hello" }, "test.adoc")
  MiniTest.expect.equality(#result.tlines, 1)
  MiniTest.expect.equality(result.levels[1], 1)
  MiniTest.expect.equality(result.tlines[1], " · Hello")
  MiniTest.expect.equality(result.bnodes[1], 1)
end

T["make_outline"]["level 2 detected"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({ "== Section" }, "test.adoc")
  MiniTest.expect.equality(result.levels[1], 2)
  MiniTest.expect.equality(result.tlines[1], "   · Section")
end

T["make_outline"]["level 3 detected"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({ "=== Sub" }, "test.adoc")
  MiniTest.expect.equality(result.levels[1], 3)
  MiniTest.expect.equality(result.tlines[1], "     · Sub")
end

T["make_outline"]["level 6 detected"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({ "====== Deep" }, "test.adoc")
  MiniTest.expect.equality(result.levels[1], 6)
  MiniTest.expect.equality(result.tlines[1], "           · Deep")
end

T["make_outline"]["correct bnode line numbers with interleaved content"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = { "= First", "some content", "== Second" }
  local result = adoc.make_outline(lines, "test.adoc")
  MiniTest.expect.equality(#result.bnodes, 2)
  MiniTest.expect.equality(result.bnodes[1], 1)
  MiniTest.expect.equality(result.bnodes[2], 3)
end

T["make_outline"]["block delimiter without space is not a heading"] = function()
  local adoc = require("voom.modes.asciidoc")
  -- AsciiDoc example block delimiters look like `====` with no space/text.
  local lines = { "====", "example block content", "====" }
  local result = adoc.make_outline(lines, "test.adoc")
  MiniTest.expect.equality(#result.tlines, 0)
end

T["make_outline"]["ignores lines with more than 6 equals signs"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = { "======= TooDeep" }
  local result = adoc.make_outline(lines, "test.adoc")
  MiniTest.expect.equality(#result.tlines, 0)
end

T["make_outline"]["strips trailing whitespace from heading text"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({ "== Section   " }, "test.adoc")
  MiniTest.expect.equality(result.tlines[1], "   · Section")
end

-- ==============================================================================
-- make_outline: style preference flags
-- ==============================================================================

T["make_outline"]["use_hash is always true"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({ "= Title" }, "test.adoc")
  MiniTest.expect.equality(result.use_hash, true)
end

T["make_outline"]["use_close_hash is always false"] = function()
  local adoc = require("voom.modes.asciidoc")
  local result = adoc.make_outline({ "= Title" }, "test.adoc")
  MiniTest.expect.equality(result.use_close_hash, false)
end

-- ==============================================================================
-- make_outline: [discrete] handling
-- ==============================================================================

T["make_outline"]["discrete heading is excluded from outline"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = { "= Title", "", "[discrete]", "== Not Structural", "", "== Real Section" }
  local result = adoc.make_outline(lines, "test.adoc")
  MiniTest.expect.equality(#result.tlines, 2)
  MiniTest.expect.equality(result.tlines[1], " · Title")
  MiniTest.expect.equality(result.tlines[2], "   · Real Section")
end

T["make_outline"]["discrete with trailing whitespace still excluded"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = { "[discrete]  ", "== Decorative" }
  local result = adoc.make_outline(lines, "test.adoc")
  MiniTest.expect.equality(#result.tlines, 0)
end

-- ==============================================================================
-- Fixture integration tests
-- ==============================================================================

T["fixture"] = MiniTest.new_set()

T["fixture"]["parses expected heading count"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = H.load_fixture("sample.adoc")
  local result = adoc.make_outline(lines, "sample.adoc")
  -- sample.adoc has 9 structural headings: 1 at level 1, 3 at level 2,
  -- 4 at level 3, 1 at level 6.  The [discrete] heading is excluded.
  MiniTest.expect.equality(#result.tlines, 9)
end

T["fixture"]["first heading is Project Overview at level 1"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = H.load_fixture("sample.adoc")
  local result = adoc.make_outline(lines, "sample.adoc")
  MiniTest.expect.equality(result.tlines[1], " · Project Overview")
  MiniTest.expect.equality(result.levels[1], 1)
  MiniTest.expect.equality(result.bnodes[1], 1)
end

T["fixture"]["discrete heading excluded from results"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = H.load_fixture("sample.adoc")
  local result = adoc.make_outline(lines, "sample.adoc")
  local found = false
  for _, t in ipairs(result.tlines) do
    if t:find("Non-structural Heading", 1, true) then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, false)
end

T["fixture"]["deep heading detected in results"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines = H.load_fixture("sample.adoc")
  local result = adoc.make_outline(lines, "sample.adoc")
  local found = false
  for _, t in ipairs(result.tlines) do
    if t:find("Deep Section", 1, true) then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

-- ==============================================================================
-- new_headline
-- ==============================================================================

T["new_headline"] = MiniTest.new_set()

T["new_headline"]["returns tree_head and body_lines keys"] = function()
  local adoc   = require("voom.modes.asciidoc")
  local result = adoc.new_headline({ use_hash = true, use_close_hash = false }, 1, "")
  MiniTest.expect.equality(type(result.tree_head), "string")
  MiniTest.expect.equality(type(result.body_lines), "table")
end

T["new_headline"]["tree_head is always NewHeadline"] = function()
  local adoc = require("voom.modes.asciidoc")
  local r1 = adoc.new_headline({ use_hash = true, use_close_hash = false }, 1, "")
  local r2 = adoc.new_headline({ use_hash = true, use_close_hash = false }, 3, "")
  MiniTest.expect.equality(r1.tree_head, "NewHeadline")
  MiniTest.expect.equality(r2.tree_head, "NewHeadline")
end

T["new_headline"]["level 1: = NewHeadline"] = function()
  local adoc   = require("voom.modes.asciidoc")
  local result = adoc.new_headline({ use_hash = true, use_close_hash = false }, 1, "")
  MiniTest.expect.equality(result.body_lines[1], "= NewHeadline")
  MiniTest.expect.equality(result.body_lines[2], "")
end

T["new_headline"]["level 2: == NewHeadline"] = function()
  local adoc   = require("voom.modes.asciidoc")
  local result = adoc.new_headline({ use_hash = true, use_close_hash = false }, 2, "")
  MiniTest.expect.equality(result.body_lines[1], "== NewHeadline")
  MiniTest.expect.equality(result.body_lines[2], "")
end

T["new_headline"]["level 3: === NewHeadline"] = function()
  local adoc   = require("voom.modes.asciidoc")
  local result = adoc.new_headline({ use_hash = true, use_close_hash = false }, 3, "")
  MiniTest.expect.equality(result.body_lines[1], "=== NewHeadline")
  MiniTest.expect.equality(result.body_lines[2], "")
end

T["new_headline"]["blank preceding line: no leading blank"] = function()
  local adoc   = require("voom.modes.asciidoc")
  local result = adoc.new_headline({ use_hash = true, use_close_hash = false }, 2, "")
  MiniTest.expect.equality(result.body_lines[1], "== NewHeadline")
end

T["new_headline"]["non-blank preceding line: leading blank prepended"] = function()
  local adoc   = require("voom.modes.asciidoc")
  local result = adoc.new_headline({ use_hash = true, use_close_hash = false }, 2, "some text")
  MiniTest.expect.equality(result.body_lines[1], "")
  MiniTest.expect.equality(result.body_lines[2], "== NewHeadline")
end

T["new_headline"]["whitespace-only preceding line counts as blank"] = function()
  local adoc   = require("voom.modes.asciidoc")
  local result = adoc.new_headline({ use_hash = true, use_close_hash = false }, 1, "   ")
  -- "   " has no %S match, so no leading blank.
  MiniTest.expect.equality(result.body_lines[1], "= NewHeadline")
end

-- ==============================================================================
-- do_body_after_oop
-- ==============================================================================

T["do_body_after_oop"] = MiniTest.new_set()

-- 'cut' operation ------------------------------------------------------------

T["do_body_after_oop"]["cut: inserts blank at non-blank cut point"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "= Alpha", "= Beta" }
  local bnodes = { 1, 2 }
  local levels = { 1, 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "cut", 0,
    0, 1, 0, 1,
    1, 1
  )

  MiniTest.expect.equality(delta, 1)
  MiniTest.expect.equality(lines[2], "")
end

T["do_body_after_oop"]["cut: no blank inserted when cut point is already blank"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "= Alpha", "", "= Beta" }
  local bnodes = { 1, 3 }
  local levels = { 1, 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "cut", 0,
    0, 1, 0, 1,
    2, 1
  )

  MiniTest.expect.equality(delta, 0)
  MiniTest.expect.equality(#lines, 3)
end

T["do_body_after_oop"]["cut: returns early, no heading format changes"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "= Alpha", "", "== Beta" }
  local bnodes = { 1, 3 }
  local levels = { 1, 2 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "cut", 1,
    0, 1, 0, 1,
    2, 1
  )

  MiniTest.expect.equality(delta, 0)
  MiniTest.expect.equality(lines[1], "= Alpha")
  MiniTest.expect.equality(lines[3], "== Beta")
end

-- Promote / demote -----------------------------------------------------------

T["do_body_after_oop"]["demote: == level 2 becomes === level 3"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "", "== Section", "" }
  local bnodes = { 2 }
  local levels = { 3 }  -- target level (caller has already updated levels[])
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "down", 1,
    2, 1, 3, 1,
    0, 0
  )

  MiniTest.expect.equality(lines[2], "=== Section")
  MiniTest.expect.equality(delta, 0)
end

T["do_body_after_oop"]["promote: === level 3 becomes == level 2"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "", "=== Deep", "" }
  local bnodes = { 2 }
  local levels = { 2 }  -- target level
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "up", -1,
    2, 1, 3, 1,
    0, 0
  )

  MiniTest.expect.equality(lines[2], "== Deep")
  MiniTest.expect.equality(delta, 0)
end

-- Paste: level normalisation -------------------------------------------------

T["do_body_after_oop"]["paste: heading prefix adjusted to match target level"] = function()
  local adoc = require("voom.modes.asciidoc")
  -- Pasting a level-2 heading into a level-3 position.
  local lines  = { "", "== Section", "" }
  local bnodes = { 2 }
  local levels = { 3 }  -- target level after paste adjustment
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 1,
    2, 1, 3, 1,
    0, 0
  )

  MiniTest.expect.equality(lines[2], "=== Section")
  MiniTest.expect.equality(delta, 0)
end

-- Blank-line management ------------------------------------------------------

T["do_body_after_oop"]["no blank inserted when heading is already at line 1"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "= Alpha", "" }
  local bnodes = { 1 }
  local levels = { 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    1, 1, 2, 1,
    0, 0
  )

  MiniTest.expect.equality(delta, 0)
  MiniTest.expect.equality(lines[1], "= Alpha")
end

T["do_body_after_oop"]["inserts blank before first heading when non-blank precedes it"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "some text", "= Heading", "" }
  local bnodes = { 2 }
  local levels = { 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    2, 1, 3, 1,
    0, 0
  )

  MiniTest.expect.equality(lines[2], "")
  MiniTest.expect.equality(lines[3], "= Heading")
  MiniTest.expect.equality(delta, 1)
end

-- b_delta integrity ----------------------------------------------------------

T["do_body_after_oop"]["b_delta equals actual net line change"] = function()
  local adoc = require("voom.modes.asciidoc")
  local lines  = { "some text", "= Alpha", "", "= Beta", "" }
  local bnodes = { 2, 4 }
  local levels = { 1, 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local before = #lines
  local delta = adoc.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    2, 1, 5, 2,
    0, 0
  )

  MiniTest.expect.equality(#lines, before + delta)
end

-- ==============================================================================
-- Modes registry integration
-- ==============================================================================

T["modes registry"] = MiniTest.new_set()

T["modes registry"]["get asciidoc returns a module"] = function()
  local modes = require("voom.modes")
  local adoc = modes.get("asciidoc")
  MiniTest.expect.equality(type(adoc), "table")
end

T["modes registry"]["asciidoc module has make_outline function"] = function()
  local modes = require("voom.modes")
  local adoc = modes.get("asciidoc")
  MiniTest.expect.equality(type(adoc.make_outline), "function")
end

return T
