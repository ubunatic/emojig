# GTK4 Built-in Emoji Picker — Observed Bugs

Observed via `make gtkdemo` (GTK4 `Entry` / `TextView`, `Ctrl+.` to open).

## Bug 1: Arrow-up on top row does not return focus to text field

**Steps:**
1. Open GTK emoji picker with `Ctrl+.`
2. Navigate into the emoji grid
3. Press `↑` while on the top icon/category row

**Expected:** Focus returns to the search text input inside the picker.  
**Actual:** Nothing happens — keyboard focus is trapped; the top row does not hand focus back up.

---

## Bug 2: Search results show wrong category / wrong emojis

**Steps:**
1. Open GTK emoji picker with `Ctrl+.`
2. Type `car`

**Expected:**
```
Travel & Places
🚘 🚗 🛻 …
```

**Actual:**
```
Smileys & People
💓 💛 💭
Body & Clothing
💅 🫀 🤸 …
Food & Drink
🥕 🍞
…
```

The search matches keyword `car` inside unrelated emoji names/keywords
(e.g. "scar", "cardiac", "carrot") across many categories, and buries
or omits the obvious Travel hits (`car`, `racing car`, `pickup truck`).
Ranking does not prioritise prefix / word-start matches.

---

## Bug 3: Typing while grid is focused does not redirect to search prompt

**Steps:**
1. Open GTK emoji picker with `Ctrl+.`
2. Navigate into the emoji grid with arrow keys
3. Type any text (e.g. `abc`)

**Expected:** Focus returns to the search text input and the typed characters
are appended to the query, continuing or starting a new search.  
**Actual:** Nothing happens — characters are silently swallowed; the grid
retains focus and the search field is not updated.

---

## Summary

| # | Area | Severity |
|---|------|----------|
| 1 | Keyboard navigation — focus trap at top row | UX / Accessibility |
| 2 | Search ranking — wrong/irrelevant results for `car` | Correctness |
| 3 | Typing while grid focused does not redirect to search prompt | UX |

These are bugs in the upstream GTK4 emoji chooser widget, not in Emojig.
Tracked here for reference when comparing against Emojig's fuzzy search.

---

## Emojig follow-up: missing `car` tag on vehicle emojis

GTK's `car` results exposed a gap in Emojig too: 🚘 and 🛻 were invisible
under `car` because their source entries in `data/emoji.json` had empty `tags`.

**Fixed** in `data/emoji.json` + `src/emojis.bin` (repacked):

| Emoji | Description | Tags added |
|-------|-------------|------------|
| 🚘 | oncoming automobile | `car` |
| 🚙 | sport utility vehicle | `car`, `suv` |
| 🛻 | pickup truck | `car`, `truck` |

All four car emojis (🚗 🚘 🚙 🛻) now appear when searching `car`.
