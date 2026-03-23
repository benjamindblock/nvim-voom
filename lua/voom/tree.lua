-- Tree buffer/window lifecycle and navigation for VOoM.
--
-- This module owns:
--   - creating and destroying the read-only outline panel
--   - populating the panel from a mode's make_outline() result
--   - keymaps that let the user navigate from the tree to the body
--   - auto-refresh when the body is saved
--
-- The tree buffer is a scratch/nofile buffer.  Its lines have the format:
--   Line 1 : root node  →  "  |{filename}"
--   Line k  : heading    →  "  [. ]*|{heading_text}"   (from mode.tlines)
--
-- Index mapping (root node at line 1 occupies the slot Python's caller
-- injected separately; headings start at tree line 2):
--   tree line 1       → body line 1
--   tree line k (k≥2) → bnodes[k - 1]

local M = {}

local config = require("voom.config")
local modes  = require("voom.modes")
local state  = require("voom.state")

-- ==============================================================================
-- Internal helpers
-- ==============================================================================

-- Return the effective tree width, falling back to the default when setup()
-- has not been called by the user.
local function tree_width()
  return (config.options and config.options.tree_width)
    or config.defaults.tree_width
end

-- Find a window displaying `buf` in the current tab, or nil.
local function find_win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

-- Write `lines` into `buf`, temporarily enabling modifiability.
local function write_lines(buf, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Build the full list of tree display lines from outline data.
-- Prepends the root node at position 1.
local function build_tree_lines(buf_name, outline)
  local tail = vim.fn.fnamemodify(buf_name, ":t")
  if tail == "" then
    -- Unnamed or scratch buffer: fall back to the raw name.
    tail = buf_name ~= "" and buf_name or "[No Name]"
  end
  local lines = { "  |" .. tail }
  for _, tl in ipairs(outline.tlines) do
    table.insert(lines, tl)
  end
  return lines
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

  -- Determine target body line number.  Line 1 is the root node and maps
  -- to the first line of the body; lines ≥ 2 index into bnodes.
  local body_lnum
  if tree_lnum == 1 then
    body_lnum = 1
  else
    local outline = state.get_outline(body_buf)
    if not outline then return end
    body_lnum = outline.bnodes[tree_lnum - 1]
    if not body_lnum then return end
  end

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

  -- Same bnode lookup as navigate_to_body.
  local body_lnum
  if tree_lnum == 1 then
    body_lnum = 1
  else
    local outline = state.get_outline(body_buf)
    if not outline then return end
    body_lnum = outline.bnodes[tree_lnum - 1]
    if not body_lnum then return end
  end

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
-- Keymap setup
-- ==============================================================================

function M.set_keymaps(tree_buf, body_buf)
  local opts = { noremap = true, silent = true }

  -- <CR>: navigate to the heading corresponding to the cursor line.
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<CR>", "", {
    noremap  = true,
    silent   = true,
    callback = function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      M.navigate_to_body(tree_buf, lnum)
    end,
  })

  -- <Tab>: move focus to body, placing its cursor at the currently-selected
  -- heading.  Unlike <CR>, this does not re-trigger a navigation call of its
  -- own — follow_cursor has already kept the body cursor in sync, so all we
  -- need to do is switch window focus via navigate_to_body (which reads the
  -- current tree cursor line and does the bnode lookup).
  vim.api.nvim_buf_set_keymap(tree_buf, "n", "<Tab>", "", {
    noremap  = true,
    silent   = true,
    callback = function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      M.navigate_to_body(tree_buf, lnum)
    end,
  })

  -- Disable text-modification keys so the buffer feels truly read-only
  -- even though 'nomodifiable' already prevents changes.
  disable_keys(tree_buf, {
    "i", "I", "a", "A", "o", "O",
    "r", "R", "x", "X", "s", "S",
    "d", "D", "c", "C", "p", "P",
    "u", "<C-r>",
    "zf", "zF", "zd", "zD",
  })
end

-- ==============================================================================
-- Autocommands
-- ==============================================================================

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

  -- Live cursor-follow: whenever the cursor moves in the tree buffer, scroll
  -- the body window to the corresponding heading without moving focus.
  -- Using CursorMoved rather than mapping individual keys (j, k, etc.) means
  -- all navigation methods — motions, searches, mouse — trigger the follow.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group  = aug,
    buffer = tree_buf,
    callback = function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      M.follow_cursor(tree_buf, lnum)
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

  -- Build the display line list (root node at index 1).
  local tree_lines = build_tree_lines(buf_name, outline)

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

  -- Register state and wire up keymaps + autocommands.
  state.register(body_buf, tree_buf, mode_name, outline)
  M.set_keymaps(tree_buf, body_buf)
  setup_autocommands(body_buf, tree_buf)

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

  local entry = state.bodies[body_buf]
  local mode  = modes.get(entry.mode)
  if not mode then return end

  local buf_name = vim.api.nvim_buf_get_name(body_buf)
  local lines    = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  local outline  = mode.make_outline(lines, buf_name)

  local tree_lines = build_tree_lines(buf_name, outline)
  write_lines(entry.tree, tree_lines)
  state.set_outline(body_buf, outline)
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

  -- Clean up the per-body augroup in case close() was called directly
  -- (not through BufWipeout).
  local group_name = "voom_body_" .. body_buf
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
end

return M
