local M = {}

-- Default configuration. Users override via require("voom").setup({...}).
M.defaults = {
  -- Width of the tree pane in columns.
  tree_width = 40,
  -- Default markup mode when none is specified.
  default_mode = "markdown",
  -- Which side of the editor the tree pane opens on: "left" or "right".
  tree_position = "left",
  -- Automatically open the tree pane for matching filetypes on BufEnter.
  -- false  → never auto-open
  -- true   → auto-open for all supported modes
  -- table  → auto-open only for the listed mode names, e.g. {"markdown"}
  -- TODO: wire auto_open in setup() once the autocommand plumbing is in place.
  auto_open = false,
  -- Whether moving the cursor in the tree automatically scrolls the body
  -- window to the corresponding heading without moving focus.
  cursor_follow = true,
  -- Virtual-text fold-state indicators shown next to each tree node.
  -- Set enabled=false to turn them off entirely.
  -- Icons are rendered via nvim_buf_set_extmark (Neovim-only).
  fold_indicators = {
    enabled = true,
    icons   = { open = "▾", closed = "▶", leaf = "·" },
  },
  -- Vertical guide lines rendered at each ancestor column of nested headings.
  -- Set enabled=false to turn them off entirely.
  -- The guide character is overlaid via nvim_buf_set_extmark; any single
  -- display-column character can be used.
  indent_guides = {
    enabled = true,
    char    = "│",   -- U+2502 box-drawing vertical bar
  },
  -- End-of-line "+N" descendant-count badges shown on collapsed nodes.
  badges = {
    enabled = true,
  },
  -- Override or disable individual tree-pane keymaps.
  -- Set a key to false to disable it; set to a string to remap the action
  -- to that key.  Setting the entire table to false disables all plugin
  -- keymaps, allowing the user to define their own via autocommands.
  -- TODO: implement keymap override/disable logic in set_keymaps().
  keymaps = {},
  -- Callback invoked after the tree pane is created.
  -- Signature: function(body_buf, tree_buf)
  -- Useful for applying buffer-local options or additional keymaps.
  on_open = nil,
  -- Options for the :VoomSort command.
  sort = {
    -- Default sort flags passed to :VoomSort when the user provides no
    -- arguments (e.g. "i" to always sort case-insensitively).
    default_opts = "",
  },
}

-- Merged config, populated by setup().
M.options = {}

function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

return M
