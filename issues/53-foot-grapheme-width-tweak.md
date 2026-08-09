<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 53 — foot may need `tweak.grapheme-width-method=double-width` set explicitly

**Priority: P2** (a real cross-user rendering-mismatch risk for the primary
GUI terminal, foot; not yet confirmed to be actively causing user-visible
misalignment)

## Summary

foot has a `[tweak]` config option, `grapheme-width-method`, controlling how
it decides the on-screen column width of variation-selector/ZWJ emoji
sequences. Its default treats a VS16 (emoji-presentation-selector) codepoint
as **zero-width** — i.e. it does not promote a base+VS16 pair to 2 columns
unless the user has explicitly set `grapheme-width-method=double-width` in
their own `foot.ini` (foot issue
[#1258](https://codeberg.org/dnkl/foot/issues/1258), related
[#782](https://codeberg.org/dnkl/foot/issues/782) for `grapheme-shaping`).

`spec/host.yaml`'s `terminals: - name: foot` args list
(`spec/host.yaml:35-61`) sets a number of `--override=...` flags for our
own spawned foot window (`csd.*`, `pad`, `scrollback.lines`, `cursor.blink`)
but **does not set `tweak.grapheme-width-method`**. That means emojig's
`--gui` picker window currently inherits whatever the *user's* `foot.ini`
happens to have — likely the foot default (not `double-width`) for most
users, since it's an opt-in tweak most people won't know to set.

If emojig's own width math (grid cell layout, VS16-derived "plain twin"
emoji, box-art/braille width classes — see `docs/SearchEngine.md`) assumes
VS16 emoji occupy 2 columns, but the user's foot instance is rendering them
as 1 (zero-width selector, default behavior), the grid will misalign for
any `--gui` user who hasn't opted into `double-width` — silently, since it
depends on the user's own config file we don't control at any other layer.

## Why this wasn't caught by existing canaries

- `scripts/vte_canary` and `spec/reels/canary-gui-*.reel` currently
  spawn foot via a `.reel`'s own `terminal = ["foot", ...]` line, which
  does **not** include a `--override=tweak.grapheme-width-method=...` flag
  either — so both the dev machine's `foot.ini` (if any tweak is set there)
  and the CI/headless capture environment (which likely has no `foot.ini`
  tweak at all, i.e. default zero-width-selector behavior) determine the
  captured result. This is the same class of "ambient environment silently
  decides the answer" bug already fixed once for `VTE_VERSION`/`TILIX_ID`
  leakage (see `docs/EnvironmentDetection.md §3`) — just via a config file
  path instead of an env var path.
- Issue 51's row-length canary (`-verify-rows`) checks pixel-measured row
  width consistency, which would catch a *within-capture* inconsistency,
  but not a systemic "every row is 1 column short of what emojig's own grid
  math assumes" offset, since there's nothing in that canary comparing
  against emojig's *intended* column count independent of what foot chose
  to render.

## Proposed fix

Add an explicit `--override=tweak.grapheme-width-method=double-width` to
the foot `args` list in `spec/host.yaml` (`terminals: - name: foot`), so
emojig's spawned foot window's width behavior is **not** dependent on the
user's own `foot.ini` — the same "decouple the spawned child from ambient
config" principle already applied to env vars via the `env VAR=... exe
--tui` tail in `src/host.zig` (see `docs/EnvironmentDetection.md §2`,
"Grid size / GUI font").

This does not help **Path B** (TUI run directly inside the user's own
already-open foot instance, per `docs/EnvironmentDetection.md §1.B`) since
we don't spawn that foot — only the `--gui` path is fixable this way. Path
B misalignment (if it occurs) would need to be either documented as a
known foot-config caveat, or handled by detecting the effective width
foot is using and adjusting emojig's own width assumptions to match
(harder, needs a real measurement — see `docs/EmojiWidthResearch.md`
"Mode 2027" / cursor-position-query approaches for how other terminals'
ecosystems handle this without static assumptions).

## Next steps

- [ ] Confirm via a headless canary capture (extend `scripts/canary_gui`
      or a new small script) whether foot's actual default
      (`grapheme-width-method` unset) really does render our VS16 "plain
      twin" / emoji-presentation pairs 1 column narrower than
      `double-width` mode, using the same PNG-pixel-measurement pattern as
      issue 50/41 (no side-channel ioctl/text-file measurements — PNG only).
  - **Note (2026-08-09):** confirmed spec-side gap only — `spec/host.yaml`
    has no `grapheme-width-method` override at all, for either state. The
    canary above would need to *add* an explicit `--override=` on one run
    and compare against a run with the setting cleared/default, since
    foot's own default is the "no override" case already.
- [ ] Add `--override=tweak.grapheme-width-method=double-width` to
      `spec/host.yaml`'s foot `args:` list.
- [ ] Add the same override to `spec/reels/canary-gui-*.reel` and
      `scripts/vte_canary/canary-foot.reel`'s `terminal = [...]` lines so
      canary captures reflect the same fixed behavior emojig's real
      `--gui` launch will use, once fixed — not whatever `foot.ini` happens
      to be present on the machine running the canary.
- [ ] Decide whether Path B (TUI inside a user's own foot) needs a startup
      warning/doc note, or is out of scope (we don't control that foot
      instance's config).

## Related

- `docs/EmojiWidthResearch.md` — websearch survey of how other terminals/
  TUIs/width libraries handle emoji-width determinism; this issue's finding
  came directly out of that research (foot section).
- `docs/EnvironmentDetection.md §2`, "Grid size / GUI font" — the existing
  precedent for decoupling a spawned foot child from ambient
  config/env so behavior doesn't depend on the launching machine's state.
- Issue 50 (`50-bg-color-leaking-in-gui.md`), 41
  (`41-width-fit-and-cosmetic-recorder-gap.md`) — the PNG-pixel-measurement
  proof pattern this issue's verification step should follow.
- foot issues [#1258](https://codeberg.org/dnkl/foot/issues/1258) and
  [#782](https://codeberg.org/dnkl/foot/issues/782).
