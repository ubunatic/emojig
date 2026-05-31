# Issue: Emoji rendering fails in xterm

## Problem

When `emojig` is run in xterm with default settings, emoji cells are blank —
the same visual symptom as the Linux VT case. However the root cause and fix
are completely different.

## Root cause

xterm uses X11 core fonts by default, which have no emoji coverage. This is a
**configuration problem, not a hard limit**. xterm supports FreeType rendering
via `-fa` (font pattern) and has explicit emoji width handling via `-emoji_width`.

Key flags from `xterm -h`:

```
-fa pattern          FreeType font-selection pattern
-fs size             FreeType font-size
-/+emoji_width       turn on/off Emoji VS15/VS16 width convention
```

The `-emoji_width` flag controls how xterm handles the double-width variation
selectors (VS15/VS16) that emoji use. Without it, variation selector handling
can cause cell misalignment even if the glyph itself renders.

## Contrast with Linux VT

| | Linux VT (`TERM=linux`) | xterm |
|---|---|---|
| Root cause | Kernel PSF font — max 512 glyphs, hard limit | X11 core font default — no emoji coverage, but fixable |
| Fix available? | No (requires fbterm/kmscon) | Yes — pass `-fa` with a FreeType font |
| Detection | `TERM=linux` is reliable | `XTERM_VERSION` env var; `TERM=xterm*` alone is too broad |
| emojig blocks? | Yes (unless `--tui` passed) | No — xterm *can* work with the right font |

## Partial fix

Launch xterm with a FreeType font:

```sh
xterm -fa "monospace" -fs 11
```

`-fa` switches xterm from X11 core font rendering to FreeType. Most emoji
render correctly in color — but see the limitation below.

`+emoji_width` (VS15/VS16 variation selector width handling) does **not** fix
color rendering; it only affects cell-width accounting. Omit it.

## Limitation: BMP emoji render monochrome

fontconfig selects fonts by codepoint coverage. For emoji in the Supplementary
Multilingual Plane (U+1F000+), no monospace font has coverage so fontconfig
falls back to NotoColorEmoji → **color** ✓.

For BMP emoji with text-presentation default (e.g. ⚙ U+2699, ☎ U+260E), DejaVu
Sans Mono already has a monochrome glyph for those codepoints, so fontconfig
stops there and never reaches NotoColorEmoji → **monochrome** ✗.

Verified with `fc-match`:

```sh
fc-match "monospace:charset=2699"   # ⚙  → DejaVu Sans Mono (monochrome)
fc-match "monospace:charset=1f525"  # 🔥 → NotoColorEmoji  (color)
```

VS16 (`U+FE0F`) in the byte stream is a presentation hint to the renderer but
fontconfig's charset-based font selection ignores it — it picks the first font
that covers the base codepoint.

The fix requires configuring fontconfig to prefer NotoColorEmoji for emoji
codepoints over DejaVu. This is a system-level fontconfig change, not something
emojig or xterm can control from the command line.

**Practical conclusion**: xterm with `-fa "monospace"` is a partial improvement
over default xterm (most emoji render in color) but not equivalent to foot/kitty/
alacritty which handle font fallback for emoji presentation correctly.

## Detection and emojig behaviour

emojig does **not** block on xterm. `TERM=xterm` and `TERM=xterm-256color` are
set by many terminal emulators (including over SSH) that support emoji fine, so
blocking on those values would be wrong.

Detection of a "real" xterm is possible via the `XTERM_VERSION` env var, which
xterm sets and other emulators do not. However, even a real xterm works correctly
with `-fa`, so blocking would be overly aggressive. The right approach is to
document the fix (this doc) rather than guard against it in code.

## Unicode ranges — why btop works but emojig doesn't

Box-drawing, braille, and block-element characters used by TUIs like btop sit
in the Basic Multilingual Plane (U+0000–U+FFFF):

- Box-drawing: U+2500–U+257F
- Braille: U+2800–U+28FF
- Block elements: U+2580–U+259F

These have been in Unicode since the early 1990s and are covered by virtually
every monospace font. Emoji are mostly in the Supplementary Multilingual Plane
(U+1F300–U+1FFFF), added in 2010+, and require fonts explicitly designed for
them. A default xterm font covers the BMP well but has no SMP emoji glyphs.
