local M = {}

-- Default configuration. Users override via require("voom").setup({...}).
M.defaults = {
  -- Width of the tree pane in columns.
  tree_width = 30,
  -- Default markup mode when none is specified.
  default_mode = "markdown",
}

-- Merged config, populated by setup().
M.options = {}

function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

return M
