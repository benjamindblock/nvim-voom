# nvim-voom

nvim-voom is a pure Lua port of the Vim plugin VOoM (Vim Outliner of Markups).
nvim-voom is a two-pane outliner plugin for Neovim. It creates a tree buffer
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

Opening nvim-voom splits the window with a narrow tree pane on the left. Each
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
| `<Right>` / `o`| Move cursor to the first child heading              |
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

## Development

Requires [mise](https://mise.jdx.dev/) for tool management.

```sh
mise install       # Install luajit, stylua, lua-language-server
mise run test      # Run the test suite
mise run fmt       # Format all Lua files
```
