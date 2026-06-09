// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Microcontroller-style TUI event loop infrastructure for emojig.
//!
//! Implements the architecture described in docs/ZigTuiArchitecture.md §1-4.
//!
//! ## Design
//!
//! Signals are converted into synchronous file-descriptor events via a
//! POSIX self-pipe:
//!
//!   1. A pipe is created at startup; both ends are set O_NONBLOCK.
//!   2. All POSIX signal handlers are replaced by the single minimal ISR
//!      `sigIsr`, which writes one byte (the raw signal number) to the
//!      write-end of the pipe.  This is the only operation the ISR performs
//!      and is listed in POSIX.1-2017 Table 2-1 of async-signal-safe functions.
//!   3. The main event loop calls `poll()` which blocks on two fds:
//!        • /dev/tty   — keyboard and mouse input
//!        • pipe read-end — signal notifications
//!   4. When the pipe wakes up, the signal bytes are drained and dispatched
//!      synchronously in the main thread, giving full access to local state and
//!      stack buffers without any async-signal-safety constraints.
//!
//! ## Benefits over the old approach (see docs/InlineTuiLoopV1.md)
//!
//!  * Terminal cleanup on Ctrl-C is done through the normal defer block, so
//!    it benefits from absolute cursor positioning and the full handshake.
//!  * SIGWINCH triggers a re-render on the next loop tick without a separate
//!    volatile flag or a EINTR-based continue.
//!  * The inactivity timeout (EMOJIG_PICKER_TIMEOUT) is driven by the poll
//!    timeout_ms parameter — no alarm(2) / SIGALRM needed.

const std = @import("std");

// ---------------------------------------------------------------------------
// Self-pipe globals
// ---------------------------------------------------------------------------

/// Write-end of the self-pipe.  Assigned once in setupSelfPipe(); only ever
/// written by sigIsr().  Must be file-scope so the ISR can reach it without
/// a pointer argument (signal handlers receive no user data).
pub var g_sig_pipe_wr: std.posix.fd_t = -1;

// ---------------------------------------------------------------------------
// Signal ISR
// ---------------------------------------------------------------------------

/// Minimal async-signal-safe Interrupt Service Routine.
///
/// Encodes the signal as a single byte and writes it into the self-pipe.
/// The main event loop drains the pipe synchronously and dispatches the event.
///
/// Only write(2) is called here — it is listed in POSIX.1-2017 Table 2-1 of
/// async-signal-safe functions, so this handler is safe to call from any
/// signal context regardless of what the main thread is doing at the time.
pub fn sigIsr(sig: std.posix.SIG) callconv(.c) void {
    var buf = [1]u8{@intCast(@intFromEnum(sig))};
    _ = std.posix.system.write(g_sig_pipe_wr, &buf, 1);
}

// ---------------------------------------------------------------------------
// Self-pipe lifecycle
// ---------------------------------------------------------------------------

/// Create the non-blocking self-pipe pair.
///
/// Returns [read_fd, write_fd]. Sets g_sig_pipe_wr = write_fd.
/// The caller must close both descriptors when done.
pub fn setupSelfPipe() ![2]std.posix.fd_t {
    // pipe2(2) with O_NONBLOCK creates both ends non-blocking in one syscall.
    // Non-blocking write-end: ISR never blocks if the pipe buffer is full.
    // Non-blocking read-end:  drainPipe() never blocks after poll() reports ready.
    var fds: [2]std.posix.fd_t = undefined;
    const flags = std.os.linux.O{ .NONBLOCK = true, .CLOEXEC = true };
    const rc = std.os.linux.pipe2(&fds, flags);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
    g_sig_pipe_wr = fds[1];
    return fds;
}

// ---------------------------------------------------------------------------
// Signal registration
// ---------------------------------------------------------------------------

/// Register sigIsr as the handler for every signal in `sigs`.
///
/// Any signal not listed here keeps its existing disposition (usually the
/// kernel default).  Errors are silently ignored — worst case the signal
/// is unhandled, which is still safe for the process.
pub fn registerSignals(sigs: []const std.posix.SIG) void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigIsr },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    for (sigs) |sig| {
        std.posix.sigaction(sig, &act, null);
    }
}

// ---------------------------------------------------------------------------
// Poll-based event dispatcher
// ---------------------------------------------------------------------------

/// Result returned by poll().
pub const Wake = enum {
    /// /dev/tty has keyboard or mouse bytes ready to read.
    tty,
    /// The self-pipe has one or more signal bytes ready to drain.
    pipe,
    /// The poll timeout elapsed (inactivity timeout fired).
    timeout,
};

/// Block until tty_fd or pipe_rd has data, or until timeout_ms elapses.
///
/// Pass timeout_ms = -1 for indefinite blocking (no inactivity timeout).
/// The pipe is checked before tty so that a signal is never starved by
/// a rapid burst of keyboard/mouse input.
pub fn poll(tty_fd: std.posix.fd_t, pipe_rd: std.posix.fd_t, timeout_ms: i32) Wake {
    var fds = [2]std.posix.pollfd{
        .{ .fd = tty_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = pipe_rd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const n = std.posix.poll(&fds, timeout_ms) catch return .timeout;
    if (n == 0) return .timeout;
    // Pipe takes priority so signals are never starved by fast keyboard input.
    if (fds[1].revents & std.posix.POLL.IN != 0) return .pipe;
    if (fds[0].revents & std.posix.POLL.IN != 0) return .tty;
    return .timeout;
}

/// Drain all pending bytes from the self-pipe into buf.
/// Returns the number of bytes actually read (each byte is one signal number).
pub fn drainPipe(pipe_rd: std.posix.fd_t, buf: []u8) usize {
    const rc = std.posix.system.read(pipe_rd, buf.ptr, buf.len);
    const n: isize = @bitCast(rc);
    if (n <= 0) return 0;
    return @intCast(n);
}
