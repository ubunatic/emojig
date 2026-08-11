---
status: done
priority: p2
---

# Color System Simplification & Single Source of Truth

**Status: Closed (Implemented)** — all three "Proposed Improvements" landed;
verified 2026-08-11 by reading the current generator and spec sources.
**Priority:** P2 (historic)

## Closure verification (2026-08-11)

The three numbered proposals below are each satisfied in the current tree.
Note that the spec sources migrated from hand-edited `spec/*.json` to
hand-edited **`spec/*.yaml`** compiled into **`spec/.gen/*.json`** (see
`AGENTS.md` Quickstart) after this issue was written — the `spec/colors.json`
/ `spec/art.json` / `spec/theme.json` paths named throughout the analysis
below now read `spec/.gen/colors.json` (generated), `spec/art.yaml` and
`spec/theme.yaml` (hand-edited) respectively.

1. **Consolidate generator lookups — done.** The hardcoded `knownColors`
   RGB map is gone from `scripts/gen_about_art/main.go`; the generator now
   loads `spec/.gen/colors.json` at startup (`os.ReadFile` →
   `globalColors = gColorsSpec.Colors`) and builds the distance table from
   the parsed `hex` values. All 256 indices are available, not the former
   six hardcoded ones.
2. **`spec/art.yaml` inherits from the global dictionary — done.**
   `resolvePalette` resolves a palette name against the local `colors:`
   override map *first*, then falls back to global colour resolution
   (`resolveRawColor`, which consults `globalColors` by name/short/alias).
   Local overrides are now an optional convenience layer rather than a
   mandatory duplication step, which is exactly what this proposal asked
   for.
3. **Conflicting definitions aligned — done.** `scripts/gen_colors/main.go`
   now maps index **200 → `pink`** and index **209 → `Rose Pink`** with the
   alias `coral` — the distinct-name resolution this issue proposed. Index
   209 is no longer named `pink` anywhere, and `spec/art.yaml` no longer
   defines a local `pink` at all, so the conflict cannot recur.

**Not closed as a defect — item 4 ("Fragmented Escape Generation Paths") is
the intended design.** The `colorNameToBasic` → `colorNameToIndex` →
literal-numeric-index resolution chain is now the *documented* contract in
`AGENTS.md §3` ("Named colors"): the 8 basic ANSI names deliberately keep
the compact `3X`/`4X` form, everything else resolves through
`spec.ColorsSpec.indexOf` to `38;5;N`/`48;5;N`, with a numeric fallback.
That is a specified three-tier lookup, not an accidental duplication, so
there is nothing left to consolidate here.

**Related, deliberately not a regression:** the
`Warning: color '...' is not compatible with the schema` messages visible
during `zig build test` are test-only by construction — `src/spec.zig:186`
routes them to `std.debug.print` under `@import("builtin").is_test` and to
`term.appendLog` (i.e. `/tmp/emojig.log`, not the user's terminal) at
runtime. This is consistent with closed issue 35's "silenced runtime color
compatibility warnings" claim.

---

## 🔍 Context and Current Architecture

The color system in **Emojig** is currently split across three distinct definitions and parsing layers:

1. **Global Dictionary (`spec/colors.json`)**:
   Contains definitions for all 256 xterm colors, including their index, systematic name (`rgbRGB` or `grayNN`), hex color code, short code, and aliases. Curation maps common names (e.g. `"orange"` = 208, `"teal"` = 30) for human-friendly typing.
2. **Theme/Palette Specification (`spec/theme.json`)**:
   Sets the semantic color tokens (like `grid_fg`, `selection_bg`, `search_bg`) for `.light` and `.dark` themes mapping directly to xterm-256 indices or hex values (for terminal OSC backgrounds).
3. **Art Frame Composition (`spec/art.json` and `scripts/gen_about_art/main.go`)**:
   Used at compile-time to resample PNG image frames into ANSI quad-block strings.

---

## ⚠️ Issues & Chaos Identified

Upon review, the color system contains several redundancies, inconsistencies, and hardcoded duplications:

### 1. Duplicate & Conflicting Color Names
* **Pink Inconsistency**: In the global dictionary (`spec/colors.json`), `"pink"` is defined as index **200**. However, in `spec/art.json`'s local `"colors"` override block, `"pink"` is defined as index **209**.
* **White Mapping**: White is resolved variously as standard basic color 7, index 15, or index 255 depending on the pathway, causing semantic ambiguity.

### 2. Local Color Names Bypass the Global Dictionary
* `spec/art.json` maintains its own local `"colors"` map (e.g. `"Bright Amber": 214`, `"Dark Gold": 178`, `"Midnight Blue": 24`). 
* The art generator script `scripts/gen_about_art/main.go` only resolves color names against this local map. You cannot use any global color names from `spec/colors.json` directly within `spec/art.json` without duplicating them in the local map first.

### 3. Hardcoded RGB Conversion Map in the Generator
* To compute Euclidean color distances from PNG pixels to the xterm palette, the generator script needs RGB values for xterm indices.
* Rather than loading these from `spec/colors.json` (which already has `hex` values), `scripts/gen_about_art/main.go` duplicates these mappings in a hardcoded `knownColors` map for indices `214`, `255`, `238`, `232`, `209`, and `54`. This is redundant and error-prone.

### 4. Fragmented Escape Generation Paths
* In `src/main.zig`, the color resolution uses a complex multi-stage path:
  1. Calls `colorNameToBasic` to check if it's one of the 8 standard colors (to output the compact `3X`/`4X` codes).
  2. Falls back to `colorNameToIndex` (which queries parsed `spec/colors.json` names at runtime).
  3. Falls back to parsing a raw decimal integer.
* This results in duplicate handling of color index lookups in Zig, Go, and the generator script.

---

## 💡 Proposed Improvements

To transition the color system into a clean, unified architecture with a **Single Source of Truth**, we propose the following steps:

```mermaid
graph TD
    colors_json["spec/colors.json<br>(Single Source of Truth)"]
    gen_art["scripts/gen_about_art/<br>(Reads hex from colors.json)"]
    zig_app["src/main.zig<br>(Resolves color names globally)"]
    art_json["spec/art.json<br>(References colors.json directly)"]

    colors_json -->|Supplies hex codes| gen_art
    colors_json -->|Embedded color name lookup| zig_app
    colors_json -->|Replaces local colors override| art_json
```

### 1. Consolidate Generator Lookups via `spec/colors.json`
* **Eliminate `knownColors`**: Modify `scripts/gen_about_art/main.go` to load `spec/colors.json` at startup.
* **Build RGB Table dynamically**: Parse the hex codes (`#RRGGBB`) of the 256 colors from `spec/colors.json` to construct the mapping table for distance calculations, completely removing hardcoded overrides.

### 2. Allow `spec/art.json` to inherit from the Global Dictionary
* Update `resolvePalette` in `scripts/gen_about_art/main.go` so that if a color name is not found in the local overrides list, it falls back to looking up the name in the global `spec/colors.json` index list.
* This allows using standard names like `"orange"` or `"pink"` in art palettes without duplicating them.

### 3. Align Conflicting Definitions
* Standardize on a single index for `"pink"`: map `"pink"` globally to index 200, and introduce a distinct name (like `"pink-orange"` or `"coral"`) for index 209 to eliminate overlap.
* Ensure all standard ANSI colors are clearly aliased so there's no confusion between basic `0-7` names and index `232-255` grays.
