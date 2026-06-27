// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const emojig = @import("emojig");
const term = @import("term.zig");

pub fn copyToClipboard(init: std.process.Init, text: []const u8, safe: bool) !void {
    const io = init.io;
    var buf: [64]u8 = undefined;
    const clean_text = if (safe) emojig.stripVariationSelectors(text, &buf) else text;

    var copied = false;

    if (std.process.spawn(io, .{
        .argv = &.{"wl-copy"},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    })) |spawned| {
        var child = spawned;
        try term.writeAll(child.stdin.?.handle, clean_text);
        child.stdin.?.close(io);
        child.stdin = null;
        if (child.wait(io)) |term_res| {
            switch (term_res) {
                .exited => |code| {
                    if (code == 0) copied = true;
                },
                else => {},
            }
        } else |_| {}
    } else |_| {}

    if (!copied) {
        if (std.process.spawn(io, .{
            .argv = &.{ "xclip", "-selection", "clipboard" },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        })) |spawned| {
            var child = spawned;
            try term.writeAll(child.stdin.?.handle, clean_text);
            child.stdin.?.close(io);
            child.stdin = null;
            if (child.wait(io)) |term_res| {
                switch (term_res) {
                    .exited => |code| {
                        if (code == 0) copied = true;
                    },
                    else => {},
                }
            } else |_| {}
        } else |_| {}
    }

    if (!copied) {
        if (init.environ_map.get("TMUX") != null) {
            if (std.process.spawn(io, .{
                .argv = &.{ "tmux", "load-buffer", "-" },
                .stdin = .pipe,
                .stdout = .ignore,
                .stderr = .ignore,
            })) |spawned| {
                var child = spawned;
                try term.writeAll(child.stdin.?.handle, clean_text);
                child.stdin.?.close(io);
                child.stdin = null;
                if (child.wait(io)) |term_res| {
                    switch (term_res) {
                        .exited => |code| {
                            if (code == 0) copied = true;
                        },
                        else => {},
                    }
                } else |_| {}
            } else |_| {}
        }
    }

    if (!copied) {
        // Fallback: OSC 52 escape sequence (remote terminal & browser sandbox compatible)
        const tty_flags = std.posix.O{ .ACCMODE = .WRONLY };
        if (std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", tty_flags, 0)) |fd| {
            defer _ = std.posix.system.close(fd);
            var base64_buf: [256]u8 = undefined;
            const base64_str = std.base64.standard.Encoder.encode(&base64_buf, clean_text);
            var osc_buf: [512]u8 = undefined;
            // Write to both CLIPBOARD ('c') and PRIMARY ('p') selection buffers
            const osc_seq_c = std.fmt.bufPrint(&osc_buf, "\x1b]52;c;{s}\x07", .{base64_str}) catch "";
            if (osc_seq_c.len > 0) {
                _ = std.posix.system.write(fd, osc_seq_c.ptr, osc_seq_c.len);
            }
            const osc_seq_p = std.fmt.bufPrint(&osc_buf, "\x1b]52;p;{s}\x07", .{base64_str}) catch "";
            if (osc_seq_p.len > 0) {
                _ = std.posix.system.write(fd, osc_seq_p.ptr, osc_seq_p.len);
            }
            copied = true;
        } else |_| {}
    }

    if (!copied) {
        return error.ClipboardFailed;
    }
}
