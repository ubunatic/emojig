<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: in-progress
---

# Architecture, spec/, and readability review — 2026-07-02

## Task

Requested by Uwe on 2026-07-02: `src/main.zig` (4834 lines) and `spec/` have
grown substantially since the last modularization pass (issue 37, closed).
Review the codebase for:

- **Decomposition**: code in `main.zig` that should move to a dedicated
  subsystem file, so `main.zig` reads more like a table of contents and
  agents can jump straight to the right file for a feature/component.
- **Testability**: logic currently hard to unit-test in isolation because
  it's entangled in `main.zig`'s event loop / render loop.
- **Duplication**: repeated logic (esp. ANSI escape sequence emission —
  goal is one well-tested `color()`/`blue()`-style func per ANSI concern,
  not scattered raw escape codes).
- **Hard-coded constants**: values that should live in `spec/` instead of
  Zig source, per the project's "spec/ is the primary developer surface"
  convention.
- **Performance**: the query → search → render hot path (user types a
  character, `runSearch` runs, grid redraws) — zero-allocation invariant
  must hold; look for accidental allocations, repeated work, O(n^2) spots.
- **spec/ organization**: `spec/*.yaml` has grown — some files may want
  merging, others splitting. Explore adding "what to test" specs — ideally
  literal spec-as-code (asserted by `spec_lint_test.go` or `zig build test`)
  rather than prose, so spec/ stays human-editable while behavior/tests are
  checked at compile/init/test time.
- **Readability**: deep nesting, long switch/if-else chains that should be
  table/map-driven, unclear names, missing invariants (checkable at
  runtime/test time, ideally speccable).

## Deliverable

One or more new `issues/*.md` docs proposing concrete, file-referenced
refactors — not a rewrite. Small issues found along the way get fixed
directly in this pass; anything non-trivial gets written up instead with
notes for the next agent, and the speculative fix (if any was attempted)
reverted.

## Status

Done. Filed four follow-up issues with concrete file:line findings:

- [44 — `main.zig` decomposition](44-main-zig-decomposition.md): `pub fn
  main()` is 4098 of the file's 4834 lines, one function, zero helpers
  extracted since issue 37. Proposes 8 concrete extractions
  (`src/panes.zig`, `src/debug_pane.zig`, `src/settings_ctl.zig`,
  `src/switcher.zig`, `src/mouse.zig`, table-driven key dispatch, hoisting
  `RowWriter`, moving the terminal-restore trio to `src/term.zig`), plus
  the duplicated 6× scrollbar-math block. Small fix applied directly: two
  hand-duplicated `theme_str` switches replaced with the existing
  `themeName()` helper.
- [45 — ANSI escape consolidation](45-ansi-escape-consolidation.md): 145
  raw `\x1b[` literals in `main.zig`; cursor-move/clear/mode-toggle
  sequences are hand-rolled in many places despite `term.zig`/`color.zig`
  already existing for this purpose. Proposed `clearLine()`/`moveTo()`/
  `cursorHide()`/`cursorShow()` helpers. Not applied — needs byte-level
  test coverage first to avoid regressing terminal-restore safety (§2).
- [46 — spec/ reorg + test-as-spec](46-spec-yaml-reorg-and-test-as-spec.md):
  27 files/4171 lines; two files (`crt-theme.yaml`, `jsdemo.yaml`) aren't
  part of the Zig app spec surface at all and should move out; proposes
  merging `keys.yaml`→`input.yaml` and `styles.yaml`→strings, splitting
  `categories.yaml`'s UI-layout knobs out of its data table, and 5 concrete
  "prose invariant → spec-as-code" conversions (ranking regression list,
  theme punch-through contract, host argv golden tests, etc).
  Proposal-only, not applied.
- [47 — search hot-path synonym scan](47-search-hot-path-synonym-scan.md):
  **P1.** `matchTerm` in `src/search.zig` does an unconditional linear scan
  of the full synonym table (~350 entries) per query term per DB entry,
  with no early exit. Confirmed via the project's own (currently
  unasserted) `zig build test` benchmark output: non-empty queries cost
  4-5.5ms vs. ~33µs for the empty-query fast path — a ~150x jump on every
  keystroke. No accidental heap allocation found anywhere in the hot path
  otherwise (allocation audit came back clean). Not fixed directly —
  needs packer-side changes + before/after benchmarking + Zig/Go engine
  parity checks, left as a scoped follow-up with a reproducible baseline.

Research was done via three parallel investigation passes (main.zig
structure, spec/ organization, and search/render perf) before writing the
four issues above.
