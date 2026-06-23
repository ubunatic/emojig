<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue 30 — Compact Grid Mode (EMOJIG_COMPACT=1)

**Status**: Closed (Implemented — 2026-06-23)  
**Priority**: P2

---

## Problem

Users requested a denser 3-column cell grid layout (Compact Grid Mode) instead of the default 4-column layout. Implementing this required:
1. Support for toggling the compact layout via the `:settings` screen and environment variable `EMOJIG_COMPACT=1`.
2. Redesigning cursor bracket rendering to fit inside 3 columns (where one column is prefix and two columns are body/emoji, leaving no space for an in-cell closing bracket `cr`).
3. Correcting cell and window width sizing to prevent the scrollbar from clipping or overwriting the rightmost cell's boundary.
4. Preserving emoji rendering for characters with variation selectors (VS15/VS16) when hovered on the dense grid.

---

## Solution

1. **Config & Env Integration**:
   - Added parsed `compact` configuration to [src/config.zig](file:///home/uwe/projects/emojig/src/config.zig).
   - Updated [src/host.zig](file:///home/uwe/projects/emojig/src/host.zig) to propagate the `EMOJIG_COMPACT` environment variable and compute the window sizes.
2. **TUI Settings Screen**:
   - Added the togglable `compact grid` setting at index 8 of the settings list, shifting MRU history clear to index 9.
   - Tied compact grid settings to `griddim_changed` so a warning note `· next launch` is shown in the settings footer.
3. **Shared Boundary Cursor Brackets**:
   - In compact mode, the closing bracket `cr` (`⌟`) of cell `c - 1` is drawn in the prefix slot of cell `c` (if `is_prev_marker` is active).
4. **Width Tuning & Gutter Space**:
   - Adjusted `final_width` calculation in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) to `base_cols * 3 + 2` in compact mode (adding 1 leading column and 1 trailing remainder column) to prevent the scrollbar from overlapping the right edge cell bracket.
   - Sync'd this calculation in `width_val` in [src/host.zig](file:///home/uwe/projects/emojig/src/host.zig).
5. **Color Merging for Variation Selectors**:
   - Fixed emoji vanishing bugs (affecting `✈️`, `⚙️`, `8️⃣`, `☺︎`, `✳︎`, etc.) by merging the rendering of `prefix` and `body` in compact mode when `prefix_bg` and `body_bg` are identical. This eliminates intermediate `\x1b[0m` (reset) and re-color sequences immediately preceding the base emoji character which were breaking terminal variation selector combining logic.
6. **Scrollbar Column Alignment**:
   - Adjusted window character columns in [src/host.zig](file:///home/uwe/projects/emojig/src/host.zig) from `width_val + 2` to `width_val + 1` and `is_too_small` checks in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) to `< content_width + 1` so that the scrollbar sits exactly at the terminal's last column `w` instead of `w - 1`.
   - Switched row ending calls to `rw.endRowFull()` when scrollbars are drawn to prevent erase-line (`\x1b[K`) commands from clearing the scrollbar glyph at the last column.
