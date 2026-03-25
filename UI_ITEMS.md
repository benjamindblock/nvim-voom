# UI Enhancement Work Items

Eight independent improvements to modernise the tree view panel.
Each item can be implemented on its own; Items 2 and 4 share a line-format
dependency (both assume the 2-space-per-level indent), so implement Item 2
before Item 4 if both are in scope.

---

## Item 1 — Winbar with filename + heading count

- [x] **Done**

**File:** `lua/voom/tree.lua`

Add a helper that sets the `winbar` option on the tree window to display the
open file's name and the total heading count:

```lua
local function update_winbar(tree_win, body_buf)
  local outline = state.get_outline(body_buf)
  local count   = outline and #outline.levels or 0
  local name    = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(body_buf), ":t")
  vim.api.nvim_set_option_value(
    "winbar",
    " 󰈙 " .. name .. "  ·  " .. count .. " headings",
    { win = tree_win }
  )
end
```

- Call `update_winbar(tree_win, body_buf)` at the bottom of `open_tree()`
  (around line 1382, after the window options are set).
- Call it again wherever the tree buffer is refreshed (wherever
  `nvim_buf_set_lines` is called for the tree buf) so the count stays current.
- Optionally expose the file icon as a config key in `config.lua`
  (`M.defaults.winbar = { file_icon = "󰈙" }`) so users with broken Nerd Font
  rendering can override it to `"•"`.

---

## Item 2 — Indent guide lines

- [x] **Done**

**Files:** `lua/voom/tree.lua`, `lua/voom/config.lua`,
`lua/voom/modes/markdown.lua` (and any other mode files)

### 2a — Config (`lua/voom/config.lua`)

Add to `M.defaults`:

```lua
indent_guides = {
  enabled = true,
  char    = "│",   -- box-drawing vertical bar
},
```

### 2b — Highlight (`lua/voom/tree.lua` → `define_highlights()`)

```lua
vim.api.nvim_set_hl(0, "VoomIndentGuide", { default = true, fg = "#3b4261" })
```

### 2c — Line format change (`lua/voom/modes/markdown.lua`, line ~163)

Replace `"· "` indentation with two plain spaces so guide characters can be
overlaid cleanly:

```lua
-- Before:
table.insert(tlines, " " .. string.rep("· ", lev - 1) .. "· " .. head)

-- After:
table.insert(tlines, " " .. string.rep("  ", lev - 1) .. "· " .. head)
```

Apply the same change to every other mode file that builds `tlines`.

Update the byte-offset comment in `render_fold_icons()` — the icon `·` now
sits at `col = 1 + (lev - 1) * 2` (was `1 + (lev - 1) * 3`).

### 2d — Guide rendering (`lua/voom/tree.lua`)

Add a new namespace and function, called from the same site as
`render_fold_icons()`:

```lua
local GUIDE_NS = vim.api.nvim_create_namespace("voom_guides")

local function render_indent_guides(tree_buf, outline)
  vim.api.nvim_buf_clear_namespace(tree_buf, GUIDE_NS, 0, -1)

  local cfg    = require("voom.config").get()
  if not cfg.indent_guides.enabled then return end

  local levels = outline.levels
  -- levels[] is 1-indexed; tree line k+1 corresponds to levels[k].
  -- Skip the root node (tree line 1 has no entry in levels[]).
  for idx, lev in ipairs(levels) do
    -- extmark row is 0-indexed; tree line idx+1 → extmark row idx
    local lnum = idx
    for ancestor = 1, lev - 1 do
      -- Each indent level occupies 2 bytes ("  "); guide sits at the first byte.
      local col = 1 + (ancestor - 1) * 2
      vim.api.nvim_buf_set_extmark(tree_buf, GUIDE_NS, lnum, col, {
        end_col       = col + 1,
        virt_text     = { { cfg.indent_guides.char, "VoomIndentGuide" } },
        virt_text_pos = "overlay",
      })
    end
  end
end
```

---

## Item 3 — Per-level heading colors

- [x] **Done**

**File:** `lua/voom/tree.lua`

### 3a — Highlights in `define_highlights()`

```lua
-- Muted rainbow that harmonises with TokyoNight; brightest at H1, dimmest at H6.
local level_colors = {
  "#c0caf5",  -- H1 bright lavender
  "#7aa2f7",  -- H2 blue
  "#7dcfff",  -- H3 cyan
  "#9ece6a",  -- H4 green
  "#ff9e64",  -- H5 orange
  "#f7768e",  -- H6 red
}
for i, fg in ipairs(level_colors) do
  vim.api.nvim_set_hl(0, "VoomHeading" .. i, { default = true, fg = fg })
end
```

### 3b — Application function

Add alongside `render_fold_icons()` and call it from the same site:

```lua
local HEAD_NS = vim.api.nvim_create_namespace("voom_headings")

local function render_heading_highlights(tree_buf, outline)
  vim.api.nvim_buf_clear_namespace(tree_buf, HEAD_NS, 0, -1)

  local lines  = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
  local levels = outline.levels

  for idx, lev in ipairs(levels) do
    local lnum     = idx   -- 0-indexed extmark row
    local hl       = "VoomHeading" .. math.min(lev, 6)
    -- Heading text starts after: 1 leading space + (lev-1)*2 indent bytes + 2 bytes for "· "
    local text_col = 1 + (lev - 1) * 2 + 2
    vim.api.nvim_buf_add_highlight(tree_buf, HEAD_NS, hl, lnum, text_col, -1)
  end
end
```

---

## Item 4 — Truncate long headings with `…`

- [ ] **Done**

> **Depends on Item 2** (uses the 2-space-per-level indent to compute prefix width).

**Files:** `lua/voom/tree.lua`, `lua/voom/modes/markdown.lua` (and other modes)

### 4a — Helper in `lua/voom/tree.lua`

Expose this as a module-level local (or add to a shared `util` module if one exists):

```lua
-- Truncate `text` to fit within a tree line of `max_cols` display columns,
-- given `prefix_width` display columns already consumed by indent + icon.
-- Returns the original string unchanged when it already fits.
local function truncate_heading(text, prefix_width, max_cols)
  -- 1 leading space is already included in prefix_width callers.
  local available = max_cols - prefix_width
  if vim.fn.strdisplaywidth(text) <= available then
    return text
  end
  local truncated = text
  while vim.fn.strdisplaywidth(truncated .. "…") > available do
    -- Drop one byte at a time. Works correctly for ASCII; for multibyte
    -- strings this may require a few extra iterations but is safe.
    truncated = truncated:sub(1, -2)
  end
  return truncated .. "…"
end
```

### 4b — Usage in mode files (e.g. `lua/voom/modes/markdown.lua`, line ~163)

```lua
local cfg          = require("voom.config").get()
local prefix_width = 1 + lev * 2   -- 1 leading space + icon-placeholder + space
head = require("voom.tree").truncate_heading(head, prefix_width, cfg.tree_width)
table.insert(tlines, " " .. string.rep("  ", lev - 1) .. "· " .. head)
```

If `truncate_heading` stays local to `tree.lua`, either make it a module
export (`M.truncate_heading`) or move it to a new `lua/voom/util.lua`.

---

## Item 5 — Child-count badge on collapsed nodes

- [ ] **Done**

**File:** `lua/voom/tree.lua`

Add highlight in `define_highlights()`:

```lua
vim.api.nvim_set_hl(0, "VoomBadge", { default = true, fg = "#565f89", italic = true })
```

Add namespace and function (call it after `render_fold_icons()`):

```lua
local BADGE_NS = vim.api.nvim_create_namespace("voom_badges")

-- `tree_win` must be the window displaying tree_buf so that foldclosed()
-- queries fold state in the right window context.
local function render_count_badges(tree_win, tree_buf, outline)
  vim.api.nvim_buf_clear_namespace(tree_buf, BADGE_NS, 0, -1)

  local levels = outline.levels

  -- We need foldclosed() to run in the context of tree_win.
  vim.api.nvim_win_call(tree_win, function()
    for idx, lev in ipairs(levels) do
      local lnum = idx  -- 0-indexed extmark row; vim line is lnum+2 (root=1, first heading=2)

      -- Count the run of deeper levels that follow (direct + indirect children).
      local children = 0
      for j = idx + 1, #levels do
        if levels[j] > lev then
          children = children + 1
        else
          break
        end
      end
      if children == 0 then goto continue end

      -- foldclosed() takes a 1-indexed vim line number.
      local vim_line = lnum + 2
      if vim.fn.foldclosed(vim_line) == -1 then goto continue end  -- fold is open

      vim.api.nvim_buf_set_extmark(tree_buf, BADGE_NS, lnum, 0, {
        virt_text     = { { "+" .. children, "VoomBadge" } },
        virt_text_pos = "eol",
      })

      ::continue::
    end
  end)
end
```

---

## Item 6 — Breadcrumb winbar (current-section tracking)

- [ ] **Done**

> **Depends on Item 1** — extends `update_winbar()` defined there.

**File:** `lua/voom/tree.lua`

### 6a — Breadcrumb builder

```lua
-- Walk the outline and build a heading path (breadcrumb) for the line the
-- body cursor is currently on.  Returns "" when outside all headings.
local function build_breadcrumb(body_buf, body_win)
  local outline = state.get_outline(body_buf)
  if not outline then return "" end

  local cursor  = vim.api.nvim_win_get_cursor(body_win)[1]
  local path    = {}
  local cur_lev = 0

  for i, lev in ipairs(outline.levels) do
    if lev <= cur_lev then
      -- Pop back up: this heading is at the same or higher level, so remove
      -- deeper-level ancestors from the path before deciding whether to push.
      while #path > 0 and cur_lev >= lev do
        table.remove(path)
        cur_lev = cur_lev - 1
      end
    end
    local start_line = outline.start_lines[i]
    if start_line <= cursor then
      table.insert(path, outline.headings[i])
      cur_lev = lev
    else
      break
    end
  end

  if #path == 0 then return "" end
  return "  ›  " .. table.concat(path, " › ")
end
```

### 6b — Extended `update_winbar()`

Replace the function from Item 1 with this version that accepts an optional
`body_win` for breadcrumb context:

```lua
local function update_winbar(tree_win, body_buf, body_win)
  local outline = state.get_outline(body_buf)
  local count   = outline and #outline.levels or 0
  local name    = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(body_buf), ":t")
  local crumb   = body_win and build_breadcrumb(body_buf, body_win) or ""
  vim.api.nvim_set_option_value(
    "winbar",
    " 󰈙 " .. name .. "  ·  " .. count .. " headings" .. crumb,
    { win = tree_win }
  )
end
```

### 6c — Hook into cursor autocmd

Find the existing `CursorMoved` / `BufEnter` autocmd that refreshes the tree
cursor highlight (search for `CursorMoved` in `tree.lua`) and add a call to
`update_winbar(tree_win, body_buf, body_win)` there.

---

## Item 7 — File-type icon in root node

- [ ] **Done**

**File:** `lua/voom/tree.lua`

Add near the top of the file (or inside `open_tree()` before the root line is
built):

```lua
-- Return a Nerd Font file-type icon for `bufnr` using nvim-web-devicons,
-- falling back to "•" when the plugin is absent.
local function get_file_icon(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ext  = vim.fn.fnamemodify(name, ":e")
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon = devicons.get_icon(name, ext, { default = true })
    if icon then return icon end
  end
  return "•"
end
```

Find where the root line is constructed (search for `" • "` or `root_line` in
`tree.lua`) and replace the hard-coded `•` with:

```lua
local root_icon = get_file_icon(body_buf)
local root_line = " " .. root_icon .. " " .. vim.fn.fnamemodify(
                    vim.api.nvim_buf_get_name(body_buf), ":t")
```

---

## Item 8 — Horizontal separator after root line

- [ ] **Done**

**File:** `lua/voom/tree.lua`

Add highlight in `define_highlights()`:

```lua
vim.api.nvim_set_hl(0, "VoomSeparator", { default = true, fg = "#3b4261" })
```

Add namespace and function; call it after the tree buffer lines are written:

```lua
local SEP_NS = vim.api.nvim_create_namespace("voom_separator")

local function render_separator(tree_buf, tree_win)
  vim.api.nvim_buf_clear_namespace(tree_buf, SEP_NS, 0, 1)
  -- Fill the window width minus 1 to avoid triggering horizontal scroll.
  local width = vim.api.nvim_win_get_width(tree_win) - 1
  local rule  = string.rep("─", width)
  -- virt_lines appends a virtual line *below* row 0 (the root node).
  vim.api.nvim_buf_set_extmark(tree_buf, SEP_NS, 0, 0, {
    virt_lines          = { { { rule, "VoomSeparator" } } },
    virt_lines_above    = false,
  })
end
```

Call `render_separator(tree_buf, tree_win)` immediately after
`nvim_buf_set_lines` populates the tree buffer (same site as
`render_fold_icons()`).
