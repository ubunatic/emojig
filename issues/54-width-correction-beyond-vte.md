<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 54 — extend per-terminal ZWJ width correction beyond VTE

**Priority: P2** (currently theoretical for us — no confirmed user report
outside VTE — but the research in
[`docs/EmojiWidthResearch.md`](../docs/EmojiWidthResearch.md) shows the
underlying cause is not VTE-specific)

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

## Related

- `docs/EmojiWidthResearch.md` — full research this issue is derived from.
- `docs/EnvironmentDetection.md §2` — current VTE/Tilix ZWJ workaround
  description.
- Issue [53](closed/53-foot-grapheme-width-tweak.md) — the narrower, already-
  actionable foot-specific config fix; do that one first.
- Issue [55](55-cursor-query-width-measurement.md) — the more general
  "measure, don't guess" alternative to a per-terminal detection table.
- Issue [51](51-vte-canary.md) — the PNG-pixel-proof pattern to reuse for
  step 1's reproduction.
