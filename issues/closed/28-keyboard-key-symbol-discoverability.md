<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue 28 — Keyboard Key Symbol Discoverability

**Status**: Closed (Implemented — 2026-06-23)  
**Priority**: P2

---

## Problem

Several keyboard-key Unicode symbols were absent from the database or ranked
poorly for the queries a developer would naturally type:

- ⭾ (tab, U+2BBE) and ↵ (enter, U+21B5) were **not in the database** at all;
  the existing tab/enter glyphs (⇥ / ⌤) were unfamiliar characters.
- `"cmd"` → ⌘ landed at **rank #16** because the greedy subsequence matcher
  found `c-m-d` inside `"command"` with a low score rather than the standalone
  `"cmd"` word later in the string.
- `"arrow keys"` → ↕/↔ returned **zero results** because the two arrow emoji
  had no `"key"` keyword; the AND query `"arrow" + "keys"` (plural→"key") had
  nothing to match.
- Navigation keys ⎀ ⇞ ⇟ ⇱ ⇲ (Ins, PgUp, PgDn, Home, End) were absent.

---

## Root Causes

1. **Missing glyphs**: ↵ and ⭾ were simply never added to `spec/boxart.json`.
2. **Greedy-matcher word-order trap**: the packer builds each boxart search
   string as `name + tags.join(" ") + " box ascii art"`.  When `name` is
   `"command"` and `"cmd"` is only in `tags`, the greedy matcher finds `c-m-d`
   scattered inside `"command"` (score ≈ 63) instead of the consecutive word
   `"cmd"` (score ≈ 130).  Fix: put the short form first in `name`.
3. **Missing `"key"` tag on quasi-emoji arrows**: ↕/↔ are in `data/emoji.json`
   and their tags had no `"key"` keyword, so AND queries including `"key"` or
   `"keys"` found zero results.

---

## Fix

### `spec/boxart.json`

| Change | Detail |
|--------|--------|
| Replace ⌤ with ↵ | ⌤ (ENTER KEY symbol) is obscure; ↵ (DOWNWARDS ARROW WITH CORNER LEFTWARDS) is the universally recognised return/enter glyph |
| Add ⭾ as primary tab; keep ⇥ as `"tab right"` | Both searchable via `"tab"` |
| Rename ⌘ entry to `"cmd command"` | Puts short form first → rank #1 for `"cmd"` |
| Add ⎀ insert, ⇞ page up, ⇟ page down, ⇱ home, ⇲ end | Each with `["keyboard", "key"]` tags |

### `data/emoji.json`

Added `"key"` to the `tags` of ↔ (left right arrow) and ↕ (up down arrow).

### Tests

Added `test "key symbol discoverability"` to `src/root_test.zig`:
- Covers all 16 keyboard key symbols with typical developer queries.
- Uses `findRank()` helper (returns 1-based rank, 0 = not found).
- `std.debug.print` emits the rank table on every run — useful for audits
  even when all assertions pass.
- Buffer size: `[1280]Match` (5 × MAX_CELLS) to avoid silent truncation on
  exhaustive ranking runs.

---

## Final Ranking (post-fix)

| Query | Char | Rank |
|---|---|---|
| `tab` / `tab key` | ⭾ | #1 |
| `tab` | ⇥ | #2 |
| `space key` | ⎵ | #1 |
| `enter` / `enter key` / `return key` | ↵ | #1 |
| `backspace` / `backspace key` | ⌫ | #1 |
| `shift` / `shift key` | ⇧ | #1 |
| `escape` / `esc key` | ⎋ | #1 |
| `delete forward` | ⌦ | #1 |
| `ctrl` / `control key` | ⌃ | #1 |
| `alt key` / `option key` | ⌥ | #1 |
| `cmd` / `command key` | ⌘ | #1 (was #16) |
| `arrow keys` | ↕ / ↔ | #1 / #2 (were rank 0) |
| `page up` | ⇞ | #2 (📄 "page facing up" wins both words) |
| `page down` | ⇟ | #1 |
| `insert key` | ⎀ | #1 |
| `home key` / `end key` | ⇱ / ⇲ | #1 |

Note: `"page up" → ⇞ rank #2` is acceptable — 📄 "page facing up" has both
words as a genuine match. `"pgup key"` yields rank #1 if needed.

---

## Docs Updated

- `docs/SearchEngine.md` §10: added `findRank` pattern to ranking test guidelines.
- `docs/SearchEngine.md` §11 (new): keyboard key symbols, codepoint-range/penalty
  explanation, greedy-matcher word-order trap, arrow-keys "key" tag requirement.
