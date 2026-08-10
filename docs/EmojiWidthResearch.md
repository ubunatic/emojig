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

## `scripts/canary_font.zig` / `scripts/canary_font/` — isolating font *alignment* from everything else

Issue 57's investigation (see the "Retracted" section in
[`../issues/57-tilix-monochrome-mixed-row-length.md`](../issues/57-tilix-monochrome-mixed-row-length.md))
found a VS16 row-length defect that reproduced reliably in wayreel's headless
nested-sway/Xvfb capture harness but did **not** reproduce on the real
desktop, once the user checked directly. `scripts/canary_font.zig` isolates
the variable that actually matters for that class of question — font
*alignment*: glyph shape, metrics, subsequence positioning — from
everything else:

- Renders `-text` with `-font` via Cairo+Pango (dlopen'd
  `libcairo`/`libpango-1.0`/`libpangocairo-1.0`), which resolves the
  `-font` flag through real fontconfig+FreeType — so pointing it at a
  CBDT bitmap family (`Twemoji`) vs. a COLR vector family (`Noto Color
  Emoji`, confirmed to be the `Noto-COLRv1.ttf` variant on this host) is a
  genuine vector-vs-bitmap glyph-technology switch, not a simulation of
  one — **but only since fallback was explicitly disabled (below); this
  was false for the first several days this canary existed.** Pango's
  *default* per-run font fallback silently substitutes a different family
  for any codepoint tagged `Emoji_Presentation` (e.g. 🚀), regardless of
  `-font`, and regardless of whether the requested font covers the glyph:
  verified directly with `hb-shape` that Twemoji.ttf has a real,
  non-`.notdef` glyph for U+1F680, yet unmodified Pango silently rendered
  it with Noto Color Emoji anyway. Every `-font=Twemoji`-vs-`-font="Noto
  Color Emoji"` comparison made with this canary before the fix was
  comparing *the exact same rendering* regardless of the flag — a
  vacuous negative result, not a real one. Fixed by disabling fallback
  (`pango_attr_fallback_new(FALSE)`, applied to the layout's attribute
  list) by default in both implementations; `-allow-fallback` restores
  the old permissive behavior for comparison. With fallback off, a font
  that genuinely lacks a glyph now renders it as a tofu/notdef box
  instead of silently substituting — see `issues/59-canary-font-research-gaps.md`.
- **Scope limitation, stated explicitly because it wasn't before**: this
  only covers the Pango/Cairo/FreeType/fontconfig stack (GTK apps,
  VTE-based terminals like gnome-terminal/tilix). `foot` links no Pango
  at all — it uses `libfcft`+FreeType+HarfBuzz directly (`ldd
  $(command -v foot)` shows no libpango) — and no terminal lays out its
  grid via `pango_layout` in the first place (that's exactly what issue
  57's row-length question was about). This canary cannot speak to
  foot's behavior or to terminal grid alignment specifically; it only
  answers "how does the Pango/Cairo stack itself handle this font/text."
- Renders straight into an **offscreen** Cairo image surface and saves it
  as a PNG — no Wayland window, no compositor, no screenshot tool. An
  earlier version of this canary opened a real on-screen window and shot
  it via `swaymsg`+`grim` (sway) or GNOME Shell's D-Bus `ScreenshotWindow`
  (Mutter), specifically to compare against a compositor round trip. That
  was dropped: alignment is decided entirely by Pango/Cairo/FreeType
  *before* anything is ever presented, so a compositor round trip only
  adds presentation effects (fractional-scale upscaling, colour
  management) that don't bear on alignment and would need controlling for
  rather than helping — and, as a side effect, this version runs
  identically anywhere (this harness's sandboxed shell included — no
  desktop session, no D-Bus permission, no `SWAYSOCK` needed).
- Bakes a small metadata label into every rendered image itself (detected
  terminal emulator, `$TERM`, session type/desktop — e.g. `term=tilix
  TERM=xterm-256color session=wayland/GNOME`), and writes a companion
  `<out>.env.txt` with a fuller env-var dump — so a PNG saved or shared
  elsewhere still carries which host and terminal it came from, which
  matters once you're comparing renders across machines.
- `-unset=A,B,C` unsets specific env vars (via libc `unsetenv`) *before*
  rendering, so a run can isolate whether one specific font-stack var is
  actually responsible for a difference, rather than just noting its
  presence in the dump. Both canaries share the same env-var list, chosen
  by websearching fontconfig/FreeType/Pango's own docs for vars that can
  change glyph metrics or font selection (not just debug/logging vars like
  `FC_DEBUG`, which don't affect rendering and were left out):
  `FREETYPE_PROPERTIES` (hinting/interpreter-version/warping — directly
  changes advance widths, see the FreeType properties reference),
  `FONTCONFIG_PATH`/`FONTCONFIG_FILE`/`FONTCONFIG_SYSROOT` (override which
  config/fonts are matched at all), `FC_LANG` (overrides the language used
  for font matching, can pick a different fallback font), and
  `PANGOCAIRO_BACKEND` (`fc`/`win32`/`coretext` — switches Pango's font
  backend entirely). `LC_ALL`/`LANG` were already tracked.

There are **two independent implementations**, deliberately built with
different tech stacks so a rendering discrepancy can be attributed to one
implementation's binding code rather than to the font stack itself:

- `scripts/canary_font.zig` — Zig, dlopens `libcairo`/`libpango-1.0`/
  `libpangocairo-1.0` directly via hand-written `extern fn` pointers (the
  same low-level approach `scripts/canary_gui.zig` uses for Wayland). No
  `-dev` packages needed — this is Zig's normal way of talking to a C
  library in this codebase.
- `scripts/canary_font/main.go` — Go, a normal `#cgo pkg-config: cairo
  pango pangocairo` link against the real headers (`go run
  ./scripts/canary_font`). This needs the `-dev` packages (headers +
  `.pc` files + unversioned `.so` symlinks) installed — `make
  canary-font-go-deps` (→ `scripts/install_cairo_pango_dev.sh`,
  dnf/apt/zypper/apk/pacman branches) installs them, and `canary-font-go`
  depends on it so it's ensured automatically. An earlier version
  dlopened the runtime `.so.N` libraries directly (like the Zig canary)
  specifically to avoid needing `-dev` packages, but a plain
  pkg-config/header link is simpler and more idiomatic Go/cgo — worth the
  one-time `-dev` install for a manual research tool.

Both produced visually identical output for the same `-font`/`-text`
**after the fallback fix above** (verified again post-fix: `-font=Twemoji`
now measures a genuinely different width from `-font="Noto Color Emoji"`
in both implementations, and produces the font's own distinct rocket
artwork). Before the fix, "identical output" was a vacuous result — any
two `-font` values would have produced identical output regardless of
whether the implementations agreed on anything, since neither was
actually switching the emoji font. Re-verified with fallback correctly
disabled, this cross-implementation agreement is a real result: it means
Zig's manual dlopen binding isn't introducing its own alignment artifacts
relative to Go's cgo-mediated calls.

Building `-unset` surfaced a real tech-stack difference, though — not in
rendering, but in each runtime's own env-var handling:

- **Zig 0.16**: calling libc's `unsetenv()` directly desyncs Zig's own
  cached `environ` view (`std.Io.Threaded.environ`) from libc's. The
  *next* `std.process.spawn` (this canary's `mkdir -p`) then segfaults
  building the child's env block from dangling pointers into memory glibc
  already freed when it reallocated `environ`. Separately, `std.debug.print`
  lazily scans `environ` on its first call to locate self debug-info
  search paths, and panics if a var like `LANG` is missing — which then
  *deadlocks* trying to print that very panic (the handler recurses into
  the same lazy-init path and re-locks its own mutex). Both are worked
  around by doing the one `std.process.spawn` and one warm-up
  `std.debug.print` *before* any `-unset` unsetenv call, while `environ`
  is still what Zig's runtime expects it to be.
- **Go**: `os.Unsetenv` had no such issue — Go tracks its own environment
  copy consistently and never hands a raw pointer into it to child
  processes the way the segfault above required.

This isn't a font-rendering finding, but it's exactly the kind of
tech-stack-specific fragility this comparison was meant to surface, and
it's a real correctness gotcha for any Zig 0.16 program that both spawns
children and mutates its own environment at runtime — worth remembering
independent of this canary.

Usage: `make canary-font FONT="Twemoji" TEXT="☺️ ☺︎" UNSET=FREETYPE_PROPERTIES`
(Zig) or `make canary-font-go FONT=... TEXT=... UNSET=...` (Go) — or run
either `-help` flag for the full list. Manual/on-demand only — not part of
`make canary`.

Sources for the env-var research above:
- [FreeType driver properties reference](http://freetype.org/freetype2/docs/reference/ft2-properties.html)
- [fontconfig-user.txt (servo/libfontconfig mirror)](https://github.com/servo/libfontconfig/blob/master/doc/fontconfig-user.txt)
- [fonts.conf(5) manpage](https://manpages.debian.org/unstable/fontconfig-config/fonts-conf.5.en.html)
- [PangoCairo.FontMap docs (PANGOCAIRO_BACKEND)](https://lazka.github.io/pgi-docs/PangoCairo-1.0/classes/FontMap.html)

## `scripts/canary_width_compare.zig` — the actual issue-57 question: does a *mixed* run add up right

`canary_font` (above) answers "does this one font render this glyph
correctly" — necessary, but not what issue 57 actually asked. That
question was about **placing emoji next to plain text**: does the
*combined* width of a run like `abc☺️ ☺︎🚀def` come out the same across
different ways of computing it, or does a VS16/VS15/ZWJ/keycap sequence
throw off the sum. `canary_width_compare.zig` feeds one `-text` string to
four independent width models and prints each one's total plus a
per-cluster/per-codepoint breakdown side by side:

1. **Pango/HarfBuzz shaping** (same dlopen'd libcairo/libpango as
   `canary_font.zig`) — cluster-aware, uses fontconfig's full *fallback
   chain* so a glyph missing from `-font` is silently substituted from a
   whole font set, same as a real GTK app.
2. **Naive per-codepoint summation** — a deliberately dumb `wcwidth()`-
   style model: every codepoint gets an independent width (0/1/2) with
   *no* clustering, approximating the "per-codepoint width" camp of
   terminals (VTE, Alacritty, kitty, tmux, xterm — see above) that don't
   collapse a VS16/ZWJ sequence into one cell. This is explicitly a
   simplified stand-in for Unicode's East Asian Width data, not an
   authoritative implementation.
3. **Raw HarfBuzz only**, via the `hb-shape` CLI against the *one*
   resolved font file (no Pango layout, no fallback chain — that concept
   doesn't exist below Pango). Needed `--utf8-clusters`: `hb-shape`'s `cl`
   field defaults to a *codepoint index*, not a byte offset — without the
   flag, cluster text-slices silently misalign on any multi-byte
   character, discovered the hard way while building this.
4. **`libfcft` — foot's own library**, dlopen'd directly and called with
   `fcft_rasterize_text_run_utf32`. No terminal, no compositor, no
   wayreel: same offscreen-pixbuffer approach as the other three columns,
   just calling foot's own library instead of Pango — chosen specifically
   to avoid wayreel's moving parts (nested sway, screenshot capture) for
   this measurement. `fcft`'s structs expose public fields (unlike
   Cairo/Pango's opaque pointers), so the layouts were transcribed
   directly from `fcft.h` (`fcft-devel`, installed via
   `scripts/install_fcft_dev.sh` purely as a one-time reference for
   maintainers — the tool itself only dlopens the runtime `.so.4`, already
   present as foot's own dependency, and needs no header at build or run
   time). Each returned glyph carries both `.cols` (fcft's own
   `wcwidth()`-equivalent decision) and `.advance.x` (pixel advance).

   **Two real findings surfaced immediately just building this column**:
   - `fcft_from_name`'s `name`/`attributes` parameters are *separate*
     fontconfig strings — concatenating `"FAMILY:size=N"` into one name
     entry (the natural first attempt) fails outright for any family
     containing a space.
   - `libfcft` cannot load COLRv1 vector color fonts at all
     (`"COLRv1 not supported"`, confirmed directly) — this is *exactly*
     why the project's own `scripts/install_fonts.sh` had to install
     Twemoji (CBDT) specifically for foot; this column now confirms that
     fact from the library level rather than by inference. Because of
     this, the tool's default `-font` is `Twemoji`, not a COLRv1 font.
   - **Important caveat, not a bug**: column 4 measures `fcft`'s own
     *default* `.cols` decision, which is **not** the same as foot's full
     width behavior. foot's `[tweak] grapheme-width-method=double-width`
     (issue 53) is applied by **foot's own source**, on top of fcft's raw
     per-grapheme result — that tweak does not exist anywhere in fcft.h's
     public API. Observed directly: fcft alone reports `cols=1` for `☺️`
     (VS16) with Twemoji — the *opposite* of what issue 53's fix assumes
     foot ends up doing end-to-end. Treat this column as a real
     measurement of one real layer foot depends on, not a full stand-in
     for foot itself.

The naive column-count is converted to a comparable pixel figure using the
advance of a plain `"M"` in the same font as one reference "cell" (not
`"0"` — Twemoji's bare digit glyphs are intentionally zero-width, see
issue 59, which silently zeroed this estimate for the tool's own default
font until caught here), so columns 1/3/4 end up in the same pixel units
alongside column 4's own `.cols` figure.

Sample run (`-text="abc☺️ ☺︎🚀def" -font=Twemoji`): Pango totals 395px
(real Latin fallback font used for `abc`/`def`); raw `hb-shape` against
Twemoji alone totals 597px (no fallback, every glyph advances ~59-60px
flat); `fcft` totals 12 cols / 392px; naive summation estimates 484px (11
columns × 44px reference cell). The four disagreeing is not itself a bug —
it reflects a genuine difference in what each layer is capable of
(fallback chain or not, clustering or not, terminal-specific override
logic or not), which is exactly the kind of tech-stack difference this
tool exists to surface.

Usage: `make canary-width WIDTH_TEXT="abc☺️ ☺︎🚀def" FONT="Twemoji"` or
`zig run scripts/canary_width_compare.zig -lc -- -help` for the full flag
list. Manual/on-demand only — not part of `make canary`.

**IDEA, not yet actioned**: wayreel's own pixel/row-color-detection logic
(used by `scripts/vte_canary` for headless proofs) could be extracted into
a reusable library, making a future real-terminal-pixel column cheaper to
add without wayreel's full nested-compositor machinery. Belongs in
`../wayreel`'s own issue tracker, not this project's, if pursued.
