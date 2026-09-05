<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 054 — extend per-terminal ZWJ width correction beyond VTE

**Status**: Open
**Priority**: P2 (Medium) (currently theoretical for us — no confirmed user report
outside VTE — but the research in
[`docs/EmojiWidthResearch.md`](../docs/EmojiWidthResearch.md) shows the
underlying cause is not VTE-specific)
**Severity**: Moderate
**Category**: Bug
**Related**: archive/053, 055, docs/EmojiWidthResearch.md

---

## Summary

`src/root.zig:131-144`'s `disable_zwj` logic only checks
`TILIX_ID`/`VTE_VERSION` (plus the `EMOJIG_DISABLE_ZWJ` override). But
[`docs/EmojiWidthResearch.md`](../docs/EmojiWidthResearch.md) documents that
VTE is just one member of the "per-codepoint summation" camp — Alacritty,
kitty, tmux, and xterm all measured the same way in Mitchell Hashimoto's
cross-terminal test (🧑‍🌾 rendered at width 4, not the cluster-collapsed
width 2 that iTerm2/Contour/WezTerm produce). `spec/host.yaml`'s
`detection:` list includes `kitty`, `alacritty`, `wezterm`, `xterm` as
`--gui` host candidates — so any of those, if selected, could hit the same
ZWJ misalignment VTE does, with no current workaround applied.

Also documented: known terminal-specific width bugs beyond ZWJ that a
correction-table approach could eventually cover (foot's Fitzpatrick
skin-tone-modifier and Sinhala mismeasurement; Contour's 54 ZWJ emoji
measured Narrow instead of Wide; WezTerm's missing VS16 promotion for some
early-Unicode emoji) — see `jquast/wcwidth`'s `ucs-detect` findings, linked
from `docs/EmojiWidthResearch.md`.

## Why this needs care before implementing

Unlike issue 53 (a single static config flag on a terminal we fully
control at spawn time), this is about **detecting the terminal at
runtime** inside the `--tui` render process — which may be running as
Path B (`docs/EnvironmentDetection.md §1.B`, directly inside *any*
terminal the user chose, not one we spawned) as much as Path A. A blanket
"disable ZWJ for kitty/alacillary/tmux/xterm too" change risks disabling
ZWJ ligature rendering for users on those terminals who *do* have a font
with correct ligature/cluster support and would have rendered fine —
`disable_zwj`'s current VTE-only scope is deliberately narrow because VTE
specifically is documented (both in our own history and in this research)
to never cluster-collapse, regardless of font.

Per `docs/EmojiWidthResearch.md`'s "best practices" §2: a real
correction-table approach detects by `TERM`/`TERM_PROGRAM` first, with an
XTVERSION query (`\x1b[>q`) fallback — not a blanket per-terminal-name
ZWJ-off switch. Getting this wrong risks *regressing* ZWJ rendering for
terminals that actually handle it fine.

## Proposed approach

1. Confirm via headless canary capture (`scripts/vte_canary`-style PNG
   pixel measurement, following issue 51's pattern) whether kitty,
   alacritty, and xterm — the `spec/host.yaml`-supported `--gui` hosts most
   likely to be user-selected — actually reproduce the width-4
   non-clustering behavior for a real ZWJ test emoji (e.g. 🧑‍🌾 or
   👨‍👨‍👧) in *our* rendering path, not just in Hashimoto's generic test.
   Do this **before** changing any Zig logic — the research is secondhand
   evidence, not a confirmed reproduction against emojig's own grid.
   **Amended 2026-08-11** (see Findings below): alacritty is now the
   best-evidenced candidate, kitty is *contra*-indicated (its current
   `wcswidth_step()` does UAX #29 segmentation), and xterm has no evidence
   either way — so measure kitty specifically to rule it *out*, not to
   confirm it.
2. If confirmed, extend `disable_zwj`'s detection in `src/root.zig` using
   `TERM`/`TERM_PROGRAM` env vars (already read elsewhere for other
   purposes — check for reuse) rather than terminal-specific ID vars like
   `TILIX_ID`, since kitty/alacritty/xterm don't have an equivalent
   self-identifying var the way VTE apps do. `TERM_PROGRAM` is set by
   several (kitty sets `TERM_PROGRAM=kitty` conditionally — verify), but
   `TERM` alone (e.g. `xterm-256color`) is not conclusive since foot and
   many others also report similarly-named `TERM` values. May need a
   combination check, or may conclude only kitty/alacritty (which do set
   distinguishing vars) are practical to detect this way, leaving
   plain-xterm undetectable without an XTVERSION query (see issue 55).
3. Keep the change spec-driven if it grows beyond a couple of vars — a
   small `spec/terminal_quirks.yaml`-style table (name → `disable_zwj`
   default) would match the project's existing "behavior values belong in
   spec, not Zig" convention (`AGENTS.md` Quickstart) better than more
   inline env-var branches in `root.zig`.

## Findings from ../fontwidth research (2026-08-11)

The sibling research project `../fontwidth` now carries per-terminal
source-inspection deep-dives (`../fontwidth/docs/related/*.md`) plus two
synthesis docs (`../fontwidth/docs/TerminalWidthArchitecture.md`,
`../fontwidth/docs/TerminalTechStacks.md`) that did not exist when this
issue was written. They change the *shape* of step 1's evidence question
considerably, though they do not replace an end-to-end reproduction.

**Alacritty: non-clustering now confirmed at mechanism level, not just
black-box.** `../fontwidth/docs/related/Alacritty.md §4.2` traces the code
path: Alacritty performs **no** `unicode-segmentation` / UAX #29 grapheme
segmentation on the input stream at all. `U+200D` has `unicode-width` 0 and
is pushed into the preceding cell's `zerowidth: Vec<char>`; the *next* emoji
in the sequence is then treated as a fresh character and advances the cursor
by 2. Documented outcome: a ZWJ sequence "breaks apart into separate
individual emojis rendered side-by-side across up to 8 cells". That is the
same failure mode `disable_zwj` exists for, derived from Alacritty's
architecture rather than inferred from Hashimoto's single-emoji screenshot —
so Alacritty is the one terminal in this issue's list where extending
`disable_zwj` is well-supported by evidence.

**kitty: the premise looks stale — do not extend `disable_zwj` to kitty
without measuring.** `../fontwidth/docs/related/Kitty.md §5.3` shows kitty's
current `wcswidth_step()` (`kitty/wcswidth.c`) is a **stateful UAX #29
segmenting** stepper: it calls `grapheme_segmentation_step()` per codepoint,
returns 0 additional cells for anything with `add_to_current_cell` (which
per UAX #29 GB11 includes the emoji *after* a ZWJ), and additionally does
dynamic variation-selector correction — VS16 on a 1-cell emoji-presentation
base returns `+1`, VS15 on a 2-cell base returns `-1`. That is the opposite
of the "per-codepoint summation, no clustering" camp this issue assigns
kitty to based on `docs/EmojiWidthResearch.md`'s citation of Hashimoto's
test. Most likely reading: kitty gained grapheme segmentation after that
test was published. Consequence for step 2: turning ZWJ off for kitty would
be a **regression**, exactly the risk the "Why this needs care" section
warns about. kitty should move from "presumed affected" to "must measure
before touching".

**xterm remains entirely unevidenced.** fontwidth has no xterm deep-dive
(`XtermJS.md` is xterm.js/VS Code — a different engine with its own
`@xterm/addon-unicode-graphemes` UAX #29 addon and a user-facing
`terminal.integrated.unicodeVersion` setting, not xterm). So of the three
terminals step 1 names, fontwidth gives strong evidence for one, contrary
evidence for one, and nothing for the third.

**A second, opposite defect class this issue does not currently cover.**
`Alacritty.md §4.1` documents VS16 *under*-allocation: `U+2705 U+FE0F` gets
**1** cell from `unicode-width`, while FreeType (`FT_LOAD_COLOR`) rasterizes
a 2-cell-wide colour bitmap that then clips into the neighbouring cell. This
is the same defect class as foot's default `grapheme-width-method`
(issue [53](archive/53-foot-grapheme-width-tweak.md)) and it points the
*other* direction from ZWJ over-counting: emojig's plain-twin/VS16 pairs
(`AGENTS.md §5`) would need a "this terminal counts VS16 pairs as 1"
correction, which a `disable_zwj`-shaped flag cannot express. A correction
table therefore wants rows keyed by **quirk** (`zwj_sums_per_codepoint`,
`vs16_not_promoted`, `ambiguous_is_wide`, …), not a per-terminal boolean —
which reinforces step 3's `spec/terminal_quirks.yaml` suggestion over more
inline env-var branches.

**Terminal-name detection is structurally incomplete, because the width
policy is user-configurable on most targets.** Collected from fontwidth:
Ghostty exposes `grapheme-width-method` and negotiates Mode 2027
(`../fontwidth/docs/related/Ghostty.md §3.4`); WezTerm exposes a
`cell_widths` per-codepoint override map, `treat_east_asian_ambiguous_width_as_wide`,
and a configurable `UnicodeVersion` (`WezTerm.md §3.1-3.3`); foot has
`grapheme-width-method`; VTE has `vte_terminal_set_cjk_ambiguous_width()`
and a width code `3` = "CJK ambiguous" resolved at runtime from that setting
(`VTE.md §5`); xterm.js/VS Code has `unicodeVersion` +
`ambiguousIsFullWidth`. So a table row keyed on terminal *name* can be right
about the default and still wrong for the user in front of us. This is an
argument for scoping the table to terminals we spawn ourselves (where we
also control the config — see issue 53) and for
issue [55](55-cursor-query-width-measurement.md) covering everything else.

**The measurement harness question, partly answered.** fontwidth already
owns the machinery step 1 needs: `canaries/canary_font_width.go` spins up
its own headless sway (`WLR_BACKENDS=headless`, no Xvfb/GPU), runs a
four-colour row grid inside foot, screenshots with `grim`, and checks
whether all four colour rows reach the same right edge — and
`../fontwidth/issues/002-png-verification-spec.md` Phase 3 specifies exactly
the bounding-box `width_px` + `width_tolerance` pixel measurement this
issue's proof needs, declaratively in `spec/config.yaml` (whose `env_sets`
already include a `VTE_VERSION=7002` set). Two caveats: (a) that canary is
**foot-only** — extending it to kitty/alacritty is plausible on the same
Wayland harness, but xterm would additionally need XWayland/Xvfb; (b) it
measures *renderer* variation (`WLR_RENDERER` pixman/gles2/auto), whose
declared expectation is equal row widths across renderers — useful mainly as
evidence that the renderer backend is not a confound in headless capture.

**Cross-check on issue 53's assumption.** `canary_width_compare.zig`'s
header records a direct measurement worth knowing before writing any
foot-related width code: `libfcft` alone reports `cols=1` for `☺️` (VS16)
with Twemoji, and `grapheme-width-method` exists **only in foot's own
source**, not in `fcft.h`'s public API (grep-confirmed there). So foot's
end-to-end width cannot be predicted from the library it shapes with — a
concrete instance of why library-level or name-level prediction is fragile.

## Next steps

- [ ] Reproduce (or rule out) the width-4 ZWJ misalignment for kitty,
      alacritty, xterm via headless canary + PNG pixel proof, same pattern
      as issues 50/51/53.
- [ ] If confirmed for any: extend detection (env var, and/or spec table)
      and re-run canaries to confirm the fix doesn't regress terminals that
      handle ZWJ correctly (iTerm2/Contour/WezTerm-style cluster-collapse
      terminals aren't in our headless test matrix currently — may need to
      explicitly document as untested/out-of-scope rather than silently
      assumed fine).
- [ ] Update `docs/EnvironmentDetection.md §2` (VTE/Tilix ZWJ workaround
      section) to describe the broadened detection once implemented.
- [ ] Prefer extending `../fontwidth`'s existing headless harness
      (`canaries/canary_font_width.go` + `issues/002-png-verification-spec.md`
      Phase 3 bounding-box measurement) over building a new emojig canary —
      it already does headless-sway + `grim` + per-row right-edge
      comparison; it just needs terminals beyond foot.
- [ ] Check `../fontwidth/issues/007-mvp-width-paths-demo.md` before
      reproducing step 1 by hand: it's building exactly this evidence —
      a Go canary implementing `naive-sum`/`uax29-cluster`/`vs-dynamic`/
      `ambiguous-negotiated` each through its own authentic library stack
      (raw FreeType for the Alacritty camp, HarfBuzz+FreeType for the
      Kitty/WezTerm camp) and rendering the result to a PNG. If that lands
      first, its output may already answer "does kitty/alacritty/xterm
      reproduce this" without a separate emojig-side reproduction.
- [ ] Re-key the eventual correction table by *quirk*
      (`zwj_sums_per_codepoint`, `vs16_not_promoted`, `ambiguous_is_wide`)
      rather than by terminal name, so alacritty's VS16 under-allocation
      (opposite direction from VTE's ZWJ over-count) is expressible.

## Related

- `docs/EmojiWidthResearch.md` — full research this issue is derived from.
- `docs/EnvironmentDetection.md §2` — current VTE/Tilix ZWJ workaround
  description.
- Issue [53](archive/53-foot-grapheme-width-tweak.md) — the narrower, already-
  actionable foot-specific config fix; do that one first.
- Issue [55](55-cursor-query-width-measurement.md) — the more general
  "measure, don't guess" alternative to a per-terminal detection table.
- Issue [51](51-vte-canary.md) — the PNG-pixel-proof pattern to reuse for
  step 1's reproduction.
- `../fontwidth/issues/007-mvp-width-paths-demo.md` — the in-progress MVP
  canary that implements these four models against their authentic
  library stacks; likely the fastest path to step 1's evidence.
- `../fontwidth/docs/related/Alacritty.md` §4.1/§4.2,
  `../fontwidth/docs/related/Kitty.md` §5.3,
  `../fontwidth/docs/related/Ghostty.md` §3.4,
  `../fontwidth/docs/related/WezTerm.md` §3.1-3.3,
  `../fontwidth/docs/related/VTE.md` §5-6 — per-terminal width-engine
  source inspections behind the findings above.
- `../fontwidth/docs/TerminalWidthArchitecture.md`,
  `../fontwidth/docs/TerminalTechStacks.md` — cross-terminal synthesis
  (`wcwidth` desync, VS/ZWJ, procedural box drawing, shaping stacks).
- `../fontwidth/issues/002-png-verification-spec.md` — the declarative
  PNG bounding-box/colour-presence verification the reproduction can reuse.
