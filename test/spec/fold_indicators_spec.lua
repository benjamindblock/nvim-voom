local H = dofile("test/helpers.lua")

local T = MiniTest.new_set()

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
      --   tree line 1 → levels[1]=1 (has child at levels[2]=2) → parent
      --   tree line 2 → levels[2]=2 (next is levels[3]=2, same level)  → leaf
      --   tree line 3 → levels[3]=2 (next is levels[4]=1, shallower)   → leaf
      --   tree line 4 → levels[4]=1 (no next entry)                    → leaf
      local outline = {
        bnodes = { 1, 5, 10, 20 },
        levels = { 1, 2, 2, 1 },
        tlines = {
          " · Heading One",
          "   · Child A",
          "   · Child B",
          " · Heading Two",
        },
      }
      local body_buf = H.make_scratch_buf()
      -- Tree buf holds the actual display lines (4 heading lines; no root node).
      -- Format: " " + string.rep("  ", lev-1) + "· " + text
      local tree_lines = {
        " · Heading One",
        "   · Child A",
        "   · Child B",
        " · Heading Two",
      }
      local tree_buf = H.make_scratch_buf(tree_lines)

      state.register(body_buf, tree_buf, "markdown", outline)
      T["apply_fold_indicators"]._body = body_buf
      T["apply_fold_indicators"]._tree = tree_buf

      -- A window must exist for find_win_for_buf; use a floating win.
      local tree_win = H.open_float_win(tree_buf)
      T["apply_fold_indicators"]._tree_win = tree_win
    end,
    post_case = function()
      local state = require("voom.state")
      if vim.api.nvim_win_is_valid(T["apply_fold_indicators"]._tree_win) then
        vim.api.nvim_win_close(T["apply_fold_indicators"]._tree_win, true)
      end
      state.unregister(T["apply_fold_indicators"]._body)
      H.del_buf(T["apply_fold_indicators"]._body)
      H.del_buf(T["apply_fold_indicators"]._tree)
    end,
  },
})

T["apply_fold_indicators"]["places extmarks on all heading lines"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  -- Lines 1–4 (0-indexed rows 0–3) should each have an extmark.
  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  MiniTest.expect.equality(#marks, 4)
end

T["apply_fold_indicators"]["parent node gets open icon (▾) when unfolded"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["apply_fold_indicators"]._tree
  local body_buf = T["apply_fold_indicators"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  -- tree line 1 (row 0) is "Heading One" — levels[1]=1 with child levels[2]=2.
  -- foldclosed returns -1 (no manual fold), so it should show ▾.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 0, 0 }, { 0, -1 }, {
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
  -- tree line 2 (row 1): "Child A" — levels[2]=2, levels[3]=2 (same), so leaf.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 1, 0 }, { 1, -1 }, {
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
  -- tree line 4 (row 3): "Heading Two" — levels[4]=1, levels[5]=nil → leaf.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 3, 0 }, { 3, -1 }, {
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
  -- Level-1 heading: col = 1 + (1-1)*2 = 1
  local marks_lev1 = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 0, 0 }, { 0, -1 }, {})
  MiniTest.expect.equality(marks_lev1[1][3], 1)

  -- Level-2 heading: col = 1 + (2-1)*2 = 3
  local marks_lev2 = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 1, 0 }, { 1, -1 }, {})
  MiniTest.expect.equality(marks_lev2[1][3], 3)
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

-- ==============================================================================
-- Integration: extmarks applied after M.update()
-- ==============================================================================
--
-- Verify that updating the tree (simulating a body save) re-applies fold
-- indicators so any new or removed headings are covered.

T["update applies fold indicators"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- We need a real displayed buffer for foldclosed() to work, so open
      -- the body buffer in the current window and let tree.create() split.
      local lines = {
        "# Alpha",
        "content",
        "## Beta",
        "more content",
        "# Gamma",
      }
      local body_buf = H.make_scratch_buf(lines)
      vim.api.nvim_buf_set_name(body_buf, "update_test.md")
      vim.api.nvim_set_current_buf(body_buf)

      local tree = require("voom.tree")
      local tree_buf = tree.create(body_buf, "markdown")
      T["update applies fold indicators"]._body = body_buf
      T["update applies fold indicators"]._tree = tree_buf
    end,
    post_case = function()
      local tree = require("voom.tree")
      tree.close(T["update applies fold indicators"]._body)
      H.del_buf(T["update applies fold indicators"]._body)
    end,
  },
})

T["update applies fold indicators"]["extmarks present after create"] = function()
  local tree_buf = T["update applies fold indicators"]._tree
  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  -- 3 headings → 3 extmarks.
  MiniTest.expect.equality(#marks, 3)
end

T["update applies fold indicators"]["extmarks refreshed after M.update"] = function()
  local tree  = require("voom.tree")
  local body_buf = T["update applies fold indicators"]._body
  local tree_buf = T["update applies fold indicators"]._tree

  -- Add a new heading to the body.
  local lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  table.insert(lines, "# Delta")
  vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, lines)

  tree.update(body_buf)

  local ns = vim.api.nvim_create_namespace("voom_fold_indicators")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  -- Now 4 headings → 4 extmarks.
  MiniTest.expect.equality(#marks, 4)
end

-- ==============================================================================
-- render_indent_guides (via apply_fold_indicators)
-- ==============================================================================
--
-- Guide extmarks are rendered inside apply_fold_indicators.  These tests use
-- the same synthetic outline as the fold-indicator tests above (levels 1,2,2,1)
-- and query GUIDE_NS for the resulting overlay marks.

T["render_indent_guides"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local state = require("voom.state")
      local outline = {
        bnodes = { 1, 5, 10, 20 },
        levels = { 1, 2, 2, 1 },
        tlines = {
          " · Heading One",
          "   · Child A",
          "   · Child B",
          " · Heading Two",
        },
      }
      local body_buf = H.make_scratch_buf()
      local tree_lines = {
        " · Heading One",
        "   · Child A",
        "   · Child B",
        " · Heading Two",
      }
      local tree_buf = H.make_scratch_buf(tree_lines)
      state.register(body_buf, tree_buf, "markdown", outline)
      T["render_indent_guides"]._body    = body_buf
      T["render_indent_guides"]._tree    = tree_buf
      local tree_win = H.open_float_win(tree_buf)
      T["render_indent_guides"]._tree_win = tree_win
    end,
    post_case = function()
      local state = require("voom.state")
      if vim.api.nvim_win_is_valid(T["render_indent_guides"]._tree_win) then
        vim.api.nvim_win_close(T["render_indent_guides"]._tree_win, true)
      end
      state.unregister(T["render_indent_guides"]._body)
      H.del_buf(T["render_indent_guides"]._body)
      H.del_buf(T["render_indent_guides"]._tree)
    end,
  },
})

T["render_indent_guides"]["no guide marks on level-1 headings"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["render_indent_guides"]._tree
  local body_buf = T["render_indent_guides"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_indent_guides")
  -- Row 0 is "Heading One" (level 1) — no ancestor columns → no guides.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 0, 0 }, { 0, -1 }, {})
  MiniTest.expect.equality(#marks, 0)
  -- Row 3 is "Heading Two" (level 1) — same expectation.
  marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 3, 0 }, { 3, -1 }, {})
  MiniTest.expect.equality(#marks, 0)
end

T["render_indent_guides"]["level-2 headings get one guide at correct column"] = function()
  local tree = require("voom.tree")
  local tree_buf = T["render_indent_guides"]._tree
  local body_buf = T["render_indent_guides"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_indent_guides")
  -- Row 1 is "Child A" (level 2): one guide for ancestor level 1 at col 1.
  -- col = 1 + (1-1)*2 = 1
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 1, 0 }, { 1, -1 }, {
    details = true,
  })
  MiniTest.expect.equality(#marks, 1)
  MiniTest.expect.equality(marks[1][3], 1)   -- byte column
  local vt = marks[1][4].virt_text
  MiniTest.expect.equality(vt[1][2], "VoomIndentGuide")
end

T["render_indent_guides"]["clears guide marks when enabled=false"] = function()
  local tree   = require("voom.tree")
  local config = require("voom.config")
  local tree_buf = T["render_indent_guides"]._tree
  local body_buf = T["render_indent_guides"]._body

  -- First apply with guides enabled to populate marks.
  tree.apply_fold_indicators(tree_buf, body_buf)

  -- Disable via config.options.
  local saved = config.options
  config.options = {
    fold_indicators = config.defaults.fold_indicators,
    indent_guides   = { enabled = false, char = "│" },
  }
  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_indent_guides")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  MiniTest.expect.equality(#marks, 0)

  config.options = saved
end

-- ==============================================================================
-- render_count_badges (via apply_fold_indicators)
-- ==============================================================================
--
-- Badges are EOL virtual-text extmarks placed in BADGE_NS on collapsed parent
-- nodes.  Because floating-window trees have no folds (foldclosed always
-- returns -1), the unit tests in the first set verify the "no badge when open"
-- paths.  The integration set uses tree.create() + real fold manipulation to
-- verify the "badge when closed" paths.

T["render_count_badges - unit"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      local state   = require("voom.state")
      -- Outline: levels [1, 2, 3, 2, 1]
      --   idx 1 lev 1 — parent with 3 descendants
      --   idx 2 lev 2 — parent with 1 descendant
      --   idx 3 lev 3 — leaf
      --   idx 4 lev 2 — leaf
      --   idx 5 lev 1 — leaf
      local outline = {
        bnodes = { 1, 5, 8, 12, 20 },
        levels = { 1, 2, 3, 2, 1 },
        tlines = {
          " · H1",
          "   · H2a",
          "     · H3",
          "   · H2b",
          " · H1b",
        },
      }
      local body_buf = H.make_scratch_buf()
      local tree_lines = {
        " · H1",
        "   · H2a",
        "     · H3",
        "   · H2b",
        " · H1b",
      }
      local tree_buf = H.make_scratch_buf(tree_lines)
      state.register(body_buf, tree_buf, "markdown", outline)
      T["render_count_badges - unit"]._body     = body_buf
      T["render_count_badges - unit"]._tree     = tree_buf
      local tree_win = H.open_float_win(tree_buf)
      T["render_count_badges - unit"]._tree_win = tree_win
    end,
    post_case = function()
      local state = require("voom.state")
      if vim.api.nvim_win_is_valid(T["render_count_badges - unit"]._tree_win) then
        vim.api.nvim_win_close(T["render_count_badges - unit"]._tree_win, true)
      end
      state.unregister(T["render_count_badges - unit"]._body)
      H.del_buf(T["render_count_badges - unit"]._body)
      H.del_buf(T["render_count_badges - unit"]._tree)
    end,
  },
})

T["render_count_badges - unit"]["no badges when all folds are open"] = function()
  -- Float windows have no folds (foldclosed returns -1 everywhere), so no
  -- parent is collapsed and BADGE_NS should remain empty.
  local tree = require("voom.tree")
  local tree_buf = T["render_count_badges - unit"]._tree
  local body_buf = T["render_count_badges - unit"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_badges")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  MiniTest.expect.equality(#marks, 0)
end

T["render_count_badges - unit"]["leaf nodes never receive a badge"] = function()
  -- Leaf nodes (no deeper successors) should never get a badge regardless of
  -- fold state.  With foldclosed=-1 this is also implied by the open test, but
  -- we check the leaf rows explicitly to cover the n_descendants==0 branch.
  local tree = require("voom.tree")
  local tree_buf = T["render_count_badges - unit"]._tree
  local body_buf = T["render_count_badges - unit"]._body

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_badges")
  -- Row 2 (idx 3, lev 3) and row 3 (idx 4, lev 2) and row 4 (idx 5, lev 1)
  -- are all leaves.
  for _, row in ipairs({ 2, 3, 4 }) do
    local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { row, 0 }, { row, -1 }, {})
    MiniTest.expect.equality(#marks, 0)
  end
end

T["render_count_badges - unit"]["badges cleared when fold_indicators disabled"] = function()
  -- If badges exist from a previous call, disabling fold_indicators must clear
  -- them (BADGE_NS is wiped alongside FOLD_NS at the top of apply_fold_indicators).
  local tree   = require("voom.tree")
  local config = require("voom.config")
  local tree_buf = T["render_count_badges - unit"]._tree
  local body_buf = T["render_count_badges - unit"]._body

  -- First pass: enabled (no real badges here since folds are open, but verify
  -- the namespace is empty after a disabled pass too).
  tree.apply_fold_indicators(tree_buf, body_buf)

  local saved = config.options
  config.options = { fold_indicators = { enabled = false, icons = {} } }
  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_badges")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, 0, -1, {})
  MiniTest.expect.equality(#marks, 0)

  config.options = saved
end

-- ==============================================================================
-- render_count_badges — integration (real folds)
-- ==============================================================================
--
-- These tests open a real tree window so that foldexpr creates actual folds,
-- then fold nodes and re-apply indicators to exercise the badge rendering path.

T["render_count_badges - integration"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Body with three headings: H1 → H2 → H1 (Alpha has one child Beta).
      local lines = {
        "# Alpha",
        "content",
        "## Beta",
        "details",
        "# Gamma",
      }
      local body_buf = H.make_scratch_buf(lines)
      vim.api.nvim_buf_set_name(body_buf, "badge_test.md")
      vim.api.nvim_set_current_buf(body_buf)

      local tree = require("voom.tree")
      local tree_buf = tree.create(body_buf, "markdown")
      T["render_count_badges - integration"]._body    = body_buf
      T["render_count_badges - integration"]._tree    = tree_buf
    end,
    post_case = function()
      local tree = require("voom.tree")
      tree.close(T["render_count_badges - integration"]._body)
      H.del_buf(T["render_count_badges - integration"]._body)
    end,
  },
})

T["render_count_badges - integration"]["badge appears on collapsed parent"] = function()
  local tree     = require("voom.tree")
  local body_buf = T["render_count_badges - integration"]._body
  local tree_buf = T["render_count_badges - integration"]._tree
  local tree_win = (function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == tree_buf then return w end
    end
  end)()

  -- Collapse the first heading (Alpha → Beta) by closing its fold.
  vim.api.nvim_win_call(tree_win, function()
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
    vim.cmd("normal! zc")
  end)

  -- Re-apply indicators so badges are computed against the new fold state.
  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_badges")
  -- Row 0 (Alpha, levels[1]=1) should now have a "+1" badge.
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 0, 0 }, { 0, -1 }, {
    details = true,
  })
  MiniTest.expect.equality(#marks, 1)
  local vt = marks[1][4].virt_text
  MiniTest.expect.equality(vt[1][1], "+1")
  MiniTest.expect.equality(vt[1][2], "VoomBadge")
end

T["render_count_badges - integration"]["badge absent after re-opening fold"] = function()
  local tree     = require("voom.tree")
  local body_buf = T["render_count_badges - integration"]._body
  local tree_buf = T["render_count_badges - integration"]._tree
  local tree_win = (function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == tree_buf then return w end
    end
  end)()

  -- Collapse then re-open the first fold.
  vim.api.nvim_win_call(tree_win, function()
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
    vim.cmd("normal! zc")
    vim.cmd("normal! zo")
  end)

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_badges")
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 0, 0 }, { 0, -1 }, {})
  MiniTest.expect.equality(#marks, 0)
end

T["render_count_badges - integration"]["descendant count is total subtree size"] = function()
  -- Outline: Alpha(H1) → Beta(H2) → Gamma(H3) + Delta(H2) — 3 descendants of Alpha.
  local tree     = require("voom.tree")
  local state    = require("voom.state")
  local body_buf = T["render_count_badges - integration"]._body
  local tree_buf = T["render_count_badges - integration"]._tree
  local tree_win = (function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == tree_buf then return w end
    end
  end)()

  -- Replace the outline with a deeper hierarchy (4 headings: lev 1,2,3,2).
  local outline = {
    bnodes = { 1, 3, 5, 8 },
    levels = { 1, 2, 3, 2 },
    tlines = {
      " · Alpha",
      "   · Beta",
      "     · Gamma",
      "   · Delta",
    },
  }
  -- Rewrite tree buffer to match (4 lines).
  vim.api.nvim_buf_set_option(tree_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(tree_buf, 0, -1, false, {
    " · Alpha",
    "   · Beta",
    "     · Gamma",
    "   · Delta",
  })
  vim.api.nvim_buf_set_option(tree_buf, "modifiable", false)

  -- Update state directly so apply_fold_indicators sees the new outline.
  state.unregister(body_buf)
  state.register(body_buf, tree_buf, "markdown", outline)

  -- Force fold recomputation for the new line count.
  vim.api.nvim_win_call(tree_win, function()
    vim.cmd("normal! zx")   -- recompute folds
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
    vim.cmd("normal! zc")   -- collapse Alpha
  end)

  tree.apply_fold_indicators(tree_buf, body_buf)

  local ns = vim.api.nvim_create_namespace("voom_badges")
  -- Alpha (row 0, levels[1]=1) has 3 descendants (Beta, Gamma, Delta).
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, ns, { 0, 0 }, { 0, -1 }, {
    details = true,
  })
  MiniTest.expect.equality(#marks, 1)
  MiniTest.expect.equality(marks[1][4].virt_text[1][1], "+3")
end

return T
