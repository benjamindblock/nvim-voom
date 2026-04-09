-- Treesitter query definition for Markdown headings.
--
-- Handles both Markdown heading styles:
--
--   ATX (levels 1–6):       ## My Heading
--                           ## My Heading ##   (optional closing hashes)
--
--   Setext (levels 1–2):    My Heading
--                           ==========         (= → level 1)
--
--                           My Heading
--                           ----------         (- → level 2)
--
-- Each entry returned by extract() carries:
--   level        int     1–6
--   name         string  heading text (markers and closing hashes stripped)
--   lnum         int     1-indexed body line number of the title line
--   heading_type string  "atx" or "setext"
--   has_close_hash bool  true when an ATX heading ends with '#'

local M = {}

M.lang = "markdown"

-- Match all heading node types with a single capture name so that extract()
-- can handle both ATX and setext nodes through one dispatch path.
M.query_string = [[(atx_heading) @heading (setext_heading) @heading]]

-- ---------------------------------------------------------------------------
-- extract: derive level, name, and metadata from raw TS captures.
-- ---------------------------------------------------------------------------

-- Inspect the children of `node` and return the child whose type matches any
-- entry in the `types` table, or nil if no such child exists.
local function find_child_by_types(node, types)
  local set = {}
  for _, t in ipairs(types) do
    set[t] = true
  end
  for i = 0, node:child_count() - 1 do
    local child = node:child(i)
    if set[child:type()] then
      return child
    end
  end
  return nil
end

-- Return the heading level encoded in an ATX marker node type string.
-- The marker types are named "atx_h1_marker" through "atx_h6_marker"; we
-- parse the digit out of the type name rather than relying on the text
-- length so that the code is robust against parser version differences.
local function atx_marker_level(marker_type)
  local n = marker_type:match("atx_h(%d)_marker")
  return n and tonumber(n) or nil
end

-- Strip trailing '#' characters and surrounding whitespace from `text`.
-- This normalises both "## Heading ##" and "## Heading" → "Heading", matching
-- the regex parser's `head:gsub("%s*#+%s*$", "")` behaviour.
local function strip_closing_hashes(text)
  return (text:gsub("%s*#+%s*$", ""))
end

-- Strip leading and trailing whitespace.
local function strip(s)
  return (s:match("^%s*(.-)%s*$"))
end

function M.extract(captures, query, bufnr)
  local entries = {}

  for _, cap in ipairs(captures) do
    local capture_name = query.captures[cap.id]
    if capture_name ~= "heading" then
      goto continue
    end

    local node = cap.node
    local node_type = node:type()
    local entry

    if node_type == "atx_heading" then
      -- -------------------------------------------------------------------
      -- ATX heading: level comes from the marker child's type name.
      -- Text comes from the `inline` child (may be absent for empty `# `).
      -- -------------------------------------------------------------------

      -- Find the marker node (atx_h1_marker … atx_h6_marker).
      local marker = find_child_by_types(node, {
        "atx_h1_marker", "atx_h2_marker", "atx_h3_marker",
        "atx_h4_marker", "atx_h5_marker", "atx_h6_marker",
      })
      if not marker then
        goto continue
      end
      local level = atx_marker_level(marker:type())
      if not level then
        goto continue
      end

      -- The `inline` child holds the heading text including any closing `##`.
      -- Empty headings (`# ` with no text) have no inline child.
      local inline = find_child_by_types(node, { "inline" })
      local raw_name = inline and vim.treesitter.get_node_text(inline, bufnr) or ""

      -- Detect whether this heading uses closing hashes by inspecting the raw
      -- heading line.  We check the heading node's source text rather than
      -- the inline text because the inline node already excludes the marker.
      local heading_text = vim.treesitter.get_node_text(node, bufnr)
                             :gsub("%s+$", "")  -- strip trailing whitespace
      local has_close_hash = heading_text:sub(-1) == "#"

      local name = strip_closing_hashes(raw_name)

      -- lnum is 1-indexed; TS rows are 0-indexed.
      local start_row = node:range()

      entry = {
        level          = level,
        name           = name,
        lnum           = start_row + 1,
        heading_type   = "atx",
        has_close_hash = has_close_hash,
      }

    elseif node_type == "setext_heading" then
      -- -------------------------------------------------------------------
      -- Setext heading: level comes from the underline child type.
      -- Text comes from the paragraph/inline child.
      -- The lnum is the title line (= paragraph's start row), NOT the
      -- underline line.
      -- -------------------------------------------------------------------

      -- Determine level from the underline node.
      local underline = find_child_by_types(node, {
        "setext_h1_underline",
        "setext_h2_underline",
      })
      if not underline then
        goto continue
      end
      local level = (underline:type() == "setext_h1_underline") and 1 or 2

      -- The title text lives inside a paragraph > inline subtree.
      local paragraph = find_child_by_types(node, { "paragraph" })
      local name = ""
      if paragraph then
        local inline = find_child_by_types(paragraph, { "inline" })
        if inline then
          name = strip(vim.treesitter.get_node_text(inline, bufnr))
        end
      end

      -- Use the paragraph's start row as lnum (the actual title line).
      local para_row = paragraph and paragraph:range() or node:range()

      entry = {
        level          = level,
        name           = name,
        lnum           = para_row + 1,
        heading_type   = "setext",
        has_close_hash = false,
      }
    end

    if entry then
      table.insert(entries, entry)
    end

    ::continue::
  end

  return entries
end

-- ---------------------------------------------------------------------------
-- outline_state: derive style hints from the extracted entries.
--
-- Mirrors the style-detection logic in modes/markdown.lua:make_outline so
-- that new_headline and do_body_after_oop receive the same preferences the
-- regex parser would have computed.
-- ---------------------------------------------------------------------------

function M.outline_state(entries, lines)
  -- Defaults match the regex parser's initial values.
  local use_hash         = false
  local use_hash_set     = false
  local use_close_hash   = true   -- regex default: assume closing hashes
  local use_close_hash_set = false

  for _, entry in ipairs(entries) do
    -- use_hash: set from the first level-1 or level-2 heading.
    if not use_hash_set and entry.level < 3 then
      use_hash     = (entry.heading_type == "atx")
      use_hash_set = true
    end

    -- use_close_hash: set from the first ATX heading of any level.
    if not use_close_hash_set and entry.heading_type == "atx" then
      use_close_hash     = entry.has_close_hash
      use_close_hash_set = true
    end

    -- Short-circuit once both flags have been resolved.
    if use_hash_set and use_close_hash_set then
      break
    end
  end

  return { use_hash = use_hash, use_close_hash = use_close_hash }
end

return M
