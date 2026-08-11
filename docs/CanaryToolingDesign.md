<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Canary Tooling Design: Retrospective & a Spec-Driven Redesign

Session 2026-08-09 through 2026-08-11 built three research canaries
(`scripts/canary_font.zig`, `scripts/canary_font/main.go`,
`scripts/canary_width_compare.zig` — see `docs/EmojiWidthResearch.md` for
the font-rendering findings themselves) to answer one motivating question
from issue 57: does a mixed text+emoji run measure the same width across
different rendering stacks? Ten commits later, the user characterized the
process as "spinning in circles." This doc records why that happened and
proposes a different shape for this kind of tool going forward.

---

## What actually happened, commit by commit

1. `feat(canary): add manual real-desktop font-rendering canary` — built a
   Wayland-window + screenshot tool (swaymsg/grim/D-Bus) to compare an
   on-screen render against font-only rendering.
2. `feat(canary): label renders with terminal/session metadata` — added
   provenance so screenshots could be compared across hosts.
3. `refactor(canary): drop compositor/screenshot round trip` — realized
   step 1's entire mechanism was answering a question ("does the
   compositor change anything") nobody had asked, and reverted to
   offscreen rendering.
4. `feat(canary): add Go/cgo counterpart` — added a second language
   implementation to cross-check the first, plus `-unset=` for env-var
   isolation.
5. `refactor(canary): simplify Go canary with real cairo/pango headers` —
   replaced the Go implementation's dlopen shim with a normal cgo link,
   because it had been over-engineered to avoid installing a `-dev`
   package that turned out to be free to install anyway.
6. `docs(issues): file Zig 0.16 unsetenv/environ-desync stdlib bug` — a
   real, valuable bug, but a detour discovered *while building the
   detour-mechanism* (`-unset=`) for the *original* canary, not while
   answering the motivating question.
7. `fix(canary): -font was a no-op for emoji glyphs` — discovered, four
   commits in, that the tool built in commits 1-4 had never actually been
   testing what its own name claimed since commit 1: Pango silently
   substitutes the emoji font regardless of `-font`. Every comparison run
   before this commit was vacuous.
8. `feat(canary): add width-compare tool for mixed text+emoji runs` — only
   *here*, at commit 8, did a tool that measures the actual issue-57
   question (a mixed run's combined width) get built at all.
9. `feat(canary): add libfcft column to width-compare` — added a fourth
   measurement approach, which itself needed two more bugs found and
   fixed inline (`fcft_from_name`'s name/attributes split, a zero-width
   reference-glyph choice) before it produced a trustworthy number.
10. `fix(canary): print absolute paths` — a UX polish request that
    surfaced because there was, by this point, no single obvious place to
    look at the output of any of this.

## Why this felt like circling, not converging

- **The tool that could answer the question wasn't built until step 8.**
  Steps 1-7 built infrastructure, found bugs in that infrastructure, and
  corrected framing — real work, but none of it moved the actual research
  question forward. Nothing in the first seven commits was wasted
  (the Zig stdlib bug and the Pango fallback bug are both genuine,
  independently useful findings), but none of it was the answer either.
- **Every new capability came with a new self-inflicted bug to catch.**
  hb-shape's cluster field is a codepoint index unless `--utf8-clusters`
  is passed; fcft's `name`/`attributes` are separate parameters, not one
  concatenated string; the naive-model's reference glyph was accidentally
  zero-width in the tool's own default font. Each was caught by *running
  the tool and eyeballing a suspicious number*, not by any check built
  into the tool itself. That means every future run of these tools still
  depends on a human noticing something looks wrong — there is no PASS/
  FAIL, only a table of numbers to interpret anew each time.
- **There was no stopping criterion.** "Add one more column" (Pango →
  naive → hb-shape → fcft) was each time a reasonable next step in
  isolation, but nothing defined in advance what "done" looked like, so
  the natural end state was "however many columns exist when we stopped,"
  not "the columns needed to answer a specific, pre-stated question."
- **Nothing captured what the *user* actually wants to see.** All four
  columns print whatever each library happens to compute. If the user
  has a specific expectation — "`☺️` in Twemoji should be exactly 2
  columns" — there is currently no way to say that to the tool. The user
  has to read four numbers and manually recall what they expected.

## Proposal: a declarative pixel/measurement spec, not more columns

This project already has a strong, established answer to "how do we stop
guessing and start asserting": `spec/*.yaml` is the single source of truth
for application behavior (`docs/Spec.md`), and `docs/Canary.md` already
distinguishes a canary (observe, don't yet assert) from a real check. The
width-comparison tools are still firmly in "observe" mode — every run
prints numbers for a human to judge. The natural next step, matching how
the rest of this codebase already works, is a small spec file the user
writes *once* per question they care about, checked by a tool that prints
PASS/FAIL instead of a table.

Sketch (not yet built — this is a proposal for the user to accept, adjust,
or reject):

```yaml
# spec/width_checks.yaml (illustrative — naming/shape is the user's call)
cases:
  - name: "VS16 promotes to 2 cols in Twemoji (issue 53)"
    font: Twemoji
    text: "☺️"
    expect:
      fcft_cols: 2       # foot's own decision, per canary_width_compare col 4
      tolerance_px: 2    # for any pixel-based column, if included

  - name: "VS15 stays 1 col in Twemoji"
    font: Twemoji
    text: "☺︎"
    expect:
      fcft_cols: 1
```

A single small verifier (extending `canary_width_compare.zig`, or a new
sibling) would load this file, run each case through whichever measurement
column(s) the case specifies, and print `PASS`/`FAIL` per case plus the
actual value on failure — the same shape as `zig build test`'s own
assertions, just aimed at font/terminal measurements instead of Zig code.
This also gives the tool a real regression-test role: once a case is
written down, a future Zig/fcft/Pango upgrade that changes behavior would
be caught automatically instead of requiring someone to remember to re-run
four commands and eyeball the output again.

**What this would NOT replace**: the four-column *exploratory* comparison
still has value the first time a new question comes up, before anyone
knows what to expect — it's how the `cols=1` vs `cols=2` VS16/VS15
discrepancy above was found in the first place. The spec file is for
*after* an expectation is known, to stop re-deriving it by eye every time.

## If this proposal is accepted

Suggested next issue (numbered by whoever runs the issues audit alongside
this doc, to avoid a numbering collision): "Add a declarative pixel/width-
check spec, verified by `canary_width_compare` or a new sibling tool,"
scoped as: define the YAML shape, add a `-spec=FILE` flag that runs cases
and prints PASS/FAIL, and migrate the `☺️`/`☺︎` VS16 case (issue 53's
original motivating example) into it as the first real case — proving the
mechanism on the exact discrepancy that started this whole thread.

## Session-level agentic-workflow observations

- **Empirical verification caught every real bug in this session** — the
  Pango fallback bug, the hb-shape cluster-index bug, and the fcft
  name/attributes bug were all found by *running the tool and reading
  suspicious output*, not by reading documentation first. Reading fcft.h
  before writing the struct bindings (rather than guessing layouts, as
  Cairo/Pango's opaque-pointer API allowed) avoided a whole class of
  memory-safety bugs the opaque-pointer libraries don't have — worth
  generalizing: **when a C library exposes public struct fields, get the
  real header before writing bindings, even if that means asking the
  user to install a `-devel` package first.**
- **Two independent Opus review passes** (one on the Zig `unsetenv` bug
  claim, one on the canary methodology itself) each found real, specific
  problems in this session's own prior work — including a factually wrong
  root-cause explanation in issue 58 that would have been embarrassing to
  file upstream unchanged, and a session-invalidating flaw (issue 59, the
  `-font` no-op bug) that had already shipped in two implementations
  before being caught. **Independent review before external-facing
  claims (bug reports, "here's what I found") earned its cost both
  times** — worth continuing as a standing practice for this class of
  claim, not just when explicitly requested.
- **The user's own visual confirmation overrode automated tooling
  correctly once** (issue 53/57's retraction) — a headless canary's
  pixel-measured "regression" turned out to be an artifact of the capture
  harness itself, not of emojig. This is a useful asymmetry to remember:
  synthetic/automated measurement is not automatically more trustworthy
  than a human looking at the real thing, especially when the measurement
  and the thing being measured share an unusual environment (nested
  compositor, software rendering) that the real usage doesn't.

## Related

- `docs/EmojiWidthResearch.md` — the font-rendering findings themselves
  (env vars, terminal camps, the canaries' own discovered bugs).
- `docs/Spec.md`, `docs/Canary.md` — the existing conventions this
  proposal extends rather than replaces.
- `issues/57-tilix-monochrome-mixed-row-length.md`, `issues/58-zig-unsetenv-environ-desync.md`,
  `issues/59-canary-font-research-gaps.md` — the concrete issues this
  session's work and detours produced.
