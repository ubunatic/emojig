<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 57 — headless nested-sway canary shows a VS16 row-length defect that does NOT reproduce on the real desktop

**Priority: P3** (downgraded 2026-08-09, final — the underlying bug this
issue chased does not exist in real usage; what remains is a headless
canary-environment reliability question, not a user-facing emojig bug)

**History of this issue's title/priority, most recent first** (kept for
context — the investigation genuinely changed conclusions twice in one day,
which is itself useful to a future reader):
1. **Final**: headless-canary-only artifact (this revision).
2. **P1, "VS16 promotion doesn't hold for every base codepoint: confirmed on
   foot AND tilix, not tilix-only"** — believed real and general, based on a
   headless canary that failed reproducibly across multiple confound tests.
   **Retracted** after the user directly checked the real `--gui` foot
   window with a screenshot and confirmed correct alignment.
3. **Original**: "tilix TUI: a grid row mixing color emoji and a monochrome
   glyph renders shorter than the others" — based on a screenshot and the
   (later falsified) 🫥 hypothesis.

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

**Superseded** — see "Root cause confirmed" below: the actual glyph was
pinned down from the user's own pasted terminal text, and the 🫥 canary
addition described here was subsequently replaced (`knownIssueEmojis`, not
`sampleEmojis` — 🫥 never reproduced anything, so it wasn't kept).

**Next (superseded)**: get the user's tilix version/font details, or a fresh screenshot
with the `dotted` query typed (isolating 🫥 to the grid's first cell) taken
on the *actual* reporting machine, to narrow down which of the three
explanations above is correct before building the real-app-in-tilix reel.

## Root cause confirmed (2026-08-09, corrected) — reproduces on foot too

The user posted the *actual* short row directly (pasted terminal text, not a
screenshot): `😗  ☺️  ☺︎   😚  😙  🥲  😋  😛` — "one cell short". This is
a different, more specific and testable pair than the 🫥 hypothesis above:
**☺️ (U+263A + VS16, "smiling face") next to its ☺︎ VS15 "plain twin"**
(the plain-twin derivation is documented in `AGENTS.md §5`).

Reading `src/search.zig`'s `getEmojiWidth()`:
```zig
if (std.mem.indexOf(u8, emoji, "\xef\xb8\x8e") != null) return 1; // VS15
if (std.mem.indexOf(u8, emoji, "\xef\xb8\x8f") != null) return 2; // VS16
```
**Any** glyph containing VS16 is assumed width 2, unconditionally — there is
no check on whether the *base* codepoint is itself Unicode East-Asian-Wide.
U+263A ("smiling face") is Neutral-width, not Wide. A per-codepoint-
summation terminal (the whole VTE/Alacritty/kitty/tmux/xterm camp documented
in `docs/EmojiWidthResearch.md`) computes width as
`wcwidth(U+263A)=1 + wcwidth(VS16)=0 (zero-width formatting char) = 1`
total — **not** the 2 emojig assumes. One column short, exactly matching the
report. `☺︎` (the VS15 twin) is *not* expected to misbehave the same way:
`getEmojiWidth` already returns 1 for it, and `src/main.zig`'s per-cell `w1`
branch pads it with an extra space to fill the 4-column cell — correct as
long as the terminal also treats VS15 as zero-width, which per-codepoint
terminals generally do.

**Canary proof — reproduced via `scripts/vte_canary`'s sentinel row grid**
(the 🫥 experiment is dropped: U+1FAE5 is ≥U+1F000 and therefore
unconditionally width-2 in `getEmojiWidth`'s first check, and apparently
always-Wide in every terminal tested, so it was never going to reproduce
anything). Reproduce with:

```
go build -o /tmp/vte_canary_bin scripts/vte_canary/main.go
wayreel record --no-video scripts/vte_canary/canary-foot.reel    # or canary-tilix.reel
/tmp/vte_canary_bin -known-issue-57 -verify-rows scripts/vte_canary/shots/canary-foot.png
```

```
FAILED: row length mismatch — yellow (right edge x=97, 6px short of x=103)   [foot]
FAILED: row length mismatch — yellow (right edge x=135, 18px short of x=153) [tilix]
```

The `☺️`/`☺︎` pair lives in `knownIssueEmojis` (`scripts/vte_canary/main.go`),
gated behind the `-known-issue-57` flag rather than the default
`sampleEmojis` grid `-s`/`make canary-shots` uses — a canary that's
permanently red for a known, unfixed issue blocks unrelated build/CI work,
so it's kept runnable on demand instead (same reasoning as issue 52
excluding ptyxis from the `canary-shots` make target while keeping its
`.reel` file). Swap `knownIssueEmojis` into `sampleEmojis` (and re-add the
row to whatever verifies by default) once the underlying fix lands, turning
this into a permanent regression guard.

**Both foot and tilix fail** — including foot, with `scripts/vte_canary/canary-foot.reel`
already carrying issue 53's `tweak.grapheme-width-method=double-width`
**and** the companion `tweak.grapheme-shaping=yes` (added during this same
investigation — foot's tweak only takes effect when shaping is on). Neither
override promotes ☺️ to width 2 on the installed foot 1.27.0. This means:

- **Issue 53's "Closed (Fixed)" status is too broad.** Its fix and
  verification (headless canary + user's own manual check) both happened to
  exercise only the picker's actual top-ranked default results, which never
  included a VS16 pair on a Neutral-width BMP base codepoint. The tweak does
  fix *some* presentation-selector emoji (confirmed by issue 53's own
  research, e.g. 🖐️/🖥️-class glyphs), but not this one — foot's own
  promotion heuristic apparently doesn't treat every VS16 pair the same way
  `getEmojiWidth` does. **Not yet root-caused why** — needs either foot
  source/changelog reading or systematic per-glyph probing, out of scope for
  this pass.
- **This is not tilix-specific at all.** The original issue title/framing
  (tilix-only bug) was wrong. It's a mismatch between `getEmojiWidth()`'s
  blanket "VS16 present ⇒ width 2" rule and what real terminals (including
  the one issue 53 specifically patched) actually render for at least this
  codepoint.
- **Awaiting user confirmation**: does this exact `☺️`/`☺︎` row also render
  short in the user's real **foot** session (not just tilix)? The user's
  original "looks fine in foot" comment was about a *different* row/glyph
  (pre-🫥-hypothesis); it's not yet confirmed whether that observation
  extends to this specific pair.

## Retracted — real desktop confirms correct alignment (2026-08-09, final)

The user checked the exact pending question above directly: typed `smili`
into their real `--gui` foot window (not headless), screenshotted all 3
rows, and confirmed correct alignment — explicitly: *"If I say that 'all is
well aligned in my GUI' you can trust me. I do not overlook such things
visually."* That screenshot's row 1 contains `☺️` (position 6) among seven
other emoji, all visibly evenly spaced, no shift.

Before accepting that at face value I tried to find a measurement artifact
that could reconcile it with the headless canary's repeated FAILED result,
since a naive read would suggest the pixel measurement itself was wrong:

- **Hypothesis: the trailing glyph's bitmap art covers background pixels
  near the edge, making the row look short when it isn't.** Tested by
  swapping the row's trailing `🚀` for a plain ASCII `8`. The deficit did
  not shrink or disappear — it changed from 6px to 22px, but proportionally
  stayed at **exactly one character cell** in both cases (image geometry
  also shifted between the two runs, so raw pixel counts aren't directly
  comparable — the *proportion* is what matters). **Ruled out.**
- **Hypothesis: bitmap (Twemoji CBDT) vs. vector font selection changes the
  outcome** (the user's own suggestion, pointing at `../wayreel`/`../conreel`
  research). Tested by adding the real `--gui` launch's exact font fallback
  chain (`monospace, Twitter Color Emoji, Twemoji, Noto Color Emoji,
  OpenMoji, JoyPixels`) to the canary reel, vs. no font override at all
  (foot's bare default resolution). The deficit persisted, unchanged in
  proportion, in both cases. **Ruled out as a simple font-selection switch**
  — though see below, this doesn't rule out headless rendering in general.

Both attempts to find a measurement artifact failed — the headless
capture's pixel measurement is internally consistent and repeatable. That
means the discrepancy is real, but it lives in the **capture environment**,
not in `getEmojiWidth()` or in foot's real width handling. The most likely
explanation, per the user's pointer to today's `../wayreel`/`../conreel`
research: nested sway (used by `wayreel record` for all headless captures in
this project) forces `WLR_RENDERER=pixman` (CPU software rendering) and, per
`../wayreel/issues/01-gui-window-scaling.md`, has a documented history of
resizing spawned windows to fixed pixel geometries that don't necessarily
match what the terminal itself would compute from its own character grid —
a plausible mechanism for foot's *actual pixel-level glyph placement* to
diverge from its *logical column accounting* specifically under this
headless harness, without any bug in emojig or in foot's real-world
behavior. **This has not been proven** — it's the most likely remaining
explanation after two other hypotheses were directly tested and ruled out,
not a confirmed root cause.

**Bottom line**: issue 53's fix is correct and stays closed. `getEmojiWidth()`'s
VS16-promotion assumption is not proven wrong — the evidence that seemed to
show it wrong doesn't hold up against the real desktop. What's left open is
a narrower, lower-stakes question: *why does `scripts/vte_canary`'s headless
nested-sway capture show a row-length defect that doesn't exist on a real
desktop?* That's a canary-reliability question (possibly worth reporting
upstream to `../wayreel` if confirmed), not an emojig bug.

## Next steps

- [x] ~~Identify the exact codepoint — 🫥~~ superseded: user's pasted text
      pinned the pair to ☺️/☺︎ (U+263A + VS16/VS15) — this identification
      still stands even though the row-length conclusion drawn from it
      didn't.
- [x] Reproduced a row-length defect via headless canary
      (`scripts/vte_canary/main.go` `knownIssueEmojis`, `-known-issue-57`
      flag) — **but retracted**: does not reproduce on the real desktop
      (user-confirmed screenshot). Kept flag-gated (not in default
      `sampleEmojis`/`make canary-shots`) as a live reproduction of the
      canary-environment question below, not as a regression guard for a
      real bug.
- [x] Tested and ruled out two measurement-artifact hypotheses (trailing
      glyph bitmap coverage; bitmap-vs-vector font selection) — see
      "Retracted" above. Neither explains the canary/real-desktop gap.
- [x] Confirmed issue [53](closed/53-foot-grapheme-width-tweak.md)'s fix is
      correct and real; **not** reopening it.
- [ ] Root-cause *why* `scripts/vte_canary`'s headless nested-sway/Xvfb
      capture shows this defect when the real desktop doesn't. Leading
      candidate per the user's pointer to today's `../wayreel`/`../conreel`
      research: nested sway's forced `WLR_RENDERER=pixman` software
      rendering, or wayreel's documented history of forcing spawned windows
      to fixed pixel geometries independent of the terminal's own character
      grid (`../wayreel/issues/01-gui-window-scaling.md`) — unconfirmed,
      needs investigation in `../wayreel` itself, likely out of emojig's
      scope.
- [ ] If confirmed as a wayreel/nested-sway rendering issue: file it in
      `../wayreel/issues/` instead, since it isn't emojig-specific — any
      headless canary measuring real pixel geometry for VS16/grapheme
      content could be equally affected.
- [ ] Decide whether `scripts/vte_canary`'s pixel-based `-verify-rows`
      technique should be trusted for *any* headless VS16/grapheme-width
      check going forward, given it produced a confident, repeatable,
      confound-tested false positive here.

## Related

- Issue [51](51-vte-canary.md) — the existing VTE canary infra
  (`scripts/vte_canary`, `-verify-rows`) this issue exercised; its pixel
  measurement technique produced a false positive here, worth keeping in
  mind for future headless width canaries.
- Issue [53](closed/53-foot-grapheme-width-tweak.md) — closed and confirmed
  correct; this issue's investigation initially looked like a
  counter-example but the counter-example didn't hold up against the real
  desktop.
- `../wayreel/issues/01-gui-window-scaling.md` — documented history of
  wayreel forcing spawned terminal windows to fixed pixel geometries
  independent of the terminal's own character-grid sizing; the leading
  unconfirmed candidate explanation for this issue's canary/real-desktop
  discrepancy.
- `docs/EmojiWidthResearch.md` — background research on VTE's width model
  (still valid background reading, independent of this issue's retraction).
