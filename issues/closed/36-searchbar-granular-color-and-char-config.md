<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue #36 — Searchbar Granular Color & Character Configuration

**Status:** Closed (Implemented)

---

## Summary

Extended the search bar theming system with per-segment separator colors, cap
character configuration, text-area fg overrides, and a corrected null-color
fallback contract. Fixes a bug where null sep/cap colors resolved to a near-black
terminal-bg index instead of the app canvas color.

---

## What Was Added

### `spec/theme.json` — new palette fields

| Field | Fallback | Effect |
|-------|----------|--------|
| `search_cursor_fg` | — (inherit search_bg fg) | Cursor / text fg when query is empty |
| `search_text_fg` | `search_cursor_fg` | Query text fg when non-empty |
| `search_placeholder_fg` | `search_cursor_fg` → `grid_fg` | Placeholder ("search…") fg |
| `search_left_cap_bg` | `search_bg` | Left cap (`▌`) background |
| `search_right_cap_bg` | `search_bg` | Right cap (`▐`) background |
| `search_theme_sep_fg` | `search_sep_fg` → `cap_fallback` | Separator fg between search area and theme icon |
| `search_theme_sep_bg` | `cap_fallback` | Separator bg between search area and theme icon |
| `theme_settings_sep_fg` | `search_sep_fg` → `cap_fallback` | Separator fg between theme icon and menu |
| `theme_settings_sep_bg` | `cap_fallback` | Separator bg between theme icon and menu |

(`search_left_cap_fg` and `search_right_cap_fg` existed before; `search_sep_fg` is
the shared override for all sep fg values.)

### `spec/strings.json` — new glyph fields

| Field | Default | Constraint |
|-------|---------|------------|
| `search_left_cap` | `▌` | Exactly 1 display cell |
| `search_right_cap` | `▐` | Exactly 1 display cell |
| `search_theme_sep` | `""` (→ `toolbar_sep`) | 1 display cell |
| `theme_settings_sep` | `""` (→ `toolbar_sep`) | 1 display cell |

Cap chars were previously hardcoded in `spec.zig`. They are now fully configurable.

### `src/spec.zig` — `buildPalette` refactor

- Added `buildSeq` helper: builds `\x1b[48;5;{bg}m\x1b[38;5;{fg}m` (or `\x1b[39m`
  when fg=None) from optional u8 indices.
- Cap color sequences are now *colors only* (no embedded glyph char). The glyph is
  appended from `g_spec.strings.search_left_cap` / `search_right_cap` at render time.
- Two independent per-segment sep sequences replace the single `search_sep`.
- `PaletteSpec` struct got 9 new `std.json.Value = .null` fields.

### `src/term.zig` — `Palette` struct

Old fields removed: `search_left_cap`, `search_right_cap`, `search_end_cap`,
`search_sep`.

New fields added: `search_left_cap_seq`, `search_right_cap_seq`,
`search_theme_sep`, `theme_settings_sep`, `search_cursor_fg`,
`search_text_fg`, `search_placeholder_fg`.

### `src/main.zig` — search bar rendering

- Left cap: emit `search_left_cap_seq` + `g_spec.strings.search_left_cap` + reset.
- Placeholder: applies `search_placeholder_fg` → `search_cursor_fg` → `grid_fg`.
- Query text: applies `search_text_fg` → `search_cursor_fg` → (inherit).
- Icon row: two independent sep sequences, each falling back to `toolbar_sep_fg`
  when the palette sequence is empty.

---

## Bug Fixed — Black Separator Colors

**Root cause**: `search_sep_fg_idx` was resolving through `cap_fallback_idx`
(`app_bg_idx orelse term_bg_idx`). For the dark theme `app_bg = null` and
`terminal_bg2 = "#2c2c2c"` → xterm 236 (#303030, near-black). This was correct for
the half-block **caps** (their fg must match the canvas to create the blend illusion)
but wrong for **separators** which need to be *visible*.

Early fix attempt used `\x1b[39m` (terminal default fg) as the null sep fg — visible
but inconsistent: `null` meant different things for caps vs seps.

**Final contract**: `null` for any sep fg or bg resolves to `cap_fallback_idx` (app
bg), not `search_bg`. This is the same "punch-through" semantics as the caps. A null
sep bg creates a gap showing the canvas; a null sep fg gives an app-bg-colored
character on the explicit bg.

To get a visible separator: set an explicit `search_theme_sep_fg` or pick a mid-gray
that contrasts with `search_bg` (e.g. `240` for dark theme, `248` for light).

---

## Reference

- `docs/SpecDrivenConfig.md` §13 — full field table with fallbacks
- Issue #32 — original toolbar hamburger/sep/cap work
- Issue #35 — color system overhaul that introduced `search_left_cap_fg` etc.
