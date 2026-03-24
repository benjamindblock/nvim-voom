-- Markdown mode for VOoM: parses Markdown headings and builds an outline tree.
--
-- This module is a Lua port of the outline-generation logic from the upstream
-- Python implementation (included as a git submodule at legacy/):
--   legacy/autoload/voom/voom_vimplugin2657/voom_mode_markdown.py
--
-- Public API:
--   make_outline(lines, buf_name)             → outline table
--   new_headline(outline_state, level, preceding_line) → { tree_head, body_lines }
--   do_body_after_oop(lines, bnodes, levels, outline_state, oop, lev_delta,
--                     blnum1, tlnum1, blnum2, tlnum2, blnum_cut, tlnum_cut)
--                                             → b_delta (net line-count change)
--
-- Root node contract: the Python hook_makeOutline did NOT prepend a root node
-- (the buffer name at level 1, bnode 1). The caller in voom.py injected it
-- separately. make_outline follows the same contract: callers are responsible
-- for prepending the root node when building the full tree.

local M = {}

-- Maps heading level (int) -> underline character, for the two underline-style
-- heading levels that Markdown supports.
M.LEVELS_ADS = { [1] = "=", [2] = "-" }

-- Maps underline character -> heading level (inverse of LEVELS_ADS).
M.ADS_LEVELS = { ["="] = 1, ["-"] = 2 }

-- ==============================================================================
-- Private helpers
-- ==============================================================================

-- Return true if `s` is a non-empty string consisting entirely of '=' or '-'.
-- These are the only two adornment characters Markdown defines for underline-
-- style (setext) headings.
local function is_adornment(s)
  if s == "" then
    return false
  end
  local ch = s:sub(1, 1)
  if ch ~= "=" and ch ~= "-" then
    return false
  end
  -- Match the entire string against repetitions of that single character.
  return s:match("^" .. ch .. "+$") ~= nil
end

-- Strip leading and trailing whitespace from `s`.
local function strip(s)
  return s:match("^%s*(.-)%s*$")
end

-- ==============================================================================
-- Public API
-- ==============================================================================

-- Parse Markdown headings from `lines` and return outline data.
--
-- Recognises two heading styles:
--
--   Hash-style (levels 1–6):
--     ## My Heading
--     ## My Heading ##   (optional closing hashes)
--
--   Underline-style / setext (levels 1–2 only):
--     My Heading
--     ==========         (level 1)
--
--     My Heading
--     ----------         (level 2)
--
-- @param lines    table   1-indexed array of strings (buffer lines)
-- @param buf_name string  display name for the buffer (unused during parsing;
--                         included so the caller contract matches across modes)
-- @return table
--   {
--     tlines        = { string },  -- formatted tree display lines
--     bnodes        = { int    },  -- 1-indexed body line numbers for each node
--     levels        = { int    },  -- heading depth (1–6) for each node
--     use_hash      = bool,        -- true if first level-1/2 heading used '#' style
--     use_close_hash = bool,       -- true if first hash heading had closing '#'
--   }
function M.make_outline(lines, buf_name)
  local tlines = {}
  local bnodes = {}
  local levels = {}

  -- Style preference flags: detected from the first heading at level 1 or 2.
  -- We use a separate `_set` boolean so we can distinguish "not yet seen" from
  -- "seen and false" — replacing the Python implementation's 0/1/2 sentinel
  -- integer pattern with an explicit two-variable form.
  local use_hash = false
  local use_hash_set = false
  local use_close_hash = true -- default matches Python: assume closing hashes
  local use_close_hash_set = false

  local Z = #lines

  -- Seed the look-ahead variable with the first line so the loop body can
  -- always reference both L1 (current) and L2 (next) without a bounds check.
  -- Trailing whitespace is stripped once here so we don't repeat it inside.
  local L2 = Z > 0 and lines[1]:gsub("%s+$", "") or ""

  for i = 1, Z do
    local L1 = L2
    -- Advance the look-ahead: strip trailing whitespace to simplify comparisons.
    L2 = (i + 1 <= Z) and lines[i + 1]:gsub("%s+$", "") or ""

    -- Blank lines are never headings; skip immediately.
    if L1 == "" then
      goto continue
    end

    local lev, head

    if is_adornment(L2) then
      -- ===========================================================
      -- Underline-style heading: L1 is the title, L2 is the adornment.
      -- ===========================================================
      lev = M.ADS_LEVELS[L2:sub(1, 1)]
      head = strip(L1)

      -- Consume the adornment by blanking the look-ahead so the next
      -- iteration does not re-read the adornment line as a title candidate.
      -- This mirrors the `L2 = ''` sentinel in the Python implementation.
      L2 = ""

      -- Record style preference the first time we observe a level-1 or
      -- level-2 heading.
      if not use_hash_set then
        use_hash = false
        use_hash_set = true
      end
    elseif L1:sub(1, 1) == "#" then
      -- ===========================================================
      -- Hash-style heading: count leading '#' characters for the level.
      -- ===========================================================
      local hashes = L1:match("^(#+)")
      lev = #hashes

      -- Strip leading hashes and spaces, then trailing spaces and optional
      -- closing hashes. This handles "## heading", "## heading ##", and the
      -- degenerate "## heading##" that Python's str.strip('#') would also clean.
      head = L1:gsub("^#+%s*", ""):gsub("%s*#+%s*$", "")

      -- Record hash-style preference the first time we see a level-1 or
      -- level-2 heading.
      if not use_hash_set and lev < 3 then
        use_hash = true
        use_hash_set = true
      end

      -- Record whether closing hashes are present, from the first hash
      -- heading of any level.
      if not use_close_hash_set then
        use_close_hash = L1:sub(-1) == "#"
        use_close_hash_set = true
      end
    else
      -- Not a heading line; skip.
      goto continue
    end

    -- Format the tree display line. One leading space plus one "· " pair per
    -- level, where the last · is the fold-state icon placeholder.
    -- Example: level 3 → " · · · My Heading"
    table.insert(tlines, " " .. string.rep("· ", lev - 1) .. "· " .. head)
    table.insert(bnodes, i)
    table.insert(levels, lev)

    ::continue::
  end

  return {
    tlines = tlines,
    bnodes = bnodes,
    levels = levels,
    use_hash = use_hash,
    use_close_hash = use_close_hash,
  }
end

-- ==============================================================================
-- Private helper: bnode array maintenance
-- ==============================================================================

-- Add `delta` to every bnode at index >= tlnum.
--
-- Called after a line is inserted into or deleted from the body buffer so that
-- all bnode pointers that follow the insertion/deletion point stay accurate.
-- Port of the Python module-level `update_bnodes(VO, tlnum, delta)` helper.
local function update_bnodes(bnodes, tlnum, delta)
  for i = tlnum, #bnodes do
    bnodes[i] = bnodes[i] + delta
  end
end

-- ==============================================================================
-- new_headline
-- ==============================================================================

-- Return the tree display string and body lines for a freshly-inserted heading.
--
-- The format is chosen based on the stored style preferences in `outline_state`
-- and the requested `level`:
--
--   • levels 1–2 with use_hash=false  → setext (underline) style
--   • all other combinations          → ATX (hash) style
--
-- A blank line is prepended to body_lines when `preceding_line` is non-blank,
-- matching the Python behaviour of adding a separator before the new node.
--
-- Port of hook_newHeadline() in voom_mode_markdown.py.
--
-- @param outline_state  table   { use_hash=bool, use_close_hash=bool }
-- @param level          int     heading level (1–6)
-- @param preceding_line string  the body line immediately before the insert point
-- @return table { tree_head=string, body_lines={string,...} }
function M.new_headline(outline_state, level, preceding_line)
  local tree_head = "NewHeadline"
  local body_lines

  if level < 3 and not outline_state.use_hash then
    -- Setext style: title line + adornment line (11 characters) + blank.
    body_lines = { tree_head, M.LEVELS_ADS[level]:rep(11), "" }
  else
    -- ATX style: '#' × level, heading text, optional closing hashes.
    local hashes = string.rep("#", level)
    if outline_state.use_close_hash then
      body_lines = { hashes .. " " .. tree_head .. " " .. hashes, "" }
    else
      body_lines = { hashes .. " " .. tree_head, "" }
    end
  end

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
-- Operations (`oop` values):
--   "cut"    — remove a region; ensure blank separator at the gap
--   "up"     — move region up; ensure blank at old position
--   "down"   — move region down; ensure blank at old position (checked last)
--   "paste"  — insert pasted region; normalise format to outline preferences
--   (any oop with lev_delta != 0) — promote or demote headings in region
--
-- `blnum1`/`blnum2` bound the body region that was pasted/moved (1-indexed,
-- inclusive). `blnum_cut`/`tlnum_cut` identify the position from which a region
-- was removed during cut/up/down. For pure promote/demote, blnum_cut = 0.
--
-- The assertion at the end mirrors the Python implementation and serves as an
-- internal consistency check; it will error if the caller passes inconsistent
-- arguments.
--
-- Port of hook_doBodyAfterOop() in voom_mode_markdown.py.
--
-- @param lines         table   1-indexed body buffer lines (mutated in place)
-- @param bnodes        table   1-indexed body line numbers per outline node (mutated)
-- @param levels        table   1-indexed heading levels, already updated by caller
-- @param outline_state table   { use_hash=bool, use_close_hash=bool }
-- @param oop           string  operation: "cut"|"up"|"down"|"paste"
-- @param lev_delta     int     level change (positive=promote, negative=demote, 0=none)
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
  -- the removed region. The two nodes that are now adjacent may need a blank
  -- between them.
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
  -- Change heading levels and/or formats for every heading in tlnum1..tlnum2.
  --
  -- Iterate bottom-to-top so that any line insertions or deletions at a lower
  -- heading do not shift the bnode indices we rely on for headings above it.
  --
  -- Heading layout in the body buffer (both styles):
  --
  --   ATX style:      ## My Heading ##   ← lines[bln]   (bnode)
  --                   (next line)        ← lines[bln+1]
  --
  --   Setext style:   My Heading         ← lines[bln]   (bnode)
  --                   ----------         ← lines[bln+1] (adornment)
  --                   (next line)        ← lines[bln+2]
  -- ===========================================================================
  if lev_delta ~= 0 or oop == "paste" then
    for i = tlnum2, tlnum1, -1 do
      -- `lev`  is the target level (levels[] already updated by the caller).
      -- `lev_` is the original level we are converting from.
      local lev  = levels[i]
      local lev_ = lev - lev_delta

      local bln = bnodes[i]
      local L1  = lines[bln]:gsub("%s+$", "")
      local L2  = (bln < #lines) and lines[bln + 1]:gsub("%s+$", "") or ""

      -- Detect the current heading format from the body lines.
      -- A setext adornment line immediately after the title means underline
      -- style; otherwise the heading is ATX (hash) style.
      local has_hash       = true
      local has_close_hash = outline_state.use_close_hash
      if is_adornment(L2) then
        has_hash = false
      else
        has_close_hash = L1:sub(-1) == "#"
      end

      -- Determine the desired format after this operation.
      local use_hash, use_close_hash
      if oop == "paste" then
        -- Normalise pasted content to the receiving outline's conventions.
        -- Levels above 2 cannot use setext style, so hash is forced.
        if lev > 2 then
          use_hash = true
        else
          use_hash = outline_state.use_hash
        end
        use_close_hash = outline_state.use_close_hash
      elseif lev < 3 and lev_ < 3 then
        -- Both old and new levels are in the setext range: keep existing style.
        use_hash       = has_hash
        use_close_hash = has_close_hash
      elseif lev > 2 and lev_ > 2 then
        -- Both levels are hash-only: keep hash, preserve close-hash preference.
        use_hash       = true
        use_close_hash = has_close_hash
      elseif lev < 3 and lev_ > 2 then
        -- Promoted into setext range: apply the outline's stored preference.
        use_hash       = outline_state.use_hash
        use_close_hash = outline_state.use_close_hash
      else
        -- lev > 2 and lev_ < 3: demoted out of setext range, must use hash.
        use_hash       = true
        use_close_hash = has_close_hash
      end

      -- -----------------------------------------------------------------------
      -- Apply the level/format change.
      -- -----------------------------------------------------------------------

      if not use_hash and not has_hash then
        -- Setext style, no format change — only adjust the adornment character
        -- when the level (= adornment character) changes.
        if lev_delta == 0 then goto next_heading end
        -- TODO: use vim.fn.strchars(L2) for Unicode-aware adornment width
        -- (currently uses byte length, which matches for ASCII titles).
        lines[bln + 1] = M.LEVELS_ADS[lev]:rep(#L2)

      elseif use_hash and has_hash then
        -- ATX style, no format change — adjust '#' count and closing hashes.
        --
        -- Strip leading '#' for the "left only" variant; strip both ends for
        -- variants that rebuild the full line symmetrically.
        local inner_both = L1:gsub("^#+", ""):gsub("#+$", "")
        local inner_left = L1:match("^#+(.*)")

        if use_close_hash and has_close_hash then
          if lev_delta == 0 then goto next_heading end
          lines[bln] = string.rep("#", lev) .. inner_both .. string.rep("#", lev)
        elseif not use_close_hash and not has_close_hash then
          if lev_delta == 0 then goto next_heading end
          lines[bln] = string.rep("#", lev) .. inner_left
        elseif use_close_hash and not has_close_hash then
          -- Add closing hashes: rebuild with trimmed inner content.
          local inner = inner_both:gsub("%s*$", "")
          lines[bln] = string.rep("#", lev) .. inner .. " " .. string.rep("#", lev)
        else
          -- Remove closing hashes: strip '#' from both ends, trim trailing space.
          local inner = inner_both:gsub("%s*$", "")
          lines[bln] = string.rep("#", lev) .. inner
        end

      elseif not use_hash and has_hash then
        -- Convert ATX → setext: strip hashes from the title, insert adornment.
        local title = strip(L1:gsub("^#+", ""):gsub("#+$", ""))
        lines[bln] = title
        -- TODO: use vim.fn.strchars(title) for Unicode-aware adornment width.
        table.insert(lines, bln + 1, M.LEVELS_ADS[lev]:rep(#title))
        update_bnodes(bnodes, i + 1, 1)
        b_delta = b_delta + 1

      else
        -- use_hash and not has_hash
        -- Convert setext → ATX: insert hashes before the title, remove adornment.
        --
        -- Preserve the leading space that some titles have by omitting the
        -- extra separator space when the title already starts with whitespace.
        local sp = L1:sub(1, 1):match("%s") and "" or " "
        if use_close_hash then
          lines[bln] = string.rep("#", lev) .. sp .. L1 .. " " .. string.rep("#", lev)
        else
          lines[bln] = string.rep("#", lev) .. sp .. L1
        end

        -- If the line following the adornment is itself an adornment (i.e. the
        -- next heading also uses setext style), we must not delete the line —
        -- doing so would make two title lines appear adjacent.  Blank it instead.
        local L3 = (bln + 1 < #lines) and lines[bln + 2]:gsub("%s+$", "") or ""
        if is_adornment(L3) then
          lines[bln + 1] = ""
        else
          table.remove(lines, bln + 1)
          update_bnodes(bnodes, i + 1, -1)
          b_delta = b_delta - 1
        end
      end

      ::next_heading::
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
  -- Checked last because the moved region (now at blnum1..blnum2) is below the
  -- gap, so the level-change loop above does not affect blnum_cut's accuracy.
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
