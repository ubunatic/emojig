# Half-Block Pixel Art in the TUI

This document captures the technique used for the about-screen smiley face and
serves as a recipe for any future pixel-art additions to `spec/strings.json`.

---

## Core idea

Unicode provides three block characters that divide a terminal cell into two
horizontal halves:

| Char | Codepoint | Top half | Bottom half |
|------|-----------|----------|-------------|
| `▀`  | U+2580    | **fg**   | bg          |
| `▄`  | U+2584    | bg       | **fg**      |
| `█`  | U+2588    | **fg**   | **fg**      |
| ` `  | space     | bg       | bg          |

Each terminal cell therefore encodes **two vertical pixels**: set `fg` and `bg`
independently to paint any combination of two colours in a single character
position.  "Transparent" (terminal-default) background counts as one colour too.

---

## Design workflow

### 1. Draw a pixel map

Treat each terminal row as two pixel rows.  Sketch the bitmap with short colour
tokens, e.g. `Y`=yellow, `K`=dark, `W`=white, `.`=transparent:

```
     0  1  2  3  4  5  6  7  8  9  10 11
P0:  .  .  Y  Y  Y  Y  Y  Y  Y  Y  .  .   ← terminal row 0 top pixel
P1:  .  Y  Y  Y  Y  Y  Y  Y  Y  Y  Y  .   ← terminal row 0 bot pixel
P2:  Y  Y  Y  Y  Y  Y  Y  Y  Y  Y  Y  Y   ← terminal row 1 top pixel
P3:  Y  Y  W  W  K  Y  Y  K  W  W  Y  Y   ← terminal row 1 bot pixel
...
```

### 2. Map pixel pairs to block characters

For each column, look at `(top_pixel, bot_pixel)`:

| top | bot | char | fg  | bg  |
|-----|-----|------|-----|-----|
| `.` | `.` | ` `  | —   | —   |
| `.` | C   | `▄`  | C   | —   |
| C   | `.` | `▀`  | C   | —   |
| A   | A   | `█`  | A   | —   |
| A   | B   | `▀`  | A   | B   |
| A   | B   | `▄`  | B   | A   (same result, pick whichever is convenient) |

Group consecutive cells that share the same `(fg, bg)` into a single ANSI span.

### 3. Use the Style DSL

The `$[fg=N,bg=M]{content}` DSL (see `spec/styles.json` and `expandTemplate` in
`src/main.zig`) emits `\x1b[38;5;Nm\x1b[48;5;Mm` before `content` and
`\x1b[0m` after.  This means each span is self-contained — no manual reset
sequences needed.

```
$[fg=220]{██}              yellow solid cells
$[fg=255,bg=220]{▄▄}      white bottom / yellow top  (teeth top edge)
$[fg=232,bg=220]{▄}       dark bottom / yellow top   (mouth corner)
$[fg=220,bg=232]{▀▀}      yellow top / dark bottom   (eyes)
$[fg=255]{████████}       solid white (teeth fill)
$[fg=232]{██████████}     solid dark  (mouth fill)
```

Colour codes used in the smiley:

| Token | Code | Description |
|-------|------|-------------|
| Y     | 220  | xterm gold-yellow (face) |
| W     | 255  | near-white (sclera, teeth) |
| K     | 232  | near-black (pupil, mouth) |

### 4. Encode in `spec/strings.json`

- **No raw ESC bytes** in JSON — they are invalid per spec and Zig's parser
  rejects them.  Write `` (6-char JSON escape) for every ESC.
- The Style DSL strings contain **no ESC at all** — colour parameters are
  resolved at runtime by `expandTemplate`.
- OSC 8 hyperlinks still need `]8;;URL\\text]8;;\\`.

To produce correct `` JSON escapes, use a Go helper script that builds
strings with actual `"\x1b"` bytes and lets `json.Marshal` encode them:

```go
const ESC = "\x1b"
lines := []string{"..." + ESC + "[38;5;220m..."}
encoded, _ := json.Marshal(lines)  // produces  in output ✓
```

Do **not** construct the `` string from raw bytes and then pass it through
`json.Marshal` — that double-encodes it to `\\u001b` (a literal backslash, not
ESC).

### 5. Wire into the rendering pipeline

`about_lines` in `spec/strings.json` are rendered by chaining:

```zig
const after_vars = expandVars(&var_expand_buf, line, &spec_vars);
text = expandTemplate(&tmpl_expand_buf, after_vars, &g_spec.styles, 0, "");
```

Pass `""` as the `search_bg` argument so no palette colour bleeds into the
trailing-space padding of grid rows.

---

## Width constraints

| Mode | `content_width` | Usable after 1-space renderer prefix |
|------|-----------------|--------------------------------------|
| TUI  | ~25 (term width) | 24 chars                            |
| GUI  | ~36 (term width) | 35 chars                            |

Pick art width and indent to fit TUI (the tighter constraint):

```
indent = (24 - art_width) / 2   →   6-space indent for 12-wide art
```

Trailing padding is added automatically by the renderer; no right-side spaces
needed in the string.

---

## Current smiley: 12×14 pixels → 7 terminal rows

```
TR  pixel rows  visual         DSL summary
0   P0+P1       " ▄████████▄ "  top arc
1   P2+P3       "██▄▄▄██▄▄▄██"  eye tops  (sclera ▄ + pupil ▄, fg=255/232 bg=220)
2   P4+P5       "██▀▀▀██▀▀▀██"  eye bots  (sclera ▀ + pupil ▀, fg=255/232 bg=220)
3   P6+P7       "█████████████"  teeth     (dark corners + solid white fg=255)
4   P8+P9       "█████████████"  dark mouth (fg=232)
5   P10+P11     "██▄▄▄▄▄▄▄▄██"  mouth arc  (fg=220 bg=232)
6   P12+P13     " ▀████████▀ "  bottom arc
```

---

## Quadrant block characters (U+2596–U+259F)

Quadrant chars divide a terminal cell into a **2×2 pixel grid** (UL, UR, LL, LR).
This gives twice the horizontal pixel resolution of half-blocks, but the same
constraint applies: **only two colours per cell** (fg fills the marked quadrants,
bg fills the rest).

| Char | Codepoint | Filled quadrants |
|------|-----------|-----------------|
| `▘`  | U+2598    | UL              |
| `▝`  | U+259D    | UR              |
| `▖`  | U+2596    | LL              |
| `▗`  | U+2597    | LR              |
| `▙`  | U+2599    | UL+LL+LR        |
| `▛`  | U+259B    | UL+UR+LL        |
| `▜`  | U+259C    | UL+UR+LR        |
| `▟`  | U+259F    | UR+LL+LR        |
| `▚`  | U+259A    | UL+LR (diagonal)|
| `▞`  | U+259E    | UR+LL (anti-diag)|
| `█`  | U+2588    | all (same as half-block) |
| ` `  | space     | none            |

The half-block chars ▀/▄ are also usable within the quad grid (they express
UL+UR and LL+LR respectively).

### Design workflow for quad art

Each **terminal cell** (tr, tc) covers pixel positions:

```
UL = pixel[tr*2][tc*2]     UR = pixel[tr*2][tc*2+1]
LL = pixel[tr*2+1][tc*2]   LR = pixel[tr*2+1][tc*2+1]
```

A 12 terminal-col × 7 terminal-row canvas encodes a **24×14 pixel image**.

Use this decision table to pick the character for each cell:

| UL | UR | LL | LR | char | fg | bg |
|----|----|----|-----|------|----|----|
| A  | A  | A  | A  | `█`  | A  | —  |
| —  | —  | —  | —  | ` `  | —  | —  |
| A  | —  | —  | —  | `▘`  | A  | —  |
| —  | A  | —  | —  | `▝`  | A  | —  |
| —  | —  | A  | —  | `▖`  | A  | —  |
| —  | —  | —  | A  | `▗`  | A  | —  |
| A  | —  | A  | A  | `▙`  | A  | —  |
| A  | A  | A  | —  | `▛`  | A  | —  |
| A  | A  | —  | A  | `▜`  | A  | —  |
| —  | A  | A  | A  | `▟`  | A  | —  |
| A  | —  | —  | A  | `▚`  | A  | —  |
| —  | A  | A  | —  | `▞`  | A  | —  |
| A  | A  | —  | —  | `▀`  | A  | —  |
| —  | —  | A  | A  | `▄`  | A  | —  |
| A  | B  | A  | B  | use two cells | — | — |
| A  | A  | B  | B  | `▀`  | A  | B  |
| B  | B  | A  | A  | `▄`  | A  | B  |
| A  | B  | …  | …  | approximate   | — | — |

### Roundness advantage

The key visible difference from the half-block version is at face corners.
Half-blocks can only express top-half / bottom-half fills; quad chars can express
corner fills, enabling genuinely round-looking corners:

```
Half-block bottom arc:   ▀████████▀   (rounded, but symmetric)
Quad bottom arc:        ▝▀████████▀▘  (sharper single-quad corners)
Half-block top-row fill: ████████████  (flat left/right edges)
Quad top-row fill:       ▟██████████▙  (single-quad corners cut off)
```

### Safety

Quadrant characters (U+2596–U+259F) render correctly in all modern terminals
that use a geometric (pixel-accurate) font renderer:

- ✅ `foot` — geometric rendering guaranteed
- ✅ `kitty`, `alacritty`, `wezterm`, `ghostty` — geometric
- ⚠️  `gnome-terminal`, `xterm` — font-dependent; may render as tofu or
     incorrectly sized if the system font lacks these codepoints

For art in `spec/strings.json` that is displayed in `about2_lines`, this is
acceptable: it degrades gracefully (the codepoints render as blank boxes in
the worst case, and the text fallback next to the art remains readable).

### The `:about2` screen

The quad-block smiley in `about2_lines` uses the same 12-col × 7-row canvas
as the half-block `about_lines` smiley, but with rounded corners:

```
TR  pixel rows  visual            Difference from about
0   P0+P1       " ▄████████▄ "   same
1   P2+P3       "▟██████████▙"   ▟/▙ corners (UL/UR quad missing)
2   P4+P5       "██WW K YY K WW██"  same (eyes)
3   P6+P7       "████████████"    solid yellow spacer (was eye-botttoms row)
4   P8+P9       "█K WWWWWWWW K█"  same (teeth)
5   P10+P11     "█K KKKKKKKK K█"  same (dark mouth)
6   P12+P13     "▝▀████████▀▘"   ▝/▘ corners (1-quad only) — more rounded
```

---

## Data-driven pipeline: `spec/art.json` + `scripts/gen_about_art`

The manual Go-script workflow above (§4 "Encode in `spec/strings.json`") has
been superseded for quad-mode art by a declarative compiler:

- **`spec/art.json`** holds `colors` (name → xterm 256-color code), `palette`
  (pixel-char → color name, or `null` for transparent), `priority` (tie-break
  order when a cell has 2+ colors), and one or more `art` entries (`shape`,
  `header`, `footer`, `indent`).
- **`scripts/gen_about_art/main.go`** (`go run ./scripts/gen_about_art/`)
  compiles each `shape` into `$[fg=N,bg=M]{...}` DSL rows and upserts them
  into the named array (`target`) in `spec/strings.json`.
- **`go run ./scripts/gen_about_art/ print`** renders the same compiled rows
  straight to stdout as live ANSI (DSL spans expanded, `$version` → `dev`)
  for fast iteration without rebuilding the Zig binary.
- **`scripts/watch_art.sh`** polls `spec/art.json` for changes and reruns
  both the compile and the `print` preview automatically.

### Quad-mode row pairing is fixed and unforgiving

`compileQuad` always groups `shape` rows into pairs `(0,1), (2,3), (4,5), …`
— row *N* unconditionally pairs with row *N+1* to form one terminal row.
There is no markup for "this row stands alone."

This means any blank/separator strip inserted between two text blocks
**must itself span an even number of rows**. A single separator row shifts
every row-pair below it by one, so a 2-row glyph gets torn across two
terminal rows and only fills one vertical half of each cell (e.g. only the
`▖`/`▗` quadrants, never `▘`/`▝`) — it looks like missing/garbled pixels even
though the source data is "clean."

When laying out multiple stacked glyphs/lines in one `shape` array, insert
separators in pairs (or omit them entirely and let glyphs touch) so every
glyph's rows land on the same `(2k, 2k+1)` pair.

### Palette chars must be canonicalized by color value, not by identity

It's tempting to give every "background/separator" role its own palette
character (`.`, `-`, `_`) so a vertical scan of the JSON shows where rows
join. But `chooseFgBg` (and the quadrant-mask computation) compares pixel
values as **palette keys**, not resolved colors. If `.`, `-`, and `_` all map
to the same color, a cell mixing them is seen as having 3 distinct "colors"
instead of 1 — the mask bits end up wrong for the chars that aren't the
chosen `fg` key. This is invisible *only* by accident, when the picked `fg`
and `bg` happen to resolve to the same color (e.g. an all-separator cell).
It becomes a real bug the moment a separator char shares a cell with an
actual content char.

Fix: precompute a `color value → canonical key` map (first match in
`priority` order) once per art entry, and normalize every pixel through it
before comparison:

```go
colorCanon := map[int]string{}
for _, p := range priority {
    if palette[p] != nil {
        if _, exists := colorCanon[*palette[p]]; !exists {
            colorCanon[*palette[p]] = p
        }
    }
}
normPx := func(ch string) string {
    if palette[ch] == nil {
        return "."
    }
    if canon, ok := colorCanon[*palette[ch]]; ok {
        return canon
    }
    return ch
}
```

Build this map (and the `normPx` closure) once outside the per-cell loop —
recreating a closure for every one of the `tcRows*tcCols` cells is wasted
allocation for no benefit.

---

## Gotchas

- **`\x1b` in Write-tool content** — the tool transmits parameters as JSON, so
  `` in the parameter becomes a raw ESC byte written to disk.  Use a Go
  script with actual `"\x1b"` constants instead.
- **`ansiDisplayWidth` runs on expanded text** — DSL spans are expanded before
  width is measured, so only the visible block characters count toward padding.
- **`search_bg` auto-reset** — `expandTemplate` emits `search_bg` after every
  span; pass `""` for art rows so the palette colour does not colour the
  trailing padding spaces.
- **`grid_bg = null`** in both themes means the terminal's own default background
  shows for transparent (`.`) pixels — which is correct for the rounded-corner
  effect.
- **Go scripts in `scripts/`** that each declare `package main` conflict when
  `go vet ./...` scans the directory.  Remove one-off helper scripts after use.
