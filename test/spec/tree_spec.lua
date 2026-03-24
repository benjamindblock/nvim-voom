local T = MiniTest.new_set()

-- ==============================================================================
-- Helpers
-- ==============================================================================

-- Load a fixture file into a 1-indexed table of strings (no trailing newline
-- per line), matching the format that nvim_buf_get_lines() returns.
local function load_fixture(name)
  local path = vim.fn.getcwd() .. "/test/fixtures/" .. name
  local lines = {}
  for line in io.lines(path) do
    table.insert(lines, line)
  end
  return lines
end

-- Create a scratch buffer loaded with `lines`, optionally named `name`.
-- Returns the buffer number.
local function make_scratch_buf(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Delete a buffer if it is still valid.
local function del_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- ==============================================================================
-- Module loading
-- ==============================================================================

T["tree loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom.tree")
  end)
end

T["state loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom.state")
  end)
end

-- ==============================================================================
-- state.lua: registration and queries
-- ==============================================================================

T["state"] = MiniTest.new_set()

T["state"]["register stores body and tree entries"] = function()
  local state = require("voom.state")
  local outline = { bnodes = { 1, 6 }, levels = { 1, 2 }, tlines = {} }

  -- Use placeholder buffer numbers that don't need to be real.
  state.register(100, 200, "markdown", outline)

  MiniTest.expect.equality(state.is_body(100), true)
  MiniTest.expect.equality(state.is_tree(200), true)
  MiniTest.expect.equality(state.get_tree(100), 200)
  MiniTest.expect.equality(state.get_body(200), 100)

  -- Clean up so state is not polluted between tests.
  state.unregister(100)
end

T["state"]["unregister removes both entries"] = function()
  local state = require("voom.state")
  local outline = { bnodes = { 3 }, levels = { 1 }, tlines = {} }

  state.register(101, 201, "markdown", outline)
  state.unregister(101)

  MiniTest.expect.equality(state.is_body(101), false)
  MiniTest.expect.equality(state.is_tree(201), false)
end

T["state"]["get_outline returns bnodes and levels"] = function()
  local state = require("voom.state")
  local outline = { bnodes = { 1, 10, 20 }, levels = { 1, 2, 3 }, tlines = {} }

  state.register(102, 202, "markdown", outline)
  local got = state.get_outline(102)

  MiniTest.expect.equality(got.bnodes, { 1, 10, 20 })
  MiniTest.expect.equality(got.levels, { 1, 2, 3 })

  state.unregister(102)
end

T["state"]["set_outline updates stored outline"] = function()
  local state = require("voom.state")
  local outline = { bnodes = { 1 }, levels = { 1 }, tlines = {} }

  state.register(103, 203, "markdown", outline)

  local new_outline = { bnodes = { 5, 15 }, levels = { 1, 2 } }
  state.set_outline(103, new_outline)

  local got = state.get_outline(103)
  MiniTest.expect.equality(got.bnodes, { 5, 15 })

  state.unregister(103)
end

T["state"]["snLn defaults to 1 and can be updated"] = function()
  local state = require("voom.state")
  local outline = { bnodes = {}, levels = {}, tlines = {} }

  state.register(104, 204, "markdown", outline)

  MiniTest.expect.equality(state.get_snLn(104), 1)

  state.set_snLn(104, 7)
  MiniTest.expect.equality(state.get_snLn(104), 7)

  state.unregister(104)
end

-- ==============================================================================
-- tree.lua: create
-- ==============================================================================

T["tree.create"] = MiniTest.new_set({
  hooks = {
    -- Each test in this set registers a body buffer; track it for teardown.
    pre_case = function()
      T["tree.create"]._body_buf = nil
      T["tree.create"]._tree_buf = nil
    end,
    post_case = function()
      -- Close the tree (which also unregisters state), then delete the body.
      local state = require("voom.state")
      local body  = T["tree.create"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.create"]._body_buf)
    end,
  },
})

T["tree.create"]["returns a valid buffer number"] = function()
  local tree   = require("voom.tree")
  local lines  = load_fixture("sample.md")
  local body   = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  MiniTest.expect.equality(type(tree_buf), "number")
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), true)
end

T["tree.create"]["tree buffer name ends with _VOOMbody_bufnr"] = function()
  local tree  = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body  = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  local name = vim.api.nvim_buf_get_name(tree_buf)
  MiniTest.expect.equality(name:match("_VOOM" .. body .. "$") ~= nil, true)
end

T["tree.create"]["tree buffer is nofile and non-modifiable"] = function()
  local tree  = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body  = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  MiniTest.expect.equality(vim.api.nvim_buf_get_option(tree_buf, "buftype"),    "nofile")
  MiniTest.expect.equality(vim.api.nvim_buf_get_option(tree_buf, "modifiable"), false)
end

T["tree.create"]["tree line 1 is the root node with filename"] = function()
  local tree  = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body  = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  local first = vim.api.nvim_buf_get_lines(tree_buf, 0, 1, false)[1]
  -- Root node contains the filename tail.
  MiniTest.expect.equality(first:match("• sample%.md") ~= nil, true)
end

T["tree.create"]["tree lines 2+ match headings from sample.md"] = function()
  local tree  = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body  = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  -- sample.md has 10 headings; with the root node the tree has 11 lines.
  local tree_lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(#tree_lines, 11)

  -- Line 2 is the first heading: "# Project Overview" → level 1, no indent.
  MiniTest.expect.equality(tree_lines[2], " · Project Overview")
  -- Line 3 is the second heading: "## Installation" → level 2, one "· ".
  MiniTest.expect.equality(tree_lines[3], " · · Installation")
end

T["tree.create"]["registers body and tree in state"] = function()
  local tree  = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body  = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  MiniTest.expect.equality(state.is_body(body), true)
  MiniTest.expect.equality(state.is_tree(tree_buf), true)
  MiniTest.expect.equality(state.get_tree(body), tree_buf)
  MiniTest.expect.equality(state.get_body(tree_buf), body)
end

-- ==============================================================================
-- tree.lua: navigate_to_body
-- ==============================================================================

T["tree.navigate_to_body"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["tree.navigate_to_body"]._body_buf = nil
      T["tree.navigate_to_body"]._tree_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body  = T["tree.navigate_to_body"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.navigate_to_body"]._body_buf)
    end,
  },
})

T["tree.navigate_to_body"]["tree line 1 navigates to body line 1"] = function()
  local tree_mod = require("voom.tree")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.navigate_to_body"]._body_buf = body

  -- The body buffer must be visible in a window for navigate_to_body to work.
  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.navigate_to_body"]._tree_buf = tree_buf

  -- Find the body window (tree.create leaves focus there).
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end
  MiniTest.expect.equality(body_win ~= nil, true)

  -- Navigate from tree line 1 (root node) → body line 1.
  tree_mod.navigate_to_body(tree_buf, 1)

  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], 1)
end

T["tree.navigate_to_body"]["tree line 2 navigates to first heading bnode"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.navigate_to_body"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.navigate_to_body"]._tree_buf = tree_buf

  -- Tree line 2 = first heading.  In sample.md that is "# Project Overview"
  -- at body line 1.
  local expected_bnode = state.get_outline(body).bnodes[1]
  MiniTest.expect.equality(expected_bnode, 1)

  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end

  tree_mod.navigate_to_body(tree_buf, 2)
  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], expected_bnode)
end

T["tree.navigate_to_body"]["tree line 3 navigates to second heading bnode"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.navigate_to_body"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.navigate_to_body"]._tree_buf = tree_buf

  -- Tree line 3 = second heading ("## Installation" at body line 6).
  local expected_bnode = state.get_outline(body).bnodes[2]
  MiniTest.expect.equality(expected_bnode, 6)

  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end

  tree_mod.navigate_to_body(tree_buf, 3)
  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], expected_bnode)
end

-- ==============================================================================
-- tree.lua: close
-- ==============================================================================

T["tree.close"] = MiniTest.new_set()

T["tree.close"]["deletes the tree buffer and unregisters state"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")

  local tree_buf = tree_mod.create(body, "markdown")

  -- Confirm registration before close.
  MiniTest.expect.equality(state.is_body(body), true)

  tree_mod.close(body)

  -- Buffer should be gone and state cleaned up.
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
  MiniTest.expect.equality(state.is_body(body), false)
  MiniTest.expect.equality(state.is_tree(tree_buf), false)

  del_buf(body)
end

-- ==============================================================================
-- tree.lua: update
-- ==============================================================================

T["tree.update"] = MiniTest.new_set({
  hooks = {
    pre_case  = function() T["tree.update"]._body_buf = nil end,
    post_case = function()
      local state = require("voom.state")
      local body  = T["tree.update"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(body)
    end,
  },
})

T["tree.update"]["rebuilds tree lines after body content changes"] = function()
  local tree_mod = require("voom.tree")

  -- Start with a single-heading buffer.
  local body = make_scratch_buf({ "# Only Heading" }, "update_test.md")
  T["tree.update"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")

  -- Initially: root node + 1 heading = 2 lines.
  local before = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(#before, 2)

  -- Add a second heading to the body buffer.
  vim.api.nvim_buf_set_option(body, "modifiable", true)
  vim.api.nvim_buf_set_lines(body, -1, -1, false, { "## Sub Heading" })
  vim.api.nvim_buf_set_option(body, "modifiable", false)

  tree_mod.update(body)

  -- After update: root node + 2 headings = 3 lines.
  local after = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(#after, 3)
  MiniTest.expect.equality(after[3], " · · Sub Heading")
end

-- ==============================================================================
-- tree.lua: follow_cursor
-- ==============================================================================

T["tree.follow_cursor"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["tree.follow_cursor"]._body_buf = nil
      T["tree.follow_cursor"]._tree_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body  = T["tree.follow_cursor"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.follow_cursor"]._body_buf)
    end,
  },
})

T["tree.follow_cursor"]["focus stays in tree after scrolling body"] = function()
  local tree_mod = require("voom.tree")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  -- Move focus to the tree window before calling follow_cursor.
  local tree_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == tree_buf then
      tree_win = win
      break
    end
  end
  vim.api.nvim_set_current_win(tree_win)

  tree_mod.follow_cursor(tree_buf, 3)

  -- Focus must still be in the tree window.
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_win)
end

T["tree.follow_cursor"]["root line scrolls body to line 1"] = function()
  local tree_mod = require("voom.tree")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end

  tree_mod.follow_cursor(tree_buf, 1)

  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], 1)
end

T["tree.follow_cursor"]["heading line scrolls body to correct bnode"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  -- Tree line 3 → second heading ("## Installation" at body line 6).
  local expected = state.get_outline(body).bnodes[2]
  MiniTest.expect.equality(expected, 6)

  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end

  tree_mod.follow_cursor(tree_buf, 3)

  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], expected)
end

T["tree.follow_cursor"]["updates snLn in state"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  tree_mod.follow_cursor(tree_buf, 4)

  MiniTest.expect.equality(state.get_snLn(body), 4)
end

-- ==============================================================================
-- <Tab> keymap: navigate to heading AND switch focus
-- ==============================================================================

T["tab keymap"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["tab keymap"]._body_buf = nil
      T["tab keymap"]._tree_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body  = T["tab keymap"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tab keymap"]._body_buf)
    end,
  },
})

T["tab keymap"]["moves focus to body at the selected heading"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tab keymap"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tab keymap"]._tree_buf = tree_buf

  -- Focus the tree window and place cursor on tree line 3 (second heading).
  local tree_win
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wb = vim.api.nvim_win_get_buf(win)
    if wb == tree_buf then tree_win = win end
    if wb == body      then body_win = win end
  end
  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })

  -- Simulate <Tab> by calling navigate_to_body directly (same as the keymap
  -- callback, which reads the current cursor line and calls navigate_to_body).
  tree_mod.navigate_to_body(tree_buf, 3)

  -- Focus should now be in the body window.
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), body_win)

  -- Body cursor should be at bnodes[2] (second heading = "## Installation" = line 6).
  local expected = state.get_outline(body).bnodes[2]
  local cursor   = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], expected)
end

-- ==============================================================================
-- state.lua: changedtick tracking
-- ==============================================================================

T["state.changedtick"] = MiniTest.new_set()

T["state.changedtick"]["get_changedtick returns stored tick"] = function()
  local state = require("voom.state")
  local buf = vim.api.nvim_create_buf(false, true)
  local tick_before = vim.api.nvim_buf_get_changedtick(buf)

  local outline = { bnodes = {}, levels = {}, tlines = {} }
  state.register(buf, 300, "markdown", outline)

  -- The tick stored at registration should equal the tick at register time.
  MiniTest.expect.equality(state.get_changedtick(buf), tick_before)

  state.unregister(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["state.changedtick"]["set_changedtick updates stored tick"] = function()
  local state = require("voom.state")
  local buf = vim.api.nvim_create_buf(false, true)
  local outline = { bnodes = {}, levels = {}, tlines = {} }
  state.register(buf, 301, "markdown", outline)

  state.set_changedtick(buf, 9999)
  MiniTest.expect.equality(state.get_changedtick(buf), 9999)

  state.unregister(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ==============================================================================
-- tree.lua: outline traversal utilities
-- ==============================================================================
--
-- These tests exercise the pure traversal functions directly, using plain
-- levels arrays without needing a live Neovim window.
--
-- The fixture levels array below describes the following tree structure:
--
--   tree line 1  — root (no levels entry)
--   tree line 2  — level 1  (levels[1] = 1)
--   tree line 3  — level 2  (levels[2] = 2)
--   tree line 4  — level 2  (levels[3] = 2)
--   tree line 5  — level 1  (levels[4] = 1)
--   tree line 6  — level 2  (levels[5] = 2)

T["outline traversal"] = MiniTest.new_set()

T["outline traversal"]["find_parent_lnum: level-1 node returns root (1)"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 2 is a level-1 heading; its parent is the root (line 1).
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 2), 1)
  -- Tree line 5 is also level 1.
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 5), 1)
end

T["outline traversal"]["find_parent_lnum: level-2 node returns nearest level-1 ancestor"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 3 (level 2) → parent is tree line 2 (level 1).
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 3), 2)
  -- Tree line 4 (level 2) → parent is still tree line 2.
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 4), 2)
  -- Tree line 6 (level 2) → parent is tree line 5.
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 6), 5)
end

T["outline traversal"]["find_parent_lnum: root line returns 1"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2 }
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 1), 1)
end

T["outline traversal"]["find_first_child_lnum: node with child returns child lnum"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 2 (level 1) has a child at tree line 3 (level 2).
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 2), 3)
  -- Root (tree line 1) has a child at tree line 2.
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 1), 2)
end

T["outline traversal"]["find_first_child_lnum: leaf node returns nil"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 3 (level 2) is followed by tree line 4 also at level 2 — same
  -- level, not a child.
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 3), nil)
  -- Tree line 6 (level 2) is the last node — no child.
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 6), nil)
end

T["outline traversal"]["find_prev_sibling_lnum: first sibling returns nil"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 2 is the first level-1 sibling; no previous sibling.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 2), nil)
  -- Tree line 3 is the first level-2 child under tree line 2.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 3), nil)
end

T["outline traversal"]["find_prev_sibling_lnum: middle sibling returns previous"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 4 (level 2) — previous sibling is tree line 3.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 4), 3)
  -- Tree line 5 (level 1) — previous sibling is tree line 2.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 5), 2)
end

T["outline traversal"]["find_next_sibling_lnum: last sibling returns nil"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 5 is the last level-1 node.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 5), nil)
  -- Tree line 6 is the last level-2 node under tree line 5.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 6), nil)
end

T["outline traversal"]["find_next_sibling_lnum: middle sibling returns next"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 2 (level 1) → next sibling is tree line 5.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 2), 5)
  -- Tree line 3 (level 2) → next sibling is tree line 4.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 3), 4)
end

T["outline traversal"]["find_first_sibling_lnum: already at first returns same"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  MiniTest.expect.equality(tree.find_first_sibling_lnum(levels, 2), 2)
end

T["outline traversal"]["find_last_sibling_lnum: already at last returns same"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  MiniTest.expect.equality(tree.find_last_sibling_lnum(levels, 5), 5)
end

T["outline traversal"]["find_first_sibling_lnum: middle sibling returns first"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 4 is a level-2 sibling; the first sibling is tree line 3.
  MiniTest.expect.equality(tree.find_first_sibling_lnum(levels, 4), 3)
  -- Tree line 5 (level 1) is second; first is tree line 2.
  MiniTest.expect.equality(tree.find_first_sibling_lnum(levels, 5), 2)
end

T["outline traversal"]["find_last_sibling_lnum: middle sibling returns last"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 3 is a level-2 sibling; the last sibling under the same parent
  -- is tree line 4.
  MiniTest.expect.equality(tree.find_last_sibling_lnum(levels, 3), 4)
  -- Tree line 2 (level 1); last level-1 sibling is tree line 5.
  MiniTest.expect.equality(tree.find_last_sibling_lnum(levels, 2), 5)
end

-- ==============================================================================
-- tree.lua: build_unl
-- ==============================================================================

T["tree.build_unl"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["tree.build_unl"]._body_buf = nil
      T["tree.build_unl"]._tree_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body = T["tree.build_unl"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.build_unl"]._body_buf)
    end,
  },
})

T["tree.build_unl"]["root node returns empty string"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.build_unl"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.build_unl"]._tree_buf = tree_buf

  local outline = state.get_outline(body)
  MiniTest.expect.equality(tree_mod.build_unl(tree_buf, outline.levels, 1), "")
end

T["tree.build_unl"]["level-1 node returns just its heading"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.build_unl"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.build_unl"]._tree_buf = tree_buf

  local outline = state.get_outline(body)
  -- Tree line 2 = "# Project Overview" (level 1).
  local unl = tree_mod.build_unl(tree_buf, outline.levels, 2)
  MiniTest.expect.equality(unl, "Project Overview")
end

T["tree.build_unl"]["nested node returns full path"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.build_unl"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.build_unl"]._tree_buf = tree_buf

  local outline = state.get_outline(body)
  -- Tree line 4 = "### Requirements" (level 3, under Installation → Project Overview).
  -- Expected UNL: "Project Overview > Installation > Requirements"
  local unl = tree_mod.build_unl(tree_buf, outline.levels, 4)
  MiniTest.expect.equality(unl, "Project Overview > Installation > Requirements")
end

-- ==============================================================================
-- tree.lua: body_select
-- ==============================================================================

T["tree.body_select"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["tree.body_select"]._body_buf = nil
      T["tree.body_select"]._tree_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body = T["tree.body_select"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.body_select"]._body_buf)
    end,
  },
})

T["tree.body_select"]["cursor on body line before first heading selects root"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")

  -- A buffer where the first heading is not on line 1.
  local lines = {
    "preamble text",
    "",
    "# First Heading",
    "content",
  }
  local body = make_scratch_buf(lines, "select_test.md")
  T["tree.body_select"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.body_select"]._tree_buf = tree_buf

  -- Place cursor on the preamble (before first heading).
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then body_win = win break end
  end
  vim.api.nvim_win_set_cursor(body_win, { 1, 0 })
  vim.api.nvim_set_current_win(body_win)

  tree_mod.body_select(body)

  -- No bnode ≤ 1 (first heading is on line 3), so root is selected.
  MiniTest.expect.equality(state.get_snLn(body), 1)
  -- Focus should remain in the body window.
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), body_win)
end

T["tree.body_select"]["cursor on heading line selects that heading's tree node"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.body_select"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.body_select"]._tree_buf = tree_buf

  -- sample.md line 1 is "# Project Overview" → bnodes[1] = 1 → tree line 2.
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then body_win = win break end
  end
  vim.api.nvim_win_set_cursor(body_win, { 1, 0 })
  vim.api.nvim_set_current_win(body_win)

  tree_mod.body_select(body)

  MiniTest.expect.equality(state.get_snLn(body), 2)
end

T["tree.body_select"]["cursor in body content between headings selects preceding heading"] = function()
  local tree_mod = require("voom.tree")
  local state    = require("voom.state")
  local lines    = load_fixture("sample.md")
  local body     = make_scratch_buf(lines, "sample.md")
  T["tree.body_select"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.body_select"]._tree_buf = tree_buf

  -- sample.md line 3 is body content under "# Project Overview" (line 1).
  -- The preceding heading is still the first one → tree line 2.
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then body_win = win break end
  end
  vim.api.nvim_win_set_cursor(body_win, { 3, 0 })
  vim.api.nvim_set_current_win(body_win)

  tree_mod.body_select(body)

  -- Cursor is on line 3, bnodes[1]=1 ≤ 3, bnodes[2]=6 > 3 → selects tree line 2.
  MiniTest.expect.equality(state.get_snLn(body), 2)
end

-- ==============================================================================
-- tree_foldexpr
-- ==============================================================================

T["tree_foldexpr"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Register a minimal body/tree pair so tree_foldexpr can look up state.
      -- We need a real buffer so nvim_get_current_buf() returns the tree buf.
      local state = require("voom.state")
      local outline = {
        bnodes = { 1, 5, 10, 15 },
        levels = { 1, 2, 3, 2 },
        tlines = {},
      }
      local body_buf = vim.api.nvim_create_buf(false, true)
      local tree_buf = vim.api.nvim_create_buf(false, true)
      state.register(body_buf, tree_buf, "markdown", outline)
      T["tree_foldexpr"]._body = body_buf
      T["tree_foldexpr"]._tree = tree_buf
      -- Make the tree buffer current so tree_foldexpr picks it up.
      vim.api.nvim_set_current_buf(tree_buf)
    end,
    post_case = function()
      local state = require("voom.state")
      state.unregister(T["tree_foldexpr"]._body)
      del_buf(T["tree_foldexpr"]._body)
      del_buf(T["tree_foldexpr"]._tree)
    end,
  },
})

T["tree_foldexpr"]["line 1 (root) opens a top-level fold"] = function()
  local tree = require("voom.tree")
  MiniTest.expect.equality(tree.tree_foldexpr(1), ">1")
end

T["tree_foldexpr"]["line 2 (level-1 heading) opens fold at depth 1"] = function()
  local tree = require("voom.tree")
  -- levels[1] = 1
  MiniTest.expect.equality(tree.tree_foldexpr(2), ">1")
end

T["tree_foldexpr"]["line 3 (level-2 heading) opens fold at depth 2"] = function()
  local tree = require("voom.tree")
  -- levels[2] = 2
  MiniTest.expect.equality(tree.tree_foldexpr(3), ">2")
end

T["tree_foldexpr"]["line 4 (level-3 heading) opens fold at depth 3"] = function()
  local tree = require("voom.tree")
  -- levels[3] = 3
  MiniTest.expect.equality(tree.tree_foldexpr(4), ">3")
end

T["tree_foldexpr"]["line 5 (level-2 heading) opens fold at depth 2"] = function()
  local tree = require("voom.tree")
  -- levels[4] = 2
  MiniTest.expect.equality(tree.tree_foldexpr(5), ">2")
end

T["tree_foldexpr"]["returns '0' when no state is registered"] = function()
  local state = require("voom.state")
  local tree  = require("voom.tree")
  -- Unregister so state is absent, then point to an unregistered tree buf.
  local orphan = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(orphan)
  local result = tree.tree_foldexpr(2)
  MiniTest.expect.equality(result, "0")
  del_buf(orphan)
  -- Restore the tree buf as current for post_case cleanup.
  vim.api.nvim_set_current_buf(T["tree_foldexpr"]._tree)
end

return T
