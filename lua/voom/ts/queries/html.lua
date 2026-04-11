-- Treesitter query definition for HTML outlines.
--
-- Captures heading elements (h1–h6).  Level matches the heading rank
-- (1–6), mirroring how Markdown headings work.  The display name is
-- the text content of the heading element.

local M = {}

M.lang = "html"

-- Match all element nodes — we filter to h1–h6 in extract() by
-- inspecting the tag name, because TS queries for HTML don't support
-- predicates on tag_name text content.
M.query_string = [[(element) @element]]

-- ===========================================================================
-- Heading tag → level mapping
-- ===========================================================================

local HEADING_LEVELS = {
  h1 = 1, h2 = 2, h3 = 3,
  h4 = 4, h5 = 5, h6 = 6,
}

-- ===========================================================================
-- extract
-- ===========================================================================

function M.extract(captures, query, bufnr)
  local entries = {}

  for _, cap in ipairs(captures) do
    local capture_name = query.captures[cap.id]
    if capture_name ~= "element" then
      goto continue
    end

    local node = cap.node

    -- Find the start_tag child to read the tag name.
    local tag_name_text = nil
    local start_tag = nil
    for i = 0, node:child_count() - 1 do
      local child = node:child(i)
      if child:type() == "start_tag" then
        start_tag = child
        break
      end
    end

    if not start_tag then
      goto continue
    end

    -- The tag_name is a child of start_tag.
    for i = 0, start_tag:child_count() - 1 do
      local child = start_tag:child(i)
      if child:type() == "tag_name" then
        tag_name_text = vim.treesitter.get_node_text(child, bufnr)
        break
      end
    end

    if not tag_name_text then
      goto continue
    end

    local level = HEADING_LEVELS[tag_name_text:lower()]
    if not level then
      goto continue
    end

    -- Extract the text content of the heading.  We take all text
    -- children between start_tag and end_tag, which handles inline
    -- elements like <em> or <strong> inside headings.
    local start_row = node:range()
    local lnum = start_row + 1

    -- Get the full element text then strip the tags.
    local full_text = vim.treesitter.get_node_text(node, bufnr)
    -- Remove opening tag: <h1 ...>
    local name = full_text:gsub("^<[^>]+>", "")
    -- Remove closing tag: </h1>
    name = name:gsub("<[^>]+>$", "")
    -- Collapse whitespace and strip leading/trailing
    name = name:gsub("%s+", " "):match("^%s*(.-)%s*$")

    if name == "" then
      name = "(empty)"
    end

    table.insert(entries, { level = level, name = name, lnum = lnum })

    ::continue::
  end

  return entries
end

-- ===========================================================================
-- outline_state
-- ===========================================================================

function M.outline_state(_entries, _lines)
  return { use_hash = false, use_close_hash = false }
end

return M
