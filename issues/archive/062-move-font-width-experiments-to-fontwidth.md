<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 062 — move font-width research experiments out of `emojig`, into `../fontwidth`

**Status**: Closed — resolved (decided and executed 2026-08-11)
**Priority**: P2 (Medium) (housekeeping/scope, no user-facing emojig behavior; but
these files currently sit in `emojig`'s own `scripts/`/`docs/`, which is
exactly the "spinning in circles" surface `docs/CanaryToolingDesign.md`
already flagged as needing a different home)
**Severity**: Minor
**Category**: Infrastructure
**Related**: 058, 059, 061

---

**Status: decided and executed (2026-08-11).** Group A (`canary_font.zig`/
`.go`) → moved to `../fontwidth/canaries/`. Group B
(`canary_width_compare.zig`) → moved to `../fontwidth/canaries/`. Group C
(`zig_unsetenv_bug_repro.zig`, `docs/Zig.md` §8, issue 58) → stayed in
emojig. See "Mechanics" below for what was actually done (the numbered
steps there are now a completed record, not a plan); `../fontwidth/issues/003-ported-emojig-font-canaries.md`
covers the porting-side details.

## Summary

`../fontwidth` is a real, already-scaffolded sibling project (own git repo,
own `AGENTS.md`, `spec/config.yaml`, `cmd/fontwidth/`, `internal/{config,
runner,web}/`, and `issues/001-web-runner-setup.md` — a phased plan for a
web UI that runs Go/Zig canaries, toggles env vars, and displays their
output/PNGs). That is materially the same tool `docs/CanaryToolingDesign.md`
proposed building on top of `canary_width_compare.zig` — it's just being
built as its own project instead of bolted onto emojig.

Meanwhile `emojig` has accumulated a full font-*width* research thread in
its own `scripts/`/`docs/` (issues 53/57/58/59, this session's ten commits)
that answers a general Pango/HarfBuzz/fcft question, not an emojig-specific
one. None of it is wrong or low-quality — the retrospective in
`docs/CanaryToolingDesign.md` covers that — but it does not belong bolted
onto emojig's own tree long-term now that a dedicated project exists.

**What stays regardless of any answer below**: `scripts/vte_canary/` (issue
51's truecolor 4×4 grid + `-verify`/`-verify-rows` pixel-coverage checks,
run via `make canary-shots`/`make canary`) is emojig's own true canary — it
proves emojig's *own* rendering (real `--gui`/`--tui` output, foot/tilix)
has no background-leak or row-length regression. That is an emojig
correctness check, not a general font-rendering research question, and it
is not part of this migration.

## Inventory — grouped for the stay-or-move decision

### Group A — `canary_font` (single-font Pango isolation, Zig + Go)

- `scripts/canary_font.zig`
- `scripts/canary_font/main.go` (+ `shots/.gitkeep`)
- `scripts/install_cairo_pango_dev.sh`
- Makefile: `canary-font`, `canary-font-go`, `canary-font-go-deps`
- Doc coverage: the "isolating font *alignment*" section of
  `docs/EmojiWidthResearch.md`

Answers: "does font X render glyph Y correctly, with fallback on/off" —
general Pango/fontconfig research, no emojig-specific code path involved
(dlopen's the same libcairo/libpango any GTK app uses).

### Group B — `canary_width_compare` (4-way width comparison incl. `libfcft`)

- `scripts/canary_width_compare.zig`
- `scripts/install_fcft_dev.sh`
- Makefile: `canary-width`
- Doc coverage: the "actual issue-57 question" section of
  `docs/EmojiWidthResearch.md`

Answers: "does a mixed text+emoji run's width agree across Pango shaping,
naive per-codepoint summation, raw HarfBuzz, and foot's own `libfcft`" —
this is the tool that *does* touch something foot-adjacent (`libfcft`
directly), but still as a general research question, not by exercising any
emojig source file.

### Group C — `zig_unsetenv_bug_repro` (Zig 0.16 stdlib bug, found via Group A)

- `scripts/zig_unsetenv_bug_repro.zig`
- `docs/Zig.md` §8 (the write-up; §9's fcft-header lesson is General-Zig
  and came from Group B, see note below)
- `issues/058-zig-unsetenv-environ-desync.md`

This one is arguably *not* a font-width experiment at all — it's a Zig
language/stdlib defect that happened to surface while building Group A's
`-unset=` flag. Its only tie to font-width is provenance. Listed as its
own group because "move everything font-width" doesn't obviously include
or exclude it, and the answer likely differs from Groups A/B.

### Not in scope for this issue (stays put either way)

- `docs/Zig.md` §9 (dlopen + public-struct-C-library lesson) is a general
  Zig-development note, not font-width-specific — stays in emojig's
  `docs/Zig.md` regardless of what happens to Groups A/B, since it's useful
  for *any* future dlopen binding work in this codebase, not just fcft.
- `docs/CanaryToolingDesign.md`'s retrospective content stays (it's about
  *how this session worked*, an emojig-agentic-process record) but its
  redesign proposal section becomes moot/superseded once Groups A/B move —
  see "Follow-up" below.
- `scripts/vte_canary/` — confirmed staying, per Summary above.
- `scripts/canary_gui/` — unrelated (GUI background-leak/geometry, issues
  50/41), not a font-width experiment, not touched by this issue.

## Decision (resolved 2026-08-11)

Asked per-group: Group A → move, Group B → move, Group C → stay. Matches
the reasoning sketched above (Groups A/B are general font-rendering
research now homed in `../fontwidth`; Group C is an emojig-development
finding that stays here regardless of where the tool that surfaced it
lives).

## Mechanics — as executed

1. Port the script(s) into `../fontwidth` under whatever structure that
   project's own conventions expect (it already has `canaries/hello.go` /
   `canaries/hello.zig` placeholders and a `cmd/fontwidth/` runner —
   check `../fontwidth/issues/001-web-runner-setup.md`'s phase plan before
   assuming a layout).
2. Remove the moved files from `emojig`'s `scripts/`/`docs/`/`Makefile`.
3. Leave a pointer, not a stub: update `docs/EmojiWidthResearch.md` (and
   `issues/57`/`58`/`59` as needed) to say "moved to `../fontwidth`, see
   issue NNN there" rather than leaving dead links or orphaned prose in
   `emojig`.
4. Re-run `make preflight` (in particular the new
   `scripts/check_docs_index` from issue-tracker-audit follow-up) to catch
   any dangling doc references the move creates.
5. Decide whether `issues/58` (the Zig stdlib bug, Group C) references
   `scripts/zig_unsetenv_bug_repro.zig` by a path that still resolves —
   if Group C moves and 58 stays (plausible: the *issue* is worth tracking
   here regardless of where the repro script lives, since it was found via
   emojig's own development), update the path/pointer rather than leaving
   it broken.

## Follow-up once decided

- If Groups A and/or B move: `docs/CanaryToolingDesign.md`'s "Proposal:
  a declarative pixel/measurement spec" section should be re-pointed at
  `../fontwidth` (which already has a superset of that idea in its own
  `issues/001-web-runner-setup.md`) rather than describing a redesign to
  build inside `emojig`.
- If Group C stays: consider whether it wants its own tiny home
  (`scripts/` is fine, it's just one file) or whether, now that it's
  decoupled from Group A, it should stop depending on Group A's presence
  in any doc cross-reference.

## Related

- `docs/CanaryToolingDesign.md` — the retrospective and redesign proposal
  this migration decision follows from.
- `docs/EmojiWidthResearch.md` — the research content that would need
  re-pointing if Groups A/B move.
- `issues/051-vte-canary.md` — the color-grid canary that stays, for
  contrast with what's proposed to move.
- `issues/057-tilix-monochrome-mixed-row-length.md`,
  `issues/058-zig-unsetenv-environ-desync.md`,
  `issues/archive/059-canary-font-research-gaps.md` — issues whose
  cross-references were updated to point at the new `../fontwidth`
  location.
- `../fontwidth/issues/001-web-runner-setup.md` — the sibling project's own
  plan, which this migration would feed.
