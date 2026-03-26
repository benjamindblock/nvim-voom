-- ==============================================================================
-- Shared OOP Test Harness
-- ==============================================================================
--
-- Consolidates repeated setup, teardown, and assertion patterns from the
-- individual spec files into a single importable module.  Spec files should
-- require this module at the top:
--
--   local H = dofile("test/helpers.lua")
--
-- The harness is structural only — it does not change any runtime behavior.

local H = {}

-- ==============================================================================
-- Buffer helpers
-- ==============================================================================

--- Load a fixture file into a 1-indexed table of strings (no trailing newline
--- per line), matching the format that `nvim_buf_get_lines()` returns.
function H.load_fixture(name)
  local path = vim.fn.getcwd() .. "/test/fixtures/" .. name
  local lines = {}
  for line in io.lines(path) do
    table.insert(lines, line)
  end
  return lines
end

--- Create a scratch buffer optionally loaded with `lines` and named `name`.
--- Returns the buffer number.
function H.make_scratch_buf(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return buf
end

--- Delete a buffer if it is still valid.
function H.del_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- ==============================================================================
-- Window helpers
-- ==============================================================================

--- Find a window showing `buf` in the current tabpage, or nil.
function H.find_win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

--- Search tree buffer lines for `text` (plain match) and return the 1-based
--- line number, or nil if not found.
function H.find_tree_lnum_by_text(tree_buf, text)
  local lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return i
    end
  end
  return nil
end

--- Open a minimal floating window displaying `buf`.  Useful when a window
--- must exist for `find_win_for_buf` but no split is needed.
function H.open_float_win(buf)
  return vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 40,
    height = 10,
  })
end

-- ==============================================================================
-- State cleanup
-- ==============================================================================

--- Close and delete every registered body buffer.  Intended for use in
--- `post_case` hooks to guarantee a clean slate between tests.
function H.cleanup_registered_bodies()
  local state = require("voom.state")
  local bodies = vim.tbl_keys(state.bodies)
  for _, body_buf in ipairs(bodies) do
    require("voom.tree").close(body_buf)
    H.del_buf(body_buf)
  end
end

--- Build a standard `post_case` hook table that cleans up all registered
--- bodies.  Shorthand for the most common hook shape:
---
---   MiniTest.new_set({ hooks = H.clean_hooks() })
function H.clean_hooks()
  return { post_case = H.cleanup_registered_bodies }
end

-- ==============================================================================
-- Echo / notify capture
-- ==============================================================================

--- Run `fn` with `vim.api.nvim_echo` temporarily replaced by a recorder.
--- Returns the list of captured calls.  Each entry has `{ chunks, history,
--- opts }` matching the original `nvim_echo` signature.
function H.with_captured_echo(fn)
  local calls = {}
  local orig = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, history, opts)
    table.insert(calls, {
      chunks = vim.deepcopy(chunks),
      history = history,
      opts = opts,
    })
  end

  local ok, err = pcall(fn, calls)
  vim.api.nvim_echo = orig
  if not ok then
    error(err)
  end
  return calls
end

--- Run `fn` with `vim.notify` temporarily replaced by a recorder.
--- Returns the list of captured calls.  Each entry has `{ msg, level, opts }`.
function H.with_captured_notify(fn)
  local calls = {}
  local orig = vim.notify
  vim.notify = function(msg, level, opts)
    table.insert(calls, { msg = msg, level = level, opts = opts })
  end

  local ok, err = pcall(fn, calls)
  vim.notify = orig
  if not ok then
    error(err)
  end
  return calls
end

-- ==============================================================================
-- Fixture documents
-- ==============================================================================

--- Build the canonical simple markdown document used across OOP tests.
--- 4 headings: H1 "Heading One", H2 "Sub A", H2 "Sub B", H1 "Heading Two".
function H.simple_doc()
  return {
    "# Heading One",
    "",
    "Content under one.",
    "",
    "## Sub A",
    "",
    "Content under Sub A.",
    "",
    "## Sub B",
    "",
    "Content under Sub B.",
    "",
    "# Heading Two",
    "",
    "Content under two.",
  }
end

-- ==============================================================================
-- Tree/body setup (high-level)
-- ==============================================================================

--- Create a body buffer from `lines` (or `simple_doc()` if nil), open a tree
--- for it, focus the tree window, and position the cursor on `tree_lnum`.
---
--- Returns `body_buf, tree_buf, tree_win`.
function H.setup_tree(lines, buf_name, tree_lnum)
  local tree_mod = require("voom.tree")

  lines = lines or H.simple_doc()
  local buf = H.make_scratch_buf(lines, buf_name)
  vim.api.nvim_set_current_buf(buf)
  local tree_buf = tree_mod.create(buf, "markdown")
  local tree_win = H.find_win_for_buf(tree_buf)

  if tree_win and tree_lnum then
    vim.api.nvim_set_current_win(tree_win)
    vim.api.nvim_win_set_cursor(tree_win, { tree_lnum, 0 })
  end

  return buf, tree_buf, tree_win
end

-- ==============================================================================
-- Keypress helper
-- ==============================================================================

--- Feed keys through Neovim's input queue, executing them immediately.
function H.press(keys)
  local term = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(term, "xt", false)
end

-- ==============================================================================
-- Reusable assertions
-- ==============================================================================
--
-- Each assertion uses MiniTest.expect internally and produces clear failure
-- messages.  They are designed to be called at assertion sites in tests,
-- replacing the repeated inline patterns.

local expect = MiniTest.expect

--- Assert that the current buffer is `expected_buf`.
function H.assert_focused_buf(expected_buf)
  expect.equality(vim.api.nvim_get_current_buf(), expected_buf)
end

--- Assert the cursor position in `win` (defaults to current window).
function H.assert_cursor(lnum, col, win)
  local cursor = vim.api.nvim_win_get_cursor(win or 0)
  expect.equality(cursor[1], lnum)
  if col then
    expect.equality(cursor[2], col)
  end
end

--- Assert `snLn` for a body buffer equals `expected_lnum`.
function H.assert_snLn(body_buf, expected_lnum)
  local state = require("voom.state")
  expect.equality(state.get_snLn(body_buf), expected_lnum)
end

--- Assert that the stored `changedtick` for `body_buf` matches the buffer's
--- actual `changedtick` (i.e. state is in sync after a mutation).
function H.assert_changedtick_synced(body_buf)
  local state = require("voom.state")
  expect.equality(
    state.get_changedtick(body_buf),
    vim.api.nvim_buf_get_changedtick(body_buf)
  )
end

--- Assert that the stored `changedtick` for `body_buf` differs from
--- `before_tick` (i.e. a mutation actually happened).
function H.assert_changedtick_changed(body_buf, before_tick)
  local state = require("voom.state")
  expect.equality(state.get_changedtick(body_buf) ~= before_tick, true)
end

--- Assert that `body_buf` content equals the expected list of lines.
function H.assert_body_lines(body_buf, expected_lines)
  local actual = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  expect.equality(actual, expected_lines)
end

--- Assert that `body_buf` content has not changed from `before_lines`.
function H.assert_body_unchanged(body_buf, before_lines)
  local after = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  expect.equality(#after, #before_lines)
  for i = 1, #before_lines do
    expect.equality(after[i], before_lines[i])
  end
end

--- Assert that a line matching `pattern` exists (or does not exist) in
--- `body_buf`.
function H.assert_body_has_line(body_buf, pattern, should_exist)
  if should_exist == nil then
    should_exist = true
  end
  local lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
  local found = false
  for _, l in ipairs(lines) do
    if l:match(pattern) then
      found = true
      break
    end
  end
  expect.equality(found, should_exist)
end

--- Assert outline levels for `body_buf` equal `expected_levels`.
function H.assert_outline_levels(body_buf, expected_levels)
  local state = require("voom.state")
  local outline = state.get_outline(body_buf)
  expect.equality(outline.levels, expected_levels)
end

--- Combined assertion for the common post-mutation contract: focus stays in
--- tree, cursor is at `tree_lnum`, snLn matches, and changedtick is synced
--- and changed from `before_tick`.
function H.assert_tree_mutation_state(body_buf, tree_buf, tree_win, tree_lnum, before_tick)
  H.assert_focused_buf(tree_buf)
  H.assert_cursor(tree_lnum, nil, tree_win)
  H.assert_snLn(body_buf, tree_lnum)
  H.assert_changedtick_synced(body_buf)
  H.assert_changedtick_changed(body_buf, before_tick)
end

return H
