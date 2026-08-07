<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: fixed
---

# BG color leaking in GUI grid and category bar

**Priority: P2** (visual artifact in primary GUI mode)

## Summary

In `--gui` mode (foot + Twemoji CBDT), the host terminal background color bleeds
through in several areas instead of the configured `bg`/`search_bg` palette colors.

Screenshot saved to `issues/50-bg-color-leaking-in-gui.png` — annotations pending from user.

## Annotated screenshot

See `issues/50-bg-color-leaking-in-gui.png` (red boxes mark leak sites).

## Known affected areas (from annotated screenshot)

Three distinct leak sites, all at the window edges:

1. **Bottom-left corner** — dark rectangle bleeding into the description/status row,
   left side. Appears as a solid dark block at column 0 of that row.
2. **Right edge of category bar** — dark vertical block at the far-right column of
   the category bar row (next to the `[ ▶ ]` cursor bracket area).
3. **Bottom-right corner** — same dark block continues one row lower, into the
   status/help row at the right edge.

All three are narrow vertical rectangles, suggesting a scrollbar thumb or bracket
cursor glyph is being painted at the wrong row/column — or that the rightmost and
leftmost cells of the bottom rows are not being cleared with the correct background
color before rendering.

## Expected behavior

All cells inside the picker window should be filled with the configured palette
background. No host-terminal background or stray glyph remnants should be visible
at the window edges.

## Root cause (confirmed)

Three distinct bugs, all in row termination:

1. **Description row — leading space in default bg**: `CLEAR_LINE_CR` was called with
   no explicit bg set, so the terminal's default bg filled col 0. Fix: emit `palette.info_bg`
   immediately after `CLEAR_LINE_CR` so the leading space is painted in `info_bg`.

2. **Status bar — leading space in `app_bg` (wrong shade)**: the leading `" "` was
   prefixed with `palette.app_bg` (index 236) while the rest of the row used
   `palette.status_bg` (index 238), creating a 1-cell darker rectangle at the left edge.
   Fix: change the leading write from `palette.app_bg` to `palette.status_bg`.

3. **Pending-wrap `\x1b[K` erase (issue #48 recurrence)**: description row, status bar,
   and switcher row all filled exactly `content_width + 1` cells and then called `endRow`,
   whose `\x1b[0m\x1b[K` from the pending-wrap cursor position erased the rightmost cell
   with default bg. Fix: all three rows now call `endRowFull` instead. The switcher fill
   was also extended by 1 to reach `content_width + 1`.

## Files changed

- `src/main.zig` — description row (pre-clear bg, `endRowFull`), status bar
  (leading space bg, `endRowFull`)
- `src/switcher.zig` — fill extended +1, `endRowFull`
- `src/switcher.zig` — test updated to expect `endRowFull` terminator
- `src/host.zig` — detection-order test updated (`foot` now first per spec/host.yaml fix)
