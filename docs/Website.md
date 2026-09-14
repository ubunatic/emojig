---
title: Website Building Rules
weight: 25
---

# Website Building Rules

Rules for any agent asked to build or update a project website (`website/` dir,
published via `uman website sync <project>` into `~/projects/ubunatic.com`).
Read this doc **before** writing any website content — it is not optional
background, it is the spec for the task.

---

## Hosting & branding

- **Do not assume GitHub.** The default host is Codeberg. Never add GitHub
  badges, "View on GitHub" links, or GitHub icons/octocats unless the project
  is explicitly hosted there and the user asked for it.
- **No octocats or GitHub-brand assets** unless explicitly requested — even
  as a generic "source code" icon.

---

## Match sibling projects, don't invent a style

- Before designing, look at sibling projects under `~/projects/*/website/`
  (see `.uman.toml` for the managed list). Some are fancy, some are plain —
  there is no single house style to assume.
- If it isn't clear which style fits (fancy vs. simple), **ask the user**
  which sibling project should act as the inspiration. Don't guess.

---

## Content honesty

- **Do not promise what cannot be delivered.** Only describe features that
  are implemented and proven — well-tested, not aspirational or planned.
- **Always include a "Why" section**: the problem being solved, and why this
  tool/approach was chosen to solve it. This is the anchor for the rest of
  the page — write it first, or at least before publishing.

---

## Subpage awareness — relative links only

- Assume this page may be mounted as a subpage of another site
  (`ubunatic.com` provides shared navigation and a top bar via
  `uman website sync` / `make inject-nav`).
- **Use relative links**, not absolute paths, so the page still works when
  hosted under a subdirectory (e.g. `ubunatic.com/<project>/`).
- Don't build your own top nav/header that would conflict with or duplicate
  the hosting site's navigation.

---

## Static only, no CDN pulls

- Websites are **static** — no server-side rendering, no build-time
  dependency on a running backend.
- **Do not pull JavaScript from a CDN.** If a library is genuinely needed
  (e.g. Mermaid for diagrams, a Markdown renderer), vendor a pinned, stable
  version as a local static asset instead of a `<script src="https://...">`
  reference.

---

## JS demos / TUI simulations — opt-in only

- Local JavaScript demos/simulations (e.g. a simplified in-browser replica
  of a terminal UI) are **optional** for most websites — don't add one
  unless asked.
- If asked, base the simulation on the real app's actual TUI/behavior —
  **do not invent features that don't exist** in the real app. Look at the
  actual terminal UI/app first, then build a smaller, faithful simulation.

---

## Anti-patterns

**Assuming GitHub hosting by default.** Check the project or ask — Codeberg
is the default in this workspace.

**Designing from a blank slate.** Sibling `website/` dirs already encode
working decisions (nav injection, subdir hosting, static asset patterns) —
reuse them instead of reinventing.

**Marketing copy for unproven features.** If it isn't tested, it doesn't go
on the website yet.

**Absolute-path navigation.** Breaks the moment the page is mounted as a
subpage under `ubunatic.com/<project>/`.

**A CDN `<script>` tag "just for now".** Vendor the asset instead — it's the
same effort and doesn't create an untracked external dependency.

**An unrequested TUI simulation with imagined features.** Demos are opt-in
and must reflect the real app, not an idealized version of it.

<!-- harnez:stop -->

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
| `website/jsdemo.js` | **Generated** from `spec/web/jsdemo.yaml` via `make jsdemo` — do not edit by hand. |
| `website/webspec.js` | **Generated** from `spec/layout.yaml`, `spec/strings/en.yaml`, `spec/categories.yaml`, `spec/boxart.yaml`, and `spec/braille.yaml` via `make jsdemo` — do not edit by hand. |
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
`spec/strings/en.yaml`). Spec-owned web data comes from `website/webspec.js`;
regenerate it with `make jsdemo` instead of hand-editing simulator constants.

Box-art classification mirrors the two Unicode bands in `src/search.zig`:
U+2500–U+259F and U+1FB00–U+1FB3B. The generator exports these explicitly;
membership in `spec/boxart.yaml` does not imply box-art classification, because
that file also contains keyboard symbols and superscripts.

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

Search regressions: `node --test scripts/gen_web_spec/simulator_test.js`.
These also run through `go test ./...` and `make preflight` (Node is required),
checking box-art boundaries, `b:` filtering, and unpenalized superscript scores.

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
