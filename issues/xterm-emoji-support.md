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

## Fix

Launch xterm with a FreeType font:

```sh
xterm -fa "monospace" -fs 11
```

That's it. `-fa` switches xterm from X11 core font rendering to FreeType.
fontconfig's monospace stack includes emoji fallback (NotoColorEmoji or similar)
automatically on most modern Linux systems — **color emoji render correctly**
without any additional flags.

`+emoji_width` (VS15/VS16 variation selector width handling) was not needed in
testing; omit it unless you see cell alignment issues with specific emoji.

The font name is a fontconfig pattern, so any font discoverable by `fc-list`
works. `monospace` is the safest default.

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
