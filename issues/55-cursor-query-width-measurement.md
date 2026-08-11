<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 55 — cursor-position-query width measurement fallback

**Priority: P3** (most future-proof option surveyed, but heaviest to build;
no confirmed user-facing bug currently requires it — do 53 and 54 first)

## Summary

[`docs/EmojiWidthResearch.md`](../docs/EmojiWidthResearch.md) documents
"measure, don't compute" as the fallback every serious width-handling
project eventually reaches for: rather than trusting any static Unicode
width table or per-terminal correction table, print the glyph, then query
the terminal's real cursor position (`CSI 6n` — Device Status Report,
already a well-supported universal escape sequence, distinct from the
newer `Mode 2027` capability-negotiation approach some terminals are
piloting) and compute width from the actual reported column delta.

This is immune to *any* terminal-specific width bug we haven't cataloged
yet (Fitzpatrick modifiers, Sinhala combos, VS16-promotion gaps, ZWJ
non-clustering, or some future terminal's own quirk) — because it doesn't
predict, it observes.

## Why this is P3, not P1/P2

- No confirmed emojig bug currently *requires* this — issues 53 and 54
  cover the two concrete gaps found so far with much smaller, targeted
  fixes.
- It requires a **synchronous terminal round-trip** (write escape sequence,
  block reading the response) for width-uncertain glyphs, which cuts
  against `AGENTS.md §5`'s zero-allocation/zero-heap-in-the-render-loop
  performance goal — even though a cursor query itself doesn't allocate,
  doing one *per uncertain glyph per render* would add real latency to the
  interactive loop we've optimized hard elsewhere (`docs/SearchEngine.md`
  hot-path notes, issue 47's synonym-scan-cost concern).
- The 6x4 grid (24 visible cells) means a naive per-cell-per-frame query
  approach would be up to 24 round-trips per redraw — likely needs to be
  scoped to a **one-time startup calibration** (query width for a small
  fixed set of "canary" glyphs representative of each width-uncertain
  class — VS16 pair, one ZWJ family sequence, one skin-tone modifier —
  once per session) rather than a per-render mechanism, to stay cheap.

## Proposed approach (calibrate-once, not query-per-render)

1. At startup (or lazily on first grid render), pick 2-3 representative
   width-uncertain glyphs already in the embedded emoji DB (one VS16 pair,
   one ZWJ sequence) that aren't already covered by a terminal-name-based
   workaround.
2. Print each probe glyph to an off-screen/scratch position (or measure via
   the normal grid render itself, since the grid already knows where each
   cell should start), issue `CSI 6n`, parse the response
   (`\x1b[row;colR`), compute the actual rendered width, and cache the
   result for the session (not per-frame).
3. Use the calibration result to override the static width table's answer
   for just that glyph class, for the remainder of the session — a
   correction layer on top of the existing Zig `width` functions
   (`isBoxArt`-style classification in `SearchEngine.md`), not a
   replacement for them.
4. Needs `docs/Zig.md`-documented care around raw `read()`/pipe handling
   for the query response (see existing subprocess/pipe patterns already
   documented there) and a timeout, since not every terminal supports
   `CSI 6n` identically and a hang here would be a serious regression
   (same class of risk as the OSC 11 `system` theme detection query in
   `src/term.zig`, which already has this exact precedent to copy from).

## Findings from ../fontwidth research (2026-08-11)

`../fontwidth`'s per-terminal source deep-dives sharpen this issue in three
ways: they strengthen the *motivation*, they suggest a **cheaper probe to try
first**, and they flag one gap the research does *not* close.

**Motivation strengthened: the width answer is user-configurable, so no
static table can be correct.** Every terminal fontwidth inspected exposes a
knob that changes its own width verdict at runtime: Ghostty's
`grapheme-width-method` plus Mode 2027 negotiation
(`../fontwidth/docs/related/Ghostty.md §3.4`); WezTerm's `cell_widths`
per-codepoint override map, `treat_east_asian_ambiguous_width_as_wide`, and
configurable `UnicodeVersion` (`../fontwidth/docs/related/WezTerm.md
§3.1-3.3`); VTE's width code `3` ("CJK ambiguous") resolved from
`vte_terminal_set_cjk_ambiguous_width()` (`../fontwidth/docs/related/VTE.md
§5`); xterm.js/VS Code's `unicodeVersion` + `ambiguousIsFullWidth`
(`../fontwidth/docs/related/XtermJS.md §3.2-3.3`); foot's
`grapheme-width-method`. A per-`TERM`/`TERM_PROGRAM` correction table
(issue [54](54-width-correction-beyond-vte.md)) can only ever encode the
*default*, and is silently wrong for any user who set the knob. Measuring is
the only mechanism that observes the configuration actually in effect.

**Corroborating measurement: the policy layer is not introspectable from
below.** `../fontwidth/canaries/canary_width_compare.zig`'s header records a
direct finding — `libfcft` alone reports `cols=1` for `☺️` (VS16) with
Twemoji, and `grapheme-width-method` exists only in *foot's own* source, with
no `grapheme_width` symbol anywhere in `fcft.h`'s public API. So even
dlopen'ing the exact shaping library a terminal uses does not predict that
terminal's grid decision. Concrete evidence that "compute it ourselves,
however carefully" has a hard ceiling.

**A cheaper probe to try before `CSI 6n`: `DECRQM` on Mode 2027.**
`Ghostty.md §3.4` documents Mode 2027 (Christian Parpart / Contour) as a
*queryable* mode — `CSI ? 2027 $ p` — that reports whether the terminal
enforces true grapheme-cluster widths or falls back to scalar `wcwidth`.
That is one round-trip, no glyphs printed, no cursor moved, and it answers
the width-*model* question directly rather than inferring it from one probe
glyph's column delta. It is the same cost class as the existing OSC 11
`system`-theme query in `src/term.zig` and reuses the identical
write-then-read-with-timeout structure. Suggested revision to the proposed
approach: make step 1 a **DECRQM 2027 probe**, and keep the `CSI 6n`
print-and-measure path as the fallback for terminals that don't answer it.
Coverage is partial but overlaps our targets: per
`docs/EmojiWidthResearch.md` Mode 2027 is implemented by Ghostty, Contour,
foot, and WezTerm — three of which are in `spec/host.yaml`'s `detection`
list.

**Related mechanism worth knowing, not worth adopting:** kitty's Text Sizing
Protocol (`../fontwidth/docs/related/Kitty.md §7`) offers both an explicit
"query how many cells this string will occupy" request *and* an "render this
string into exactly N cells" declaration — strictly better than `CSI 6n` on
kitty, but kitty-only, so it belongs in a per-terminal fast path at most, not
as this issue's primary mechanism.

**Gap this research does not close: `CSI 6n` reliability is still
unvalidated.** Nothing in `../fontwidth/docs/` mentions `CSI 6n`, DSR,
XTVERSION, or cursor-position reporting at all — the deep-dives cover
rendering and width *engines*, not escape-sequence query support. So the
"not every terminal supports `CSI 6n` identically" risk in step 4 remains
exactly as open as before, and the timeout/fallback discipline copied from
`detectSystemTheme` stays mandatory. Note also the specific hazard that
`CSI 6n` measures the *terminal's* post-print cursor column, which is the
quantity we want — but only if nothing else (a shell prompt, tmux, an
autowrap at the right margin) has moved it in between; probe in a known-safe
column, well clear of the right margin.

**Priority: unchanged at P3**, but the ordering *rationale* changes. This is
no longer merely "the most future-proof but heaviest option" — the
configurability finding above means it is the only tier that can be
*correct* for a user who has tuned their terminal. If
issue [54](54-width-correction-beyond-vte.md) step 1's measurements show the
observed width depends on the user's terminal config rather than on the
terminal's identity, this issue should be re-scored to P2 and 54's
detection-table scope narrowed to defaults only.

## Next steps

- [ ] Probe Mode 2027 via `DECRQM` (`CSI ? 2027 $ p`) *before* building the
      print-and-measure path — one round-trip, no visual side effects, and
      it answers the width-model question directly. Reuse
      `src/term.zig`'s OSC 11 timeout/parse structure.
- [ ] Confirm `src/term.zig`'s existing OSC 11 query implementation
      (`detectSystemTheme`) as the template for timeout/parsing/fallback
      behavior — this issue should reuse that pattern, not invent a new
      one.
- [ ] Prototype calibration for one glyph class (VS16 pair) behind an
      opt-in `EMOJIG_EXPERIMENTAL_WIDTH_QUERY=1` env var, measure actual
      startup latency impact.
- [ ] Decide, based on measured latency and issue 54's findings (how many
      terminals actually need this vs. how many a simple detection table
      already covers), whether this is worth shipping generally or stays
      an experimental/opt-in escape hatch for terminals nobody's added a
      static rule for yet.
- [ ] If shipped: PNG-pixel-proof verification via the same headless
      canary pattern as issues 50/51/53, comparing calibrated vs.
      uncalibrated rendering on a terminal with a known width quirk.

## Related

- `docs/EmojiWidthResearch.md` — "measure, don't compute" and Mode 2027
  sections; full research this issue is derived from.
- `src/term.zig` `detectSystemTheme` — existing OSC-query precedent to
  reuse for timeout/parsing/fallback structure.
- Issue [53](closed/53-foot-grapheme-width-tweak.md), [54](54-width-correction-beyond-vte.md) —
  smaller, more targeted fixes to do first; this issue is the fallback for
  whatever they don't cover.
- `../fontwidth/docs/related/Ghostty.md` §3.4 — Mode 2027 as a queryable
  (`CSI ? 2027 $ p`) width-model negotiation, plus `grapheme-width-method`.
- `../fontwidth/docs/related/Kitty.md` §7 — Text Sizing Protocol's explicit
  width-query / declared-cell-span requests.
- `../fontwidth/docs/related/WezTerm.md` §3.1-3.3,
  `../fontwidth/docs/related/VTE.md` §5,
  `../fontwidth/docs/related/XtermJS.md` §3.2-3.3 — the user-configurable
  width knobs that make a static per-terminal table structurally incomplete.
- `../fontwidth/canaries/canary_width_compare.zig` (header comment) —
  measured `libfcft` `cols=1` for `☺️`, and the finding that foot's
  `grapheme-width-method` lives above `fcft.h`'s public API.
- `../fontwidth/issues/007-mvp-width-paths-demo.md` — in-progress MVP
  canary that renders the static-model camps this issue's calibration
  fallback would need to override; its `-report-libs` diagnostic is the
  same "say what actually ran, don't assume it" instinct this issue's
  measure-don't-compute premise is built on.
- `../fontwidth/issues/008-app-render-graph-spec.md` — unrelated to the
  measurement mechanism itself, but shows the same "make the actual
  pipeline visible instead of assumed" principle applied to fontwidth's
  own web UI.
