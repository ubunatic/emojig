// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Minimal, standalone reproduction of a Zig 0.16 stdlib bug found while
//! building scripts/canary_font.zig's `-unset=` flag — see
//! issues/058-zig-unsetenv-environ-desync.md for the full writeup.
//! No application code, no C libraries: this is std.debug.print,
//! std.process.spawn, and libc's unsetenv() only.
//!
//! Four modes, selected by argv[1]:
//!
//!   panic-deadlock
//!     Unsets LANG, then calls std.debug.print for the first time in the
//!     process. Expected: prints something and returns. Actual: panics
//!     ("attempt to use null value") and then *hangs forever* (verified up
//!     to 20s) instead of exiting — the panic handler's own attempt to
//!     print the panic message recurses into the same lazy-init code path
//!     that just panicked and re-locks a mutex it's already holding.
//!
//!   spawn-segfault
//!     Spawns `true` (succeeds), unsets LANG, spawns `true` again.
//!     Expected: second spawn also succeeds. Actual: segfaults inside
//!     std.process.Environ.createPosixBlock reading a dangling pointer —
//!     std.Io.Threaded's cached view of environ was invalidated when
//!     libc's unsetenv() reallocated its own copy, and a prior successful
//!     spawn does *not* prevent this (rules out "spawn just needs a
//!     warm-up" as an explanation).
//!
//!   print-workaround
//!     Calls std.debug.print once (warm-up), unsets LANG, calls
//!     std.debug.print again. This one succeeds — proves the *first*
//!     debug.print call is what's lazily broken, and one warm-up call
//!     before unsetenv is a real, working fix for this specific symptom.
//!
//!   spawn-still-broken-after-print-warmup
//!     Same warm-up as print-workaround, then unsets LANG, then spawns
//!     `true`. Still segfaults identically to spawn-segfault — proves the
//!     debug.print warm-up does NOT also fix spawn; the two failure modes
//!     do not share whatever state the warm-up call primes, so there is
//!     no known workaround for the spawn case other than never spawning
//!     after unsetenv at all.
//!
//! All four only reproduce when the named var (LANG here) is actually
//! *present* beforehand — unsetting an already-absent var is a no-op for
//! libc and doesn't trigger any of this, which is itself part of the proof
//! this is a genuine environ-cache-invalidation issue, not a coincidence.

const std = @import("std");

extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Raw write to stderr, deliberately NOT std.debug.print — the first ever
// call to std.debug.print in the process is exactly what lazily triggers
// the bug below, so any diagnostic printed *before* the deliberate trigger
// point must avoid it, or it would pre-warm the lazy init and hide the bug
// (this is the same reason scripts/canary_font.zig's own workaround is a
// one-time debug.print call placed *before* any unsetenv).
fn rawPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.system.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    const mode = it.next() orelse {
        rawPrint("usage: zig_unsetenv_bug_repro (panic-deadlock|spawn-segfault)\n", .{});
        return;
    };

    if (getenv("LANG") == null) {
        rawPrint("LANG is already unset in this shell — this repro needs it set to demonstrate the bug (it's a no-op for libc otherwise, which is part of the proof). Run: LANG=en_US.UTF-8 zig run scripts/zig_unsetenv_bug_repro.zig -- {s}\n", .{mode});
        return;
    }

    if (std.mem.eql(u8, mode, "panic-deadlock")) {
        rawPrint("before unsetenv: LANG={s}\n", .{getenv("LANG").?});
        _ = unsetenv("LANG");
        rawPrint("after unsetenv: about to call std.debug.print for the FIRST time in this process...\n", .{});
        // This is the first std.debug.print call in the whole process,
        // with LANG already unset — this is where it panics, then hangs
        // trying to print the panic message.
        std.debug.print("SUCCESS: no panic, no deadlock\n", .{});
        return;
    }

    if (std.mem.eql(u8, mode, "spawn-segfault")) {
        rawPrint("spawning `true` BEFORE unsetenv (to prove spawn itself works, and that merely\nspawning once beforehand does NOT pre-warm whatever cache avoids the crash)...\n", .{});
        var child1 = try std.process.spawn(io, .{ .argv = &[_][]const u8{"true"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        _ = try child1.wait(io);
        rawPrint("first spawn OK. Unsetting LANG...\n", .{});
        _ = unsetenv("LANG");
        rawPrint("spawning `true` AFTER unsetenv — this is where it segfaults...\n", .{});
        var child2 = try std.process.spawn(io, .{ .argv = &[_][]const u8{"true"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        _ = try child2.wait(io);
        // If this line ever prints, the bug is fixed/absent on this Zig version.
        rawPrint("SUCCESS: second spawn OK, no segfault\n", .{});
        return;
    }

    if (std.mem.eql(u8, mode, "print-workaround")) {
        // Isolates whether a warm-up std.debug.print call before unsetenv
        // makes *later debug.print calls* safe (independent of spawn).
        std.debug.print("warm-up debug.print, before any unsetenv\n", .{});
        _ = unsetenv("LANG");
        std.debug.print("SUCCESS: second debug.print call, after unsetenv, did not panic\n", .{});
        return;
    }

    if (std.mem.eql(u8, mode, "spawn-still-broken-after-print-warmup")) {
        // Isolates whether that same debug.print warm-up ALSO makes a
        // later std.process.spawn call safe. Spoiler: it does not — spawn
        // and debug.print apparently do not share whatever cache/state the
        // warm-up primes, so this is expected to still segfault exactly
        // like "spawn-segfault" above.
        std.debug.print("warm-up debug.print, before any unsetenv\n", .{});
        _ = unsetenv("LANG");
        var child = try std.process.spawn(io, .{ .argv = &[_][]const u8{"true"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        _ = try child.wait(io);
        std.debug.print("SUCCESS: spawn after unsetenv worked even after only a debug.print warm-up\n", .{});
        return;
    }

    rawPrint("unknown mode {s}; use panic-deadlock, spawn-segfault, print-workaround, or spawn-still-broken-after-print-warmup\n", .{mode});
}
