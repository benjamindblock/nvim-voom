# nvim-voom

`nvim-voom` is a pure Lua port of the Vim plugin
[VOoM](https://github.com/vim-voom/VOoM) (Vim Outliner of Markups). It is a
two-pane outliner for Neovim: a read-only tree buffer on the left mirrors the
heading structure of the current buffer, enabling fast navigation and
reorganization of structured documents.

> **Status:** This is an in-progress Lua rewrite. The original Python-based
> plugin is included as a git submodule at `legacy/`
> ([vim-voom/VOoM](https://github.com/vim-voom/VOoM)) for reference.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "benjamindblock/nvim-voom" }
```

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'benjamindblock/nvim-voom'
```

Any Neovim package manager that adds the plugin to `runtimepath` will work.

## Configuration

Call `require("voom").setup({...})` anywhere in your init file after the
plugin loads to override defaults:

```lua
require("voom").setup({
  tree_width   = 40,         -- width of the tree pane in columns
  default_mode = "markdown", -- markup mode used when none can be auto-detected
  fold_indicators = {
    enabled = true,
    icons   = { open = "▾", closed = "▶", leaf = "·" },
  },
  indent_guides = {
    enabled = true,
    char    = "│",            -- U+2502 box-drawing vertical bar
  },
})
```

`setup()` is optional — all options have sensible defaults and the plugin
works without any explicit configuration.

## Commands

```vim
:Voom [mode]         " Open the tree pane (auto-detects filetype if mode omitted)
:VoomToggle [mode]   " Toggle the tree pane open/closed
:VoomGrep {pattern}  " Search headings for a Lua pattern; results go to the quickfix list
:VoomSort [opts]     " Sort sibling nodes under the current heading (see below)
:Voominfo            " Display state info for the current nvim-voom session
:Voomlog             " Open the nvim-voom log buffer
:Voomhelp            " Open the help file
```

`:Voom` and `:VoomToggle` support command-line completion for mode names.

## Supported markup modes

| Mode       | Trigger                         | Heading styles supported              |
|------------|---------------------------------|---------------------------------------|
| `markdown` | `.md` files or `:Voom markdown` | ATX headings (`#` through `######`, levels 1-6) and setext underline headings (`===` / `---`, levels 1-2) |

The mode is detected automatically from the buffer's filetype. Pass an explicit
mode name to `:Voom` or `:VoomToggle` to override.

## Tree pane

Opening `nvim-voom` splits the window with a narrow tree pane on the left
(40 columns by default). Each line in the tree represents one heading.
Indentation depth mirrors heading level:

```
  |sample.md
  |Introduction
  . |Installation
  . . |Requirements
  . . |Platform Notes
  . |Usage
  |Advanced Topics
```

The tree is read-only. It refreshes automatically whenever the body buffer is
saved, and also when you re-enter the body after an out-of-band edit.

### Visual elements

The tree pane renders several visual aids via extmarks:

- **Fold indicators** — each node shows an icon reflecting its fold state:
  `▾` (open), `▶` (closed), or `·` (leaf with no children).
- **Indent guides** — vertical lines (`│`) are drawn at each ancestor column
  to make nesting depth easy to follow.
- **Descendant badges** — when a node is folded and has hidden children, a
  `+N` badge appears showing how many descendants are collapsed beneath it.

## Keymaps — tree pane

### Navigation

| Key             | Action                                              |
|-----------------|-----------------------------------------------------|
| `j` / `k`       | Move cursor up/down (standard Vim motions)          |
| `<CR>` / `gO`   | Jump to the heading under the cursor in the body    |
| `<Tab>`         | Switch focus to the body window                     |
| `<Left>` / `P`  | Move cursor to the parent heading                   |
| `<Right>` / `o` | Open/reveal current node if needed, then move to first child heading |
| `K`             | Move cursor to the previous sibling heading         |
| `J`             | Move cursor to the next sibling heading             |
| `U`             | Move cursor to the first (topmost) sibling heading  |
| `D`             | Move cursor to the last (bottommost) sibling heading|
| `=`             | Return cursor to the currently selected heading     |

### Folding

| Key       | Action                                            |
|-----------|---------------------------------------------------|
| `<Space>` | Toggle fold at cursor (`za`)                      |
| `C`       | Contract (close) all siblings of the current node |
| `O`       | Expand (open) all siblings of the current node    |

### Display

| Key | Action                                                                    |
|-----|---------------------------------------------------------------------------|
| `s` | Echo the heading text of the current node to the command line             |
| `S` | Echo the full UNL path (`Head > Sub > Leaf`) and yank it to register `n` |

### Editing

| Key                | Action                                                                  |
|--------------------|-------------------------------------------------------------------------|
| `i`                | Jump to the body buffer with cursor on the heading line                 |
| `I`                | Jump to the body buffer with cursor on the last line of the node's body |
| `aa`               | Insert a new sibling node after the current one                         |
| `AA`               | Insert a new child node under the current one                           |
| `yy`               | Copy the current node and its subtree to the plugin clipboard           |
| `dd`               | Cut the current node and its subtree (stores in plugin clipboard)       |
| `pp`               | Paste the clipboard contents after the current node                     |
| `^^` / `<C-Up>`    | Move the current node and its subtree up (swap with previous sibling)   |
| `__` / `<C-Down>`  | Move the current node and its subtree down (swap with next sibling)     |
| `<<` / `<C-Left>`  | Promote: decrease heading level by 1                                    |
| `>>` / `<C-Right>` | Demote: increase heading level by 1                                     |
| `u` / `<C-r>`      | Undo / redo via the body buffer's undo tree (keeps focus in tree pane)  |

When inserting a new node (`aa` / `AA`), the cursor lands on the placeholder
text `NewHeadline` in the body buffer — use `ciw` to replace it immediately.

## Keymaps — body pane

| Key  | Action                                                                  |
|------|-------------------------------------------------------------------------|
| `gO` | Select the heading that owns the cursor; syncs the tree and jumps to it |

## Live cursor-follow

Moving the cursor in the tree pane automatically scrolls the body window to the
corresponding heading, without moving focus away from the tree. This uses a
`CursorMoved` autocommand so all navigation methods — motions, searches, mouse
clicks — trigger the follow.

## VoomGrep

`:VoomGrep {pattern}` searches the heading texts of the current body buffer
using a Lua pattern and populates the quickfix list with matching entries.
If any headings match, the quickfix window opens automatically; if none match,
a warning is displayed.

## VoomSort

`:VoomSort [opts]` sorts the sibling nodes of the current heading. The sort
operates on the current heading's siblings (nodes at the same level under the
same parent), moving each node together with its entire subtree.

| Option    | Effect                                      |
|-----------|---------------------------------------------|
| _(none)_  | Alphabetical sort (A-Z)                     |
| `r`       | Reverse alphabetical sort (Z-A)             |
| `i`       | Case-insensitive alphabetical sort          |
| `i r`     | Case-insensitive, reverse alphabetical sort |
| `flip`    | Reverse the current order                   |
| `shuffle` | Randomize order (Fisher-Yates shuffle)      |

## Customization

### Highlight groups

Each heading level in the tree pane uses a dedicated highlight group. By
default these link to the treesitter markdown heading captures, so they
automatically match your active colorscheme.

| Group             | Default link / color       | Purpose                    |
|-------------------|----------------------------|----------------------------|
| `VoomHeading1`-`6`| `@markup.heading.N.markdown` | Per-level heading colors |
| `VoomFoldOpen`    | `#7aa2f7` (blue)           | Open fold indicator (`▾`)  |
| `VoomFoldClosed`  | `#e0af68` (amber)          | Closed fold indicator (`▶`)|
| `VoomLeafNode`    | `#565f89` (grey)           | Leaf indicator (`·`)       |
| `VoomIndentGuide` | `#3b4261` (dark grey)      | Vertical guide lines (`│`) |
| `VoomBadge`       | `#565f89` (italic grey)    | Descendant count (`+N`)    |

All groups are defined with `default = true`, so any colorscheme or user
override takes precedence. To customize, add `vim.api.nvim_set_hl` calls
**after** your colorscheme is applied — for example inside a `ColorScheme`
autocommand or at the bottom of your `init.lua`:

```lua
vim.api.nvim_set_hl(0, "VoomHeading1", { fg = "#ffffff", bold = true })
vim.api.nvim_set_hl(0, "VoomFoldClosed", { fg = "#f7768e" })
```

## Development

Requires [mise](https://mise.jdx.dev/) for tool management.

```sh
mise install          # Install lua, stylua, lua-language-server
mise run test         # Run the full test suite
mise run test-file <path>  # Run a single spec file
mise run fmt          # Format all Lua files with StyLua
mise run fmt-check    # Check formatting without modifying files
```

Tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md)
(auto-bootstrapped on first run). Specs live in `test/spec/`.
