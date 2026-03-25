local T = MiniTest.new_set()

-- ==============================================================================
-- Module loading
-- ==============================================================================

T["loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom")
  end)
end

-- ==============================================================================
-- Default configuration
-- ==============================================================================

T["config"] = MiniTest.new_set()

T["config"]["has default tree_width"] = function()
  local config = require("voom.config")
  MiniTest.expect.equality(config.defaults.tree_width, 40)
end

T["config"]["has default mode"] = function()
  local config = require("voom.config")
  MiniTest.expect.equality(config.defaults.default_mode, "markdown")
end

-- ==============================================================================
-- complete()
-- ==============================================================================

T["complete"] = MiniTest.new_set()

T["complete"]["empty arglead returns all modes"] = function()
  local voom = require("voom")
  local result = voom.complete("")
  MiniTest.expect.equality(type(result), "table")
  -- "markdown" must be present.
  local has_markdown = false
  for _, v in ipairs(result) do
    if v == "markdown" then has_markdown = true end
  end
  MiniTest.expect.equality(has_markdown, true)
end

T["complete"]["matching prefix returns matching modes"] = function()
  local voom = require("voom")
  local result = voom.complete("mar")
  MiniTest.expect.equality(#result, 1)
  MiniTest.expect.equality(result[1], "markdown")
end

T["complete"]["non-matching prefix returns empty list"] = function()
  local voom = require("voom")
  local result = voom.complete("xyz")
  MiniTest.expect.equality(#result, 0)
end

-- ==============================================================================
-- init() and toggle()
-- ==============================================================================

T["init"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["init"]._body_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body  = T["init"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      if body and vim.api.nvim_buf_is_valid(body) then
        vim.api.nvim_buf_delete(body, { force = true })
      end
    end,
  },
})

T["init"]["creates a tree window for a markdown buffer"] = function()
  local voom  = require("voom")
  local state = require("voom.state")

  local body = vim.api.nvim_create_buf(false, true)
  T["init"]._body_buf = body
  vim.api.nvim_buf_set_name(body, "init_test.md")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "# Hello", "## World" })

  -- Open the body buffer in the current window, then call init().
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  voom.init("markdown")

  MiniTest.expect.equality(state.is_body(body), true)
  local tree_buf = state.get_tree(body)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), true)
end

T["toggle"] = MiniTest.new_set()

T["toggle"]["closes tree when body already has one"] = function()
  local voom     = require("voom")
  local state    = require("voom.state")
  local tree_mod = require("voom.tree")

  local body = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(body, "toggle_test.md")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "# Heading" })

  -- Open body and create a tree.
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  local tree_buf = tree_mod.create(body, "markdown")
  MiniTest.expect.equality(state.is_body(body), true)

  -- Toggle should close the tree.
  vim.api.nvim_set_current_buf(body)
  voom.toggle("markdown")

  MiniTest.expect.equality(state.is_body(body), false)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)

  if vim.api.nvim_buf_is_valid(body) then
    vim.api.nvim_buf_delete(body, { force = true })
  end
end

T["toggle"]["opens tree when body has none"] = function()
  local voom  = require("voom")
  local state = require("voom.state")

  local body = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(body, "toggle_open_test.md")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "# Open Me" })

  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  voom.toggle("markdown")

  MiniTest.expect.equality(state.is_body(body), true)

  -- Clean up.
  require("voom.tree").close(body)
  if vim.api.nvim_buf_is_valid(body) then
    vim.api.nvim_buf_delete(body, { force = true })
  end
end

return T
