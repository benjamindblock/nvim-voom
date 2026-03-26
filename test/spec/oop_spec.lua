local H = dofile("test/helpers.lua")

local T = MiniTest.new_set()

-- ==============================================================================
-- Module loading
-- ==============================================================================

T["oop loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom.oop")
  end)
end

-- ==============================================================================
-- get_node_range
-- ==============================================================================

T["get_node_range"] = MiniTest.new_set()

T["get_node_range"]["first heading returns range up to next same-level heading"] = function()
  local oop = require("voom.oop")
  -- bnodes[1]=1 (H1 Heading One), bnodes[2]=5 (H2 Sub A), bnodes[3]=9 (H2 Sub B), bnodes[4]=13 (H1)
  -- tlnum=1 is Heading One (level 1).  Subtree: levels[2]=2>1 ✓, levels[3]=2>1 ✓,
  -- levels[4]=1 not >1 → stop.  bln2 = bnodes[4]-1 = 12.
  local bnodes = { 1, 5, 9, 13 }
  local levels = { 1, 2, 2, 1 }
  local bln1, bln2 = oop.get_node_range(bnodes, levels, 1, 15)
  MiniTest.expect.equality(bln1, 1)
  MiniTest.expect.equality(bln2, 12)
end

T["get_node_range"]["leaf node with successor"] = function()
  local oop = require("voom.oop")
  -- bnodes[1]=1 (H1), bnodes[2]=5 (H2 Sub A), bnodes[3]=9 (H2 Sub B), bnodes[4]=13 (H1)
  local bnodes = { 1, 5, 9, 13 }
  local levels = { 1, 2, 2, 1 }
  -- tlnum=2 is bnodes[2] (Sub A at level 2).  Next at <=2 is bnodes[3].
  local bln1, bln2 = oop.get_node_range(bnodes, levels, 2, 15)
  MiniTest.expect.equality(bln1, 5)
  MiniTest.expect.equality(bln2, 8)
end

T["get_node_range"]["node with children"] = function()
  local oop = require("voom.oop")
  -- H1 at 1, H2 at 5, H3 at 9, H2 at 13
  local bnodes = { 1, 5, 9, 13 }
  local levels = { 1, 2, 3, 2 }
  -- tlnum=2 is bnodes[2] (level 2).  Subtree includes bnodes[3] (level 3).
  -- Ends before bnodes[4] (level 2).
  local bln1, bln2 = oop.get_node_range(bnodes, levels, 2, 20)
  MiniTest.expect.equality(bln1, 5)
  MiniTest.expect.equality(bln2, 12)
end

T["get_node_range"]["last node extends to end of file"] = function()
  local oop = require("voom.oop")
  local bnodes = { 1, 5, 9 }
  local levels = { 1, 2, 2 }
  -- tlnum=3 is bnodes[3] (last node).  No successor → range extends to EOF.
  local bln1, bln2 = oop.get_node_range(bnodes, levels, 3, 20)
  MiniTest.expect.equality(bln1, 9)
  MiniTest.expect.equality(bln2, 20)
end

-- ==============================================================================
-- count_subnodes
-- ==============================================================================

T["count_subnodes"] = MiniTest.new_set()

T["count_subnodes"]["first heading counts direct subtree"] = function()
  local oop = require("voom.oop")
  -- levels={1,2,2,1}: tlnum=1 is H1.  Subtree: levels[2]=2>1 ✓, levels[3]=2>1 ✓,
  -- levels[4]=1 not >1 → stop.  Returns 2.
  local levels = { 1, 2, 2, 1 }
  MiniTest.expect.equality(oop.count_subnodes(levels, 1), 2)
end

T["count_subnodes"]["leaf has zero subnodes"] = function()
  local oop = require("voom.oop")
  local levels = { 1, 2, 2, 1 }
  -- tlnum=2 is levels[2] (Sub A, level 2), next is levels[3]=2 = sibling, not child.
  MiniTest.expect.equality(oop.count_subnodes(levels, 2), 0)
end

T["count_subnodes"]["node with children"] = function()
  local oop = require("voom.oop")
  -- H1 at idx 1, H2 at idx 2, H3 at idx 3, H2 at idx 4
  local levels = { 1, 2, 3, 2 }
  -- tlnum=2 is levels[2] (level 2). It has one child at level 3.
  MiniTest.expect.equality(oop.count_subnodes(levels, 2), 1)
end

T["count_subnodes"]["last node has zero subnodes"] = function()
  local oop = require("voom.oop")
  local levels = { 1, 2, 2 }
  -- tlnum=3 is levels[3] (last node, level 2).  No successor → 0 subnodes.
  MiniTest.expect.equality(oop.count_subnodes(levels, 3), 0)
end

T["count_subnodes"]["deeply nested subtree"] = function()
  local oop = require("voom.oop")
  -- H1, H2, H3, H4, H2
  local levels = { 1, 2, 3, 4, 2 }
  -- tlnum=2 is levels[2] (level 2). Subtree: H3(3), H4(4) = 2 subnodes.
  MiniTest.expect.equality(oop.count_subnodes(levels, 2), 2)
end

-- ==============================================================================
-- clipboard
-- ==============================================================================

T["clipboard"] = MiniTest.new_set()

T["clipboard"]["initially empty"] = function()
  local oop = require("voom.oop")
  oop.clear_clipboard()
  local cb = oop.get_clipboard()
  MiniTest.expect.equality(cb.body_lines, nil)
  MiniTest.expect.equality(cb.levels, nil)
end

-- ==============================================================================
-- edit_node
-- ==============================================================================

T["edit_node"] = MiniTest.new_set({
  hooks = H.clean_hooks(),
})

T["edit_node"]["i jumps to heading line in body"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "edit_i_test.md")

  -- Need to display the buffer in a window for tree creation.
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  -- Navigate tree to "Sub A" (tree line 2: H1=1, SubA=2).
  local tree_win = H.find_win_for_buf(tree_buf)
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.edit_node(tree_buf, "i")

  -- Should now be in body window, at line 5 (## Sub A).
  local cur_buf = vim.api.nvim_get_current_buf()
  MiniTest.expect.equality(cur_buf, buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(cursor[1], 5)
end

T["edit_node"]["I jumps to last line of heading region"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "edit_I_test.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    -- "Sub A" is tree line 2.  Its region ends at line 8 (before "## Sub B" at line 9).
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.edit_node(tree_buf, "I")

  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(cursor[1], 8)
end

T["edit_node"]["I on last heading jumps to end of buffer"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "edit_I_last.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- "Heading Two" is tree line 4 (H1=1, SubA=2, SubB=3, H2=4).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 4, 0 })
  end

  oop.edit_node(tree_buf, "I")
  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(cursor[1], #lines)
end

T["edit_node"]["i on first heading jumps to body line 1"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "edit_first.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Tree line 1 is now "Heading One" (the first H1); no root node exists.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  oop.edit_node(tree_buf, "i")
  -- Should jump to body window at line 1 ("# Heading One").
  local cur_buf = vim.api.nvim_get_current_buf()
  MiniTest.expect.equality(cur_buf, buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(cursor[1], 1)
end

-- ==============================================================================
-- insert_node
-- ==============================================================================

T["insert_node"] = MiniTest.new_set({
  hooks = H.clean_hooks(),
})

T["insert_node"]["aa inserts sibling at same level"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "insert_aa.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Position on "Sub A" (tree line 2, level 2).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.insert_node(tree_buf, false)

  -- Verify a new heading was inserted at level 2.
  local body_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false
  for _, l in ipairs(body_lines) do
    if l:match("^## NewHeadline") then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

T["insert_node"]["AA inserts child at level+1"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "insert_AA.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Position on "Heading One" (tree line 1, level 1).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  oop.insert_node(tree_buf, true)

  -- Verify a new heading was inserted at level 2 (child of level 1).
  local body_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false
  for _, l in ipairs(body_lines) do
    if l:match("^## NewHeadline") then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

T["insert_node"]["moves focus to body, selects new node, and syncs changedtick"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf({ "# One", "", "## Two" }, "insert_focus.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })

  local before_tick = state.get_changedtick(buf)
  oop.insert_node(tree_buf, false)

  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), buf)
  MiniTest.expect.equality(cursor[1], 5)
  MiniTest.expect.equality(cursor[2], 3)
  MiniTest.expect.equality(state.get_snLn(buf), 3)
  MiniTest.expect.equality(state.get_changedtick(buf), vim.api.nvim_buf_get_changedtick(buf))
  MiniTest.expect.equality(state.get_changedtick(buf) ~= before_tick, true)
end

-- ==============================================================================
-- copy_node
-- ==============================================================================

T["copy_node"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("voom.oop").clear_clipboard()
    end,
    post_case = H.cleanup_registered_bodies,
  },
})

T["copy_node"]["stores body lines in clipboard"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "copy_test.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Copy "Sub A" (tree line 2).  Its body range is lines 5-8.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.copy_node(tree_buf)

  local cb = oop.get_clipboard()
  MiniTest.expect.equality(cb.body_lines ~= nil, true)
  MiniTest.expect.equality(cb.body_lines[1], "## Sub A")
  MiniTest.expect.equality(#cb.levels, 1)
  MiniTest.expect.equality(cb.levels[1], 2)
end

T["copy_node"]["does not modify body buffer"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "copy_nomod.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  oop.copy_node(tree_buf)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  MiniTest.expect.equality(#before, #after)
  for i = 1, #before do
    MiniTest.expect.equality(before[i], after[i])
  end
end

T["copy_node"]["copies subtree with children"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "copy_subtree.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Copy "Heading One" (tree line 1, has children Sub A and Sub B).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  oop.copy_node(tree_buf)

  local cb = oop.get_clipboard()
  -- Should have 3 nodes: H1, SubA, SubB
  MiniTest.expect.equality(#cb.levels, 3)
  MiniTest.expect.equality(cb.levels[1], 1)
  MiniTest.expect.equality(cb.levels[2], 2)
  MiniTest.expect.equality(cb.levels[3], 2)
  -- Body lines should span from line 1 to line 12 (before "# Heading Two").
  MiniTest.expect.equality(cb.body_lines[1], "# Heading One")
end

-- ==============================================================================
-- cut_node
-- ==============================================================================

T["cut_node"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("voom.oop").clear_clipboard()
    end,
    post_case = H.cleanup_registered_bodies,
  },
})

T["cut_node"]["removes node from body and stores in clipboard"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local original_count = #lines
  local buf = H.make_scratch_buf(lines, "cut_test.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Cut "Sub A" (tree line 2).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.cut_node(tree_buf)

  -- Clipboard should have the cut content.
  local cb = oop.get_clipboard()
  MiniTest.expect.equality(cb.body_lines[1], "## Sub A")

  -- Body should have fewer lines.
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  MiniTest.expect.equality(#after < original_count, true)

  -- "## Sub A" should no longer be in the body.
  local found = false
  for _, l in ipairs(after) do
    if l == "## Sub A" then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, false)
end

T["cut_node"]["cutting first heading removes it from body"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  -- Tree line 1 is now "Heading One" (a real heading, not a root node).
  -- Cutting it should remove it and its children from the body.
  local lines = H.simple_doc()
  local original_count = #lines
  local buf = H.make_scratch_buf(lines, "cut_first.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  oop.cut_node(tree_buf)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Heading One and its subtree (Sub A, Sub B) should be gone; body is smaller.
  MiniTest.expect.equality(#after < original_count, true)
  local found = false
  for _, l in ipairs(after) do
    if l == "# Heading One" then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, false)
end

T["cut_node"]["cuts subtree including children"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "cut_subtree.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Cut "Heading One" (tree line 1) — includes Sub A and Sub B.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  oop.cut_node(tree_buf)

  local cb = oop.get_clipboard()
  MiniTest.expect.equality(#cb.levels, 3) -- H1, SubA, SubB

  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- "# Heading One" should be gone.
  local found = false
  for _, l in ipairs(after) do
    if l == "# Heading One" then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, false)
end

T["cut_node"]["keeps focus in tree, selects previous node, and syncs changedtick"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf({
    "# One",
    "",
    "## Two",
    "",
    "## Three",
    "",
    "# Four",
  }, "cut_focus.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })

  local before_tick = state.get_changedtick(buf)
  oop.cut_node(tree_buf)

  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), tree_buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 1)
  MiniTest.expect.equality(state.get_snLn(buf), 1)
  MiniTest.expect.equality(state.get_changedtick(buf), vim.api.nvim_buf_get_changedtick(buf))
  MiniTest.expect.equality(state.get_changedtick(buf) ~= before_tick, true)
end

-- ==============================================================================
-- paste_node
-- ==============================================================================

T["paste_node"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("voom.oop").clear_clipboard()
    end,
    post_case = H.cleanup_registered_bodies,
  },
})

T["paste_node"]["no-op with empty clipboard"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "paste_empty.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  oop.paste_node(tree_buf)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  MiniTest.expect.equality(#before, #after)
end

T["paste_node"]["empty clipboard emits warning message"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local buf = H.make_scratch_buf(H.simple_doc(), "paste_empty_warn.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local echoes = H.with_captured_echo(function()
    oop.paste_node(tree_buf)
  end)

  MiniTest.expect.equality(#echoes, 1)
  MiniTest.expect.equality(echoes[1].chunks[1][1], "VOoM (paste): clipboard is empty")
  MiniTest.expect.equality(echoes[1].chunks[1][2], "WarningMsg")
end

T["paste_node"]["cut then paste round-trip preserves content"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "paste_roundtrip.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Cut "Sub A" (tree line 2).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.cut_node(tree_buf)

  -- Now paste after "Heading Two" (which is now at a different tree line
  -- after the cut).  Find it.
  -- After cutting Sub A, the tree should have: H1, SubB, H2
  -- Paste after H2 (last node).
  local new_outline = require("voom.state").get_outline(buf)
  local last_tlnum = #new_outline.bnodes
  if tree_win and vim.api.nvim_win_is_valid(tree_win) then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { last_tlnum, 0 })
  end

  oop.paste_node(tree_buf)

  -- Verify "## Sub A" is back in the body.
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false
  for _, l in ipairs(after) do
    if l:match("Sub A") then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

T["paste_node"]["keeps focus in tree, selects first pasted node, and syncs changedtick"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf(H.simple_doc(), "paste_focus.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  oop.copy_node(tree_buf)

  vim.api.nvim_win_set_cursor(tree_win, { 4, 0 })
  local before_tick = state.get_changedtick(buf)
  oop.paste_node(tree_buf)

  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), tree_buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 5)
  MiniTest.expect.equality(state.get_snLn(buf), 5)
  MiniTest.expect.equality(state.get_changedtick(buf), vim.api.nvim_buf_get_changedtick(buf))
  MiniTest.expect.equality(state.get_changedtick(buf) ~= before_tick, true)
end

T["paste_node"]["invalid clipboard emits error and leaves body unchanged"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local buf = H.make_scratch_buf(H.simple_doc(), "paste_invalid.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local clipboard = oop.get_clipboard()
  clipboard.body_lines = { "not a heading", "", "still not a heading" }
  clipboard.levels = { 1 }

  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local echoes = H.with_captured_echo(function()
    oop.paste_node(tree_buf)
  end)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  MiniTest.expect.equality(after, before)
  MiniTest.expect.equality(#echoes, 1)
  MiniTest.expect.equality(
    echoes[1].chunks[1][1],
    "VOoM (paste): invalid clipboard — first line is not a headline"
  )
  MiniTest.expect.equality(echoes[1].chunks[1][2], "ErrorMsg")
end

-- ==============================================================================
-- promote / demote
-- ==============================================================================

T["promote"] = MiniTest.new_set({
  hooks = H.clean_hooks(),
})

T["promote"]["decreases heading level by 1"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "promote_test.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Promote "Sub A" (tree line 2, level 2 → level 1).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.promote(tree_buf)

  -- Verify the heading changed from "## Sub A" to "# Sub A".
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false
  for _, l in ipairs(after) do
    if l == "# Sub A" then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

T["promote"]["no-op when already at level 1"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "promote_noop.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- "Heading One" is tree line 1, level 1.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  oop.promote(tree_buf)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Should be unchanged.
  MiniTest.expect.equality(#before, #after)
  MiniTest.expect.equality(before[1], after[1])
end

T["promote"]["top-level no-op emits warning message"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local buf = H.make_scratch_buf(H.simple_doc(), "promote_warn.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })

  local echoes = H.with_captured_echo(function()
    oop.promote(tree_buf)
  end)

  MiniTest.expect.equality(#echoes, 1)
  MiniTest.expect.equality(echoes[1].chunks[1][1], "VOoM: cannot promote — already at top level")
  MiniTest.expect.equality(echoes[1].chunks[1][2], "WarningMsg")
end

T["demote"] = MiniTest.new_set({
  hooks = H.clean_hooks(),
})

T["demote"]["increases heading level by 1"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "demote_test.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Demote "Heading One" (tree line 1, level 1 → level 2).
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  oop.demote(tree_buf)

  -- Verify the heading changed to "## Heading One".
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false
  for _, l in ipairs(after) do
    if l == "## Heading One" then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

T["demote"]["changes only current heading level in normal mode"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "demote_sub.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Demote "Heading One" (level 1) with children Sub A, Sub B (level 2).
  -- In normal mode only the current heading should change.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  end

  oop.demote(tree_buf)

  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Sub A should remain level 2.
  local found_sub_a = false
  local found_sub_a_too_deep = false
  for _, l in ipairs(after) do
    if l == "## Sub A" then
      found_sub_a = true
    end
    if l == "### Sub A" then
      found_sub_a_too_deep = true
    end
  end
  MiniTest.expect.equality(found_sub_a, true)
  MiniTest.expect.equality(found_sub_a_too_deep, false)
end

T["demote"]["keeps focus in tree, preserves selection, and syncs changedtick"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf(H.simple_doc(), "demote_focus.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })

  local before_tick = state.get_changedtick(buf)
  oop.demote(tree_buf)

  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), tree_buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 1)
  MiniTest.expect.equality(state.get_snLn(buf), 1)
  MiniTest.expect.equality(state.get_changedtick(buf), vim.api.nvim_buf_get_changedtick(buf))
  MiniTest.expect.equality(state.get_changedtick(buf) ~= before_tick, true)
end

T["demote"]["child no-op emits warning message"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local buf = H.make_scratch_buf({
    "# Parent",
    "",
    "## Child",
    "",
    "# Sibling",
  }, "demote_warn.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })

  local echoes = H.with_captured_echo(function()
    oop.demote(tree_buf)
  end)

  MiniTest.expect.equality(#echoes, 1)
  MiniTest.expect.equality(
    echoes[1].chunks[1][1],
    "VOoM: cannot demote — already a child of previous node"
  )
  MiniTest.expect.equality(echoes[1].chunks[1][2], "WarningMsg")
end

-- ==============================================================================
-- move_up / move_down
-- ==============================================================================

T["move_up"] = MiniTest.new_set({
  hooks = H.clean_hooks(),
})

T["move_up"]["swaps node with previous sibling"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "moveup_test.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Move "Sub B" (tree line 3) up.  It should swap with "Sub A".
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })
  end

  oop.move_up(tree_buf)

  -- After move, "Sub B" should appear before "Sub A" in the body.
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sub_b_line, sub_a_line
  for i, l in ipairs(after) do
    if l == "## Sub B" then
      sub_b_line = i
    end
    if l == "## Sub A" then
      sub_a_line = i
    end
  end
  MiniTest.expect.equality(sub_b_line ~= nil, true)
  MiniTest.expect.equality(sub_a_line ~= nil, true)
  MiniTest.expect.equality(sub_b_line < sub_a_line, true)
end

T["move_up"]["no-op on first sibling"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "moveup_first.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- "Sub A" (tree line 2) is the first child of H1 — no previous sibling.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  oop.move_up(tree_buf)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  MiniTest.expect.equality(#before, #after)
  for i = 1, #before do
    MiniTest.expect.equality(before[i], after[i])
  end
end

T["move_up"]["keeps sibling level when previous sibling has children"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local lines = H.load_fixture("readme_outline.md")
  local buf = H.make_scratch_buf(lines, "moveup_prev_with_children.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local function find_lnum(text)
    local tree_lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
    for i, line in ipairs(tree_lines) do
      if line:find(text, 1, true) then
        return i
      end
    end
    return nil
  end

  local body_keymaps_lnum = find_lnum("Keymaps — body pane")
  MiniTest.expect.equality(body_keymaps_lnum ~= nil, true)

  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { body_keymaps_lnum, 0 })
  end

  oop.move_up(tree_buf)

  local outline = state.get_outline(buf)
  local tree_pane_lnum2 = find_lnum("Tree pane")
  local body_keymaps_lnum2 = find_lnum("Keymaps — body pane")
  local tree_pane_level = outline.levels[tree_pane_lnum2]
  local body_keymaps_level = outline.levels[body_keymaps_lnum2]

  MiniTest.expect.equality(body_keymaps_level, tree_pane_level)
end

T["move_up"]["keeps focus in tree, selects moved node, and syncs changedtick"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf(H.simple_doc(), "moveup_focus.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })

  local before_tick = state.get_changedtick(buf)
  oop.move_up(tree_buf)

  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), tree_buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 2)
  MiniTest.expect.equality(state.get_snLn(buf), 2)
  MiniTest.expect.equality(state.get_changedtick(buf), vim.api.nvim_buf_get_changedtick(buf))
  MiniTest.expect.equality(state.get_changedtick(buf) ~= before_tick, true)
end

T["move_down"] = MiniTest.new_set({
  hooks = H.clean_hooks(),
})

T["move_down"]["swaps node with next sibling"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "movedn_test.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- Move "Sub A" (tree line 2) down.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })
  end

  oop.move_down(tree_buf)

  -- After move, "Sub A" should appear after "Sub B" in the body.
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sub_a_line, sub_b_line
  for i, l in ipairs(after) do
    if l == "## Sub A" then
      sub_a_line = i
    end
    if l == "## Sub B" then
      sub_b_line = i
    end
  end
  MiniTest.expect.equality(sub_a_line ~= nil, true)
  MiniTest.expect.equality(sub_b_line ~= nil, true)
  MiniTest.expect.equality(sub_b_line < sub_a_line, true)
end

T["move_down"]["no-op on last sibling"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")

  local lines = H.simple_doc()
  local buf = H.make_scratch_buf(lines, "movedn_last.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)

  -- "Sub B" (tree line 3) is the last child of H1.
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })
  end

  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  oop.move_down(tree_buf)
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  MiniTest.expect.equality(#before, #after)
  for i = 1, #before do
    MiniTest.expect.equality(before[i], after[i])
  end
end

T["move_down"]["keeps moved node as sibling when next sibling has children"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local lines = H.load_fixture("readme_outline.md")
  local buf = H.make_scratch_buf(lines, "movedn_next_sib_children.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")

  local tree_win = H.find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  local function find_lnum(text)
    local tree_lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
    for i, line in ipairs(tree_lines) do
      if line:find(text, 1, true) then
        return i
      end
    end
    return nil
  end

  local tree_pane_lnum = find_lnum("Tree pane")
  MiniTest.expect.equality(tree_pane_lnum ~= nil, true)
  if tree_win then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { tree_pane_lnum, 0 })
  end

  oop.move_down(tree_buf)

  local outline = state.get_outline(buf)
  local keymaps_tree_lnum = find_lnum("Keymaps — tree pane")
  local tree_pane_new_lnum = find_lnum("Tree pane")
  local keymaps_body_lnum = find_lnum("Keymaps — body pane")
  MiniTest.expect.equality(keymaps_tree_lnum ~= nil, true)
  MiniTest.expect.equality(tree_pane_new_lnum ~= nil, true)
  MiniTest.expect.equality(keymaps_body_lnum ~= nil, true)

  local keymaps_tree_level = outline.levels[keymaps_tree_lnum]
  local tree_pane_level = outline.levels[tree_pane_new_lnum]
  local keymaps_body_level = outline.levels[keymaps_body_lnum]

  MiniTest.expect.equality(tree_pane_level, keymaps_tree_level)
  MiniTest.expect.equality(tree_pane_level, keymaps_body_level)
end

T["move_down"]["keeps focus in tree, selects moved node, and syncs changedtick"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf(H.simple_doc(), "movedn_focus.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })

  local before_tick = state.get_changedtick(buf)
  oop.move_down(tree_buf)

  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), tree_buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 3)
  MiniTest.expect.equality(state.get_snLn(buf), 3)
  MiniTest.expect.equality(state.get_changedtick(buf), vim.api.nvim_buf_get_changedtick(buf))
  MiniTest.expect.equality(state.get_changedtick(buf) ~= before_tick, true)
end

-- ==============================================================================
-- sort
-- ==============================================================================

T["sort"] = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.cleanup_registered_bodies()
    end,
  },
})

T["sort"]["sorts root-level siblings alphabetically and preserves current selection"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf({
    "# B",
    "",
    "body b",
    "# A",
    "",
    "body a",
    "# C",
    "",
    "body c",
  }, "sort_root.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 2, 0 })

  local before_tick = state.get_changedtick(buf)
  oop.sort(buf, "")

  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), tree_buf)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    "# A",
    "",
    "body a",
    "# B",
    "",
    "body b",
    "# C",
    "",
    "body c",
  })
  MiniTest.expect.equality(state.get_changedtick(buf), vim.api.nvim_buf_get_changedtick(buf))
  MiniTest.expect.equality(state.get_changedtick(buf) ~= before_tick, true)
  MiniTest.expect.equality(state.get_snLn(buf), 1)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 1)
end

T["sort"]["sorts sibling group under the current parent and keeps ancestors intact"] = function()
  local tree_mod = require("voom.tree")
  local oop = require("voom.oop")
  local state = require("voom.state")

  local buf = H.make_scratch_buf({
    "# Root",
    "",
    "## B",
    "",
    "body b",
    "## A",
    "",
    "body a",
    "## C",
    "",
    "body c",
    "# Tail",
  }, "sort_nested.md")
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  vim.api.nvim_set_current_win(tree_win)
  vim.api.nvim_win_set_cursor(tree_win, { 3, 0 })

  oop.sort(tree_buf, "")

  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    "# Root",
    "",
    "## A",
    "",
    "body a",
    "## B",
    "",
    "body b",
    "## C",
    "",
    "body c",
    "# Tail",
  })

  local outline = state.get_outline(buf)
  MiniTest.expect.equality(outline.levels, { 1, 2, 2, 2, 1 })
  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), tree_buf)
  MiniTest.expect.equality(state.get_snLn(buf), 2)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(tree_win)[1], 2)
end

-- ==============================================================================
-- state.outline_state
-- ==============================================================================

T["outline_state"] = MiniTest.new_set()

T["outline_state"]["stored on register"] = function()
  local state = require("voom.state")
  local markdown = require("voom.modes.markdown")

  local lines = H.simple_doc()
  local outline = markdown.make_outline(lines, "test.md")

  local body_buf = H.make_scratch_buf(lines, "os_test.md")
  local tree_buf = vim.api.nvim_create_buf(false, true)

  state.register(body_buf, tree_buf, "markdown", outline)

  local os = state.get_outline_state(body_buf)
  MiniTest.expect.equality(os ~= nil, true)
  MiniTest.expect.equality(os.use_hash, true) -- first heading is hash style
  MiniTest.expect.equality(os.use_close_hash, false)

  state.unregister(body_buf)
  H.del_buf(body_buf)
  H.del_buf(tree_buf)
end

T["outline_state"]["updated on set_outline"] = function()
  local state = require("voom.state")
  local markdown = require("voom.modes.markdown")

  local lines = H.simple_doc()
  local outline = markdown.make_outline(lines, "test.md")

  local body_buf = H.make_scratch_buf(lines, "os_update.md")
  local tree_buf = vim.api.nvim_create_buf(false, true)

  state.register(body_buf, tree_buf, "markdown", outline)

  -- Simulate a rebuild with different style.
  local new_outline = {
    bnodes = outline.bnodes,
    levels = outline.levels,
    use_hash = false,
    use_close_hash = true,
  }
  state.set_outline(body_buf, new_outline)

  local os = state.get_outline_state(body_buf)
  MiniTest.expect.equality(os.use_hash, false)
  MiniTest.expect.equality(os.use_close_hash, true)

  state.unregister(body_buf)
  H.del_buf(body_buf)
  H.del_buf(tree_buf)
end

return T
