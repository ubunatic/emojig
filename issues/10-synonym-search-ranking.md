# Synonym Support for Better Search Ranking

## Problem

Typing "car" surfaces `🚋 tram car` before `🚗 automobile` because the fuzzy
scorer penalizes late matches and long targets. "car" appears at position 5 in
`"tram car tramcar"` (short string, early hit) versus position 11 in
`"automobile car redcar"` (longer string, later hit) — giving tram car a ~10-
point scoring advantage despite being the less relevant result.

## Proposed Fix

Synonym support at **match time**. When matching query term "car", also try
matching its synonym "automobile" against each candidate's search string. The
`🚗` entry has "automobile" at position 0 (its description), scoring a large
start-of-word + exact-word-boundary bonus. `🚋 tram car` has no "automobile" in
its search string, so its score is unchanged. Result: `🚗` ranks first.

## Files to Change

### 1. `spec/synonyms.json` (new)
Declarative synonym map, single source of truth shared by Go and Zig:
```json
{
  "description": "Synonym map for fuzzy search. Each key maps to synonyms tried during matching. Bidirectional pairs must be listed in both directions.",
  "synonyms": {
    "car": ["automobile"],
    "automobile": ["car"]
  }
}
```

### 2. `assets.go`
Add a `//go:embed spec/synonyms.json` entry (same pattern as other spec files).

### 3. `internal/emoji/emoji.go`
- Add `Synonyms map[string][]string` to the `DB` struct
- Load and parse `SynonymsJSON` in `Load()`

### 4. `internal/emoji/fuzzy.go`
In `matchTerm`, after the existing direct + stem fallbacks, iterate the term's
synonyms and call `matchTermDirect(syn, target)`; return the max score across all
attempts. No synonym expansion inside synonym lookup (no cycles).

### 5. `scripts/pack_emojis.go`
- Read `spec/synonyms.json`
- Extend the `emojis.bin` header from 16 → 24 bytes (bump version 1 → 2):
  - `[16..20]` synonym_table_offset u32
  - `[20..24]` synonym_count u32
- Add synonym strings to the string table
- Append synonym pairs `(from_off u32, to_off u32)` × N after the string table

### 6. `src/root.zig`
- Update `EmojiDb` header parsing: entry index starts at offset 24 (was 16)
- Add `SynonymDb` struct reading `synonym_table_offset` / `synonym_count` from
  `data[16..24]`; `getSynonym(i)` returns `(from, to)` slices via the string table
- Update `matchTerm` to linearly scan `SynonymDb` for the query term and try each
  synonym via `matchTermDirect`; return best score (no alloc, synonym count small)
- Update version assertion in tests (1 → 2)

### 7. Tests
- Go: assert `🚗` outranks `🚋` for query `"car"` in `search_test.go`
- Zig: same assertion in `root.zig` test block

## Scoring Walk-through (Zig)

Query "car", synonym "automobile":

| Target | Match term | Start pos | startIdx penalty | exact-word bonus | target.len penalty | Score |
|---|---|---|---|---|---|---|
| `"automobile car redcar"` | "automobile" | 0 | 0 | +100 | −21 | ~350+ |
| `"tram car tramcar"` | "car" (no synonym hit) | 5 | −5 | +100 | −16 | ~209 |

`🚗` wins by ~140 points.
