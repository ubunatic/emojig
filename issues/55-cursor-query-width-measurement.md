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

## Next steps

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
