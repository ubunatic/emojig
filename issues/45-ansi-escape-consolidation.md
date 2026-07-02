<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: open
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
