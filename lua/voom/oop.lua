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

local config     = require("voom.config")
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
  -- Guard: tlnum must be a valid index in both parallel arrays.
  if tlnum < 1 or tlnum > #levels then return nil, nil end

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
  if idx < 1 or idx >= #levels then
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

-- Write `lines` (a Lua table) into the body buffer, replacing all content.
-- Each OOP command should create its own undo step in the body undo tree.
local function write_body(body_buf, lines)
  -- Apply from inside the body buffer context so undo history is segmented by
  -- each OOP command invocation (rather than coalescing non-current-buffer writes).
  vim.api.nvim_buf_call(body_buf, function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end)
end

-- Resolve the mode module and outline style preferences for a body buffer.
--
-- Most mutating commands need mode + outline_state for do_body_after_oop()
-- or new_headline().  Commands with strict requirements (insert_node,
-- paste_node) nil-check the return values and early-return; commands with
-- lenient requirements (cut, move, promote/demote) guard at the call site.
--
-- @return mode|nil, outline_state|nil
local function resolve_mode(body_buf)
  local mode_name = state.get_mode(body_buf)
  if not mode_name then return nil, nil end
  return modes.get(mode_name), state.get_outline_state(body_buf)
end

-- Set the selected tree line and move the tree-window cursor to match.
--
-- This is the shared Phase 5 primitive: after a structural edit and refresh,
-- every command needs to persist the new snLn and position the tree cursor.
-- Safe to call with an invalid or nil tree_win.
local function select_node(body_buf, tree_win, tlnum)
  state.set_snLn(body_buf, tlnum)
  if tree_win and vim.api.nvim_win_is_valid(tree_win) then
    vim.api.nvim_win_set_cursor(tree_win, { tlnum, 0 })
  end
end

-- After a refresh, find the tree line whose bnode equals `body_lnum`.
--
-- insert_node uses this to locate the newly created heading in the
-- refreshed outline.  Returns the tree line number, or nil if not found.
local function tree_lnum_after_refresh(body_buf, body_lnum)
  local outline = state.get_outline(body_buf)
  if not outline then return nil end
  for i, bn in ipairs(outline.bnodes) do
    if bn == body_lnum then return i end
  end
  return nil
end

-- Return the last body line for a subtree whose last bnodes index is
-- `ln_end`.  When `ln_end` is the final node, the range extends to
-- `total_body` (end of document).
--
-- This is the shared computation for the recurring pattern:
--   if ln_end < #bnodes then bnodes[ln_end + 1] - 1 else total_body end
local function body_line_end(bnodes, ln_end, total_body)
  if ln_end < #bnodes then
    return bnodes[ln_end + 1] - 1
  end
  return total_body
end

-- Compute the full tree-line and body-line range for a node's subtree.
--
-- Returns four values:
--   ln1  — first bnodes/levels index (= tlnum)
--   ln2  — last bnodes/levels index in the subtree
--   bln1 — first body line of the subtree
--   bln2 — last body line of the subtree
--
-- Used by cut, copy, move_up, move_down, and sort to avoid repeating the
-- same count_subnodes + body_line_end sequence.
local function node_subtree_range(bnodes, levels, tlnum, total_body)
  local ln1 = tlnum
  local sub_count = M.count_subnodes(levels, tlnum)
  local ln2 = ln1 + sub_count
  local bln1 = bnodes[ln1]
  local bln2 = body_line_end(bnodes, ln2, total_body)
  return ln1, ln2, bln1, bln2
end

-- Apply mode-specific format normalization, then write the body buffer.
--
-- Combines Phase 2b (normalization via do_body_after_oop) and Phase 3
-- (body write) into a single call.  The `norm` table carries named
-- do_body_after_oop arguments, replacing the positional-`0`-placeholder
-- pattern that was previously repeated in every mutating command.
--
-- norm fields (all optional, default to 0):
--   op         — operation name ("cut", "paste", "up", "down", "left", "right")
--   lev_delta  — level adjustment applied to the moved/promoted/demoted nodes
--   blnum1, tlnum1 — body line / tree line of the first affected node
--   blnum2, tlnum2 — body line / tree line of the last affected node
--   blnum_cut, tlnum_cut — body line / tree line at the cut junction
local function normalize_and_write(body_buf, mode, outline_state, all_lines, new_bnodes, new_levels, norm)
  if mode and mode.do_body_after_oop and outline_state then
    mode.do_body_after_oop(
      all_lines, new_bnodes, new_levels, outline_state,
      norm.op,
      norm.lev_delta or 0,
      norm.blnum1 or 0, norm.tlnum1 or 0,
      norm.blnum2 or 0, norm.tlnum2 or 0,
      norm.blnum_cut or 0, norm.tlnum_cut or 0
    )
  end
  write_body(body_buf, all_lines)
end

-- Post-write coordinator: handles phases 4–6 of the OOP flow.
--
-- Phase 4 — re-parse the body buffer, update state, refresh the tree
-- display, and sync the stored changedtick to prevent redundant re-parses
-- from the BufEnter autocommand.
--
-- Phase 5 — restore selection and cursor.  When `result` carries a
-- `target_tlnum`, the coordinator clamps it to the refreshed outline range
-- and updates both snLn and the tree-window cursor.  When `target_tlnum` is
-- nil but `target_body_lnum` is present, the coordinator resolves the tree
-- line by looking up the body line in the refreshed outline (used by
-- insert_node, whose new heading's tree position is only known after
-- refresh).  When `focus` is "body", the coordinator transfers focus to the
-- body window and places the cursor at `body_cursor`.
--
-- Phase 6 — optional status echo.  When `result.echo` is non-nil, the
-- coordinator calls nvim_echo with the provided chunks.
--
-- @param body_buf  number        body buffer
-- @param tree_win  number|nil    tree window handle (nil skips phases 5–6)
-- @param result    OopResult|nil post-edit result (nil performs refresh only)
local function refresh_after_edit(body_buf, tree_win, result)
  -- Phase 4: refresh outline and tree, sync changedtick.
  tree.update(body_buf)
  local tick = vim.api.nvim_buf_get_changedtick(body_buf)
  state.set_changedtick(body_buf, tick)

  if not result then return end

  -- Phase 5: restore selection and cursor.
  local target = result.target_tlnum
  if not target and result.target_body_lnum then
    target = tree_lnum_after_refresh(body_buf, result.target_body_lnum)
  end
  if target then
    local outline = state.get_outline(body_buf)
    if outline then
      target = math.max(1, math.min(target, #outline.bnodes))
    end
    select_node(body_buf, tree_win, target)
  end

  if result.focus == "body" and result.body_cursor then
    local body_win = find_win_for_buf(body_buf)
    if body_win then
      vim.api.nvim_set_current_win(body_win)
      vim.api.nvim_win_set_cursor(body_win, result.body_cursor)
    end
  end

  -- Phase 6: echo.
  if result.echo then
    vim.api.nvim_echo(result.echo, true, {})
  end
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
  local mode, outline_state = resolve_mode(ctx.body_buf)
  if not mode or not outline_state then
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

  -- The new heading's body line is bln_insert + offset (accounting for
  -- any blank separator that new_headline may have prepended).
  local new_bln = bln_insert + 1
  if #body_lines > 0 and body_lines[1] == "" then
    new_bln = new_bln + 1
  end

  -- Compute the body cursor position for the "NewHeadline" placeholder
  -- before refresh, since the body content is already written.
  local line = vim.api.nvim_buf_get_lines(ctx.body_buf, new_bln - 1, new_bln, false)[1] or ""
  local col_start = line:find("NewHeadline")

  refresh_after_edit(ctx.body_buf, ctx.tree_win, {
    target_body_lnum = new_bln,
    focus = "body",
    body_cursor = { new_bln, col_start and (col_start - 1) or 0 },
  })
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

  local ln1, ln2, bln1, bln2 = node_subtree_range(ctx.bnodes, ctx.levels, ctx.tlnum, ctx.total_body)

  -- Read the body lines for this subtree.
  local body_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, bln1 - 1, bln2, false)

  -- Collect the levels for nodes in this subtree.
  local copied_levels = {}
  for i = ln1, ln2 do
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
  local mode, outline_state = resolve_mode(ctx.body_buf)
  if not mode then
    return
  end

  local bnodes = ctx.bnodes
  local levels = ctx.levels
  local tlnum = ctx.tlnum

  -- Subtree range for the node being cut.
  local ln1, ln2, bln1, bln2 = node_subtree_range(bnodes, levels, tlnum, ctx.total_body)

  -- Copy to clipboard before removing.
  local cut_body_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, bln1 - 1, bln2, false)
  local cut_levels = {}
  for i = ln1, ln2 do
    table.insert(cut_levels, levels[i])
  end
  clipboard = { body_lines = cut_body_lines, levels = cut_levels }

  -- Read all body lines and delete the subtree range.
  local all_lines = vim.api.nvim_buf_get_lines(ctx.body_buf, 0, -1, false)
  for _ = bln1, bln2 do
    table.remove(all_lines, bln1)
  end

  -- Build post-cut bnodes/levels for mode normalization.
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

  -- Normalize blank lines at the cut junction and write.
  -- blnum_cut/tlnum_cut point to the node just before the cut boundary
  -- in the post-delete arrays (ln1-1 is unchanged since we removed ln1..ln2).
  local blnum_cut = bln1 - 1
  local tlnum_cut = ln1 - 1
  if blnum_cut > 0 and tlnum_cut >= 1 then
    normalize_and_write(ctx.body_buf, mode, outline_state, all_lines, new_bnodes, new_levels, {
      op = "cut", blnum_cut = blnum_cut, tlnum_cut = tlnum_cut,
    })
  else
    write_body(ctx.body_buf, all_lines)
  end

  local node_count = #cut_levels
  refresh_after_edit(ctx.body_buf, ctx.tree_win, {
    target_tlnum = math.max(1, tlnum - 1),
    focus = "tree",
    echo = {
      { string.format("VOoM: cut %d node%s", node_count, node_count == 1 and "" or "s"), "Normal" },
    },
  })
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
  local mode, outline_state = resolve_mode(ctx.body_buf)
  if not mode or not outline_state then
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

  -- Normalize pasted heading format and write.
  normalize_and_write(ctx.body_buf, mode, outline_state, all_lines, new_bnodes, new_levels, {
    op = "paste", lev_delta = lev_delta,
    blnum1 = blnum1, tlnum1 = tlnum1,
    blnum2 = blnum2, tlnum2 = tlnum2,
  })

  refresh_after_edit(ctx.body_buf, ctx.tree_win, {
    target_tlnum = tlnum1,
    focus = "tree",
  })
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
  local mode, outline_state = resolve_mode(ctx.body_buf)

  local tlnum = ctx.tlnum
  if tlnum < 1 then
    return
  end -- cursor is always >=1; guard against impossible state

  local bnodes = ctx.bnodes
  local levels = ctx.levels

  -- Find previous sibling.
  local prev_sib = tree.find_prev_sibling_lnum(levels, tlnum)
  if not prev_sib then
    return
  end

  -- Subtree range for the node being moved.
  local ln1, ln2, bln1, bln2 = node_subtree_range(bnodes, levels, tlnum, ctx.total_body)

  -- lnUp1: previous sibling root (bnodes index, direct = tree line).
  local lnUp1 = prev_sib

  -- Compute level delta.
  -- Move-up swaps sibling branches, so the moved root should take the previous
  -- sibling's level (and remain a sibling), regardless of descendants above.
  local lev_delta = levels[lnUp1] - levels[ln1]

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

  -- Normalize blank lines at old and new positions, then write.
  normalize_and_write(ctx.body_buf, mode, outline_state, all_lines, new_bnodes, new_levels, {
    op = "up", lev_delta = lev_delta,
    blnum1 = bln_up1, tlnum1 = lnUp1,
    blnum2 = bln_up1 + #moved_lines - 1, tlnum2 = lnUp1 + #n_levels - 1,
    blnum_cut = bln1 - 1 + #moved_lines, -- body line at old position (post-insert)
    tlnum_cut = ln1 - 1 + #n_levels,     -- bnodes index at old position
  })

  refresh_after_edit(ctx.body_buf, ctx.tree_win, {
    target_tlnum = lnUp1,
    focus = "tree",
  })
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
  local mode, outline_state = resolve_mode(ctx.body_buf)

  local tlnum = ctx.tlnum
  if tlnum < 1 then
    return
  end -- cursor is always >=1; guard against impossible state

  local bnodes = ctx.bnodes
  local levels = ctx.levels

  -- Find next sibling.
  local next_sib = tree.find_next_sibling_lnum(levels, tlnum)
  if not next_sib then
    return
  end

  -- Subtree range for the node being moved.
  local ln1, ln2, bln1, bln2 = node_subtree_range(bnodes, levels, tlnum, ctx.total_body)

  -- lnDn1: tree line (= bnodes index) of the sibling after which we move.
  local lnDn1 = next_sib

  -- Compute where to insert (after lnDn1's subtree).
  local lnIns = lnDn1
  if lnDn1 < #levels then
    -- lnDn1 has children — always insert after the full sibling branch.
    -- move_down is a sibling swap, so never insert as child based on fold state.
    if levels[lnDn1] < levels[lnDn1 + 1] then
      lnIns = lnDn1 + M.count_subnodes(levels, next_sib)
    end
  end

  local lev_delta = levels[lnDn1] - levels[ln1]
  local bln_ins = body_line_end(bnodes, lnIns, ctx.total_body)

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

  -- Normalize blank lines at old and new positions, then write.
  local bln_show = new_bnodes[new_snLn_idx]
  normalize_and_write(ctx.body_buf, mode, outline_state, all_lines, new_bnodes, new_levels, {
    op = "down", lev_delta = lev_delta,
    blnum1 = bln_show, tlnum1 = new_snLn_idx,
    blnum2 = bln_show + #moved_lines - 1, tlnum2 = new_snLn_idx + #n_levels - 1,
    blnum_cut = bln1 - 1, tlnum_cut = ln1 - 1,
  })

  refresh_after_edit(ctx.body_buf, ctx.tree_win, {
    target_tlnum = new_snLn_idx,
    focus = "tree",
  })
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
  local mode, outline_state = resolve_mode(ctx.body_buf)

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

  -- Normalize heading format for the new level, then write.
  local blnum1 = bnodes[ln1]
  local blnum2 = body_line_end(bnodes, ln2, total_body)
  normalize_and_write(ctx.body_buf, mode, outline_state, all_lines, new_bnodes, new_levels, {
    op = "left", lev_delta = -1,
    blnum1 = blnum1, tlnum1 = ln1,
    blnum2 = blnum2, tlnum2 = ln2,
  })

  refresh_after_edit(ctx.body_buf, ctx.tree_win, {
    target_tlnum = tlnum,
    focus = "tree",
  })
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
  local mode, outline_state = resolve_mode(ctx.body_buf)

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

  -- Normalize heading format for the new level, then write.
  local blnum1 = bnodes[ln1]
  local blnum2 = body_line_end(bnodes, ln2, total_body)
  normalize_and_write(ctx.body_buf, mode, outline_state, all_lines, new_bnodes, new_levels, {
    op = "right", lev_delta = 1,
    blnum1 = blnum1, tlnum1 = ln1,
    blnum2 = blnum2, tlnum2 = ln2,
  })

  refresh_after_edit(ctx.body_buf, ctx.tree_win, {
    target_tlnum = tlnum,
    focus = "tree",
  })
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

  -- Parse options, falling back to the configured default when the user
  -- provides no arguments (e.g. sort.default_opts = "i" sorts
  -- case-insensitively by default).
  local effective_args = (args_string ~= nil and args_string ~= "") and args_string
    or (config.options.sort and config.options.sort.default_opts)
    or config.defaults.sort.default_opts
  local opts = {}
  for word in effective_args:gmatch("%S+") do
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
    local sib_idx, sib_end, bln1, bln2 = node_subtree_range(bnodes, levels, sib, total_body)
    local sub_count = sib_end - sib_idx

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

  -- Detect whether the sibling group uses blank-line separators *between*
  -- siblings (blank at the trailing end of a chunk's body_lines) before we
  -- reorder them.  When separator-style blanks are present we normalise every
  -- inter-chunk boundary in the sorted output to exactly one blank line, so
  -- that reordering cannot leave two adjacent headings without a separator.
  --
  -- Documents that place blanks *inside* sections (blank after heading rather
  -- than after the body) produce no trailing blanks on non-last chunks and are
  -- left untouched.
  local use_separator_blanks = false
  for i = 1, #chunks - 1 do
    local bl = chunks[i].body_lines
    if #bl > 0 and bl[#bl]:match("^%s*$") then
      use_separator_blanks = true
      break
    end
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
  local _, _, _, orig_bln2 = node_subtree_range(bnodes, levels, last_sib, total_body)

  -- Collect all sorted body lines.
  local sorted_lines = {}
  for i, chunk in ipairs(chunks) do
    local is_last = (i == #chunks)
    if use_separator_blanks and not is_last then
      -- Strip trailing blanks from this chunk and emit exactly one blank
      -- separator so every inter-chunk boundary is consistently normalised.
      local last_content = #chunk.body_lines
      while last_content > 1 and chunk.body_lines[last_content]:match("^%s*$") do
        last_content = last_content - 1
      end
      for j = 1, last_content do
        table.insert(sorted_lines, chunk.body_lines[j])
      end
      table.insert(sorted_lines, "")
    else
      -- No separator normalisation: append verbatim.  The last chunk is always
      -- preserved as-is so its trailing content (e.g. blank before the next
      -- non-sibling node) is not disturbed.
      for _, line in ipairs(chunk.body_lines) do
        table.insert(sorted_lines, line)
      end
    end
  end

  -- Replace in buffer.  Wrap in nvim_buf_call so the write creates a proper
  -- undo step in the body buffer's undo tree, consistent with write_body()
  -- used by other OOP commands (matters when sort is invoked from the tree).
  vim.api.nvim_buf_call(body_buf, function()
    vim.api.nvim_buf_set_lines(0, orig_bln1 - 1, orig_bln2, false, sorted_lines)
  end)

  -- Track the selected node through the reorder so the cursor stays on it.
  local target_tlnum
  if selected_chunk then
    target_tlnum = first_sib
    for _, chunk in ipairs(chunks) do
      if chunk == selected_chunk then
        break
      end
      target_tlnum = target_tlnum + #chunk.levels_slice
    end
  end

  refresh_after_edit(body_buf, tree_win, {
    target_tlnum = target_tlnum,
    focus = "tree",
  })
end

return M
