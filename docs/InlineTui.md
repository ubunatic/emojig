# Design Guide: Inline Terminal UIs (TUI) & Clean Viewport Management

> [!NOTE]
> **Currency Status:** Current as of June 1, 2026. Reflects the inline viewport management, non-scrolling overwrite mechanics, and query-based exit synchronization of **Emojig v0.1.x**.

How emojig renders an inline TUI that does not hijack the screen or alternate buffer,
preserves scrollback history, and cleans up after itself on exit.

---

## 1. Core Mechanics

An inline TUI occupies a fixed region of lines directly beneath the shell command
that invoked it. It lives in the normal screen buffer (no `\x1b[?1049h`).

### Key lifecycle phases

1. **First frame**: reserves vertical space by emitting newlines and moving back to TUI top.
2. **Redraw frames**: moves cursor back to TUI top, overwrites each line in place, and repositions the cursor.
3. **Teardown**: moves to top of TUI region, clears each line with `\x1b[2K` + `\x1b[B\r` (cursor-down without scroll), then moves back up.

### /dev/tty vs stdout

TUI output goes to a `/dev/tty` file descriptor opened with `O_RDWR`, not to
`STDOUT_FILENO`. This keeps stdout clean for shell capture:

```sh
emoji=$(emojig)   # TUI appears on terminal; emoji captured from stdout
```

The selected emoji is written to `STDOUT_FILENO` after the TUI teardown defer
completes. Signal handlers and the panic handler use the same `/dev/tty` fd
(stored in `global_tty_fd`) so the terminal is always restored correctly.

---

## 2. Terminal Session Lifecycle

### Before launch

```
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig█
```

### Active TUI (execution)

```
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig
 🔍 fir█              🔆

  🚒  🔥  🎆  🧨  🧯  🇮🇪
  ⚙️  ⛸️  😝  🎭  😚  😍
  😗  🏎️  😃  😀  😄  😁
  😆  😅  🤣  😂  🙂  🙃
 fire
```

### Clean exit — stdout capture

After teardown the TUI lines are cleared and the emoji appears on stdout.
When called as `$(emojig)`, the shell captures the emoji; when called directly,
it prints on the terminal where the prompt will appear:

```
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig
🔥
user@host:~$ █
```

---

## 3. ANSI Sequences

### Frame overwrite (each frame after the first)

The cursor is always left at the **search bar row** after rendering
(`cursor_up = current_total_rows - (2 + row_off)` rows up from the last printed row).
Each new frame begins by moving back to the TUI top:

```zig
// Normal redraw.
const move_seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{ 1 + row_off });

// Resize redraw (transitioning from visible to hidden or vice-versa).
const move_seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r\x1b[J", .{ 1 + row_off });
```

`row_off` is `1` when `EMOJIG_BORDER=1` is set (adds a coloured header/footer row), `0` otherwise.

### Erase-in-line and Cursor-Down on every output row

All vertical downward movement during rendering is performed without causing viewport scrolls:

```zig
try writeAll(stdout_fd, "\x1b[2K\r"); // clear line and return carriage
// [print line content here]
try writeAll(stdout_fd, "\x1b[0m\x1b[K"); // reset attributes and clear remaining ghost chars
try writeAll(stdout_fd, "\x1b[B\r"); // cursor down to next row, carriage return
```

`\x1b[B` moves the cursor down one row, clamping to the bottom edge of the viewport rather than scrolling when executed on the bottom line. This completely prevents vertical scrolling artifacts.

---

## 4. Terminal Resize Handling

Inline TUIs are fundamentally harder to resize than full-screen (alt-screen) TUIs
because the terminal can push TUI content into the scrollback buffer without warning.

### 4.1 SIGWINCH signal

Register a `SIGWINCH` handler. Keep it minimal — it simply lets the in-flight `read()` return `EINTR` (interrupted system call). The main loop re-polls `ioctl(TIOCGWINSZ)` at the top of every render iteration to detect actual dimension changes.

### 4.2 Horizontal resize — erase to end of line

Horizontal resize leaves **trailing ghost characters** on lines whose previous
render was wider than the current terminal width. Fix: always emit `\x1b[0m\x1b[K`
at the end of every printed line (see above). No cursor repositioning is needed.

### 4.3 Vertical resize — "Eat Lines Above" Strategy

Instead of complex CPR calculations and viewport state machines during manual resizing, Emojig implements the **"eat lines above"** strategy:

1. **Space Reservation at Startup:** The application emits `final_h - 1` newlines to reserve space in the terminal, then moves the cursor back up `final_h - 1` lines.
2. **Collapse Threshold:** The viewport rows (`rows`) are monitored on every render loop. If the terminal height falls below `final_h + 1`:
   - The TUI enters **hidden/collapsed mode**.
   - It only emits a single `clear_line` (`\x1b[2K\r`) at the TUI top and halts drawing body rows.
   - The TUI footprint collapses to exactly **1 blank line**, preventing the shell prompt above from entering scrollback.
3. **Restoration:** When the terminal grows above the threshold, the app automatically transitions out of hidden mode and redraws the full TUI.

---

## 5. SGR Mouse Coordinates & Viewport Warping

Terminal mouse tracking (SGR standard `\x1b[?1003h` + `\x1b[?1006h`) reports mouse coordinates
relative to the **absolute top row of the visible terminal viewport**, not relative
to the TUI's internal drawing region.

### Robust Viewport Shift Mapping

To keep mouse hover and click tracking perfectly aligned, the TUI dynamically
resolves its own viewport starting position and compensates for scrolling:

1. **Draining Input Stale Bytes:** Standard input can contain buffered stale bytes (such as mouse release or key presses sent before startup or resize). To prevent these from corrupting the ANSI response, `queryCursorRow` configures `VMIN=0 VTIME=0` non-blocking raw mode and completely drains `stdin` *before* issuing the cursor position report.
2. **Cursor Position Report (CPR):** Immediately after startup space reservation and on every height/width resize event, the TUI queries the absolute cursor row position by writing `\x1b[6n` and reading the response (`\x1b[r;cR`), yielding `tui_start_row`.
3. **Mouse Coordinate Calculation:** During SGR mouse events, the relative starting row is dynamically mapped:
   ```zig
   const scroll_amount = if (start_row + tui_h - 1 > actual_h)
       (start_row + tui_h - 1) - actual_h
   else
       0;
   const y_start = start_row - scroll_amount;
   const click_row = click_row_raw - y_start + 1;
   ```

---

## 6. Exit State Synchronization Handshake

To prevent in-flight mouse release or motion events from leaking onto the user's shell prompt as raw control characters (e.g. `^[[<35;7;7M` or `^[[<0;13;8m`), Emojig implements a deterministic exit handshake in its `defer` block:

1. **Disable Mouse Tracking:** App sends `MOUSE_OFF` (`\x1b[?1003l\x1b[?1006l`) immediately to stop the terminal emulator from generating new mouse events.
2. **Synchronous CPR Query:** App appends a Cursor Position Report query (`\x1b[6n`) to `stdout_fd` immediately after `MOUSE_OFF`.
3. **Timed Response Wait:** Stdin is configured in raw mode with a 100ms timeout (`VTIME=1`). The loop reads incoming bytes until it parses the terminating `'R'` character of the CPR response. Because the terminal state machine parses sequences sequentially in a FIFO queue, receiving the response to `\x1b[6n` guarantees that the terminal emulator has executed `MOUSE_OFF` and that all in-flight mouse events have arrived in `stdin`.
4. **Flush Queue:** App performs a final sweep of `stdin` in raw non-blocking mode (`VTIME=0`) to discard any trailing events.
5. **Restore Cooked Mode:** Standard terminal attributes (`orig_termios`) are restored, ensuring a completely clean shell prompt with zero control character leakage.

---

## 7. Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `EMOJIG_RESIZE_MODE` | `eat` | Resize strategy: `eat` (for TUI mode), `altscreen` (alternate screen buffer — used for GUI mode). Other modes have been removed. |
| `EMOJIG_ALT_SCREEN` | — | Legacy alias: `EMOJIG_ALT_SCREEN=1` is equivalent to `EMOJIG_RESIZE_MODE=altscreen`. |
| `EMOJIG_BORDER` | `0` | Draw a coloured background row above and below the TUI. Adds 2 rows to window height and shifts row offsets by 1. |
| `EMOJIG_DEBUG` | `0` | Add 2 debug rows showing live terminal dimensions. |
| `EMOJIG_THEME` | `dark` | `dark`, `light`, or `system` (auto-detect via OSC 11). |

---

## 8. Pitfalls & Solutions

### Save/restore cursor (`\x1b7` / `\x1b8`)

Do not use for inline TUIs. If the terminal scrolls during the first frame render
(cursor at bottom of window), saved absolute coordinates do not adjust — subsequent
restores land at the wrong position. Use only relative movements (`\x1b[A`, `\x1b[B`,
`\x1b[G`).

### Natural scrolling on line print

Do not use `\n` for vertical movement during the render loop. `\n` at the bottom
of the terminal window causes the viewport to scroll, invalidating all relative
cursor math. Use `\x1b[B\r` (cursor down + carriage return) instead.  
Exception: the **startup space reservation** intentionally emits `N` bare `\n`
characters to scroll the viewport before the first draw (then moves the cursor
back up), ensuring there is enough room below the current cursor for the full TUI.

### Line wrap

Disable line wrap with `\x1b[?7l` on entry; re-enable with `\x1b[?7h` on exit.
Overflow causes the terminal to wrap onto a new line, creating an implicit scroll
and corrupting the layout.

### Cursor Line Flicker on Fade-Out

**Problem:** In terminal emulators with "Highlight active line" or "Highlight cursor line" features (such as Tilix/VTE), the terminal draws a background highlight on the line where the cursor is currently located. Even if the cursor is hidden via `\x1b[?25l`, the terminal emulator still tracks the cursor's logical position. During a multi-frame fade-out animation or a rapid teardown clear, moving the cursor to park it or draw rows results in wild screen flickering as the line highlight flashes across the entire TUI viewport. Additionally, clipboard copy utilities (such as `wl-copy`/`xclip`) run as external processes, introducing a blocking delay of 50-100ms. If the cursor is not hidden before this delay, it remains visible in the search bar, creating a jarring transition.

**Solution:** 
1. **Hide Immediately on Decision:** The cursor must be hidden (`\x1b[?25l`) and parked at column 1 immediately when the exit decision is registered (`should_copy_and_exit`), *before* executing the blocking clipboard copy or starting the fade-out animation loop.
2. **Deactivate Highlight via Visibility:** Since modern terminals disable the active line highlight entirely when the cursor is hidden, hiding the cursor at the start of the exit sequence ensures the line highlight remains turned off throughout all frames of the fade animation and `defer` cleanup, completely eliminating flicker.

---

## 9. Current Knowns & Verification

### 9.1 Verified Baselines
1. **Query-Based Exit Synchronization**: Disables mouse tracking and performs a CPR handshake to completely drain in-flight mouse releases and drag motion bytes, preventing any leaked characters under high load or parallel execution loops.
2. **Stale Input Draining**: Non-blocking draining of `stdin` before issuing startup/resize CPR queries prevents stale buffered inputs from corrupting the cursor report response, keeping the mouse hover and click tracking perfectly aligned.
3. **Non-Scrolling Drawing Loop**: Drawing via `\x1b[2K\r` and `\x1b[B\r` avoids all natural scrolling actions during rendering.
4. **PTY Testing Baseline**: The test harness at [test_tui.go](file:///home/uwe/projects/emojig/scripts/test_tui.go) reliably spawns the application inside a programmatic PTY, sends simulated user keystrokes, and captures raw ANSI frame output for validation.
