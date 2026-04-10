# Treesitter Integration Plan

## Context

nvim-voom historically used regex-based parsers in
`lua/voom/modes/markdown.lua` and `lua/voom/modes/asciidoc.lua` to extract
headings. Markdown is now routed through Treesitter, and AsciiDoc support is
temporarily removed so the migration can focus on Markdown plus future
programming-language modes first. The remaining regex parser will be removed at
the end.

## Current Architecture

### Mode contract

Every mode module in `lua/voom/modes/` exports three functions:

```lua
make_outline(lines, buf_name) -> {
  tlines = { string },       -- formatted tree display lines
  bnodes = { int },          -- body line numbers (1-indexed, strictly increasing)
  levels = { int },          -- heading depth 1-6
  use_hash = bool,           -- style hint (ATX vs setext for markdown)
  use_close_hash = bool,     -- style hint (closing hashes)
}

new_headline(outline_state, level, preceding_line) -> { tree_head, body_lines }

do_body_after_oop(lines, bnodes, levels, outline_state, oop, lev_delta,
                  blnum1, tlnum1, blnum2, tlnum2, blnum_cut, tlnum_cut) -> b_delta
```

Invariant: `#bnodes == #levels == #tlines` (parallel arrays).

### Call sites for `make_outline`

- `lua/voom/tree.lua:1468` — initial outline on tree creation
- `lua/voom/tree.lua:1580` — re-parse on `BufWritePost` / manual update
- `lua/voom/oop.lua:703` — parse clipboard content during paste (no buffer, just lines)

### Call site for `do_body_after_oop`

- `lua/voom/oop.lua:305` — already guarded with `if mode and mode.do_body_after_oop`

### Mode registry

`lua/voom/modes/init.lua` maps mode names to lazy loaders. `modes.get(name)`
returns the module.

## Target Architecture

```
lua/voom/
  ts/
    init.lua                 -- TS engine: parse, query, build outline; build_mode() factory
    queries/
      markdown.lua           -- query definition for Markdown headings
      python.lua             -- query definition for Python classes/functions
      lua.lua                -- query definition for Lua functions
      ruby.lua               -- query definition for Ruby classes/modules/methods
      go.lua                 -- query definition for Go funcs/types/methods
    templates/
      markdown.lua           -- new_headline + do_body_after_oop (from modes/markdown.lua)
      code.lua               -- shared no-op template for programming languages
  modes/
    init.lua                 -- updated registry pointing at TS-built modes
```

### Module interfaces

**Query definition** (`ts/queries/*.lua`):

```lua
return {
  lang = "markdown",           -- treesitter parser language name

  -- Treesitter query in s-expression syntax. Captures are language-specific;
  -- the extract() function interprets them.
  query_string = [[ ... ]],

  -- Given the list of raw TS captures from the query, return an array of
  -- { level = int, name = string, lnum = int (1-indexed) } entries sorted
  -- by lnum. `bufnr` is the buffer the tree was parsed from (needed for
  -- vim.treesitter.get_node_text).
  extract = function(captures, query, bufnr) -> entries[],

  -- Given the extracted entries, return the outline_state table that
  -- new_headline and do_body_after_oop need for format-aware operations.
  outline_state = function(entries, lines) -> { use_hash, use_close_hash, ... },
}
```

**Template** (`ts/templates/*.lua`):

```lua
return {
  new_headline = function(outline_state, level, preceding_line) -> { tree_head, body_lines } | nil,
  do_body_after_oop = function(...) -> b_delta | nil,  -- nil = not supported
  capabilities = {
    insert = bool,
    promote = bool,
    demote = bool,
    move = bool,
    cut = bool,
    paste = bool,
    sort = bool,
  },
}
```

**TS engine** (`ts/init.lua`):

```lua
-- Factory: create a make_outline function from a query definition.
M.make_outliner(query_def) -> function(lines, buf_name, bufnr?) -> outline_table

-- Factory: assemble a complete mode table from a query def + template.
M.build_mode(lang) -> { make_outline, new_headline, do_body_after_oop, capabilities }
```

`build_mode` is intentionally a thin factory — it loads the query
definition for `lang`, looks up a template (falling back to
`voom.ts.templates.code`), and wires them together. Adding a new
language only requires a query file and an optional template file; no
changes to the engine itself.

### Key design decisions

1. **`make_outline` gains an optional `bufnr` parameter.** When present, the
   engine calls `vim.treesitter.get_parser(bufnr, lang)` directly. When absent
   (unit tests, paste from clipboard), it creates a temp scratch buffer, sets
   the lines, parses, extracts, and deletes the buffer. This preserves full
   backward compatibility — every existing test continues to pass without
   modification.

2. **Programming language levels use structural nesting depth**, not
   indentation. The engine walks `node:parent()` counting ancestor nodes that
   are themselves outline-worthy (class/function/method definitions). Top-level
   constructs = level 1, nested = level 2+, clamped at 6.

3. **Code modes disable structural editing.** `new_headline` returns nil,
   `do_body_after_oop` is nil. A `capabilities` table lets `oop.lua` skip
   operations that don't apply (insert, promote, demote). Move and cut still
   work since they just rearrange body lines.

4. **Fallback when TS parser is missing.** `make_outliner` catches parser
   creation errors, notifies the user (`:TSInstall <lang>`), and returns a
   valid empty outline. The tree pane renders empty — no crash.

## Work Items

Each work item is a single committable unit. Items within a phase are
sequential; phases are sequential (later phases depend on earlier ones).
`TREESITTER.md` must be updated as each work item is completed so the
document always reflects current progress.

Status markers:
- `[done]` work item completed and committed
- `[next]` next work item to execute
- `[todo]` not started yet

---

### Phase 1: Treesitter engine and Markdown query

#### WI-1 [done]: Golden-master test harness (red phase)

**File:** `test/spec/ts_markdown_spec.lua`

Write the golden-master tests *before* the TS implementation exists.
These tests establish the expected output by running the existing regex
parser on every Markdown fixture and recording its `bnodes`, `levels`,
`tlines`, `use_hash`, and `use_close_hash`. They then attempt to run the
TS parser and assert identical output. At this stage the TS require will
fail or be skipped — the tests are red.

For each existing Markdown test fixture (find them in `test/fixtures/`):
1. Load the fixture lines.
2. Run the regex parser: `require("voom.modes.markdown").make_outline(lines, name)`.
3. Run the TS parser: `require("voom.ts").build_mode("markdown").make_outline(lines, name)`.
4. Assert `bnodes` arrays are identical.
5. Assert `levels` arrays are identical.
6. Assert `tlines` arrays are identical.
7. Assert `use_hash` and `use_close_hash` match.

Also add unit tests for the TS engine (these will also be red initially):
- Parsing from a lines array (temp buffer path).
- Parsing from a real buffer (bufnr path).
- Empty document produces empty outline.
- Document with no headings produces empty outline.

**Important:** These tests are the primary safety net for the migration.
Writing them first ensures the implementation target is unambiguous.

#### WI-2 [done]: Create the TS engine (`lua/voom/ts/init.lua`)

Create the core Treesitter abstraction that all modes will use.

**File:** `lua/voom/ts/init.lua`

Implement:

- `parse_buffer(bufnr, lang)` — get parser and parse tree from a live buffer.
- `parse_lines(lines, lang)` — create temp scratch buffer, set lines, attach
  parser, parse, return tree + temp bufnr. Caller is responsible for cleanup
  after extraction (since `vim.treesitter.get_node_text` needs the buffer
  alive).
- `make_outliner(query_def)` — returns a `make_outline(lines, buf_name, bufnr?)`
  function. Internally:
  1. Parse via `parse_buffer` or `parse_lines` depending on whether `bufnr` is
     provided.
  2. Compile and run the query from `query_def.query_string`.
  3. Collect all captures into a list of `{ id, node }` tuples.
  4. Call `query_def.extract(captures, query, src_bufnr)` to get entries.
  5. Sort entries by `lnum`.
  6. Build parallel arrays `tlines`, `bnodes`, `levels` from entries. Tree
     display format: indent based on level (2 spaces per level), then ` · `,
     then the heading name — matching the existing format from
     `tree.lua:build_tree_lines`.
  7. Call `query_def.outline_state(entries, lines)` for style hints.
  8. Clean up temp buffer if one was created (see cleanup note below).
  9. Return the standard outline table.

**Outline table wire format:** `state.lua:update()` reads `use_hash` and
`use_close_hash` as **top-level keys** on the outline table returned by
`make_outline` (see `state.lua:124-128`). The TS engine must return them
at the top level — not nested under an `outline_state` sub-table — or
`state.lua` will silently ignore them and `new_headline` /
`do_body_after_oop` will receive stale style preferences.

**Temp buffer cleanup:** If `extract()` or the outline-building steps
throw an error, the temp scratch buffer will leak. Wrap the extract +
build sequence in `pcall` and delete the temp buffer in all code paths
(success and failure). Leaked scratch buffers are a real usability
problem in Neovim — this is the one place where defensive cleanup is
warranted.

**Incremental parsing:** `parse_buffer` should call `parser:parse()`
without a force flag so it benefits from Neovim's incremental parsing
cache. On the `BufWritePost` re-parse path (`tree.lua:1580`), the TS
subsystem will already have an up-to-date tree if the buffer was parsed
previously.
- `build_mode(lang)` — load `voom.ts.queries.<lang>` and
  `voom.ts.templates.<lang>` (falling back to `voom.ts.templates.code`),
  assemble and return the mode table.

**Note on `tlines` construction:** The current `tree.lua:build_tree_lines()`
function constructs display lines from the outline *after* `make_outline`
returns. The TS engine's `make_outline` should return raw `tlines` in the same
format the regex parsers use (level-based indent prefix + ` · ` + heading text),
since `build_tree_lines` then truncates them to window width. Look at
`tree.lua:build_tree_lines` to match the exact format.

#### WI-3 [done]: Create the Markdown query definition (`lua/voom/ts/queries/markdown.lua`)

**File:** `lua/voom/ts/queries/markdown.lua`

The query must handle:

- **ATX headings** (levels 1-6): Match `atx_heading` nodes. The level is
  determined by the marker child type (`atx_h1_marker` through `atx_h6_marker`).
  Extract heading text from the `heading_content` child (or from the inline
  node within it).

  ```scm
  (atx_heading) @heading
  ```

  In `extract()`, inspect children to find the marker node and determine level
  from its type name (parse the digit from `atx_h<N>_marker`). Get the heading
  content text, stripping leading/trailing whitespace.

- **Setext headings** (levels 1-2): Match `setext_heading` nodes. The level is
  determined by the underline child (`setext_h1_underline` for `=`,
  `setext_h2_underline` for `-`).

  ```scm
  (setext_heading) @heading
  ```

  In `extract()`, inspect children for the underline node type.

`extract(captures, query, bufnr)` implementation:
- Iterate captures where the capture name is `"heading"`.
- For each heading node, walk its children to find the marker/underline node.
- Derive level from the child node type.
- Get heading text via `vim.treesitter.get_node_text()` on the content child,
  or fall back to reading the buffer line and stripping the markers.
- Return `{ level = N, name = "heading text", lnum = start_row + 1 }`.

`outline_state(entries, lines)` implementation:
- Scan entries to find the first level-1 or level-2 heading.
- Check whether it was ATX or setext style (can store this in the entry during
  extraction, or re-inspect the original line).
- For ATX headings, check whether the line has closing `#` characters.
- Return `{ use_hash = bool, use_close_hash = bool }`.

**Edge cases to handle** (match current regex parser behavior):
- Empty headings (`# ` with no text after the marker)
- Headings with trailing hashes (`## Foo ##`)
- Setext headings where the underline is the only content on the line
- Lines inside fenced code blocks should NOT be matched — TS handles this
  correctly since code blocks are separate node types, but verify.

#### WI-4 [done]: Create the Markdown template (`lua/voom/ts/templates/markdown.lua`)

**File:** `lua/voom/ts/templates/markdown.lua`

Extract from `lua/voom/modes/markdown.lua`:
- Constants: `LEVELS_ADS`, `ADS_LEVELS`
- Helper: `is_adornment(s)`
- Function: `new_headline(outline_state, level, preceding_line)`
  (lines 213-237 of current file)
- Function: `do_body_after_oop(...)` and all its internal helpers
  (lines 278-481 of current file: `change_setext_lev`, `to_atx`,
  `to_setext`, the main `do_body_after_oop` function)
- Helper: `update_bnodes` (line 186 of current file)
- `capabilities = { insert = true, promote = true, demote = true, move = true, cut = true, paste = true, sort = true }`

This is a mechanical extraction — the logic does not change, only the file it
lives in.

At this point, the golden-master tests from WI-1 should go green. All
four work items (WI-1 through WI-4) must pass before Phase 2.

---

### Phase 2: Wire Treesitter Markdown as the default

#### WI-5 [done]: Update `make_outline` call sites to pass `bufnr`

**Files:**
- `lua/voom/tree.lua:1468` — change `mode.make_outline(lines, buf_name)` to
  `mode.make_outline(lines, buf_name, body_buf)`
- `lua/voom/tree.lua:1580` — same change
- `lua/voom/oop.lua:703` — no change needed; this calls
  `mode.make_outline(p_blines, "")` on clipboard lines with no buffer, which
  correctly uses the temp-buffer fallback path

The third parameter is optional, so this change is backward-compatible with
any mode that ignores it.

#### WI-6 [done]: Switch the Markdown mode registry entry to TS

**File:** `lua/voom/modes/init.lua`

Change:
```lua
markdown = function()
  return require("voom.modes.markdown")
end,
```
To:
```lua
markdown = function()
  return require("voom.ts").build_mode("markdown")
end,
```

The old `lua/voom/modes/markdown.lua` remains in the repo (still used by
golden-master tests and as documentation) but is no longer loaded at runtime.

**Verification:**
- Full test suite passes (including integration tests in `tree_spec.lua`,
  `oop_spec.lua`, `voom_spec.lua`).
- Manual: open a Markdown file, run `:Voom markdown`, verify the outline.
  Promote/demote a heading, verify format changes are correct.

---

### Phase 3: Remove Current AsciiDoc Support

#### WI-7 [done]: Remove AsciiDoc support from nvim-voom

Remove AsciiDoc entirely for now instead of attempting a Treesitter port.
This narrows the migration to Markdown plus programming-language modes and
avoids carrying an unmaintained parser path during the transition.

Completed:
- removed the AsciiDoc mode loader and filetype auto-detection
- deleted the AsciiDoc mode, fixture, and dedicated spec file
- updated docs and completion/init tests to reflect the temporary removal

**Files:**
- `lua/voom/modes/asciidoc.lua`
- `lua/voom/modes/init.lua`
- `lua/voom/init.lua`
- `test/spec/asciidoc_spec.lua`
- `test/spec/voom_spec.lua`
- `README.md`
- `doc/voom.txt`
- any fixture or test helper files that only exist for AsciiDoc coverage

Tasks:
1. Remove the AsciiDoc mode loader from `lua/voom/modes/init.lua`.
2. Remove any filetype-to-mode detection that maps `asciidoc` or `asciidoctor`
   to `asciidoc`.
3. Delete the AsciiDoc regex mode implementation and its dedicated tests.
4. Update user-facing docs to state that AsciiDoc support is temporarily
   removed and will be revisited later.
5. Run the full test suite and clean up any assumptions that AsciiDoc is still
   a supported mode.

---

### Phase 4: Programming language modes

#### WI-8 [next]: Create the shared code template (`lua/voom/ts/templates/code.lua`)

**File:** `lua/voom/ts/templates/code.lua`

```lua
return {
  new_headline = nil,          -- inserting code constructs via tree pane is not supported
  do_body_after_oop = nil,     -- no format normalization for code
  capabilities = {
    insert = false,
    promote = false,
    demote = false,
    move = true,
    cut = true,
    paste = false,
    sort = true,
  },
}
```

#### WI-9 [todo]: Add capability checks to `oop.lua`

**File:** `lua/voom/oop.lua`

Guard each mutating operation in `oop.lua` by checking `mode.capabilities`
before proceeding. The capability is read from the mode table returned by
`resolve_mode()` — no changes to `state.lua` are needed since `mode` is
already resolved at each call site.

The mapping from capability to `oop.lua` function:

| Capability | Guard function(s)                    | Why                                    |
|------------|--------------------------------------|----------------------------------------|
| `insert`   | `do_insert_node`                     | Needs `new_headline` to create content |
| `promote`  | `do_move_left`                       | Needs `do_body_after_oop` to rewrite markers |
| `demote`   | `do_move_right`                      | Same as promote                        |
| `paste`    | `do_paste`                           | Needs `new_headline` for pasted nodes  |
| `move`     | `do_move_up`, `do_move_down`         | Rearranges body lines only             |
| `cut`      | `do_cut`                             | Rearranges body lines only             |
| `sort`     | `do_sort`                            | Rearranges body lines only             |

Guard pattern (same for each):

```lua
if mode.capabilities and not mode.capabilities.insert then
  vim.api.nvim_echo(
    { { "VOoM: insert is not supported for " .. mode_name .. " mode", "WarningMsg" } },
    true, {}
  )
  return
end
```

For code modes, `move`, `cut`, and `sort` are enabled (they only rearrange
body lines without format-aware mutations). `insert`, `promote`, `demote`,
and `paste` are disabled (they require generating or rewriting language
constructs).

#### WI-10 [todo]: Python query definition

**File:** `lua/voom/ts/queries/python.lua`

Query captures:
- `class_definition` with `name: (identifier)`
- `function_definition` with `name: (identifier)`
- `decorated_definition` wrapping either of the above

Level derivation in `extract()`: walk `node:parent()`, count ancestors that are
themselves `class_definition`, `function_definition`, or `decorated_definition`.
Top-level = 1.

Display name: For classes, use `class ClassName`. For functions, use
`def function_name(...)` (include parameter list or just `(...)`).

**Test fixture:** `test/fixtures/sample.py` with classes, top-level functions,
methods, nested functions, decorated functions.

**Test file:** `test/spec/ts_python_spec.lua` — verify levels, bnodes, names.

#### WI-11 [todo]: Lua query definition

**File:** `lua/voom/ts/queries/lua.lua`

Query captures:
- `function_declaration` with `name: (identifier)` or `name: (dot_index_expression)`
- `local_function` (Neovim's Lua TS grammar may call this
  `function_definition_statement` depending on version — verify)
- Assignment-based functions: `variable_declaration` or `assignment_statement`
  where the value is a `function_definition`

Level derivation: same parent-walking approach.

Display name: function name (e.g., `M.setup`, `local helper`).

**Test fixture:** `test/fixtures/sample.lua`
**Test file:** `test/spec/ts_lua_spec.lua`

#### WI-12 [todo]: Ruby query definition

**File:** `lua/voom/ts/queries/ruby.lua`

Query captures:
- `class` with `name: (constant)`
- `module` with `name: (constant)`
- `method` with `name: (identifier)`
- `singleton_method` with `name: (identifier)`

Level derivation: parent-walking, counting `class`, `module`, `method` ancestors.

Display name: `class ClassName`, `module ModName`, `def method_name`.

**Test fixture:** `test/fixtures/sample.rb`
**Test file:** `test/spec/ts_ruby_spec.lua`

#### WI-13 [todo]: Go query definition

**File:** `lua/voom/ts/queries/go.lua`

Query captures:
- `function_declaration` with `name: (identifier)`
- `method_declaration` with `name: (field_identifier)` and
  `receiver: (parameter_list)`
- `type_declaration` containing `type_spec` with `name: (type_identifier)`

Level derivation: Go has no nesting (all at package level), so:
- Type declarations (struct, interface) = level 1
- Methods with a receiver whose base type matches a captured type declaration =
  level 2 under that type. Receiver matching must strip pointer indicators
  (e.g., `*Type` → `Type`) before comparing against the type name.
- Interface method signatures = level 2 under the interface type
- Package-level functions = level 1

Display name: `func FuncName`, `func (r Type) MethodName`, `type TypeName`.

**Test fixture:** `test/fixtures/sample.go`
**Test file:** `test/spec/ts_go_spec.lua`

#### WI-14 [todo]: Register programming language modes

**File:** `lua/voom/modes/init.lua`

Add entries:
```lua
python = function() return require("voom.ts").build_mode("python") end,
lua    = function() return require("voom.ts").build_mode("lua") end,
ruby   = function() return require("voom.ts").build_mode("ruby") end,
go     = function() return require("voom.ts").build_mode("go") end,
```

Add filetype auto-detection: when `:Voom` is called without an explicit
mode argument, derive the mode name from the buffer's `filetype`. If a
mode with that name exists in the registry, use it; otherwise fall back
to the current error message. This eliminates the need for users to type
`:Voom python` when the buffer filetype already tells us the answer.

Filetype-to-mode mapping for cases where filetype differs from mode name
(e.g., `plaintex` → none) can be a simple lookup table in
`modes/init.lua`; for the initial four languages the filetype string
matches the mode name exactly (`python`, `lua`, `ruby`, `go`).

---

### Phase 5: Remove regex parsers

#### WI-15 [todo]: Convert golden-master tests to snapshot tests

Before deleting the regex parsers, convert the golden-master comparison
tests (from WI-1) into **snapshot tests**. Run the regex
parser one final time on every fixture and hardcode its `bnodes`,
`levels`, `tlines`, `use_hash`, and `use_close_hash` as literal tables
in the test files. The tests then assert the TS output matches these
frozen snapshots instead of requiring the regex modules at runtime.

This preserves the regression safety net after the regex parsers are
deleted.

#### WI-16 [todo]: Delete remaining regex parser modules

- Delete `lua/voom/modes/markdown.lua`
- Remove any remaining `require("voom.modes.markdown")` or
  `require("voom.modes.asciidoc")` calls from test files (the snapshot
  conversion in WI-15 and the AsciiDoc removal in WI-7 should have eliminated
  them).
- Update any tests that relied on internal regex parser details (e.g.,
  `M.ADS_LEVELS`) to use the template equivalents.
- Verify the full test suite passes with no references to the deleted files.

---

## Risks

| Risk | Mitigation |
|------|------------|
| TS markdown grammar produces different results from regex on edge cases (e.g., setext heading detection, blank-line sensitivity) | Golden-master tests (WI-1) catch all differences before switchover |
| Removing AsciiDoc support may surprise existing users | Call out the temporary removal clearly in docs as part of WI-7 |
| TS parser not installed for a language | Engine returns empty outline + user notification |
| `vim.treesitter` API differences across Neovim versions | Target Neovim 0.10+; document minimum version requirement |
| `outline_state` detection (use_hash, use_close_hash) harder via TS | Read raw heading lines with `get_node_text`; small amount of string inspection on identified heading lines is acceptable |

## Verification

After each work item:
1. `nvim --headless -u test/minimal_init.lua -c "lua MiniTest.run()"`
2. Update `TREESITTER.md` to mark the completed work item before moving on
3. For Markdown mode changes: manual smoke test with `:Voom markdown`; verify promote/demote/move
4. For code mode additions: manual smoke test with `:Voom python` etc.; verify outline nesting is correct
