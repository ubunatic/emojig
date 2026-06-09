<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Archived: Inline TUI Loop V1

This document captures the design of the **first-generation** emojig inline TUI
control loop.  It is preserved here so the trade-offs are understood when reading
the replacement (`src/tui.zig`).

---

## How V1 worked

### Signal handlers doing terminal I/O

The V1 approach registered two POSIX signal handlers directly on `SIGINT`,
`SIGTERM`, and `SIGALRM`:

```zig
// sigHandler — fires on SIGINT, SIGTERM, SIGALRM
fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    // Restore cooked mode (tcsetattr from a signal handler — NOT async-signal-safe)
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(global_tty_fd, .NOW, &orig);
    }
    // Clear TUI rows and write RESTORE (terminal I/O from signal context)
    clearTuiRows(global_tty_fd, global_tui_height, global_row_off);
    _ = std.posix.system.write(global_tty_fd, RESTORE, RESTORE.len);
    logMemoryUsage();
    std.process.exit(1);
}

// sigWinchHandler — fires on SIGWINCH (terminal resize)
fn sigWinchHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    // Intentionally empty: resize is detected at the next render via ioctl.
    // EINTR from the blocked read() causes the loop to re-render.
}
```

### Blocking read + alarm for inactivity timeout

The event loop called `readStdin` (a blocking `read(2)`) with `VMIN=1`:

```zig
var n = readStdin(stdin_fd, &read_buf) catch |err| {
    if (err == error.SystemResources or err == error.Interrupted) continue;
    return err;
};
if (n == 0) break;
// Reset inactivity timer after each key event
if (active_timeout) |t| { _ = alarm(t); }
```

`SIGALRM` was used to implement the inactivity timeout
(`EMOJIG_PICKER_TIMEOUT` seconds of no input → process exits):

```zig
// At startup:
if (std.fmt.parseInt(c_uint, timeout_str, 10)) |t| {
    active_timeout = t;
    _ = alarm(t);   // fires SIGALRM after t seconds → sigHandler → exit(1)
}

// After each keypress:
_ = alarm(t);      // reset the countdown
```

---

## Problems with V1

| Problem | Effect |
|---|---|
| `tcsetattr` in signal handler | Not async-signal-safe; undefined behaviour if signal fires mid-malloc |
| Terminal I/O in signal handler | Race: signal can interrupt a frame draw halfway through |
| `clearTuiRows` in signal handler | Uses relative cursor moves; cursor position unknown at signal time |
| `alarm` + `SIGALRM` | Extra signal; resets are racy (signal delivered between `read` returning and `alarm` resetting) |
| `EINTR` loop for resize | Resize detection depends on `read` returning `EINTR`; fragile |

The root cause of **Bug 12 / Issue #5** (clearing too far up) was that
`clearTuiRows` used relative cursor moves (`\x1b[{n}A`) that assumed the cursor
was at the search bar — but in the copy-and-exit path the cursor was at the TUI
bottom, causing the up-move to overshoot above TUI row 0 and erase pre-existing
terminal content.

Even after switching to absolute cursor positioning via `global_tui_start_row`
(see commit history), the signal handler was still performing terminal I/O from
an async context, which violates POSIX.

---

## How V2 (src/tui.zig) fixes this

| V1 | V2 |
|---|---|
| Signal handler does terminal I/O | ISR writes 1 byte to pipe (only `write(2)` — async-signal-safe) |
| Signal handler calls `exit(1)` (no defer) | Signal → pipe → main loop `break` → full defer cleanup runs |
| `alarm(2)` for inactivity | `poll(timeout_ms)` — no extra signal needed |
| `EINTR` triggers resize re-render | `SIGWINCH` → pipe byte → loop `continue` → `ioctl` at next render |
| Cleanup relies on relative cursor moves | Cleanup uses `\x1b[{row};1H` absolute positioning |

See `src/tui.zig` and `docs/ZigTuiArchitecture.md` for the new design.
