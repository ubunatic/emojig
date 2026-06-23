<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue 29 — Category Synonym Search Ranking Confuses Results

**Status**: Closed (Fixed — 2026-06-23)  
**Priority**: P1

---

## Problem

When a user typed a search query that matched a category synonym (for example, searching `"car"`, which is a synonym for the `"travel"` category):
1. The search engine implicitly auto-detected the category (`travel`).
2. It silently consumed/stripped the synonym (`"car"`) from the query, leaving the text query empty (`""`).
3. An empty text query triggered a fallback to browse mode, returning *all* emojis in that category ordered by their raw database position.
4. Emojis like `✈️` (airplane), `🚣` (rowboat), and globes, which happen to appear early in the Unicode travel category, were displayed first, pushing actual cars (`🚗`, etc.) off the screen.

### Test Isolation Gap
The unit test suite in [root_test.zig](file:///home/uwe/projects/emojig/src/root_test.zig) did not catch this regression because the test helper functions passed `null` for `categories_spec` to bypass category parsing in library tests. As a result, the auto-detect logic was a no-op during tests, allowing standard fuzzy searches for `"car"` to succeed and pass.

---

## Solution

1. **Retain Synonym Keywords**:
   Updated the category auto-detect logic in [root.zig](file:///home/uwe/projects/emojig/src/root.zig) to differentiate between category names/shorts and category synonyms. 
   - Category names and shorts (e.g., `"travel"`) are still stripped when matched.
   - Category synonyms (e.g., `"car"`) are **not** stripped. They activate the category filter (e.g., `travel` category only) but remain in the query string so the fuzzy match engine runs, prioritizing specific matching emojis (e.g. `🚗`) at the top.
2. **Added Unit Tests**:
   Added a new ranking test `test "ranking: category synonym search does not get confused"` in [root_test.zig](file:///home/uwe/projects/emojig/src/root_test.zig). This test explicitly loads the categories JSON specification to verify that `"car"` queries rank the `🚗` emoji within the top 3 results even when category auto-detection is active.
