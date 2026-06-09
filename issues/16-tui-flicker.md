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

To achieve flicker-free rendering:
1. **Remove redundant pre-clearing**: Remove `\x1b[2K\r` at the start of drawing each row.
2. **Rely on trailing clear**: Rely entirely on `\x1b[K` at the end of the row (`RowWriter.endRow()`) to erase any remaining columns. Because the new row text directly overwrites the old text character-by-character, there is no blank frame state, resulting in a perfectly smooth/flicker-free redraw.
3. **Carriage Return Guard**: Ensure carriage return `\r` is emitted at the beginning of the row if not already handled by cursor positioning or the previous row's end sequence.

## Affected Files
* [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig)
