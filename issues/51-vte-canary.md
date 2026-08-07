<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 51 — VTE canary: headless color-grid screenshots per terminal

**Status:** Implemented (initial), open for extension

## What it is

`scripts/vte_canary/main.go` renders a 4×4 color-grid pattern (truecolor rows:
red, green, blue, yellow) in a terminal window and optionally captures a
screenshot. Its purpose: visually confirm that a given terminal renders 24-bit
color and emoji correctly — especially VTE-based terminals (tilix, ptyxis,
gnome-terminal) which have historically mishandled ambiguous-width emoji.

## Current state

Three wayreel reels capture headless screenshots via `I mode=app`:

| Reel | Terminal | Shot |
|---|---|---|
| `scripts/vte_canary/canary-foot.reel` | foot | `shots/canary-foot.png` |
| `scripts/vte_canary/canary-ptyxis.reel` | ptyxis | `shots/canary-ptyxis.png` |
| `scripts/vte_canary/canary-tilix.reel` | tilix | `shots/canary-tilix.png` |

Run with: `make canary-shots`

Each reel:
1. Builds the canary binary (`go build -o /tmp/vte_canary_bin`)
2. Launches the terminal in wayreel's headless sway (Xvfb)
3. Runs `vte_canary_bin -s` (silent mode — grid rows only, no stderr)
4. Takes an `I mode=app` screenshot
5. Exits

GTK/VTE isolation env is required (see `docs/HeadlessRecording.md §7`):
```reel
env = ["DBUS_SESSION_BUS_ADDRESS=", "DISPLAY=:99"]
```

foot uses the default terminal; ptyxis and tilix use `$ "tilix" focus=new`
(launched from within foot so they inherit wayreel's compositor environment).

## Automated pixel verification (implemented 2026-08-07)

Hardened via wayreel's `crop_colors` feature (wayreel commit `14c47f6`,
`I`/`IMG` screenshot steps): each `I mode=app` step in the `.reel` files now
crops the screenshot to the bounding box of pixels matching the canary's own
row colors (`crop_colors=["ff0000","00ff00","0000ff","ffff00"]`), instead of
capturing the full window. This replaced the old ~150-line
`verifyScreenshotNonBlank`/`captureRealScreenshot`/`findLatestGnomeScreenshot`/
`runTerminalTest` real-desktop-screenshot machinery (and the `-test-term`/
`-test-all` flags) entirely — that path was superseded by the wayreel-reel
flow and unreferenced by `Makefile`/docs.

`main.go` defines `canaryColors` (pure RGB red/green/blue/yellow — the
single source of truth for both the ANSI rendering and the check) and a
`-verify PATH` flag that decodes the now-tightly-cropped PNG and requires
each color cover ≥5% of pixels (`minColorCoverage`). `make canary-shots`
builds the binary once, records each reel, then runs `-verify` against each
shot — a real pass/fail gate, not just "did a file get written."

Notes from hardening:
- `crop_colors` combo tokens (`"rgb"`) resolve through `reelang.ResolveColor`,
  which maps `"g"` to dark green `008000`, not pure `00ff00` — there's no
  built-in "lime" entry. Explicit hex values (`crop_colors=["ff0000","00ff00","0000ff","ffff00"]`)
  are used instead so the crop targets match `canaryColors` exactly, rather
  than relying on red/yellow (rows 0 and 3) coincidentally anchoring the
  bounding box's top/bottom regardless of the green/blue mismatch.
- `crop_tolerance=0` (exact match) works for **foot** and **tilix** — both
  render solid ANSI truecolor backgrounds with no antialiasing bleed.
- **ptyxis is currently blank** in headless capture (see issue 52) — dropped
  from `canary-shots` for now; the `.reel` file and its `crop_colors` are
  kept for when that's fixed.

## Open

- [ ] `st` — skipped; `terminal = ["st"]` is broken in wayreel (upstream known issue)
- [ ] `gnome-terminal` — not yet added; same VTE isolation approach as tilix
- [ ] ptyxis re-enablement — blocked on issue 52
- [ ] `V ocr=` step — wayreel's verify instruction could assert color names
      appear in the grid description row once the canary prints them

## Related

- `docs/HeadlessRecording.md §7` — wayreel screenshot pattern + GTK isolation pitfall
- `../wayreel/issues/18` — wayreel should auto-inject `DISPLAY=:99` so projects
  don't need to spell it out in every reel
