-- Shared read-only helpers for derived tree data.
--
-- These utilities extract user-visible information from the tree buffer and
-- outline arrays without mutating any state.  They exist so that modules
-- that need to read tree data (tree.lua, oop.lua, init.lua) share one
-- implementation instead of each carrying its own copy.
--
-- Structural edit logic (oop.lua) should not live here — this module is
-- strictly read-only.

local M = {}

-- Find a window displaying `buf` in the current tab, or nil.
function M.find_win_for_buf(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

-- Extract the heading text that appears after the last "· " separator in a
-- tree display line.  The tree line format is " [· ]*· {heading_text}", so
-- the greedy match skips all indentation dots and lands on the text.
-- Returns the empty string for lines without a match (defensive fallback).
function M.heading_text_from_tree_line(line)
  local text = line:match(".*· (.+)$")
  return text or ""
end

-- Given sorted heading start lines (`bnodes`) and a body cursor line, return
-- the owning tree line number.  Returns 1 (first heading) when the cursor is
-- above all headings — a reasonable fallback for preamble content.
function M.tree_lnum_for_body_line(bnodes, cursor_line)
  local target_tree_lnum = 1
  for i = #bnodes, 1, -1 do
    if bnodes[i] <= cursor_line then
      target_tree_lnum = i   -- direct 1:1 mapping; no +1 offset for root
      break
    end
  end
  return target_tree_lnum
end

return M
