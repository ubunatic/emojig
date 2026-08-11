<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 61 — canary shot artifacts land untracked in `git status` with no ignore rule or commit policy

**Status: Closed (moot) — 2026-08-11.** `scripts/canary_font/` (the
directory this issue is about) moved to `../fontwidth` per
[issue 62](62-move-font-width-experiments-to-fontwidth.md); it no longer
exists in this repo, so there is nothing here to gitignore. The underlying
question (should a canary's output artifacts be tracked, throwaway, or
redirected to `/tmp`?) may still be worth deciding in `../fontwidth` if its
own `results/` directory develops the same tension — not tracked as an
emojig issue anymore.

**Priority: P3** (hygiene; no user-facing impact, but it produces steady
`git status` noise and interacts badly with `AGENTS.md §10`'s "stage commits
by explicit path" rule)

## Summary

Running the manual font canaries writes PNG + env-dump artifacts into
`scripts/canary_font/shots/`, which is **tracked** (it carries a `.gitkeep`)
but has **no `.gitignore` rule**. Every canary run therefore leaves untracked
files in `git status`, with no stated policy on whether they are throwaway
output or intended fixtures.

Observed on 2026-08-11 at the start of a tracker audit, on an otherwise clean
tree:

```
?? scripts/canary_font/shots/monospace.env.txt
?? scripts/canary_font/shots/monospace.png
```

Those two files were cleaned up later the same day, so the snapshot above is
not reproducible as-is — but the **structural** gap that produced it is
permanent and verifiable at any time:

```sh
git check-ignore -v scripts/canary_font/shots/anything.png   # → no match
git ls-files scripts/canary_font/shots/                      # → only .gitkeep
```

i.e. the directory is tracked, nothing in it is ignored, and
`make canary-font` writes into it. Any run reproduces the untracked-noise
state.

## Why it isn't simply "add it to .gitignore"

The two shot directories are treated inconsistently today, and picking a
policy requires a decision rather than a one-line ignore:

- `scripts/vte_canary/shots/` — artifacts **are committed** on purpose:
  `canary-foot.png`, `canary-tilix.png`, `canary-ptyxis.png`,
  `canary-tilix-minimal.png`, `canary-gui-dark.png`, `canary-gui-light.png`
  are all tracked. That makes sense: they are evidence attached to issues
  [50](50-bg-color-leaking-in-gui.md), [51](51-vte-canary.md),
  [52](52-ptyxis-headless-blank-capture.md) and
  [57](57-tilix-monochrome-mixed-row-length.md), and `make canary` /
  `make canary-gui` verify against recorded-good geometry.
- `scripts/canary_font/shots/` — contains only `.gitkeep`. Its artifacts are
  named after whatever `-font` the developer happened to pass
  (`<sanitized-font>.png`), so the filename set is unbounded and
  developer-specific. These look like throwaway output.

So the two directories want opposite rules, and neither is written down.

## Compounding: the filename collision already noted in issue 59

Issue [59](59-canary-font-research-gaps.md), gap 10, records that the Zig and
Go font canaries **share** the `scripts/canary_font/shots/<sanitized-font>.png`
convention, so running one then the other with the same `-font` silently
overwrites the artifact you wanted to compare — and `sanitizeForFilename`
collapses `Twemoji`/`twemoji` casing differences onto the same name too. That
makes accidentally-committing one of these files actively misleading: the
name does not record which implementation produced it.

Any fix here should be coordinated with that gap rather than cementing the
current naming.

## Suggested fix

Pick one and write it down (a comment in `.gitignore` plus a line in the
`make canary-font` target's help text would be enough):

1. **Treat `canary_font` shots as throwaway** — the option most consistent
   with `make canary-font` being documented as "manual, on-demand,
   **NOT** part of `make canary`". Add
   `scripts/canary_font/shots/*` + `!scripts/canary_font/shots/.gitkeep` to
   `.gitignore`, and leave `scripts/vte_canary/shots/` tracked as-is since
   those genuinely are issue evidence.
2. **Or redirect them out of the repo entirely** — default the output path to
   the scratch/temp dir (matching how `make canary-shots` already builds to
   `/tmp/vte_canary_bin` and `make canary-gui` to `/tmp/canary_gui_bin`),
   keeping `-out` available for the rare case where a shot should be kept as
   evidence. This removes the ignore-rule question altogether and is the
   cleaner fit for a research tool.

Option 2 is probably the better default, with option 1 as the minimum.

Either way, also disambiguate the Zig-vs-Go filenames per issue 59 gap 10
(e.g. a `.zig`/`.go` infix) so a kept artifact is self-describing.

## Next steps

- [ ] Decide throwaway-vs-tracked for `scripts/canary_font/shots/` and
      encode it (`.gitignore` and/or a changed default output path).
- [ ] Document the chosen policy where a developer will hit it — the
      `canary-font` / `canary-font-go` Makefile help strings, since those are
      the documented entry points.
- [ ] Fold in issue 59 gap 10's Zig/Go filename disambiguation while
      touching the path convention, so it is one change rather than two.
- [ ] Confirm `reuse lint` / `make preflight` are unaffected by whichever
      option is chosen (untracked binary artifacts in a tracked directory are
      a plausible source of REUSE-compliance noise, the same class of problem
      `.claude/worktrees/` was gitignored to avoid per `AGENTS.md §10`).

## Related

- Issue [59](59-canary-font-research-gaps.md) — gap 10 documents the
  overlapping-filename half of this problem.
- `AGENTS.md §10` — "Stage commits by explicit path — never `git add -A`",
  which untracked artifacts in tracked directories make easier to get wrong.
