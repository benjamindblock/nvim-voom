-- VOoM plugin entry point.
--
-- This module is the public API surface that plugin/voom.lua dispatches to.
-- Heavy lifting is delegated to tree.lua (buffer/window management) and
-- modes/ (markup-specific outline parsing).

local M = {}

-- ==============================================================================
-- Internal helpers
-- ==============================================================================

-- Resolve the markup mode name from the command argument or the current
-- buffer's filetype.  The "md" filetype alias is normalised to "markdown"
-- so that both :Voom and :Voom markdown work on .md files.
local function detect_mode(args)
  if args and args ~= "" then
    return args
  end
  local ft = vim.bo.filetype
  if ft == "md" then return "markdown" end
  return ft
end

-- ==============================================================================
-- Public API
-- ==============================================================================

-- Open (or focus) the VOoM tree panel for the current buffer.
--
-- @param args  string  optional mode name passed from the user command
function M.init(args)
  local state = require("voom.state")
  local tree  = require("voom.tree")
  local modes = require("voom.modes")

  local body_buf = vim.api.nvim_get_current_buf()

  -- If the current buffer is already a tree, do nothing.
  if state.is_tree(body_buf) then return end

  -- If this body already has a tree, focus it instead of creating another.
  local existing_tree = state.get_tree(body_buf)
  if existing_tree then
    local tree_win = require("voom.tree").find_win_for_buf and nil
    -- find_win_for_buf is module-private; use a tabpage scan instead.
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == existing_tree then
        vim.api.nvim_set_current_win(win)
        return
      end
    end
    return
  end

  local mode_name = detect_mode(args)

  -- Validate the mode before attempting to create the tree so the user
  -- gets a clear error rather than a confusing Lua stack trace.
  if not modes.get(mode_name) then
    vim.notify(
      "VOoM: unsupported mode '" .. tostring(mode_name) .. "'",
      vim.log.levels.ERROR
    )
    return
  end

  tree.create(body_buf, mode_name)
end

-- Toggle the VOoM tree panel for the current buffer.
-- Opens the panel if it does not exist; closes it if it does.
--
-- @param args  string  optional mode name (forwarded to init() when opening)
function M.toggle(args)
  local state = require("voom.state")
  local tree  = require("voom.tree")

  local body_buf = vim.api.nvim_get_current_buf()

  -- If the current buffer is a tree, treat toggle as "close".
  if state.is_tree(body_buf) then
    local actual_body = state.get_body(body_buf)
    if actual_body then tree.close(actual_body) end
    return
  end

  if state.is_body(body_buf) then
    tree.close(body_buf)
  else
    M.init(args)
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

-- TODO: implement log buffer
function M.log_init() end

return M
