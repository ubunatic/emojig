// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

// ---------------------------------------------------------------------------
// Theme & Palette
// ---------------------------------------------------------------------------

pub const Theme = enum { dark, light, system };

pub const Palette = struct {
    bg: []const u8, // grid rows + description row
    fg: []const u8, // text color for grid rows (reset after selection)
    selection_bg: []const u8,
    search_bg: []const u8, // entire search-bar row
    border_bg: []const u8, // optional border rows
    search_shade_fg: []const u8, // foreground color sequence for search bar shading
    border_shade_fg: []const u8, // foreground color sequence for border shading
};

pub const dark_palette = Palette{
    .bg = "",
    .fg = "\x1b[38;5;248m",
    .selection_bg = "\x1b[48;5;24m\x1b[38;5;255m",
    .search_bg = "\x1b[48;5;238m\x1b[38;5;255m",
    .border_bg = "",
    .search_shade_fg = "\x1b[38;5;238m",
    .border_shade_fg = "\x1b[38;5;236m",
};

pub const light_palette = Palette{
    .bg = "",
    .fg = "\x1b[38;5;238m",
    .selection_bg = "\x1b[48;5;111m\x1b[38;5;232m",
    .search_bg = "\x1b[48;5;251m\x1b[38;5;232m",
    .border_bg = "",
    .search_shade_fg = "\x1b[38;5;251m",
    .border_shade_fg = "\x1b[38;5;252m",
};

pub fn themeIcon(t: Theme) []const u8 {
    return switch (t) {
        .dark => "🌙",
        .light => "🌞",
        .system => "🔆",
    };
}

pub fn effectivePalette(t: Theme, sys: Theme) Palette {
    const eff = if (t == .system) sys else t;
    return switch (eff) {
        .light => light_palette,
        .dark, .system => dark_palette,
    };
}

pub fn applyTerminalColors(stdout_fd: std.posix.fd_t, t: Theme, sys: Theme) void {
    const eff = if (t == .system) sys else t;
    const bg = if (eff == .light) "#eeeeee" else "#1c1c1c";
    const fg = if (eff == .light) "#444444" else "#a8a8a8";
    var osc_buf: [64]u8 = undefined;
    const osc_seq = std.fmt.bufPrint(&osc_buf, "\x1b]11;{s}\x1b\\\x1b]10;{s}\x1b\\", .{ bg, fg }) catch return;
    writeAll(stdout_fd, osc_seq) catch {};
}

// ---------------------------------------------------------------------------
// Terminal helpers
// ---------------------------------------------------------------------------

pub fn queryCursorRow(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) ?i32 {
    const sys = std.posix.system;

    // CRITICAL WARNING FOR SUBSEQUENT AGENTS/DEVELOPERS:
    // We MUST drain stdin non-blockingly before writing "\x1b[6n". If there are any stale buffered
    // bytes in the input queue (such as mouse click releases or motion events from startup/resize),
    // sys.read will read them instead of the CPR response, causing queryCursorRow to fail (returns null).
    // A null global_tui_start_row disables viewport warping mouse offset mapping, rendering mouse clicks
    // and hovers completely dead. DO NOT REMOVE THIS DRAIN BLOCK!
    var drain = raw;
    drain.cc[@intFromEnum(sys.V.MIN)] = 0;
    drain.cc[@intFromEnum(sys.V.TIME)] = 0;
    std.posix.tcsetattr(stdin_fd, .NOW, drain) catch return null;

    var drain_buf: [256]u8 = undefined;
    while (true) {
        const rc = sys.read(stdin_fd, &drain_buf, drain_buf.len);
        if (rc <= 0) break;
    }

    // 2. Now write the query sequence
    writeAll(stdout_fd, "\x1b[6n") catch return null;

    // 3. Configure to 200ms timeout for reading the response
    var timed = raw;
    timed.cc[@intFromEnum(sys.V.MIN)] = 0;
    timed.cc[@intFromEnum(sys.V.TIME)] = 2; // 200 ms timeout
    std.posix.tcsetattr(stdin_fd, .NOW, timed) catch return null;
    defer std.posix.tcsetattr(stdin_fd, .NOW, raw) catch {};

    var buf: [32]u8 = undefined;
    const n = std.posix.read(stdin_fd, &buf) catch return null;
    if (n == 0) return null;

    const resp = buf[0..n];
    var i: usize = 0;
    while (i + 2 < resp.len) : (i += 1) {
        if (resp[i] == '\x1b' and resp[i + 1] == '[') {
            i += 2;
            var r: i32 = 0;
            while (i < resp.len and resp[i] >= '0' and resp[i] <= '9') : (i += 1) {
                r = r * 10 + @as(i32, @intCast(resp[i] - '0'));
            }
            if (i < resp.len and resp[i] == ';') {
                return r;
            }
        }
    }
    return null;
}

pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[index..].ptr, bytes.len - index);
        const err = std.posix.errno(rc);
        if (err == .SUCCESS) {
            if (rc == 0) return error.Unexpected;
            index += @intCast(rc);
        } else if (err == .INTR) {
            continue;
        } else {
            return error.SystemResources;
        }
    }
}

pub fn logMemoryUsage() void {
    const flags = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/statm", flags, 0) catch return;
    defer _ = std.posix.system.close(fd);

    var buf: [128]u8 = undefined;
    const len = std.posix.read(fd, &buf) catch return;
    if (len == 0) return;

    var it = std.mem.splitScalar(u8, buf[0..len], ' ');
    const virt_pages_str = it.next() orelse return;
    const rss_pages_str = it.next() orelse return;

    const virt_pages = std.fmt.parseInt(usize, std.mem.trim(u8, virt_pages_str, " \t\r\n"), 10) catch return;
    const rss_pages = std.fmt.parseInt(usize, std.mem.trim(u8, rss_pages_str, " \t\r\n"), 10) catch return;

    const page_size: usize = 4096;
    const virt_bytes = virt_pages * page_size;
    const rss_bytes = rss_pages * page_size;

    const wr_flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const log_fd = std.posix.openat(std.posix.AT.FDCWD, "/tmp/emojig.log", wr_flags, 0o644) catch return;
    defer _ = std.posix.system.close(log_fd);

    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);

    var log_buf: [256]u8 = undefined;
    const log_line = std.fmt.bufPrint(&log_buf, "[{d}] Emojig closed. Memory Usage: VIRT = {d:.2} MB, RSS = {d:.2} MB\n", .{
        ts.sec,
        @as(f64, @floatFromInt(virt_bytes)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(rss_bytes)) / (1024.0 * 1024.0),
    }) catch return;

    _ = std.posix.system.write(log_fd, log_line.ptr, log_line.len);
}

// Escape sequence to disable all mouse tracking + alt screen + cursor restore.
// Uses 1003l (any-motion off) which covers 1000 as well.
pub const MOUSE_OFF = "\x1b[?1003l\x1b[?1006l";
pub const RESTORE = MOUSE_OFF ++ "\x1b[?1049l\x1b[0q\x1b[?25h\x1b[7h\x1b]111\x1b\\\x1b]110\x1b\\";

/// Query the terminal background colour via OSC 11, detect dark/light.
pub fn detectSystemTheme(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) Theme {
    // Reset terminal colors to default first to ensure we query the native system theme,
    // not any custom theme background/foreground we previously applied.
    writeAll(stdout_fd, "\x1b]111\x1b\\\x1b]110\x1b\\\x1b]11;?\x1b\\") catch return .dark;
    var timed = raw;
    const sys = std.posix.system;
    timed.cc[@intFromEnum(sys.V.MIN)] = 0;
    timed.cc[@intFromEnum(sys.V.TIME)] = 2;
    std.posix.tcsetattr(stdin_fd, .NOW, timed) catch return .dark;
    defer std.posix.tcsetattr(stdin_fd, .NOW, raw) catch {};
    var buf: [64]u8 = undefined;
    const n = std.posix.read(stdin_fd, &buf) catch return .dark;
    if (n == 0) return .dark;
    const resp = buf[0..n];
    var i: usize = 0;
    const prefix = "rgb:";
    while (i + prefix.len <= resp.len) : (i += 1) {
        if (!std.mem.startsWith(u8, resp[i..], prefix)) continue;
        i += prefix.len;
        if (i + 4 > resp.len) break;
        const r = std.fmt.parseInt(u16, resp[i .. i + 4], 16) catch break;
        const g = if (i + 9 <= resp.len and resp[i + 4] == '/')
            std.fmt.parseInt(u16, resp[i + 5 .. i + 9], 16) catch r
        else
            r;
        const b = if (i + 14 <= resp.len and resp[i + 9] == '/')
            std.fmt.parseInt(u16, resp[i + 10 .. i + 14], 16) catch r
        else
            r;

        const luma = (@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114) / 1000;
        return if (luma > 32767) .light else .dark;
    }
    return .dark;
}

/// Map absolute viewport row to TUI-relative row (accounting for cursor start and potential scroll).
pub fn mapSgrRow(click_row_raw: i32, start_row_opt: ?i32, tty_fd: std.posix.fd_t, final_h: usize) i32 {
    const start_row = start_row_opt orelse return click_row_raw;
    var ws_mouse = std.mem.zeroes(std.posix.winsize);
    const rc_mouse = std.posix.system.ioctl(tty_fd, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws_mouse));
    if (rc_mouse == 0 and ws_mouse.row > 0) {
        const actual_h = @as(i32, @intCast(ws_mouse.row));
        const tui_h = @as(i32, @intCast(final_h));
        const scroll_amount = if (start_row + tui_h - 1 > actual_h)
            (start_row + tui_h - 1) - actual_h
        else
            0;
        const y_start = start_row - scroll_amount;
        return click_row_raw - y_start + 1;
    }
    return click_row_raw;
}
