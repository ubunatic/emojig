<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 059 — `canary_font` research gaps found by independent review

**Status**: Closed — resolved (moved 2026-08-11)
**Priority**: P3 (Low) (research-tool correctness, not shipped emojig behavior)
**Severity**: Minor
**Category**: Infrastructure
**Related**: 062

---

**Status: Closed (moved) — 2026-08-11.** The two critical gaps below were
fixed here first. The tools themselves (`canary_font.zig`/`.go`,
`canary_width_compare.zig`) have since moved to `../fontwidth` per
[issue 62](62-move-font-width-experiments-to-fontwidth.md); the remaining
"not yet fixed" gaps (3-10) travel with them and are now tracked in
`../fontwidth/issues/003-ported-emojig-font-canaries.md` rather than here.
Kept closed (not deleted) for the historical record of what was found and
fixed while the tools still lived in this repo.

## Summary

An independent Opus review of `scripts/canary_font.zig` and
`scripts/canary_font/main.go` (the font-*alignment* research canaries —
see `docs/EmojiWidthResearch.md`) found two critical gaps that invalidated
conclusions drawn so far, both **fixed immediately** as part of this
issue, plus a list of smaller, real gaps left open for later.

## Fixed

1. **`-font` was a no-op for emoji glyphs specifically.** Pango's default
   per-run font fallback silently substitutes a different family for any
   codepoint tagged `Emoji_Presentation` (e.g. 🚀), regardless of `-font`,
   even when the requested font covers the glyph — verified directly with
   `hb-shape /usr/share/fonts/twemoji/Twemoji.ttf --unicodes=1F680`
   returning a real, non-`.notdef` glyph (`gid964`), while unmodified
   Pango rendered that same codepoint with Noto Color Emoji regardless of
   `-font=Twemoji`. Every CBDT-vs-COLR comparison made with these canaries
   before this fix was comparing the exact same rendering regardless of
   the flag.

   **Fix**: both implementations now disable Pango's fallback by default
   (`pango_attr_fallback_new(FALSE)` via a `PangoAttrList` set on the
   layout) before measuring/rendering, restoring `-font` as a real,
   literal switch. A font that genuinely lacks a glyph now shows a
   tofu/notdef box instead of silently substituting — an honest result
   instead of a hidden one. `-allow-fallback` restores the old permissive
   behavior for comparison if ever needed.

2. **Wrong stack for the motivating question.** `foot` (emojig's default
   `--gui` host terminal) links no Pango/Cairo at all — it uses
   `libfcft`+FreeType+HarfBuzz directly (`ldd $(command -v foot)` shows no
   `libpango`) — and no terminal lays out its grid via `pango_layout` in
   the first place. So this canary was never able to speak to foot's
   behavior or to terminal grid alignment (the actual subject of issue
   57's VS16 row-length question), only to the Pango/Cairo/fontconfig
   stack itself (GTK apps, VTE-based terminals).

   **Fix**: documented explicitly, in both source files' top comments,
   both `-help` outputs, and `docs/EmojiWidthResearch.md` — this canary's
   scope is the Pango stack only, not foot, not terminal grids.

   **Superseded by an actual capability (2026-08-11 audit).** The
   documentation-only fix above has since been overtaken by a real tool that
   closes the substantive half of this gap:
   **`scripts/canary_width_compare.zig`** (`make canary-width
   WIDTH_TEXT="..." FONT="..."`, added in commits `b81763e` / `483dcf5`)
   compares four width models side by side over one mixed text+emoji run —
   (1) Pango/HarfBuzz shaping, (2) deliberately naive per-codepoint
   `wcwidth()`-style summation matching the VTE/Alacritty/kitty/tmux/xterm
   camp, (3) raw `hb-shape` against the resolved font file, and
   (4) **foot's own `libfcft`, dlopen'd directly and driven through
   `fcft_rasterize_text_run_utf32`**, reporting both fcft's own `.cols`
   decision and the actual `.advance.x` pixel advance per glyph.
   Column 4 is precisely the "wrong stack" complaint above: it is foot's
   real shaping code, called offscreen with no terminal, no compositor and
   no wayreel involved — so this research thread is no longer blind to
   foot, and no longer has to infer foot's behavior from a screenshot.

   What remains genuinely out of reach (so this gap is narrowed, not
   eliminated): **no terminal's grid-layout logic is exercised by any of
   these canaries.** `libfcft` answers "how does foot shape and advance
   this run", not "how does foot assign it to grid cells", which is
   separate code in foot itself. Anything needing the latter still requires
   capturing the real terminal — the route issue
   [57](57-tilix-monochrome-mixed-row-length.md) took, and whose headless
   trustworthiness is that issue's remaining open question.

## Not yet fixed (tracked here)

Ranked by how much each could still mislead a conclusion, most important
first:

3. **Silent font-resolution and glyph failures aren't reported.**
   `-font="ThisFontDoesNotExist123"` renders happily, indistinguishable
   from a real result — no resolved-font-file, per-run fallback list, or
   missing-glyph/tofu count is printed. Even with fallback disabled
   (fixed above), a typo'd family name currently just falls through to
   whatever fontconfig's own default substitution picks, silently.
   → Fix idea: after layout, walk `PangoLayoutIter` runs, print each
   item's `pango_font_describe()` result (the *actually used* font, not
   just what was requested) and flag any run whose family doesn't match
   `-font`.

   **Concrete case found (2026-08-10), not a bug — a silent, correct-but-
   surprising result of this class**: `-font=Twemoji -text="123"` renders
   *nothing at all*, with a measured width of `0x95px` — not tofu, not a
   missing-glyph box, genuinely zero advance width. Confirmed directly at
   the font level with `hb-shape /usr/share/fonts/twemoji/Twemoji.ttf
   --unicodes=0031` → `{"g":"gid7","ax":0}`: Twemoji.ttf deliberately maps
   bare ASCII digits to a real (non-`.notdef`) but zero-width placeholder
   glyph, intended only as the *base* of a keycap emoji sequence. The full
   sequence `1️⃣` (`U+0031 U+FE0F U+20E3`) shapes to a completely different,
   real-width glyph (`hb-shape --unicodes=0031,FE0F,20E3` → `{"g":"gid1452",
   "ax":2533}`) and renders the expected blue keycap square. Neither
   fallback-disabling (fixed above) nor anything else in this canary can
   or should "fix" this — it's correct behavior once you know Twemoji's
   digit glyphs are combining-sequence bases, not standalone glyphs — but
   it's exactly the kind of silent, correct-yet-surprising result this
   gap's fix (report the actually-used font *and* a zero/notdef-advance
   flag per run) would have surfaced immediately instead of needing manual
   `hb-shape` investigation to explain.

4. **The baked metadata label contaminates the artifact being compared.**
   The label is drawn into the same PNG and participates in the image's
   measured width (`max(text_w, label_w) + 2*pad`), so an env/host
   difference that only changes the label text can change the PNG bytes
   *and* canvas width even when glyph rendering is pixel-identical —
   breaking any naive "diff the two PNGs" comparison. Compounding it. the
   two implementations currently use different label gaps
   (`label_gap = 6` in Zig vs `labelGap = 16` in Go), so images differ in
   height even when the measured text itself matches exactly.
   → Fix idea: write the label only to the sidecar (or a separate
   `<out>.label.png`), and unify the gap constant across both
   implementations.

5. **Env dump is written *after* `-unset`, and omits key provenance.**
   Both implementations unset env vars before writing the dump, so an
   unset var records as `(unset)` — indistinguishable from "was never
   set." The dump also omits the `-unset` list itself, hostname, and
   library versions (Pango/Cairo/fontconfig/FreeType), so two hosts
   differing only by a Pango minor version would be unattributable from
   the artifact alone.
   → Fix idea: snapshot env *before* unsetting; add `unset=`,
   `hostname=`, and `pango_version_string()`/`cairo_version_string()`/
   `FcGetVersion()` to the dump.

6. **Measurement is whole-pixel only, for research explicitly about
   subpixel alignment.** Only `pango_layout_get_pixel_size` (rounded) is
   captured; `pango_layout_get_size` (1/1024-unit precision), ink vs.
   logical extents, and per-cluster advances are all available and
   discarded — the per-cluster advances are exactly the quantity a VS16
   alignment question needs. Also: `FREETYPE_PROPERTIES`
   hinting-interpreter-version and hint-style variations produced *no*
   measurable difference in testing (Pango appears to use unhinted
   advances here), meaning the env-var lens currently has no positive
   control proving it can detect a hinting-caused difference at all —
   only `FONTCONFIG_FILE` was confirmed to move the needle.
   → Fix idea: also print `pango_layout_get_size` and per-cluster
   advances; add one *known*-sensitive var as a self-test.

7. **The env-var lens can't see the dominant real-app variable.** GNOME's
   `font-hinting`/`font-antialiasing`/`text-scaling-factor` (verified via
   `gsettings get org.gnome.desktop.interface ...`) reach real GTK apps
   through GSettings → XSettings → GDK → `cairo_font_options`, not through
   any env var, and this canary never calls `cairo_*_set_font_options`, so
   it silently inherits the image surface's defaults regardless of what a
   real terminal/app would use. A `~/.config/fontconfig/fonts.conf` (none
   present on this host, but not recorded anywhere if one existed) would
   also silently dominate. `LC_CTYPE` (distinct from `LC_ALL`/`LANG`) is
   missing from the tracked var list.
   → Fix idea: record effective `cairo_font_options`
   (hint_style/hint_metrics/antialias/subpixel_order) and the GNOME
   gsettings values in the dump; add `LC_CTYPE`.
   → Confirmed NOT a gap: `GDK_SCALE`/`GDK_DPI_SCALE`/`QT_SCALE_FACTOR`/
   `QT_FONT_DPI`/`XDG_CACHE_HOME` were tested and correctly have no effect
   (`set_absolute_size` bypasses DPI resolution entirely; an alternate
   `XDG_CACHE_HOME` produced a byte-identical PNG) — this immunity is real
   but was previously unstated.

8. **Test size (48px) is a size no terminal cell ever uses.** CBDT bitmap
   strike selection and hinting behavior are both size-gated (this host
   has `/etc/fonts/conf.d/20-unhint-small-dejavu-sans-mono.conf`, active
   only below a threshold size); a defect only visible at a real ~13-17px
   terminal cell size wouldn't show at the current default.
   → Fix idea: default to (or sweep) realistic sizes, e.g. 13/14/17px.

9. **The baked label invites exactly the "which terminal rendered this"
   misreading.** The label records only which shell's env the *process*
   inherited (`term=tilix`), not anything about how the glyphs were
   rendered — this canary's rendering is 100% terminal-independent
   (offscreen, no terminal involvement at all). A reader comparing
   `term=tilix` vs `term=foot` labeled PNGs could easily misread that as
   "how it renders in tilix vs foot," a conclusion these canaries cannot
   support (see gap 2).
   → Fix idea: rename the field to `invoked-from=` and note
   "(rendering is terminal-independent)" in the label or sidecar header.

10. **Smaller code-level issues:**
    - Both implementations default to the same output path convention
      (`scripts/canary_font/shots/<sanitized-font>.png`), so running the
      Zig canary then the Go canary with the same `-font` silently
      overwrites the pair you wanted to compare; `sanitizeForFilename`
      also collapses `Twemoji`/`twemoji`-style casing differences into the
      same filename.
    - `cairo_surface_write_to_png`'s status return is discarded in both
      implementations, so `canary_font: saved <path>` prints even on a
      write failure.
    - Go's `pixels`/`scratchPixels` are plain Go-allocated slices handed
      to `cairo_image_surface_create_for_data`, which retains those
      pointers past the call — legal today only because Go's current GC
      doesn't move heap objects; a future moving collector would break
      this silently. Fix would be `C.malloc`-backed buffers or
      `runtime.Pinner`.
    - Neither sets `pango_layout_set_single_paragraph_mode`, wrap, width,
      or base direction — a `-text` containing a newline silently becomes
      multi-line with no indication; bidi direction is auto-detected from
      content. Not a problem for the current ASCII+emoji test corpus, a
      hazard if it ever grows to include RTL/multi-script text.

## What's already confirmed sound (no action needed)

- The `-unset` mechanism genuinely reaches fontconfig in both
  implementations (verified with `FONTCONFIG_FILE` as a positive
  control — unsetting it correctly restored baseline metrics in both).
- No sway/wlroots-specific assumption exists in either implementation;
  nothing branches on compositor, so GNOME vs. sway cannot silently skew
  a result.
- The offscreen-rendering design genuinely runs identically in a
  sandboxed/CI shell as in a real desktop session — no D-Bus/session
  dependency, confirmed with an alternate `XDG_CACHE_HOME` producing a
  byte-identical PNG.
- The offscreen premise is sound as far as *compositor* effects go
  (fractional scaling, colour management are genuinely post-layout); it
  was gap 2 above, not the compositor, that actually limits this
  canary's scope.

## Related

- `scripts/canary_font.zig`, `scripts/canary_font/main.go` — where gaps 1
  and 2 were fixed.
- `docs/EmojiWidthResearch.md` — canary_font section, corrected to match.
- `issues/057-tilix-monochrome-mixed-row-length.md` — the original
  motivating question (VS16 grapheme alignment) that gap 2 means this
  canary was never actually able to answer.
- `docs/Zig.md` §8 — the separate `unsetenv`/`environ` stdlib bug found
  while building `-unset=`, tracked in
  `issues/058-zig-unsetenv-environ-desync.md`.
