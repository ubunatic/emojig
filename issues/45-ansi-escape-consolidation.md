<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: done
---

# ANSI escapes: `main.zig` still hand-rolls cursor/clear/mode sequences

**Priority: P2**

## Summary

The project already has the right shape for this: `src/color.zig` owns
color/SGR building (`bgEscape`, `buildSgr`) and `src/term.zig` owns some
shared sequence constants (`RESTORE`, `RESTORE_ALT`, `MOUSE_OFF`). But
`main.zig` contains **145 raw `\x1b[` literals**, and color/SGR escapes are
mostly properly routed through `color.zig` while **cursor movement, line
clearing, and terminal-mode toggles are still hand-rolled inline** in many
places — exactly the "should be exactly one function per ANSI concern"
smell called out in the review brief.

Concrete violations found:

- **`clearTuiRows`** (`main.zig` ~244–304) hand-builds `\x1b[{d};1H`,
  `\x1b[2K`, `\x1b[B\r` via raw `bufPrint`/`memcpy` into a stack buffer —
  no shared helper — and this logic is itself **duplicated** against the
  near-identical scroll-repositioning code at ~1198–1321 (`scroll_seq`,
  `move_up_seq`, `up_seq`, `abs_seq`, `clear_seq`, `down_seq`, all hand
  building `\x1b[{d}A\r` / `\x1b[{d};1H` variants).
- **Mode toggles** at ~1340–1356: raw literals
  `"\x1b[?1049h\x1b[?7l"`, `"\x1b[?12h\x1b[?25l\x1b[?1004h"` inline,
  instead of named constants — contrast with `term_lib.MOUSE_OFF`, which
  *is* a shared constant and *is* used correctly at ~1247.
- **Cursor hide / focus tracking**: `"\x1b[?25l"` (~1118, ~1662),
  `"\x1b[?1004h"` (~1123) — raw literals; no `term_lib.CURSOR_HIDE`
  equivalent exists yet.
- **Bold/attr toggles** at ~1824–1825 (`"\x1b[1m"`/`"\x1b[22m"`) and
  ~3990 region — ad hoc, not routed through `color.zig`'s SGR builder
  (which *is* used correctly elsewhere, e.g. ~2897).
- **Clear-line-then-write**: `"\x1b[2K\r"` appears **25+ times** as a raw
  literal immediately followed by content — no `clearLine()`/`beginRow()`
  helper exists to pair with the `RowWriter.endRow`/`endRowFull` that
  already exist for the *end* of a row.
- **Scrollbar column jump**: `\x1b[{d}G` constructed ad hoc at 6
  duplicated call sites (same sites as the scrollbar duplication in
  [issue 44](44-main-zig-decomposition.md)) rather than via a shared
  `moveToCol(col)` helper.
- One legitimate one-off: `\x1b[6n` (cursor-position report query, ~1247)
  is raw but commented and genuinely single-use — not a violation.

## Proposed fix

Extend `src/term.zig` (or a new small `src/ansi.zig` if `term.zig` is felt
to be about terminal *state* rather than *escape building*) with:

- `clearLine()` — the `"\x1b[2K\r"` pattern, used at all 25+ sites.
- `moveTo(row, col)` / `moveToCol(col)` — replaces the hand-built
  `\x1b[{d};1H` / `\x1b[{d}G` sequences in `clearTuiRows`, the scroll
  repositioning block, and the 6 scrollbar sites.
- `cursorHide()` / `cursorShow()` — pairs with the existing (correct)
  hide/show usage, replaces raw `"\x1b[?25l"` literals.
- Named constants for the altscreen/bracketed-paste/focus-tracking mode
  toggle strings currently inlined at ~1340–1356 and ~1118–1123.

This is best tackled *together* with the `main.zig` decomposition in
[issue 44](44-main-zig-decomposition.md) — several of the raw-escape sites
(scrollbar rendering, row clearing) are inside the same code being
extracted to `src/panes.zig`/`src/tui_draw.zig` there, so doing the ANSI
cleanup as part of that extraction avoids touching the same lines twice.

## Not done in this pass

This is a multi-site mechanical refactor across a 4800-line file with no
existing test coverage asserting exact escape-sequence byte output for
most of these paths (only the null-color "punch-through" contract in
`docs/SpecDrivenConfig.md §13` has such coverage, for `color.zig`, not
`term.zig`). Given the "small fixes only, write up the rest" instruction
for this review pass, this is left for a dedicated follow-up rather than
attempted piecemeal here, since touching `clearTuiRows` or the mode-toggle
sequences incorrectly risks the exact class of bug §2 of AGENTS.md exists
to prevent (leaving the terminal in a broken state on exit/panic). Any
agent picking this up should add a byte-level assertion test (e.g. via
`scripts/test_tui`'s PTY harness capturing raw output) *before* refactoring
each call site, not after.

## Resolution (2026-07-02)

Applied as a mechanical, behavior-preserving refactor. `src/term.zig` gained
a dedicated "ANSI escape sequences" block — one named constant / helper per
concern, each **byte-tested first** (two new test blocks assert the exact
emitted bytes, incl. the §2-critical RESTORE/RESTORE_ALT parts):

- Constants: `CURSOR_HIDE/SHOW/BLINK/SHOW_BLINK/HOME`, `ALT_SCREEN_ON`,
  `WRAP_OFF`, `FOCUS_ON`, `CLEAR_LINE`, `CLEAR_LINE_CR`, `CR_CLEAR_LINE`,
  `CLEAR_BELOW`, `CLEAR_SCREEN`, `CURSOR_DOWN_CR`, `BOLD`/`BOLD_OFF`,
  `REVERSE`/`REVERSE_OFF`.
- Formatter helpers: `moveToRow`, `moveTo`, `moveToCol`, `cursorUpCr`,
  `scrollUp`, plus comptime `FMT_*` fragments for concatenation into larger
  format strings (e.g. `FMT_MOVE_TO_COL ++ "{s}"` at the 6 scrollbar sites).

All concrete violations listed above were converted in `main.zig`:
`clearTuiRows`, the startup scroll-reservation block, the defer-cleanup
clear loop, the mode-toggle block (alt-screen/wrap/blink/hide/focus), the
cursor hide/focus-tracking writes, the cursor-reposition `cursor_seq` blk,
the resize/redraw moves, the `RowWriter` down-step, the dropdown/category
bold toggles, and the scrollbar column-jump format strings. Raw `\x1b[`
literal count in `main.zig`: **145 → 42**; the remainder is input *parsing*
(`\x1b[I`/`\x1b[O` focus reports), the documented one-off `\x1b[6n` CPR
query, `\x1b[K`/`\x1b[0m` row-termination/SGR-reset bytes interleaved with
palette content (a color.zig concern, out of scope here), and two `\x1b[1G`
column-1 jumps kept literal next to their `FMT_CURSOR_UP` concatenation.

Test wiring note: `term.zig` belongs to the *exe* module (`main.zig` root),
so its tests are referenced from a `test { _ = @import("term.zig"); }`
block at the bottom of `main.zig` — importing it from `root.zig` fails with
"file exists in modules 'root' and 'emojig'". Side effect: the exe test
binary now actually runs tests (3, incl. `color.zig`'s previously-dormant
test); the total went 79 → 82.

Verified: `zig build test -Doptimize=ReleaseSafe -Dllvm=false` 82/82,
`go test ./scripts/test_tui/` ok, screenshot frame unchanged (caps/seps/
search bar render identically).
