<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 57 — tilix TUI: a grid row mixing color emoji and a monochrome glyph renders shorter than the others

**Priority: P2** (a real visible misalignment in a supported "Path B" host
terminal — TUI run directly inside the user's own already-open terminal,
per `docs/EnvironmentDetection.md §1.B` — not yet covered by any canary)

## Summary

Running `emojig --tui` directly inside **tilix** (2026-08-09, user report +
screenshot), one grid row is visibly **narrower** than the rows above and
below it. The short row contains a monochrome/outline-rendered glyph mixed
in among the row's otherwise-normal color emoji — the cursor-highlighted
cell in the reported screenshot sits in that row, and the row's right edge
falls short of the other rows' right edge. **The same content renders fine
in foot** (already hardened by issue 53's
`tweak.grapheme-width-method=double-width` override, but that override is
foot-specific and inert for tilix/VTE).

This is the same width-miscounting family already documented for VTE in
`docs/EmojiWidthResearch.md` and tracked generally in issue
[54](54-width-correction-beyond-vte.md) (ZWJ sequences summed per-codepoint
instead of clustered) — but this is a **different trigger**: not a ZWJ
sequence, a single glyph that VTE's font-fallback renders as a monochrome
(non-color, likely text-presentation width-1) glyph instead of the color
double-width glyph emojig's own grid math assumes for it. Whatever codepoint
this is, VTE's wcwidth()/font-fallback disagrees with emojig's static width
table for it, exactly the class of bug issue 55's "measure, don't compute"
cursor-query fallback is meant to catch — but issue 55 is scoped as a
one-time startup calibration, not a per-glyph runtime check, so a glyph
that's *usually* double-width but occasionally falls back to a monochrome
single-width rendering (font coverage gap, not a systematic terminal
quirk) may not be caught by that fallback either. This issue is scoped
narrower: **prove the row-length regression exists reproducibly, with a
canary**, before deciding whether the fix belongs in issue 54's per-terminal
detection table, issue 55's measurement fallback, or a new font-fallback-
aware width class of its own.

## Why this wasn't caught by existing canaries

- `scripts/vte_canary` (issue 51) already renders a *synthetic* color-grid
  test pattern through tilix and verifies row lengths via
  `-verify-rows` (`verifyRowLengths` in `scripts/vte_canary/main.go`) — but
  it exercises the **standalone `vte_canary` binary's own test pattern**
  (`sampleEmojis`, all weather/BMP symbols, no real emoji-database content),
  not the **real `emojig --tui` grid** rendering actual database entries.
  A glyph that only exhibits the bug via the real font/DB lookup path (e.g.
  a specific codepoint's actual glyph coverage in the system's emoji font,
  as opposed to `vte_canary`'s hand-picked sample set) would never surface
  through that canary.
- `scripts/canary_gui` (issues 50/41/53) does capture the **real** app via
  `spec/reels/canary-gui-{dark,light}.reel` and has a proven magenta-host-bg
  leak detector (`verifyBgLeak`) that would catch exactly this class of bug
  (a short row leaves the host terminal's own background showing through
  the gap) — but those reels only spawn **foot** (the `--gui` host terminal
  emojig itself launches). Nothing currently captures the real app inside
  **tilix**, because tilix isn't a `--gui`-spawnable host at all (absent
  from `spec/host.yaml`'s `detection` list) — this bug only shows up on
  "Path B" (user's own pre-existing terminal), which by definition emojig
  doesn't spawn or control.

## Proposed canary

Combine the two existing, already-proven techniques instead of inventing a
third:

1. **Real app, not the synthetic tool** — capture `emojig --tui` itself
   (like `canary-gui-*.reel` does for foot), not `vte_canary`'s hand-built
   grid (like `canary-tilix.reel` does today).
2. **Inside headless tilix** — reuse `canary-tilix.reel`'s proven
   `$ "tilix" focus=new` + `DBUS_SESSION_BUS_ADDRESS=`/`DISPLAY=:99`
   isolation pattern (`docs/HeadlessRecording.md §7`), just running the real
   binary instead of `vte_canary_bin -s`.
3. **A query that deterministically mixes color + monochrome glyphs on one
   row** — rather than relying on the default startup grid (data-file
   ordering could drift and silently stop reproducing the bug). Needs a
   short investigation step: identify the actual codepoint from the
   screenshot's row (grep `data/emoji.json` for the glyph under the
   cursor-highlighted cell) and pick/craft a query whose top matches
   deterministically place it beside ordinary color emoji in the same row.
4. **Row-length verification** — either:
   - the `verifyBgLeak`/magenta-host-bg technique from `canary-gui-*.reel`,
     *if* tilix has some way to force its background to a distinct probe
     color for a single headless invocation (tilix has no per-launch CLI
     color override like foot's `--override=`; would likely need a
     throwaway dconf profile — needs investigation, may not be worth the
     complexity), or
   - a `verifyRowLengths`-style check (`scripts/vte_canary/main.go`'s
     existing implementation) adapted to the real app's own row background
     colors (`palette.bg`/`selection_bg` from `spec/theme.yaml`) as the
     row-boundary landmark instead of `vte_canary`'s rainbow test rows —
     simpler, no new tilix-side profile machinery needed, and reuses code
     that's already proven correct.
   The second option is likely the pragmatic starting point.

## Confirmed reproduction (2026-08-09)

The default-view screenshot's grid ordering is influenced by MRU/recency and
isn't a stable canary input on its own — but the glyph itself is:
**🫥 "dotted line face" (U+1FAE5)**, `data/emoji.json` description "dotted
line face" — a Unicode 14.0 (2021) emoji, one of the newest in the database,
and *intentionally* rendered pale/faded by design (it's meant to look
"invisible"), which is exactly why it stood out as "monochrome" in the
screenshot. New-Unicode-version glyphs are a known gap for terminal width
tables that haven't been updated (`docs/EmojiWidthResearch.md`'s
correction-table findings) — consistent with this being a VTE/tilix
per-codepoint width miscalculation rather than a rendering fluke.

**Deterministic query**: typing `dotted` (confirmed via
`go run ./scripts/screenshot zig-out/bin/emojig dotted`) reliably ranks 🫥
as the #1 result, occupying the grid's first cell every time — this is the
query the canary in "Proposed canary" step 3 should use, instead of relying
on the (MRU-dependent) default view.

## Canary added, but does NOT reproduce (2026-08-09)

Added 🫥 directly into `scripts/vte_canary`'s row-color sentinel grid
(`sampleEmojis` row 4, alongside ✨/❌/🚀 — real color emoji, mixed with the
real glyph, per the user's request to combine regular + text-based glyphs
under the existing sentinel-color/`-verify-rows` machinery rather than
inventing new infra) and ran it through the already-proven
`canary-foot.reel`/`canary-tilix.reel` pipeline (`make canary-shots`).

**Result: both foot and tilix PASS `-verify-rows` — all 4 rows reach the
same right edge, including the 🫥 row.** Visual inspection of
`scripts/vte_canary/shots/canary-tilix.png` confirms 🫥 renders at the
correct double-width cell with no length defect in this headless capture.

This is a real negative result, not a shrug: it means the row-shortening
the user saw is **not** a universal raw-ANSI-sequence width defect that
reproduces from 🫥's bytes alone in *any* tilix. Plausible explanations,
untested:
- **Font/version-specific on the reporting machine** — the headless capture
  environment's tilix version and installed emoji font may differ from the
  user's desktop tilix, and 🫥 (Unicode 14.0, 2021) is new enough that font
  coverage varies more than for older emoji.
- **Real-app-specific rendering context** — the bare `vte_canary` tool
  prints raw emoji with plain background padding, not the real app's cell
  bracket/highlight box-drawing (`⌜…⌟`) or its own cursor/selection ANSI
  sequences; the defect might only appear in that specific byte sequence,
  which only `emojig --tui` itself emits. The "Proposed canary" section's
  original real-app-in-tilix plan (steps 1-2, not yet done) would still be
  needed to rule this in or out.
- **Misidentified glyph** — 🫥 was the strongest visual candidate from the
  screenshot but was not pixel-confirmed against the original report; it
  could be a different codepoint in that row.

The canary addition itself is kept regardless (`scripts/vte_canary/main.go`
`sampleEmojis`) — it's now a permanent regression guard mixing a real,
recent-Unicode monochrome-appearing glyph with color emoji in one sentinel
row, which is worth having even though it didn't reproduce this specific
report.

**Next**: get the user's tilix version/font details, or a fresh screenshot
with the `dotted` query typed (isolating 🫥 to the grid's first cell) taken
on the *actual* reporting machine, to narrow down which of the three
explanations above is correct before building the real-app-in-tilix reel.

## Next steps

- [x] Identify the exact codepoint under the cursor cell — 🫥 U+1FAE5
      "dotted line face" (see "Confirmed reproduction" above).
- [x] Find a deterministic query — `dotted` (see "Confirmed reproduction").
- [x] Added 🫥 to `scripts/vte_canary`'s sentinel-color row grid and ran it
      through `make canary-shots` — **did not reproduce** on either foot or
      tilix in headless capture (see "Canary added, but does NOT reproduce").
      Kept as a permanent regression guard regardless.
- [ ] Get the reporting machine's tilix version + font details, or a fresh
      `dotted`-query screenshot taken there, to distinguish
      font/version-specific vs. real-app-rendering-specific vs.
      misidentified-glyph (see the three explanations above).
- [ ] If font/version-specific or real-app-specific: build the originally
      proposed `canary-gui-tilix.reel` running the real `emojig --tui`
      inside headless tilix with the `dotted` query, per "Proposed canary"
      steps 1-2 (not yet done — the canary added so far is the standalone
      `vte_canary` tool, not the real app).
- [ ] Once reproduced and proven via canary, decide the actual fix's home:
      issue [54](54-width-correction-beyond-vte.md)'s per-terminal
      detection table, issue [55](55-cursor-query-width-measurement.md)'s
      measurement fallback, or a new font-fallback-aware width class.

## Related

- Issue [51](51-vte-canary.md) — the existing VTE canary infra
  (`scripts/vte_canary`, `-verify-rows`) this issue's canary should mirror
  for the real app instead of the synthetic test pattern.
- Issue [53](closed/53-foot-grapheme-width-tweak.md) — fixed the equivalent
  width-assumption gap for foot; this issue is the same class of bug for
  tilix, where there's no equivalent config override to pin.
- Issue [54](54-width-correction-beyond-vte.md) — the general "extend
  width correction beyond VTE" tracking issue; this bug may end up as a
  concrete reproduction case for it, or may turn out to be font-coverage
  specific rather than a systematic VTE per-codepoint-summation issue.
- Issue [55](55-cursor-query-width-measurement.md) — measure-don't-compute
  fallback; relevant if this turns out to be a per-glyph font-fallback gap
  rather than a systematic terminal-class quirk.
- `docs/EmojiWidthResearch.md` — background research on VTE's width model.
- `docs/HeadlessRecording.md §7` — tilix/GTK3 headless isolation pattern.
