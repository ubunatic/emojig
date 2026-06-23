<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue 31 — Configurable Scrollbar and Padding with Viewport Clamping Fix

**Status**: Closed (Implemented — 2026-06-23)  
**Priority**: P2

---

## Problem

1. The scrollbar character was hardcoded to `"▐"`, preventing customization via `spec/strings.json`.
2. When the category switcher bar is enabled (`visible_rows = rows - 1` due to switcher drawing), the scrollbar never reached the bottom row of the grid screen. This was caused by the safety-net clamp for `grid_scroll_top` utilizing the full `rows` value instead of `visible_rows` when determining `max_top`, forcing the scroll-top viewport offset to clamp 1 row too early.
3. The TUI/GUI always started with a blank top padding row, which was hardcoded and not configurable.

---

## Solution

1. **Configurable Scrollbar Character**:
   - Added `scrollbar_char` (default `"▐"`) to the [Strings](file:///home/uwe/projects/emojig/src/spec.zig#L248) struct in [src/spec.zig](file:///home/uwe/projects/emojig/src/spec.zig).
   - Added `"scrollbar_char": "▐"` configuration to [spec/strings.json](file:///home/uwe/projects/emojig/spec/strings.json#L57).
   - Replaced all hardcoded `"▐"` scrollbar glyph references in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) with `g_spec.strings.scrollbar_char`.

2. **Viewport Clamping Fix**:
   - Updated the safety-net clamp logic for `grid_scroll_top` in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig#L1734-L1740) to clamp using `visible_rows` instead of `rows`. This allows the scrolling offset to correctly reach the bottom rows (touching the bottom edge) when the category switcher is visible.

3. **Configurable Top Padding**:
   - Added `"top_padding": false` option (defaulting to `true`) in [spec/layout.json](file:///home/uwe/projects/emojig/spec/layout.json#L13).
   - Added `top_padding` to the [Layout](file:///home/uwe/projects/emojig/src/spec.zig#L57) struct in [src/spec.zig](file:///home/uwe/projects/emojig/src/spec.zig).
   - Dynamically adjust `layout_overhead` in [src/spec.zig](file:///home/uwe/projects/emojig/src/spec.zig#L420-L424) (subtracting 1) if `top_padding` is disabled, ensuring correct height calculations across the application.
   - Updated search bar, grid first row, scrollbar drag absolute row, and search row cursor parking coordinates in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) to compute row coordinates dynamically based on `top_padding`.
   - Bypassed rendering of the blank top padding row in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) if `top_padding` is disabled.
