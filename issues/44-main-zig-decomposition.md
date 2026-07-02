<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: open
---

# `main.zig` decomposition: it regrew into one 4098-line function

**Priority: P2** (readability/maintainability, not correctness)

## Summary

Issue 37 (closed) extracted `src/cli.zig`, `src/input.zig`, `src/render.zig`
out of `main.zig`. Since then `main.zig` regrew to **4834 lines**, and
critically: `pub fn main()` itself now runs from line 737 to 4834 —
**4098 lines, one function, zero helpers extracted after it starts**. Every
other `src/*.zig` file stayed under ~900 lines. All render-dispatch and
event-loop logic for every `ScreenState` lives inside this one function
body, nested up to 8–10 levels deep in places.

This makes `main.zig` hard to use as a "table of contents" for agents: to
fix a settings-screen bug, or a category-switcher bug, or a debug-pane bug,
an agent has to navigate deep into one giant function instead of jumping to
a dedicated file.

## Decomposition candidates (highest value first)

1. **Doc-screen render dispatch → new `src/panes.zig`.** The render
   branches for `help`/`about`/`status`/`debug`/`settings`/`categories`
   (`main.zig` ~2022–2450, ~430 lines) are six near-identical arms: each
   computes `viewport_h = rows + 3`, `needs_scroll`, `max_scroll_*`,
   `thumb_h`, `travel_*`, `thumb_start` (the same 6-line scrollbar formula,
   copy-pasted 6×: ~2089–2096, ~2148–2155, ~2218–2225, ~2265–2272, ~2603,
   ~2832), then draws lines via the same clear-line-then-write pattern
   (`"\x1b[2K\r"`, 25+ occurrences across this region and elsewhere). This
   is both the biggest duplication cluster and the highest-value single
   extraction: collapsing to one parameterized `renderPane(pane_lines,
   scroll_top, rows, ...)` function removes ~300+ duplicate lines and cuts
   `main.zig` by roughly 10%.
2. **Debug pane model → new `src/debug_pane.zig`.** `DebugCtx`,
   `debugLineCount`, `debugValue`, `debugLine` (`main.zig` ~515–653) are
   already close to pure (buffer + id + ctx → formatted string) but
   `DebugCtx` is only ever constructed inline inside the debug render
   branch (~2264), so there's no way to unit-test debug-line formatting
   without driving the whole TUI. Move the type + functions, construct
   `DebugCtx` at the call site, and add direct tests.
3. **Settings screen key handling → new `src/settings_ctl.zig`.**
   Dropdown open/close, grid-dim ‹/› typing and click handling, keybind
   text-input editing, and toggle dispatch (~3350–3420, ~4241–4430) belong
   next to `render.renderSettingRow` (already in `src/render.zig`) rather
   than in the event loop.
4. **Category switcher → new `src/switcher.zig`.** `swPrefix`,
   `bgOnlyFromPattern`, `swRenderSlot` (~2906, ~2919, ~2985) are defined as
   **local closures re-created every render pass** — pure string/color
   logic with no possible unit test today. Hoist to real functions.
5. **Mouse dispatch → new `src/mouse.zig`.** Wheel/motion/click/drag
   routing per screen (~3727–4090, nesting 8+ deep: `if event → if wheel →
   if screen → if row-in-range → if col-in-range → ...`) is pure
   coordinate-to-action geometry buried in the event loop. `src/input.zig`
   currently only covers key decode — this is its natural counterpart.
6. **Key-name dispatch → table-driven, inside existing `src/input.zig`.**
   The 38-branch `if (std.mem.eql(u8, name, "..."))` chain (~4188–4830)
   is a textbook `std.StaticStringMap`/table candidate.
7. **`RowWriter` local struct → hoist into `src/tui_draw.zig`.** Defined
   inline at ~1793, used throughout the render loop; `tui_draw.zig` already
   owns line-rendering helpers (`renderPaneLine`) with a divergent
   signature — worth reconciling into one write-a-row abstraction.
8. **`clearTuiRows`/`sigHandler`/`panic` terminal-restore trio (~244–343)
   → `src/term.zig`**, which already owns `RESTORE`/`RESTORE_ALT`.

## Other duplication found

- `theme_str` switch (`.dark => "dark"`, etc.) was hand-duplicated at two
  render sites even though `themeName()` already exists at `main.zig:190`
  — **fixed directly in this pass**, see below.
- Scrollbar-cell rendering block (`sb_buf` bufPrint variants) repeated
  6× — see item 1 above.

## Testability gaps (beyond what's listed above)

- Scrollbar-viewport math (`needs_scroll`/`max_scroll_*`/`thumb_h`/
  `travel_*`/`thumb_start`) is copy-pasted 6× with no standalone function
  and no test. Extracting item 1 above makes this directly unit-testable.
- Mouse hit-zone → action mapping is pure geometry with no test coverage
  because it's inline in the event loop (see item 5).

## Fixed in this pass

Replaced the two hand-duplicated `theme_str` switches (`main.zig` former
~2136–2140 and ~2196–2200) with calls to the existing `themeName(theme)`
helper. Verified with `zig build test -Doptimize=ReleaseSafe -Dllvm=false`
(exit 0, same pass/fail state as before the change).

## Progress (2026-07-02 late, item 1 done)

Item 1 (pane render dispatch) is extracted: `tui_draw.zig` gained
`RowWriter` (hoisted from `main()` — the item-7 half that render code
needs), `PaneEnv`, `renderScrollPane` (help/about/status/debug), and
`renderListPane` (settings/categories, incl. the shared `padRowTail`),
all with pipe-based byte tests. `main.zig` keeps only thin per-pane line
sources (`LinesPane`/`VarLinesPane`/`TemplateLinesPane`/`DebugLinesPane`/
`SettingsListPane`/`CategoriesListPane`) that turn a line/item index into
content. Behavior changes folded in deliberately:

- **Settings/categories/cmd-/cat-autocomplete item rows now pad to the
  full `content_width + 1`** like every other screen (the issue-48
  off-by-one); `TestTUISettingsRowWidthsAreEqual` and a
  `ValidatePaintedRowWidths` call in visual subtest 7a now guard it.
- **Full-width pane rows end with `endRowFull`** (no `\x1b[K`), applying
  the issue-48 pending-wrap rule to the doc panes; leading
  `CLEAR_LINE_CR` still clears each row.
- **Visual subtest 7d now actually opens the dropdown** and asserts its
  content ("leaves C-e free"): the old script batched `/s\n`, whose
  Enter landed before the first autocomplete render computed
  `cmd_matches` and was a no-op — the subtest had been validating a
  plain settings screen (and toggling shell integration) all along.

Observed during verification: the issue-47 benchmark regression guard
(2 ms/query) flaked twice when both test binaries ran their benchmarks
concurrently under `zig build test` (measured ~0.45 ms alone; parallel
runs pushed one binary over 2 ms). **Fixed** in the item-2 pass: the
bound now also scales with the measured empty-query baseline
(`max(2ms, 50 × ns_empty)`) — uniform load inflates both sides, a
return of the linear synonym scan only inflates the left side.

## Progress (2026-07-03, item 2 done)

Item 2 (debug pane model) extracted to **`src/debug_pane.zig`**:
`SearchStats`, `DebugCtx`, `lineCount`, `value`, `line`, and the
`DebugLinesPane` source moved there with direct unit tests (line walk,
value formatting, percentile math). Decoupling from main: `DebugCtx`
gained a `spec: *const spec_mod.Spec` field (no `g_spec` global access)
and stores a pre-resolved `screen_name` string instead of main's
`ScreenState` enum. `themeName` moved to `term.zig` (next to `Theme`);
`categorySynonymCount`/`disabledCategoryCount` moved along (spec-param
form); `switcherCatCount` lives in debug_pane temporarily and should
move to `switcher.zig` when item 4 creates it.

## Earlier progress (2026-07-02, partial)

The 6× copy-pasted scrollbar cluster from item 1 is extracted to
`src/tui_draw.zig`: `paneScroll()` computes the shared viewport/thumb
geometry (`needs_scroll`/`max_scroll`/`thumb_h`/`travel`/`thumb_start`/
`pos_eighths`) and `scrollbarSeq()` builds the per-row scrollbar escape
sequence for both `.expand` and `.bar` styles. All six call sites in
`main.zig` (help/about/status/debug panes + the two grid arms) now use
them, closing the "no standalone function and no test" gap noted under
Testability — both helpers have byte-exact unit tests, wired into the exe
test module via `test { _ = @import("tui_draw.zig"); }` in `main.zig`
(which also revived a dormant `config.zig` test whose `stepGridDim`
sub-min expectation had drifted from the implementation and is now
corrected). `main.zig` drops ~130 lines. The full pane-render extraction
(one parameterized `renderPane`) and items 2–6 remain open.

## Suggested order for a follow-up agent

Do decomposition **one file at a time**, in the priority order above,
each as its own PR: extract, keep `main.zig` calling the new module,
run `zig build test` + `go run ./scripts/test_tui`, then move to the next.
Item 1 (pane render dispatch) is the best first PR — biggest line-count
win, least behavioral risk (pure refactor, no logic change).

## What the next agent needs to know (state as of 2026-07-02 evening)

- **Where to put extracted render code**: `src/tui_draw.zig` is the
  established home for pure render helpers (`paneScroll`, `scrollbarSeq`,
  `truncateAnsi`, `ansiDisplayWidth`, `renderPaneLine`,
  `scrollbarThumb`/`scrollbarCell`, `smoothScrollPos`). `src/render.zig`
  holds settings-row rendering. Prefer extending these over inventing the
  `src/panes.zig` from item 1 unless the extraction is big enough to
  warrant its own file.
- **Test wiring**: a file's tests only run if it is reachable from a test
  root. `main.zig` ends with `test { _ = @import("term.zig");
  _ = @import("tui_draw.zig"); }` — add any newly extracted file there
  (a file may only belong to one Zig module, hence the exe-module test
  block). Beware: wiring a previously-unwired file can revive dormant
  tests whose expectations drifted (happened with `config.zig`'s
  `stepGridDim` test — the code was right, the dead test was wrong).
- **RowWriter contract** (critical when moving row-emission code): every
  row starts with `term_lib.CLEAR_LINE_CR` and ends with `rw.endRow()`
  (resets + `\x1b[K`) *unless* the row paints the full width
  (`content_width + 1` cells) — then it must use `rw.endRowFull()`,
  because `\x1b[K` fired from the pending-wrap cursor position erases the
  last column in exact-width GUI windows. Violating this caused the
  issue-48 padding-row bug.
- **Row width invariant**: search-screen rows paint exactly
  `content_width + 1` display cells (1-col gutter or left cap + content +
  scrollbar/right-cap column). `ValidatePaintedRowWidths` in
  `scripts/test_tui/vt.go` enforces this for the search screen. Known
  unvalidated off-by-one: settings rows pad only to `content_width`
  *including* their gutter (`main.zig` ~2300, `pad_len = content_width -
  vis_w` where `vis_w` counts the gutter), so they paint 33 cells where
  other screens paint 34. Decide during extraction whether to unify (and
  then extend the validator to non-search screens).
- **Verification is now trustworthy** (issue 48 fixed): `go test
  ./scripts/test_tui/` is stable (8/8 back-to-back) and the standalone
  `go run ./scripts/test_tui` visual suite passes end-to-end — run both
  plus `zig build test -Doptimize=ReleaseSafe -Dllvm=false` and
  `zig fmt --check src/` after each extraction. PTY frame collection is
  quiescence-based (`collectScreenBytes`: 100 ms idle, 3 s cap), so new
  PTY tests should not add `time.Sleep` sync hacks.

See also [issue 45](45-ansi-escape-consolidation.md) (raw ANSI escapes in
this same code, found during the same review) and
[issue 46](46-spec-yaml-reorg-and-test-as-spec.md) (spec/ organization).
