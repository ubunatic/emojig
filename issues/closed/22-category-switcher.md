<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue 22 — Category Switcher UI

**Status**: Closed (Implemented — 2026-06-23)  
**Priority**: P3

---

## Resolution

- **Implemented**: A horizontal category switcher bar has been added. Tab and Shift-Tab cycle through categories. c: prefix filters are supported.
- **Visuals**: Features clean borders, dim hlines separating sections, and interactive mouse/keyboard navigation.
- **Hover Feedback**: Hovering a category switcher icon shows the category name (in bold ANSI formatting) and its non-redundant synonyms in the description row (label bar), e.g. "**smileys**, face, smile, emotion...". Redundant synonyms (matching category name/short name) are filtered out, and hovering the "All" slot displays "**All**". Padding is calculated using `ansiDisplayWidth` to keep the row highlight clean.

## Idea

Add a horizontal category bar to the emojig TUI, similar to the GTK4 emoji
picker's icon row (screenshot: clock/recent, smiley, hand/people, speech,
food, globe, sports, lightbulb, symbols, flag).

Assign **Tab** to cycle through categories (currently Tab cycles the colour
theme — reassign theme-cycle to a different key, e.g. `Ctrl+T` or the
existing theme-toggle click on the search-bar icon).

---

## GTK4 Category Reference

The GTK picker shows these categories as icon buttons:

| Icon | Category |
|------|----------|
| 🕐 | Recent |
| 😀 | Smileys & Emotion |
| 👍 | People & Body |
| 💬 | Component / Skin tones |
| 🍴 | Food & Drink |
| 🌍 | Travel & Places |
| ⚽ | Activities |
| 💡 | Objects |
| 🔣 | Symbols |
| 🚩 | Flags |

These map to the `category` field already present in `data/emoji.json`.

---

## Proposed UX

- A new **category bar row** rendered between the search bar and the emoji
  grid (or below the grid, above the status bar — TBD).
- Each category is one icon cell; the active category is highlighted with
  `selection_bg`.
- **Tab** moves focus to the category bar and advances one category; wraps.
- **Shift+Tab** moves backwards.
- Selecting a category filters the result set to that category only (AND-ed
  with the current query if non-empty).
- A special "All" / no-filter slot (e.g. `🔍` or `✱`) resets category
  filtering — Tab-cycling lands on it last before wrapping.
- **Esc** or typing any character returns focus to the search prompt and
  clears the category filter (consistent with current grid-focus → prompt
  behaviour).

---

## Implementation Notes

- Category list can be derived at pack time from `data/emoji.json` and
  embedded (no runtime allocation).
- The existing `runSearch` result buffer already holds category strings per
  entry; filtering is a post-pass or a secondary `matchCategory` check.
- Row layout impact: +1 row for the category bar (inside the existing
  `rows` budget, or as an optional overlay); update `EMOJIG_BORDER` height
  calculation accordingly.
- Tab key is currently bound to theme-cycle on the search screen. Reassign
  theme-cycle to the mouse-click on the `🌙`/`☀️` icon (already works) and
  keep a keyboard shortcut via `Ctrl+T` or `F2`.
- The existing `show_categories` settings toggle (`spec/strings.json`,
  Settings screen row 4) may become the on/off switch for this bar.

---

## Open Questions

1. Row position: above the grid (between search and grid) or below (between
   grid and description)?
2. Category icon representation: use the emoji from the first entry of each
   category, or a fixed curated icon per category (more stable)?
3. Should Tab with a non-empty query filter *within* the category, or should
   selecting a category clear the query?
4. "Recent" category — reuse the existing MRU list?
