<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [InlineTuiGuide.md](file:///home/uwe/projects/emojig/docs/InlineTuiGuide.md)
> - **Extra Content Covered Here:** Precise status bar count layout formulas, help screen layout wide/narrow variants, and coordinate mapping formulas.
> - **Outdated Information:** Lists `cols = 10` and `rows = 6` as the default TUI layout parameters, whereas the default interactive TUI runs on a `6x4` grid.

---


# TUI Layout Constants and Simulator Mirroring

> [!NOTE]
> **Currency Status:** Current as of June 7, 2026. Documents the canonical TUI grid dimensions, row-budget arithmetic, and the rule that `website/simulator.js` must be kept in sync with `src/main.zig`.

---

## 1. Canonical Grid Dimensions (`src/main.zig`)

The TUI is built from a fixed set of compile-time constants. Changing grid shape requires updating **all** of the following in lock-step:

| Constant / Variable | Location | Current Value | Meaning |
|---|---|---|---|
| `cols` | `main.zig` | `10` | Emoji cells per row |
| `rows` | `main.zig` | `6` | Grid rows |
| `total_cells` | `main.zig` | `60` (`cols × rows`) | Max emojis shown |
| `content_rows` | `main.zig` | `12` | Total TUI rows (see budget below) |
| `final_width` default | `main.zig` | `41` | Default terminal columns (`cols × 4 + 1`) |
| `grid_rem` pivot | `main.zig` | `40` | `cols × 4`; used in both grid render branches |
| `grid_last_row` (mouse) | `main.zig` | `9 + row_off` | `grid_first_row(4) + rows - 1` |
| `cell_buffers/strings` arrays | `main.zig` | `[10]` | Must equal `cols` |

### Row Budget

`content_rows` is the sum of all rendered rows (excluding optional border and debug rows):

```
1  top padding
1  search bar
1  spacer
N  grid rows          ← rows = 6
1  spacer
1  description
1  status bar
──
12 total              ← content_rows = 12
```

`final_h = content_rows + 2` when border is shown (adds top + bottom border rows).

### Cell Width

Each emoji cell occupies exactly **4 display columns**: ` emoji ` (space + 2-col emoji + space), or `[emoji]` when selected. The default width formula is:

```
final_width = cols × 4 + 1   →   10 × 4 + 1 = 41
```

The `+1` adds one trailing space column so the styled background visually closes on the right.

### `is_too_small` Threshold

```zig
const is_too_small = (current_w < content_width + 2);
```

This is dynamic — it collapses the grid to a "Too small" label whenever the actual terminal is narrower than the configured content width by more than 1 column. Do **not** hardcode a pixel value here.

---

## 2. Search Bar Column Arithmetic

The search bar row renders: `" " + "🔍 " + query + padding + " theme_icon "`.

| Segment | Display columns |
|---|---|
| Leading margin | 1 |
| `🔍 ` (emoji + space) | 3 → `prefix_cols = 3` |
| Query text | `display_query_len` |
| Padding | `content_width - 3 - 4 - display_query_len` |
| ` icon ` | 4 → `icon_cols = 4` |

`max_query_cols = content_width - prefix_cols - icon_cols = 41 - 3 - 4 = 34`

The "search…" **placeholder** renders when `query_len == 0`. It occupies 7 display columns (`search` = 6, `…` = 1), so the padding shrinks by 7 when the placeholder is shown.

---

## 3. Status Bar Column Arithmetic

The status bar layout changes dynamically based on whether the search query is empty or active, utilizing `↕↔` instead of `←↑↓→` to save space:

### Empty Search (`query_len == 0`)
```
" ?:help  ↕↔|↵|Esc"
```

| Segment | Display columns |
|---|---|
| Leading space | 1 |
| `?:help` | 7 |
| Spacer | 2 |
| `↕↔` (navigation keys) | 2 |
| `|↵|Esc` (select/exit) | 6 |
| **Total** | `18` |

`text_cols = 18` is used to compute the right-side padding when empty.

### Active Search (`query_len > 0`)
```
" {count}  ↕↔|↵|Esc"
```

| Segment | Display columns |
|---|---|
| Leading space | 1 |
| Count digits | `digits` (variable) |
| Spacer | 2 |
| `↕↔` (navigation keys) | 2 |
| `|↵|Esc` (select/exit) | 6 |
| **Total** | `11 + digits` |

`text_cols = 11 + digits` is used to compute the right-side padding when typing.

---

## 3.1 Help Screen Layout

Typing `?` as the first character in the search bar overrides the grid/description rendering with a text-based Help Screen. To prevent height drift or terminal scrolling, the help screen renders exactly `rows + 3` rows (matching the replaced spacer, grid, spacer, and description rows).

The help screen detects the width of the terminal to select the text density:
- **Narrow Layout** (`content_width < 35`): Displays 6 lines of compact usage hints.
- **Wide Layout** (`content_width >= 35`): Displays 7 lines of detailed keybind descriptions.

To keep the screen visually balanced, if `rows` allows (e.g. `help_rows >= 9` for wide, `help_rows >= 8` for narrow), a leading/trailing spacer is applied. Otherwise, spacers are dropped to fit all help items without truncating the key bindings.

---

## 4. Mouse Hit-Test Row Mapping

Mouse clicks are mapped to TUI-relative rows. The grid occupies rows `grid_first_row` through `grid_last_row` (1-indexed from TUI top, accounting for `row_off` when border is shown):

```
grid_first_row = 4 + row_off
grid_last_row  = grid_first_row + rows - 1 = 4 + row_off + 5 = 9 + row_off
```

If `rows` changes, update **both** occurrences of `grid_last_row` in the SGR mouse handler (motion and click branches).

---

## 5. Simulator Mirroring (`website/simulator.js` + `simulator.css`)

The web simulator is a pixel-faithful HTML replica of the TUI. Every layout constant has a JS counterpart that **must be kept in sync** whenever `src/main.zig` changes:

| `main.zig` | `simulator.js` | Current value |
|---|---|---|
| `cols` | `this.cols` | `10` |
| `rows` | `this.rows` | `6` |
| `total_cells` (60) | `Math.min(60, ...)` in `render()` | `60` |
| empty-query default | `db.slice(0, 60)` in `getFilteredMatches()` | `60` |
| `max_query_cols` (34) | `maxQueryCols` | `34` |
| `maxDescLen` (40) | `maxDescLen` | `40` |
| Status bar text | `statusText` string | `↑↓←→  ↵ Esc  Tab:🌙→🌞` |
| `padRight(..., 41)` | second arg to `padRight` | `41` |

### CSS Width

`simulator.css` `.sim-window { max-width }` must be wide enough for the terminal content:

```
min_px ≈ content_width × char_width + 2 × padding
       ≈ 41 × 8.7px + 28px ≈ 385px
```

Current value: `520px` (generous headroom for emoji double-width variance across fonts).

### Placeholder

The simulator renders `<span class="sim-search-placeholder">search…</span>` (dim, 70% opacity) when the query is empty, matching the `palette.fg`-coloured placeholder in the real TUI.

---

## 6. Checklist: Resizing the Grid

When changing `cols` or `rows`, touch every item in this list:

- [ ] `const cols = N;` in `main.zig`
- [ ] `const rows = M;` in `main.zig`
- [ ] `content_rows` = 1+1+1+**M**+1+1+1
- [ ] `final_width` default = `N × 4 + 1`
- [ ] `grid_rem` pivot = `N × 4` (two occurrences, both render branches)
- [ ] `cell_buffers: [N]` and `cell_strings: [N]` (both render branches)
- [ ] `bufPrint` format string: 2 + N `{s}` placeholders
- [ ] `grid_last_row = (3 + M) + row_off` (two occurrences in mouse handler)
- [ ] `simulator.js`: `this.cols`, `this.rows`, `topCount` cap, empty-query slice, `maxQueryCols`, `maxDescLen`, `padRight` width
- [ ] `simulator.css`: `.sim-window max-width ≥ N × 4 × ~8.7px + 28px`
