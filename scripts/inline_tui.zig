// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// inline_tui.zig — faithful Zig port of scripts/inline_tui.go for direct behavioral comparison.
//
// Matches the Go app exactly in strategy:
//   startup  : emit tuiHeight-1 newlines → cursorUp(tuiHeight-1); cursor lands at TUI top
//   draw     : clearLine + content + cursorDown (\x1b[B\r) between rows; cursorUp(n-1) at end
//   SIGWINCH : update hidden flag only — NO repositioning; next draw overwrites in place
//   hidden   : rows < tuiHeight+1; collapses to single clearLine, no cursor advance
//   teardown : clearLine + cursorDown per row, then cursorUp(n-1); print "(bye)"
//
// Run:  zig run scripts/inline_tui.zig
// Args: -delay <ms>   redraw interval in milliseconds (default 100)

const std = @import("std");
const system = std.posix.system;

const tui_height: usize = 6;

// ANSI sequences
const cursor_hide = "\x1b[?25l";
const cursor_show = "\x1b[?25h";
const cursor_blink = "\x1b[?12h";
const wrap_off = "\x1b[?7l";
const wrap_on = "\x1b[?7h";
const clear_line = "\x1b[2K\r"; // clear entire line, carriage return
const cursor_down = "\x1b[B\r"; // move down one row without scrolling

var g_fd: std.posix.fd_t = undefined;
var g_orig: std.posix.termios = undefined;
var g_winch: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn write(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = system.write(g_fd, bytes[i..].ptr, bytes.len - i);
        switch (std.posix.errno(rc)) {
            .SUCCESS => i += @intCast(rc),
            .INTR => {},
            else => return,
        }
    }
}

fn cursorUp(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d}A\r", .{n}) catch "";
}

fn termRows() usize {
    var ws = std.mem.zeroes(std.posix.winsize);
    _ = system.ioctl(g_fd, system.T.IOCGWINSZ, @intFromPtr(&ws));
    return if (ws.row > 0) ws.row else 24;
}

fn sigwinchHandler(_: std.posix.SIG) callconv(.c) void {
    g_winch.store(true, .release);
}

fn enterRaw(delay_ms: u32) !void {
    g_orig = try std.posix.tcgetattr(g_fd);
    var raw = g_orig;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    // VMIN=0 + VTIME=N: read returns after N*100ms with 0 bytes if no input
    raw.cc[@intFromEnum(system.V.MIN)] = 0;
    raw.cc[@intFromEnum(system.V.TIME)] = @intCast(@min(255, (delay_ms + 99) / 100));
    try std.posix.tcsetattr(g_fd, .NOW, raw);
}

fn leaveRaw() void {
    std.posix.tcsetattr(g_fd, .NOW, g_orig) catch {};
    write(cursor_show ++ wrap_on);
}

fn drawFrame(tick: usize, hidden: bool) void {
    var up_buf: [16]u8 = undefined;

    if (hidden) {
        write(clear_line);
        return;
    }

    var title_buf: [32]u8 = undefined;
    const blink: []const u8 = if (tick % 2 == 0) " " else "█";
    const title = std.fmt.bufPrint(&title_buf, " inline TUI  [{s}]", .{blink}) catch " inline TUI  [?]";

    const lines = [tui_height][]const u8{
        "",
        title,
        " \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
        " row 1: hello",
        " row 2: world",
        " q to quit",
    };

    for (lines, 0..) |l, i| {
        write(clear_line);
        write(l);
        if (i < lines.len - 1) write(cursor_down);
    }
    // Leave cursor at TUI top — identical to the Go app.
    write(cursorUp(&up_buf, tui_height - 1));
}

fn clearTUI() void {
    var up_buf: [16]u8 = undefined;
    for (0..tui_height) |i| {
        write(clear_line);
        if (i < tui_height - 1) write(cursor_down);
    }
    if (tui_height > 1) write(cursorUp(&up_buf, tui_height - 1));
}

pub fn main(init: std.process.Init) !void {
    // Parse -delay <ms> from args.
    var delay_ms: u32 = 100;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // skip argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-delay")) {
            if (it.next()) |val| {
                delay_ms = std.fmt.parseInt(u32, val, 10) catch delay_ms;
            }
        }
    }

    g_fd = try std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0);
    defer _ = system.close(g_fd);

    try enterRaw(delay_ms);
    defer leaveRaw();

    const winch_act = std.posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &winch_act, null);

    // Startup: emit tuiHeight-1 newlines to reserve space, then move cursor back to TUI top.
    // This is the ONLY time we scroll; all subsequent redraws overwrite in place.
    {
        var up_buf: [16]u8 = undefined;
        for (0..tui_height - 1) |_| write("\n");
        write(cursorUp(&up_buf, tui_height - 1));
    }

    write(wrap_off ++ cursor_hide ++ cursor_blink);

    var hidden = termRows() < tui_height + 1;
    var tick: usize = 0;
    var buf: [1]u8 = undefined;

    outer: while (true) {
        if (g_winch.swap(false, .acq_rel)) {
            // SIGWINCH: update hidden flag only — no repositioning, no erase.
            hidden = termRows() < tui_height + 1;
        }

        const n = std.posix.read(g_fd, &buf) catch 0;
        if (n > 0) {
            if (buf[0] == 'q' or buf[0] == 3) break :outer;
        } else {
            if (g_winch.swap(false, .acq_rel)) {
                hidden = termRows() < tui_height + 1;
            }
            // Timeout or interrupted — draw next frame.
            tick += 1;
            drawFrame(tick, hidden);
        }
    }

    clearTUI();
    write("\r(bye)\r\n");
}
