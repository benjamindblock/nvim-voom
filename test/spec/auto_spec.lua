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
  local orig = vim.schedule
  vim.schedule = function(f) f() end
  local ok, err = pcall(fn)
  vim.schedule = orig
  if not ok then error(err) end
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

--- Trigger `BufWinLeave` on `body_buf` by swapping the current window's
--- buffer to a throwaway scratch.  This matches the real-world scenarios the
--- auto_close flag targets (fzf replacing the buffer, netrw replacing it with
--- a directory listing) more closely than `:bwipeout`, and — because the body
--- buffer stays alive — it avoids the `E855: Autocommands caused command to
--- abort` warning that a sync tree-delete inside a wipe would trigger.
local function trigger_bufwinleave(body_buf)
  with_sync_schedule(function()
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
  local voom  = require("voom")
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

  trigger_bufwinleave(body)

  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)
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

return T
