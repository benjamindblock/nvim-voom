local H = dofile("test/helpers.lua")

local T = MiniTest.new_set()

-- ==============================================================================
-- Shared helpers
-- ==============================================================================
--
-- Both autocommands (FileType for auto_open, BufWinLeave for auto_close) defer
-- their real work via `vim.schedule` so that voom.init / voom.close don't
-- re-enter buffer setup mid-event.  MiniTest itself drives case execution
-- through `vim.schedule`, which makes a `vim.wait` inside a test body deadlock
-- — the inner wait pumps the event loop and can advance MiniTest's own
-- scheduler out of order, leaving later cases perpetually "Executing".
--
-- The workaround: temporarily replace `vim.schedule` with a synchronous shim
-- while we trigger the event, then restore it.  Production behaviour is
-- unchanged; only the test's call to `vim.schedule` becomes immediate.

local function with_sync_schedule(fn)
  -- Collect scheduled callbacks during `fn` and drain them once fn
  -- returns.  Running them inline (immediately inside `vim.schedule`)
  -- works for auto_open but breaks auto_close: nvim_buf_delete on the
  -- tree buffer inside its own BufWinLeave dispatch raises E937
  -- ("Attempt to delete a buffer that is in use").  By draining after
  -- fn returns, the event dispatch has already completed and the
  -- buffer is no longer in use, matching production's next-tick
  -- behaviour without the MiniTest-vs-vim.wait deadlock.
  local orig = vim.schedule
  local queue = {}
  vim.schedule = function(f)
    table.insert(queue, f)
  end
  local ok, err = pcall(fn)
  vim.schedule = orig
  for _, f in ipairs(queue) do
    f()
  end
  if not ok then
    error(err)
  end
end

--- Set `body_buf`'s filetype, then display it in the current window.
--- The filetype is set first so that the BufWinEnter-driven auto_open
--- handler sees the resolved mode when it reads vim.bo[args.buf].filetype.
local function open_body_in_window(body_buf, ft)
  vim.bo[body_buf].filetype = ft
  with_sync_schedule(function()
    vim.api.nvim_set_current_buf(body_buf)
  end)
end

--- Trigger `BufWinLeave` on `buf` by focusing its window and swapping the
--- window's buffer to a throwaway scratch.  Works for either the body or the
--- tree buffer, so tests can exercise `auto_close` from either direction.
--- Matches the real-world scenarios the flag targets (fzf replacing the
--- buffer, netrw replacing it with a directory listing) more closely than
--- `:bwipeout`, and — because `buf` stays alive — avoids the
--- `E855: Autocommands caused command to abort` warning that a sync
--- tree-delete inside a wipe would trigger.
local function trigger_bufwinleave(buf)
  local win = H.find_win_for_buf(buf)
  assert(win, "trigger_bufwinleave: no window shows buffer " .. tostring(buf))
  with_sync_schedule(function()
    vim.api.nvim_set_current_win(win)
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(scratch)
  end)
end

--- Build a scratch buffer from a fixture (by content), without a name.
--- Setting a buffer name collides (E95) across cases that reuse the same
--- fixture file, so every body created here is anonymous.
local function make_body_from_fixture(fixture)
  return H.make_scratch_buf(H.load_fixture(fixture))
end

--- Post-case cleanup: reset config to defaults (so auto_open / auto_close
--- flags don't leak across cases) and delete any bodies registered in state.
local function reset_state()
  require("voom").setup({})
  H.cleanup_registered_bodies()
end

-- ==============================================================================
-- M.close()
-- ==============================================================================

T["close"] = MiniTest.new_set({ hooks = { post_case = reset_state } })

T["close"]["no-op when body has no active tree"] = function()
  local voom = require("voom")

  local body = H.make_scratch_buf({ "# Alpha" }, "close_notree.md")
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"

  MiniTest.expect.no_error(function()
    voom.close(body)
  end)

  H.del_buf(body)
end

T["close"]["deletes tree buffer and clears state"] = function()
  local voom = require("voom")
  local state = require("voom.state")
  local tree = require("voom.tree")

  local body = H.make_scratch_buf({ "# Alpha", "## Beta" }, "close_active.md")
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  local tree_buf = tree.create(body, "markdown")
  MiniTest.expect.equality(state.is_body(body), true)

  voom.close(body)

  MiniTest.expect.equality(state.get_tree(body), nil)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
end

T["close"]["closes associated tree when called from a tree window"] = function()
  local voom = require("voom")
  local state = require("voom.state")
  local tree = require("voom.tree")

  local body = H.make_scratch_buf({ "# Alpha" }, "close_from_tree.md")
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  local tree_buf = tree.create(body, "markdown")

  -- Focus the tree pane; voom.close() with no args should resolve back to
  -- the correct body via resolve_body_buf().
  local tree_win = H.find_win_for_buf(tree_buf)
  vim.api.nvim_set_current_win(tree_win)

  voom.close()

  MiniTest.expect.equality(state.get_tree(body), nil)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
end

-- ==============================================================================
-- auto_open autocommand
-- ==============================================================================

T["auto_open"] = MiniTest.new_set({ hooks = { post_case = reset_state } })

T["auto_open"]["default (false) does not open tree"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  voom.setup({})
  local body = make_body_from_fixture("sample.md")
  open_body_in_window(body, "markdown")

  MiniTest.expect.equality(state.is_body(body), false)
end

T["auto_open"]["true opens tree for markdown"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  voom.setup({ auto_open = true })
  local body = make_body_from_fixture("sample.md")
  open_body_in_window(body, "markdown")

  MiniTest.expect.equality(state.is_body(body), true)
  local tree_buf = state.get_tree(body)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), true)
end

T["auto_open"]["table form only opens listed modes"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  voom.setup({ auto_open = { "markdown" } })

  -- Markdown: should open.
  local md_body = make_body_from_fixture("sample.md")
  open_body_in_window(md_body, "markdown")
  MiniTest.expect.equality(state.is_body(md_body), true)

  -- Python: should not.
  local py_body = make_body_from_fixture("sample.py")
  open_body_in_window(py_body, "python")
  MiniTest.expect.equality(state.is_body(py_body), false)
end

T["auto_open"]["unsupported filetype is silent"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  voom.setup({ auto_open = true })

  -- "yaml" isn't in the mode registry; no tree should be created, and no
  -- notification should be emitted (the auto-open path deliberately bypasses
  -- voom.init's "unsupported mode" error).
  local body = H.make_scratch_buf({ "key: value" })
  local notifications = H.with_captured_notify(function()
    open_body_in_window(body, "yaml")
  end)

  MiniTest.expect.equality(state.is_body(body), false)
  MiniTest.expect.equality(#notifications, 0)
  H.del_buf(body)
end

T["auto_open"]["re-opens tree when body returns to its window"] = function()
  -- Regression for the netrw round-trip bug: with `FileType`-based auto_open,
  -- selecting a markdown file from netrw (which re-displays the already-loaded
  -- buffer) did not fire FileType and the tree stayed closed.  Moving auto_open
  -- to BufWinEnter makes the tree reopen on every display, which is the
  -- behaviour users expect from a pane that mirrors the active buffer.
  local voom = require("voom")
  local state = require("voom.state")

  voom.setup({ auto_open = true, auto_close = true })
  local body = make_body_from_fixture("sample.md")

  -- Step 1: first display — tree opens.
  open_body_in_window(body, "markdown")
  MiniTest.expect.equality(state.is_body(body), true)

  -- Step 2: body leaves its window (simulates pressing `-` to netrw) —
  -- auto_close fires, tree goes away.
  trigger_bufwinleave(body)
  MiniTest.expect.equality(state.is_body(body), false)

  -- Step 3: body re-enters its window (simulates selecting the same file
  -- back from netrw).  Filetype is still "markdown" from step 1, so the
  -- set-filetype step is a no-op — only BufWinEnter can trigger here.
  with_sync_schedule(function()
    vim.api.nvim_set_current_buf(body)
  end)
  MiniTest.expect.equality(state.is_body(body), true)
end

-- ==============================================================================
-- auto_close autocommand
-- ==============================================================================

T["auto_close"] = MiniTest.new_set({ hooks = { post_case = reset_state } })

--- Open a voom tree for a fresh body buffer.  Returns body_buf, tree_buf.
--- Leaves the body focused so a subsequent trigger_bufwinleave call fires
--- BufWinLeave cleanly.  If a surrounding test has already enabled auto_open,
--- the `state.get_tree(body) or …` guard picks up the auto-created tree
--- instead of opening a second one.
local function open_tree_for(fixture, filetype)
  local tree = require("voom.tree")
  local body = make_body_from_fixture(fixture)
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = filetype
  local state = require("voom.state")
  local tree_buf = state.get_tree(body) or tree.create(body, filetype)
  vim.api.nvim_set_current_buf(body)
  return body, tree_buf
end

T["auto_close"]["default (false) leaves tree alive when body leaves its window"] = function()
  local voom = require("voom")

  voom.setup({})
  local body, tree_buf = open_tree_for("sample.md", "markdown")

  trigger_bufwinleave(body)

  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), true)
  -- post_case → cleanup_registered_bodies will close the surviving tree.
end

T["auto_close"]["true closes tree when body leaves its window"] = function()
  local voom = require("voom")

  voom.setup({ auto_close = true })
  local body, tree_buf = open_tree_for("sample.md", "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)
  MiniTest.expect.equality(tree_win ~= nil, true)

  trigger_bufwinleave(body)

  -- The tree *window* must be closed, not just the tree buffer wiped.
  -- If only the buffer were wiped, Neovim would pick another buffer for
  -- the still-open tree window and grab the just-hidden body — the
  -- user-visible flicker that regression-motivated this fix.
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(tree_win), false)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
  MiniTest.expect.equality(H.find_win_for_buf(body), nil)
end

T["auto_close"]["table form only closes listed modes"] = function()
  local voom = require("voom")

  voom.setup({ auto_close = { "markdown" } })

  -- Markdown: tree should close.
  local md_body, md_tree = open_tree_for("sample.md", "markdown")
  trigger_bufwinleave(md_body)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(md_tree), false)

  -- Python: tree should survive.
  local py_body, py_tree = open_tree_for("sample.py", "python")
  trigger_bufwinleave(py_body)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(py_tree), true)
  -- post_case → cleanup_registered_bodies will close the python tree.
end

-- ------------------------------------------------------------------------
-- Symmetric direction: tree-side BufWinLeave tears down the whole pair.
-- ------------------------------------------------------------------------

T["auto_close"]["true closes body window when tree leaves its window"] = function()
  local voom = require("voom")

  voom.setup({ auto_close = true })
  local body, tree_buf = open_tree_for("sample.md", "markdown")
  local body_win = H.find_win_for_buf(body)
  MiniTest.expect.equality(body_win ~= nil, true)

  -- Act on the tree side: swap the tree window's buffer to a scratch.
  -- This models `-` / fzf / `:q` invoked from the tree pane.
  trigger_bufwinleave(tree_buf)

  -- The body *window* must be closed.  Previously we called
  -- nvim_win_close(body_win, false) which refuses to close the last
  -- window in the last tab (E444) — pcall swallowed the error and the
  -- body was left hanging.  `:quit` via nvim_win_call handles that case
  -- by exiting Neovim, which in tests is fine because `trigger_bufwinleave`
  -- leaves a scratch window behind so `:quit` just closes body's window.
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(body_win), false)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
  MiniTest.expect.equality(H.find_win_for_buf(body), nil)
  -- Body buffer itself survives — `:quit` closes the window, not the
  -- buffer, so the user can `:b` back into it if they want.
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(body), true)
end

T["auto_close"]["default (false) leaves body alone when tree leaves its window"] = function()
  local voom = require("voom")

  voom.setup({})
  local body, tree_buf = open_tree_for("sample.md", "markdown")

  trigger_bufwinleave(tree_buf)

  -- Nothing should happen on either side when auto_close is off.
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), true)
  MiniTest.expect.equality(H.find_win_for_buf(body) ~= nil, true)
  -- post_case → cleanup_registered_bodies closes the orphaned tree.
end

T["auto_close"]["table form filter applies to tree direction"] = function()
  local voom = require("voom")

  voom.setup({ auto_close = { "markdown" } })

  -- Markdown tree leaving → body window closes.
  local md_body, md_tree = open_tree_for("sample.md", "markdown")
  trigger_bufwinleave(md_tree)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(md_tree), false)
  MiniTest.expect.equality(H.find_win_for_buf(md_body), nil)

  -- Python tree leaving → body window untouched (mode not listed).
  local py_body, py_tree = open_tree_for("sample.py", "python")
  trigger_bufwinleave(py_tree)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(py_tree), true)
  MiniTest.expect.equality(H.find_win_for_buf(py_body) ~= nil, true)
  -- post_case → cleanup_registered_bodies closes the python tree.
end

-- ------------------------------------------------------------------------
-- Explicit close: wiping the tree from :VoomToggle must not look like the
-- tree leaving its window, or auto_close would `:quit` the body as well.
-- ------------------------------------------------------------------------

--- Run `fn` with an extra window in the tab.  If close regresses into
--- quitting the body window, `:quit` then closes that window instead of
--- exiting the test Neovim when the body is the last window.
local function with_spare_window(fn)
  local spare = vim.api.nvim_get_current_win()
  vim.cmd("noautocmd botright split")
  local ok, err = pcall(fn)
  pcall(vim.api.nvim_win_close, spare, true)
  if not ok then
    error(err)
  end
end

T["auto_close"]["toggle from body closes only the tree"] = function()
  local voom = require("voom")

  voom.setup({ auto_close = true })
  with_spare_window(function()
    local body, tree_buf = open_tree_for("sample.md", "markdown")
    local body_win = H.find_win_for_buf(body)

    with_sync_schedule(function()
      vim.api.nvim_set_current_win(body_win)
      voom.toggle()
    end)

    MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
    MiniTest.expect.equality(vim.api.nvim_win_is_valid(body_win), true)
    MiniTest.expect.equality(vim.api.nvim_win_get_buf(body_win), body)
  end)
end

T["auto_close"]["toggle from tree closes only the tree"] = function()
  local voom = require("voom")

  voom.setup({ auto_close = true })
  with_spare_window(function()
    local body, tree_buf = open_tree_for("sample.md", "markdown")
    local body_win = H.find_win_for_buf(body)

    with_sync_schedule(function()
      vim.api.nvim_set_current_win(H.find_win_for_buf(tree_buf))
      voom.toggle()
    end)

    MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
    MiniTest.expect.equality(vim.api.nvim_win_is_valid(body_win), true)
    MiniTest.expect.equality(vim.api.nvim_win_get_buf(body_win), body)
  end)
end

-- ==============================================================================
-- unified_horizontal_splits autocommand
-- ==============================================================================

T["unified_horizontal_splits"] = MiniTest.new_set({ hooks = { post_case = reset_state } })

--- Open a fresh voom session, focus a specific pane, and return the
--- pieces tests need: body buffer, tree buffer, tree window, body
--- window.  `focus_pane` is "body" or "tree".
local function open_session(focus_pane)
  local tree = require("voom.tree")
  local body = make_body_from_fixture("sample.md")
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  local tree_buf = tree.create(body, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)
  local body_win = H.find_win_for_buf(body)
  if focus_pane == "tree" then
    vim.api.nvim_set_current_win(tree_win)
  else
    vim.api.nvim_set_current_win(body_win)
  end
  return body, tree_buf, tree_win, body_win
end

--- Find the "row" child of a top-level "col" layout (or vice-versa) and
--- return the list of leaf window IDs it contains.  Used to assert that
--- the tree+body row stays intact after a fix-up.
local function row_leaves(layout)
  if layout[1] ~= "row" then
    return nil
  end
  local leaves = {}
  for _, child in ipairs(layout[2]) do
    if child[1] == "leaf" then
      table.insert(leaves, child[2])
    end
  end
  return leaves
end

--- Return true if the given top-level layout matches the post-fixup
--- shape: a "col" whose children are exactly { "row" with [tree, body],
--- "leaf" } in either order (top or bottom placement of the new leaf).
local function is_unified_layout(layout, tree_win, body_win)
  if layout[1] ~= "col" then
    return false, "top is not col"
  end
  if #layout[2] ~= 2 then
    return false, "col does not have 2 children"
  end

  local row_node, leaf_node
  for _, child in ipairs(layout[2]) do
    if child[1] == "row" then
      row_node = child
    end
    if child[1] == "leaf" then
      leaf_node = child
    end
  end
  if not (row_node and leaf_node) then
    return false, "col children are not row+leaf"
  end

  local leaves = row_leaves(row_node)
  if not (vim.tbl_contains(leaves, tree_win) and vim.tbl_contains(leaves, body_win)) then
    return false, "row does not contain both panes"
  end
  return true
end

T["unified_horizontal_splits"]["bel split from body lifts new window to full-width bottom"] = function()
  require("voom").setup({}) -- default unified_horizontal_splits = true

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("belowright split")
  end)

  local layout = vim.fn.winlayout()
  local ok, msg = is_unified_layout(layout, tree_win, body_win)
  MiniTest.expect.equality(ok, true, msg)

  -- :bel placed the new window below body, so the fix-up should land it
  -- as the bottom child of the top-level col.
  MiniTest.expect.equality(layout[2][1][1], "row")
  MiniTest.expect.equality(layout[2][2][1], "leaf")
end

T["unified_horizontal_splits"]["bel split from tree lifts new window to full-width bottom"] = function()
  -- Tree-source splits are locked down by default; opt out so the
  -- legacy unified-split fix-up path stays exercised.
  require("voom").setup({ lock_tree_splits = false })

  local _, _, tree_win, body_win = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("belowright split")
  end)

  local layout = vim.fn.winlayout()
  local ok, msg = is_unified_layout(layout, tree_win, body_win)
  MiniTest.expect.equality(ok, true, msg)
  MiniTest.expect.equality(layout[2][1][1], "row")
  MiniTest.expect.equality(layout[2][2][1], "leaf")
end

T["unified_horizontal_splits"]["abo split from body lifts new window to full-width top"] = function()
  require("voom").setup({})

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("aboveleft split")
  end)

  local layout = vim.fn.winlayout()
  local ok, msg = is_unified_layout(layout, tree_win, body_win)
  MiniTest.expect.equality(ok, true, msg)

  -- :abo placed the new window above body, so the fix-up should land it
  -- as the top child of the top-level col.
  MiniTest.expect.equality(layout[2][1][1], "leaf")
  MiniTest.expect.equality(layout[2][2][1], "row")
end

T["unified_horizontal_splits"]["vsplit does not trigger col-promotion"] = function()
  -- The horizontal flag must only fire on `"col"` parents.  A vsplit
  -- creates a `"row"` parent, which the vertical flag handles instead.
  -- Verify here that the horizontal branch leaves the top-level layout
  -- as a row (the vertical branch may still reshape *within* that row,
  -- which is `unified_vertical_splits`'s job to test).
  require("voom").setup({})

  open_session("body")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  local layout = vim.fn.winlayout()
  MiniTest.expect.equality(layout[1], "row")
end

T["unified_horizontal_splits"]["flag=false leaves the broken split layout in place"] = function()
  require("voom").setup({ unified_horizontal_splits = false })

  open_session("body")

  with_sync_schedule(function()
    vim.cmd("belowright split")
  end)

  -- With the flag off, Neovim's default is preserved: the top level is
  -- still a "row" (tree + nested col on the body side), not a unified
  -- "col".
  local layout = vim.fn.winlayout()
  MiniTest.expect.equality(layout[1], "row")
end

T["unified_horizontal_splits"]["voom's own tree split is not disturbed"] = function()
  require("voom").setup({})

  -- tree.create issues a vertical split for the tree pane.  WinNew fires
  -- inside that call.  The handler must not move the tree pane to a
  -- full-width row of its own (parent is "row", not "col") — assert by
  -- checking the resulting baseline layout is still a single row of
  -- [tree, body] with no extra col wrapping.
  local _, _, tree_win, body_win = open_session("body")

  -- Drain any deferred work the session setup may have queued.
  with_sync_schedule(function() end)

  local layout = vim.fn.winlayout()
  MiniTest.expect.equality(layout[1], "row")
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(vim.tbl_contains(leaves, tree_win), true)
  MiniTest.expect.equality(vim.tbl_contains(leaves, body_win), true)
end

-- ==============================================================================
-- unified_vertical_splits autocommand
-- ==============================================================================

T["unified_vertical_splits"] = MiniTest.new_set({ hooks = { post_case = reset_state } })

--- Resolve the new (third) window from a post-vsplit layout.  The
--- handler may have moved it; we identify it as the lone leaf that's
--- not the tree or body window.
local function third_leaf(layout, tree_win, body_win)
  if layout[1] ~= "row" then
    return nil, "top is not row"
  end
  for _, child in ipairs(layout[2]) do
    if child[1] == "leaf" and child[2] ~= tree_win and child[2] ~= body_win then
      return child[2]
    end
  end
  return nil, "no third leaf"
end

T["unified_vertical_splits"]["vs from tree pushes new window to far right"] = function()
  -- Tree-source splits are locked down by default; opt out so the
  -- unified-vsplit fix-up path stays exercised.
  require("voom").setup({ lock_tree_splits = false }) -- tree_position="left", unified flag default true

  local _, _, tree_win, body_win = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  local layout = vim.fn.winlayout()
  MiniTest.expect.equality(layout[1], "row")

  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  -- Order must be [tree, body, new].
  MiniTest.expect.equality(leaves[1], tree_win)
  MiniTest.expect.equality(leaves[2], body_win)
  MiniTest.expect.equality(leaves[3] ~= tree_win and leaves[3] ~= body_win, true)
end

T["unified_vertical_splits"]["vs from body pushes new window to far right"] = function()
  require("voom").setup({})

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  local layout = vim.fn.winlayout()
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  MiniTest.expect.equality(leaves[1], tree_win)
  MiniTest.expect.equality(leaves[2], body_win)
end

T["unified_vertical_splits"]["splitright=false from body still pushes far right"] = function()
  -- Without splitright, default `:vsplit` from body would land *between*
  -- tree and body — the broken state.  Confirm the handler still pushes
  -- to far right regardless of splitright direction.
  require("voom").setup({})

  local prev = vim.opt.splitright:get()
  vim.opt.splitright = false

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  local layout = vim.fn.winlayout()
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  MiniTest.expect.equality(leaves[1], tree_win)
  MiniTest.expect.equality(leaves[2], body_win)

  vim.opt.splitright = prev
end

T["unified_vertical_splits"]["abo vsplit from body has its left intent overridden"] = function()
  -- Documented asymmetry with horizontal splits: `:abo vsp` would land
  -- the new window between tree and body (or past the tree, displacing
  -- the sidebar).  We override that intent and push to the body-side
  -- edge anyway.
  require("voom").setup({})

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("aboveleft vsplit")
  end)

  local layout = vim.fn.winlayout()
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  MiniTest.expect.equality(leaves[1], tree_win)
  MiniTest.expect.equality(leaves[2], body_win)
  -- The new window must NOT be on the tree-side edge (would displace
  -- the sidebar).
  MiniTest.expect.equality(leaves[1] ~= leaves[3], true)
end

T["unified_vertical_splits"]["tree_position=right pushes new window to far left"] = function()
  require("voom").setup({ tree_position = "right" })

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  local layout = vim.fn.winlayout()
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  -- With tree on right, the body-side edge is the LEFT edge.  Order
  -- becomes [new, body, tree].
  MiniTest.expect.equality(leaves[3], tree_win)
  MiniTest.expect.equality(leaves[2], body_win)
  MiniTest.expect.equality(leaves[1] ~= tree_win and leaves[1] ~= body_win, true)
end

T["unified_vertical_splits"]["flag=false leaves the broken vsplit layout in place"] = function()
  -- Same opt-out as the analogous tree-source tests above.
  require("voom").setup({ unified_vertical_splits = false, lock_tree_splits = false })

  local _, _, tree_win, body_win = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  -- With the flag off, Neovim's default `:vs` from the tree pane
  -- (with the default `splitright = false`) lands the new window to
  -- the *left* of the tree — `[new, tree, body]`.  Our fix-up would
  -- have moved it to the body-side edge (rightmost); confirm it's
  -- still in the broken position (anywhere but the rightmost slot).
  local layout = vim.fn.winlayout()
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  local new_win
  for _, w in ipairs(leaves) do
    if w ~= tree_win and w ~= body_win then
      new_win = w
      break
    end
  end
  MiniTest.expect.equality(new_win ~= nil, true)
  MiniTest.expect.equality(leaves[#leaves] ~= new_win, true)
end

T["unified_vertical_splits"]["voom's own tree split is not disturbed"] = function()
  -- Same guard as the horizontal version: tree.create() issues a vsplit
  -- and WinNew fires inside it.  The exclude-win + pair-membership guard
  -- keeps the handler from acting on the tree pane itself.
  require("voom").setup({})

  local _, _, tree_win, body_win = open_session("body")
  with_sync_schedule(function() end)

  local layout = vim.fn.winlayout()
  MiniTest.expect.equality(layout[1], "row")
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 2)
  MiniTest.expect.equality(vim.tbl_contains(leaves, tree_win), true)
  MiniTest.expect.equality(vim.tbl_contains(leaves, body_win), true)
end

T["unified_vertical_splits"]["follow_cursor keeps focus in duplicate tree window"] = function()
  -- Regression: when `:vs` from the tree pane creates a second window
  -- showing the tree buffer, `follow_cursor`'s "restore focus" branch
  -- would call `nvim_set_current_win(find_win_for_buf(tree_buf))` —
  -- which returns the first tree window in layout order, not the one
  -- the user is currently in.  Every cursor move in the duplicate tree
  -- bounced focus back to the original.  Confirm the duplicate keeps
  -- focus across an explicit follow_cursor call.
  --
  -- The dup-tree state is now only reachable with lock_tree_splits=false
  -- (or by some other path that creates two tree windows); opt out so
  -- this regression stays guarded for users who disable the lockdown.
  require("voom").setup({ lock_tree_splits = false })

  local _, tree_buf, tree_win_orig, _ = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  -- Identify the duplicate tree window (the one that's not tree_win_orig).
  local tree_dup
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == tree_buf and w ~= tree_win_orig then
      tree_dup = w
      break
    end
  end
  MiniTest.expect.equality(tree_dup ~= nil, true)

  vim.api.nvim_set_current_win(tree_dup)
  require("voom.tree").follow_cursor(tree_buf, 1)

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_dup)

  -- Close the duplicate explicitly so post_case → cleanup_registered_bodies
  -- doesn't trip over a window whose buffer it's about to wipe.
  if vim.api.nvim_win_is_valid(tree_dup) then
    vim.api.nvim_win_close(tree_dup, true)
  end
end

-- ==============================================================================
-- lock_tree_splits autocommand
-- ==============================================================================

T["lock_tree_splits"] = MiniTest.new_set({ hooks = { post_case = reset_state } })

T["lock_tree_splits"]["vs from tree pane is silently dropped"] = function()
  require("voom").setup({}) -- default lock_tree_splits = true

  local _, _, tree_win, body_win = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  -- Layout returns to the canonical [tree, body] row — no third
  -- window survives.
  local layout = vim.fn.winlayout()
  MiniTest.expect.equality(layout[1], "row")
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 2)
  MiniTest.expect.equality(vim.tbl_contains(leaves, tree_win), true)
  MiniTest.expect.equality(vim.tbl_contains(leaves, body_win), true)
end

T["lock_tree_splits"]["sp from tree pane is silently dropped"] = function()
  require("voom").setup({})

  local _, _, tree_win, body_win = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("split")
  end)

  -- Top-level layout stays a "row" of [tree, body].  No "col"
  -- promotion (which is what unified_horizontal_splits would have
  -- done if the lockdown hadn't fired first).
  local layout = vim.fn.winlayout()
  MiniTest.expect.equality(layout[1], "row")
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 2)
  MiniTest.expect.equality(vim.tbl_contains(leaves, tree_win), true)
  MiniTest.expect.equality(vim.tbl_contains(leaves, body_win), true)
end

T["lock_tree_splits"]["body-pane vsplit still gets unified treatment"] = function()
  -- Lockdown is asymmetric: only tree-pane splits are blocked.  Body
  -- splits flow through the unified-vsplit branch as before.
  require("voom").setup({})

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  local layout = vim.fn.winlayout()
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  MiniTest.expect.equality(leaves[1], tree_win)
  MiniTest.expect.equality(leaves[2], body_win)
end

T["lock_tree_splits"]["body-pane split still gets unified treatment"] = function()
  require("voom").setup({})

  local _, _, tree_win, body_win = open_session("body")

  with_sync_schedule(function()
    vim.cmd("belowright split")
  end)

  -- Same shape as the unified_horizontal_splits "bel split from body"
  -- assertion: top-level becomes a col with the tree+body row above
  -- a leaf below.
  local layout = vim.fn.winlayout()
  local ok, msg = is_unified_layout(layout, tree_win, body_win)
  MiniTest.expect.equality(ok, true, msg)
end

T["lock_tree_splits"]["flag=false re-allows tree-pane splits"] = function()
  -- Sanity: with the lockdown disabled, the tree-pane vsplit flows
  -- through the unified-vsplit branch and produces a 3-leaf row.
  require("voom").setup({ lock_tree_splits = false })

  local _, _, tree_win, body_win = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  local layout = vim.fn.winlayout()
  local leaves = row_leaves(layout)
  MiniTest.expect.equality(#leaves, 3)
  MiniTest.expect.equality(leaves[1], tree_win)
  MiniTest.expect.equality(leaves[2], body_win)
end

T["lock_tree_splits"]["focus returns to the source tree window"] = function()
  -- After the lockdown closes the new window, Neovim falls back to
  -- the previously-focused window.  Confirm the user lands back where
  -- they started (still in the tree pane), so a stray :vs keystroke
  -- isn't user-visible beyond the new window flickering away.
  require("voom").setup({})

  local _, _, tree_win, _ = open_session("tree")

  with_sync_schedule(function()
    vim.cmd("vsplit")
  end)

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), tree_win)
end

return T
