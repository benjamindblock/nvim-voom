# REFACTOR: Consistent Edit, Refresh, Render, and State Flow

## Summary
This refactor should make the plugin's internal flow explicit and consistent without changing any public behavior.

The core target is a single private flow for tree-driven structural edits:

1. Resolve the current body/tree/mode/outline context.
2. Compute the body mutation for the command.
3. Apply the body write in a way that preserves current undo behavior.
4. Rebuild outline state and redraw the tree from that outline.
5. Sync persisted state such as `changedtick` and `snLn`.
6. Restore selection, cursor, focus, and any command-specific follow-up behavior.

The public plugin API, commands, keymaps, and user-visible behavior must remain unchanged.

## Public API / Interface Constraints
- No user-facing command changes (`:Voom`, `:VoomToggle`, `:VoomGrep`, `:VoomSort`, `:Voominfo`, `:Voomlog`, `:Voomhelp`).
- No breaking changes to existing public Lua module entrypoints (`require("voom")`, `require("voom.tree")`, `require("voom.oop")`, `require("voom.state")`).
- Internal helper additions are allowed, but do not turn internal coordination helpers into new de facto public APIs.

## Internal Invariants To Preserve
- The body buffer is the source of truth. Outline data and tree rendering are always derived from the body.
- Tree rendering is rebuilt from outline data; commands should not manually patch tree lines after structural edits.
- Tree line `k` maps directly to outline index `k` (`bnodes[k]`, `levels[k]`).
- `snLn` is the persisted selected tree line for a body buffer.
- `changedtick` stays in sync after tree-triggered body mutations so refresh-on-reentry stays correct.
- Focus changes and cursor placement are explicit command outcomes, not incidental side effects of refresh.
- Existing early-return and no-op behavior for invalid or impossible operations must remain unchanged unless current behavior is already user-visible and incorrect.

## Ordered Work Items

1. **Lock the current contract with characterization tests** — COMPLETE (012a7bc)
- Contract test suite added in commit 012a7bc ("Expand refactor contract coverage"):
  - `oop_spec.lua` (1642 lines): all OOP operations including insert, cut, copy, paste, move, promote, demote, sort.
  - `tree_spec.lua` (1652 lines): rendering, navigation, undo/redo, changedtick refresh.
  - `voom_spec.lua` (331 lines): init/toggle/grep/voominfo.
  - `fold_indicators_spec.lua` (634 lines): fold rendering, indent guides, count badges.
  - `markdown_spec.lua` (584 lines): heading parsing.
  - `edge_cases.md` fixture for deep nesting, mixed depths, empty sections, sibling boundaries.
- Remaining gaps (non-blocking):
  - `:Voomlog` behavior is not yet covered by contract tests.
  - `edit_node` (i/I) cursor placement and focus transitions could use additional edge-case coverage.
- The refactor gate is met: the expanded suite is green and covers all user-visible command behavior.

2. **Add a shared OOP test harness before production changes** — COMPLETE
- Shared harness added in `test/helpers.lua` with:
  - Buffer helpers: `load_fixture`, `make_scratch_buf`, `del_buf`.
  - Window helpers: `find_win_for_buf`, `find_tree_lnum_by_text`, `open_float_win`.
  - State cleanup: `cleanup_registered_bodies`, `clean_hooks`.
  - Echo/notify capture: `with_captured_echo`, `with_captured_notify`.
  - Fixture documents: `simple_doc`.
  - High-level setup: `setup_tree` (body/tree/cursor in one call).
  - Keypress helper: `press`.
  - Reusable assertions: `assert_focused_buf`, `assert_cursor`, `assert_snLn`,
    `assert_changedtick_synced`, `assert_changedtick_changed`, `assert_body_lines`,
    `assert_body_unchanged`, `assert_body_has_line`, `assert_outline_levels`,
    `assert_tree_mutation_state` (combined post-mutation contract check).
- All five spec files migrated to `local H = dofile("test/helpers.lua")`:
  - `oop_spec.lua`: all duplicated helpers removed, inline window-find loops replaced, cleanup hooks replaced with `H.clean_hooks()`.
  - `tree_spec.lua`: duplicated helpers removed, inline window-find loops replaced, per-buffer cleanup hooks replaced with `H.clean_hooks()`.
  - `voom_spec.lua`: duplicated helpers removed, cleanup hooks simplified.
  - `fold_indicators_spec.lua`: duplicated helpers removed.
  - `markdown_spec.lua`: duplicated `load_fixture` removed.
- Remaining vestigial `_body_buf`/`_tree_buf` assignments in tree_spec and voom_spec test bodies are harmless dead stores that can be cleaned up in a follow-on pass.
- Full test suite (192 cases) passes with zero failures after migration.

3. **Add `get_mode` and migrate production code off direct `state.bodies` access** — COMPLETE
- Added `get_mode(body_buf)` to `voom.state`.
- Replaced all 9 direct `state.bodies[body_buf]` accesses in production code:
  - `oop.lua` (7 places): each now uses `state.get_mode(body_buf)` instead of `entry.mode`.
  - `tree.lua` (1 place, `update()`): now uses `state.get_mode` and `state.get_tree` instead of `entry.mode` and `entry.tree`.
  - `init.lua` (`voominfo`): now uses `state.get_tree`, `state.get_snLn`, `state.get_outline`, and `state.get_mode` instead of direct entry field access.
- No direct `state.trees[` access exists in production code; no migration needed for that table.
- All 192 contract tests pass with zero failures after migration.

4. **Define the internal flow and result contract before extracting helpers** — COMPLETE
- Six-phase private flow documented in `oop.lua` header comment block:
  1. Resolve command context (body_buf, outline, outline_state, mode, tree_win, tlnum).
  2. Compute the body mutation (pure data transformation, no side effects).
  3. Write the body (via `write_body()` or `nvim_buf_set_lines`).
  4. Refresh outline and tree (via `refresh_after_edit()`).
  5. Restore selection and cursor (command-specific target_tlnum, optional body focus).
  6. Command-specific follow-up (echo messages, clipboard updates).
- Private `OopResult` contract defined in `oop.lua` header:
  - `refresh`      — whether tree refresh is needed (bool).
  - `target_tlnum` — tree line to select after refresh (int|nil).
  - `focus`        — "tree" or "body" disposition after the operation.
  - `body_cursor`  — { lnum, col } target when focus == "body" (nil otherwise).
  - `echo`         — optional status message chunks for nvim_echo.
- Selection policies documented per command (cut, paste, move, promote/demote, insert, sort).
- Contract is private to `oop.lua` — not exposed through `voom.oop`, `voom.state`, or any other public API.
- All 192 contract tests pass with zero failures.

5. **Separate OOP operations into real families before refactoring internals** — COMPLETE
- Three operation families separated in `oop.lua` with dedicated section headers:
  - **Tree-context read-only navigation**: `edit_node` — resolves tree context and transfers focus without mutating buffers.
  - **Tree-context structural edits**: `insert_node`, `cut_node`, `copy_node`, `paste_node`, `move_up`, `move_down`, `promote`, `demote` — all mutate the body through the tree panel following the six-phase flow.
  - **Buffer-context sort**: `sort` — accepts either a body or tree buffer and keeps its own context resolution path.
- Added shared `resolve_tree_ctx(tree_buf)` helper that resolves body_buf, outline, tree_win, tlnum, and total_body — used by all tree-initiated commands (both navigation and structural edits).
- Mutating commands resolve outline_state and mode locally because their nil-check policies differ per command (some guard at the call site, others early-return). This avoids introducing a universal context object that would create more special cases than it removes.
- `sort` retains its own entry path (resolves body from tree, looks up tree_buf from body).
- All 192 contract tests pass with zero failures after migration.

6. **Extract shared read-only helpers for derived tree data** — COMPLETE
- New `lua/voom/tree_utils.lua` module with three shared read-only helpers:
  - `find_win_for_buf(buf)` — window lookup by buffer, previously duplicated in `tree.lua`, `oop.lua`, and reimplemented inline in `init.lua`.
  - `heading_text_from_tree_line(line)` — heading text extraction, previously private in `tree.lua` and replicated inline in `init.lua` (`grep` and `voominfo`).
  - `tree_lnum_for_body_line(bnodes, cursor_line)` — tree line lookup from body line, previously private in `tree.lua` (exposed for cross-module use).
- Consumers updated:
  - `tree.lua`: imports all three helpers from `tree_utils` via local aliases (drop-in replacement for the former module-private functions).
  - `oop.lua`: imports `find_win_for_buf` from `tree_utils`, removing its duplicate definition.
  - `init.lua`: uses `tree_utils.find_win_for_buf` in `init()` and `log_init()`, and `tree_utils.heading_text_from_tree_line` in `grep()` and `voominfo()`, replacing all inline reimplementations.
- Module is strictly read-only — no coupling to structural edit logic.
- All 192 contract tests pass with zero failures.

7. **Extract shared OOP primitives around context resolution and body writes**
- Acknowledge existing local helpers in `oop.lua` that already handle some of this work:
  - `write_body(body_buf, lines)` (line 122): writes replacement body lines inside `nvim_buf_call` to preserve undo segmentation.
  - `refresh_after_edit(body_buf)` (line 114): calls `tree.update` and syncs `changedtick`.
  - These should be promoted to shared internal helpers rather than rewritten from scratch.
- Add small internal helpers for remaining recurring work:
  - Resolve body/tree/mode/outline/tree window for tree-context operations.
  - Resolve outline/tree window for sort.
  - Compute subtree body ranges and target tree lines.
  - Resolve a tree line from a body line after refresh when a command needs to land on a new node.
- Keep command-specific structure readable:
  - Each command should still visibly express its own intent.
  - Selection and cursor semantics should remain obvious at the command site.
- Avoid a monolithic helper that hides the full control flow.

8. **Extend `refresh_after_edit` into a full post-write coordinator**
- `refresh_after_edit(body_buf)` already exists as a local function in `oop.lua` (line 114), handling `tree.update` and `changedtick` sync. Extend it rather than creating a new coordinator.
- Add support for the remaining post-write mechanics:
  - Post-refresh tree-line resolution when selection must move.
  - Tree cursor restoration.
  - Optional body cursor restoration and focus transfer.
- Keep per-command finalize behavior local where semantics differ:
  - Commands that keep the same node selected should say so explicitly.
  - Commands that move selection to a new node should compute and pass the target policy explicitly.
  - Commands that jump into the body and place the cursor on placeholder text should keep that final targeting local to the command, while still using the shared refresh coordinator.
- Preserve current behavior exactly, including focus changes and cursor placement.

9. **Refactor tree-context structural edits incrementally**
- Refactor `insert`, `cut`, `copy`, `paste`, `move_up`, `move_down`, `promote`, and `demote` one command at a time.
- For each command:
  - Use the narrow state API (already migrated in step 3) for all state reads.
  - Move body-write mechanics and post-refresh mechanics onto the shared helpers.
  - Keep command-specific mutation math and mode-specific normalization inputs local.
- After each command:
  - Re-run the relevant spec subset.
  - Confirm no drift in clipboard behavior, undo/redo semantics, fold refresh timing, selection behavior, and focus behavior.
- Do not batch all tree-context commands into a single large edit; keep each step reviewable.

10. **Refactor `sort` separately**
- Keep `sort` on its own path because its entry semantics differ from tree-initiated edits.
- Share only the helpers that fit naturally:
  - Outline lookup.
  - Body rewrite.
  - Tree refresh and changedtick sync.
  - Selection restoration where the behavior is truly shared.
- Preserve current semantics around sibling-group discovery, sorting options, and cursor/selection behavior.

11. **Add explicit state test helpers and migrate tests**
- Replace test cleanup loops that iterate `state.bodies` directly with explicit helpers designed for tests or low-level inspection.
- Keep test support narrow and intentional:
  - Examples: iterate known body buffers, clear registered bodies in tests, inspect a specific body entry through a dedicated helper, or inspect structural history through a test-only helper.
- Avoid leaving raw mutable tables as the easiest path for tests, or contributors will keep depending on the wrong abstraction boundary.

12. **Define invariant handling precisely**
- Add internal consistency checks only where the behavior is explicitly defined:
  - Use production-safe guards where current behavior is a silent early return.
  - Use stricter assertions only in tests or clearly internal debug-only code paths.
- Do not add runtime checks that throw, notify, or otherwise change visible behavior unless the existing code already does so.

13. **Run final parity verification**
- Re-run the full automated test suite after:
  1. State migration (step 3).
  2. Tree-context OOP refactor completion (step 9).
  3. `sort` refactor completion (step 10).
  4. State test helper migration (step 11).
- Manually verify high-value interactive flows:
  - Opening and closing the tree.
  - Tree navigation and body sync.
  - Each OOP edit command, including `edit_node` focus/cursor transitions.
  - Undo and redo from the tree side.
  - Fold indicators after edits and refreshes.
  - `:VoomGrep`.
  - `:Voominfo`.
  - `:Voomlog`.
- Confirm unchanged public behavior and simpler internal contributor paths before considering follow-on cleanup.

## Test Plan
- Use contract tests to lock user-visible behavior, not incidental internal details.
- Add regression tests for every bug found during the refactor.
- Prefer focused tests around command behavior, selection/focus behavior, tree/body parity, documented display output, and state synchronization.
- Acceptance criteria:
  - Same public commands and Lua entrypoints.
  - Same user-visible tree/body behavior.
  - Same quickfix, selection, cursor, undo/redo, and refresh behavior.
  - Production modules no longer depend on `state.bodies` directly (no production code accesses `state.trees` today).
  - Mutating tree commands follow one consistent private flow for write, refresh, state sync, and UI restoration.

## Assumptions and Defaults
- Existing user-visible behavior, including edge-case quirks, is the source of truth.
- Internal implementation may change freely if the public contract remains stable.
- The internal edit-flow contract and result shape are private helpers, not public APIs.
- `sort` remains a separate refactor path because its entry semantics differ from tree-driven edit commands.
- State encapsulation should reduce coupling, not replace one broad internal bag-of-fields API with another.
- Contributor readability is a first-class goal: prefer small explicit helpers over large generic abstractions.
