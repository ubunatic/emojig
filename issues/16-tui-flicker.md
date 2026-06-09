<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

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

### B — Remove redundant pre-clearing (pending)

Remove `\x1b[2K\r` at the start of drawing each row (lines ~1337, ~1342, ~1365,
~1373 in `src/main.zig`). Rely entirely on `\x1b[K` in `RowWriter.endRow()` to
erase trailing columns. Because the new row text overwrites old text
character-by-character, there is no blank-frame state between clear and draw.
Ensure `\r` is emitted at row start (already present via `\x1b[B\r` from the
previous `endRow`).

## Affected Files
* [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig)
