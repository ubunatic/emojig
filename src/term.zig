// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

// ---------------------------------------------------------------------------
// Theme & Palette
// ---------------------------------------------------------------------------

pub const Theme = enum { dark, light, system };

pub fn themeName(t: Theme) []const u8 {
    return switch (t) {
        .dark => "dark",
        .light => "light",
        .system => "system",
    };
}

pub const Palette = struct {
    grid_bg: []const u8, // background sequence for grid rows
    grid_fg: []const u8, // grid_bg + fg — resets bg; only use inside grid rows
    grid_fg_only: []const u8, // fg-only (no bg reset); safe to use on any bg
    selection_bg: []const u8, // selection background sequence
    search_bg: []const u8, // entire search-bar row bg+fg sequence
    status_bg: []const u8, // entire status-bar row sequence
    categories_bg: []const u8, // category switcher row bg+fg sequence (null → search_bg)
    info_bg: []const u8, // info bar background sequence
    info_fg: []const u8, // info bar text color sequence
    border_bg: []const u8, // optional border background sequence
    search_shade_fg: []const u8, // foreground color sequence for search bar shading
    status_shade_fg: []const u8, // foreground color sequence for status bar shading
    border_shade_fg: []const u8, // foreground color sequence for border shading
    warning_fg: []const u8, // warning foreground color sequence
    success_fg: []const u8, // success/action foreground color sequence
    toolbar_sep_fg: []const u8, // fg color for toolbar separators (grid bg color as fg)
    app_bg: []const u8, // overall canvas background sequence
    app_topline_bg: []const u8, // top padding/border row background sequence
    emoji_pane_bg: []const u8, // emoji scroll pane background sequence
    scrollbar_rail_bg: []const u8, // scrollbar rail background sequence
    view_bg: []const u8, // help/about/status/settings view background sequence
    // Search-bar cap escape sequences — bg+fg colors only, no character.
    // Combine with g_spec.strings.search_left_cap / search_right_cap for the glyph.
    search_left_cap_seq: []const u8,
    search_right_cap_seq: []const u8,
    // Per-segment separator sequences: bg+fg colors for search↔theme and theme↔settings.
    search_theme_sep: []const u8,
    theme_settings_sep: []const u8,
    // Search-bar text area foreground sequences (empty = inherit from search_bg).
    search_cursor_fg: []const u8,
    search_text_fg: []const u8,
    search_placeholder_fg: []const u8,
    hline: []const u8, // horizontal rule escape sequence (app_bg as bg, hline_fg as fg)
};

// Palettes, the theme icon, and terminal color values now live in the
// declarative spec (spec/theme.yaml) and are built at startup by src/spec.zig.
// See Spec.paletteFor / Spec.iconFor / Spec.terminalColors.

/// Apply the terminal background/foreground via OSC 11/10. `bg`/`fg` are hex
/// strings including the leading '#' (e.g. "#1c1c1c"), sourced from the spec.
pub fn applyTerminalColors(stdout_fd: std.posix.fd_t, bg: ?[]const u8, fg: ?[]const u8) void {
    if (bg) |b| {
        var osc_buf: [64]u8 = undefined;
        const osc_seq = std.fmt.bufPrint(&osc_buf, "\x1b]11;{s}\x1b\\", .{b}) catch return;
        writeAll(stdout_fd, osc_seq) catch {};
    }
    if (fg) |f| {
        var osc_buf: [64]u8 = undefined;
        const osc_seq = std.fmt.bufPrint(&osc_buf, "\x1b]10;{s}\x1b\\", .{f}) catch return;
        writeAll(stdout_fd, osc_seq) catch {};
    }
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

/// Append a timestamped line to /tmp/emojig.log.
/// The caller formats the message body; a Unix second timestamp and newline
/// are prepended/appended automatically.  Uses raw POSIX I/O — no heap.
pub fn appendLog(comptime fmt: []const u8, args: anytype) void {
    const wr_flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/tmp/emojig.log", wr_flags, 0o644) catch return;
    defer _ = std.posix.system.close(fd);
    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    var buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&buf, "[{d}] ", .{ts.sec}) catch return;
    const body = std.fmt.bufPrint(buf[hdr.len..], fmt ++ "\n", args) catch return;
    const total = hdr.len + body.len;
    _ = std.posix.system.write(fd, buf[0..total].ptr, total);
}

/// Read RSS from /proc/self/statm and return it in bytes (0 on error).
pub fn readRssBytes() usize {
    const flags = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/statm", flags, 0) catch return 0;
    defer _ = std.posix.system.close(fd);
    var buf: [64]u8 = undefined;
    const len = std.posix.read(fd, &buf) catch return 0;
    if (len == 0) return 0;
    var it = std.mem.splitScalar(u8, buf[0..len], ' ');
    _ = it.next(); // virt
    const rss_str = it.next() orelse return 0;
    const rss_pages = std.fmt.parseInt(usize, std.mem.trim(u8, rss_str, " \t\r\n"), 10) catch return 0;
    return rss_pages * 4096;
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

// ---------------------------------------------------------------------------
// ANSI escape sequences (issue 45): one named constant / helper per concern.
// Renderers must not build these shapes inline — route new cursor, clear, or
// mode sequences through this block so they stay byte-tested below.
// ---------------------------------------------------------------------------

// Cursor visibility & blink (DECTCEM ?25, att610 blink ?12).
pub const CURSOR_HIDE = "\x1b[?25l";
pub const CURSOR_SHOW = "\x1b[?25h";
pub const CURSOR_BLINK = "\x1b[?12h";
pub const CURSOR_SHOW_BLINK = CURSOR_BLINK ++ CURSOR_SHOW;
pub const CURSOR_HOME = "\x1b[1;1H";

// Terminal mode toggles.
pub const ALT_SCREEN_ON = "\x1b[?1049h"; // the matching off lives in RESTORE_ALT
pub const WRAP_OFF = "\x1b[?7l"; // DECAWM off; RESTORE re-enables it with ?7h
pub const FOCUS_ON = "\x1b[?1004h"; // focus-report events; MOUSE_OFF disables

// Line clearing / row stepping.
pub const CLEAR_LINE = "\x1b[2K"; // clear whole line, cursor stays
pub const CLEAR_LINE_CR = CLEAR_LINE ++ "\r";
pub const CR_CLEAR_LINE = "\r" ++ CLEAR_LINE;
pub const CLEAR_BELOW = "\x1b[J";
pub const CLEAR_SCREEN = "\x1b[2J";
pub const CURSOR_DOWN_CR = "\x1b[B\r";

// SGR attribute toggles (color/palette SGR building lives in color.zig).
pub const BOLD = "\x1b[1m";
pub const BOLD_OFF = "\x1b[22m";
pub const REVERSE = "\x1b[7m";
pub const REVERSE_OFF = "\x1b[27m";

// Comptime format-string fragments for sequences with numeric parameters.
// Use them either via the helpers below or concatenated into larger comptime
// format strings (e.g. FMT_MOVE_TO_COL ++ "{s}").
pub const FMT_MOVE_TO_ROW = "\x1b[{d};1H"; // absolute row, column 1
pub const FMT_MOVE_TO = "\x1b[{d};{d}H"; // absolute row;col
pub const FMT_MOVE_TO_COL = "\x1b[{d}G"; // absolute column, same row
pub const FMT_CURSOR_UP = "\x1b[{d}A"; // relative up
pub const FMT_SCROLL_UP = "\x1b[{d}S"; // scroll viewport up

/// "\x1b[{row};1H" — jump to an absolute row, column 1. Returns a slice into
/// `buf`; empty on overflow (cannot happen for buf.len >= 16).
pub fn moveToRow(buf: []u8, row: anytype) []const u8 {
    return std.fmt.bufPrint(buf, FMT_MOVE_TO_ROW, .{row}) catch "";
}

/// "\x1b[{row};{col}H" — jump to an absolute row and column.
pub fn moveTo(buf: []u8, row: anytype, col: anytype) []const u8 {
    return std.fmt.bufPrint(buf, FMT_MOVE_TO, .{ row, col }) catch "";
}

/// "\x1b[{col}G" — jump to an absolute column on the current row.
pub fn moveToCol(buf: []u8, col: anytype) []const u8 {
    return std.fmt.bufPrint(buf, FMT_MOVE_TO_COL, .{col}) catch "";
}

/// "\x1b[{n}A\r" — move up n rows and return to column 1.
pub fn cursorUpCr(buf: []u8, n: anytype) []const u8 {
    return std.fmt.bufPrint(buf, FMT_CURSOR_UP ++ "\r", .{n}) catch "";
}

/// "\x1b[{n}S" — scroll the viewport up by n lines.
pub fn scrollUp(buf: []u8, n: anytype) []const u8 {
    return std.fmt.bufPrint(buf, FMT_SCROLL_UP, .{n}) catch "";
}

test "ansi helpers: exact byte output" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[5;1H", moveToRow(&buf, 5));
    try std.testing.expectEqualStrings("\x1b[12;34H", moveTo(&buf, 12, 34));
    try std.testing.expectEqualStrings("\x1b[7G", moveToCol(&buf, 7));
    try std.testing.expectEqualStrings("\x1b[3A\r", cursorUpCr(&buf, 3));
    try std.testing.expectEqualStrings("\x1b[9S", scrollUp(&buf, 9));
}

test "ansi constants: exact bytes" {
    try std.testing.expectEqualStrings("\x1b[?25l", CURSOR_HIDE);
    try std.testing.expectEqualStrings("\x1b[?12h\x1b[?25h", CURSOR_SHOW_BLINK);
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?7l", ALT_SCREEN_ON ++ WRAP_OFF);
    try std.testing.expectEqualStrings("\x1b[?1004h", FOCUS_ON);
    try std.testing.expectEqualStrings("\x1b[2K\r", CLEAR_LINE_CR);
    try std.testing.expectEqualStrings("\r\x1b[2K", CR_CLEAR_LINE);
    try std.testing.expectEqualStrings("\x1b[B\r", CURSOR_DOWN_CR);
    try std.testing.expectEqualStrings("\x1b[1m", BOLD);
    try std.testing.expectEqualStrings("\x1b[22m", BOLD_OFF);
    try std.testing.expectEqualStrings("\x1b[7m", REVERSE);
    try std.testing.expectEqualStrings("\x1b[27m", REVERSE_OFF);
    // The terminal-restore trio (§2 safety) must keep these exact parts.
    try std.testing.expect(std.mem.startsWith(u8, RESTORE, MOUSE_OFF));
    try std.testing.expect(std.mem.indexOf(u8, RESTORE, CURSOR_SHOW) != null);
    try std.testing.expect(std.mem.indexOf(u8, RESTORE_ALT, "\x1b[?1049l") != null);
}

// Escape sequence to disable all mouse tracking + focus reporting + cursor restore.
// Uses 1003l (any-motion off) which covers 1000 as well, and 1004l to disable focus events.
pub const MOUSE_OFF = "\x1b[?1003l\x1b[?1006l\x1b[?1004l";
// RESTORE must NOT emit "\x1b[?1049l" in inline (non-alt-screen) mode: VTE
// terminals (Tilix, GNOME Terminal, Ptyxis) execute the "restore saved cursor"
// half of ?1049l even when the alt screen was never entered, yanking the cursor
// away from the parked position and leaving blank lines before the next prompt
// (foot/tmux ignore the unmatched ?1049l, masking the bug there).
// "\x1b[?7h" re-enables auto-wrap (DECAWM) — the '?' is required; plain
// "\x1b[7h" is ANSI mode 7, which terminals don't implement.
pub const RESTORE = MOUSE_OFF ++ "\x1b[0q\x1b[?25h\x1b[?7h\x1b]111\x1b\\\x1b]110\x1b\\";
pub const RESTORE_ALT = MOUSE_OFF ++ "\x1b[?1049l" ++ "\x1b[0q\x1b[?25h\x1b[?7h\x1b]111\x1b\\\x1b]110\x1b\\";

pub const DetectedTermColor = struct {
    r: u16,
    g: u16,
    b: u16,
    luma: u32,
    theme: Theme,
};

pub var last_system_theme_color: ?DetectedTermColor = null;

/// OSC 11 luma cutoff (0–65535) for `--theme system` detection. Set from
/// spec/theme.yaml `detect.osc_luma_threshold` when the spec loads; the
/// initializer only covers detection that runs before spec.load (none today).
pub var system_luma_threshold: u32 = 32767;

/// Run `gsettings get SCHEMA KEY` and return the output stripped of shell-ish
/// quoting. Returns a slice into `buf`, or empty on failure.
fn gsettingsGet(io: anytype, schema: []const u8, key: []const u8, buf: []u8) []u8 {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    const pipe_rc = std.os.linux.pipe2(&pipe_fds, .{});
    if (std.posix.errno(pipe_rc) != .SUCCESS) return buf[0..0];

    const argv = [_][]const u8{ "gsettings", "get", schema, key };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    }) catch {
        _ = std.posix.system.close(pipe_fds[1]);
        _ = std.posix.system.close(pipe_fds[0]);
        return buf[0..0];
    };
    _ = std.posix.system.close(pipe_fds[1]);

    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(pipe_fds[0], buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = std.posix.system.close(pipe_fds[0]);
    _ = child.wait(io) catch {};
    const trimmed = std.mem.trim(u8, buf[0..total], " \t\n\r'\"");
    return @constCast(trimmed);
}

fn containsDarkAscii(s: []const u8) bool {
    if (s.len < "dark".len) return false;
    var i: usize = 0;
    while (i + "dark".len <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i .. i + "dark".len], "dark")) return true;
    }
    return false;
}

/// Detect the desktop light/dark preference via GNOME gsettings.
///
/// Order matters:
/// 1. `color-scheme=prefer-dark` means dark.
/// 2. `color-scheme=default|prefer-light` falls through to GTK theme name.
/// 3. A GTK theme containing "dark" means dark; otherwise light.
/// Returns null when gsettings is unavailable/unreadable so callers can use a
/// context-specific fallback.
pub fn detectDesktopTheme(io: anytype) ?Theme {
    var color_buf: [64]u8 = undefined;
    const color_scheme = gsettingsGet(io, "org.gnome.desktop.interface", "color-scheme", &color_buf);
    if (std.mem.eql(u8, color_scheme, "prefer-dark")) return .dark;

    var gtk_buf: [128]u8 = undefined;
    const gtk_theme = gsettingsGet(io, "org.gnome.desktop.interface", "gtk-theme", &gtk_buf);
    if (gtk_theme.len == 0) {
        return if (color_scheme.len > 0) .light else null;
    }
    return if (containsDarkAscii(gtk_theme)) .dark else .light;
}

/// Query the terminal background colour via OSC 11, detect dark/light.
pub fn detectSystemTheme(io: anytype, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) Theme {
    _ = io;
    last_system_theme_color = null;

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
        const detected_theme = if (luma > system_luma_threshold) Theme.light else Theme.dark;
        last_system_theme_color = .{ .r = r, .g = g, .b = b, .luma = luma, .theme = detected_theme };
        return detected_theme;
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
