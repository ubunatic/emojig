<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Alias Strategy: Closing the Gap Between Official Names and User Intent

Real users search with everyday words.  Unicode names are designed for
technical precision and interoperability, not for what a person would
naturally type.  This gap is the primary source of "why can't I find X?"
complaints.

This document records the strategy for closing that gap via `data/emoji.json`
aliases, `spec/synonyms.json` mappings, and ranking-test assertions.  Read it
before touching search data.  The mechanics (packer, binary format, scorer) are
in `docs/SearchEngine.md`.

---

## The core problem

Official Unicode names reflect *visual appearance* or *technical category*, not
user intent:

| What the user types | Official Unicode name         | Why it fails                                     |
|---------------------|-------------------------------|--------------------------------------------------|
| `cars`              | "oncoming automobile"         | "automobile" ≠ "car"; greedy scorer hits "c" in "oncoming" |
| `glass`             | "clinking glasses"            | "glasses" in the name — but the scorer finds "cl**i**nking **g**lasses" poorly |
| `sparkling`         | "clinking glasses"            | no "sparkle" keyword at all                      |
| `lens`              | "magnifying glass tilted left"| "lens" never appears in the official corpus      |
| `crystal`           | "crystal ball"                | works fine — name matches intent                 |

The pattern: the emoji that *feels* right often has a name that fuzzy-matches
poorly because (a) the key word appears late in a long string, (b) the key word
is split across multiple emoji names, or (c) the key word simply doesn't exist
in the official data.

---

## Mental model: how the scorer ranks things

The fuzzy scorer (`matchTermDirect` in `src/search.zig`) does a **greedy
left-to-right subsequence scan** and rewards:

1. **Word-start position** — matching the first letter of a word adds +40 to
   the character score.
2. **Consecutive characters** — each consecutive match after the first adds
   `+20 × consecutive_count`.
3. **Exact word match** (all chars consecutive, bounded by spaces) — +100
   bonus.
4. **Early start** — a late-starting match subtracts `start_index` from the
   final score.
5. **Short target** — `score -= target.len` as a tie-breaker, so a short,
   precise name beats a long description with the same keyword.

`matchTermSelf` also applies plural/stem fallbacks (`"cars" → "car"`,
`"racing" → "race"`), but **only if the direct match fails**.  If 'c' appears
earlier in the string (e.g. in "on**c**oming") the greedy scan latches onto it
before reaching the actual word "car", producing a poor score.

**Practical consequence**: the most impactful thing you can do for a search
term is put the matching word **first** in the emoji's search string.  Since
the packer orders words as `aliases → description → tags → category`, the
right lever is usually **adding a word as the first alias**.

---

## The three tools and when to use each

### 1. First alias in `data/emoji.json` — the primary lever

Use when you want one specific emoji to rank *at the very top* for a term.

```json
"aliases": ["car", "oncoming_automobile"]
```

The packer puts aliases first in the search string, so "car" lands at position 0
with the maximum word-start bonus and zero late-start penalty.

**When to use**: the term is a common user-intent word not otherwise in the
emoji's name (`"car"` for 🚘, `"glass"` for 🥂, `"lens"` for 🔍).

**When NOT to use**: the term is already the first word of the description
(you'd be duplicating it — the packer deduplicates, but it's confusing to read).

### 2. Later alias or tag in `data/emoji.json` — secondary hit

Use for terms where top ranking doesn't matter — you just want the emoji to
appear somewhere in results.

```json
"tags": ["sparkle", "sparkling", "bubbly"]
```

Tags land after the description in the search string.  The emoji will surface
but not necessarily in the first row.

**When to use**: supplementary synonyms, alternate contexts (`"celebration"` on
🍾), rare but valid searches.

### 3. `spec/synonyms.json` — cross-emoji word expansion

Use for true many-to-many substitutions that should apply to *every* emoji
containing a word.

```json
"synonyms": {
  "fast": ["quick", "rapid", "speedy"],
  "car":  ["auto", "automobile", "truck"]
}
```

`matchTerm` applies synonyms after the direct match: it scores both `"car"`
and `"automobile"` against each target and keeps the better score.

**When to use**: adjectives and verbs that are genuine synonyms
(`fast/quick/rapid`, `auto/automobile/car`).

**When NOT to use**: single-emoji targeting.  Synonyms affect *every* emoji
that happens to contain the mapped word, so tie-breaking is unpredictable
(see `SearchEngine.md §3` for the cautionary tale about `"emojig"`).

---

## Common alias categories and examples

### Container / glassware words

Many drink-related emojis say "glass" in their name, but not all do:

| Emoji | Official name       | Fix applied                                |
|-------|---------------------|--------------------------------------------|
| 🥂    | clinking glasses    | `"glasses"`, `"glass"`, `"sparkling"` as first aliases |
| 🥤    | cup with straw      | `"glass"` as first alias                  |
| 🍸    | cocktail glass      | `"glass"` as first alias (word 2 in name) |
| 🍾    | bottle with popping cork | `"glass"` as first alias             |
| 🔮    | crystal ball        | `"glass"`, `"lens"` as first aliases       |

**Why "glass" as first alias on 🥂 when its name already says "glasses"?**
The description is "clinking glasses" — "glasses" is word 2.  The greedy
scanner finds 'g' in "clin**k**ing" before it reaches "g**l**asses", giving a
degraded score.  Putting "glasses" as the very first alias makes it word 0,
and the exact-word match bonus kicks in.

### Vehicle plurals

"cars" is the most natural search for multiple vehicles, but only 🚗 has "car"
as an alias (so it scores ~205).  🚘, 🛻, 🚚, 🚛 all had "car" buried after
longer primary words — the greedy scanner found 'c' in "on**c**oming" / "tru**c**k"
/ "carpentry" and scored near 0:

| Emoji | Was                                 | Now                              |
|-------|-------------------------------------|----------------------------------|
| 🚘    | `"oncoming_automobile"` (one alias) | `"car"` prepended as first alias |
| 🛻    | `"pickup_truck"`                    | `"car"` prepended as first alias |
| 🚚    | `"truck"`                           | `"car"` prepended as first alias |
| 🚛    | `"truck"`, `"articulated_lorry"`    | `"car"` prepended as first alias |

### Optical / scientific terms

Users think "lens" when they want a magnifying glass; Unicode thinks "tilted".
The word "lens" simply does not appear in any emoji's official name or tags:

| Emoji | Fix                         |
|-------|-----------------------------|
| 🔍    | `"lens"` as first alias     |
| 🔎    | `"lens"` as first alias     |
| 🔮    | `"glass"`, `"lens"` as first aliases |

### Occasion / context words

Users type what they're *doing*, not what the emoji depicts:

| Query        | Target emoji | Fix                                  |
|--------------|-------------|--------------------------------------|
| `sparkling`  | 🥂          | `"sparkling"` alias (no such word in official name) |
| `celebrate`  | 🍾          | `"celebration"` tag already present (✓) |
| `toast`      | 🥂          | `"toast"` tag already present (✓)   |

---

## Decision guide: what needs fixing?

Run a quick mental test before every edit:

1. **Type the word in the TUI.** Does the target emoji appear in the first two
   rows?  If yes, stop — it's already good enough.
2. **Check the search string** (use the probe test pattern in `root_test.zig`
   or `zig build test` output).  Where does the key word appear in the string?
   - Position 0 → should score high; something else is wrong (check synonyms).
   - Position ≥ 8 → add as first alias.
   - Not present at all → add as first alias or tag depending on importance.
3. **Check if the same word would help multiple emojis.**  If yes, consider
   `spec/synonyms.json`.  If it's only one or two specific emojis, use aliases.
4. **Write the assertion first**, then fix the data, then verify.

---

## Writing ranking assertions

Add to `src/root_test.zig`.  Rules of thumb:

- **`inTop(query, emoji, 3)`** for "typing this word should immediately show
  this emoji" (e.g. `inTop("lens", "🔍", 3)`).
- **`inTop(query, emoji, 10)`** for "close synonym — visible in first row/two"
  (e.g. `inTop("cars", "🚘", 10)`).
- **`inTop(query, emoji, 20)`** for "reachable by scrolling" (e.g.
  `inTop("glass", "🍾", 20)`).
- **Eyewear occupies top 5 for `"glasses"`** — drinkware can't all fit in top 10.
  Test them at top-15 instead of top-10 when the query is also the exact name of
  another emoji category (eyewear, sunglasses, etc.).
- **Do not test `c:` queries via `search()`** — the bare `search()` function
  receives `null` for `categories_spec`, so all `c:`-filtered queries return
  zero results.  Use combined-keyword forms instead (`"travel car"`, `"food glass"`).

---

## Before committing data changes

1. Edit `data/emoji.json`.
2. `make pack` → regenerates `src/emojis.bin` and `website/emojis.js`.
3. `zig build test` → all ranking assertions must pass.
4. Commit `data/emoji.json` changes alongside regenerated `src/emojis.bin` and
   `website/emojis.js`.  (`data/emoji.json` is gitignored on this repo, so only
   the binary and JS artifacts are shared — but document what you changed and
   why in the commit message so future contributors can reproduce the intent.)
