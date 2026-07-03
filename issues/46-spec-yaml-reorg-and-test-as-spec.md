<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: in-progress
---

# spec/: reorganize a few files, and move "what to test" from prose to data

**Priority: P2**

## Summary

`spec/` has grown to **27 files / 4171 lines** (16 files feed the Zig app
via `src/spec.zig`; the rest are for other consumers — see below). Overall
health is good: `src/spec.zig` (893 lines) does real load-time invariant
checking (the null-color "punch-through" fallback chain, required-vs-
optional field conventions, xterm-256 nearest-color fallback with a
warning log), and `scripts/test_tui/spec_lint_test.go` already asserts 5
spec-as-code invariants directly against the compiled `spec/.gen/*.json`.
But there are concrete gaps and a couple of files worth reorganizing.

## 1. Two files aren't part of the app spec surface at all

`spec/crt-theme.yaml` (33 lines) and `spec/jsdemo.yaml` (44 lines) are
consumed **only** by `website/` (the JS demo) — grep-confirmed zero
references from any `src/*.zig` file, zero `src/spec.zig` struct backing,
zero `spec_lint_test.go` coverage. Same story for `spec/reels/*.yaml`,
consumed only by the external `wayreel` recorder via
`scripts/convert_spec`. Keeping these flat inside `spec/` next to the 16
files that actually back the Zig binary blurs the "spec/ IS the app"
convention — a reader/agent scanning `spec/` for app behavior has to
already know these three are irrelevant.

**Proposal**: move `crt-theme.yaml` and `jsdemo.yaml` into a `spec/web/`
subdirectory (or into `website/` directly, wherever `Makefile`/`c2w`
tooling expects them with least churn); leave `spec/reels/` where it is
since it's already namespaced as a subdirectory, just document in
AGENTS.md that `spec/reels/` and (the proposed) `spec/web/` are
non-Zig-app spec tiers.

## 2. Merge candidates

- **`spec/keys.yaml` (24 lines) → fold into `spec/input.yaml`.** Both
  files are the same "terminal input state machine" pipeline (raw bytes →
  `input.yaml`'s key-sequence table → logical name → `keys.yaml`'s
  logical-name→action bindings), currently loaded as two separate
  `@embedFile`s into two separate Zig structs (`Keys`, `InputSpec`) for no
  clear reason. A `bindings:` key nested under the existing `input.yaml`
  top-level map loses no editability.
- **`spec/styles.yaml` (14 lines) → fold into the strings spec.** It exists
  solely to support `$style{text}` templating inside `spec/strings/*.yaml`
  content — its own file header already documents that coupling. It's not
  per-locale (styles aren't translated), so it doesn't belong *inside*
  `spec/strings/en.yaml` verbatim, but a shared non-localized
  `spec/strings/_styles.yaml` (or a `styles:` block loaded alongside
  strings) would remove a fourth tiny top-level artifact.

## 3. Split candidate

**`spec/categories.yaml` (310 lines) mixes two concerns.** Lines ~1–15
(`row_pad_left`, `select_left/right`, `select_scope`, `hl_left/right/
scope`, `hl_pattern`, `select_pattern`) are pure switcher-bar *rendering*
knobs (consumed in `main.zig` ~2870–3058); lines ~16–310 are the actual
category *data* (name/short/icon/switcher/synonyms) consumed as
search/filter data. These have different edit cadences — adding a new
category shouldn't require scrolling past switcher pixel-layout fields.
Propose: keep `categories.yaml` as data-only, move the switcher-bar layout
block into `spec/layout.yaml` (which already owns other UI-chrome knobs
like `interaction`/`components`/`rows_order`) or a new small
`spec/switcher.yaml` if `layout.yaml` would get too grab-bag as a result.

Lower-priority, not urgent: `spec/layout.yaml` (59 lines) already covers 5
loosely related sub-concerns (grid dims, MRU size, exit-fade animation,
interaction step sizes, component overflow styling, row order) — fine at
current size, flag for revisit if it grows past ~100 lines or absorbs the
categories split above.

## 4. Lint coverage gap

`spec_lint_test.go` covers settings/search/host/layout/strings — **11 of
16 Zig-consumed spec files have zero Go-side lint**: `theme.yaml`,
`categories.yaml`, `commands.yaml`, `keys.yaml`, `debug.yaml`,
`input.yaml`, `synonyms.yaml`, `boxart.yaml`, `braille.yaml`, `art.yaml`,
`styles.yaml`. Not all of these need lint (boxart/braille are flat data
tables with low invariant risk), but `theme.yaml` (the null-color
punch-through contract) and `input.yaml` (key-sequence table correctness)
are the two highest-value gaps given documented past bugs in exactly these
areas (`docs/SpecDrivenConfig.md §13`'s near-black separator bug).

Also found two **hand-duplicated magic numbers** between Zig source and
the Go lint test, with no compile-time or generation-time link: (a)
`spec_lint_test.go`'s `mru_size <= 64` bound mirrors `src/mru.zig`'s
`MAX_MRU` constant by hand; (b) `spec_lint_test.go`'s `hostArgPlaceholders`
map mirrors `src/host.zig`'s `ArgValues` struct fields by hand. Either
constant drifting silently desyncs the lint test from the Zig source of
truth until someone notices by accident.

## 5. Test-as-spec: concrete proposals (prose → data)

The maintainer's stated goal is "spec/ is mostly spec-as-code checked at
compile/init/test time, not prose docs." Five concrete, scoped proposals:

1. **`spec/search.yaml` ranking regression list.** Add
   `ranking_tests: [{query: "car", expect_top: "🚗"}, ...]`, asserted
   directly against the live search engine in `src/ranking_test.zig`
   (Zig), the Go port under `scripts/test_tui` (Go), *and* flow through to
   `webspec.js` for the JS simulator — giving triple-engine parity
   checking for the exact "word-order trap" class of bug documented only
   as prose today in `docs/SearchEngine.md`.
2. **`spec/theme.yaml` punch-through contract as data.** A
   `punch_through_checks:` list naming which fields must resolve to
   `cap_fallback_idx` when null, asserted by a Zig test calling
   `buildPalette` against a null-heavy fixture theme and checking the
   exact resolved color index — turns the documented near-black-separator
   bug class (`docs/SpecDrivenConfig.md §13`) into an automated regression
   guard instead of a paragraph a future agent has to re-read and
   re-derive correctly.
3. **`spec/host.yaml` argv golden tests.** `argv_tests: [{terminal: foot,
   borderless: true, expect_contains: ["--override=csd.size=0"]}, ...]`,
   asserted against the real `src/host.zig` argv-assembly function — a
   stronger version of the existing `TestSpecHostTerminals` placeholder
   check, which today only validates placeholder *names*, not assembled
   output.
4. **Cross-link `layout.yaml`'s grid-clamp bounds to `src/defaults.zig`.**
   `MIN_COLS=5`/`MAX_COLS=16`/`MIN_ROWS=3`/`MAX_ROWS=16` currently live
   only as Zig constants, referenced from `layout.yaml` only via a prose
   comment. Add a small Zig or Go test that asserts the spec's documented
   bounds match the real constants, removing one of the two hand-mirrored
   magic-number risks from item 4 above.
5. **`spec/settings.yaml` help-line length as a lint, not just presence.**
   AGENTS.md says long help lines get truncated in the modal; today
   `TestSpecSettingsOptionsHaveHelp` only checks `Help != ""`, never
   length — silent truncation is currently unguarded. Add a
   `max_help_line_len` bound and assert every help line against it.

## Minor / not urgent

- `spec.zig`'s `DebugField.description` (`?[]const u8 = null`) has no
  YAML file ever setting it — worth a follow-up grep of the debug-pane
  renderer to confirm it's genuinely unused before deleting the field.
- `PaletteSpec.categories_bg` isn't present in either `theme.yaml` theme
  block; it resolves via `orelse s_bg_idx` fallback so this isn't a bug,
  but it's an undocumented field a maintainer scanning `theme.yaml` has no
  way to discover.

## Scope note

This issue is proposal-only; none of the merges/splits/lint additions
were applied in this review pass (all are medium-sized, cross-cutting
changes to a generator + multiple consumers, not "very small fixes").

## Resolution (2026-07-02) — non-invasive parts applied

Done in this pass:

- **§1 file moves**: `spec/crt-theme.yaml` and `spec/jsdemo.yaml` moved to
  **`spec/web/`**. Makefile gained a `SPEC_WEB` list (generated from
  `spec/web/*.yaml` into the same `spec/.gen/*.json` names, so downstream
  consumers — `make jsdemo`, `gen_web_spec` — needed no path changes beyond
  the `website/jsdemo.js` header comment). AGENTS.md Quickstart now
  documents `spec/web/` and `spec/reels/` as non-Zig-app spec tiers.
- **§4 hand-mirrored magic numbers eliminated** in
  `scripts/test_tui/spec_lint_test.go`: the `mru_size` bound is now parsed
  from `src/mru.zig`'s `MAX_MRU`, and `hostArgPlaceholders` is now parsed
  from `src/host.zig`'s `ArgValues` struct fields (new `readZigSource` /
  `zigIntConst` / `zigStructFields` helpers) — drift in either Zig source
  now fails the lint instead of silently desyncing.
- **§5.4 grid-clamp cross-link**: new `TestSpecLayoutGridBoundsMatchDefaults`
  asserts `layout.yaml` `tui`/`gui` cols/rows sit inside the
  `MIN_COLS/MAX_COLS/MIN_ROWS/MAX_ROWS` clamp parsed from
  `src/defaults.zig`.
- **§5.5 help-line length lint**: `spec/settings.yaml` gained
  `max_help_line_len: 32` (documented: content-width budget of the default
  8-col grid), and `TestSpecSettingsOptionsHaveHelp` now asserts every line
  of every option's `help` (and `help_fallback`) against it — silent modal
  truncation is now guarded.

## Resolution (2026-07-03) — §3 categories split applied

Done together with issue 44 item 4 (`src/switcher.zig` extraction): the
12 switcher-bar layout knobs moved from `spec/categories.yaml` into a
new **`spec/switcher.yaml`** (own file rather than `layout.yaml`, since
it pairs 1:1 with the new `src/switcher.zig` consumer and `layout.yaml`
was already flagged as grab-bag). `spec.SwitcherSpec` holds the knobs;
`CategoriesSpec` (root.zig, shared with the search library) is now pure
category data. Wiring: Makefile `SPEC_YAMLS` + build.zig embed list +
`src/spec.zig` load. Grep-verified `gen_web_spec`/`webspec.js` never
read the layout knobs.

Still open (invasive, left for follow-ups):

- §2 merges (`keys.yaml`→`input.yaml`, `styles.yaml`→strings tier) — touch
  the generator, `@embedFile` wiring in build.zig, and two Zig spec structs.
- §5.1 ranking regression list in `spec/search.yaml` (triple-engine parity).
- §5.2 theme punch-through contract as data (Zig-side `buildPalette` test).
- §5.3 host argv golden tests against the real argv assembly.
- §4's theme/input lint coverage gap (beyond the two magic-number fixes).
