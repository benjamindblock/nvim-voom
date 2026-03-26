# Configuration options

This file tracks configuration options for nvim-voom. Options marked
**Exists** are already defined in `lua/voom/config.lua` but not yet exposed
via a public `setup()` function. Options marked **Planned** are candidates
for future implementation.

## Existing (in `config.lua`, not yet wired to public API)

### `tree_width`
- **Type:** `number`
- **Default:** `40`
- **Description:** Width of the tree pane in columns.

### `default_mode`
- **Type:** `string`
- **Default:** `"markdown"`
- **Description:** Markup mode used when none is specified and the filetype
  cannot be auto-detected.

### `fold_indicators.enabled`
- **Type:** `boolean`
- **Default:** `true`
- **Description:** Show virtual-text fold-state indicators (`▾`/`▶`/`·`)
  next to each tree node.

### `fold_indicators.icons`
- **Type:** `table { open: string, closed: string, leaf: string }`
- **Default:** `{ open = "▾", closed = "▶", leaf = "·" }`
- **Description:** Characters used for the fold indicators.

### `indent_guides.enabled`
- **Type:** `boolean`
- **Default:** `true`
- **Description:** Render vertical guide lines at ancestor columns of nested
  headings.

### `indent_guides.char`
- **Type:** `string`
- **Default:** `"│"` (U+2502)
- **Description:** Character used for the indent guide lines. Must be a single
  display-column character.

---

## Planned

### `tree_position`
- **Type:** `"left" | "right"`
- **Default:** `"left"`
- **Description:** Which side of the window the tree pane opens on.

### `auto_open`
- **Type:** `boolean | table<string>`
- **Default:** `false`
- **Description:** Automatically open the tree pane for matching filetypes.
  `true` opens for all supported modes; a list like `{ "markdown" }` limits
  it to specific modes.

### `cursor_follow`
- **Type:** `boolean`
- **Default:** `true`
- **Description:** Whether moving the cursor in the tree automatically scrolls
  the body to the corresponding heading.

### `badges.enabled`
- **Type:** `boolean`
- **Default:** `true`
- **Description:** Show `+N` descendant count badges on folded nodes.

### `keymaps`
- **Type:** `table | false`
- **Default:** (built-in keymap table)
- **Description:** Override or disable individual tree-pane keymaps. Setting a
  key to `false` disables it. Setting it to a string remaps the action to that
  key. Setting the entire option to `false` disables all plugin keymaps, letting
  the user define their own via autocommands.

### `on_open`
- **Type:** `function(body_buf, tree_buf) | nil`
- **Default:** `nil`
- **Description:** Callback invoked after the tree pane is created. Useful for
  applying buffer-local settings or additional keymaps.

### `sort.default_opts`
- **Type:** `string`
- **Default:** `""`
- **Description:** Default options passed to `:VoomSort` when none are
  specified (e.g., `"i"` to always sort case-insensitively).
