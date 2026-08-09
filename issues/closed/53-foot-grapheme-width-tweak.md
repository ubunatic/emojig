<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 53 — foot may need `tweak.grapheme-width-method=double-width` set explicitly

**Status: Closed (Fixed)** — `--override=tweak.grapheme-width-method=double-width`
(+ the required companion `tweak.grapheme-shaping=yes`) added to
`spec/host.yaml`'s foot `args:` and all foot-based canary reels; verified via
`make canary-gui` (leak + geometry PASS, both themes). The close-time
`[colors]` deprecation-warning fix (`footSupportsColorThemeSections` in
`src/host.zig`) is unaffected; issue
[56](../56-cache-foot-color-theme-probe.md) (probe caching) is also
unaffected.

**Was briefly reopened, then re-closed, same day (2026-08-09)** — issue
[57](../57-tilix-monochrome-mixed-row-length.md)'s headless canary (nested
sway + Xvfb, `scripts/vte_canary`) showed `☺️` (U+263A + VS16, "smiling
face") rendering width-1 (row-length short) even with both tweaks set, which
looked like a counter-example to this fix. The user then directly checked
the exact same query (`smili`) in their **real** `--gui` foot window and
confirmed — with a screenshot, and explicit "I do not overlook such things
visually" — that the row is correctly aligned there. Follow-up experiments
(swapping the trailing glyph, removing the Twemoji font override) still
showed the headless canary failing in exactly the same way regardless, which
means the discrepancy is very likely a property of the **headless
nested-sway/Xvfb capture harness itself** — not of foot's real width
handling — matching the class of headless-rendering gotcha already
documented in `../wayreel`/`../conreel`'s own research (nested sway forcing
`WLR_RENDERER=pixman` software rendering, and separately, wayreel forcing
windows to fixed pixel geometries independent of the terminal's own
character-grid sizing — see `../wayreel/issues/01-gui-window-scaling.md`).
**This fix stands as correct and verified on the real desktop.** The
canary-environment discrepancy itself is tracked as a narrowed, re-scoped
issue 57 — likely a wayreel/nested-sway problem, not an emojig one.

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

## Implementation plan (2026-08-09)

`spec/host.yaml`'s foot `args:` list (`terminals: - name: foot`) currently
ends with `--override=pad=0x4`. Add one line:

```yaml
    args:
      - "--app-id=emojig-picker"
      - "--override=title={title}"
      - "{size}"
      - "{font}"
      - "--override=cursor.blink=yes"
      - "--override=scrollback.lines=0"
      - "--override=pad=0x4"
      - "--override=tweak.grapheme-width-method=double-width"
```

No Zig changes needed — `src/host.zig` reads `args:` generically, no
placeholder substitution required for this literal flag. Same line to be
added to the `terminal = [...]` array in
`spec/reels/canary-gui-dark.reel`, `spec/reels/canary-gui-light.reel`, and
`scripts/vte_canary/canary-foot.reel` so canary captures reflect the fixed
`--gui` behavior rather than the machine's ambient `foot.ini`.

Verification: re-run `make canary-gui` and `make canary-shots`, visually
compare the `I mode=app` PNG output (grid alignment of any VS16 emoji cell)
before/after the flag is added — no new automated pixel check is strictly
required since issue 51's `-verify-rows` already measures row-length
consistency and would need to keep passing.

## Next steps

- [x] Confirmed via headless canary (`make canary-gui`, both dark/light
      reels) that the fix doesn't regress leak/geometry checks; the
      before/after VS16-width difference itself was not isolated with a
      dedicated pixel check (no existing canary asserts column width
      directly) — closure relies on the config-side fix plus the user's
      own manual GUI/TUI visual confirmation instead.
- [x] Added `--override=tweak.grapheme-width-method=double-width` to
      `spec/host.yaml`'s foot `args:` list.
- [x] Added the same override to `spec/reels/canary-gui-*.reel` and
      `scripts/vte_canary/canary-foot.reel`'s `terminal = [...]` lines.
- [ ] Path B (TUI inside a user's own foot) still depends on the user's
      own `foot.ini` — left out of scope; no startup warning added. Revisit
      only if a real user report surfaces.

## Related

- `docs/EmojiWidthResearch.md` — websearch survey of how other terminals/
  TUIs/width libraries handle emoji-width determinism; this issue's finding
  came directly out of that research (foot section).
- `docs/EnvironmentDetection.md §2`, "Grid size / GUI font" — the existing
  precedent for decoupling a spawned foot child from ambient
  config/env so behavior doesn't depend on the launching machine's state.
- Issue 50 (`../50-bg-color-leaking-in-gui.md`), 41
  (`../41-width-fit-and-cosmetic-recorder-gap.md`) — the PNG-pixel-measurement
  proof pattern this issue's verification step followed.
- Issue [54](../54-width-correction-beyond-vte.md) — next up: reassess
  whether the same VS16 gap or a ZWJ-clustering gap shows up on other
  `--gui` host terminals.
- Issue [55](../55-cursor-query-width-measurement.md) — the general
  measure-don't-guess fallback, for whatever a static config/detection
  fix like this one doesn't cover.
- Issue [56](../56-cache-foot-color-theme-probe.md) — caches/defers the
  `foot --check-config` color-theme dialect probe added while fixing this
  issue's close-time warning-flash bug, so it stops running synchronously
  on every `--gui` launch.
- foot issues [#1258](https://codeberg.org/dnkl/foot/issues/1258) and
  [#782](https://codeberg.org/dnkl/foot/issues/782).
