# nvim-voom

`nvim-voom` is a pure Lua port of the Vim plugin VOoM (Vim Outliner of Markups).
`nvim-voom` is a two-pane outliner plugin for Neovim. It creates a tree buffer
mirroring the heading structure of the current buffer, enabling fast navigation
of structured documents.

> **Status:** This is an in-progress Lua rewrite. The original Python-based
> plugin is included as a git submodule at `legacy/`
> ([vim-voom/VOoM](https://github.com/vim-voom/VOoM)) for reference.

## Installation

Using [vim-plug](https://github.com/junegunn/vim-plug):

```neovim
plug("benjamindblock/nvim-voom")
```

## Commands

```vim
:Voom [mode]         " Open the tree pane (auto-detects filetype if mode omitted)
:VoomToggle [mode]   " Toggle the tree pane open/closed
:VoomGrep {pattern}  " Search headings for pattern; results go to the quickfix list
:VoomSort [opts]     " Sort sibling nodes under the current heading (see below)
:Voominfo            " Display state info for the current nvim-voom session
:Voomlog             " Open the nvim-voom log buffer
:Voomhelp            " Open the help file
```

## Supported markup modes

| Mode       | Trigger                         | Heading styles supported              |
|------------|---------------------------------|---------------------------------------|
| `markdown` | `.md` files or `:Voom markdown` | `# Hash` headings (levels 1–6) and setext underline headings (`===` / `---`) |

The mode is detected automatically from the buffer's filetype. Pass an explicit
mode name to `:Voom` or `:VoomToggle` to override.

## Tree pane

Opening `nvim-voom` splits the window with a narrow tree pane on the left. Each
line in the tree represents one heading. Indentation depth mirrors heading
level:

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

## Keymaps — tree pane

### Navigation

| Key            | Action                                              |
|----------------|-----------------------------------------------------|
| `j` / `k`      | Move cursor up/down (standard Vim motions)          |
| `<CR>`         | Jump to the heading under the cursor in the body    |
| `<Tab>`        | Switch focus to the body window                     |
| `<Left>` / `P` | Move cursor to the parent heading                   |
| `<Right>` / `o`| Open/reveal current node if needed, then move to first child heading |
| `K`            | Move cursor to the previous sibling heading         |
| `J`            | Move cursor to the next sibling heading             |
| `U`            | Move cursor to the first (topmost) sibling heading  |
| `D`            | Move cursor to the last (bottommost) sibling heading|
| `=`            | Return cursor to the currently selected heading     |

### Folding

| Key       | Action                                           |
|-----------|--------------------------------------------------|
| `<Space>` | Toggle fold at cursor (`za`)                     |
| `C`       | Contract (close) all siblings of the current node|
| `O`       | Expand (open) all siblings of the current node   |

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

| Key    | Action                                                               |
|--------|----------------------------------------------------------------------|
| `<CR>` | Select the heading that owns the cursor; syncs the tree to that node |
| `<Tab>`| Switch focus to the tree pane                                        |

## Live cursor-follow

Moving the cursor in the tree pane automatically scrolls the body window to the
corresponding heading, without moving focus away from the tree. This uses a
`CursorMoved` autocommand so all navigation methods — motions, searches, mouse
clicks — trigger the follow.

## VoomGrep

`:VoomGrep {pattern}` searches the heading texts of the current body buffer
using a Lua pattern and populates the quickfix list with matching entries. Open
the quickfix list with `:copen` or let `:VoomGrep` open it automatically.

## VoomSort

`:VoomSort [opts]` sorts the sibling nodes of the current heading. The sort
operates on the current heading's siblings (nodes at the same level under the
same parent), moving each node together with its entire subtree.

| Option    | Effect                                      |
|-----------|---------------------------------------------|
| _(none)_  | Alphabetical sort (A–Z)                     |
| `r`       | Reverse alphabetical sort (Z–A)             |
| `i`       | Case-insensitive alphabetical sort          |
| `i r`     | Case-insensitive, reverse alphabetical sort |
| `flip`    | Reverse the current order                   |
| `shuffle` | Randomize order (Fisher-Yates shuffle)      |

## Customization

### Heading colors

Each heading level in the tree pane is colored with a dedicated highlight
group, `VoomHeading1` through `VoomHeading6`. By default these are linked
to the treesitter markdown heading groups (`@markup.heading.N.markdown`),
so they automatically match whatever colorscheme you have active (including
light themes).

To override the colors, add `vim.api.nvim_set_hl` calls to your Neovim
config **after** the colorscheme is applied — for example inside a
`ColorScheme` autocommand or at the bottom of your `init.lua`:

```lua
-- Example: bold white for H1, a custom green for H2.
vim.api.nvim_set_hl(0, "VoomHeading1", { fg = "#ffffff", bold = true })
vim.api.nvim_set_hl(0, "VoomHeading2", { fg = "#a6e3a1" })
```

To restore the plugin defaults, clear your overrides with
`:hi clear VoomHeading1` (repeat for each level you changed), then reload
the plugin or restart Neovim.

## Development

Requires [mise](https://mise.jdx.dev/) for tool management.

```sh
mise install       # Install luajit, stylua, lua-language-server
mise run test      # Run the test suite
mise run fmt       # Format all Lua files
```
