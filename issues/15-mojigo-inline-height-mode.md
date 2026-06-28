<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "mojigo inline --height mode (skim-style) + /dev/tty I/O"
status: open
priority: p2
---

# Issue 15 — mojigo inline `--height` mode (skim-style) + `/dev/tty` I/O

**Status:** Implemented.

Ports the four inline-TUI techniques proven in the Rust demo (`src/main.rs`,
documented in [`docs/SkimInlineTui.md`](../docs/SkimInlineTui.md)) into the Go
`mojigo` picker, as an **additive** opt-in. No flag → unchanged alt-screen mode.

## Motivation

mojigo rendered on the **alt-screen** (`AltScreenOn`, full repaint each frame)
and wrote its UI to **`os.Stdout`**. Two problems:

1. It could not render inline below the prompt the way skim does.
2. **Real bug:** because the UI went to stdout, `e=$(mojigo)` captured ANSI
   escapes, not just the chosen emoji — mojigo was *not* pipe-composable.

The archived `docs/archive/MojigoInlineAdvantage.md` *described* mojigo as
already inline with `/dev/tty` I/O; that was aspirational — the code never
matched it. This change makes the code match.

## What landed

- **`mojigo --height N` / `--height N%`** renders the existing grid picker as a
  fixed inline region below the prompt. The grid/help renderers are unchanged;
  only the region *mechanics* are new.
- **`/dev/tty` I/O (both modes):** raw-mode, key input, and all control codes
  go through `/dev/tty`; `os.Stdout` carries only the selection. `e=$(mojigo)`
  is now clean.

## The four mechanics (mapped from skim / the Rust demo)

1. **Query the cursor first** — `term.QueryCursor` (DSR `\x1b[6n`, parsed by
   `parseCursorReport`) before reserving space; safe fallback (bottom row) on
   timeout.
2. **Scroll up only by the deficit** — `reserveRegion(cy, rows, want)` returns
   `to_scroll = want - (rows-cy) - 1` (the skim formula), pure and unit-tested.
3. **Fixed region, absolute coordinates** — every frame is `term.MoveTo(row,1)`
   + `term.ClearLine` (`\r\x1b[2K`, carriage-return-guarded) per row, blank-
   padded to a constant `regH`; never a trailing newline (which would scroll).
4. **Clean teardown** — `Terminal.SetInline` records the region so `Restore`
   clears it and parks the cursor at its top-left, on the signal path too.

**Horizontal-resize safety:** the region is clamped to `cols-1` and each row is
truncated by `clampANSI` (ANSI-aware, emoji counted as width 2), so an h-shrink
trims cells instead of soft-wrapping. mojigo's width is spec-driven, so unlike
the Rust demo there is no widest-item measurement — just the clamp.

## Files

- `internal/term/term.go` — `/dev/tty` handle, `QueryCursor`/`parseCursorReport`,
  `ScrollUp`/`MoveTo`/`ClearLine`, inline teardown in `Restore`.
- `internal/tui/tui.go` — `Height`/`ParseHeight`, `enterInline`/`reserveRegion`/
  `footprint`, `frame()` (rows as `[]string`) + dual emit, `clampANSI`.
- `internal/tui/input.go` — `readKey` reads the tty handle, not `os.Stdin`.
- `cmd/mojigo/main.go` — `--height` parsing.
- Tests: `internal/term/term_test.go`, `internal/tui/inline_test.go`.

## Verification

`make test` (zig + `go vet` + `go test ./...`) is green. Unit tests cover the
DSR parser, height parsing, the scroll-deficit table, `clampANSI`, footprint,
and the inline frame shape (exactly `regH` positioned+cleared rows, no
alt-screen/clear-screen leak — the stdout-clean guarantee). Interactive smoke
(resize, Ctrl-C teardown, `e=$(mojigo --height 8)`) is left to the user per the
no-manual-app-runs rule.
