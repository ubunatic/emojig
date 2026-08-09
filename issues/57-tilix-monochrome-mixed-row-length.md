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

## Next steps

- [ ] Identify the exact codepoint under the cursor cell in the reported
      screenshot (grep `data/emoji.json`) and confirm it's genuinely
      rendered monochrome/width-1 by tilix's font fallback, not an
      unrelated rendering artifact.
- [ ] Find or construct a query whose result grid deterministically places
      that glyph beside color emoji on the same row, for a stable canary.
- [ ] Add a `canary-gui-tilix.reel` (or extend `scripts/vte_canary/`) that
      runs the real `emojig --tui` inside headless tilix and captures
      `I mode=app`.
- [ ] Decide leak-detection vs. row-length-measurement verification (see
      "Proposed canary" above) and implement whichever is simpler once the
      reel exists and a first raw screenshot can be inspected.
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
