<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue #32 — Search Bar Toolbar: Hamburger Menu, Separator & End Cap

**Status:** Closed (Implemented)

---

## Summary

Extended the search bar toolbar (right side of the search row) with three features:

1. **`≡` hamburger menu icon** — opens/closes the Settings screen; toggling click behavior.
2. **Configurable `toolbar_sep`** — separator string between toolbar buttons, driven by `terminal_bg2` color.
3. **`▐` search bar end cap** — half-block character creating a smooth visual transition from the search bar into the terminal background.

Along the way a **critical rendering bug** was fixed: the search bar row was using `endRow()` which emits `\x1b[K` and silently erases the end cap character in exact-width GUI windows.

---

## Features Implemented

### Hamburger menu icon (`≡`)
- `spec/theme.json` `icons.menu` field added.
- Rendered as the rightmost clickable icon in the toolbar.
- Click on `≡` when search is active → open Settings; click when Settings is open → close (return to search).
- Hover over `≡` → description row shows `"Settings"` label.
- `spec/commands.json` — added `menu` (short: `mn`) and `hamburger` (short: `hb`) as aliases for `:settings`, improving discoverability via the command bar.

### Hover labels for toolbar icons
- Hover over `🌙`/`🌞`/`🔆` theme icon → description row shows `"theme: dark"` / `"theme: light"` / `"theme: system"`.
- Hover over `≡` → description row shows `"Settings"`.
- Implemented as the first branch of the description-row `if/else` chain (checked before switcher-hover and emoji-hover).

### Configurable `toolbar_sep` (`spec/strings.json`)
- New field `toolbar_sep` (default `" "`). Must be exactly 1 display cell.
- **Separator color** (`toolbar_sep_fg`): resolved from `terminal_bg2` hex (from `spec/theme.json`) → closest 256-color index via `resolveColorValue`. The separator fg color matches the terminal background, making it a subtle but configurable divider. Fallback chain: `terminal_bg2` hex → `grid_bg` index → dim SGR.
- `Palette` gains two new fields: `toolbar_sep_fg: []const u8` and `search_end_cap: []const u8`.

### Search bar end cap (`▐`)
- `▐` (U+2590 RIGHT HALF BLOCK) placed as the last character of the search bar row.
- Colors: `bg = search_bg_idx` (left half = search bar color, seamless continuation), `fg = terminal_bg_idx` (right half = terminal background color).
- Sequence: `\x1b[48;5;{search_bg}m\x1b[38;5;{term_bg}m▐`
- Using `▐` (bg = search bar) is more robust than `▌` (fg = search bar): if the block character is not rendered, the cell still shows `search_bg` (search bar continues rather than ending 1 col early).

---

## Critical Bug: `endRowFull()` vs `endRow()`

**Symptom:** The `▐` end cap was visible in TUI mode but missing in GUI (foot) mode.

**Root cause:** `endRow()` emits `\x1b[0m\x1b[K` (reset attributes + erase to end of line). When `▐` is the **last character** in an exact-width window (foot `--window-size-chars=NxH` gives exactly N columns), writing to column N leaves the cursor in **pending-wrap state** (it has printed the character but has not advanced past it). From pending-wrap, `\x1b[K` erases **the character just written** — foot sees the cursor as still being on column N.

In inline TUI mode the terminal window is slightly wider than `content_width` (the user's actual terminal), so `\x1b[K` fires from a later column and does not overwrite the cap. Only in the GUI's exact-width foot window does the pending-wrap position coincide with the last column.

**Fix:** Use `endRowFull()` for the search bar row. `endRowFull()` emits only `\x1b[0m` (no `\x1b[K`), leaving the end cap intact. The method already had a comment documenting this exact use case.

See also: [`docs/TerminalRestore.md`](../../docs/TerminalRestore.md) §8 for the generalized pitfall.

**Why it was invisible before:** The previous trailing character was a space (` `) — `\x1b[K` erasing it had no visible effect. Only when the trailing character became visually significant (`▐`) did the erasure become apparent.

---

## Hover and Click Zone Math

Zones are computed as 0-indexed `local_col = click_col - 1` relative to `content_width`. With `sep_w = 1` and `icon_cols = sep_w*2 + 4 = 6`:

| Zone | `local_col` range | Action |
|---|---|---|
| Theme icon | `[cw-6, cw-2)` | Cycle theme |
| Menu icon | `[cw-2, cw)` | Toggle settings |

The end cap occupies 1 col (the final column) inside the menu zone — it's decorative, not a separate hit target.

---

## Files Changed

| File | Change |
|---|---|
| `spec/theme.json` | Added `icons.menu = "≡"` |
| `spec/strings.json` | Added `toolbar_sep = " "` |
| `spec/commands.json` | Added `menu` / `hamburger` commands |
| `src/term.zig` | Added `toolbar_sep_fg`, `search_end_cap` to `Palette` |
| `src/spec.zig` | `toolbar_sep_fg` and `search_end_cap` built in `buildPalette`; `terminal_bg2` resolved via `resolveColorValue` |
| `src/main.zig` | Toolbar rendering, hover/click zone detection for theme + menu; description-row labels; `endRowFull()` for search bar row |
