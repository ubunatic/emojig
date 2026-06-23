<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue #35 — Color Overhaul & Container/Controls Styling System

**Status:** Closed (Implemented)

---

## Summary

Implemented a comprehensive color and container styling system, centralizing all margins, layout backgrounds, settings/text pane backgrounds, hlines, scrollbar rails, and search bar dividers under [spec/theme.json](file:///home/uwe/projects/emojig/spec/theme.json). This eliminates hardcoded default styling colors and allows clean semantic themes to be defined entirely in configuration files. Also resolved a search ranking degradation on the popped cork emoji `🍾` caused by greedy matching on `"glass"` aliases, and silenced xterm-256 color schema warning pollution on stderr at runtime by logging them to `/tmp/emojig.log` instead.

---

## Features Implemented

### 1. Extended Palette Specification (`spec/theme.schema.json` & `spec/theme.json`)
* Configured the JSON schema to support new semantic color fields.
* Defined default color properties in [spec/theme.json](file:///home/uwe/projects/emojig/spec/theme.json):
  * `app_bg`: Overall margins/canvas background.
  * `app_topline_bg`: First line (top padding or top border) background.
  * `emoji_pane_bg`: Emoji grid viewport background.
  * `scrollbar_rail_bg`: Gutter background behind the scrollbar thumb.
  * `view_bg`: Overlay background for text pages (help, about, categories, settings, status).
  * `search_left_cap_fg`: Left cap (`▌`) foreground.
  * `search_right_cap_fg`: Right cap (`▐`) foreground.
  * `search_sep_fg`: Search capsule separator (`│`) foreground.
  * `hline_fg`: Horizontal separator lines (`─`) foreground.

### 2. Palette Resolver & Escape Sequence Compilation (`src/spec.zig`)
* Updated the `Palette` struct and `buildPalette` loader in [src/spec.zig](file:///home/uwe/projects/emojig/src/spec.zig#L510-L658) to resolve the new JSON color configuration parameters into ANSI escape sequences with appropriate default fallbacks (e.g. defaulting view backgrounds to `app_bg` if undefined).
* Replaced hardcoded escape sequence constants with dynamic palette members: `palette.app_bg`, `palette.app_topline_bg`, `palette.emoji_pane_bg`, `palette.scrollbar_rail_bg`, `palette.view_bg`, `palette.search_left_cap`, `palette.search_right_cap`, `palette.search_sep`, and `palette.hline`.

### 3. TUI Rendering Refactoring (`src/main.zig`)
* Styled top/bottom margins, borders, and blank spacer lines using `palette.app_topline_bg` and `palette.app_bg`.
* Refactored the search bar row drawing logic to place the left cap (`▌`) and right cap (`▐`) using custom foreground colors on the search bar background, blending seamlessly with the app canvas.
* Updated horizontal line rendering, switcher borders, popups, and the status row to pull styling from the parsed palette instead of terminal/grid defaults.
* Styled the scrollbar rails in the grid and page views using `palette.scrollbar_rail_bg`.

### 4. Silencing Runtime Warnings (`src/spec.zig`)
* Conditionally guarded color schema compatibility warnings using `@import("builtin").is_test` in [src/spec.zig](file:///home/uwe/projects/emojig/src/spec.zig#L136-L140).
* Mismatched hex colors (like `#2c2c2c`) now print warnings to `stderr` only during unit tests to guide developers, but write silently to [term.appendLog](file:///home/uwe/projects/emojig/src/term.zig#L132) at runtime to prevent polluting the user's terminal.
