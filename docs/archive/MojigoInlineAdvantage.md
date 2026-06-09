<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Mojigo Inline TUI Advantages & Zig TUI Fix Plan

This document details why the Go-based `mojigo` picker now offers a superior, more robust inline terminal UI experience compared to the Zig-based `emojig` app, and outlines a comprehensive plan to upgrade the Zig application to match.

---

## 1. Why the Go (`mojigo`) Inline TUI is Superior

The refactored Go TUI solves several classic terminal rendering issues with a simpler, more robust architecture:

```mermaid
graph TD
    A[Go Inline TUI Design] --> B(Dedicated /dev/tty IO)
    A --> C(Constant Viewport Footprint)
    A --> D(Carriage Return Guard \r\x1b[2K)
    A --> E(Zero Alt-Screen Overhead)

    B --> B1[STDOUT remains 100% clean for pipelining]
    C --> C1[Viewport never shrinks/grows; zero height jitter]
    D --> D1[Cursor column resets to 1; zero horizontal drift]
    E --> E1[No alt-screen switching glitches or context leaks]
```

### Key Advantages

1. **Dedicated `/dev/tty` I/O Separation**
   - **Problem in Zig**: The Zig app writes TUI sequences to stdout and attempts to auto-detect if stdout is redirected to fall back to stderr. This TTY hijacking is complex and prone to edge-case failures.
   - **Solution in Go**: `mojigo` opens `/dev/tty` for read/write. Keyboard input is read from and ANSI drawings are written directly to `/dev/tty`. Standard output (`os.Stdout`) remains completely untouched until the final selection is printed. This makes pipes like `emoji=$(mojigo)` work out of the box with zero detection code.

2. **Constant Viewport Footprint (Stability)**
   - **Problem in Zig**: The Zig app draws a dynamic number of lines depending on whether it is showing the emoji grid, rendering the help screen, or resizing. This height variance causes layout shifts and scrollback pollution on smaller viewports.
   - **Solution in Go**: `mojigo` computes the maximum TUI height at startup (the maximum of grid layout vs help page lines) and pads every frame to this height with blank lines. The viewport footprint is completely stable (always 9 rows), preventing any dynamic layout shifts.

3. **Zero Alternate-Screen Overhead**
   - **Problem in Zig**: Zig switches into the alternate screen (`\x1b[?1049h`) by default or handles inline rendering conditionally, leading to dual-mode branching.
   - **Solution in Go**: `mojigo` runs purely as an inline TUI, avoiding alternate-screen escapes completely.

4. **Horizontal Shift Prevention**
   - **Problem in Zig**: Moving the cursor to the search query position and clearing lines with `\x1b[2K` without first returning to column 1 causes the terminal to draw the search bar shifted to the right as the query grows.
   - **Solution in Go**: Prepends a carriage return `\r` to every line clearing operation (`\r\x1b[2K`). This guarantees the cursor column resets to 1 before any text is written.

---

## 2. Action Plan to Fix the Zig TUI App (`emojig`)

To port these rendering stability improvements to the core Zig application, follow this step-by-step implementation plan:

### Step 1: Enforce Carriage Return Prefix (`\r\x1b[2K`)
Modify the line-clearing operations in the Zig renderer and terminal state restoration code to include a carriage return:
- Update `src/main.zig` where lines are cleared (e.g., lines 995, 1003, 1216, 1221, 1244) to write `\r\x1b[2K` instead of `\x1b[2K`.
- Update `src/term.zig` panic/signal restoration helpers to prepend `\r` before writing the clear-line sequence.

### Step 2: Implement Constant Footprint Padding in Zig
Ensure the Zig app uses a stable vertical height:
- Compute the maximum TUI height during initialization:
  ```zig
  const tui_height = @max(grid_rows + layout_overhead, help_lines_count + layout_overhead - 2);
  ```
- Modify the rendering loop in `src/main.zig` to pad the drawn rows with blank lines (`" \x1b[2K\r"`) up to `tui_height` before returning the cursor to the top of the region.

### Step 3: Align I/O Separation on `/dev/tty`
Ensure stdout is kept clean:
- Validate that the Zig app always routes TUI control codes and query inputs to `/dev/tty` when running in interactive `--tui` mode, keeping standard output clear for the emoji payload.
- Simplify `force_stdout` / `can_use_tty` checks by relying on explicit `/dev/tty` handles for interactive frames.
