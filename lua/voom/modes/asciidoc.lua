-- AsciiDoc mode for VOoM: parses AsciiDoc section titles and builds an outline tree.
--
-- AsciiDoc uses a single heading style with leading `=` signs:
--
--   = Document Title      (level 1)
--   == Section            (level 2)
--   === Subsection        (level 3)
--   ...up to...
--   ====== Level 6        (level 6)
--
-- Public API:
--   make_outline(lines, buf_name)             -> outline table
--   new_headline(outline_state, level, preceding_line) -> { tree_head, body_lines }
--   do_body_after_oop(lines, bnodes, levels, outline_state, oop, lev_delta,
--                     blnum1, tlnum1, blnum2, tlnum2, blnum_cut, tlnum_cut)
--                                             -> b_delta (net line-count change)
local M = {}

-- ==============================================================================
-- Private helpers
-- ==============================================================================

-- Add `delta` to every bnode at index >= tlnum.
--
-- Called after a line is inserted into or deleted from the body buffer so that
-- all bnode pointers that follow the insertion/deletion point stay accurate.
local function update_bnodes(bnodes, tlnum, delta)
  for i = tlnum, #bnodes do
    bnodes[i] = bnodes[i] + delta
  end
end

-- ==============================================================================
-- Public API
-- ==============================================================================

-- Parse AsciiDoc section titles from `lines` and return outline data.
--
-- Recognises the standard AsciiDoc heading style (levels 1-6):
--
--   = Document Title
--   == Section
--   === Subsection
--
-- Headings preceded by `[discrete]` are non-structural and excluded from the
-- outline.
--
-- @param lines    table   1-indexed array of strings (buffer lines)
-- @param buf_name string  display name for the buffer (unused during parsing;
--                         included so the caller contract matches across modes)
-- @return table
--   {
--     tlines         = { string },  -- formatted tree display lines
--     bnodes         = { int    },  -- 1-indexed body line numbers for each node
--     levels         = { int    },  -- heading depth (1-6) for each node
--     use_hash       = true,        -- always true (single heading style)
--     use_close_hash = false,       -- always false (no closing `=` signs)
--   }
function M.make_outline(lines, buf_name)
  local tlines = {}
  local bnodes = {}
  local levels = {}

  for i = 1, #lines do
    local line = lines[i]

    -- Match one or more `=` at start of line, followed by a space and then
    -- heading text.  This naturally excludes AsciiDoc block delimiters like
    -- `====` which have no trailing space+text.
    local equals, head = line:match("^(=+)%s+(.+)")
    if not equals then
      goto continue
    end

    local lev = #equals
    -- AsciiDoc supports levels 0-5 (1-6 `=` signs).  Ignore deeper headings
    -- to stay consistent with the plugin's 6-level cap.
    if lev > 6 then
      goto continue
    end

    -- TODO: full AsciiDoc attribute handling — currently only checks the
    -- immediately preceding line for `[discrete]`.  Real AsciiDoc allows
    -- stacked attributes (e.g. `[discrete]` then `[role="special"]` then
    -- the heading), but the single-line check covers the common case.
    if i > 1 and lines[i - 1]:match("^%[discrete%]%s*$") then
      goto continue
    end

    -- Strip trailing whitespace from the heading text.
    head = head:gsub("%s+$", "")

    -- Format the tree display line identically to the markdown mode:
    -- one leading space, then (lev-1) two-space pairs as indentation,
    -- then the fold-state icon placeholder "* ", then the text.
    table.insert(tlines, " " .. string.rep("  ", lev - 1) .. "· " .. head)
    table.insert(bnodes, i)
    table.insert(levels, lev)

    ::continue::
  end

  return {
    tlines = tlines,
    bnodes = bnodes,
    levels = levels,
    use_hash = true,
    use_close_hash = false,
  }
end

-- ==============================================================================
-- new_headline
-- ==============================================================================

-- Return the tree display string and body lines for a freshly-inserted heading.
--
-- AsciiDoc has only one heading style, so the format is always:
--   == NewHeadline
-- with the appropriate number of `=` signs for the level.
--
-- A blank line is prepended to body_lines when `preceding_line` is non-blank,
-- matching the behaviour of adding a separator before the new node.
--
-- @param outline_state  table   { use_hash=bool, use_close_hash=bool }
--                               (not used for AsciiDoc but included for
--                               contract consistency across modes)
-- @param level          int     heading level (1-6)
-- @param preceding_line string  the body line immediately before the insert point
-- @return table { tree_head=string, body_lines={string,...} }
function M.new_headline(outline_state, level, preceding_line)
  local tree_head = "NewHeadline"
  local body_lines = { string.rep("=", level) .. " " .. tree_head, "" }

  -- Insert a blank separator when the preceding body line is non-blank, so the
  -- new headline starts a visually distinct block.
  if preceding_line ~= nil and preceding_line:match("%S") then
    table.insert(body_lines, 1, "")
  end

  return { tree_head = tree_head, body_lines = body_lines }
end

-- ==============================================================================
-- do_body_after_oop
-- ==============================================================================

-- Post-process the body buffer after an outline operation (oop).
--
-- Mutates `lines` and `bnodes` in place and returns the net line-count delta
-- `b_delta` (positive = lines inserted, negative = lines deleted).
--
-- AsciiDoc headings have a single format (`= Title`), so there is no format
-- conversion logic.  Level changes simply adjust the number of `=` signs.
--
-- @param lines         table   1-indexed body buffer lines (mutated in place)
-- @param bnodes        table   1-indexed body line numbers per outline node (mutated)
-- @param levels        table   1-indexed heading levels, already updated by caller
-- @param outline_state table   { use_hash=bool, use_close_hash=bool }
-- @param oop           string  operation: "cut"|"up"|"down"|"paste"
-- @param lev_delta     int     level change (positive=demote, negative=promote, 0=none)
-- @param blnum1        int     first body line of affected region (0 if N/A)
-- @param tlnum1        int     first tree line of affected region
-- @param blnum2        int     last body line of affected region (0 if N/A)
-- @param tlnum2        int     last tree line of affected region
-- @param blnum_cut     int     body line after which region was removed (0 if N/A)
-- @param tlnum_cut     int     tree line of the node at the cut boundary
-- @return int  b_delta
function M.do_body_after_oop(lines, bnodes, levels, outline_state,
                              oop, lev_delta,
                              blnum1, tlnum1, blnum2, tlnum2,
                              blnum_cut, tlnum_cut)
  local Z       = #lines
  local b_delta = 0

  -- ===========================================================================
  -- After 'cut' or 'up': ensure a blank separator exists at the gap left by
  -- the removed region.
  -- ===========================================================================
  if (oop == "cut" or oop == "up")
      and blnum_cut > 0 and blnum_cut < Z
      and lines[blnum_cut]:match("%S") then
    table.insert(lines, blnum_cut + 1, "")
    update_bnodes(bnodes, tlnum_cut + 1, 1)
    b_delta = b_delta + 1
  end

  -- 'cut' only needs the blank-separator check above; no heading changes.
  if oop == "cut" then
    return b_delta
  end

  -- ===========================================================================
  -- Ensure a blank line follows the last node in the affected region.
  -- ===========================================================================
  if blnum2 < Z and lines[blnum2]:match("%S") then
    table.insert(lines, blnum2 + 1, "")
    update_bnodes(bnodes, tlnum2 + 1, 1)
    b_delta = b_delta + 1
  end

  -- ===========================================================================
  -- Change heading levels for every heading in tlnum1..tlnum2.
  --
  -- AsciiDoc has only one heading format, so this is a simple prefix
  -- replacement — no format conversion needed.
  -- ===========================================================================
  if lev_delta ~= 0 or oop == "paste" then
    for i = tlnum2, tlnum1, -1 do
      local bln = bnodes[i]
      local line = lines[bln]

      -- Strip the existing `=` prefix and any following whitespace, then
      -- rebuild with the target level's `=` count.
      local text = line:gsub("^=+%s*", "")
      lines[bln] = string.rep("=", levels[i]) .. " " .. text
    end
  end

  -- ===========================================================================
  -- Ensure the first heading in the region is preceded by a blank line.
  -- Re-read blnum1 from bnodes because the loop above may have shifted it.
  -- ===========================================================================
  blnum1 = bnodes[tlnum1]
  if blnum1 > 1 and lines[blnum1 - 1]:match("%S") then
    table.insert(lines, blnum1, "")
    update_bnodes(bnodes, tlnum1, 1)
    b_delta = b_delta + 1
  end

  -- ===========================================================================
  -- After 'down': ensure a blank separator at the gap left by the moved region.
  -- Checked last because the moved region is below the gap.
  -- ===========================================================================
  if oop == "down"
      and blnum_cut > 0 and blnum_cut < Z
      and lines[blnum_cut]:match("%S") then
    table.insert(lines, blnum_cut + 1, "")
    update_bnodes(bnodes, tlnum_cut + 1, 1)
    b_delta = b_delta + 1
  end

  assert(#lines == Z + b_delta,
    "do_body_after_oop: line count mismatch (got " .. #lines ..
    ", expected " .. (Z + b_delta) .. ")")
  return b_delta
end

return M
