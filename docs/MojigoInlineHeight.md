<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Inline `--height` in mojigo: porting skim's mechanics to Go

How the skim-style inline TUI from [`SkimInlineTui.md`](./SkimInlineTui.md) (the
Rust demo in [`src/main.rs`](../src/main.rs)) was ported into the Go `mojigo`
picker — as an **additive** mode. No flag → unchanged alt-screen; `--height N`
or `--height N%` → a fixed inline region below the prompt.

Implementation lives in `internal/term/term.go`, `internal/tui/{tui,input}.go`,
and `cmd/mojigo/main.go`; rationale and file map in
[`issues/15-mojigo-inline-height-mode.md`](../issues/15-mojigo-inline-height-mode.md).

---

## What we started from

mojigo rendered on the **alt-screen** (`AltScreenOn`, full repaint per frame) and
wrote its UI to **`os.Stdout`**. So it couldn't render inline, and — the real
bug — `e=$(mojigo)` captured ANSI escapes instead of just the emoji. The
mechanics below are the fix.

## The four mechanics (and their Go homes)

1. **Query the cursor first.** `term.QueryCursor` writes DSR (`\x1b[6n`) and
   parses the `\x1b[row;colR` reply (`parseCursorReport`). Reserving space before
   you know where the cursor is is the root of inline drift. On timeout it falls
   back to the bottom row (forces a full scroll — never overdraws upward).
2. **Scroll up only by the deficit.** `reserveRegion(cy, rows, want)` returns
   `to_scroll = want - (rows-cy) - 1` — skim's exact formula. It's a pure
   function, so the table of `(cy, rows, want) → (y, scroll)` cases is
   unit-tested without a terminal.
3. **Fixed region, absolute coordinates.** Each frame is `MoveTo(row,1)` +
   `ClearLine` per row, blank-padded to a constant `regH`. `ClearLine` is
   `\r\x1b[2K` — the leading `\r` resets the column so a growing query can't
   drift right. **Never** emit a trailing newline inside the region: at the
   bottom row it would scroll the screen.
4. **Clean teardown.** `Terminal.SetInline(y, h)` records the region so
   `Restore` clears it row-by-row and parks the cursor at its top-left — and
   crucially does this on the **signal path** too (`installSignalHandler` →
   `Restore`), or Ctrl-C orphans the region.

## Two Go-specific lessons

- **`/dev/tty` is the I/O fix, and it applies to *both* modes.** `MakeRaw` opens
  `/dev/tty` for raw-mode, key input (`readKey` reads it, not `os.Stdin`), and
  all control codes. `os.Stdout` now carries only the selection, so
  `e=$(mojigo)` is clean — and piped stdin is no longer mistaken for keystrokes.
  Unifying both modes on the tty (not just inline) is safe because any
  interactive launch has a controlling terminal; harnesses that use a PTY set
  `Setctty`, so `/dev/tty` resolves to the slave.

- **Don't port the list UI — only the region mechanics.** skim and the Rust demo
  are single-column lists that re-measure the widest item for an h-resize-safe
  box. mojigo is a spec-driven `cols×rows` grid with a constant footprint, so the
  width learning collapses to a single clamp: `box = cols-1`, and each row is
  truncated by `clampANSI` (ANSI-aware, emoji counted as width 2). An h-shrink
  then trims cells instead of soft-wrapping — no resize handling, no
  widest-item pass.

## Frame shape (one builder, two emitters)

`frame()` returns the picker's logical rows as a `[]string` (no positioning).
The alt-screen path joins them with `\r\n` after `CursorHome+ClearScreen`; the
inline path positions each row absolutely inside the region and clamps it. The
grid/help renderers (`gridRows`/`helpRows`) are otherwise unchanged.

`footprint()` reserves `max(grid, help)` rows so the region never overflows
either view; the requested `--height` is then capped to that and to `rows-1`
(keep the initiating line visible).

## Extending to `--simple` mode

`--simple` adds a fzf/sk-like flat list layout on top of the same inline
mechanics. See [`SimpleListMode.md`](./SimpleListMode.md) for implementation
details. Key deltas from the grid mode:

- `footprint()` returns 1000 so `--height` is never artificially capped.
- `listCap()` = `regH - 2` (inline) or `termRows - 2` (alt-screen), min 1.
  Search is capped at this count instead of `cols × rows`.
- `simpleFrame()` renders list rows + count row + prompt row.
- Navigation collapses to linear prev/next for all four directions.
