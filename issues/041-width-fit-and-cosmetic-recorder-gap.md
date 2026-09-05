<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "Prove GUI character-grid geometry independent of legacy font-size assumptions"
status: open
priority: p2
---

# 041 - Prove GUI character-grid geometry independent of legacy font-size assumptions

**Status**: Open
**Priority**: P2 (Medium)
**Severity**: Moderate
**Category**: Architecture
**Related**: —

---

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

The historical recording path converted an assumed font size into fixed pixel
dimensions and then forced those dimensions through the compositor. That is not
a measurement of the terminal's actual glyph-cell metrics. Depending on the
font, scaling, decorations, and compositor, the real terminal could expose a
different row/column count than Emojig requested. Too few rows caused clipping
and misplaced cursors; excess columns caused unused padding. Hand-tuned
`app_width`/`app_height` values only hide the mismatch for one environment.

`height_guard=fit` is a valuable runtime mitigation, and absolute cursor
addressing removes one failure mode, but neither proves that GUI launch sizing
is correct. The issue is therefore not merely cosmetic: we need measured proof
that the requested character grid, the real terminal geometry, and the rendered
row positions agree without relying on legacy font-size assessment.

## Historical solution directions

These remain implementation options, not substitutes for the proof below:

1. **Accept extra width after proving geometry safety.** Extra columns may be an
   intentional policy, but only after the verifier distinguishes them from an
   accidental font-metric mismatch and confirms row/cursor correctness.
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
   in emojig. The proof must still measure the resulting TTY rather than trust
   the calculation.

## Required proof for closure

- Launch the real `emojig --gui` path and obtain the child terminal's actual
  rows and columns from the PTY/TTY after the compositor has applied the window
  geometry. Do not infer them solely from pixels or configured font size.
- Assert that the effective grid and chrome row budget match those measured
  dimensions, including top padding, search, grid, description/info, switcher,
  status/footer, optional border, and any active pane rows.
- Correlate the measured TTY geometry with a captured GUI frame so a correct
  ioctl value cannot mask clipped, duplicated, shifted, or padded physical rows.
- Exercise at least two materially different GUI font sizes and both light and
  dark themes. The test must not use per-case hand-tuned pixel dimensions as its
  oracle.
- Include an undersized case that proves `height_guard=fit` selects the expected
  effective row count, plus an exact-fit case that proves no guard adjustment is
  needed.
- Fail on missing/extra physical rows, unexpected columns, wrapping, clipping,
  cursor displacement, or unexplained right/bottom padding.
- Store the reel/fixture, geometry capture, and assertions in the repository and
  expose one non-interactive command with a non-zero failure exit.
- Demonstrate that the proof fails when the legacy fixed-pixel/font-size
  assumption is deliberately restored, or against a preserved failing fixture.
- Document terminal, font, font size, scale factor, requested grid, measured TTY
  geometry, captured pixel dimensions, effective grid, and result.

The pixel checks required by issue 50 may share the same capture, but geometry
and background-color assertions must remain separately reported so one cannot
accidentally stand in for the other.

## Recommendation

Build the proof harness before choosing further app-side or recorder-side
resizing behavior. The measurements should show whether the durable correction
belongs in Emojig, Wayreel, or both. Until that evidence exists, fixed pixel
sizes are test setup rather than a correctness oracle.
