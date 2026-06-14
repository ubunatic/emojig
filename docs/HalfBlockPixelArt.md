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
