-- Plugin state: bidirectional body↔tree buffer mapping and per-body outline data.
--
-- All mutable plugin state lives here so that init.lua and tree.lua stay
-- stateless and easy to test in isolation.
--
-- Terminology mirrors the legacy voom.vim conventions:
--   body   — the "real" content buffer the user is editing
--   tree   — the read-only outline panel VOoM creates alongside it
--   bnodes — 1-indexed array of body line numbers, one per tree heading
--   levels — 1-indexed array of heading depths (1–6), parallel to bnodes
--   snLn   — "selected node line number": the tree line currently highlighted

local M = {}

-- ==============================================================================
-- Internal storage
-- ==============================================================================

-- tree_bufnr → body_bufnr
M.trees = {}

-- body_bufnr → { tree, snLn, mode, bnodes, levels, changedtick }
M.bodies = {}

-- ==============================================================================
-- Registration
-- ==============================================================================

-- Register a new body↔tree pair and store the parsed outline data.
--
-- @param body_buf  number   body buffer number
-- @param tree_buf  number   tree buffer number
-- @param mode      string   markup mode name (e.g. "markdown")
-- @param outline   table    return value of mode.make_outline()
function M.register(body_buf, tree_buf, mode, outline)
  M.trees[tree_buf] = body_buf
  M.bodies[body_buf] = {
    tree        = tree_buf,
    snLn        = 1,
    mode        = mode,
    bnodes      = outline.bnodes,
    levels      = outline.levels,
    -- Snapshot the tick so the BufEnter autocmd can detect out-of-band edits
    -- (e.g. changes made while the panel was closed, or edits in another tab).
    -- pcall guards against tests that register placeholder (non-real) buffer
    -- numbers; in production body_buf is always a valid live buffer.
    changedtick = (function()
      local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, body_buf)
      return ok and tick or 0
    end)(),
  }
end

-- Remove all state associated with `body_buf` (and its tree).
function M.unregister(body_buf)
  local entry = M.bodies[body_buf]
  if entry then
    M.trees[entry.tree] = nil
  end
  M.bodies[body_buf] = nil
end

-- ==============================================================================
-- Queries
-- ==============================================================================

-- Return true if `buf` is a known body buffer.
function M.is_body(buf)
  return M.bodies[buf] ~= nil
end

-- Return true if `buf` is a known tree buffer.
function M.is_tree(buf)
  return M.trees[buf] ~= nil
end

-- Return the body buffer number for a given tree buffer, or nil.
function M.get_body(tree_buf)
  return M.trees[tree_buf]
end

-- Return the tree buffer number for a given body buffer, or nil.
function M.get_tree(body_buf)
  local entry = M.bodies[body_buf]
  return entry and entry.tree or nil
end

-- Return { bnodes, levels } for a body buffer, or nil.
function M.get_outline(body_buf)
  local entry = M.bodies[body_buf]
  if not entry then return nil end
  return { bnodes = entry.bnodes, levels = entry.levels }
end

-- Replace the stored outline data after a tree rebuild.
function M.set_outline(body_buf, outline)
  local entry = M.bodies[body_buf]
  if not entry then return end
  entry.bnodes = outline.bnodes
  entry.levels = outline.levels
end

-- Return the currently selected tree line number for a body buffer.
function M.get_snLn(body_buf)
  local entry = M.bodies[body_buf]
  return entry and entry.snLn or nil
end

-- Update the selected tree line number.
function M.set_snLn(body_buf, lnum)
  local entry = M.bodies[body_buf]
  if entry then
    entry.snLn = lnum
  end
end

-- Return the stored changedtick for a body buffer, or nil.
function M.get_changedtick(body_buf)
  local entry = M.bodies[body_buf]
  return entry and entry.changedtick or nil
end

-- Overwrite the stored changedtick (called after a tree rebuild triggered by
-- BufEnter, to avoid redundant rebuilds on the next re-entry).
function M.set_changedtick(body_buf, tick)
  local entry = M.bodies[body_buf]
  if entry then
    entry.changedtick = tick
  end
end

return M
