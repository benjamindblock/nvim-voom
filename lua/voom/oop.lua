-- Outline editing operations for VOoM.
--
-- This module contains all operations that modify the body buffer through
-- the tree panel: insert, cut, copy, paste, move up/down, promote/demote.
--
-- Design: each operation reads body lines into a Lua table, performs
-- structural edits, calls the mode's do_body_after_oop() for format
-- normalization (blank lines, heading style conversion), writes the result
-- back to the buffer, then calls tree.update() to re-parse and rebuild the
-- tree display.  This avoids manually maintaining tree lines / bnodes /
-- levels after each edit — the existing make_outline parser handles that.
--
-- Port of the editing functions in:
--   legacy/autoload/voom/voom_vimplugin2657/voom_vim.py
--
-- ==============================================================================
-- Private internal flow for tree-driven structural edits
-- ==============================================================================
--
-- Every mutating tree command follows this six-phase flow.  The phases are
-- documented here to make the expected structure explicit; individual
-- commands still express each phase inline today.  Later refactor steps
-- (items 7–9 in REFACTOR.md) will extract shared helpers for phases that
-- are genuinely duplicated, while keeping command-specific logic local.
--
-- Phase 1 — Resolve command context
--   Gather the working set that every tree-initiated edit needs:
--     body_buf       — the body buffer (via state.get_body)
--     outline        — current { bnodes, levels } (via state.get_outline)
--     outline_state  — style prefs for the mode parser (via state.get_outline_state)
--     mode           — the markup mode module (via modes.get + state.get_mode)
--     tree_win       — the tree window handle (via find_win_for_buf)
--     tlnum          — the tree-cursor line number (via nvim_win_get_cursor)
--   Any nil result from the state lookups or a missing tree window is a
--   silent early return — the command is a no-op when context is incomplete.
--
-- Phase 2 — Compute the body mutation
--   Read body lines into a Lua table and compute the structural edit:
--     - Determine affected body-line range(s) and outline index ranges.
--     - Build the replacement line table (insert, rearrange, or delete).
--     - Call mode.do_body_after_oop() for format normalization when the
--       mode provides it (blank-line cleanup, ATX/setext heading rewrite).
--   This phase is pure data transformation — no buffer writes, no state
--   changes, no cursor moves.
--
-- Phase 3 — Write the body
--   Apply the computed line table to the body buffer via write_body() (which
--   calls nvim_buf_set_lines inside nvim_buf_call to preserve undo
--   segmentation).  insert_node uses nvim_buf_set_lines directly for
--   appending rather than full replacement; sort uses it for ranged
--   replacement.  The body buffer is the source of truth — all downstream
--   state is derived from it.
--
-- Phase 4 — Refresh outline and tree
--   Call refresh_after_edit(body_buf), which:
--     a. Calls tree.update() to re-parse the body and rebuild the tree
--        display (outline data in state is replaced by the fresh parse).
--     b. Syncs the stored changedtick so the BufEnter autocommand does not
--        trigger a redundant re-parse on the next window entry.
--
-- Phase 5 — Restore selection and cursor
--   Each command determines its own post-edit selection target.  The target
--   is expressed as an OopResult (see below) and applied after refresh:
--     - Set state.snLn to the target tree line.
--     - Move the tree-window cursor to that line.
--     - Optionally transfer focus to the body window and set the body
--       cursor (insert_node jumps to the "NewHeadline" placeholder).
--
-- Phase 6 — Command-specific follow-up
--   Optional status feedback (echo/notify) or clipboard updates that do
--   not affect buffer or outline state.  Examples:
--     - cut_node / copy_node echo the node count.
--     - paste_node echoes nothing on success but echoes errors on invalid
--       clipboard content.
--
-- ==============================================================================
-- Private result contract for mutating commands (OopResult)
-- ==============================================================================
--
-- After phases 2–3 complete, each mutating command produces a small result
-- table that carries only the information phases 4–6 need.  This contract
-- is private to this module — it is not exposed through voom.oop, voom.state,
-- or any other public API.
--
-- OopResult = {
--   -- Whether tree refresh is needed.  True for all body-mutating commands.
--   -- False only for read-only operations (copy_node) or early-return no-ops.
--   refresh = bool,
--
--   -- The tree line that should be selected after refresh.  Nil means "keep
--   -- the current snLn unchanged" (used when the command is a no-op).
--   --
--   -- Selection policies by command:
--   --   cut       → node above the deleted range, clamped to [1, #bnodes]
--   --   paste     → first pasted node (insert_idx + 1)
--   --   move_up   → moved node's new tree line (previous sibling's old line)
--   --   move_down → moved node's new tree line (after the passed-over sibling)
--   --   promote   → same tree line (tlnum unchanged)
--   --   demote    → same tree line (tlnum unchanged)
--   --   insert    → new node's tree line (looked up by body line in refreshed outline)
--   --   sort      → selected node's new tree line (tracked through chunk reorder)
--   target_tlnum = int | nil,
--
--   -- Focus disposition after the operation completes.
--   --   "tree" → focus stays in the tree window (default for most commands)
--   --   "body" → focus transfers to the body window (insert_node, edit_node)
--   focus = "tree" | "body",
--
--   -- Body cursor target when focus == "body".  Nil when focus == "tree".
--   -- { lnum, col } — 1-indexed line number and 0-indexed column.
--   body_cursor = { int, int } | nil,
--
--   -- Optional status message to echo after the operation.
--   -- { { text, hlgroup }, ... } — same shape as nvim_echo's chunks arg.
--   echo = { { string, string }, ... } | nil,
-- }

local M = {}

local modes      = require("voom.modes")
local state      = require("voom.state")
local tree       = require("voom.tree")
local tree_utils = require("voom.tree_utils")

-- ==============================================================================
-- Module-level clipboard
-- ==============================================================================

-- Stores the last cut/copied node content for paste operations.
local clipboard = {
  body_lines = nil, -- {string,...} body lines of the copied/cut subtree
  levels = nil, -- {int,...} heading levels for paste-time adjustment
}

-- ==============================================================================
-- Core helpers
-- ==============================================================================

-- Return the body line range (bln1, bln2) for a node and its entire subtree.
--
-- `tlnum` is a tree line number (1-indexed).  Tree line k maps directly to
-- bnodes[k] and levels[k] — no offset.  We look up the bnode and walk
-- forward through levels to find the end of the subtree (first node at same
-- or shallower level, or end of document).
--
-- @param bnodes          table  1-indexed bnode array
-- @param levels          table  1-indexed levels array
-- @param tlnum           int    tree line number
-- @param total_body_lines int   total number of body lines
-- @return int, int  (bln1, bln2) inclusive body line range
function M.get_node_range(bnodes, levels, tlnum, total_body_lines)
  local idx = tlnum -- levels/bnodes index = tree line (direct mapping)
  local bln1 = bnodes[idx]
  local cur_level = levels[idx]

  -- Walk forward to find the end of the subtree.  The subtree ends at the
  -- first node whose level is <= cur_level, or at the end of the document.
  for i = idx + 1, #levels do
    if levels[i] <= cur_level then
      return bln1, bnodes[i] - 1
    end
  end

  -- No subsequent sibling/uncle found: subtree extends to end of document.
  return bln1, total_body_lines
end

-- Count all descendant nodes under tree line `tlnum`.
--
-- Port of nodeSubnodes() in voom_vim.py.
--
-- @param levels  table  1-indexed levels array
-- @param tlnum   int    tree line number
-- @return int    number of subnodes (0 if leaf or last node)
function M.count_subnodes(levels, tlnum)
  local idx = tlnum -- direct mapping: tree line k = levels[k]
  if idx >= #levels then
    return 0
  end

  local cur_level = levels[idx]
  for i = idx + 1, #levels do
    if levels[i] <= cur_level then
      return i - idx - 1
    end
  end
  return #levels - idx
end

-- Return the clipboard contents (for testing).
function M.get_clipboard()
  return clipboard
end

-- Clear the clipboard (for testing).
function M.clear_clipboard()
  clipboard = { body_lines = nil, levels = nil }
end

-- ==============================================================================
-- Internal helpers
-- ==============================================================================

local find_win_for_buf = tree_utils.find_win_for_buf

-- Re-parse the body buffer, update state, refresh the tree display, and
-- sync the stored changedtick to prevent redundant re-parses from the
-- BufEnter autocommand.
local function refresh_after_edit(body_buf)
  tree.update(body_buf)
  local tick = vim.api.nvim_buf_get_changedtick(body_buf)
  state.set_changedtick(body_buf, tick)
end

-- Write `lines` (a Lua table) into the body buffer, replacing all content.
-- Each OOP command should create its own undo step in the body undo tree.
local function write_body(body_buf, lines)
  -- Apply from inside the body buffer context so undo history is segmented by
  -- each OOP command invocation (rather than coalescing non-current-buffer writes).
  vim.api.nvim_buf_call(body_buf, function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end)
end

-- Resolve the shared context for any tree-initiated command.
--
-- Returns a table with the body buffer, outline data, tree window, cursor
-- position, and body line count — or nil if any required field is missing
-- (making the command a silent no-op).
--
-- Both structural edits and read-only navigation use this resolver.
-- Mutating commands additionally resolve outline_state and mode locally,
-- because their nil-check policies differ across commands (some guard at
-- the call site, others early-return).
local function resolve_tree_ctx(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then
    return nil
  end
  local outline = state.get_outline(body_buf)
  if not outline then
    return nil
  end
  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then
    return nil
  end
  local tlnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  return {
    body_buf = body_buf,
    outline = outline,
    bnodes = outline.bnodes,
    levels = outline.levels,
    tree_win = tree_win,
    tlnum = tlnum,
    total_body = vim.api.nvim_buf_line_count(body_buf),
  }
end

-- ==============================================================================
-- Tree-context read-only navigation
-- ==============================================================================
--
-- Operations that resolve tree context and transfer focus to the body without
-- mutating any buffer content.  edit_node is the only member today.

-- ==============================================================================
-- edit_node (i / I)
-- ==============================================================================

-- Jump from the tree to the body at the heading's first line (op="i") or
-- the last line of the heading's region (op="I").
--
-- No body modification — pure cursor positioning.
function M.edit_node(tree_buf, op)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end

  local idx = ctx.tlnum
  local body_lnum

  if op == "i" then
    body_lnum = ctx.bnodes[idx]
  elseif op == "I" then
    -- Last line of this node's region (line before the next node, or EOF).
    if idx < #ctx.bnodes then
      body_lnum = ctx.bnodes[idx + 1] - 1
    else
      body_lnum = ctx.total_body
    end
  end

  if not body_lnum then
    return
  end

  state.set_snLn(ctx.body_buf, ctx.tlnum)

  local body_win = find_win_for_buf(ctx.body_buf)
  if body_win then
    vim.api.nvim_set_current_win(body_win)
    vim.api.nvim_win_set_cursor(body_win, { body_lnum, 0 })
  end
end

-- ==============================================================================
-- Tree-context structural edits
-- ==============================================================================
--
-- Operations that mutate the body buffer through the tree panel, then refresh
-- the tree display and restore selection.  All members share the six-phase
-- flow documented at the top of this file.
--
-- Members: insert_node, cut_node, copy_node, paste_node,
--          move_up, move_down, promote, demote.

-- ==============================================================================
-- insert_node (aa / AA)
-- ==============================================================================

-- Insert a new heading after the current node.
--
-- as_child=false → insert as sibling (same level)
-- as_child=true  → insert as first child (level + 1)
--
-- After insertion, jumps to the body and selects "NewHeadline" text for
-- easy replacement.
function M.insert_node(tree_buf, as_child)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end
  local outline_state = state.get_outline_state(ctx.body_buf)
  if not outline_state then
    return
  end
  local mode_name = state.get_mode(ctx.body_buf)
  if not mode_name then
    return
  end
  local mode = modes.get(mode_name)
  if not mode then
    return
  end

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local ln = ctx.tlnum
  local total_body = ctx.total_body

  -- Determine the insert level and the tree line after which to insert.
  -- Tree line k maps directly to levels[k]; no root-offset needed.
  local lev = levels[ln]

  if as_child then
    -- Always insert as first child, regardless of fold state.
    lev = lev + 1
  elseif ln ~= #levels then
    -- Node has children — check fold state.
    if levels[ln + 1] and lev < levels[ln + 1] then
      -- Check if folded in the tree window.
      local fold_end = vim.api.nvim_win_call(ctx.tree_win, function()
        return vim.fn.foldclosedend(ln)
      end)
      if fold_end ~= -1 then
        -- Folded: insert after the subtree, same level.
        ln = ln + M.count_subnodes(levels, ln)
      else
        -- Not folded: insert as child.
        lev = lev + 1
      end
    end
  end

  -- Body lnum after which to insert.
  local bln_insert
  if ln <= #bnodes then
    -- There is a node after ln in the outline; insert before it.
    -- But first compute the end of ln's subtree.
    local _, bln2 = M.get_node_range(bnodes, levels, ln, total_body)
    bln_insert = bln2
  else
    bln_insert = total_body
  end

  -- Get the preceding body line (for blank-separator logic in new_headline).
  local preceding_line = ""
  if bln_insert >= 1 then
    preceding_line = vim.api.nvim_buf_get_lines(ctx.body_buf, bln_insert - 1, bln_insert, false)[1]
      or ""
  end

  -- Generate the new heading lines.
  local result = mode.new_headline(outline_state, lev, preceding_line)
  local body_lines = result.body_lines

  -- Insert into the body buffer.
  vim.api.nvim_buf_set_lines(ctx.body_buf, bln_insert, bln_insert, false, body_lines)

  -- Refresh the tree to reflect the new heading.
  refresh_after_edit(ctx.body_buf)

  -- Position the tree cursor on the new node, then jump to body to edit.
  -- The new heading's body line is bln_insert + offset (accounting for
  -- any blank separator that new_headline may have prepended).
  local new_bln = bln_insert + 1
  -- If a blank line was prepended, the actual heading is one line further.
  if #body_lines > 0 and body_lines[1] == "" then
    new_bln = new_bln + 1
  end

  -- Find the new tree line for this heading by looking up new_bln in the
  -- refreshed outline.
  local new_outline = state.get_outline(ctx.body_buf)
  if new_outline then
    for i, bn in ipairs(new_outline.bnodes) do
      if bn == new_bln then
        -- Direct mapping: tree line = bnodes index (no root offset).
        local new_tlnum = i
        state.set_snLn(ctx.body_buf, new_tlnum)
        if ctx.tree_win and vim.api.nvim_win_is_valid(ctx.tree_win) then
          vim.api.nvim_win_set_cursor(ctx.tree_win, { new_tlnum, 0 })
        end
        break
      end
    end
  end

  -- Jump to the body and position cursor on the "NewHeadline" text.
  -- The user can use `ciw` or similar to replace the placeholder.
  local body_win = find_win_for_buf(ctx.body_buf)
  if body_win then
    vim.api.nvim_set_current_win(body_win)
    local line = vim.api.nvim_buf_get_lines(ctx.body_buf, new_bln - 1, new_bln, false)[1] or ""
    local col_start = line:find("NewHeadline")
    vim.api.nvim_win_set_cursor(body_win, { new_bln, col_start and (col_start - 1) or 0 })
  end
end

-- ==============================================================================
-- copy_node (yy)
-- ==============================================================================

-- Copy the current node and its subtree to the plugin clipboard.
function M.copy_node(tree_buf)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end

  local bln1, bln2 = M.get_node_range(ctx.bnodes, ctx.levels, ctx.tlnum, ctx.total_body)

  -- Read the body lines for this subtree.
  local body_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, bln1 - 1, bln2, false)

  -- Collect the levels for nodes in this subtree.
  -- Tree line k = levels[k] (direct mapping; no root offset).
  local copied_levels = {}
  local idx = ctx.tlnum
  local sub_count = M.count_subnodes(ctx.levels, ctx.tlnum)
  for i = idx, idx + sub_count do
    table.insert(copied_levels, ctx.levels[i])
  end

  clipboard = {
    body_lines = body_lines,
    levels = copied_levels,
  }

  local node_count = #copied_levels
  vim.api.nvim_echo(
    {
      {
        string.format("VOoM: copied %d node%s", node_count, node_count == 1 and "" or "s"),
        "Normal",
      },
    },
    true,
    {}
  )
end

-- ==============================================================================
-- cut_node (dd)
-- ==============================================================================

-- Cut the current node and its subtree: copy to clipboard, then remove.
function M.cut_node(tree_buf)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end
  local outline_state = state.get_outline_state(ctx.body_buf)
  local mode_name = state.get_mode(ctx.body_buf)
  if not mode_name then
    return
  end
  local mode = modes.get(mode_name)

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local tlnum = ctx.tlnum
  local total_body = ctx.total_body

  -- Compute the tree line range for the subtree being cut.
  -- Tree line k = levels[k] / bnodes[k] (direct mapping; no root offset).
  local ln1 = tlnum -- levels/bnodes index of first node
  local sub_count = M.count_subnodes(levels, tlnum)
  local ln2 = ln1 + sub_count -- levels/bnodes index of last node in subtree

  -- Body range.
  local bln1 = bnodes[ln1]
  local bln2
  if ln2 < #bnodes then
    bln2 = bnodes[ln2 + 1] - 1
  else
    bln2 = total_body
  end

  -- Copy to clipboard before removing.
  local cut_body_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, bln1 - 1, bln2, false)
  local cut_levels = {}
  for i = ln1, ln2 do
    table.insert(cut_levels, levels[i])
  end
  clipboard = { body_lines = cut_body_lines, levels = cut_levels }

  -- Read all body lines, delete the range, apply post-processing.
  local all_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, 0, -1, false)

  -- Delete the range from the lines table.
  for _ = bln1, bln2 do
    table.remove(all_lines, bln1)
  end

  -- Update bnodes: decrement entries after the deleted range, then remove.
  local delta = bln2 - bln1 + 1
  local new_bnodes = {}
  local new_levels = {}
  for i = 1, #bnodes do
    if i < ln1 then
      table.insert(new_bnodes, bnodes[i])
      table.insert(new_levels, levels[i])
    elseif i > ln2 then
      table.insert(new_bnodes, bnodes[i] - delta)
      table.insert(new_levels, levels[i])
    end
    -- Skip indices ln1..ln2 (the cut range).
  end

  -- Call do_body_after_oop("cut") for blank-line cleanup.
  -- blnum_cut = bln1 - 1 (body line at the junction, in the post-delete table).
  -- tlnum_cut = ln1 - 1 (bnodes index of node just before the cut).
  -- We need the index into the new (post-cut) bnodes array.  Since we removed
  -- entries ln1..ln2, the node at old index ln1-1 is now at new index ln1-1.
  if mode and mode.do_body_after_oop and outline_state then
    local blnum_cut = bln1 - 1
    local tlnum_cut = ln1 - 1
    -- Only call if the cut boundary is valid.
    if blnum_cut > 0 and tlnum_cut >= 1 then
      mode.do_body_after_oop(
        all_lines,
        new_bnodes,
        new_levels,
        outline_state,
        "cut",
        0,
        0,
        0, -- blnum1, tlnum1 (not used for cut)
        0,
        0, -- blnum2, tlnum2 (not used for cut)
        blnum_cut,
        tlnum_cut
      )
    end
  end

  -- Write back to buffer.
  write_body(ctx.body_buf, all_lines)
  refresh_after_edit(ctx.body_buf)

  -- Position cursor on the node above the deleted range.
  local target_tlnum = tlnum - 1
  if target_tlnum < 1 then
    target_tlnum = 1
  end
  -- Clamp to valid range after refresh.
  local new_outline = state.get_outline(ctx.body_buf)
  if new_outline then
    local max_tlnum = #new_outline.bnodes
    if target_tlnum > max_tlnum then
      target_tlnum = max_tlnum
    end
  end

  state.set_snLn(ctx.body_buf, target_tlnum)
  if ctx.tree_win and vim.api.nvim_win_is_valid(ctx.tree_win) then
    vim.api.nvim_win_set_cursor(ctx.tree_win, { target_tlnum, 0 })
  end

  local node_count = #cut_levels
  vim.api.nvim_echo(
    {
      { string.format("VOoM: cut %d node%s", node_count, node_count == 1 and "" or "s"), "Normal" },
    },
    true,
    {}
  )
end

-- ==============================================================================
-- paste_node (pp)
-- ==============================================================================

-- Paste the clipboard content after the current node.
function M.paste_node(tree_buf)
  if not clipboard.body_lines or #clipboard.body_lines == 0 then
    vim.api.nvim_echo({ { "VOoM (paste): clipboard is empty", "WarningMsg" } }, true, {})
    return
  end

  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end
  local outline_state = state.get_outline_state(ctx.body_buf)
  if not outline_state then
    return
  end
  local mode_name = state.get_mode(ctx.body_buf)
  if not mode_name then
    return
  end
  local mode = modes.get(mode_name)
  if not mode then
    return
  end

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local ln = ctx.tlnum
  local total_body = ctx.total_body

  -- Parse clipboard to get pasted outline structure.
  local p_blines = vim.deepcopy(clipboard.body_lines)
  local p_outline = mode.make_outline(p_blines, "")
  local p_bnodes = p_outline.bnodes
  local p_levels = p_outline.levels

  -- Validate clipboard: first line must be a heading.
  if #p_bnodes == 0 or p_bnodes[1] ~= 1 then
    vim.api.nvim_echo(
      { { "VOoM (paste): invalid clipboard — first line is not a headline", "ErrorMsg" } },
      true,
      {}
    )
    return
  end

  -- Validate: no node should have a level smaller than the first node.
  for _, lv in ipairs(p_levels) do
    if lv < p_levels[1] then
      vim.api.nvim_echo(
        { { "VOoM (paste): invalid clipboard — root level error", "ErrorMsg" } },
        true,
        {}
      )
      return
    end
  end

  -- Compute where to insert and at what level.
  local lev
  if ln == 1 then
    if #levels > 0 then
      lev = levels[1]
    else
      lev = 1
    end
  else
    lev = levels[ln - 1]
    -- Node has children — check fold state.
    if ln <= #levels and lev < levels[ln] then
      local fold_end = vim.api.nvim_win_call(ctx.tree_win, function()
        return vim.fn.foldclosedend(ln)
      end)
      if fold_end ~= -1 then
        -- Folded: insert after subtree.
        ln = ln + M.count_subnodes(levels, ln)
      else
        -- Not folded: insert as child.
        lev = lev + 1
      end
    end
  end

  -- Compute level delta.
  local lev_delta = lev - p_levels[1]

  -- Adjust pasted levels.
  if lev_delta ~= 0 then
    for i = 1, #p_levels do
      p_levels[i] = p_levels[i] + lev_delta
    end
  end

  -- Body lnum after which to insert.
  local bln_insert
  if ln <= #bnodes then
    -- Get end of current node's subtree.
    local _, bln2 = M.get_node_range(bnodes, levels, ln, total_body)
    bln_insert = bln2
  else
    bln_insert = total_body
  end

  -- Read all body lines and insert clipboard content.
  local all_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, 0, -1, false)
  for i, line in ipairs(p_blines) do
    table.insert(all_lines, bln_insert + i, line)
  end

  -- Update bnodes: increment pasted bnodes, increment bnodes after insertion.
  local new_bnodes = vim.deepcopy(bnodes)
  local new_levels = vim.deepcopy(levels)

  -- Increment bnodes of pasted nodes by bln_insert.
  local inserted_bnodes = {}
  for _, bn in ipairs(p_bnodes) do
    table.insert(inserted_bnodes, bn + bln_insert)
  end

  -- Increment existing bnodes after the insertion point.
  local insert_idx = ln -- levels/bnodes index after which to insert
  if ln == 1 then
    insert_idx = 0
  end
  local p_delta = #p_blines
  for i = insert_idx + 1, #new_bnodes do
    new_bnodes[i] = new_bnodes[i] + p_delta
  end

  -- Insert pasted bnodes and levels.
  for i = #inserted_bnodes, 1, -1 do
    table.insert(new_bnodes, insert_idx + 1, inserted_bnodes[i])
    table.insert(new_levels, insert_idx + 1, p_levels[i])
  end

  -- Compute the tree line range of inserted region (1-indexed into bnodes).
  local tlnum1 = insert_idx + 1
  local tlnum2 = insert_idx + #p_bnodes

  -- Body range of the inserted region.
  local blnum1 = bln_insert + 1
  local blnum2 = bln_insert + #p_blines

  -- Call do_body_after_oop("paste") for format normalization.
  if mode.do_body_after_oop then
    mode.do_body_after_oop(
      all_lines,
      new_bnodes,
      new_levels,
      outline_state,
      "paste",
      lev_delta,
      blnum1,
      tlnum1,
      blnum2,
      tlnum2,
      0,
      0 -- blnum_cut, tlnum_cut not used for paste
    )
  end

  -- Write back.
  write_body(ctx.body_buf, all_lines)
  refresh_after_edit(ctx.body_buf)

  -- Position cursor on the first pasted node.
  -- tlnum1 is already a direct tree line (bnodes index = tree line; no root offset).
  local new_tlnum = tlnum1
  local new_outline = state.get_outline(ctx.body_buf)
  if new_outline then
    local max_tlnum = #new_outline.bnodes
    if new_tlnum > max_tlnum then
      new_tlnum = max_tlnum
    end
  end

  state.set_snLn(ctx.body_buf, new_tlnum)
  if ctx.tree_win and vim.api.nvim_win_is_valid(ctx.tree_win) then
    vim.api.nvim_win_set_cursor(ctx.tree_win, { new_tlnum, 0 })
  end
end

-- ==============================================================================
-- move_up (^^ / <C-Up>)
-- ==============================================================================

-- Move the current node (and its subtree) up, swapping with the previous
-- sibling.
function M.move_up(tree_buf)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end
  local outline_state = state.get_outline_state(ctx.body_buf)
  local mode_name = state.get_mode(ctx.body_buf)
  if not mode_name then
    return
  end
  local mode = modes.get(mode_name)

  local tlnum = ctx.tlnum
  if tlnum < 1 then
    return
  end -- cursor is always >=1; guard against impossible state

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local total_body = ctx.total_body

  -- Find previous sibling.
  local prev_sib = tree.find_prev_sibling_lnum(levels, tlnum)
  if not prev_sib then
    return
  end

  -- Tree line k = bnodes[k] / levels[k] (direct mapping; no root offset).
  local ln1 = tlnum -- bnodes index of first node being moved
  local sub_count = M.count_subnodes(levels, tlnum)
  local ln2 = ln1 + sub_count -- bnodes index of last node in subtree

  -- lnUp1: previous sibling root (bnodes index, direct = tree line).
  local lnUp1 = prev_sib

  -- Compute level delta.
  -- Move-up swaps sibling branches, so the moved root should take the previous
  -- sibling's level (and remain a sibling), regardless of descendants above.
  local lev_old = levels[ln1]
  local lev_new = levels[lnUp1]
  local lev_delta = lev_new - lev_old

  -- Body ranges.
  local bln1 = bnodes[ln1]
  local bln2
  if ln2 < #bnodes then
    bln2 = bnodes[ln2 + 1] - 1
  else
    bln2 = total_body
  end
  local bln_up1 = bnodes[lnUp1]

  -- Read all body lines.
  local all_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, 0, -1, false)

  -- Extract the lines being moved.
  local moved_lines = {}
  for i = bln1, bln2 do
    table.insert(moved_lines, all_lines[i])
  end

  -- Cut then insert: remove from old position, insert at new position.
  -- Since bln_up1 < bln1, removing from bln1..bln2 first doesn't affect bln_up1.
  for _ = bln1, bln2 do
    table.remove(all_lines, bln1)
  end
  for i = #moved_lines, 1, -1 do
    table.insert(all_lines, bln_up1, moved_lines[i])
  end

  -- Update bnodes: mirror the legacy approach.
  local new_bnodes = vim.deepcopy(bnodes)
  local new_levels = vim.deepcopy(levels)

  -- Increment bnodes in the "above" range (they shift down by moved size).
  local move_delta = bln2 - bln1 + 1
  for i = lnUp1, ln1 - 1 do
    new_bnodes[i] = new_bnodes[i] + move_delta
  end
  -- Decrement bnodes in the moved range (they shift up).
  local up_delta = bln1 - bln_up1
  for i = ln1, ln2 do
    new_bnodes[i] = new_bnodes[i] - up_delta
  end

  -- Cut then insert in bnodes and levels arrays.
  local n_bnodes = {}
  local n_levels = {}
  for i = ln1, ln2 do
    table.insert(n_bnodes, new_bnodes[i])
    table.insert(n_levels, new_levels[i] + lev_delta)
  end
  -- Remove old positions.
  for _ = ln1, ln2 do
    table.remove(new_bnodes, ln1)
    table.remove(new_levels, ln1)
  end
  -- Insert at new position.
  for i = #n_bnodes, 1, -1 do
    table.insert(new_bnodes, lnUp1, n_bnodes[i])
    table.insert(new_levels, lnUp1, n_levels[i])
  end

  -- Compute arguments for do_body_after_oop.
  local new_bln_show = bln_up1
  local new_ln1 = lnUp1
  local new_ln2 = lnUp1 + #n_levels - 1
  local blnum_cut = bln1 - 1 + #moved_lines -- body line at old position (post-insert)
  local tlnum_cut = ln1 - 1 + #n_levels -- bnodes index at old position

  if mode and mode.do_body_after_oop and outline_state then
    mode.do_body_after_oop(
      all_lines,
      new_bnodes,
      new_levels,
      outline_state,
      "up",
      lev_delta,
      new_bln_show,
      new_ln1,
      new_bln_show + #moved_lines - 1,
      new_ln2,
      blnum_cut,
      tlnum_cut
    )
  end

  -- Write back.
  write_body(ctx.body_buf, all_lines)
  refresh_after_edit(ctx.body_buf)

  -- Position cursor: the moved node is now at tree line lnUp1 (direct mapping).
  local new_tlnum = lnUp1
  state.set_snLn(ctx.body_buf, new_tlnum)
  if ctx.tree_win and vim.api.nvim_win_is_valid(ctx.tree_win) then
    vim.api.nvim_win_set_cursor(ctx.tree_win, { new_tlnum, 0 })
  end
end

-- ==============================================================================
-- move_down (__ / <C-Down>)
-- ==============================================================================

-- Move the current node (and its subtree) down, swapping with the next sibling.
function M.move_down(tree_buf)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end
  local outline_state = state.get_outline_state(ctx.body_buf)
  local mode_name = state.get_mode(ctx.body_buf)
  if not mode_name then
    return
  end
  local mode = modes.get(mode_name)

  local tlnum = ctx.tlnum
  if tlnum < 1 then
    return
  end -- cursor is always >=1; guard against impossible state

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local total_body = ctx.total_body

  -- Find next sibling.
  local next_sib = tree.find_next_sibling_lnum(levels, tlnum)
  if not next_sib then
    return
  end

  -- Tree line k = bnodes[k] / levels[k] (direct mapping; no root offset).
  local ln1 = tlnum -- bnodes index of first node being moved
  local sub_count = M.count_subnodes(levels, tlnum)
  local ln2 = ln1 + sub_count

  -- lnDn1: tree line (= bnodes index) of the sibling after which we move.
  local lnDn1 = next_sib

  -- Compute where to insert (after lnDn1's subtree).
  local lnIns = lnDn1
  local lev_old = levels[ln1]
  local lev_new = levels[lnDn1]

  if lnDn1 < #levels then
    -- lnDn1 has children — always insert after the full sibling branch.
    -- move_down is a sibling swap, so never insert as child based on fold state.
    if levels[lnDn1] < levels[lnDn1 + 1] then
      lnIns = lnDn1 + M.count_subnodes(levels, next_sib)
    end
  end

  local lev_delta = lev_new - lev_old

  -- Body ranges.
  local bln1 = bnodes[ln1]
  local bln2 = bnodes[ln2 + 1] and (bnodes[ln2 + 1] - 1) or total_body

  local bln_ins
  if lnIns < #bnodes then
    bln_ins = bnodes[lnIns + 1] - 1
  else
    bln_ins = total_body
  end

  -- Read all body lines.
  local all_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, 0, -1, false)

  -- Extract lines being moved.
  local moved_lines = {}
  for i = bln1, bln2 do
    table.insert(moved_lines, all_lines[i])
  end

  -- Insert then cut (order matters: insert first since insertion point is after).
  for i = #moved_lines, 1, -1 do
    table.insert(all_lines, bln_ins + 1, moved_lines[i])
  end
  for _ = bln1, bln2 do
    table.remove(all_lines, bln1)
  end

  -- Update bnodes.
  local new_bnodes = vim.deepcopy(bnodes)
  local new_levels = vim.deepcopy(levels)

  -- Increment moved range bnodes (they shift down).
  local down_delta = bln_ins - bln2
  for i = ln1, ln2 do
    new_bnodes[i] = new_bnodes[i] + down_delta
  end
  -- Decrement the "between" range bnodes (they shift up).
  local move_delta = bln2 - bln1 + 1
  for i = ln2 + 1, lnIns do
    new_bnodes[i] = new_bnodes[i] - move_delta
  end

  -- Insert then cut in arrays.
  local n_bnodes = {}
  local n_levels = {}
  for i = ln1, ln2 do
    table.insert(n_bnodes, new_bnodes[i])
    table.insert(n_levels, new_levels[i] + lev_delta)
  end

  -- Compute new snLn position.
  local new_snLn_idx = lnIns + 1 - (ln2 - ln1 + 1)

  -- Insert at new position, then cut old.
  for i = #n_bnodes, 1, -1 do
    table.insert(new_bnodes, lnIns + 1, n_bnodes[i])
    table.insert(new_levels, lnIns + 1, n_levels[i])
  end
  for _ = ln1, ln2 do
    table.remove(new_bnodes, ln1)
    table.remove(new_levels, ln1)
  end

  -- do_body_after_oop arguments.
  local bln_show = new_bnodes[new_snLn_idx]
  local blnum_cut = bln1 - 1
  local tlnum_cut = ln1 - 1

  if mode and mode.do_body_after_oop and outline_state then
    mode.do_body_after_oop(
      all_lines,
      new_bnodes,
      new_levels,
      outline_state,
      "down",
      lev_delta,
      bln_show,
      new_snLn_idx,
      bln_show + #moved_lines - 1,
      new_snLn_idx + #n_levels - 1,
      blnum_cut,
      tlnum_cut
    )
  end

  -- Write back.
  write_body(ctx.body_buf, all_lines)
  refresh_after_edit(ctx.body_buf)

  -- Position cursor at new location (new_snLn_idx is already a tree line).
  local new_tlnum = new_snLn_idx
  state.set_snLn(ctx.body_buf, new_tlnum)
  if ctx.tree_win and vim.api.nvim_win_is_valid(ctx.tree_win) then
    vim.api.nvim_win_set_cursor(ctx.tree_win, { new_tlnum, 0 })
  end
end

-- ==============================================================================
-- promote (<<  / <C-Left>)
-- ==============================================================================

-- Promote (decrease heading level by 1) for the current node.
function M.promote(tree_buf)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end
  local outline_state = state.get_outline_state(ctx.body_buf)
  local mode_name = state.get_mode(ctx.body_buf)
  if not mode_name then
    return
  end
  local mode = modes.get(mode_name)

  local tlnum = ctx.tlnum
  if tlnum < 1 then
    return
  end -- cursor is always >=1; guard against impossible state

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local total_body = ctx.total_body

  -- Tree line k = bnodes[k] / levels[k] (direct mapping; no root offset).
  local ln1 = tlnum
  local ln2 = ln1

  -- Check: cannot promote if any node in the range is already at level 1.
  for i = ln1, ln2 do
    if levels[i] <= 1 then
      vim.api.nvim_echo(
        { { "VOoM: cannot promote — already at top level", "WarningMsg" } },
        true,
        {}
      )
      return
    end
  end

  -- Read body lines and create working copies of bnodes/levels.
  local all_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, 0, -1, false)
  local new_bnodes = vim.deepcopy(bnodes)
  local new_levels = vim.deepcopy(levels)

  -- Decrement levels.
  for i = ln1, ln2 do
    new_levels[i] = new_levels[i] - 1
  end

  -- Body range.
  local blnum1 = bnodes[ln1]
  local blnum2
  if ln2 < #bnodes then
    blnum2 = bnodes[ln2 + 1] - 1
  else
    blnum2 = total_body
  end

  -- Call do_body_after_oop for format changes (ATX ↔ setext etc.)
  if mode and mode.do_body_after_oop and outline_state then
    mode.do_body_after_oop(
      all_lines,
      new_bnodes,
      new_levels,
      outline_state,
      "left",
      -1,
      blnum1,
      ln1,
      blnum2,
      ln2,
      0,
      0
    )
  end

  -- Write back.
  write_body(ctx.body_buf, all_lines)
  refresh_after_edit(ctx.body_buf)

  -- Keep cursor on the same node.
  state.set_snLn(ctx.body_buf, tlnum)
  if ctx.tree_win and vim.api.nvim_win_is_valid(ctx.tree_win) then
    vim.api.nvim_win_set_cursor(ctx.tree_win, { tlnum, 0 })
  end
end

-- ==============================================================================
-- demote (>> / <C-Right>)
-- ==============================================================================

-- Demote (increase heading level by 1) for the current node.
function M.demote(tree_buf)
  local ctx = resolve_tree_ctx(tree_buf)
  if not ctx then
    return
  end
  local outline_state = state.get_outline_state(ctx.body_buf)
  local mode_name = state.get_mode(ctx.body_buf)
  if not mode_name then
    return
  end
  local mode = modes.get(mode_name)

  local tlnum = ctx.tlnum
  if tlnum < 1 then
    return
  end -- cursor is always >=1; guard against impossible state

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local total_body = ctx.total_body

  -- Tree line k = bnodes[k] / levels[k] (direct mapping; no root offset).
  local ln1 = tlnum
  local ln2 = ln1

  -- Check: cannot demote if it's already a child of the preceding node.
  -- levels[ln1] = level of current node; levels[ln1-1] = level of previous node.
  if ln1 > 1 and levels[ln1] > levels[ln1 - 1] then
    vim.api.nvim_echo(
      { { "VOoM: cannot demote — already a child of previous node", "WarningMsg" } },
      true,
      {}
    )
    return
  end

  -- Check: cannot demote beyond level 6 (Markdown limit).
  for i = ln1, ln2 do
    if levels[i] >= 6 then
      vim.api.nvim_echo(
        { { "VOoM: cannot demote — already at maximum level", "WarningMsg" } },
        true,
        {}
      )
      return
    end
  end

  -- Read body lines and create working copies.
  local all_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, 0, -1, false)
  local new_bnodes = vim.deepcopy(bnodes)
  local new_levels = vim.deepcopy(levels)

  -- Increment levels.
  for i = ln1, ln2 do
    new_levels[i] = new_levels[i] + 1
  end

  -- Body range.
  local blnum1 = bnodes[ln1]
  local blnum2
  if ln2 < #bnodes then
    blnum2 = bnodes[ln2 + 1] - 1
  else
    blnum2 = total_body
  end

  -- Call do_body_after_oop for format changes.
  if mode and mode.do_body_after_oop and outline_state then
    mode.do_body_after_oop(
      all_lines,
      new_bnodes,
      new_levels,
      outline_state,
      "right",
      1,
      blnum1,
      ln1,
      blnum2,
      ln2,
      0,
      0
    )
  end

  -- Write back.
  write_body(ctx.body_buf, all_lines)
  refresh_after_edit(ctx.body_buf)

  -- Keep cursor on the same node.
  state.set_snLn(ctx.body_buf, tlnum)
  if ctx.tree_win and vim.api.nvim_win_is_valid(ctx.tree_win) then
    vim.api.nvim_win_set_cursor(ctx.tree_win, { tlnum, 0 })
  end
end

-- ==============================================================================
-- Buffer-context sort
-- ==============================================================================
--
-- Sort accepts either a body or tree buffer and resolves its own context.
-- Its entry semantics differ from tree-initiated edits: it looks up the
-- tree buffer from the body (rather than vice versa), and operates on a
-- sibling group rather than the cursor node's subtree.

-- ==============================================================================
-- sort (VoomSort)
-- ==============================================================================

-- Sort sibling nodes under the current node's parent.
--
-- @param body_buf    number  body buffer number
-- @param args_string string  space-separated options: deep, i, r, flip, shuffle
function M.sort(body_buf, args_string)
  -- Accept either tree or body buffer.
  if state.is_tree(body_buf) then
    body_buf = state.get_body(body_buf)
  end
  if not state.is_body(body_buf) then
    return
  end
  local outline = state.get_outline(body_buf)
  if not outline then
    return
  end

  local tree_buf = state.get_tree(body_buf)
  if not tree_buf then
    return
  end
  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then
    return
  end

  local bnodes = outline.bnodes
  local levels = outline.levels
  local total_body = vim.api.nvim_buf_line_count(body_buf)

  -- Parse options.
  local opts = {}
  for word in (args_string or ""):gmatch("%S+") do
    opts[word] = true
  end

  local tlnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local selected_chunk

  -- Find the parent to identify the sibling group to sort.
  local first_sib = tree.find_first_sibling_lnum(levels, tlnum)
  local last_sib = tree.find_last_sibling_lnum(levels, tlnum)

  -- Collect sibling chunks: each sibling + its subtree is one chunk.
  -- Tree line k = bnodes[k] / levels[k] (direct mapping; no root offset).
  local chunks = {} -- { { tlnum_start, tlnum_end, bln1, bln2, sort_key, body_lines } }
  local sib = first_sib
  while sib do
    local sib_idx = sib -- direct mapping: tree line = bnodes/levels index
    local sub_count = M.count_subnodes(levels, sib)
    local sib_end = sib_idx + sub_count -- last bnodes index in this branch

    local bln1 = bnodes[sib_idx]
    local bln2
    if sib_end < #bnodes then
      bln2 = bnodes[sib_end + 1] - 1
    else
      bln2 = total_body
    end

    local body_lines = vim.api.nvim_buf_get_lines(body_buf, bln1 - 1, bln2, false)

    -- Sort key: heading text of the sibling node.
    local heading_line = body_lines[1] or ""
    local sort_key = heading_line:gsub("^#+%s*", ""):gsub("%s*#+%s*$", "")
    if opts.i then
      sort_key = sort_key:lower()
    end

    table.insert(chunks, {
      tlnum_start = sib,
      tlnum_end = sib + sub_count,
      bln1 = bln1,
      bln2 = bln2,
      sort_key = sort_key,
      body_lines = body_lines,
      levels_slice = (function()
        local sl = {}
        for i = sib_idx, sib_end do
          table.insert(sl, levels[i])
        end
        return sl
      end)(),
    })
    if sib == tlnum then
      selected_chunk = chunks[#chunks]
    end

    -- Advance to next sibling.
    if sib > last_sib then
      break
    end
    local next = tree.find_next_sibling_lnum(levels, sib)
    if not next or next > last_sib + M.count_subnodes(levels, last_sib) then
      break
    end
    sib = next
  end

  if #chunks < 2 then
    return
  end

  -- Sort the chunks.
  if opts.shuffle then
    -- Fisher-Yates shuffle.
    math.randomseed(os.time())
    for i = #chunks, 2, -1 do
      local j = math.random(1, i)
      chunks[i], chunks[j] = chunks[j], chunks[i]
    end
  elseif opts.flip then
    -- Reverse the current order.
    local n = #chunks
    for i = 1, math.floor(n / 2) do
      chunks[i], chunks[n - i + 1] = chunks[n - i + 1], chunks[i]
    end
  else
    -- Alphabetical sort.
    table.sort(chunks, function(a, b)
      if opts.r then
        return a.sort_key > b.sort_key
      else
        return a.sort_key < b.sort_key
      end
    end)
  end

  -- TODO: implement `deep` option (recursive sort of children).

  -- Rebuild the body by replacing the sibling range with sorted chunks.
  -- We need the original first and last body lines of the entire sibling group.
  local orig_bln1 = bnodes[first_sib]
  local orig_bln2
  local last_sib_end = last_sib + M.count_subnodes(levels, last_sib)
  if last_sib_end < #bnodes then
    orig_bln2 = bnodes[last_sib_end + 1] - 1
  else
    orig_bln2 = total_body
  end

  -- Collect all sorted body lines.
  local sorted_lines = {}
  for _, chunk in ipairs(chunks) do
    for _, line in ipairs(chunk.body_lines) do
      table.insert(sorted_lines, line)
    end
  end

  -- Replace in buffer.
  vim.api.nvim_buf_set_lines(body_buf, orig_bln1 - 1, orig_bln2, false, sorted_lines)
  refresh_after_edit(body_buf)

  -- Keep the same root node selected after sorting.
  if selected_chunk then
    local selected_tlnum = first_sib
    for _, chunk in ipairs(chunks) do
      if chunk == selected_chunk then
        break
      end
      selected_tlnum = selected_tlnum + #chunk.levels_slice
    end

    state.set_snLn(body_buf, selected_tlnum)
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_set_cursor(tree_win, { selected_tlnum, 0 })
    end
  end
end

return M
