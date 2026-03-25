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

-- Find a window showing `buf` in the current tabpage.
local function find_win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

local function find_tree_lnum_by_text(tree_buf, text)
  local lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return i
    end
  end
  return nil
end

local function top_heading_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {}
  for _, line in ipairs(lines) do
    if line:match("^#%s") then
      table.insert(out, line)
    end
  end
  return out
end

local function press(keys)
  local term = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(term, "xt", false)
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
      local body = T["tree.create"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.create"]._body_buf)
    end,
  },
})

T["tree.create"]["returns a valid buffer number"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  MiniTest.expect.equality(type(tree_buf), "number")
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), true)
end

T["tree.create"]["tree buffer name ends with _VOOMbody_bufnr"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  local name = vim.api.nvim_buf_get_name(tree_buf)
  MiniTest.expect.equality(name:match("_VOOM" .. body .. "$") ~= nil, true)
end

T["tree.create"]["tree buffer is nofile and non-modifiable"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  MiniTest.expect.equality(vim.api.nvim_buf_get_option(tree_buf, "buftype"), "nofile")
  MiniTest.expect.equality(vim.api.nvim_buf_get_option(tree_buf, "modifiable"), false)
end

T["tree.create"]["tree line 1 is the first heading"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  -- sample.md has 10 headings; the tree has exactly 10 lines (no root node).
  local tree_lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(#tree_lines, 10)

  -- Line 1 is the first heading: "# Project Overview" → level 1, no indent.
  MiniTest.expect.equality(tree_lines[1], " · Project Overview")
  -- Line 2 is the second heading: "## Installation" → level 2, two-space indent.
  MiniTest.expect.equality(tree_lines[2], "   · Installation")
end

T["tree.create"]["renders exact tree lines for mixed heading styles and deep nesting"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("edge_cases.md")
  local body = make_scratch_buf(lines, "edge_cases.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  local tree_lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(tree_lines, {
    " · Root",
    "   · Child One",
    "     · Grandchild",
    "       · Great Grandchild",
    "   · Empty Child",
    " · Setext Parent",
    "   · Setext Child",
    " · Tail",
  })
end

T["tree.create"]["registers body and tree in state"] = function()
  local tree = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  MiniTest.expect.equality(state.is_body(body), true)
  MiniTest.expect.equality(state.is_tree(tree_buf), true)
  MiniTest.expect.equality(state.get_tree(body), tree_buf)
  MiniTest.expect.equality(state.get_body(tree_buf), body)
end

T["tree.create"]["initializes folds on first open"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local foldlevel = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldlevel(2)
  end)
  MiniTest.expect.equality(foldlevel > 0, true)
end

T["tree.create"]["sets winbar with filename and heading count"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local winbar = vim.api.nvim_get_option_value("winbar", { win = tree_win })
  -- Winbar should contain the filename tail.
  MiniTest.expect.equality(winbar:find("sample%.md", 1, false) ~= nil, true)
  -- sample.md has 10 headings.
  MiniTest.expect.equality(winbar:find("10 headings", 1, true) ~= nil, true)
end

T["tree.create"]["winbar updates heading count after tree.update"] = function()
  local tree = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.create"]._body_buf = body

  local tree_buf = tree.create(body, "markdown")
  T["tree.create"]._tree_buf = tree_buf

  -- Remove all headings from the body buffer and trigger a rebuild.
  local plain = { "No headings here." }
  vim.api.nvim_buf_set_lines(body, 0, -1, false, plain)
  tree.update(body)

  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local winbar = vim.api.nvim_get_option_value("winbar", { win = tree_win })
  MiniTest.expect.equality(winbar:find("0 headings", 1, true) ~= nil, true)
end

-- ==============================================================================
-- tree.lua: fold actions
-- ==============================================================================

T["tree.fold_actions"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["tree.fold_actions"]._body_buf = nil
      T["tree.fold_actions"]._tree_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body = T["tree.fold_actions"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.fold_actions"]._body_buf)
    end,
  },
})

T["tree.fold_actions"]["tree_toggle_fold closes and reopens current node"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.fold_actions"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.fold_actions"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  tree_mod.tree_toggle_fold(tree_buf)
  local after_close = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(2)
  end)
  MiniTest.expect.equality(after_close, 2)

  tree_mod.tree_toggle_fold(tree_buf)
  local after_open = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(2)
  end)
  MiniTest.expect.equality(after_open, -1)
end

T["tree.fold_actions"]["tree_contract_siblings closes sibling nodes that have children"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.fold_actions"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.fold_actions"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  -- "Installation" (line 2) is a level-2 sibling with children.
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  tree_mod.tree_contract_siblings(tree_buf)

  local closed = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(2)
  end)
  MiniTest.expect.equality(closed, 2)

  -- Cursor must not have moved during sibling iteration.
  local cursor_after = vim.api.nvim_win_get_cursor(tree_win)
  MiniTest.expect.equality(cursor_after[1], 2)
end

T["tree.fold_actions"]["tree_expand_siblings opens closed sibling nodes"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.fold_actions"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.fold_actions"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  -- "Installation" (line 2) is a level-2 sibling with children; collapse
  -- siblings first so there is something for expand to reopen.
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  tree_mod.tree_contract_siblings(tree_buf)

  local before = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(2)
  end)
  MiniTest.expect.equality(before, 2)

  -- Expand siblings; the fold on line 2 should now be open.
  tree_mod.tree_expand_siblings(tree_buf)

  local after = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(2)
  end)
  MiniTest.expect.equality(after, -1)

  -- Cursor must not have moved during sibling iteration.
  local cursor_after = vim.api.nvim_win_get_cursor(tree_win)
  MiniTest.expect.equality(cursor_after[1], 2)
end

T["tree.fold_actions"]["tree_navigate_right opens closed node before descending"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.fold_actions"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.fold_actions"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  tree_mod.tree_toggle_fold(tree_buf)
  local before = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(2)
  end)
  MiniTest.expect.equality(before, 2)

  tree_mod.tree_navigate_right(tree_buf)
  local cursor = vim.api.nvim_win_get_cursor(tree_win)
  MiniTest.expect.equality(cursor[1], 3)

  local after = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(2)
  end)
  MiniTest.expect.equality(after, -1)
end

T["tree.fold_actions"]["tree_contract_siblings on README Tree pane does not collapse first heading"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("readme_outline.md")
  local body = make_scratch_buf(lines, "readme_outline.md")
  T["tree.fold_actions"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.fold_actions"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local tree_pane_lnum = find_tree_lnum_by_text(tree_buf, "Tree pane")
  MiniTest.expect.equality(tree_pane_lnum ~= nil, true)
  vim.api.nvim_win_set_cursor(tree_win, { tree_pane_lnum, 0 })

  tree_mod.tree_contract_siblings(tree_buf)

  local first_line_fold_state = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(1)
  end)
  MiniTest.expect.equality(first_line_fold_state, -1)

  local keymaps_lnum = find_tree_lnum_by_text(tree_buf, "Keymaps — tree pane")
  MiniTest.expect.equality(keymaps_lnum ~= nil, true)
  local sibling_closed = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(keymaps_lnum)
  end)
  MiniTest.expect.equality(sibling_closed, keymaps_lnum)
end

T["tree.fold_actions"]["tree_contract_siblings works after promote then demote on SESSION"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local lines = load_fixture("session_outline.md")
  local body = make_scratch_buf(lines, "session_outline.md")
  T["tree.fold_actions"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.fold_actions"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local bugs_lnum = find_tree_lnum_by_text(tree_buf, "Bugs / Issues")
  MiniTest.expect.equality(bugs_lnum ~= nil, true)
  vim.api.nvim_win_set_cursor(tree_win, { bugs_lnum, 0 })
  oop.promote(tree_buf)

  local bugs_lnum2 = find_tree_lnum_by_text(tree_buf, "Bugs / Issues")
  MiniTest.expect.equality(bugs_lnum2 ~= nil, true)
  vim.api.nvim_win_set_cursor(tree_win, { bugs_lnum2, 0 })
  oop.demote(tree_buf)

  local first_heading_lnum = find_tree_lnum_by_text(tree_buf, "VOoM Session Notes")
  MiniTest.expect.equality(first_heading_lnum ~= nil, true)
  vim.api.nvim_win_set_cursor(tree_win, { first_heading_lnum, 0 })

  tree_mod.tree_contract_siblings(tree_buf)
  local closed = vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(first_heading_lnum)
  end)
  MiniTest.expect.equality(closed, first_heading_lnum)
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
      local body = T["tree.navigate_to_body"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.navigate_to_body"]._body_buf)
    end,
  },
})

T["tree.navigate_to_body"]["tree line 1 navigates to body line 1"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
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

  -- Navigate from tree line 1 (first heading, "# Project Overview") → body line 1.
  tree_mod.navigate_to_body(tree_buf, 1)

  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], 1)
end

T["tree.navigate_to_body"]["tree line 2 navigates to second heading bnode"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.navigate_to_body"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.navigate_to_body"]._tree_buf = tree_buf

  -- Tree line 2 = second heading ("## Installation" at body line 6).
  local expected_bnode = state.get_outline(body).bnodes[2]

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

T["tree.navigate_to_body"]["tree line 3 navigates to third heading bnode"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.navigate_to_body"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.navigate_to_body"]._tree_buf = tree_buf

  -- Tree line 3 = third heading ("### Requirements" at body line 10).
  local expected_bnode = state.get_outline(body).bnodes[3]

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
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")

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
    pre_case = function()
      T["tree.update"]._body_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body = T["tree.update"]._body_buf
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

  -- Initially: 1 heading = 1 line (no root node).
  local before = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(#before, 1)

  -- Add a second heading to the body buffer.
  vim.api.nvim_buf_set_option(body, "modifiable", true)
  vim.api.nvim_buf_set_lines(body, -1, -1, false, { "## Sub Heading" })
  vim.api.nvim_buf_set_option(body, "modifiable", false)

  tree_mod.update(body)

  -- After update: 2 headings = 2 lines.
  local after = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(#after, 2)
  MiniTest.expect.equality(after[2], "   · Sub Heading")
end

T["tree.update"]["BufWritePost refreshes tree lines and changedtick"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")

  local body = make_scratch_buf({ "# Alpha", "", "## Beta" }, "update_autocmd.md")
  T["tree.update"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  local before_tick = state.get_changedtick(body)

  vim.api.nvim_buf_set_lines(body, -1, -1, false, { "", "## Gamma" })

  MiniTest.expect.no_error(function()
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = body })
  end)

  local tree_lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  MiniTest.expect.equality(tree_lines[#tree_lines], "   · Gamma")
  MiniTest.expect.equality(state.get_changedtick(body), vim.api.nvim_buf_get_changedtick(body))
  MiniTest.expect.equality(state.get_changedtick(body) ~= before_tick, true)
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
      local body = T["tree.follow_cursor"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.follow_cursor"]._body_buf)
    end,
  },
})

T["tree.follow_cursor"]["focus stays in tree after scrolling body"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
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

T["tree.follow_cursor"]["line 1 scrolls body to first heading"] = function()
  local tree_mod = require("voom.tree")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
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
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  -- Tree line 3 → third heading ("### Requirements" at body line 10).
  local expected = state.get_outline(body).bnodes[3]

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
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  tree_mod.follow_cursor(tree_buf, 4)

  MiniTest.expect.equality(state.get_snLn(body), 4)
end

T["tree.follow_cursor"]["unsaved body edits refresh stale tree before follow"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = {
    "# Root",
    "",
    "## Keep",
    "",
    "## Gone",
    "",
  }
  local body = make_scratch_buf(lines, "follow_refresh.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  local tree_win = find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local gone_lnum = find_tree_lnum_by_text(tree_buf, "Gone")
  MiniTest.expect.equality(gone_lnum ~= nil, true)

  local tick_before = state.get_changedtick(body)

  -- Delete "## Gone" from the body without saving; this leaves tree state stale
  -- until the next changedtick-driven refresh.
  vim.api.nvim_buf_set_lines(body, 4, 5, false, {})
  local tick_after_edit = vim.api.nvim_buf_get_changedtick(body)
  MiniTest.expect.equality(tick_after_edit ~= tick_before, true)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { gone_lnum, 0 })

  MiniTest.expect.no_error(function()
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = tree_buf })
  end)

  -- Tree should have rebuilt from current body content and removed stale node.
  MiniTest.expect.equality(find_tree_lnum_by_text(tree_buf, "Gone"), nil)
  MiniTest.expect.equality(state.get_changedtick(body), vim.api.nvim_buf_get_changedtick(body))
end

T["tree.follow_cursor"]["stale bnode beyond EOF is clamped"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local body = make_scratch_buf({ "# One" }, "follow_clamp.md")
  T["tree.follow_cursor"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.follow_cursor"]._tree_buf = tree_buf

  local body_win = find_win_for_buf(body)
  MiniTest.expect.equality(body_win ~= nil, true)

  -- Inject stale outline data to emulate a corrupted/stale bnode mapping.
  state.set_outline(body, {
    bnodes = { 999 },
    levels = { 1 },
    tlines = { " · One" },
  })

  -- Tree line 1 maps to bnodes[1]=999, which is beyond EOF and gets clamped.
  MiniTest.expect.no_error(function()
    tree_mod.follow_cursor(tree_buf, 1)
  end)

  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], 1)
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
      local body = T["tab keymap"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tab keymap"]._body_buf)
    end,
  },
})

T["tab keymap"]["moves focus to body at the selected heading"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tab keymap"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tab keymap"]._tree_buf = tree_buf

  -- Focus the tree window and place cursor on tree line 3 (third heading).
  local tree_win
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wb = vim.api.nvim_win_get_buf(win)
    if wb == tree_buf then
      tree_win = win
    end
    if wb == body then
      body_win = win
    end
  end
  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })

  -- Simulate <Tab> by calling navigate_to_body directly (same as the keymap
  -- callback, which reads the current cursor line and calls navigate_to_body).
  tree_mod.navigate_to_body(tree_buf, 3)

  -- Focus should now be in the body window.
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), body_win)

  -- Body cursor should be at bnodes[3] (third heading = "### Requirements" = line 10).
  local expected = state.get_outline(body).bnodes[3]
  local cursor = vim.api.nvim_win_get_cursor(body_win)
  MiniTest.expect.equality(cursor[1], expected)
end

-- ==============================================================================
-- tree undo / redo from tree pane
-- ==============================================================================

T["tree.undo_redo"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      T["tree.undo_redo"]._body_buf = nil
      T["tree.undo_redo"]._tree_buf = nil
    end,
    post_case = function()
      local state = require("voom.state")
      local body = T["tree.undo_redo"]._body_buf
      if body and state.is_body(body) then
        require("voom.tree").close(body)
      end
      del_buf(T["tree.undo_redo"]._body_buf)
    end,
  },
})

T["tree.undo_redo"]["undoes move_up one action at a time and preserves tree cursor line"] = function()
  local tree_mod = require("voom.tree")
  local lines = {
    "# One",
    "",
    "one",
    "# Two",
    "",
    "two",
    "# Three",
    "",
    "three",
    "# Four",
    "",
    "four",
  }
  local body = make_scratch_buf(lines, "undo_move.md")
  T["tree.undo_redo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.undo_redo"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(tree_win)

  -- Move "Three" up twice.  Tree line 3 = "Three" (One=1, Two=2, Three=3, Four=4).
  vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })
  press("^^")
  press("^^")
  MiniTest.expect.equality(top_heading_lines(body), { "# Three", "# One", "# Two", "# Four" })
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 1)

  -- First undo should revert only one move.
  tree_mod.tree_undo(tree_buf)
  MiniTest.expect.equality(top_heading_lines(body), { "# One", "# Three", "# Two", "# Four" })
  -- Cursor should not jump to top/root.
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 2)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1] ~= 1, true)
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_win)

  -- Second undo returns to original.
  tree_mod.tree_undo(tree_buf)
  MiniTest.expect.equality(top_heading_lines(body), { "# One", "# Two", "# Three", "# Four" })

  -- Redo reapplies one step.
  tree_mod.tree_redo(tree_buf)
  MiniTest.expect.equality(top_heading_lines(body), { "# One", "# Three", "# Two", "# Four" })
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_win)
end

T["tree.undo_redo"]["undoes demote from tree pane"] = function()
  local tree_mod = require("voom.tree")
  local lines = {
    "# One",
    "",
    "one",
    "# Two",
    "",
    "two",
    "# Three",
    "",
    "three",
  }
  local body = make_scratch_buf(lines, "undo_demote.md")
  T["tree.undo_redo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.undo_redo"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(tree_win)

  -- "Two" is tree line 2 (One=1, Two=2, Three=3). Demote should make it level-2.
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  press(">>")
  MiniTest.expect.equality(find_tree_lnum_by_text(tree_buf, "Two") ~= nil, true)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(body, 0, -1, false)[5], "## Two")

  tree_mod.tree_undo(tree_buf)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(body, 0, -1, false)[4], "# Two")
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_win)
end

T["tree.undo_redo"]["undoes direct body edits from tree pane"] = function()
  local tree_mod = require("voom.tree")
  local lines = {
    "# One",
    "",
    "one",
    "# Two",
    "",
    "two",
  }
  local body = make_scratch_buf(lines, "undo_body_edit.md")
  T["tree.undo_redo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.undo_redo"]._tree_buf = tree_buf

  local body_win = find_win_for_buf(body)
  local tree_win = find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(body_win)
  vim.api.nvim_buf_set_lines(body, 0, 1, false, { "# One changed" })

  vim.api.nvim_set_current_win(tree_win)
  tree_mod.tree_undo(tree_buf)

  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(body, 0, 1, false)[1], "# One")
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_win)
end

T["tree.undo_redo"]["no-error on unavailable redo"] = function()
  local tree_mod = require("voom.tree")
  local lines = {
    "# One",
    "",
    "one",
    "# Two",
    "",
    "two",
  }
  local body = make_scratch_buf(lines, "redo_unavailable.md")
  T["tree.undo_redo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.undo_redo"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(tree_win)

  local before = vim.api.nvim_buf_get_lines(body, 0, -1, false)
  MiniTest.expect.no_error(function()
    tree_mod.tree_redo(tree_buf)
  end)
  local after = vim.api.nvim_buf_get_lines(body, 0, -1, false)
  MiniTest.expect.equality(after, before)
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_win)
end

T["tree.undo_redo"]["display and editing remain siblings after << then >> on Display"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("readme_outline.md")
  local body = make_scratch_buf(lines, "readme_outline.md")
  T["tree.undo_redo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.undo_redo"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(tree_win)

  local display_lnum = find_tree_lnum_by_text(tree_buf, "Display")
  MiniTest.expect.equality(display_lnum ~= nil, true)

  vim.api.nvim_win_set_cursor(tree_win, { display_lnum, 0 })
  press("<<")
  press(">>")

  local outline = state.get_outline(body)
  local nav_lnum = find_tree_lnum_by_text(tree_buf, "Navigation")
  local fold_lnum = find_tree_lnum_by_text(tree_buf, "Folding")
  local disp_lnum = find_tree_lnum_by_text(tree_buf, "Display")
  local edit_lnum = find_tree_lnum_by_text(tree_buf, "Editing")

  MiniTest.expect.equality(nav_lnum ~= nil, true)
  MiniTest.expect.equality(fold_lnum ~= nil, true)
  MiniTest.expect.equality(disp_lnum ~= nil, true)
  MiniTest.expect.equality(edit_lnum ~= nil, true)

  local nav_level = outline.levels[nav_lnum]
  local fold_level = outline.levels[fold_lnum]
  local disp_level = outline.levels[disp_lnum]
  local edit_level = outline.levels[edit_lnum]

  MiniTest.expect.equality(fold_level, nav_level)
  MiniTest.expect.equality(disp_level, nav_level)
  MiniTest.expect.equality(edit_level, nav_level)
end

T["tree.undo_redo"]["move_up keeps Keymaps - body pane as sibling of Tree pane"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("readme_outline.md")
  local body = make_scratch_buf(lines, "readme_outline.md")
  T["tree.undo_redo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.undo_redo"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(tree_win)

  local kb_lnum = find_tree_lnum_by_text(tree_buf, "Keymaps — body pane")
  MiniTest.expect.equality(kb_lnum ~= nil, true)

  vim.api.nvim_win_set_cursor(tree_win, { kb_lnum, 0 })
  press("^^")

  local outline = state.get_outline(body)
  local tree_pane_lnum = find_tree_lnum_by_text(tree_buf, "Tree pane")
  local kb_new_lnum = find_tree_lnum_by_text(tree_buf, "Keymaps — body pane")

  MiniTest.expect.equality(tree_pane_lnum ~= nil, true)
  MiniTest.expect.equality(kb_new_lnum ~= nil, true)

  local tree_pane_level = outline.levels[tree_pane_lnum]
  local kb_level = outline.levels[kb_new_lnum]
  MiniTest.expect.equality(kb_level, tree_pane_level)
end

T["tree.undo_redo"]["move_down keeps Tree pane sibling between Keymaps tree/body sections"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("readme_outline.md")
  local body = make_scratch_buf(lines, "readme_outline.md")
  T["tree.undo_redo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.undo_redo"]._tree_buf = tree_buf
  local tree_win = find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(tree_win)

  local tree_pane_lnum = find_tree_lnum_by_text(tree_buf, "Tree pane")
  MiniTest.expect.equality(tree_pane_lnum ~= nil, true)

  vim.api.nvim_win_set_cursor(tree_win, { tree_pane_lnum, 0 })
  press("__")

  local outline = state.get_outline(body)
  local keymaps_tree_lnum = find_tree_lnum_by_text(tree_buf, "Keymaps — tree pane")
  local tree_pane_new_lnum = find_tree_lnum_by_text(tree_buf, "Tree pane")
  local keymaps_body_lnum = find_tree_lnum_by_text(tree_buf, "Keymaps — body pane")

  MiniTest.expect.equality(keymaps_tree_lnum ~= nil, true)
  MiniTest.expect.equality(tree_pane_new_lnum ~= nil, true)
  MiniTest.expect.equality(keymaps_body_lnum ~= nil, true)
  MiniTest.expect.equality(keymaps_tree_lnum < tree_pane_new_lnum, true)
  MiniTest.expect.equality(tree_pane_new_lnum < keymaps_body_lnum, true)

  local keymaps_tree_level = outline.levels[keymaps_tree_lnum]
  local tree_pane_level = outline.levels[tree_pane_new_lnum]
  local keymaps_body_level = outline.levels[keymaps_body_lnum]
  MiniTest.expect.equality(tree_pane_level, keymaps_tree_level)
  MiniTest.expect.equality(tree_pane_level, keymaps_body_level)
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
--   tree line 1  — level 1  (levels[1] = 1)
--   tree line 2  — level 2  (levels[2] = 2)
--   tree line 3  — level 2  (levels[3] = 2)
--   tree line 4  — level 1  (levels[4] = 1)
--   tree line 5  — level 2  (levels[5] = 2)

T["outline traversal"] = MiniTest.new_set()

T["outline traversal"]["find_parent_lnum: level-1 node returns nil (no parent)"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 1 is a level-1 heading; it has no parent.
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 1), nil)
  -- Tree line 4 is also level 1.
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 4), nil)
end

T["outline traversal"]["find_parent_lnum: level-2 node returns nearest level-1 ancestor"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 2 (level 2) → parent is tree line 1 (level 1).
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 2), 1)
  -- Tree line 3 (level 2) → parent is still tree line 1.
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 3), 1)
  -- Tree line 5 (level 2) → parent is tree line 4.
  MiniTest.expect.equality(tree.find_parent_lnum(levels, 5), 4)
end

T["outline traversal"]["find_first_child_lnum: node with child returns child lnum"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 1 (level 1) has a child at tree line 2 (level 2).
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 1), 2)
  -- Tree line 4 (level 1) has a child at tree line 5 (level 2).
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 4), 5)
end

T["outline traversal"]["find_first_child_lnum: leaf node returns nil"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 2 (level 2) is followed by tree line 3 also at level 2 — same
  -- level, not a child.
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 2), nil)
  -- Tree line 5 (level 2) is the last node — no child.
  MiniTest.expect.equality(tree.find_first_child_lnum(levels, 5), nil)
end

T["outline traversal"]["find_prev_sibling_lnum: first sibling returns nil"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 1 is the first level-1 sibling; no previous sibling.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 1), nil)
  -- Tree line 2 is the first level-2 child under tree line 1.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 2), nil)
end

T["outline traversal"]["find_prev_sibling_lnum: middle sibling returns previous"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 3 (level 2) — previous sibling is tree line 2.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 3), 2)
  -- Tree line 4 (level 1) — previous sibling is tree line 1.
  MiniTest.expect.equality(tree.find_prev_sibling_lnum(levels, 4), 1)
end

T["outline traversal"]["find_next_sibling_lnum: last sibling returns nil"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 4 is the last level-1 node.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 4), nil)
  -- Tree line 5 is the last level-2 node under tree line 4.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 5), nil)
end

T["outline traversal"]["find_next_sibling_lnum: middle sibling returns next"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 1 (level 1) → next sibling is tree line 4.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 1), 4)
  -- Tree line 2 (level 2) → next sibling is tree line 3.
  MiniTest.expect.equality(tree.find_next_sibling_lnum(levels, 2), 3)
end

T["outline traversal"]["find_first_sibling_lnum: already at first returns same"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  MiniTest.expect.equality(tree.find_first_sibling_lnum(levels, 1), 1)
end

T["outline traversal"]["find_last_sibling_lnum: already at last returns same"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  MiniTest.expect.equality(tree.find_last_sibling_lnum(levels, 4), 4)
end

T["outline traversal"]["find_first_sibling_lnum: middle sibling returns first"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 3 is a level-2 sibling; the first sibling is tree line 2.
  MiniTest.expect.equality(tree.find_first_sibling_lnum(levels, 3), 2)
  -- Tree line 4 (level 1) is second; first is tree line 1.
  MiniTest.expect.equality(tree.find_first_sibling_lnum(levels, 4), 1)
end

T["outline traversal"]["find_last_sibling_lnum: middle sibling returns last"] = function()
  local tree = require("voom.tree")
  local levels = { 1, 2, 2, 1, 2 }
  -- Tree line 2 is a level-2 sibling; the last sibling under the same parent
  -- is tree line 3.
  MiniTest.expect.equality(tree.find_last_sibling_lnum(levels, 2), 3)
  -- Tree line 1 (level 1); last level-1 sibling is tree line 4.
  MiniTest.expect.equality(tree.find_last_sibling_lnum(levels, 1), 4)
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

T["tree.build_unl"]["level-1 node returns just its heading"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.build_unl"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.build_unl"]._tree_buf = tree_buf

  local outline = state.get_outline(body)
  -- Tree line 1 = "# Project Overview" (level 1).
  local unl = tree_mod.build_unl(tree_buf, outline.levels, 1)
  MiniTest.expect.equality(unl, "Project Overview")
end

T["tree.build_unl"]["nested node returns full path"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.build_unl"]._body_buf = body

  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.build_unl"]._tree_buf = tree_buf

  local outline = state.get_outline(body)
  -- Tree line 3 = "### Requirements" (level 3, under Installation → Project Overview).
  -- Expected UNL: "Project Overview > Installation > Requirements"
  local unl = tree_mod.build_unl(tree_buf, outline.levels, 3)
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

T["tree.body_select"]["cursor on body line before first heading selects first heading (line 1)"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")

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
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end
  vim.api.nvim_win_set_cursor(body_win, { 1, 0 })
  vim.api.nvim_set_current_win(body_win)

  tree_mod.body_select(body)

  -- No bnode ≤ 1 (first heading is on line 3), so tree line 1 is selected.
  MiniTest.expect.equality(state.get_snLn(body), 1)
  -- Focus should remain in the body window.
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), body_win)
end

T["tree.body_select"]["cursor on heading line selects that heading's tree node"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.body_select"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.body_select"]._tree_buf = tree_buf

  -- sample.md line 1 is "# Project Overview" → bnodes[1] = 1 → tree line 1.
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end
  vim.api.nvim_win_set_cursor(body_win, { 1, 0 })
  vim.api.nvim_set_current_win(body_win)

  tree_mod.body_select(body)

  MiniTest.expect.equality(state.get_snLn(body), 1)
end

T["tree.body_select"]["cursor in body content between headings selects preceding heading"] = function()
  local tree_mod = require("voom.tree")
  local state = require("voom.state")
  local lines = load_fixture("sample.md")
  local body = make_scratch_buf(lines, "sample.md")
  T["tree.body_select"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree_mod.create(body, "markdown")
  T["tree.body_select"]._tree_buf = tree_buf

  -- sample.md line 3 is body content under "# Project Overview" (line 1).
  -- The preceding heading is still the first one → tree line 1.
  local body_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == body then
      body_win = win
      break
    end
  end
  vim.api.nvim_win_set_cursor(body_win, { 3, 0 })
  vim.api.nvim_set_current_win(body_win)

  tree_mod.body_select(body)

  -- Cursor is on line 3, bnodes[1]=1 ≤ 3, bnodes[2]=6 > 3 → selects tree line 1.
  MiniTest.expect.equality(state.get_snLn(body), 1)
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

T["tree_foldexpr"]["line 1 (level-1 heading) opens fold at depth 1"] = function()
  local tree = require("voom.tree")
  -- levels[1] = 1
  MiniTest.expect.equality(tree.tree_foldexpr(1), ">1")
end

T["tree_foldexpr"]["line 2 (level-2 heading) opens fold at depth 2"] = function()
  local tree = require("voom.tree")
  -- levels[2] = 2
  MiniTest.expect.equality(tree.tree_foldexpr(2), ">2")
end

T["tree_foldexpr"]["line 3 (level-3 heading) opens fold at depth 3"] = function()
  local tree = require("voom.tree")
  -- levels[3] = 3
  MiniTest.expect.equality(tree.tree_foldexpr(3), ">3")
end

T["tree_foldexpr"]["line 4 (level-2 heading) opens fold at depth 2"] = function()
  local tree = require("voom.tree")
  -- levels[4] = 2
  MiniTest.expect.equality(tree.tree_foldexpr(4), ">2")
end

T["tree_foldexpr"]["line 5 returns 0 (beyond outline)"] = function()
  local tree = require("voom.tree")
  -- levels[5] = nil (outline only has 4 headings)
  MiniTest.expect.equality(tree.tree_foldexpr(5), "0")
end

T["tree_foldexpr"]["returns '0' when no state is registered"] = function()
  local state = require("voom.state")
  local tree = require("voom.tree")
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
