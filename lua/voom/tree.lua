-- Tree buffer/window lifecycle and navigation for VOoM.
--
-- This module owns:
--   - creating and destroying the read-only outline panel
--   - populating the panel from a mode's make_outline() result
--   - keymaps that let the user navigate from the tree to the body
--   - outline traversal utilities (parent / sibling / child lookups)
--   - body→tree selection sync (body_select)
--   - auto-refresh when the body is saved or re-entered after edits
--
-- The tree buffer is a scratch/nofile buffer.  Its lines have the format:
--   Line k : heading → " [· ]*· {heading_text}"   (from mode.tlines)
--
-- Index mapping: tree line k ↔ bnodes[k] / levels[k] (direct 1:1).
-- The levels/bnodes arrays stored in state are 1-indexed parallel arrays:
--   levels[i]  = heading depth (1–6)
--   bnodes[i]  = body line number of heading i

local M = {}

local config     = require("voom.config")
local modes      = require("voom.modes")
local state      = require("voom.state")
local tree_utils = require("voom.tree_utils")

-- Extmark namespaces created once at module load; Neovim returns the same
-- integer for repeated calls with the same name.
local FOLD_NS  = vim.api.nvim_create_namespace("voom_fold_indicators")
local GUIDE_NS = vim.api.nvim_create_namespace("voom_indent_guides")
local HEAD_NS  = vim.api.nvim_create_namespace("voom_headings")
local BADGE_NS = vim.api.nvim_create_namespace("voom_badges")

-- Per-body history for tree-initiated structural operations.  This guarantees
-- one tree undo step per tree action even when Neovim coalesces underlying
-- buffer writes in the body undo tree.
--
-- shape: [body_buf] = { undo_stack = {entry,...}, redo_stack = {entry,...} }
-- entry: {
--   before_lines = {string,...},
--   after_lines  = {string,...},
--   before_lnum  = int,
--   after_lnum   = int,
-- }
local TREE_HISTORY = {}

-- ==============================================================================
-- Internal helpers
-- ==============================================================================

-- Return the effective tree width, falling back to the default when setup()
-- has not been called by the user.
local function tree_width()
  return (config.options and config.options.tree_width)
    or config.defaults.tree_width
end

local find_win_for_buf = tree_utils.find_win_for_buf

-- Write `lines` into `buf`, temporarily enabling modifiability.
local function write_lines(buf, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Truncate heading `text` to fit within `max_cols - prefix_width` display
-- columns, appending `…` when truncation is needed.  Returns `text` unchanged
-- when it already fits.
-- `prefix_width`: columns consumed by the leading space + indent + "· ".
local function truncate_heading(text, prefix_width, max_cols)
  local available = max_cols - prefix_width
  if vim.fn.strdisplaywidth(text) <= available then
    return text
  end
  local truncated = text
  while vim.fn.strdisplaywidth(truncated .. "…") > available do
    -- Drop one byte at a time.  Safe for ASCII; for multibyte strings this
    -- may need a few extra iterations but never produces corrupt output.
    truncated = truncated:sub(1, -2)
  end
  return truncated .. "…"
end

-- Return the list of tree display lines from outline data, truncating each
-- heading so it fits within `max_cols` display columns.
-- The winbar now carries the filename, so the tree is a pure heading list.
local function build_tree_lines(outline, max_cols)
  local result = {}
  for i, tline in ipairs(outline.tlines) do
    local lev = outline.levels[i]
    -- Prefix layout per Item 2: 1 leading space + (lev-1)*2 indent bytes
    -- + "· " (2 bytes) = 1 + lev*2 columns total.
    local prefix_width = 1 + lev * 2
    local head         = tline:sub(prefix_width + 1)
    result[i]          = tline:sub(1, prefix_width)
                         .. truncate_heading(head, prefix_width, max_cols)
  end
  return result
end

local heading_text_from_tree_line = tree_utils.heading_text_from_tree_line

-- ==============================================================================
-- Fold-state indicator helpers
-- ==============================================================================

-- Define highlight groups used by the fold-state icon extmarks.
--
-- All groups use `default = true` so that colorschemes (and users' init.lua)
-- can override them without the plugin overwriting their preferences.
local function define_highlights()
  vim.api.nvim_set_hl(0, "VoomFoldOpen",    { default = true, fg = "#7aa2f7" }) -- ▾ blue
  vim.api.nvim_set_hl(0, "VoomFoldClosed",  { default = true, fg = "#e0af68" }) -- ▶ amber
  vim.api.nvim_set_hl(0, "VoomLeafNode",    { default = true, fg = "#565f89" }) -- · muted grey
  vim.api.nvim_set_hl(0, "VoomIndentGuide", { default = true, fg = "#3b4261" }) -- │ dark grey
  vim.api.nvim_set_hl(0, "VoomBadge",       { default = true, fg = "#565f89", italic = true }) -- +N muted

  -- Link per-level heading groups to the treesitter markdown heading groups so
  -- colors automatically adapt to any colorscheme.  `default = true` means a
  -- user's :hi override (or a colorscheme's explicit set) takes precedence.
  -- When the linked group is absent (no treesitter), Neovim silently clears
  -- the group — a safe no-op rather than rendering wrong colors.
  local heading_links = {
    "@markup.heading.1.markdown",
    "@markup.heading.2.markdown",
    "@markup.heading.3.markdown",
    "@markup.heading.4.markdown",
    "@markup.heading.5.markdown",
    "@markup.heading.6.markdown",
  }
  for i, group in ipairs(heading_links) do
    vim.api.nvim_set_hl(0, "VoomHeading" .. i, { default = true, link = group })
  end
end

-- Re-apply highlights whenever the colorscheme changes so user theme overrides
-- take effect without a plugin reload.
vim.api.nvim_create_autocmd("ColorScheme", {
  group    = vim.api.nvim_create_augroup("voom_highlights", { clear = true }),
  callback = define_highlights,
})

define_highlights()

-- Apply vertical guide-line extmarks at each ancestor column of every heading.
--
-- For a heading at level N, guide characters are overlaid at the first byte of
-- each ancestor indentation slot (levels 1 through N-1).  The tree line format
-- is " " + string.rep("  ", lev-1) + "· " + text, so each indentation slot is
-- 2 plain bytes wide and ancestor level A occupies bytes [1+(A-1)*2, 1+(A-1)*2+1).
--
-- Called from apply_fold_indicators so that all rendering happens in one pass
-- from every existing call site.
local function render_indent_guides(tree_buf, outline)
  vim.api.nvim_buf_clear_namespace(tree_buf, GUIDE_NS, 0, -1)

  local cfg = (config.options and config.options.indent_guides)
    or config.defaults.indent_guides
  if not cfg.enabled then return end

  local levels = outline.levels

  for idx, lev in ipairs(levels) do
    -- extmark rows are 0-indexed; tree line idx maps to extmark row idx-1.
    local row = idx - 1
    for ancestor = 1, lev - 1 do
      -- Each indentation slot is 2 bytes ("  "); guide overlays the first byte.
      local col = 1 + (ancestor - 1) * 2
      vim.api.nvim_buf_set_extmark(tree_buf, GUIDE_NS, row, col, {
        end_col       = col + 1,
        virt_text     = { { cfg.char, "VoomIndentGuide" } },
        virt_text_pos = "overlay",
      })
    end
  end
end

-- Apply `VoomHeadingN` highlights to the text portion of every heading line.
--
-- The heading text starts after the leading space, the (lev-1)*2 indent bytes,
-- and the 2-byte "· " icon placeholder, so text_col = 1 + (lev-1)*2 + 2.
-- Levels beyond 6 are clamped to VoomHeading6.
--
-- Called from apply_fold_indicators alongside render_indent_guides so all
-- decoration happens in a single pass from every call site.
local function render_heading_highlights(tree_buf, outline)
  vim.api.nvim_buf_clear_namespace(tree_buf, HEAD_NS, 0, -1)

  local levels = outline.levels

  for idx, lev in ipairs(levels) do
    -- extmark rows are 0-indexed; levels[idx] lives on tree line idx (1-indexed)
    -- = extmark row idx-1.
    local row      = idx - 1
    local hl       = "VoomHeading" .. math.min(lev, 6)
    local text_col = 1 + (lev - 1) * 2 + 2
    vim.api.nvim_buf_add_highlight(tree_buf, HEAD_NS, hl, row, text_col, -1)
  end
end

-- Append an end-of-line virtual-text badge "+N" on each collapsed parent node,
-- where N is the total number of descendants (direct + indirect children) hidden
-- by the fold.
--
-- The badge is rendered as EOL virtual text so it never displaces heading text.
-- Only collapsed folds receive a badge; expanded parents and leaf nodes are left
-- unmarked.  The count covers all strictly-deeper consecutive entries in
-- levels[], which equals the entire subtree rooted at that node.
--
-- Called from apply_fold_indicators after the fold icons have been placed.
-- BADGE_NS is pre-cleared by apply_fold_indicators before this is called.
local function render_count_badges(tree_win, tree_buf, outline)
  local levels = outline.levels

  vim.api.nvim_win_call(tree_win, function()
    for idx, lev in ipairs(levels) do
      -- Count all descendants: walk forward until we hit a node at the same
      -- or higher (shallower) level, which terminates the subtree.
      local n_descendants = 0
      for j = idx + 1, #levels do
        if levels[j] > lev then
          n_descendants = n_descendants + 1
        else
          break
        end
      end
      if n_descendants == 0 then goto continue end

      -- Tree lines and levels[] are both 1-indexed (no root line; the filename
      -- lives in the winbar).  foldclosed() takes a 1-indexed vim line number.
      local vim_line = idx
      if vim.fn.foldclosed(vim_line) == -1 then goto continue end  -- fold is open

      -- Extmark rows are 0-indexed.
      vim.api.nvim_buf_set_extmark(tree_buf, BADGE_NS, idx - 1, 0, {
        virt_text     = { { "+" .. n_descendants, "VoomBadge" } },
        virt_text_pos = "eol",
      })

      ::continue::
    end
  end)
end

-- Apply virtual-text fold-state icons to every heading line in `tree_buf`.
--
-- The icon placeholder · in each heading line is overlaid (not replaced in the
-- buffer) with one of three icons:
--   ▾  — parent node, subtree visible
--   ▶  — parent node, subtree folded
--   ·  — leaf node (no children)
--
-- Icons are placed via nvim_buf_set_extmark with virt_text_pos="overlay",
-- which requires no conceallevel setting and does not modify buffer text.
-- All existing extmarks in FOLD_NS are cleared before re-applying so that
-- stale marks never linger after structural edits that change the line count.
--
-- Also calls render_indent_guides() so all decorations stay in sync from every
-- existing call site without needing separate wiring.
--
-- Fold state is queried with foldclosed() inside nvim_win_call so the result
-- reflects the tree window's fold state regardless of which window is current.
-- If the tree window is not visible (e.g. during a headless test), the
-- function returns early without placing any fold marks (guides still render).
function M.apply_fold_indicators(tree_buf, body_buf)
  if not vim.api.nvim_buf_is_valid(tree_buf) then return end

  -- Read config, falling back to defaults if setup() has not been called.
  local cfg = (config.options and config.options.fold_indicators)
    or config.defaults.fold_indicators

  -- Always clear stale fold marks and badges first, even when the feature is
  -- disabled, so toggling the feature off removes lingering decorations.
  vim.api.nvim_buf_clear_namespace(tree_buf, FOLD_NS,  0, -1)
  vim.api.nvim_buf_clear_namespace(tree_buf, BADGE_NS, 0, -1)

  -- Fetch outline before the early-return so guides can render independently
  -- of whether fold indicators are enabled.
  local outline = body_buf and state.get_outline(body_buf)
  if not outline then return end

  render_indent_guides(tree_buf, outline)
  render_heading_highlights(tree_buf, outline)

  if not cfg.enabled then return end

  -- Fold state is window-local; we must query from inside the tree window.
  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local levels  = outline.levels
  local n_nodes = #levels
  local icons   = cfg.icons

  -- Every tree line is a heading; tree line k ↔ levels[k].
  -- Use n_nodes (not n_lines) to guard against the empty-buffer edge case
  -- where Neovim reports 1 line even when the tree has no headings yet.
  for lnum = 1, n_nodes do
    local idx = lnum   -- 1-based index into levels[]

    -- A node has children when the immediately following entry in levels[] is
    -- strictly deeper.  The last node always has nil at idx+1 → leaf.
    local has_children = (levels[idx + 1] ~= nil)
      and (levels[idx + 1] > levels[idx])

    local icon, hl
    if has_children then
      -- foldclosed(lnum) returns lnum when that line is a closed fold start,
      -- or -1 when the line is visible (open or not a fold boundary).
      local fold_start = vim.api.nvim_win_call(tree_win, function()
        return vim.fn.foldclosed(lnum)
      end)
      if fold_start == lnum then
        icon, hl = icons.closed, "VoomFoldClosed"
      else
        icon, hl = icons.open,   "VoomFoldOpen"
      end
    else
      icon, hl = icons.leaf, "VoomLeafNode"
    end

    -- The icon-placeholder · sits at byte offset 1 + (lev-1)*2 (0-indexed).
    -- Indentation is now "  " (2 plain bytes per level); · is still 2-byte UTF-8.
    -- Format: " " + string.rep("  ", lev-1) + "· " + text
    local lev = levels[idx]
    local col = 1 + (lev - 1) * 2

    vim.api.nvim_buf_set_extmark(tree_buf, FOLD_NS, lnum - 1, col, {
      end_col       = col + 2,   -- · is 2 UTF-8 bytes
      virt_text     = { { icon, hl } },
      virt_text_pos = "overlay",
    })
  end

  render_count_badges(tree_win, tree_buf, outline)
end

-- ==============================================================================
-- Winbar helpers
-- ==============================================================================

-- Set the tree window's winbar to show the body filename and heading count.
--
-- The icon 󰈙 requires a Nerd Font; users without one can override the winbar
-- highlight or set a custom winbar after the tree is created.  We use
-- `default = false` (normal set_option_value) so the winbar updates
-- dynamically as the tree is rebuilt.
local function update_winbar(tree_win, body_buf)
  if not vim.api.nvim_win_is_valid(tree_win) then return end

  local outline = state.get_outline(body_buf)
  local count   = outline and #outline.levels or 0
  local name    = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(body_buf), ":t")
  -- Fall back to "[No Name]" for unnamed scratch buffers.
  if name == "" then name = "[No Name]" end

  vim.api.nvim_set_option_value(
    "winbar",
    " 󰈙 " .. name .. "  ·  " .. count .. " headings",
    { win = tree_win }
  )
end

-- ==============================================================================
-- Keymap helpers
-- ==============================================================================

-- Disable a list of normal-mode keys in `buf` by mapping them to <Nop>.
-- This prevents accidental text modification in the read-only tree buffer.
local function disable_keys(buf, keys)
  for _, key in ipairs(keys) do
    vim.api.nvim_buf_set_keymap(buf, "n", key, "<Nop>", { noremap = true, silent = true })
  end
end

local function lines_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function history_for_body(body_buf)
  local h = TREE_HISTORY[body_buf]
  if h then return h end
  h = { undo_stack = {}, redo_stack = {} }
  TREE_HISTORY[body_buf] = h
  return h
end

local function clear_history_for_body(body_buf)
  TREE_HISTORY[body_buf] = nil
end

local function apply_body_snapshot(body_buf, lines)
  vim.api.nvim_buf_call(body_buf, function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end)
end

local function restore_tree_cursor(tree_buf, body_buf, preferred_lnum)
  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end
  local max_lnum = vim.api.nvim_buf_line_count(tree_buf)
  if max_lnum < 1 then max_lnum = 1 end
  local lnum = math.max(1, math.min(preferred_lnum or 1, max_lnum))
  pcall(vim.api.nvim_win_set_cursor, tree_win, { lnum, 0 })
  state.set_snLn(body_buf, lnum)
  if vim.api.nvim_win_is_valid(tree_win) then
    vim.api.nvim_set_current_win(tree_win)
  end
end

-- Execute a structural tree operation and record a per-action snapshot for
-- deterministic tree-side undo/redo.
local function run_structural_action_with_history(tree_buf, fn)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  if not state.is_body(body_buf) then return end
  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local before_lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  local before_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]

  fn()

  local after_lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  if lines_equal(before_lines, after_lines) then
    return
  end

  local after_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local history = history_for_body(body_buf)
  table.insert(history.undo_stack, {
    before_lines = before_lines,
    after_lines  = after_lines,
    before_lnum  = before_lnum,
    after_lnum   = after_lnum,
  })
  history.redo_stack = {}
end

local tree_lnum_for_body_line = tree_utils.tree_lnum_for_body_line

-- ==============================================================================
-- Navigation
-- ==============================================================================

-- Jump from the current tree cursor position to the corresponding body line.
--
-- Called from the <CR> keymap inside the tree buffer.
-- `tree_buf` is passed explicitly so the function is testable without a
-- live window cursor.
function M.navigate_to_body(tree_buf, tree_lnum)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end

  -- Tree line k maps directly to bnodes[k].
  local outline = state.get_outline(body_buf)
  if not outline then return end
  local body_lnum = outline.bnodes[tree_lnum]
  if not body_lnum then return end

  state.set_snLn(body_buf, tree_lnum)

  -- Move focus to the body window and place the cursor on the target line.
  local body_win = find_win_for_buf(body_buf)
  if body_win then
    vim.api.nvim_set_current_win(body_win)
    vim.api.nvim_win_set_cursor(body_win, { body_lnum, 0 })
  end
end

-- Scroll the body window to the heading corresponding to `tree_lnum`, keeping
-- focus in the tree window.
--
-- This is the "stay in tree" counterpart to navigate_to_body().  It is called
-- by the CursorMoved autocommand to implement live cursor-follow as the user
-- moves through the tree with j/k or any other motion.
function M.follow_cursor(tree_buf, tree_lnum)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end

  -- Same bnode lookup as navigate_to_body: tree line k → bnodes[k].
  local outline = state.get_outline(body_buf)
  if not outline then return end
  local body_lnum = outline.bnodes[tree_lnum]
  if not body_lnum then return end

  -- Outline data can be stale temporarily (for example, when the body changed
  -- but the tree has not yet rebuilt).  Clamp to a valid body line so cursor
  -- updates never throw "Cursor position outside buffer".
  local body_line_count = vim.api.nvim_buf_line_count(body_buf)
  if body_line_count < 1 then return end
  body_lnum = math.max(1, math.min(body_lnum, body_line_count))

  state.set_snLn(body_buf, tree_lnum)

  -- Scroll the body window to the heading WITHOUT moving focus away from the
  -- tree.  We set the body window cursor directly via the API so there is no
  -- window-switch overhead and no flicker.
  local body_win = find_win_for_buf(body_buf)
  local tree_win = find_win_for_buf(tree_buf)
  if body_win then
    vim.api.nvim_win_set_cursor(body_win, { body_lnum, 0 })
  end
  -- Restore focus to the tree window in case the API call moved it.
  if tree_win and vim.api.nvim_get_current_win() ~= tree_win then
    vim.api.nvim_set_current_win(tree_win)
  end
end

-- ==============================================================================
-- Outline traversal utilities
-- ==============================================================================
--
-- These functions operate on the `levels` array from state (1-indexed, where
-- levels[i] is the depth of tree line i — direct 1:1 mapping).  They return
-- tree line numbers (1-based).  All are exposed on M so tests can call them
-- directly without needing a live Neovim window.

-- Return the tree line number of the parent of `tree_lnum`, or nil if the
-- node is already at the top level (level 1 heading with no ancestor).
--
-- We walk backward from tree_lnum−1, looking for the first node whose level
-- is strictly less than the current node's level — that node is the parent.
function M.find_parent_lnum(levels, tree_lnum)
  if tree_lnum <= 1 then return nil end     -- nothing above the first line

  local cur_level = levels[tree_lnum]       -- levels[i] = depth of tree line i

  for i = tree_lnum - 1, 1, -1 do          -- walk backward through levels[]
    if levels[i] < cur_level then
      return i                              -- tree line = levels index (direct)
    end
  end

  -- No ancestor found with a lower level: node is already at the top depth.
  return nil
end

-- Return the tree line number of the first child of `tree_lnum`, or nil if
-- this node is a leaf.
--
-- A child exists when the very next slot in levels[] has a deeper level.
function M.find_first_child_lnum(levels, tree_lnum)
  -- levels[tree_lnum + 1] is the next slot (tree line tree_lnum+1).
  local next_level = levels[tree_lnum + 1]   -- may be nil at end of array
  if next_level and next_level > levels[tree_lnum] then
    return tree_lnum + 1
  end
  return nil
end

-- Return the tree line number of the previous sibling of `tree_lnum`, or nil.
--
-- We walk backward from tree_lnum−1.  If we encounter a node at the same
-- depth, that is the previous sibling.  If we first hit a node at a shallower
-- depth, we have crossed the parent boundary — no previous sibling exists on
-- this branch.
function M.find_prev_sibling_lnum(levels, tree_lnum)
  if tree_lnum <= 1 then return nil end

  local cur_level = levels[tree_lnum]       -- levels[i] = depth of tree line i

  for i = tree_lnum - 1, 1, -1 do
    local lv = levels[i]
    if lv < cur_level then
      -- Reached the parent without finding a same-level sibling.
      return nil
    elseif lv == cur_level then
      return i                              -- tree line = index (direct)
    end
    -- lv > cur_level: a deeper node in a sibling subtree; keep searching.
  end

  -- Walked off the start of the array — this was the first sibling.
  return nil
end

-- Return the tree line number of the next sibling of `tree_lnum`, or nil.
--
-- Walk forward from tree_lnum+1.  First node at the same depth is the next
-- sibling; first node at shallower depth means we exited the parent, so nil.
function M.find_next_sibling_lnum(levels, tree_lnum)
  local cur_level = levels[tree_lnum]
  if not cur_level then return nil end      -- out of range

  for i = tree_lnum + 1, #levels do        -- levels[i] = tree line i (direct)
    local lv = levels[i]
    if lv < cur_level then
      return nil
    elseif lv == cur_level then
      return i
    end
    -- lv > cur_level: still inside a child subtree; continue forward.
  end

  return nil
end

-- Return the tree line number of the first (topmost) sibling of `tree_lnum`.
-- If already at the first sibling, returns tree_lnum itself.
function M.find_first_sibling_lnum(levels, tree_lnum)
  local result = tree_lnum
  while true do
    local prev = M.find_prev_sibling_lnum(levels, result)
    if prev == nil then break end
    result = prev
  end
  return result
end

-- Return the tree line number of the last (bottommost) sibling of `tree_lnum`.
-- If already at the last sibling, returns tree_lnum itself.
function M.find_last_sibling_lnum(levels, tree_lnum)
  local result = tree_lnum
  while true do
    local nxt = M.find_next_sibling_lnum(levels, result)
    if nxt == nil then break end
    result = nxt
  end
  return result
end

-- Build a UNL (Uniform Node Locator) path string for `tree_lnum`.
--
-- Returns a ">"-separated chain of ancestor heading texts from the outermost
-- to the innermost, e.g. "Introduction > Background > Motivation".
-- Returns "" when tree_lnum is nil or the tree is empty.
--
-- Walk up via find_parent_lnum (returns nil at the top level) collecting
-- heading text until there are no more ancestors.
function M.build_unl(tree_buf, levels, tree_lnum)
  if not tree_lnum or not levels[tree_lnum] then return "" end

  local parts = {}

  local lnum = tree_lnum
  while lnum ~= nil do
    local line = vim.api.nvim_buf_get_lines(tree_buf, lnum - 1, lnum, false)[1] or ""
    table.insert(parts, 1, heading_text_from_tree_line(line))
    lnum = M.find_parent_lnum(levels, lnum)
  end

  return table.concat(parts, " > ")
end

-- ==============================================================================
-- Fold expression
-- ==============================================================================

-- Compute a foldexpr value for the tree buffer.
--
-- This function must be public so Neovim can call it through the `v:lua`
-- foldexpr string set on the tree window.  It mirrors the legacy
-- `voom#TreeFoldexpr` from the original Vimscript plugin.
--
-- Every tree line is a heading.  Line k opens a fold at depth equal to its
-- heading level, naturally nesting children inside their parents.
--
-- Returns "0" when state is unavailable (e.g. during buffer construction
-- before the outline has been registered).
function M.tree_foldexpr(lnum)
  local tree_buf = vim.api.nvim_get_current_buf()
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return "0" end

  local outline = state.get_outline(body_buf)
  if not outline then return "0" end

  -- levels[i] = depth of tree line i (direct 1:1 mapping; no offset).
  local lev = outline.levels[lnum]
  if not lev then return "0" end

  return ">" .. lev
end

-- ==============================================================================
-- Tree navigation actions
-- ==============================================================================
--
-- Each function reads the current tree cursor, computes the target tree line
-- via the traversal utilities, and moves the cursor there.  Body scrolling is
-- handled automatically by the CursorMoved → follow_cursor autocmd.

-- Move to the parent node.  If the current node has an open fold, close it
-- first so the user sees the tree contract before moving up.
function M.tree_navigate_left(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  -- Close a fold at the current position before moving, mirroring Vim's
  -- convention that Left collapses a node before ascending.
  pcall(function() vim.api.nvim_win_call(tree_win, function() vim.cmd("normal! zc") end) end)

  local target = M.find_parent_lnum(outline.levels, tree_lnum)
  if target then
    vim.api.nvim_win_set_cursor(tree_win, { target, 0 })
  end
  M.apply_fold_indicators(tree_buf, body_buf)
end

-- Move to the first child of the current node.
function M.tree_navigate_right(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  -- Match legacy VOoM behavior: when the current node is closed, first reveal
  -- it, then descend to the first child.
  pcall(function()
    vim.api.nvim_win_call(tree_win, function()
      if vim.fn.foldclosed(tree_lnum) == tree_lnum then
        vim.cmd("normal! zv")
      end
    end)
  end)

  local target = M.find_first_child_lnum(outline.levels, tree_lnum)
  if target then
    vim.api.nvim_win_set_cursor(tree_win, { target, 0 })
  end
  M.apply_fold_indicators(tree_buf, body_buf)
end

-- Move to the previous sibling.
function M.tree_navigate_prev_sibling(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local target = M.find_prev_sibling_lnum(outline.levels, tree_lnum)
  if target then
    vim.api.nvim_win_set_cursor(tree_win, { target, 0 })
  end
end

-- Move to the next sibling.
function M.tree_navigate_next_sibling(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local target = M.find_next_sibling_lnum(outline.levels, tree_lnum)
  if target then
    vim.api.nvim_win_set_cursor(tree_win, { target, 0 })
  end
end

-- Move to the first (topmost) sibling.
function M.tree_navigate_first_sibling(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local target = M.find_first_sibling_lnum(outline.levels, tree_lnum)
  vim.api.nvim_win_set_cursor(tree_win, { target, 0 })
end

-- Move to the last (bottommost) sibling.
function M.tree_navigate_last_sibling(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local target = M.find_last_sibling_lnum(outline.levels, tree_lnum)
  vim.api.nvim_win_set_cursor(tree_win, { target, 0 })
end

-- Toggle the fold at the current tree line (za).
function M.tree_toggle_fold(tree_buf)
  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end
  pcall(function()
    vim.api.nvim_win_call(tree_win, function() vim.cmd("normal! za") end)
  end)
  M.apply_fold_indicators(tree_buf, state.get_body(tree_buf))
end

-- Move the tree cursor to snLn (the last body-selected node), restoring
-- the "selected" position after the user has moved the tree cursor away.
function M.tree_goto_selected(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local snLn = state.get_snLn(body_buf)
  if not snLn then return end

  local tree_win = find_win_for_buf(tree_buf)
  if tree_win then
    vim.api.nvim_win_set_cursor(tree_win, { snLn, 0 })
  end
end

-- Echo the heading text of the current tree line to the Neovim message area.
function M.echo_headline(tree_buf)
  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local line = vim.api.nvim_buf_get_lines(tree_buf, tree_lnum - 1, tree_lnum, false)[1] or ""
  local text = heading_text_from_tree_line(line)
  vim.api.nvim_echo({ { text, "Normal" } }, true, {})
end

-- Echo the UNL (ancestor path) for the current tree line and yank it into
-- register n so the user can paste it.
function M.echo_unl(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local unl = M.build_unl(tree_buf, outline.levels, tree_lnum)

  vim.api.nvim_echo({ { unl, "Normal" } }, true, {})
  -- Yank into register n for easy pasting.
  vim.fn.setreg("n", unl)
end

-- ==============================================================================
-- Sibling fold operations
-- ==============================================================================

-- Close all sibling folds of the current tree node.
--
-- Cursor movements are batched inside a single nvim_win_call so that Neovim
-- redraws the screen only once, after all operations complete, rather than
-- after each cursor jump.  pcall guards are no longer needed here because
-- foldmethod=expr guarantees that every parent node has a real fold.
function M.tree_contract_siblings(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local levels    = outline.levels

  -- All fold operations run inside one window call so the cursor's
  -- intermediate positions never reach the screen.  zx is issued first to
  -- recompute fold metadata after any OOP edits that rewrote tree lines.
  vim.api.nvim_win_call(tree_win, function()
    vim.cmd("normal! zx")

    local lnum = M.find_first_sibling_lnum(levels, tree_lnum)
    while lnum do
      -- levels[lnum] = depth of this node; levels[lnum+1] = depth of next.
      local has_children = (levels[lnum + 1] ~= nil) and (levels[lnum + 1] > levels[lnum])
      if has_children then
        vim.api.nvim_win_set_cursor(tree_win, { lnum, 0 })
        vim.cmd("normal! zc")
      end
      lnum = M.find_next_sibling_lnum(levels, lnum)
    end

    -- Restore the cursor to where it was before the loop.
    vim.api.nvim_win_set_cursor(tree_win, { tree_lnum, 0 })
  end)

  M.apply_fold_indicators(tree_buf, body_buf)
end

-- Open all sibling folds of the current tree node.
--
-- Uses the same single-nvim_win_call batching as tree_contract_siblings.
function M.tree_expand_siblings(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  local tree_win = find_win_for_buf(tree_buf)
  if not tree_win then return end

  local tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]
  local levels    = outline.levels

  vim.api.nvim_win_call(tree_win, function()
    vim.cmd("normal! zx")

    local lnum = M.find_first_sibling_lnum(levels, tree_lnum)
    while lnum do
      local has_children = (levels[lnum + 1] ~= nil) and (levels[lnum + 1] > levels[lnum])
      if has_children then
        vim.api.nvim_win_set_cursor(tree_win, { lnum, 0 })
        vim.cmd("normal! zo")
      end
      lnum = M.find_next_sibling_lnum(levels, lnum)
    end

    vim.api.nvim_win_set_cursor(tree_win, { tree_lnum, 0 })
  end)

  M.apply_fold_indicators(tree_buf, body_buf)
end

-- ==============================================================================
-- Body → tree selection sync
-- ==============================================================================

-- From the body buffer cursor position, determine which tree node "owns" that
-- body line (the largest bnode value ≤ cursor_line) and move the tree cursor
-- there without changing body window focus.
--
-- This is the body-side counterpart to follow_cursor: instead of tree→body
-- scrolling, we do body→tree highlighting so the user always sees which
-- section their cursor is in.
function M.body_select(body_buf)
  if not state.is_body(body_buf) then return end
  local outline = state.get_outline(body_buf)
  if not outline then return end

  -- Identify the body window (focus must stay here after this call).
  local body_win = find_win_for_buf(body_buf)
  if not body_win then return end

  local cursor_line = vim.api.nvim_win_get_cursor(body_win)[1]
  local bnodes = outline.bnodes

  -- Linear reverse scan for largest bnode ≤ cursor_line.
  local target_tree_lnum = tree_lnum_for_body_line(bnodes, cursor_line)

  state.set_snLn(body_buf, target_tree_lnum)

  local tree_buf = state.get_tree(body_buf)
  local tree_win = tree_buf and find_win_for_buf(tree_buf)
  if tree_win then
    vim.api.nvim_win_set_cursor(tree_win, { target_tree_lnum, 0 })
  end

  -- Keep focus in the body window regardless.
  vim.api.nvim_set_current_win(body_win)
end

-- Execute an undo-tree command ("undo" / "redo") against the associated body
-- buffer while keeping focus in the tree window.
local function tree_apply_undo_command(tree_buf, cmd)
  local body_buf = state.get_body(tree_buf)
  if not body_buf then return end
  if not state.is_body(body_buf) then return end

  local body_win = find_win_for_buf(body_buf)
  local tree_win = find_win_for_buf(tree_buf)
  if not body_win or not tree_win then return end
  local prev_tree_lnum = vim.api.nvim_win_get_cursor(tree_win)[1]

  local ok = pcall(function()
    vim.api.nvim_win_call(body_win, function()
      vim.cmd(cmd)
    end)
  end)

  if not ok then
    vim.api.nvim_echo(
      { { "VOoM: " .. cmd .. " unavailable", "WarningMsg" } },
      true, {}
    )
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_set_current_win(tree_win)
    end
    return
  end

  M.update(body_buf)

  local target_tree_lnum = prev_tree_lnum
  local max_tree_lnum = vim.api.nvim_buf_line_count(tree_buf)
  if max_tree_lnum < 1 then max_tree_lnum = 1 end
  target_tree_lnum = math.max(1, math.min(target_tree_lnum, max_tree_lnum))

  -- If cursor restoration ever fails, fall back to selecting the node that owns
  -- the current body cursor line.
  if tree_win and vim.api.nvim_win_is_valid(tree_win) then
    local ok = pcall(vim.api.nvim_win_set_cursor, tree_win, { target_tree_lnum, 0 })
    if not ok then
      local outline = state.get_outline(body_buf)
      if outline then
        local body_cursor = vim.api.nvim_win_get_cursor(body_win)[1]
        target_tree_lnum = tree_lnum_for_body_line(outline.bnodes, body_cursor)
        target_tree_lnum = math.max(1, math.min(target_tree_lnum, max_tree_lnum))
        pcall(vim.api.nvim_win_set_cursor, tree_win, { target_tree_lnum, 0 })
      end
    end
  end

  state.set_snLn(body_buf, target_tree_lnum)

  if tree_win and vim.api.nvim_win_is_valid(tree_win) then
    vim.api.nvim_set_current_win(tree_win)
  end
end

-- Undo the latest body change from the tree pane, then refresh tree state.
function M.tree_undo(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if body_buf then
    local history = TREE_HISTORY[body_buf]
    if history and #history.undo_stack > 0 then
      local entry = table.remove(history.undo_stack)
      local cur_lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
      if lines_equal(cur_lines, entry.after_lines) then
        apply_body_snapshot(body_buf, entry.before_lines)
        M.update(body_buf)
        restore_tree_cursor(tree_buf, body_buf, entry.before_lnum)
        table.insert(history.redo_stack, entry)
        return
      end
      -- Body has drifted relative to recorded snapshots; invalidate custom
      -- history and fall back to native body undo behavior.
      clear_history_for_body(body_buf)
    end
  end
  tree_apply_undo_command(tree_buf, "undo")
end

-- Redo the latest body change from the tree pane, then refresh tree state.
function M.tree_redo(tree_buf)
  local body_buf = state.get_body(tree_buf)
  if body_buf then
    local history = TREE_HISTORY[body_buf]
    if history and #history.redo_stack > 0 then
      local entry = table.remove(history.redo_stack)
      local cur_lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
      if lines_equal(cur_lines, entry.before_lines) then
        apply_body_snapshot(body_buf, entry.after_lines)
        M.update(body_buf)
        restore_tree_cursor(tree_buf, body_buf, entry.after_lnum)
        table.insert(history.undo_stack, entry)
        return
      end
      clear_history_for_body(body_buf)
    end
  end
  tree_apply_undo_command(tree_buf, "redo")
end

-- ==============================================================================
-- Body keymap setup
-- ==============================================================================

-- Install a single normal-mode keymap on the body buffer for tree interaction.
--
-- gO  — select the heading that owns the cursor, then jump to it in the tree.
--
-- This replaces the former <CR> + <Tab> pair:
--   * <CR> would call body_select() but stay in the body window
--   * <Tab> would then switch focus to the tree
-- Collapsing them into one chord avoids clobbering <CR> (vital in help/quickfix
-- buffers) and <Tab> (used by snippet engines and completion plugins) on the
-- user's primary editing buffer.
function M.setup_body_keymaps(body_buf, tree_buf)
  vim.api.nvim_buf_set_keymap(body_buf, "n", "gO", "", {
    noremap  = true,
    silent   = true,
    callback = function()
      M.body_select(body_buf)
      -- Switch focus after syncing the tree cursor; body_select() has already
      -- moved the tree cursor to the right position, so no further positioning
      -- is needed.
      local tree_win = find_win_for_buf(tree_buf)
      if tree_win then
        vim.api.nvim_set_current_win(tree_win)
      end
    end,
  })
end

-- ==============================================================================
-- Keymap setup
-- ==============================================================================

function M.set_keymaps(tree_buf, body_buf)
  local opts = { noremap = true, silent = true }

  -- <CR> / gO: navigate to the heading corresponding to the cursor line.
  -- gO mirrors the body-pane binding so the key is reciprocal: gO in the body
  -- jumps to the outline node; gO in the tree jumps back to the heading.
  local function goto_body()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    M.navigate_to_body(tree_buf, lnum)
  end
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<CR>", "", {
    noremap  = true,
    silent   = true,
    callback = goto_body,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "gO", "", {
    noremap  = true,
    silent   = true,
    callback = goto_body,
  })

  -- <Tab>: move focus to the body window without re-running navigation.
  -- follow_cursor (via CursorMoved) already keeps the body cursor in sync,
  -- so all we need is a window focus switch.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<Tab>", "", {
    noremap  = true,
    silent   = true,
    callback = function()
      local body_win = find_win_for_buf(body_buf)
      if body_win then vim.api.nvim_set_current_win(body_win) end
    end,
  })

  -- Structural navigation keys (parent / child / sibling / first / last).
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<Left>", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_left(tree_buf) end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "P", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_left(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<Right>", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_right(tree_buf) end,
  })
  -- 'o' (lowercase) navigates to first child; 'O' (uppercase) is expand-siblings.
  -- This departs from the legacy voom.vim convention where 'o' opened a new
  -- headline; here we keep the read-only tree semantics throughout.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "o", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_right(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "K", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_prev_sibling(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "J", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_next_sibling(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "U", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_first_sibling(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "D", "", {
    noremap = true, silent = true,
    callback = function() M.tree_navigate_last_sibling(tree_buf) end,
  })

  -- Fold operations.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<Space>", "", {
    noremap = true, silent = true,
    callback = function() M.tree_toggle_fold(tree_buf) end,
  })

  -- 'c' contracts siblings; 'C' is intentionally not a separate binding —
  -- using uppercase C for contract keeps muscle memory consistent with
  -- outline editors that treat C/O as contract/open.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "C", "", {
    noremap = true, silent = true,
    callback = function() M.tree_contract_siblings(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "O", "", {
    noremap = true, silent = true,
    callback = function() M.tree_expand_siblings(tree_buf) end,
  })

  -- Go to selected node (=) and echo commands (s, S).
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "=", "", {
    noremap = true, silent = true,
    callback = function() M.tree_goto_selected(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "s", "", {
    noremap = true, silent = true,
    callback = function() M.echo_headline(tree_buf) end,
  })

  vim.api.nvim_buf_set_keymap(tree_buf, "n", "S", "", {
    noremap = true, silent = true,
    callback = function() M.echo_unl(tree_buf) end,
  })

  -- -----------------------------------------------------------------------
  -- Editing operations (delegate to voom.oop)
  -- -----------------------------------------------------------------------

  -- Edit node: jump to body at heading start / region end.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "i", "", {
    noremap = true, silent = true,
    callback = function() require("voom.oop").edit_node(tree_buf, "i") end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "I", "", {
    noremap = true, silent = true,
    callback = function() require("voom.oop").edit_node(tree_buf, "I") end,
  })

  -- Insert new node: aa = sibling, AA = child.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "aa", "", {
    noremap = true, silent = true,
    callback = function() require("voom.oop").insert_node(tree_buf, false) end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "AA", "", {
    noremap = true, silent = true,
    callback = function() require("voom.oop").insert_node(tree_buf, true) end,
  })

  -- Copy / cut / paste.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "yy", "", {
    noremap = true, silent = true,
    callback = function() require("voom.oop").copy_node(tree_buf) end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "dd", "", {
    noremap = true, silent = true,
    callback = function() require("voom.oop").cut_node(tree_buf) end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "pp", "", {
    noremap = true, silent = true,
    callback = function() require("voom.oop").paste_node(tree_buf) end,
  })

  -- Move up / down.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "^^", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").move_up(tree_buf)
      end)
    end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<C-Up>", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").move_up(tree_buf)
      end)
    end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "__", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").move_down(tree_buf)
      end)
    end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<C-Down>", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").move_down(tree_buf)
      end)
    end,
  })

  -- Promote / demote.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<<", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").promote(tree_buf)
      end)
    end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<C-Left>", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").promote(tree_buf)
      end)
    end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", ">>", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").demote(tree_buf)
      end)
    end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<C-Right>", "", {
    noremap = true, silent = true,
    callback = function()
      run_structural_action_with_history(tree_buf, function()
        require("voom.oop").demote(tree_buf)
      end)
    end,
  })

  -- Undo/redo against the body buffer while keeping focus in tree.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "u", "", {
    noremap = true, silent = true,
    callback = function() M.tree_undo(tree_buf) end,
  })
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<C-r>", "", {
    noremap = true, silent = true,
    callback = function() M.tree_redo(tree_buf) end,
  })

  -- Disable text-modification keys so the buffer feels truly read-only
  -- even though 'nomodifiable' already prevents changes.
  -- Note: keys mapped to editing operations above (i, I, aa, AA, dd, pp, yy)
  -- are intentionally excluded. Single-key prefixes (a, d, p, y) are not
  -- disabled because Neovim's keymap resolver waits for the second key, and
  -- the buffer is nomodifiable anyway.
  -- 's', 'S', 'o', 'O', 'c', 'C', 'D', 'U' are mapped to navigation above.
  disable_keys(tree_buf, {
    "r", "R", "x", "X",
    "zf", "zF", "zd", "zD",
  })

  -- Suppress Lua "unused variable" warning: opts is referenced by the local
  -- definitions but all keymaps above use inline option tables.
  _ = opts
end

-- ==============================================================================
-- Autocommands
-- ==============================================================================

-- Rebuild the tree when the body changed since our last recorded tick.
local function refresh_tree_if_body_changed(body_buf)
  local tick = vim.api.nvim_buf_get_changedtick(body_buf)
  if tick ~= state.get_changedtick(body_buf) then M.update(body_buf) end
end

-- Attach per-body autocommands.  Each body gets its own named augroup so
-- that unregistering cleans up cleanly without affecting other bodies.
local function setup_autocommands(body_buf, tree_buf)
  local group_name = "voom_body_" .. body_buf
  local aug = vim.api.nvim_create_augroup(group_name, { clear = true })

  -- Rebuild the tree whenever the body is saved.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group  = aug,
    buffer = body_buf,
    callback = function()
      M.update(body_buf)
    end,
  })

  -- Rebuild the tree when the body is entered after out-of-band changes.
  -- Out-of-band means edits that happened while the body was not the active
  -- window (e.g. edits from another tab, or a :substitute run in the tree
  -- window via the command line).  We detect this by comparing changedtick.
  vim.api.nvim_create_autocmd("BufEnter", {
    group  = aug,
    buffer = body_buf,
    callback = function()
      refresh_tree_if_body_changed(body_buf)
    end,
  })

  -- Live cursor-follow: whenever the cursor moves in the tree buffer, scroll
  -- the body window to the corresponding heading without moving focus.
  -- Using CursorMoved rather than mapping individual keys (j, k, etc.) means
  -- all navigation methods — motions, searches, mouse — trigger the follow.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group  = aug,
    buffer = tree_buf,
    callback = function()
      refresh_tree_if_body_changed(body_buf)
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      M.follow_cursor(tree_buf, lnum)
    end,
  })

  -- Re-render headings with updated truncation whenever the tree window is
  -- resized (mouse drag, keyboard split-resize, or terminal resize).
  -- vim.v.event.windows lists every window whose dimensions changed.
  vim.api.nvim_create_autocmd("WinResized", {
    group  = aug,
    callback = function()
      for _, win in ipairs(vim.v.event.windows) do
        if vim.api.nvim_win_get_buf(win) == tree_buf then
          M.update(body_buf)
          break
        end
      end
    end,
  })

  -- Clean up state when the tree is wiped out (e.g. user runs :bwipe).
  vim.api.nvim_create_autocmd("BufWipeout", {
    group  = aug,
    buffer = tree_buf,
    callback = function()
      state.unregister(body_buf)
      vim.api.nvim_del_augroup_by_name(group_name)
    end,
  })
end

-- ==============================================================================
-- Public API
-- ==============================================================================

-- Create a tree buffer for `body_buf` using `mode_name` to parse headings.
-- Opens a vertical split to the left and returns the new tree buffer number.
--
-- @param body_buf   number   body buffer number
-- @param mode_name  string   markup mode (e.g. "markdown")
-- @return           number   tree buffer number
function M.create(body_buf, mode_name)
  local mode = modes.get(mode_name)
  -- Caller is expected to validate mode_name before calling; error here
  -- surfaces programming mistakes rather than user input errors.
  assert(mode, "unknown mode: " .. tostring(mode_name))

  -- Parse the body buffer contents.
  local buf_name = vim.api.nvim_buf_get_name(body_buf)
  local lines    = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  local outline  = mode.make_outline(lines, buf_name)

  -- Build the display line list (headings only; filename lives in the winbar).
  -- The window does not exist yet at this point, so we use the configured
  -- width; the window will be opened at exactly that width.
  local tree_lines = build_tree_lines(outline, tree_width())

  -- Create the scratch buffer that will hold the tree display.
  local tree_buf = vim.api.nvim_create_buf(false, true)
  local basename = vim.fn.fnamemodify(buf_name, ":t")
  if basename == "" then basename = tostring(body_buf) end
  vim.api.nvim_buf_set_name(tree_buf, basename .. "_VOOM" .. body_buf)

  -- Buffer options for a read-only, non-persistent scratch panel.
  vim.api.nvim_buf_set_option(tree_buf, "buftype",   "nofile")
  vim.api.nvim_buf_set_option(tree_buf, "buflisted", false)
  vim.api.nvim_buf_set_option(tree_buf, "swapfile",  false)
  vim.api.nvim_buf_set_option(tree_buf, "filetype",  "voomtree")

  -- Write tree lines before setting modifiable=false.
  vim.api.nvim_buf_set_option(tree_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(tree_buf, 0, -1, false, tree_lines)
  vim.api.nvim_buf_set_option(tree_buf, "modifiable", false)

  -- Open the body window (in case focus was elsewhere) and then split.
  local body_win = find_win_for_buf(body_buf)
  if body_win then
    vim.api.nvim_set_current_win(body_win)
  end

  -- Open a left-side vertical split for the tree.
  vim.cmd("leftabove vertical " .. tree_width() .. "split")
  local tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tree_win, tree_buf)
  vim.api.nvim_win_set_option(tree_win, "winfixwidth", true)

  -- Strip UI gutters that consume columns without displaying tree content.
  -- This keeps nvim_win_get_width() consistent with the visible text area so
  -- that heading truncation thresholds are accurate.  Users may have number,
  -- relativenumber, signcolumn, or foldcolumn set globally; override them here
  -- so the tree panel looks clean regardless of their preferences.
  vim.wo[tree_win].number         = false
  vim.wo[tree_win].relativenumber = false
  vim.wo[tree_win].signcolumn     = "no"
  vim.wo[tree_win].foldcolumn     = "0"
  -- Prevent visual line-wrapping.  Truncation ensures lines fit within the
  -- panel width; wrapping would re-introduce the overflow we just removed.
  vim.wo[tree_win].wrap           = false

  -- Register state before configuring folds. foldexpr evaluates through
  -- state.get_body()/get_outline(); without registration Neovim sees "0" and
  -- creates no folds on first open.
  state.register(body_buf, tree_buf, mode_name, outline)

  -- Enable expression-based folding so the tree's fold structure mirrors the
  -- heading hierarchy. foldlevel=20 starts fully open; users collapse with
  -- <Space> / C. conceallevel=0 prevents third-party plugins from concealing
  -- the | separator characters.
  vim.wo[tree_win].foldmethod   = "expr"
  vim.wo[tree_win].foldexpr     = "v:lua.require('voom.tree').tree_foldexpr(v:lnum)"
  vim.wo[tree_win].foldlevel    = 20
  vim.wo[tree_win].foldenable   = true
  vim.wo[tree_win].conceallevel = 0

  -- Force one fold recomputation now that foldexpr and state are both ready.
  -- Without this, first-open trees can remain unfurled until a later redraw.
  vim.api.nvim_win_call(tree_win, function()
    vim.cmd("normal! zx")
  end)

  -- Wire up keymaps + autocommands.
  M.set_keymaps(tree_buf, body_buf)
  M.setup_body_keymaps(body_buf, tree_buf)
  setup_autocommands(body_buf, tree_buf)

  -- Apply fold-state icons now that the tree window exists and foldexpr has
  -- been configured.  Must come after setup_autocommands so that the tree win
  -- is fully initialised before foldclosed() is queried inside the function.
  M.apply_fold_indicators(tree_buf, body_buf)
  update_winbar(tree_win, body_buf)

  -- Leave the cursor in the body window so the user can continue editing.
  local new_body_win = find_win_for_buf(body_buf)
  if new_body_win then
    vim.api.nvim_set_current_win(new_body_win)
  end

  return tree_buf
end

-- Rebuild the tree panel for `body_buf` from the current buffer contents.
-- Called automatically on BufWritePost; can also be called manually.
function M.update(body_buf)
  if not state.is_body(body_buf) then return end

  local mode_name = state.get_mode(body_buf)
  local mode      = mode_name and modes.get(mode_name)
  if not mode then return end

  local buf_name = vim.api.nvim_buf_get_name(body_buf)
  local lines    = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  local outline  = mode.make_outline(lines, buf_name)

  -- Resolve the tree window early so we can truncate headings to its actual
  -- current width rather than the configured default (they differ after the
  -- user resizes the panel).
  local tree_buf   = state.get_tree(body_buf)
  if not tree_buf or not vim.api.nvim_buf_is_valid(tree_buf) then return end
  local tree_win   = find_win_for_buf(tree_buf)
  local max_cols   = tree_win and vim.api.nvim_win_get_width(tree_win) or tree_width()
  local tree_lines = build_tree_lines(outline, max_cols)
  write_lines(tree_buf, tree_lines)
  state.set_outline(body_buf, outline)
  state.set_changedtick(body_buf, vim.api.nvim_buf_get_changedtick(body_buf))

  -- Recompute fold structure after line rewrites so fold commands work
  -- immediately after structural edits (promote/demote/move/etc).
  if tree_win then
    pcall(function()
      vim.api.nvim_win_call(tree_win, function()
        vim.cmd("normal! zx")
      end)
    end)
  end

  M.apply_fold_indicators(tree_buf, body_buf)
  if tree_win then
    update_winbar(tree_win, body_buf)
  end
end

-- Delete the tree buffer and clean up all associated state for `body_buf`.
function M.close(body_buf)
  local tree_buf = state.get_tree(body_buf)
  if tree_buf and vim.api.nvim_buf_is_valid(tree_buf) then
    -- Force-delete so the buffer disappears even if displayed in a window.
    vim.api.nvim_buf_delete(tree_buf, { force = true })
  end
  -- Unregister is also called by the BufWipeout autocmd, but calling it
  -- here handles the case where the buffer was already wiped before close().
  state.unregister(body_buf)
  clear_history_for_body(body_buf)

  -- Clean up the per-body augroup in case close() was called directly
  -- (not through BufWipeout).
  local group_name = "voom_body_" .. body_buf
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
end

return M
