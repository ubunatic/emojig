<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# Website: Structure, Simulator Contract & Verification

How the `website/` directory is organized, what the JS simulator needs from
the page, and how an agent verifies website changes headlessly. Companion
docs: [WebSandbox.md](WebSandbox.md) (WASM demo), [HeadlessRecording.md](HeadlessRecording.md)
(video recording).

---

## 1. Directory layout

| Path | Role |
|---|---|
| `website/index.html` | The live site. Hand-written single file (style + markup + tiny inline JS). |
| `website/simulator.js` / `simulator.css` | Interactive shell + picker simulator (see §3). |
| `website/emojis.js` | Generated emoji DB for the simulator (mirror of the packed binary DB). |
| `website/jsdemo.js` | **Generated** from `spec/jsdemo.json` via `make jsdemo` — do not edit by hand. |
| `website/webspec.js` | **Generated** from `spec/layout.json`, `spec/strings.json`, `spec/categories.json`, `spec/boxart.json`, and `spec/braille.json` via `make jsdemo` — do not edit by hand. |
| `website/*.webm`, `*.png` | Shared recordings/screenshots, written by the reel pipeline. |
| `website/reels/` | Output directory for the newer `.reel`-scripted recordings. |

The live site is always `website/index.html`. Superseded sites are not
kept in-tree (the previous `website/v0/` archive was removed because it
loaded Google Fonts, breaking the no-external-requests policy — git
history has it if ever needed).

`make browse` opens the live site (and regenerates `jsdemo.js` first).

## 2. Design principles (the "honest page" contract)

* **No external requests.** No font CDNs, no trackers, no frameworks — the
  footer says so, and that claim must stay true. Fonts come from a
  `ui-monospace`-first system stack; emoji render via locally installed
  fonts.
* **Honest numbers.** Performance claims on the page must be measurable
  (binary size budget, the self-reported RSS in `/tmp/emojig.log`,
  embedded-emoji count). Don't put a number on the page that a user cannot
  reproduce.
* **Reproducible demos.** Videos are recorded from scripts in `spec/reels/`
  (JSON for the recorded ones, `.reel` for the scripted backlog) — never
  hand-recorded. The reels section on the page maps 1:1 to those files.
* The roadmap section mirrors the maintainer's actual priorities; update it
  together with `issues/` when priorities change.

## 3. Simulator DOM contract

`simulator.js` boots on `DOMContentLoaded` and is a 1:1 JS port of the Zig
search engine (same scoring, stem/plural fallbacks, `e:`/`t:`/`b:`/`br:`/`c:`
filters, category auto-detect, paged `?` / `??` help mirroring
`spec/strings.json`). Spec-owned web data comes from `website/webspec.js`;
regenerate it with `make jsdemo` instead of hand-editing simulator constants.

Required element (boot throws without it):

* `#sim-screen` — the terminal render target.

Optional elements (feature-detected):

* `#sim-panel` — HUD container (clicks inside keep keyboard focus).
* `#sim-query-input` — text input mirrored with the picker query.
* `#sim-opt-theme` — `<select>` for dark/light/system.
* `#sim-focus-badge` — focus indicator; **clickable** (focuses the sim).
* `.sim-dpad-btn.up/.down/.left/.right/.ok` — mobile d-pad buttons.
  Inside the d-pad callbacks the simulator instance is `sim`, not `this`
  (a `this.cols` regression here once NaN'd the whole grid navigation).

## 4. Headless verification recipes

JS sanity: `node --check website/*.js`.

Render checks use headless chromium. Three gotchas cost real time once —
remember them:

1. **Write outputs inside the repo.** The Bash-tool sandbox gives chromium
   a private `/tmp` and blocks writes outside the project — screenshots to
   `/tmp/...` or `~/.cache/...` silently vanish or fail. Use the gitignored
   `.claude/worktrees/` and delete artifacts afterwards.
2. **Screenshots scroll away from the header.** The simulator autofocuses
   its input on load, which scrolls `--screenshot` captures down the page
   unpredictably. For an unscrolled, full-page render use
   `--print-to-pdf=...` instead and read the PDF (page 1 = header/hero).
3. **DOM assertion beats pixels** for "did the sim boot": 
   `--dump-dom ... | grep -o "sim-row" | wc -l` — a booted simulator
   renders ~14 rows; `0` means a JS error before first render.

```sh
cd website
node --check simulator.js
chromium --headless --disable-gpu --no-sandbox --virtual-time-budget=3000 \
  --dump-dom file://$PWD/index.html | grep -o "sim-row" | wc -l
chromium --headless --disable-gpu --no-sandbox --virtual-time-budget=3000 \
  --print-to-pdf=$PWD/../.claude/worktrees/page.pdf file://$PWD/index.html
```

For tall single screenshots: `--window-size=1100,8000 --screenshot=...`,
then `convert -crop` to inspect sections.

## 5. REUSE / licensing

* `REUSE.toml` globs do **not** recurse: `website/*.js` does not cover
  `website/reels/*.webm` — each subdirectory needs its
  own annotation entries. `make preflight` catches misses (generated files
  like `jsdemo.js` carry no header and rely on the annotations).
* **Codeberg branding:** the official logo artwork is CC0 and linking to
  your own Codeberg repo is an explicitly permitted use, but the mark is a
  trademark of Codeberg e.V. and their guidelines forbid recoloring/tinting
  (white version on dark backgrounds only). The site therefore uses a
  *generic* stroked mountain (lucide "mountain", as on the wayreel site) so
  it can follow the theme color freely.

## 6. Shared flourishes

* The logo float/glow animation (`@keyframes float` + `drop-shadow`) and the
  cursor-following background bloom (`.cursor-glow`, a fixed 600px radial
  gradient moved by a `mousemove` listener) are shared idioms with the
  wayreel site. The bloom must sit at `z-index: -1` (behind all content,
  above the body background) with `pointer-events: none`.
