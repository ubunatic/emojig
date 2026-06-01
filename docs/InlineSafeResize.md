# Inline Terminal UIs: Scrollback Preservation & The "Eat Lines Above" Resize Strategy

> [!NOTE]
> **Currency Status:** Current as of June 1, 2026. Documents the scrollback preservation mechanics analyzed from [inline_tui.go](file:///home/uwe/projects/emojig/scripts/inline_tui.go) and [inline_tui.zig](file:///home/uwe/projects/emojig/scripts/inline_tui.zig).

This document analyzes how the minimal inline TUI implementation preserves the shell prompt/command line that initiated the application during vertical terminal shrinking. By employing a specific cursor placement invariant and a height-sensitive collapse threshold, this strategy prevents TUI lines from polluting the terminal's scrollback history.

---

## 1. The Core Problem: Resize-Induced Scrollback Pollution

When an inline TUI runs inside the normal screen buffer (without switching to the alternate screen buffer via `\x1b[?1049h`), it shares the viewport with the preceding shell history and the command line that launched it.

When the terminal window shrinks vertically:
1. The terminal emulator must reduce the visible viewport height.
2. To keep the active cursor row visible on screen, the emulator scrolls the terminal contents upward.
3. This upward scroll pushes the topmost visible lines into the scrollback buffer.
4. If a TUI continues to draw its full height when the viewport is smaller than the TUI height plus the preceding command line, the initiating shell command is pushed into scrollback.
5. If the TUI continues to update, the terminal scrolls further, causing TUI frames to enter the scrollback buffer. When the application exits, the user's scrollback history is polluted with transient TUI states.

---

## 2. The "Eat Lines Above" Solution

The reference implementation at [inline_tui.go](file:///home/uwe/projects/emojig/scripts/inline_tui.go) (and its Zig port [inline_tui.zig](file:///home/uwe/projects/emojig/scripts/inline_tui.zig)) solves this issue using three key design invariants:

### A. The Top-Resting Cursor Invariant
Between frame renders, the cursor does not sit at the bottom or middle of the TUI. Instead, it is always returned to the **very top row** of the TUI region (TUI Row 0).
* The TUI defines a blank, empty string `""` as its first line (TUI Row 0).
* At the end of every frame render, the cursor moves up to this top row.
* Consequently, from the terminal emulator's perspective, the "active line" of the application is the topmost line of the TUI.

### B. Vertical Movement Without Scroll
All downward vertical movements during the drawing loop are performed using `\x1b[B\r` (Cursor Down + Carriage Return).
* Unlike `\n` (newline), which triggers a viewport scroll when executed on the bottom line of the terminal, `\x1b[B` simply clamps the cursor to the bottom edge of the viewport.
* This ensures that drawing the TUI never generates new scroll events, even if the terminal window is smaller than the TUI height.

### C. The Collapse Threshold (`rows < tuiHeight + 1`)
The application queries the viewport height (`rows`) on every redraw or `SIGWINCH` event. If the viewport height shrinks below the threshold of `tuiHeight + 1` (where `tuiHeight` is the total height occupied by the TUI):
* The TUI enters **hidden/collapsed mode**.
* In hidden mode, the application halts drawing all content rows (Rows 1 to `N`).
* It only emits a single `clear_line` (`\x1b[2K\r`) at the cursor's current position (TUI Row 0) and returns immediately.
* This collapses the active TUI footprint from `tuiHeight` rows to exactly **1 row**.

---

## 3. Step-by-Step Viewport Lifecycle during Shrink

Below is an ASCII walkthrough showing how a 6-row TUI (with `tuiHeight = 6`) behaves inside a terminal window shrinking from 10 rows down to 6 rows.

### Step 1: Normal Viewport (10 Rows)
The terminal has plenty of space. The shell prompt and command line are fully visible at the top, and the TUI sits comfortably below it. The cursor (`█`) rests on the empty TUI Row 0.

```
Row 1:  user@host:~$ ls -la
Row 2:  total 16
Row 3:  drwxr-xr-x  3 user user 4096 May 30 18:00 src
Row 4:  user@host:~$ emojig --tui
Row 5:  █                                           <-- TUI Row 0 (empty, cursor rests here)
Row 6:   inline TUI  [ ]
Row 7:   ─────────────────
Row 8:   row 1: hello
Row 9:   row 2: world
Row 10:  q to quit                                  <-- TUI Row 5
```

### Step 2: Shrunk Viewport (8 Rows)
The terminal shrinks to 8 rows. To keep the cursor on Row 5 (now Row 3) visible, the terminal emulator scrolls the viewport up by 2 lines. `ls -la` and `total 16` enter the scrollback buffer. The initiating command line is still visible.

```
[Scrollback Buffer]
  user@host:~$ ls -la
  total 16
─────────────────────────────────────────────────
[Active Viewport]
Row 1:  drwxr-xr-x  3 user user 4096 May 30 18:00 src
Row 2:  user@host:~$ emojig --tui
Row 3:  █                                           <-- TUI Row 0 (cursor rests here)
Row 4:   inline TUI  [ ]
Row 5:   ─────────────────
Row 6:   row 1: hello
Row 7:   row 2: world
Row 8:   q to quit                                  <-- TUI Row 5
```

### Step 3: Minimal Viewport (7 Rows / `rows == tuiHeight + 1`)
The terminal shrinks to 7 rows. The viewport scrolls up by 1 more line. The line immediately above the cursor is Row 1, which holds the initiating command line. The TUI occupies Rows 2 to 7.

```
[Scrollback Buffer]
  drwxr-xr-x  3 user user 4096 May 30 18:00 src
─────────────────────────────────────────────────
[Active Viewport]
Row 1:  user@host:~$ emojig --tui                   <-- Initiating command line (PRESERVED)
Row 2:  █                                           <-- TUI Row 0 (cursor rests here)
Row 3:   inline TUI  [ ]
Row 4:   ─────────────────
Row 5:   row 1: hello
Row 6:   row 2: world
Row 7:   q to quit                                  <-- TUI Row 5
```

### Step 4: Collapsed Viewport (6 Rows / `rows < tuiHeight + 1`)
The terminal shrinks to 6 rows. The threshold condition `rows < tuiHeight + 1` (6 < 7) is met, triggering the **collapse**. 
* The TUI stops drawing Rows 1 to 5.
* It only clears and updates Row 2 (TUI Row 0).
* The TUI's vertical height is now 1 row instead of 6.
* Because the drawn height collapsed, the terminal emulator does not need to scroll the initiating command line (Row 1) off the screen.
* The initiating command line remains visible on Row 1, safe from entering scrollback.

```
[Scrollback Buffer]
  (Unchanged - no new lines pushed)
─────────────────────────────────────────────────
[Active Viewport]
Row 1:  user@host:~$ emojig --tui                   <-- Initiating command line (PRESERVED)
Row 2:  █                                           <-- TUI Row 0 (collapsed to 1 row)
Row 3:  (Stale TUI Row 1 - not updated)
Row 4:  (Stale TUI Row 2 - not updated)
Row 5:  (Stale TUI Row 3 - not updated)
Row 6:  (Stale TUI Row 4 - not updated)
```

When the terminal window is resized back to 7 or more rows, the threshold check evaluates to `false`. The application resumes full rendering, overwriting the stale rows below the cursor.

---

## 4. Reference Code Implementation Details

The implementation of this strategy requires careful control of startup allocation, rendering movement, and signal handling.

### A. Startup Space Reservation
Before drawing the first frame, the TUI must reserve vertical space by emitting newlines and then returning the cursor to the top of that reserved space. This is the **only** time a scroll operation is permitted.

```zig
// Startup reservation in scripts/inline_tui.zig
{
    var up_buf: [16]u8 = undefined;
    // Emit tui_height-1 newlines to scroll the window if necessary
    for (0..tui_height - 1) |_| write("\n");
    // Move the cursor back up to the top of the reserved area (Row 0)
    write(cursorUp(&up_buf, tui_height - 1));
}
```

### B. The Render Loop
The frame drawing function loops through the lines, clearing each line and descending using `cursor_down` (`\x1b[B\r`). It then moves the cursor back to the top of the TUI.

```zig
fn drawFrame(tick: usize, hidden: bool) void {
    var up_buf: [16]u8 = undefined;

    if (hidden) {
        // Collapsed state: clear the current line and do not advance
        write(clear_line);
        return;
    }

    const lines = [tui_height][]const u8{
        "", // TUI Row 0
        " inline TUI  [...]",
        " ─────────────────",
        " row 1: hello",
        " row 2: world",
        " q to quit",
    };

    for (lines, 0..) |l, i| {
        write(clear_line);
        write(l);
        // Move down without causing viewport scrolling
        if (i < lines.len - 1) write(cursor_down);
    }
    // Return cursor to TUI Row 0
    write(cursorUp(&up_buf, tui_height - 1));
}
```

### C. Non-Repositioning SIGWINCH Handler & Loop Synchronization
The `SIGWINCH` handler only updates the `g_winch` atomic flag based on the new dimensions. It does **not** attempt to clear the screen or reposition the cursor. 

#### Synchronous Control Loop Race Condition (And Solution)
In a single-threaded synchronous TUI control loop (like Zig's `std.posix.read`), when `SIGWINCH` fires:
1. The blocking `read` system call is interrupted and returns `EINTR` (caught as `0`).
2. The loop enters the error/timeout branch and immediately triggers `drawFrame(tick, hidden)`.
3. If the loop does **not** check the atomic flag before drawing, it will execute `drawFrame` using the **stale** `hidden = false` state in the newly shrunk terminal.
4. Drawing a 6-row frame in a 2-row terminal causes `cursorUp(5)` to clamp the cursor to **Row 1** (the prompt).
5. On the next tick, `hidden` becomes `true` and clears the line at the cursor, erasing the prompt.

**Fix:** Swapping and checking `g_winch` must occur **both** at the top of the loop and immediately inside the interrupted read/timeout block:

```zig
    outer: while (true) {
        if (g_winch.swap(false, .acq_rel)) {
            hidden = termRows() < tui_height + 1;
        }

        const n = std.posix.read(g_fd, &buf) catch 0;
        if (n > 0) {
            if (buf[0] == 'q' or buf[0] == 3) break :outer;
        } else {
            // CRITICAL: Interrupted read due to SIGWINCH must update hidden flag
            // BEFORE drawing the frame, preventing stale-state rendering.
            if (g_winch.swap(false, .acq_rel)) {
                hidden = termRows() < tui_height + 1;
            }
            tick += 1;
            drawFrame(tick, hidden);
        }
    }
```

---

## 5. Adoption Strategy for Emojig

The main `emojig` Zig application can adopt this strategy to replace or augment its existing Cursor Position Report (CPR) based `hide/freeze` state machine.

### Comparison of Approaches

| Metric | CPR-Based Hide/Freeze (Existing) | "Eat Lines Above" (Go/Zig Reference) |
|---|---|---|
| **Scrollback Preservation** | Preserves all scrollback above the TUI. | Sacrifices scrollback above the TUI up to the initiating command line. |
| **Command Line Protection** | Protects the initiating command line. | Protects the initiating command line. |
| **Complexity** | **High**. Requires reading `\x1b[6n` from stdin, parsing ANSI responses, and maintaining viewport offset state. | **Low**. Requires only standard `TIOCGWINSZ` queries and a height comparison. |
| **Latency / Overhead** | Requires kernel round-trip for CPR (~1-2ms delay on resize). | Zero round-trip overhead. Instantaneous redrawing. |
| **Reliability** | Susceptible to terminal multiplexer (e.g. `tmux`) reflow timing differences. | Uniformly supported across all standard terminal emulators. |

### Integration Steps for `emojig`

1. **Add `EMOJIG_RESIZE_MODE=eat` Option**:
   Extend `src/resize.zig` to fully implement the "eat lines above" strategy when configured via the `EMOJIG_RESIZE_MODE` environment variable.
2. **Re-arrange Render Layout**:
   Ensure the top row of the Emojig layout is a blank line that serves as the cursor resting position between frame renders.
3. **Use Non-Scrolling Down Sequence**:
   Standardize on `\x1b[B\r` for vertical downward travel during rendering.
4. **Implement the `tui_height + 1` Threshold**:
   Configure the render loop to monitor `winsize.row` and transition to the single-line collapsed state whenever the terminal height falls below the threshold.
