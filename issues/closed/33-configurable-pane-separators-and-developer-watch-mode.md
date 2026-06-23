<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue #33 — Configurable Pane Separators & Developer watch-run Mode

**Status:** Closed (Implemented)

---

## Summary

Implemented runtime customizability for the horizontal pane-separating lines in the TUI, moving the separator character from a hardcoded constant to the declarative specification. Also added a developer-focused `watch-run` task to automatically rebuild/recompile and launch the GUI app on changes to any source or spec files.

---

## Features Implemented

### Configurable Pane Separator (`spec/strings.json`)
- Added `"hline_char": "─"` to [spec/strings.json](file:///home/uwe/projects/emojig/spec/strings.json#L61).
- Added `hline_char: []const u8 = "─"` to the `Strings` struct in [src/spec.zig](file:///home/uwe/projects/emojig/src/spec.zig#L277) to act as a fallback value for localized strings and parser default.
- Replaced the compile-time `const hlines = "─" ** 512;` constant in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig#L1651) with a dynamically initialized stack buffer (`var hlines_buf: [2048]u8`). The buffer is populated at runtime with repetitions of the configured `hline_char` or a `"─"` fallback.
- Replaced hardcoded byte width assumptions (`current_w * 3`) with dynamically computed width limits (`current_w * hline_unit_len`) across all three separator lines (Search/Grid, Grid/Switcher, Switcher/Description) in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) to ensure correct character-width alignment for single-byte, multi-byte, or empty separator strings.

### Watch-Run Development Flow
- Created [scripts/watch_run.sh](file:///home/uwe/projects/emojig/scripts/watch_run.sh) to recursively find the last modified timestamp under `src/` and `spec/` (along with `Makefile`, `build.zig`, and `build.zig.zon`) and recompile/install on changes.
- Upon successful compilation, the script automatically triggers the GUI app (`make gui`).
- Integrated the target as `watch-run` in the [Makefile](file:///home/uwe/projects/emojig/Makefile#L47).
