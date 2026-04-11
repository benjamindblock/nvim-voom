local H = dofile("test/helpers.lua")

local T = MiniTest.new_set()

-- ==============================================================================
-- Module loading
-- ==============================================================================

T["loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom.ts").build_mode("markdown")
  end)
end

-- ==============================================================================
-- make_outline: return shape
-- ==============================================================================

T["make_outline"] = MiniTest.new_set()

T["make_outline"]["returns table with required keys"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local result = md.make_outline({}, "test.md")
  MiniTest.expect.equality(type(result.tlines), "table")
  MiniTest.expect.equality(type(result.bnodes), "table")
  MiniTest.expect.equality(type(result.levels), "table")
  MiniTest.expect.equality(type(result.use_hash), "boolean")
  MiniTest.expect.equality(type(result.use_close_hash), "boolean")
end

T["make_outline"]["empty buffer produces empty outline"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local result = md.make_outline({}, "empty.md")
  MiniTest.expect.equality(#result.tlines, 0)
  MiniTest.expect.equality(#result.bnodes, 0)
  MiniTest.expect.equality(#result.levels, 0)
end

-- ==============================================================================
-- make_outline: hash-style headings
-- ==============================================================================

T["make_outline"]["hash level 1 detected"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local result = md.make_outline({ "# Hello" }, "test.md")
  MiniTest.expect.equality(#result.tlines, 1)
  MiniTest.expect.equality(result.levels[1], 1)
  MiniTest.expect.equality(result.tlines[1], " · Hello")
  MiniTest.expect.equality(result.bnodes[1], 1)
end

T["make_outline"]["hash level 2 detected"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local result = md.make_outline({ "## Section" }, "test.md")
  MiniTest.expect.equality(result.levels[1], 2)
  MiniTest.expect.equality(result.tlines[1], "   · Section")
end

T["make_outline"]["hash level 3 detected"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local result = md.make_outline({ "### Sub" }, "test.md")
  MiniTest.expect.equality(result.levels[1], 3)
  MiniTest.expect.equality(result.tlines[1], "     · Sub")
end

T["make_outline"]["hash strips closing hashes"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local result = md.make_outline({ "## Section ##" }, "test.md")
  MiniTest.expect.equality(result.tlines[1], "   · Section")
end

T["make_outline"]["hash correct bnode line numbers"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- Headings at lines 1 and 3; line 2 is non-heading content.
  local lines = { "# First", "some content", "## Second" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(#result.bnodes, 2)
  MiniTest.expect.equality(result.bnodes[1], 1)
  MiniTest.expect.equality(result.bnodes[2], 3)
end

-- ==============================================================================
-- make_outline: underline-style headings
-- ==============================================================================

T["make_outline"]["underline level 1 with ==="] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = { "Title", "=====" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(#result.tlines, 1)
  MiniTest.expect.equality(result.levels[1], 1)
  MiniTest.expect.equality(result.tlines[1], " · Title")
  MiniTest.expect.equality(result.bnodes[1], 1)
end

T["make_outline"]["underline level 2 with ---"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = { "Section", "-------" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(result.levels[1], 2)
  MiniTest.expect.equality(result.tlines[1], "   · Section")
end

T["make_outline"]["underline adornment line not treated as title"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- Two back-to-back underline headings; the adornment lines must not be
  -- parsed as the titles of subsequent headings.
  local lines = { "Title", "=====", "Next Heading", "------------" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(#result.tlines, 2)
  MiniTest.expect.equality(result.tlines[1], " · Title")
  MiniTest.expect.equality(result.tlines[2], "   · Next Heading")
end

T["make_outline"]["underline bnode points to title not adornment"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- Blank line separates preamble from heading so the TS parser treats
  -- them as distinct blocks (without the blank line, CommonMark absorbs
  -- the preceding text into the heading's paragraph node).
  local lines = { "preamble text", "", "Title", "=====" }
  local result = md.make_outline(lines, "test.md")
  -- bnode must be 3 (the title line), not 4 (the adornment).
  MiniTest.expect.equality(result.bnodes[1], 3)
end

-- ==============================================================================
-- make_outline: style preference detection
-- ==============================================================================

T["make_outline"]["use_hash false when first level-1/2 is underline"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = { "Title", "=====" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(result.use_hash, false)
end

T["make_outline"]["use_hash true when first level-1/2 is hash"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = { "# Title" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(result.use_hash, true)
end

T["make_outline"]["use_close_hash true when closing hashes present"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = { "## Section ##" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(result.use_close_hash, true)
end

T["make_outline"]["use_close_hash false when no closing hashes"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = { "## Section" }
  local result = md.make_outline(lines, "test.md")
  MiniTest.expect.equality(result.use_close_hash, false)
end

-- ==============================================================================
-- Fixture integration tests
-- ==============================================================================

T["fixture"] = MiniTest.new_set()

T["fixture"]["parses expected heading count"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = H.load_fixture("sample.md")
  local result = md.make_outline(lines, "sample.md")
  -- sample.md has 10 headings: 4 hash (levels 1,1,2,6) + 4 hash nested
  -- (levels 2,3,3,2) + 2 underline (levels 1,2). See fixture for details.
  MiniTest.expect.equality(#result.tlines, 10)
end

T["fixture"]["first heading is Project Overview at level 1"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = H.load_fixture("sample.md")
  local result = md.make_outline(lines, "sample.md")
  MiniTest.expect.equality(result.tlines[1], " · Project Overview")
  MiniTest.expect.equality(result.levels[1], 1)
  MiniTest.expect.equality(result.bnodes[1], 1)
end

T["fixture"]["underline heading detected in results"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines = H.load_fixture("sample.md")
  local result = md.make_outline(lines, "sample.md")
  local found = false
  for _, t in ipairs(result.tlines) do
    if t:find("Underline Level One", 1, true) then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

T["fixture"]["use_hash false because first heading is hash style"] = function()
  -- sample.md starts with "# Project Overview" so use_hash should be true.
  local md = require("voom.ts").build_mode("markdown")
  local lines = H.load_fixture("sample.md")
  local result = md.make_outline(lines, "sample.md")
  MiniTest.expect.equality(result.use_hash, true)
end

-- ==============================================================================
-- new_headline
-- ==============================================================================

T["new_headline"] = MiniTest.new_set()

T["new_headline"]["returns tree_head and body_lines keys"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = false, use_close_hash = true }, 1, "")
  MiniTest.expect.equality(type(result.tree_head), "string")
  MiniTest.expect.equality(type(result.body_lines), "table")
end

T["new_headline"]["tree_head is always NewHeadline"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local r1 = md.new_headline({ use_hash = false, use_close_hash = true }, 1, "")
  local r2 = md.new_headline({ use_hash = true,  use_close_hash = false }, 3, "")
  MiniTest.expect.equality(r1.tree_head, "NewHeadline")
  MiniTest.expect.equality(r2.tree_head, "NewHeadline")
end

-- Setext (underline) style -----------------------------------------------

T["new_headline"]["level 1 setext: title + === adornment + blank"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = false, use_close_hash = true }, 1, "")
  MiniTest.expect.equality(result.body_lines[1], "NewHeadline")
  MiniTest.expect.equality(result.body_lines[2], "===========")
  MiniTest.expect.equality(result.body_lines[3], "")
end

T["new_headline"]["level 2 setext: title + --- adornment + blank"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = false, use_close_hash = true }, 2, "")
  MiniTest.expect.equality(result.body_lines[1], "NewHeadline")
  MiniTest.expect.equality(result.body_lines[2], "-----------")
  MiniTest.expect.equality(result.body_lines[3], "")
end

-- ATX (hash) style -------------------------------------------------------

T["new_headline"]["level 1 hash no close: # NewHeadline"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = true, use_close_hash = false }, 1, "")
  MiniTest.expect.equality(result.body_lines[1], "# NewHeadline")
  MiniTest.expect.equality(result.body_lines[2], "")
end

T["new_headline"]["level 1 hash with close: # NewHeadline #"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = true, use_close_hash = true }, 1, "")
  MiniTest.expect.equality(result.body_lines[1], "# NewHeadline #")
  MiniTest.expect.equality(result.body_lines[2], "")
end

T["new_headline"]["level 3 forces hash even when use_hash=false"] = function()
  -- Setext style only supports levels 1–2; level 3 must use hash.
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = false, use_close_hash = false }, 3, "")
  MiniTest.expect.equality(result.body_lines[1], "### NewHeadline")
end

T["new_headline"]["level 6 hash no close"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = true, use_close_hash = false }, 6, "")
  MiniTest.expect.equality(result.body_lines[1], "###### NewHeadline")
end

-- Blank separator before new heading ----------------------------------------

T["new_headline"]["blank preceding line: no leading blank"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = true, use_close_hash = false }, 2, "")
  MiniTest.expect.equality(result.body_lines[1], "## NewHeadline")
end

T["new_headline"]["non-blank preceding line: leading blank prepended"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = true, use_close_hash = false }, 2, "some text")
  MiniTest.expect.equality(result.body_lines[1], "")
  MiniTest.expect.equality(result.body_lines[2], "## NewHeadline")
end

T["new_headline"]["whitespace-only preceding line counts as blank"] = function()
  local md     = require("voom.ts").build_mode("markdown")
  local result = md.new_headline({ use_hash = true, use_close_hash = false }, 1, "   ")
  -- "   " has no %S match, so no leading blank.
  MiniTest.expect.equality(result.body_lines[1], "# NewHeadline")
end

-- ==============================================================================
-- do_body_after_oop
-- ==============================================================================

T["do_body_after_oop"] = MiniTest.new_set()

-- 'cut' operation ------------------------------------------------------------

T["do_body_after_oop"]["cut: inserts blank at non-blank cut point"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- Body after cutting node 1: heading at line 1 is now directly adjacent to
  -- heading at line 2, with no blank separator.  blnum_cut=1 means the gap is
  -- after line 1.
  local lines  = { "# Alpha", "# Beta" }
  local bnodes = { 1, 2 }
  local levels = { 1, 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "cut", 0,
    0, 1, 0, 1,  -- blnum1/blnum2 unused for cut; tlnum1/tlnum2 irrelevant
    1, 1          -- blnum_cut=1, tlnum_cut=1
  )

  MiniTest.expect.equality(delta, 1)
  MiniTest.expect.equality(lines[2], "")
end

T["do_body_after_oop"]["cut: no blank inserted when cut point is already blank"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines  = { "# Alpha", "", "# Beta" }
  local bnodes = { 1, 3 }
  local levels = { 1, 1 }
  local state  = { use_hash = true, use_close_hash = false }

  -- blnum_cut=2 points to the blank line; lines[2]="" → no blank inserted.
  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "cut", 0,
    0, 1, 0, 1,
    2, 1
  )

  MiniTest.expect.equality(delta, 0)
  MiniTest.expect.equality(#lines, 3)
end

T["do_body_after_oop"]["cut: returns early, no heading format changes"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- Even with lev_delta != 0 the function must return after the blank check.
  local lines  = { "# Alpha", "", "## Beta" }
  local bnodes = { 1, 3 }
  local levels = { 1, 2 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "cut", 1,
    0, 1, 0, 1,
    2, 1
  )

  -- Line 2 is blank, no insertion; headings remain unchanged.
  MiniTest.expect.equality(delta, 0)
  MiniTest.expect.equality(lines[1], "# Alpha")
  MiniTest.expect.equality(lines[3], "## Beta")
end

-- Promote / demote: ATX level changes ----------------------------------------

T["do_body_after_oop"]["demote: ATX level 2 → level 3"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- Heading already surrounded by blanks; blnum2=Z so no blank-after insertion.
  local lines  = { "", "## Section", "" }
  local bnodes = { 2 }
  local levels = { 3 }  -- target level (caller has already updated levels[])
  local state  = { use_hash = true, use_close_hash = false }

  -- lev_delta = lev - lev_ = 3 - 2 = 1 (demoted deeper by 1)
  -- blnum2 = Z = 3 so no blank is inserted after the region.
  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "down", 1,
    2, 1, 3, 1,  -- blnum2=Z=3 so no trailing-blank insertion
    0, 0
  )

  MiniTest.expect.equality(lines[2], "### Section")
  MiniTest.expect.equality(delta, 0)
end

T["do_body_after_oop"]["promote: ATX level 3 → level 2"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines  = { "", "### Deep", "" }
  local bnodes = { 2 }
  local levels = { 2 }  -- target level
  local state  = { use_hash = true, use_close_hash = false }

  -- lev_delta = lev - lev_ = 2 - 3 = -1 (promoted shallower by 1)
  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "up", -1,
    2, 1, 3, 1,
    0, 0
  )

  MiniTest.expect.equality(lines[2], "## Deep")
  MiniTest.expect.equality(delta, 0)
end

-- Paste: closing-hash normalisation ------------------------------------------

T["do_body_after_oop"]["paste: adds closing hashes when use_close_hash=true"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines  = { "", "## Section", "" }
  local bnodes = { 2 }
  local levels = { 2 }
  local state  = { use_hash = true, use_close_hash = true }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    2, 1, 3, 1,
    0, 0
  )

  MiniTest.expect.equality(lines[2], "## Section ##")
  MiniTest.expect.equality(delta, 0)
end

T["do_body_after_oop"]["paste: removes closing hashes when use_close_hash=false"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines  = { "", "## Section ##", "" }
  local bnodes = { 2 }
  local levels = { 2 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    2, 1, 3, 1,
    0, 0
  )

  MiniTest.expect.equality(lines[2], "## Section")
  MiniTest.expect.equality(delta, 0)
end

-- Format conversion: ATX → setext -------------------------------------------

T["do_body_after_oop"]["promotes ATX lev3 → setext lev2 (ATX→setext)"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- lev_=3, lev=2, use_hash=false → lev<3 and lev_>2 triggers setext preference.
  -- lev_delta = 2 - 3 = -1
  local lines  = { "", "### Alpha", "" }
  local bnodes = { 2 }
  local levels = { 2 }
  local state  = { use_hash = false, use_close_hash = true }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "up", -1,
    2, 1, 3, 1,  -- blnum2=Z=3
    0, 0
  )

  -- ATX hashes stripped, title kept, adornment line inserted after it.
  MiniTest.expect.equality(lines[2], "Alpha")
  MiniTest.expect.equality(lines[3], "-----")
  MiniTest.expect.equality(delta, 1)
end

-- Format conversion: setext → ATX -------------------------------------------

T["do_body_after_oop"]["demotes setext lev1 → ATX lev3 (setext→ATX)"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- lev_=1 (setext), lev=3 (ATX). lev>2 and lev_<3 forces use_hash=true.
  -- lev_delta = 3 - 1 = 2
  -- Layout: blank | title | adornment | blank (4 lines total; blnum2=Z=4)
  local lines  = { "", "Title", "=====", "" }
  local bnodes = { 2 }
  local levels = { 3 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "down", 2,
    2, 1, 4, 1,  -- blnum2=Z=4
    0, 0
  )

  -- Adornment line removed (-1), no other insertions → net delta = -1.
  MiniTest.expect.equality(lines[2], "### Title")
  MiniTest.expect.equality(#lines, 3)
  MiniTest.expect.equality(delta, -1)
end

-- Blank-line management ------------------------------------------------------

T["do_body_after_oop"]["no blank inserted when heading is already at line 1"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- blnum1=1: the heading is the very first body line, no preceding line exists.
  local lines  = { "# Alpha", "" }
  local bnodes = { 1 }
  local levels = { 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    1, 1, 2, 1,
    0, 0
  )

  MiniTest.expect.equality(delta, 0)
  MiniTest.expect.equality(lines[1], "# Alpha")
end

T["do_body_after_oop"]["inserts blank before first heading when non-blank precedes it"] = function()
  local md = require("voom.ts").build_mode("markdown")
  -- Heading at line 2, preceded by non-blank content at line 1.
  -- blnum2=Z=3 avoids blank-after insertion; only blank-before fires.
  local lines  = { "some text", "# Heading", "" }
  local bnodes = { 2 }
  local levels = { 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    2, 1, 3, 1,
    0, 0
  )

  -- Blank inserted before the heading; heading shifts to line 3.
  MiniTest.expect.equality(lines[2], "")
  MiniTest.expect.equality(lines[3], "# Heading")
  MiniTest.expect.equality(delta, 1)
end

-- b_delta integrity ----------------------------------------------------------

T["do_body_after_oop"]["b_delta equals actual net line change"] = function()
  local md = require("voom.ts").build_mode("markdown")
  local lines  = { "some text", "# Alpha", "", "# Beta", "" }
  local bnodes = { 2, 4 }
  local levels = { 1, 1 }
  local state  = { use_hash = true, use_close_hash = false }

  local before = #lines
  local delta = md.do_body_after_oop(
    lines, bnodes, levels, state,
    "paste", 0,
    2, 1, 5, 2,  -- blnum2=Z=5
    0, 0
  )

  MiniTest.expect.equality(#lines, before + delta)
end

-- ==============================================================================
-- Modes registry integration
-- ==============================================================================

T["modes registry"] = MiniTest.new_set()

T["modes registry"]["get markdown returns a module"] = function()
  local modes = require("voom.modes")
  local md = modes.get("markdown")
  MiniTest.expect.equality(type(md), "table")
end

T["modes registry"]["markdown module has make_outline function"] = function()
  local modes = require("voom.modes")
  local md = modes.get("markdown")
  MiniTest.expect.equality(type(md.make_outline), "function")
end

return T
