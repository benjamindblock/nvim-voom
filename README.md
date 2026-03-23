# VOoM

VOoM (Vim Outliner of Markers) is a two-pane outliner plugin for Neovim. It
creates a tree buffer mirroring the heading structure of the current buffer,
enabling fast navigation and reorganization of structured documents.

> **Status:** This is an in-progress Lua rewrite. The original Python-based
> plugin is preserved in `legacy/` for reference.

## Installation

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'benjamindblock/VOoM'
```

## Usage

```vim
:Voom [mode]       " Open the tree pane (optional markup mode, e.g. 'markdown')
:VoomToggle [mode] " Toggle the tree pane open/closed
:Voomhelp          " Open the help file
```

## Development

Requires [mise](https://mise.jdx.dev/) for tool management.

```sh
mise install       # Install luajit, stylua, lua-language-server
mise run test      # Run the test suite
mise run fmt       # Format all Lua files
```
