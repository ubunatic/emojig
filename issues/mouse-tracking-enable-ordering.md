# Issue: Mouse tracking enabled before raw-mode setup is complete

## Problem

In `src/main.zig` around line 677, the TUI entry path sends the mouse-tracking
enable sequences to the terminal **before** `tcgetattr` / `tcsetattr` have run
and before the `defer` block that calls `RESTORE` is reachable:

```zig
// line 677 — sent unconditionally before any setup
try writeAll(stdout_fd, "\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l");

// line 679 — only after this does the defer/sighandler become active
const orig_termios = try std.posix.tcgetattr(stdin_fd);
global_orig_termios = orig_termios;
// ...
try std.posix.tcsetattr(stdin_fd, .NOW, raw);  // line 701
// defer { ... writeAll(stdout_fd, RESTORE) ... }  // line 712
```

`RESTORE` (defined at line 127) contains `\x1b[?1003l\x1b[?1006l` to disable
mouse tracking, plus cursor restore and OSC color reset. But if `tcgetattr`
(line 679) returns an error — or any `try` between 677 and 712 returns an
error — the `defer` block is never registered and `RESTORE` is never sent.
The terminal is left with `?1003h` (any-motion mouse tracking) enabled.

### Impact

- The parent shell receives a flood of mouse-movement escape sequences as
  raw input, breaking readline/zsh until the user manually runs `reset`.
- Any VTE-based terminal emulator (Tilix, GNOME Terminal, …) will buffer
  those events; combined with VT switching or rapid redraws this can expose
  latent VTE assertion failures.
- The window of failure is small (stdin is a tty, so `tcgetattr` rarely
  fails), but the consequence when it does fail is user-visible terminal
  corruption.

## Fix

Move the mouse-tracking enable to **after** `tcsetattr` and the `defer` block
are both in place, so the invariant "if tracking is on, RESTORE is guaranteed
to run" holds:

```zig
const orig_termios = try std.posix.tcgetattr(stdin_fd);
global_orig_termios = orig_termios;
// ... signal handler setup ...
try std.posix.tcsetattr(stdin_fd, .NOW, raw);

defer {
    std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
    // ... clear TUI lines ...
    writeAll(stdout_fd, RESTORE) catch {};
}

// Only enable mouse tracking now — RESTORE is guaranteed to run from here on.
try writeAll(stdout_fd, "\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l");
```

**Effort**: 2-line reorder, no logic change.
**Risk**: None — `tcgetattr` on an interactive tty is effectively infallible,
but correctness is better than relying on that assumption.
