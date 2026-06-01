# Design Guide: Inline Terminal UIs (TUI) & Clean Viewport Management

> [!NOTE]
> **Currency Status:** Current as of June 1, 2026. Reflects the inline viewport management, resize hardening, and scrollback-overflow hiding of **Emojig v0.1.x**.

How emojig renders an inline TUI that does not hijack the screen or alternate buffer,
preserves scrollback history, and cleans up after itself on exit.

---

## 1. Core Mechanics

An inline TUI occupies a fixed region of lines directly beneath the shell command
that invoked it. It lives in the normal screen buffer (no `\x1b[?1049h`).

### Key lifecycle phases

1. **First frame**: draw lines downward from the current cursor position.
2. **Subsequent frames**: move cursor back to the top of the TUI region with
   `\x1b[{N}A\r`, then overwrite each line in place.
3. **Teardown**: move to top of TUI region, clear each line with `\x1b[2K` +
   `\x1b[B\r` (cursor-down without scroll), then move back up.

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
user@host:~$ emojig --tui█
```

### Active TUI (execution)

```
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig --tui
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
user@host:~$ emojig --tui
🔥
user@host:~$ █
```

---

## 3. ANSI Sequences

### Frame relocation (each frame after the first)

The cursor is always left at the **search bar row** after rendering
(`cursor_up = frame_h - (2 + row_off)` rows up from the last printed row).
Each new frame begins by moving back to the TUI top:

```zig
// Normal redraw — no size change.
const move_seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{ 1 + row_off });

// Resize redraw — erase to end of screen after repositioning.
const move_seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r\x1b[J", .{ 1 + row_off });
```

`row_off` is `1` when `EMOJIG_BORDER=1` is set (adds a coloured header/footer row), `0` otherwise.

### Erase to end of line on every output row

```zig
try writeAll(stdout_fd, "\x1b[0m\x1b[K\r\n");  // clear trailing chars after content
```

`\x1b[K` prevents ghost characters from previous (wider) renders persisting
when the terminal is resized narrower then wider again.

### Teardown — line-by-line clear without scrolling

```zig
var k: usize = 0;
while (k < final_h) : (k += 1) {
    _ = std.posix.system.write(stdout_fd, "\x1b[2K", 4);
    if (k < final_h - 1) {
        _ = std.posix.system.write(stdout_fd, "\x1b[B\r", 4);
    }
}
const move_up = std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{ final_h - 1 }) catch "";
_ = std.posix.system.write(stdout_fd, move_up.ptr, move_up.len);
```

---

## 4. Terminal Resize Handling

Inline TUIs are fundamentally harder to resize than full-screen (alt-screen) TUIs
because the terminal can push TUI content into the scrollback buffer without warning.

### 4.1 SIGWINCH signal

Register a `SIGWINCH` handler. Keep it minimal — set an atomic flag or simply
let the in-flight `read()` return `EINTR`. The main loop re-polls `ioctl(TIOCGWINSZ)`
at the top of every render iteration to detect actual dimension changes.

```zig
// Detect size change at top of render loop:
var ws_size = std.mem.zeroes(std.posix.winsize);
_ = std.posix.system.ioctl(stdout_fd, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws_size));
const current_w = ws_size.col;
const current_h = ws_size.row;
const height_changed = (current_h != last_h);
const resized = (current_w != last_w or height_changed);
```

### 4.2 Horizontal resize — erase to end of line

Horizontal resize leaves **trailing ghost characters** on lines whose previous
render was wider than the current terminal width. Fix: always emit `\x1b[K`
at the end of every printed line (see above). No cursor repositioning is needed.

### 4.3 Vertical resize — the hard problem

When the terminal **shrinks vertically**, the terminal emulator scrolls the viewport
upward, pushing the topmost rows into the scrollback buffer. If the TUI top row
enters scrollback, subsequent renders that naively move up `1 + row_off` rows from
the cursor land at the wrong position, producing stacked ghost search-bar rows.

**Solution used in emojig:**

1. **Query actual cursor row** with `\x1b[6n` (CPR) immediately before the resize
   redraw. This gives the ground truth of where the cursor actually is after the
   terminal reflow.

2. **Clamp the upward move** to the number of rows that actually exist above the
   cursor on the current screen (`min(1 + row_off, cursor_row - 1)`). This prevents
   attempting to erase rows that are already in scrollback.

3. **Update `global_tui_start_row`** immediately (before the redraw) from the queried
   position so mouse coordinate mapping stays correct for the new frame.

```zig
const actual_cursor = queryCursorRow(stdin_fd, stdout_fd, raw) orelse fallback;
const tui_top = actual_cursor - @as(i32, @intCast(1 + row_off));
const rows_above = actual_cursor - 1;
const ideal_up = @as(i32, @intCast(1 + row_off));
const clamped_up = @min(ideal_up, rows_above);
if (clamped_up > 0) {
    const seq = try std.fmt.bufPrint(&buf, "\x1b[{d}A\r\x1b[J", .{clamped_up});
    try writeAll(stdout_fd, seq);
} else {
    try writeAll(stdout_fd, "\r\x1b[J");
}
global_tui_start_row = tui_top;
```

### 4.4 Scrollback overflow — hide mode

Even with clamped erasing, content that has already entered the scrollback buffer
will reappear when the user scrolls back or the terminal grows again, producing
ghost frames. The only way to prevent this completely is to **collapse the TUI**
before it enters scrollback.

**Strategy (`EMOJIG_HIDE_OVERFLOW=1`, the default):**

When `tui_top <= 0` (the TUI header row has been pushed to or above screen row 0):

- **Enter hidden mode**: erase the full visible TUI from screen, switch to a
  1-row search-bar-only frame (`is_tui_hidden = true`, `current_frame_h = 1`).
  No trailing `\r\n` is emitted — the cursor stays on the single search bar line.
- **Stay hidden**: subsequent SIGWINCH events while still too small redraw the
  single search bar in place with `\r\x1b[J`.
- **Exit hidden mode**: when the terminal grows so that `tui_top > 0` again,
  erase the stub with `\r\x1b[J` and redraw the full 8-row TUI.

The user can still type and interact with the search bar in hidden mode; results
are waiting when the TUI is restored.

```zig
const should_hide = final_hide_overflow and (tui_top <= 0);

if (should_hide and !is_tui_hidden) {
    // Erase visible TUI content and collapse.
    is_tui_hidden = true;
} else if (!should_hide and is_tui_hidden) {
    // Restore full TUI.
    is_tui_hidden = false;
}

// In render: guard all rows except the search bar:
if (!is_tui_hidden) { /* draw border, padding, grid, description */ }
// Search bar always drawn; trailing newline suppressed when hidden:
try writeAll(stdout_fd, if (is_tui_hidden) "\x1b[0m\x1b[K" else "\x1b[0m\x1b[K\r\n");
```

### 4.5 Alternative strategy — "eat lines above" (scrollback sacrifice)

A simpler approach that entirely avoids the hide/CPR complexity: instead of
collapsing the TUI when the terminal shrinks, **let the terminal eat whatever
scrollback lines sit above the TUI**.

When the terminal shrinks vertically, the emulator scrolls content upward. The
TUI stays on screen because it sits at the bottom of the viewport; the lines
that disappear are whatever was above it (shell history / prior output). The
TUI frame itself never enters scrollback. On the next `SIGWINCH` the app just
re-reads `TIOCGWINSZ` and redraws in place — no CPR query, no hide state machine.

**Tradeoff summary**

| | Hide/freeze (emojig default) | Eat-lines-above |
|---|---|---|
| TUI lines in scrollback | Never | Never |
| Scrollback consumed on shrink | None | Yes — rows above TUI lost |
| Implementation complexity | High (CPR, state machine) | Low (SIGWINCH + TIOCGWINSZ) |
| User experience | TUI disappears when too small | TUI always visible |

**When it is acceptable:** The user has explicitly invoked the TUI (it is not a
background widget). Losing a few lines of prior shell output when they drag the
window smaller is a reasonable tradeoff for keeping the TUI interactive.

**When to prefer hide/freeze:** The TUI is auto-launched (e.g. shell integration),
or preserving scrollback history is a hard requirement.

**Reference implementation:** `scripts/inline_tui.go` — a minimal Go testbed that
demonstrates this strategy. It draws a 5-row inline TUI with a blinking cursor,
listens for `SIGWINCH`, and redraws in place. No CPR, no hide mode. Run with:

```sh
go run scripts/inline_tui.go
```

---

## 5. SGR Mouse Coordinates & Viewport Warping

Terminal mouse tracking (SGR standard `\x1b[<...M`) reports mouse coordinates
relative to the **absolute top row of the visible terminal viewport**, not relative
to the TUI's internal drawing region.

* **The GUI / Full-screen Case:** If the TUI runs in a dedicated terminal window
  sized exactly to the TUI height (`ws.row == final_h`), the viewport and TUI
  align perfectly (`y_start = 1`).
* **The Inline TUI / Scrollback Case:** If the TUI runs inline inside a larger
  terminal (e.g. 50 rows high), it is rendered at the current cursor position.
  If drawing the TUI causes the terminal viewport to scroll, the relative start
  row of the TUI shifts upwards.

### Scroll-Compensated Cursor Query

To achieve pixel-perfect mouse hover and click tracking, the TUI dynamically
queries its own starting position and compensates for scrolling:

1. **Startup Position Query:** Immediately after entering raw mode, query the
   absolute cursor row position by writing `\x1b[6n` (Cursor Position Report) and
   reading the response (`\x1b[r;cR`), yielding `start_row`.
2. **Dynamic Scroll Calculation:** During mouse events, query the active viewport
   row height (`actual_h` via `ioctl(TIOCGWINSZ)`).
3. **Viewport Shift Mapping:** Compute the scrollback shift and the TUI-relative
   mouse row:
   ```zig
   const scroll_amount = if (start_row + tui_h - 1 > actual_h)
       (start_row + tui_h - 1) - actual_h
   else
       0;
   const y_start = start_row - scroll_amount;
   const click_row = click_row_raw - y_start + 1;
   ```
4. **After vertical resize:** Re-query `global_tui_start_row` from the cursor
   position immediately after the resize redraw (before the next mouse event),
   since the terminal reflow may have changed which screen row the search bar
   occupies.

---

## 6. Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `EMOJIG_RESIZE_MODE` | `freeze` | Resize strategy: `freeze` (collapse to blank, hide cursor), `hide` (collapse to search-bar stub), `eat` (sacrifice scrollback above, always visible), `altscreen` (alternate screen buffer — no scrollback interaction). See `src/resize.zig` for full descriptions. |
| `EMOJIG_ALT_SCREEN` | — | Legacy alias: `EMOJIG_ALT_SCREEN=1` is equivalent to `EMOJIG_RESIZE_MODE=altscreen`. Set automatically by foot GUI mode. |
| `EMOJIG_SCROLL_BIAS` | `0` | Signed integer added to the startup scroll reservation (`space_needed`). Positive = emit more newlines before first draw; negative = fewer. |
| `EMOJIG_BORDER` | `0` | Draw a coloured background row above and below the TUI. Adds 2 rows to window height and shifts row offsets by 1. |
| `EMOJIG_DEBUG` | `0` | Add 2 debug rows showing live terminal dimensions. |
| `EMOJIG_THEME` | `dark` | `dark`, `light`, or `system` (auto-detect via OSC 11). |

---

## 7. Pitfalls & Solutions

### Alternate screen buffer (`\x1b[?1049l`)

Never include `\x1b[?1049h`/`\x1b[?1049l` in an inline TUI unless you entered
the alt screen first. Sending `\x1b[?1049l` without having entered the alt screen
clears the screen and resets scrollback in VTE-based terminals (GNOME Terminal, Tilix).

### Erase-in-display (`\x1b[J`) — use with care

`\x1b[J` (erase from cursor to end of screen) is safe to use **after a verified
cursor move** during a resize redraw — it clears stale TUI rows below without
touching the scrollback. Do **not** use it during teardown (use `\x1b[2K` per
line instead to avoid over-erasing shell history).

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

### CPR round-trip cost

`\x1b[6n` (Cursor Position Report) requires a kernel round-trip and adds ~1 ms of
latency. Only query it:
- Once at startup (to record `global_tui_start_row`).
- On **height** resize events (to re-sync after terminal reflow).
- Never on every frame or width-only resize (use the fixed `1 + row_off` offset).

### Width-only resize vs height resize

Treat them separately:
- **Width-only**: no terminal scrolling occurs; the fixed `\x1b[{1+row_off}A\r\x1b[J`
  is safe and fast. No CPR needed.
- **Height change**: the terminal may have scrolled; CPR is required to determine
  the actual cursor row and whether the TUI top is still on-screen.

---

## 8. Current Knowns, Unknowns, and Baselines

As of June 1, 2026, here is the verified status of what works, what remains problematic or unknown, and how diagnostic scripts are used.

### 8.1 What is 100% Known & Working

1. **Width-Only Resizes**: Erasing with `\x1b[K` at the end of each line completely prevents horizontal ghosting without needing cursor repositioning or CPR queries.
2. **"Eat Lines Above" Strategy**: The minimal Go implementation at [inline_tui.go](file:///home/uwe/projects/emojig/scripts/inline_tui.go) confirms that sacrificing preceding terminal lines to scrollback is highly robust and avoids all CPR query complexity. It simply tracks `TIOCGWINSZ` and lets the terminal handle reflow naturally.
3. **Cursor Drift Prevention**: Using `\x1b[0A` to move the cursor up by 0 lines causes a drift upwards in many ANSI-compliant terminals (since they treat `0` as `1`). In 1-row stub/hidden mode, cursor repositioning must bypass `\x1b[0A` completely and position with absolute columns or direct `\r` carriage returns.
4. **PTY Testing Baseline**: The test harness at [test_tui.go](file:///home/uwe/projects/emojig/scripts/test_tui.go) reliably spawns the application inside a programmatic PTY, sends simulated user keystrokes, and captures raw ANSI frame output for validation, proving that the basic input/output loop operates correctly in standard terminal environments.

### 8.2 What is Unknown / Under Investigation

1. **Scrollback Restoration Ghosting**: When recovering the TUI from a collapsed/hidden state after a vertical window resize, terminal emulators pull in varying amounts of old TUI lines from the scrollback buffer. Attempts to programmatically compute and erase this history (via calculated line offsets and CPR queries) are inconsistent across different shell environments and multiplexers (e.g., `tmux` vs raw terminal emulator).
2. **Terminal Reflow Timing**: During interactive manual resizing, terminal reflow events trigger rapid, successive height changes. The timing of `ioctl` updates, `SIGWINCH` signal delivery, and standard input reads sometimes mismatch, leading to race conditions where the drawing math uses outdated viewport dimensions.
3. **Alternate Mode Transition in GUIs**: Under certain Wayland/X11 foot configurations, the automatic switch between inline `--tui` and floating `--gui` mode leaves terminal handles in a raw state if terminated abruptly.

