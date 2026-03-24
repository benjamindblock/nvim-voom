local T = MiniTest.new_set()

-- ==============================================================================
-- Helpers
-- ==============================================================================

-- Create a scratch buffer optionally loaded with lines.
local function make_scratch_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return buf
end

local function del_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- Open a floating window displaying `buf` so find_win_for_buf() can locate it.
-- Returns the window handle.
local function open_float_win(buf)
  return vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0, col = 0, width = 40, height = 10,
  })
end

-- ==============================================================================
-- apply_fold_indicators
-- ==============================================================================
--
-- These tests call M.apply_fold_indicators directly against synthetic buffers
-- and inspect the resulting extmarks.  We mock fold state by controlling
-- foldclosed() results indirectly: because the tree buffers used here are
-- floating windows with foldmethod=manual (no folds created), foldclosed()
-- always returns -1, so every parent node appears "open" (▾).  The "folded"
-- icon path is verified via a separate stub approach below.

T["apply_fold_indicators"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local state = require("voom.state")
      -- Outline: 4 headings at levels [1, 2, 2, 1].
      --   tree line 2 → levels[1]=1 (has child at levels[2]=2) → parent
      --   tree line 3 → levels[2]=2 (next is levels[3]=2, same level)  → leaf
      --   tree line 4 → levels[3]=2 (next is levels[4]=1, shallower)   → leaf
      --   tree line 5 → levels[4]=1 (no next entry)                    → leaf
      local outline = {
        bnodes = { 1, 5, 10, 20 },
        levels = { 1, 2, 2, 1 },
        tlines = {
          "  |Heading One",
          "  . |Child A",
          "  . |Child B",
          "  |Heading Two",
        },
      }
      local body_buf = make_scratch_buf()
      -- Tree buf holds the actual display lines (root line + 4 heading lines).
      local tree_lines = {
        "  \xe2\x80\xa2README.md", -- root: "  •README.md"
        "  |Heading One",
        "  . |Child A",
        "  . |Child B",
        "  |Heading Two",
      }
      local tree_buf = make_scratch_buf(tree_lines)

      state.register(body_buf, tree_buf, "markdown", outline)
      T["apply_fold_indicators"]._body = body_buf
      T["apply_fold_indicators"]._tree = tree_buf

      -- A window must exist for find_win_for_buf; use a floating win.
      local tree_win = open_float_win(tree_buf)
      T["apply_fold_indicators"]._tree_win = tree_win
    end,
    post_case = function()
      local state = require("voom.state")
      if vim.api.nvim_win_is_valid(T["apply_fold_indicators"]._tree_win) then
        vim.api.nvim_win_close(T["apply_fold_indicators"]._tree_win, true)
      end
      state.unregister(T["apply_fold_indicators"]._body)
      del_buf(T["apply_fold_indicators"]._body)
      del_buf(T["apply_fold_indicators"]._tree)
    end,
  },
})

T["apply_fold_indicators"]["places extmarks on all heading lines"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  -- Lines 2–5 (0-indexed rows 1–4) should each have an extmark.
  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  MiniTest.expect.equality(#marks, 4)
end

T["apply_fold_indicators"]["line 1 (root) has no extmark"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  -- Row 0 = tree line 1 (root).  No marks should be on that row.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 0, 0 }, { 0, -1 }, {})
  MiniTest.expect.equality(#marks, 0)
end

T["apply_fold_indicators"]["parent node gets open icon (▾) when unfolded"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  -- tree line 2 (row 1) is "Heading One" — levels[1]=1 with child levels[2]=2.
  -- foldclosed returns -1 (no manual fold), so it should show ▾.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 1, 0 }, { 1, -1 }, {
    details = true,
  })
  MiniTest.expect.equality(#marks, 1)
  local vt = marks[1][4].virt_text
  MiniTest.expect.equality(vt[1][1], "▾")
  MiniTest.expect.equality(vt[1][2], "VoomFoldOpen")
end

T["apply_fold_indicators"]["leaf node gets leaf icon (·)"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  -- tree line 3 (row 2): "Child A" — levels[2]=2, levels[3]=2 (same), so leaf.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 2, 0 }, { 2, -1 }, {
    details = true,
  })
  MiniTest.expect.equality(#marks, 1)
  local vt = marks[1][4].virt_text
  MiniTest.expect.equality(vt[1][1], "·")
  MiniTest.expect.equality(vt[1][2], "VoomLeafNode")
end

T["apply_fold_indicators"]["last node is always a leaf (·)"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  -- tree line 5 (row 4): "Heading Two" — levels[4]=1, levels[5]=nil → leaf.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 4, 0 }, { 4, -1 }, {
    details = true,
  })
  MiniTest.expect.equality(#marks, 1)
  local vt = marks[1][4].virt_text
  MiniTest.expect.equality(vt[1][1], "·")
end

T["apply_fold_indicators"]["icon column matches heading level indentation"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  -- Level-1 heading: col = 2 + (1-1)*2 = 2
  local marks_lev1 = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 1, 0 }, { 1, -1 }, {})
  MiniTest.expect.equality(marks_lev1[1][3], 2)

  -- Level-2 heading: col = 2 + (2-1)*2 = 4
  local marks_lev2 = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 2, 0 }, { 2, -1 }, {})
  MiniTest.expect.equality(marks_lev2[1][3], 4)
end

T["apply_fold_indicators"]["clears extmarks when enabled=false"] = function()
  local tree   = require("voom.tree")
  local config = require("voom.config")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  -- First apply with default (enabled) config to populate marks.
  tree.apply_fold_indicators(tree_buf, body_buf)

  -- Temporarily disable via config.options.
  local saved = config.options
  config.options = { fold_indicators = { enabled = false, icons = {} } }

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  MiniTest.expect.equality(#marks, 0)

  -- Restore.
  config.options = saved
end

T["apply_fold_indicators"]["returns early when tree_buf is invalid"] = function()
  local tree = require("voom.tree")
  -- Should not raise even with a bogus buffer number.
  MiniTest.expect.no_error(function()
    tree.apply_fold_indicators(99999, 99998)
  end)
end

return T
