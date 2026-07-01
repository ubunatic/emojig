<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "Width side of height_guard resilience is still missing (cosmetic gap in gui.json recording)"
status: open
priority: p3
---

# 41 - Width side of height_guard resilience is still missing

**Status:** Open
**Priority:** P3

## Background

While chasing a persistently misplaced cursor in the `spec/reels/gui.json`
recording (root-caused to a nested-sway/wayreel window-sizing mismatch — see
`docs/HeadlessRecording.md` and `../wayreel/issues/01-gui-window-scaling.md`),
emojig gained real resilience against a terminal being **shorter** than the
grid it was launched to draw:

- `config.HeightGuard` (`off`/`strict`/`fit`, default `fit`), settable via
  `--height-guard=`, `EMOJIG_HEIGHT_GUARD`, or the `height_guard=` config key.
- `fit` mode shrinks the live grid row count to whatever actually fits
  (floor: `defaults.MIN_ROWS`), instead of silently drawing more rows than the
  terminal has and desyncing the cursor-reposition math.
- `strict` mode (and `fit` when even the minimum doesn't fit) falls back to
  the existing width-only "too small" UI.
- Alt-screen cursor repositioning now uses absolute addressing
  (`\x1b[{row};{col}H`) instead of relative "move up N rows" math, removing
  the specific desync mechanism entirely for `--gui`/altscreen sessions.

## Problem

This only covers the **height** axis. After the fix, the `gui.json` recording
still shows extra unused columns on the right of the emojig window — the
window is **wider** than the grid needs at the configured `cols`/font size.
`is_too_small` already has a pure width check (`current_w < content_width + 1`)
that triggers the "too small" fallback when the terminal is *narrower* than
needed, but there's no equivalent "shrink to fit" behavior for a terminal that
is *wider* than needed — extra width is just left as blank padding.

This is purely cosmetic (no cursor/functional bug), but it means reel authors
(or anyone whose GUI host doesn't grant an exact-fit window) still have to
hand-tune pixel sizes to avoid a visibly padded window, same as the height
problem did before this round of fixes.

## Possible directions

1. **Do nothing / accept it.** Extra width is harmless and cheap to work
   around per-reel (adjust `app_width` down). Given `height_guard=fit` already
   solves the *functional* bug class (misplaced cursor), this may not be worth
   more app-side complexity.
2. **Mirror `height_guard` for width**: an analogous `width_guard` (or fold
   both into one `size_guard` covering both axes) that shrinks `cols` when the
   terminal is wider than configured... but shrinking cols doesn't help with
   *extra* width the way shrinking rows helps with *insufficient* height —
   there's no "too much room" failure mode to fix, just wasted space. A more
   useful version would let the grid **grow** into extra width/height when
   available (opt-in, since `--gui` currently pins an exact size on purpose so
   the host window matches `EMOJIG_COLS`/`EMOJIG_ROWS`).
3. **Recorder-side**: teach wayreel to auto-size the sub-app window from the
   target grid's actual font metrics (Option B in
   `../wayreel/issues/01-gui-window-scaling.md`) rather than fixing anything
   in emojig. Probably the better home for a purely cosmetic recording-pipeline
   gap.

## Recommendation

Leans toward option 3 (recorder-side) or just accepting the cosmetic gap
(option 1) — emojig growing/shrinking its *own* rendered grid to opportunistically
fill extra terminal width doesn't have an obvious "correct" behavior (unlike
the height case, where "shrink to what fits" is unambiguous), and the actual
bug class (misplaced cursor) is already fixed. Revisit if this keeps costing
reel-authoring time.
