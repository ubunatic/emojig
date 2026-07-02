<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: done
---

# Flaky PTY test: TestTUIRenderedLineWidthsAreEqual fails ~50% on main

**Priority: P2** (test reliability — fails `make preflight` intermittently)

## Summary

`scripts/test_tui/line_width_test.go` (`TestTUIRenderedLineWidthsAreEqual`)
fails intermittently with:

```
line_width_test.go:54: painted row width mismatch: row 0 has width 33, expected 34
```

Measured on 2026-07-02 with back-to-back `go test ./scripts/test_tui/
-count=1` runs (binary pre-built, otherwise idle machine):

- `main` (b111be2): **4 of 8 runs failed**
- issue-47 branch: 1 of 8 runs failed

So this is a pre-existing flake, independent of the issue-47 search change.
It fails `make preflight` roughly every other run, which trains everyone to
ignore preflight failures.

## Analysis

The test spawns the TUI in a PTY (8×10 grid, `content_width = 8*4+1 = 33`,
plus scrollbar column ⇒ expected painted width 34), types `zzzzzz`, and
validates every painted row of the parsed screen has width 34. Row 0 (the
blank top padding row) intermittently parses as width 33.

The test already has a retry loop (5 attempts, re-collecting late PTY bytes)
guarding against a *mid-stream* cut, but the bad frame is stable across
retries — so the mismatch is in what the app actually emitted for row 0 in
that frame, or in how `vt.go`'s `TerminalState.Parse` accumulates two
overlapping redraws (initial render + query redraw are concatenated into one
byte stream before parsing).

Likely suspects, unverified:

- A race between the initial render and the `zzzzzz` redraw: the write can
  land before the first frame finished, interleaving escape sequences.
- `collectScreenBytes` window (500 ms) cutting between the two frames in a
  way the retry loop can't heal because the *first* frame was already
  truncated (retries only append, never re-collect the beginning).
- Row 0 being a padding row that the app repaints with a different width
  when the redraw path takes the "row unchanged" shortcut.

## Suggested fix directions

- Wait for a render-complete sentinel (e.g. the cursor-position sequence the
  app emits last) before writing the query, instead of a fixed 500 ms
  collection window.
- Or validate only the *final* frame: track the last full-screen repaint
  (cursor-home / clear sequence) and parse from there, so a truncated first
  frame can't poison the result.
- Re-run the 8× loop after any fix on an otherwise idle machine to confirm
  0 failures.

## Related flake (same family)

`TestTUISettingsHelpModalFromSpec` also fails intermittently under
full-suite load ("settings screen did not open" — the captured frame shows
the search screen, i.e. the menu-open keystroke landed before the app was
ready), while passing 4/4 in isolation (`-run TestTUISettingsHelpModalFromSpec`,
measured 2026-07-02). Any fix that replaces fixed sleep/collect windows
with a render-complete sentinel should be applied to both tests.

## Resolution (2026-07-02)

The root cause was in the harness, not (only) the app:
`collectScreenBytes` waited for the *first* PTY chunk, then drained only
what was instantly available (`default:` in the select) — a mid-render
pause under load cut the frame anywhere, producing truncated rows,
missed screen transitions, and keystrokes sent before the app finished
painting. The fix makes collection quiescence-based: after the first
chunk it keeps reading until the stream has been idle for 100 ms
(3 s hard cap so an animating screen can't stall a test). This fixed
both flakes at once and applies to all 19 call sites.

Making frames deterministic exposed two real app bugs the racy
collection had been masking, both fixed:

- **Top padding row painted 1 cell short** (`main.zig`): it painted
  `max_w` (= `content_width`) background cells while every other row
  paints `content_width + 1` (gutter/caps + scrollbar column) — the
  actual source of the "row 0 has width 33, expected 34" message. Now
  paints `max_w + 1` and ends with `endRowFull` (full-width rows must
  skip `\x1b[K`, which fired from the pending-wrap position erases the
  last column in exact-width windows).
- **Settings rows could overflow the content area** (`main.zig`): long
  value+label combos ("[default #2c2c2c]  app background" = 36 cols)
  exceeded the 33-col budget on narrow grids; now clipped via
  `truncateAnsi` to gutter + content width, gated on the same
  `dropdown.overflow: hidden` spec knob as the other truncation sites.

Also: `ValidatePaintedRowWidths` now reports *all* mismatching rows in
one error, and the dead `drainTransitionBytes` helper was removed.

Verified: `go test ./scripts/test_tui/` 8/8 green back-to-back (was
~4/8 failing on main); the standalone `go run ./scripts/test_tui`
suite now passes end-to-end (it failed on main even before subtest 7d);
`zig build test` and `zig fmt --check src/` clean.

## Open observations — resolved 2026-07-02 (issue 44 item 1 pass)

- **Subtest 7d did not exercise the dropdown — confirmed and fixed.**
  The suspicion was right, and the cause was deeper than a missing
  assertion: the batched `/s\n` Enter landed before the first
  autocomplete render computed `cmd_matches`, so it was a no-op; the
  following `\x1b[B` then selected autocomplete item 0 and the final
  `\n` is what actually opened settings — the subtest validated a plain
  settings screen (and silently toggled shell integration) every run.
  Now each keystroke gets a render cycle (quiescence collect between
  writes, no sleeps) and the subtest asserts the dropdown caveat text
  ("leaves C-e free") is on screen.
- **Settings-row 33-vs-34 width unified** during the issue-44 pane
  extraction: settings/categories/cmd-/cat-autocomplete item rows now
  pad to `content_width + 1` via `tui_draw.padRowTail`. Guarded by the
  new `TestTUISettingsRowWidthsAreEqual` and a `ValidatePaintedRowWidths`
  check in visual subtest 7a.
