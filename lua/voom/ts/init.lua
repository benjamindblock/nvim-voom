-- Treesitter engine for nvim-voom.
--
-- Provides a language-agnostic outline extraction layer on top of Neovim's
-- built-in Treesitter API.  Modes are assembled from two independent pieces:
--
--   • A query definition  (lua/voom/ts/queries/<lang>.lua)  — declares which
--     nodes to capture and how to derive heading level + display name.
--
--   • A template          (lua/voom/ts/templates/<lang>.lua) — implements the
--     editing operations (new_headline, do_body_after_oop) for the language.
--     Falls back to voom.ts.templates.code for languages that don't support
--     structural editing through the tree pane.
--
-- Adding a new language only requires a query file (and optionally a template
-- file); this engine module needs no changes.
--
-- Public API:
--   make_outliner(query_def) -> function(lines, buf_name, bufnr?) -> outline_table
--   build_mode(lang)         -> { make_outline, new_headline, do_body_after_oop,
--                                 capabilities }

local M = {}

-- ==============================================================================
-- Private: parse helpers
-- ==============================================================================

-- Get a parse tree from a live buffer.  Passes no range so Neovim can use its
-- incremental parse cache — on the BufWritePost re-parse path the tree will
-- already be current if the buffer was parsed before.
local function parse_buffer(bufnr, lang)
  local parser = vim.treesitter.get_parser(bufnr, lang)
  local tree   = parser:parse()[1]
  return tree, bufnr
end

-- Create a temporary scratch buffer containing `lines`, parse it with TS, and
-- return the parse tree together with the temporary buffer number.
--
-- The caller MUST delete the buffer after extraction is complete because
-- `vim.treesitter.get_node_text` needs the buffer to still exist at call time.
local function parse_lines(lines, lang)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local parser = vim.treesitter.get_parser(buf, lang)
  local tree   = parser:parse()[1]
  return tree, buf
end

-- ==============================================================================
-- make_outliner
-- ==============================================================================

-- Return a `make_outline(lines, buf_name, bufnr?)` function configured for
-- `query_def`.  When `bufnr` is provided the engine parses the live buffer
-- directly; otherwise it creates a temporary scratch buffer and cleans it up
-- after extraction, preserving backward-compatibility with code paths that
-- have no live buffer (unit tests, clipboard paste).
function M.make_outliner(query_def)
  return function(lines, buf_name, bufnr)
    local tree, src_buf
    local temp_buf = nil  -- set only when we created the buffer ourselves

    -- -------------------------------------------------------------------------
    -- Step 1: obtain a parse tree.
    -- -------------------------------------------------------------------------
    if bufnr then
      local ok, err = pcall(function()
        tree, src_buf = parse_buffer(bufnr, query_def.lang)
      end)
      if not ok then
        vim.notify(
          "VOoM: treesitter parser for '" .. query_def.lang ..
          "' unavailable — run :TSInstall " .. query_def.lang ..
          " (" .. tostring(err) .. ")",
          vim.log.levels.WARN
        )
        return { tlines = {}, bnodes = {}, levels = {},
                 use_hash = false, use_close_hash = false }
      end
    else
      -- No live buffer: spin up a scratch buffer.  We hold on to temp_buf so
      -- we can delete it in all code paths (success and error) below.
      local ok, err = pcall(function()
        tree, temp_buf = parse_lines(lines, query_def.lang)
        src_buf = temp_buf
      end)
      if not ok then
        if temp_buf and vim.api.nvim_buf_is_valid(temp_buf) then
          vim.api.nvim_buf_delete(temp_buf, { force = true })
        end
        vim.notify(
          "VOoM: treesitter parser for '" .. query_def.lang ..
          "' unavailable — run :TSInstall " .. query_def.lang ..
          " (" .. tostring(err) .. ")",
          vim.log.levels.WARN
        )
        return { tlines = {}, bnodes = {}, levels = {},
                 use_hash = false, use_close_hash = false }
      end
    end

    -- -------------------------------------------------------------------------
    -- Step 2: run the query and build the outline.
    --
    -- Everything from here to the cleanup block is wrapped in pcall so that a
    -- buggy extract() implementation cannot leak the scratch buffer.
    -- -------------------------------------------------------------------------
    local query = vim.treesitter.query.parse(query_def.lang, query_def.query_string)

    -- Collect raw captures into a plain list so query_def.extract() receives
    -- a stable snapshot rather than a live iterator.
    local captures = {}
    for id, node, metadata in query:iter_captures(tree:root(), src_buf, 0, -1) do
      table.insert(captures, { id = id, node = node, metadata = metadata })
    end

    local ok, result = pcall(function()
      -- The query definition interprets the raw captures and returns an array
      -- of { level, name, lnum } entries.
      local entries = query_def.extract(captures, query, src_buf)

      -- Guarantee document order; well-behaved parsers already produce captures
      -- in source order, but this guard prevents subtle bugs if they don't.
      table.sort(entries, function(a, b) return a.lnum < b.lnum end)

      -- Build the three parallel outline arrays.
      local tlines = {}
      local bnodes = {}
      local levels = {}
      for _, entry in ipairs(entries) do
        -- Tree-pane display format (matches modes/markdown.lua:161):
        --   one leading space
        --   (level - 1) two-space pairs for visual depth
        --   "· " fold-state placeholder
        --   heading text
        -- Example: level 3 → "     · My Heading"
        table.insert(tlines, " " .. string.rep("  ", entry.level - 1) .. "· " .. entry.name)
        table.insert(bnodes, entry.lnum)
        table.insert(levels, entry.level)
      end

      -- Collect style hints.  state.lua reads use_hash and use_close_hash as
      -- top-level keys on the outline table (state.lua:124-128), so they must
      -- not be nested inside a sub-table.
      local style = query_def.outline_state(entries, lines)

      return {
        tlines         = tlines,
        bnodes         = bnodes,
        levels         = levels,
        use_hash       = style.use_hash,
        use_close_hash = style.use_close_hash,
      }
    end)

    -- -------------------------------------------------------------------------
    -- Step 3: cleanup — always delete the temp buffer, whether or not the
    -- extraction succeeded.  Leaked scratch buffers are a usability problem.
    -- -------------------------------------------------------------------------
    if temp_buf and vim.api.nvim_buf_is_valid(temp_buf) then
      vim.api.nvim_buf_delete(temp_buf, { force = true })
    end

    if not ok then
      error(result)
    end

    return result
  end
end

-- ==============================================================================
-- build_mode
-- ==============================================================================

-- Assemble a complete VOoM mode table for `lang`.
--
-- Loads the query definition from `voom.ts.queries.<lang>` and the editing
-- template from `voom.ts.templates.<lang>` (falling back to the no-op code
-- template when no language-specific template exists).  The resulting table
-- satisfies the mode contract expected by tree.lua and oop.lua.
function M.build_mode(lang)
  local query_def = require("voom.ts.queries." .. lang)

  local template_ok, template = pcall(require, "voom.ts.templates." .. lang)
  if not template_ok then
    template = require("voom.ts.templates.code")
  end

  return {
    make_outline      = M.make_outliner(query_def),
    new_headline      = template.new_headline,
    do_body_after_oop = template.do_body_after_oop,
    capabilities      = template.capabilities,
  }
end

return M
