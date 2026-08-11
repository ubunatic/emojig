<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "Zig TUI flickering during rapid redraws"
status: open
priority: p2
---

# Issue 16 — Zig TUI flickering during rapid redraws

**Status:** Open

## Description

The Zig TUI occasionally flickers or flashes during rapid redraw events (e.g., fast typing, hover events, or window resizing). 

## Analysis

In [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig), each row's drawing routine starts by clearing the entire row:
```zig
try writeAll(stdout_fd, "\x1b[2K\r");
```
And then at the end of drawing the row, it clears any remaining characters to the end of the line:
```zig
fn endRow(self: @This()) !void {
    try term_lib.writeAll(self.fd, "\x1b[0m\x1b[K");
    ...
}
```

This dual-clearing pattern causes a visible flicker:
1. `\x1b[2K` clears the entire line, making it momentarily blank.
2. The new row content is written.
3. `\x1b[K` clears any remaining columns.

Between step 1 and step 2, the line is empty, resulting in a flash of background color.

## Proposed Solution

Two complementary approaches (both pending):

### A — Reduce redraw frequency (`skip_render`, implemented)

Before rendering, call `tui.poll(stdin_fd, pipe_rd, 0)` (non-blocking). If input
is already buffered — e.g., a burst of mouse-motion events or rapid keystrokes —
skip the render and drain the event first. Render only when the input queue is
momentarily empty. This collapses N queued events into 1 redraw per lull.

**Implemented** in `src/main.zig` (render guard at the top of the main loop):
```zig
const skip_render = !is_first_render and !exit_preview and
    (tui.poll(stdin_fd, pipe_rd, 0) == .tty);
if (!skip_render and (exit_preview or !should_copy_and_exit)) { ... }
```
First render and exit-preview animation are never skipped.

### B — Remove redundant pre-clearing (still pending)

**Reference refresh 2026-08-11** — the behavior is unchanged, but the code
moved twice since this was written, so the original pointers no longer
resolve:

- The raw `"\x1b[2K\r"` literal is gone from `src/main.zig`. It is now the
  named constant `term_lib.CLEAR_LINE_CR` (defined `src/term.zig:234`, as
  `CLEAR_LINE ++ "\r"`) — a rename from issue
  [45](closed/45-ansi-escape-consolidation.md)'s ANSI consolidation, not a
  fix. Grep for `CLEAR_LINE_CR`, not for the escape bytes.
- The cited lines `~1337, ~1342, ~1365, ~1373` are stale. The row-start
  pre-clear writes now sit at roughly `src/main.zig:1605, 1613, 1635, 1641,
  1648, 1677, 1684, 1787, 1807` (nine sites, not four), plus
  `src/tui_draw.zig:738` and `:791` after the pane extraction of issue
  [44](44-main-zig-decomposition.md).
- Two sites are **not** candidates for removal and must be excluded from any
  such change: `src/main.zig:1075` (the exit `defer`'s hidden-mode row
  clear) and `clearTuiRows`' `CR_CLEAR_LINE` loop (`src/main.zig:228`),
  which are exit-path *cleanup*, not redraw. Deleting those would regress
  issue [12](12-tui-line-cleanup-and-terminal-restoration.md), whose whole
  invariant is per-row `\x1b[2K` erasure on exit.
- Note also `src/tui_draw.zig:961`, which *counts* `CLEAR_LINE_CR`
  occurrences in rendered output (`std.mem.count`) to identify spacer rows —
  a test/assertion that would need updating alongside any removal.

Remove the redraw-path pre-clears only, and rely entirely on `\x1b[K` in
`RowWriter.endRow()` to erase trailing columns. Because the new row text
overwrites old text character-by-character, there is no blank-frame state
between clear and draw. Ensure `\r` is emitted at row start (already present
via `\x1b[B\r` from the previous `endRow`).

⚠️ Interacts with issue [45](closed/45-ansi-escape-consolidation.md)'s
`endRowFull` distinction: full-width rows deliberately skip `\x1b[K` (it
fires from the pending-wrap position and erases the last column in
exact-width GUI windows — see closed issue 32). Those rows therefore cannot
rely on a trailing clear at all, so dropping their leading clear as well
would leave them with no erasure path. Any fix must handle
`endRow`-vs-`endRowFull` rows differently rather than uniformly.

## Affected Files
* [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig)
