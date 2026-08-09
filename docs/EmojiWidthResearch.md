<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# Emoji Width Research: How Other Terminals, TUIs & Libraries Handle It

A websearch survey (2026-08-09) of how other projects solve deterministic
emoji column-width — the same problem emojig faces rendering its borderless
grid across `foot`, VTE-based terminals, and bare Linux VT consoles. Kept
here to re-read before touching width/grapheme logic, alongside
[`SearchEngine.md`](SearchEngine.md) (box-art/braille width classes) and
[`EnvironmentDetection.md`](EnvironmentDetection.md) (terminal
self-detection). Filed as issue [53](../issues/closed/53-foot-grapheme-width-tweak.md)
for the one directly actionable finding (foot's `grapheme-width-method`).

## TL;DR

There is **no converged industry standard** for how wide a ZWJ emoji
sequence or a VS16-presentation-selected emoji should be on screen. Every
mature terminal and every width-calculation library has, at some point,
shipped a production emoji/ZWJ column-corruption bug. Two mutually
incompatible "correct" models compete, terminal-detection + correction
tables is the most mature mitigation anyone has, and a couple of newer
terminals are experimenting with query/declare protocols instead of static
heuristics. Our own `VTE_VERSION`/`TILIX_ID`-gated `disable_zwj` workaround
(`src/root.zig`) is architecturally the same shape as what everyone else who
takes this seriously ends up building.

## The two competing width models

1. **Cluster-collapse**: width = the width of the whole grapheme cluster's
   *rendered* glyph, treating ZWJ-joined codepoints as one unit.
   Used by: iTerm2, Contour, WezTerm; Go's `go-runewidth` (after fixing
   [#28](https://github.com/mattn/go-runewidth/issues/28) /
   [PR #29](https://github.com/mattn/go-runewidth/pull/29)).
2. **Per-codepoint summation**: width = sum of each codepoint's individual
   Unicode East-Asian-Width property, ZWJ or not.
   Used by: Alacritty, kitty, tmux, xterm, **VTE** (gnome-terminal, tilix,
   ptyxis, xfce4-terminal); Python's `uwcwidth`.

Mitchell Hashimoto's cross-terminal test of 🧑‍🌾 (wcwidth-sum = 4) found:
iTerm2/Contour/WezTerm render it as width 2 (full clustering); **Alacritty,
Kitty, tmux, xterm render it as width 4** (no clustering); Terminal.app 6,
Windows Terminal 5 (partial clustering). Six terminals, four different
answers, for one emoji. ([mitchellh.com/writing/grapheme-clusters-in-terminals](https://mitchellh.com/writing/grapheme-clusters-in-terminals))

This directly confirms our `VTE_VERSION`/`TILIX_ID`-gated ZWJ workaround is
not an outlier hack — VTE genuinely does not cluster-collapse, consistent
with the wider per-codepoint-summation camp.

## Findings by project

### Jeff Quast's `wcwidth` + `ucs-detect` (Python)

- **Technique**: `wcstwidth()` applies a per-terminal *correction table* on
  top of standard Unicode width, built from empirical measurement across
  ~35 real terminals (`ucs-detect`). Example: `wcwidth('🧟‍♂')==2` but
  `wcstwidth(..., term_program='VTE')==8` (VTE sums per-codepoint, no
  clustering).
- **Detection cascade**: `TERM` (SSH-safe) → `TERM_PROGRAM` (unreliable over
  SSH) → XTVERSION query (`\x1b[>q`, supported by 21/35 tested terminals) →
  ENQ fallback.
- **Terminal-specific bugs found** (useful to cross-check against emojig's
  own width tables):
  - **foot**: mis-measures Fitzpatrick skin-tone modifiers as width 1 (not
    2), and some Sinhala combining sequences as Narrow.
  - **Contour**: 54 ZWJ emoji measured Narrow instead of Wide; missing VS16
    promotion for keycap digits.
  - **WezTerm**: missing VS16 promotion for some early-Unicode-version
    emoji.
  - **Windows Terminal**: shares foot's Fitzpatrick/Sinhala bugs.
- Links: [correction tables](https://www.jeffquast.com/post/perfecting-terminal-character-width-using-correction-tables/),
  [terminal battle royale results](https://www.jeffquast.com/post/ucs-detect-test-results/),
  [wcwidth PR #97 (VS16)](https://github.com/jquast/wcwidth/pull/97),
  [PR #91 (ZWJ)](https://github.com/jquast/wcwidth/pull/91)

### Mitchell Hashimoto — grapheme clusters in terminals

- Proposes **Mode 2027** (`CSI ?2027$p` query, `h`/`l` to set) — a
  capability-negotiation escape sequence for grapheme-cluster-aware width.
  Supported (as of research date) only by Ghostty, Contour, foot, WezTerm.
- Also documents "measure, don't compute" as the fallback of last resort:
  query real cursor position (`CSI 6n`) after printing, rather than trusting
  any static width table.
- Link: [mitchellh.com/writing/grapheme-clusters-in-terminals](https://mitchellh.com/writing/grapheme-clusters-in-terminals)

### foot — `[tweak] grapheme-width-method` (directly actionable — see issue 53)

- **Bug**: presentation-selector emoji (🖐️) misaligned in foot and
  Alacritty, not kitty — foot's default `wcswidth()` treats the VS16
  selector as zero-width, so it doesn't promote the pair to 2 columns.
- **Fix is a config knob, not a code change on foot's side**:
  `foot.ini` `[tweak] grapheme-width-method=double-width` switches foot to
  promote presentation-selected emoji to width 2. Default is *not*
  `double-width` — most users never set this. Related:
  `grapheme-shaping=false/true` ([#782](https://codeberg.org/dnkl/foot/issues/782))
  controls ligature *shaping* independently of width.
- **Emojig-specific implication**: since we spawn our own foot window for
  `--gui`, this is a config *we* control via `spec/host.yaml`'s foot `args:`
  list — currently unset there, meaning behavior silently depends on
  whatever the launching user's own `foot.ini` happens to contain. Filed as
  [issue 53](../issues/closed/53-foot-grapheme-width-tweak.md).
- Links: [foot #1258](https://codeberg.org/dnkl/foot/issues/1258),
  [foot #782](https://codeberg.org/dnkl/foot/issues/782)

### VTE (gnome-terminal / tilix / xfce4-terminal)

- Confirmed bug pattern: regional-indicator flag pairs sometimes render as
  literal letter pairs instead of merging into a flag glyph; Unicode 9+
  wide emoji sometimes render overlapping/single-width depending on the
  installed font.
- No explicit width "policy" document found on VTE's own tracker — this
  corroborates rather than adds new mechanism beyond what we already assume
  in `disable_zwj`.
- Links: [VTE emoji flags](https://gitlab.gnome.org/GNOME/vte/-/work_items/162),
  [Ubuntu LP #1665140](https://bugs.launchpad.net/bugs/1665140)

### kitty — text-sizing protocol / Unicode-width RFC (design direction, not a fix)

- **kitty #8265** (open) discusses two alternatives: iTerm2's approach of
  declaring *which Unicode version's width rules* apply via an escape
  sequence, and VTM's
  [character_geometry.md](https://github.com/directvt/vtm/blob/master/doc/character_geometry.md)
  model, where the **application** explicitly declares on-screen cell
  geometry before printing, sidestepping terminal-side guessing entirely.
- kitty's shipped text-sizing protocol solves a related but different
  problem (multi-cell font *scaling*, not emoji width), but signals
  "declare it explicitly, don't guess" as an active design direction across
  the ecosystem.
- Links: [kitty #8265](https://github.com/kovidgoyal/kitty/issues/8265),
  [text-sizing-protocol docs](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/),
  [kitty #3998](https://github.com/kovidgoyal/kitty/issues/3998)

### Alacritty & WezTerm — ongoing, unsettled even in "careful" terminals

- **Alacritty**: ZWJ emoji get "stuck"/drawn over adjacent cells
  ([#8475](https://github.com/alacritty/alacritty/issues/8475)); double-width
  emoji sometimes treated as single-width
  ([#6144](https://github.com/alacritty/alacritty/issues/6144)); maintains
  its own [`unicode-width-16`](https://github.com/alacritty/unicode-width-16)
  crate and documents that computed width may not match rendered width for
  ZWJ composites.
- **WezTerm**: added VS15/VS16 support
  ([#997](https://github.com/wezterm/wezterm/issues/997)) but
  [#3923](https://github.com/wezterm/wezterm/issues/3923) (open) and
  [#7523](https://github.com/wezterm/wezterm/issues/7523) (2026-01) report
  ongoing presentation-flicker/width bugs — still unstable even in a
  terminal that's explicitly careful about Unicode.

### Width libraries in comparable TUI ecosystems

- **`go-runewidth`**: fixed ZWJ family-emoji miscount (👨‍👨‍👧 measured 6
  instead of 2) by switching to grapheme-cluster segmentation with
  "cluster width = first non-zero-width rune's width." Notably this is the
  *opposite* policy from what most real terminals (VTE, Alacritty, kitty,
  tmux, xterm) actually implement (per-codepoint sum) — a textbook
  library-vs-terminal mismatch.
  ([#28](https://github.com/mattn/go-runewidth/issues/28) /
  [PR #29](https://github.com/mattn/go-runewidth/pull/29))
- **`charmbracelet/lipgloss`** (Bubble Tea's own layout library — the
  closest direct domain analog to emojig's grid rendering): fixed
  box-overflow caused by emoji/ZWJ/CJK width miscalculation with a two-tier
  width calc — a fast ASCII path plus a `go-runewidth` fallback for complex
  Unicode.
  ([#562](https://github.com/charmbracelet/lipgloss/issues/562) /
  [PR #563](https://github.com/charmbracelet/lipgloss/pull/563))
- **`sindresorhus/string-width`**: unresolved ZWNJ
  ([#4](https://github.com/sindresorhus/string-width/issues/4)) and VS
  ([#42](https://github.com/sindresorhus/string-width/issues/42)) issues,
  which directly caused **`gajus/table` #67** — an emoji+VS16 string
  corrupting a rendered table's column width (measured 6 cells instead of
  the correct value). A real-world instance of the exact grid-misalignment
  failure mode emojig cares about, in a completely different ecosystem
  (Node.js table-rendering library).
- **`uwcwidth`** (Python/Cython, musl-derived): sums per-codepoint widths
  for skin-tone+ZWJ+gender combos (🏃🏾‍♂️ = 8 cells) — matches real
  terminal per-codepoint-summation behavior, the opposite of
  `go-runewidth`'s cluster-collapse. Direct illustration of the two
  competing models disagreeing on the same input.

### Emoji pickers checked, found not directly relevant

`emoji-fzf`, `rofimoji`, `rofi-emoji-picker`, `telescope-emoji.nvim`,
`emoji.nvim`, `emotive.nvim` are all single-column list UIs with no
per-cell grid-alignment problem to solve. `Termiji` (Rust, the closest
categorized-grid analog found) and `terminal-emoji-rs` had no accessible
width-handling documentation to extract anything from.

## Best practices / patterns that recur across every project surveyed

1. **No single "correct" width model exists.** Correctness is
   terminal-and-config dependent, not universal — plan for it, don't chase
   a unifying fix.
2. **Terminal-detection + a curated correction table** is the most mature
   general answer (`wcstwidth`'s per-`TERM`/`TERM_PROGRAM` tables, foot's
   config knob, kitty's discussed version-declaration escape). This is
   architecturally identical to emojig's `VTE_VERSION`/`TILIX_ID` gate in
   `src/root.zig` — just generalized to more terminals and more dimensions
   of behavior than we currently branch on.
3. **"Measure, don't compute"** (query real cursor position, e.g. `CSI 6n`,
   after printing) is the fallback everyone reaches for when no correction
   table can be trusted. We don't currently do this anywhere; it's a
   heavier-weight technique (needs a synchronous terminal round-trip) but
   is the only approach immune to *new* terminal-specific bugs we haven't
   cataloged yet.
4. **VS16/presentation-selector promotion tables are always curated and
   versioned, never a general rule.** This mirrors emojig's own curated
   approach elsewhere (e.g. `isBoxArt`'s explicit codepoint range in
   `SearchEngine.md`) — consistent with how this problem is solved
   everywhere, not a shortcut we're uniquely taking.
5. **ZWJ has no standardized terminal contract.** Multi-terminal support
   structurally *requires* per-terminal branching; there is no future
   Unicode spec update that would make this go away, short of every
   terminal adopting something like Mode 2027.
6. **Every mature width library has shipped a production emoji/ZWJ
   column-corruption bug** (`go-runewidth`, `string-width` → `gajus/table`,
   `lipgloss`). This is normal for the entire ecosystem, not a sign
   emojig's grid rendering is unusually fragile — worth remembering next
   time a width-alignment bug surfaces and it's tempting to assume our own
   code uniquely got something wrong.

## Specifically relevant to our `disable_zwj` VTE workaround

- **Confirmed, not contradicted**: every source that measured real terminal
  behavior agrees VTE-family (and Alacritty/kitty/tmux/xterm) do not
  cluster-collapse ZWJ sequences — they sum per-codepoint widths or render
  visibly "stuck"/overlapping glyphs. Our env-var-gated workaround
  (`VTE_VERSION`/`TILIX_ID` → `disable_zwj = true`) is in line with
  ecosystem norms.
- **New, actionable extension**: foot's own default `grapheme-width-method`
  (not `double-width` unless the user's `foot.ini` opts in) means emojig's
  VS16-width assumptions may currently depend on the *user's* config for
  the `--gui` foot window we spawn ourselves — filed as
  [issue 53](../issues/closed/53-foot-grapheme-width-tweak.md).
- **Longer-term idea, not urgent**: Mode 2027 (Ghostty/Contour/foot/WezTerm)
  and kitty/VTM's "declare geometry explicitly" family point toward
  terminal-queried or app-declared width instead of static heuristics —
  could reduce reliance on env-var sniffing for terminals we haven't
  special-cased yet, but a full grid-render probe would need scoping
  against the zero-allocation/performance constraints in `AGENTS.md §5`.
- No new VTE-specific bug beyond what's already suspected (flag-pair
  rendering, font/width mismatches) was found; no evidence our
  `VTE_VERSION`/`TILIX_ID` signal is stale or needs replacing.
