-- nvim-voom plugin entry point.
--
-- This module is the public API surface that plugin/voom.lua dispatches to.
-- Heavy lifting is delegated to tree.lua (buffer/window management) and
-- modes/ (markup-specific outline parsing).

local M = {}

local config = require("voom.config")

-- Allow users to customise nvim-voom by calling require("voom").setup({...}).
-- Delegates directly to config.setup, which deep-merges user_opts over
-- config.defaults and stores the result in config.options.
M.setup = config.setup

-- ==============================================================================
-- Log buffer
-- ==============================================================================

-- Module-level handle for the nvim-voom log buffer (nil until first :Voomlog).
-- We keep it at module level so that successive calls to log() and log_init()
-- share the same buffer rather than creating new scratch buffers each time.
local log_buf = nil

-- Ensure the log buffer exists.  Returns its buffer number.
local function ensure_log_buf()
  if log_buf and vim.api.nvim_buf_is_valid(log_buf) then
    return log_buf
  end
  -- Create a named scratch buffer that will not prompt for saving on exit.
  log_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(log_buf, "*nvim-voom log*")
  vim.api.nvim_buf_set_option(log_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(log_buf, "buflisted", false)
  return log_buf
end

-- Append `msg` as a new line to the nvim-voom log buffer, creating it if needed.
function M.log(msg)
  local buf = ensure_log_buf()
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { tostring(msg) })
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- Open (or focus) the nvim-voom log buffer in a horizontal split at the bottom.
function M.log_init()
  local buf = ensure_log_buf()

  -- Check whether the log buffer is already visible; if so, just focus it.
  local existing_win = require("voom.tree_utils").find_win_for_buf(buf)
  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
    return
  end

  -- Open a bottom horizontal split and switch it to the log buffer.
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
end

-- ==============================================================================
-- Internal helpers
-- ==============================================================================

-- Resolve the markup mode name from the command argument or the current
-- buffer's filetype.  Delegates filetype→mode resolution to
-- voom.modes.resolve_filetype so aliases (e.g. "md" → "markdown") live
-- alongside the mode registry.  Falls back to the raw &filetype value when
-- the filetype isn't registered so init() can emit its "unsupported mode"
-- notification with the name the user actually saw.
local function detect_mode(args)
  if args and args ~= "" then
    return args
  end
  local ft = vim.bo.filetype
  return require("voom.modes").resolve_filetype(ft) or ft
end

-- Resolve the body buffer from the current context.
-- If the current buffer is a body, returns it directly.
-- If the current buffer is a tree, returns the associated body.
-- Otherwise returns nil and emits an error.
local function resolve_body_buf()
  local state = require("voom.state")
  local current = vim.api.nvim_get_current_buf()

  if state.is_body(current) then
    return current
  elseif state.is_tree(current) then
    return state.get_body(current)
  else
    vim.notify("nvim-voom: current buffer has no active nvim-voom tree", vim.log.levels.ERROR)
    return nil
  end
end

-- ==============================================================================
-- Public API
-- ==============================================================================

-- Open (or focus) the nvim-voom tree panel for the current buffer.
--
-- @param args  string  optional mode name passed from the user command
function M.init(args)
  local state = require("voom.state")
  local tree = require("voom.tree")
  local modes = require("voom.modes")

  local body_buf = vim.api.nvim_get_current_buf()

  -- If the current buffer is already a tree, do nothing.
  if state.is_tree(body_buf) then
    return
  end

  -- If this body already has a tree, focus it instead of creating another.
  local existing_tree = state.get_tree(body_buf)
  if existing_tree then
    local tree_utils = require("voom.tree_utils")
    local tree_win = tree_utils.find_win_for_buf(existing_tree)
    if tree_win then
      vim.api.nvim_set_current_win(tree_win)
    end
    return
  end

  local mode_name = detect_mode(args)

  -- Validate the mode before attempting to create the tree so the user
  -- gets a clear error rather than a confusing Lua stack trace.
  if not modes.get(mode_name) then
    vim.notify("nvim-voom: unsupported mode '" .. tostring(mode_name) .. "'", vim.log.levels.ERROR)
    return
  end

  tree.create(body_buf, mode_name)
end

-- Toggle the nvim-voom tree panel for the current buffer.
-- Opens the panel if it does not exist; closes it if it does.
--
-- @param args  string  optional mode name (forwarded to init() when opening)
function M.toggle(args)
  local state = require("voom.state")
  local tree = require("voom.tree")

  local body_buf = vim.api.nvim_get_current_buf()

  -- If the current buffer is a tree, treat toggle as "close".
  if state.is_tree(body_buf) then
    local actual_body = state.get_body(body_buf)
    if actual_body then
      tree.close(actual_body)
    end
    return
  end

  if state.is_body(body_buf) then
    tree.close(body_buf)
  else
    M.init(args)
  end
end

-- Close the nvim-voom tree for `body_buf` (defaults to the current buffer's
-- associated body).  No-op if the buffer has no active tree.
--
-- Stable public counterpart to M.init / M.toggle — prefer this over reaching
-- into voom.tree.close from external code (autocommands, user rcfiles, etc.).
--
-- @param body_buf  number?  body buffer number; defaults to the current
--                           buffer's associated body via resolve_body_buf().
function M.close(body_buf)
  local state = require("voom.state")
  local tree = require("voom.tree")

  body_buf = body_buf or resolve_body_buf()
  if not body_buf then
    return
  end

  if state.get_tree(body_buf) then
    tree.close(body_buf)
  end
end

-- Return a list of mode names that begin with `arglead`, for command-line
-- completion of :Voom and :VoomToggle.
function M.complete(arglead)
  local modes = require("voom.modes")
  local names = vim.tbl_keys(modes.modes)
  if arglead == nil or arglead == "" then
    return names
  end
  return vim.tbl_filter(function(n)
    return n:sub(1, #arglead) == arglead
  end, names)
end

function M.help()
  vim.cmd("help voom")
end

-- ==============================================================================
-- VoomGrep
-- ==============================================================================

-- Search body headings for a Lua pattern; populate the quickfix list.
--
-- The search is over heading texts (not raw body lines), so "Overview" would
-- match the heading "Project Overview" in the tree but not a body paragraph
-- that happens to contain that word.
--
-- @param args  string  Lua pattern to match against heading texts
function M.grep(args)
  local state = require("voom.state")
  local tree_mod = require("voom.tree")

  local body_buf = resolve_body_buf()
  if not body_buf then
    return
  end

  local outline = state.get_outline(body_buf)
  if not outline then
    vim.notify("nvim-voom: no outline data for this buffer", vim.log.levels.ERROR)
    return
  end

  local tree_buf = state.get_tree(body_buf)
  if not tree_buf or not vim.api.nvim_buf_is_valid(tree_buf) then
    vim.notify("nvim-voom: tree buffer is not available", vim.log.levels.ERROR)
    return
  end

  local bnodes = outline.bnodes
  local entries = {}

  -- Walk every heading (bnodes[i] → tree line i).  Read the tree line to
  -- extract the display text, which is already stripped of markup syntax;
  -- this is cleaner than parsing the raw body line again.
  for i, bnode in ipairs(bnodes) do
    local tree_lnum = i
    local raw = vim.api.nvim_buf_get_lines(tree_buf, tree_lnum - 1, tree_lnum, false)[1] or ""
    local text = require("voom.tree_utils").heading_text_from_tree_line(raw)

    if text:match(args) then
      table.insert(entries, {
        bufnr = body_buf,
        lnum = bnode,
        text = text,
      })
    end
  end

  vim.fn.setqflist(entries, "r")

  if #entries == 0 then
    vim.notify("nvim-voom grep: no headings matched '" .. args .. "'", vim.log.levels.WARN)
  else
    vim.cmd("copen")
  end
end

-- ==============================================================================
-- Voominfo
-- ==============================================================================

-- Display diagnostic information about the nvim-voom state for the current buffer.
-- Useful for debugging and verifying that the outline is in sync with the body.
function M.voominfo()
  local state = require("voom.state")

  local body_buf = resolve_body_buf()
  if not body_buf then
    return
  end

  local tree_buf = state.get_tree(body_buf)
  local snLn = state.get_snLn(body_buf)
  local outline = state.get_outline(body_buf)
  local mode_name = state.get_mode(body_buf)
  if not tree_buf or not snLn or not outline or not mode_name then
    vim.notify("nvim-voom: no state entry found", vim.log.levels.ERROR)
    return
  end

  local node_count = #outline.bnodes

  -- Read the heading text for the currently selected node.  Tree line 1 is
  -- the first real heading (there is no synthetic root node), so we read from
  -- snLn unconditionally.
  local headline = "(unknown)"
  if vim.api.nvim_buf_is_valid(tree_buf) then
    local raw = vim.api.nvim_buf_get_lines(tree_buf, snLn - 1, snLn, false)[1] or ""
    local extracted = require("voom.tree_utils").heading_text_from_tree_line(raw)
    headline = extracted ~= "" and extracted or "(unknown)"
  end

  local msg = string.format(
    "nvim-voom info\n  mode:   %s\n  nodes:  %d\n  snLn:   %d\n  node:   %s",
    tostring(mode_name),
    node_count,
    snLn,
    headline
  )
  vim.notify(msg, vim.log.levels.INFO)
end

return M
