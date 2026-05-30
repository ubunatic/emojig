const std = @import("std");
const Io = std.Io;
const emojig = @import("emojig");
const mru = emojig.mru;

// ---------------------------------------------------------------------------
// Theme & Palette
// ---------------------------------------------------------------------------

const Theme = enum { dark, light, system };

const Palette = struct {
    bg: []const u8,           // grid rows + description row
    fg: []const u8,           // text color for grid rows (reset after selection)
    selection_bg: []const u8,
    search_bg: []const u8,    // entire search-bar row
    border_bg: []const u8,    // optional border rows
};

const dark_palette = Palette{
    .bg           = "\x1b[48;5;234m",
    .fg           = "\x1b[38;5;248m",
    .selection_bg = "\x1b[48;5;24m\x1b[38;5;255m",
    .search_bg    = "\x1b[48;5;238m\x1b[38;5;255m",
    .border_bg    = "\x1b[48;5;236m",
};

const light_palette = Palette{
    .bg           = "\x1b[48;5;255m",
    .fg           = "\x1b[38;5;238m",
    .selection_bg = "\x1b[48;5;111m\x1b[38;5;232m",
    .search_bg    = "\x1b[48;5;251m\x1b[38;5;232m",
    .border_bg    = "\x1b[48;5;252m",
};

fn themeIcon(t: Theme) []const u8 {
    return switch (t) {
        .dark   => "🌙",
        .light  => "🌞",
        .system => "🔆",
    };
}

fn effectivePalette(t: Theme, sys: Theme) Palette {
    const eff = if (t == .system) sys else t;
    return switch (eff) {
        .light         => light_palette,
        .dark, .system => dark_palette,
    };
}

// ---------------------------------------------------------------------------
// Terminal helpers
// ---------------------------------------------------------------------------

var global_orig_termios: ?std.posix.termios = null;

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
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

fn logMemoryUsage() void {
    const flags = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/statm", flags, 0) catch return;
    defer _ = std.posix.system.close(fd);

    var buf: [128]u8 = undefined;
    const len = std.posix.read(fd, &buf) catch return;
    if (len == 0) return;

    var it = std.mem.splitScalar(u8, buf[0..len], ' ');
    const virt_pages_str = it.next() orelse return;
    const rss_pages_str  = it.next() orelse return;

    const virt_pages = std.fmt.parseInt(usize, std.mem.trim(u8, virt_pages_str, " \t\r\n"), 10) catch return;
    const rss_pages  = std.fmt.parseInt(usize, std.mem.trim(u8, rss_pages_str,  " \t\r\n"), 10) catch return;

    const page_size: usize = 4096;
    const virt_bytes = virt_pages * page_size;
    const rss_bytes  = rss_pages  * page_size;

    const wr_flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const log_fd = std.posix.openat(std.posix.AT.FDCWD, "/tmp/emojig.log", wr_flags, 0o644) catch return;
    defer _ = std.posix.system.close(log_fd);

    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);

    var log_buf: [256]u8 = undefined;
    const log_line = std.fmt.bufPrint(&log_buf,
        "[{d}] Emojig closed. Memory Usage: VIRT = {d:.2} MB, RSS = {d:.2} MB\n", .{
        ts.sec,
        @as(f64, @floatFromInt(virt_bytes)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(rss_bytes))  / (1024.0 * 1024.0),
    }) catch return;

    _ = std.posix.system.write(log_fd, log_line.ptr, log_line.len);
}

// Escape sequence to disable all mouse tracking + alt screen + cursor restore.
// Uses 1003l (any-motion off) which covers 1000 as well.
const MOUSE_OFF = "\x1b[?1003l\x1b[?1006l";
const RESTORE   = MOUSE_OFF ++ "\x1b[?1049l\x1b[0q\x1b[?25h";

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(std.posix.STDIN_FILENO, .NOW, &orig);
    }
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, RESTORE, RESTORE.len);
    logMemoryUsage();
    std.process.exit(1);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(std.posix.STDIN_FILENO, .NOW, &orig);
    }
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, RESTORE, RESTORE.len);
    logMemoryUsage();
    std.debug.defaultPanic(msg, ret_addr);
}

/// Query the terminal background colour via OSC 11, detect dark/light.
fn detectSystemTheme(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) Theme {
    writeAll(stdout_fd, "\x1b]11;?\x1b\\") catch return .dark;
    var timed = raw;
    const sys = std.posix.system;
    timed.cc[@intFromEnum(sys.V.MIN)]  = 0;
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
        else r;
        const b = if (i + 14 <= resp.len and resp[i + 9] == '/')
            std.fmt.parseInt(u16, resp[i + 10 .. i + 14], 16) catch r
        else r;
        const luma = (@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114) / 1000;
        return if (luma > 32767) .light else .dark;
    }
    return .dark;
}

// ---------------------------------------------------------------------------
// Config file  (~/.config/emojig/config)
// ---------------------------------------------------------------------------

fn configPath(buf: []u8) ?[:0]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    const path = std.fmt.bufPrint(buf, "{s}/.config/emojig/config", .{home}) catch return null;
    if (path.len + 1 > buf.len) return null;
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// Read theme= from the config file. Returns null if absent or unreadable.
fn loadThemeFromConfig() ?Theme {
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return null;
    const flags = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    var file_buf: [1024]u8 = undefined;
    const len = std.posix.read(fd, &file_buf) catch return null;
    var it = std.mem.splitScalar(u8, file_buf[0..len], '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "theme=")) continue;
        const val = line["theme=".len..];
        if (std.mem.eql(u8, val, "light"))  return .light;
        if (std.mem.eql(u8, val, "dark"))   return .dark;
        if (std.mem.eql(u8, val, "system")) return .system;
    }
    return null;
}

/// Rewrite the config file with an updated theme= line, preserving other keys.
fn saveThemeToConfig(t: Theme) void {
    const theme_str: []const u8 = switch (t) {
        .dark => "dark", .light => "light", .system => "system",
    };
    const home = std.mem.span(std.c.getenv("HOME") orelse return);

    // Ensure ~/.config/emojig/ exists.
    var dir_buf: [512]u8 = undefined;
    const dot_config = std.fmt.bufPrint(&dir_buf, "{s}/.config", .{home}) catch return;
    if (dot_config.len + 1 > dir_buf.len) return;
    dir_buf[dot_config.len] = 0;
    _ = std.c.mkdir(dir_buf[0..dot_config.len :0], 0o755);
    var cfg_dir_buf: [512]u8 = undefined;
    const cfg_dir = std.fmt.bufPrint(&cfg_dir_buf, "{s}/.config/emojig", .{home}) catch return;
    if (cfg_dir.len + 1 > cfg_dir_buf.len) return;
    cfg_dir_buf[cfg_dir.len] = 0;
    _ = std.c.mkdir(cfg_dir_buf[0..cfg_dir.len :0], 0o755);

    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return;

    // Read existing content to preserve non-theme lines.
    var old_buf: [1024]u8 = undefined;
    var old_len: usize = 0;
    {
        const rf = std.posix.O{ .ACCMODE = .RDONLY };
        if (std.posix.openat(std.posix.AT.FDCWD, path, rf, 0)) |rfd| {
            old_len = std.posix.read(rfd, &old_buf) catch 0;
            _ = std.posix.system.close(rfd);
        } else |_| {}
    }

    // Rebuild: every non-theme, non-blank line, then the updated theme line.
    var out: [2048]u8 = undefined;
    var pos: usize = 0;
    var lines = std.mem.splitScalar(u8, old_buf[0..old_len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "theme=")) continue;
        if (pos + line.len + 1 >= out.len) break;
        @memcpy(out[pos..][0..line.len], line);
        pos += line.len;
        out[pos] = '\n';
        pos += 1;
    }
    const new_line = std.fmt.bufPrint(out[pos..], "theme={s}\n", .{theme_str}) catch return;
    pos += new_line.len;

    const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, wf, 0o644) catch return;
    defer _ = std.posix.system.close(fd);
    _ = std.posix.system.write(fd, out[0..pos].ptr, pos);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    // Priority: config file < EMOJIG_THEME env var < --theme CLI arg.
    var theme: Theme = loadThemeFromConfig() orelse .dark;

    if (init.environ_map.get("EMOJIG_THEME")) |env_val| {
        if (std.mem.eql(u8, env_val, "light"))       theme = .light
        else if (std.mem.eql(u8, env_val, "dark"))   theme = .dark
        else if (std.mem.eql(u8, env_val, "system")) theme = .system;
    }

    var args_it = init.minimal.args.iterate();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--theme")) {
            if (args_it.next()) |v| {
                if (std.mem.eql(u8, v, "light"))       theme = .light
                else if (std.mem.eql(u8, v, "dark"))   theme = .dark
                else if (std.mem.eql(u8, v, "system")) theme = .system
                else {
                    try writeAll(std.posix.STDERR_FILENO,
                        "Error: invalid theme. Supported values are 'dark', 'light', or 'system'.\n");
                    std.process.exit(1);
                }
            } else {
                try writeAll(std.posix.STDERR_FILENO,
                    "Error: --theme requires an argument ('dark', 'light', or 'system').\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try writeAll(std.posix.STDOUT_FILENO,
                "Emojig - Premium Zero-Allocation Emoji Picker\n\n" ++
                "Usage: emojig [options]\n\n" ++
                "Options:\n" ++
                "  --theme [dark|light|system]  Set the UI theme\n" ++
                "  -h, --help                   Show this help message\n");
            std.process.exit(0);
        }
    }

    const term_width: usize = blk: {
        const s = init.environ_map.get("EMOJIG_WIDTH") orelse break :blk 25;
        break :blk std.fmt.parseInt(usize, s, 10) catch 40;
    };

    const show_border: bool = blk: {
        const s = init.environ_map.get("EMOJIG_BORDER") orelse break :blk false;
        break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
    };

    // Row offset: when border is shown, all content rows shift down by 1.
    const row_off: i32 = if (show_border) 1 else 0;

    mru.load();

    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_fd  = std.posix.STDIN_FILENO;

    // Enable alt screen, any-motion mouse tracking (1003), SGR coords, blinking cursor, hide cursor.
    try writeAll(stdout_fd, "\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l");

    const orig_termios = try std.posix.tcgetattr(stdin_fd);
    global_orig_termios = orig_termios;

    var act = std.posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT,  &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    var raw = orig_termios;
    raw.iflag.IGNBRK = false; raw.iflag.BRKINT = false; raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false; raw.iflag.INLCR  = false; raw.iflag.IGNCR  = false;
    raw.iflag.ICRNL  = false; raw.iflag.IXON   = false;
    raw.oflag.OPOST  = false;
    raw.lflag.ECHO   = false; raw.lflag.ECHONL = false; raw.lflag.ICANON = false;
    raw.lflag.ISIG   = false; raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE  = .CS8;  raw.cflag.PARENB = false;
    const system = std.posix.system;
    raw.cc[@intFromEnum(system.V.MIN)]  = 1;
    raw.cc[@intFromEnum(system.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .NOW, raw);

    var system_theme: Theme = if (theme == .system)
        detectSystemTheme(stdin_fd, stdout_fd, raw)
    else
        theme;

    defer {
        std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
        writeAll(stdout_fd, RESTORE) catch {};
        logMemoryUsage();
    }

    var query_buf: [64]u8 = undefined;
    var query_len: usize = 0;

    const cols = 6;
    const rows = 4;
    const total_cells = cols * rows;

    var selected_idx: ?usize = null;
    var top_matches: [total_cells]emojig.Match = undefined;
    var top_count: usize = 0;

    var should_copy_and_exit = false;

    emojig.search(query_buf[0..query_len], &top_matches, &top_count, total_cells);

    var read_buf: [64]u8 = undefined;

    while (true) {
        const palette = effectivePalette(theme, system_theme);

        // ----------------------------------------------------------------
        // Render
        // ----------------------------------------------------------------
        try writeAll(stdout_fd, "\x1b[?25l\x1b[H");

        var line_buf: [1024]u8 = undefined;

        // Optional top border row.
        if (show_border) {
            try writeAll(stdout_fd, palette.border_bg);
            try writeAll(stdout_fd, "\x1b[K\r\n");
        }

        // Blank top padding row.
        try writeAll(stdout_fd, palette.bg);
        try writeAll(stdout_fd, palette.fg);
        try writeAll(stdout_fd, "\x1b[K\r\n");

        // Search bar — entire row uses search_bg for a clean "menu row" look.
        const icon_col = if (term_width >= 4) term_width - 3 else 1;
        const search_line = try std.fmt.bufPrint(&line_buf,
            "{s}🔍 {s}\x1b[K\x1b[{d}G {s} \r\n",
            .{ palette.search_bg, query_buf[0..query_len], icon_col, themeIcon(theme) });
        try writeAll(stdout_fd, search_line);

        // Blank spacer row.
        try writeAll(stdout_fd, palette.bg);
        try writeAll(stdout_fd, palette.fg);
        try writeAll(stdout_fd, "\x1b[K\r\n");

        // Grid rows.
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            var cell_buffers: [6][64]u8 = undefined;
            var cell_strings: [6][]const u8 = undefined;

            var c: usize = 0;
            while (c < cols) : (c += 1) {
                const idx = r * cols + c;
                if (idx < top_count) {
                    const m = top_matches[idx];
                    const entry = emojig.EmojiDb.getEntry(m.index);
                    if (selected_idx) |sel| {
                        if (idx == sel) {
                            cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c],
                                " {s}{s}\x1b[0m{s}{s} ",
                                .{ palette.selection_bg, entry.emoji, palette.bg, palette.fg });
                        } else {
                            cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c],
                                " {s} ", .{entry.emoji});
                        }
                    } else {
                        cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c],
                            " {s} ", .{entry.emoji});
                    }
                } else {
                    cell_strings[c] = "   ";
                }
            }

            const grid_line = try std.fmt.bufPrint(&line_buf,
                "{s}{s}{s}{s}{s}{s}{s}{s}\x1b[K\r\n",
                .{ palette.bg, palette.fg,
                   cell_strings[0], cell_strings[1], cell_strings[2],
                   cell_strings[3], cell_strings[4], cell_strings[5] });
            try writeAll(stdout_fd, grid_line);
        }

        // Description row.
        // When show_border is true the bottom border row follows, so we keep \r\n.
        // When show_border is false this IS the last rendered line; omit \r\n to
        // prevent the terminal scrolling when window-height == content-height — a
        // scroll shifts every row up by one, breaking both cursor placement and
        // hover/click row calculations.
        const desc_nl = if (show_border) "\r\n" else "";
        const max_len = if (term_width > 1) term_width - 1 else 0;
        if (selected_idx) |sel| {
            if (top_count > 0 and sel < top_count) {
                const name = emojig.EmojiDb.getEntry(top_matches[sel].index).name;
                const name_line = if (name.len > max_len and max_len >= 3)
                    try std.fmt.bufPrint(&line_buf, "{s}{s} {s}...\x1b[K{s}",
                        .{ palette.bg, palette.fg, name[0 .. max_len - 3], desc_nl })
                else
                    try std.fmt.bufPrint(&line_buf, "{s}{s} {s}\x1b[K{s}",
                        .{ palette.bg, palette.fg, name, desc_nl });
                try writeAll(stdout_fd, name_line);
            } else {
                try writeAll(stdout_fd, palette.bg);
                try writeAll(stdout_fd, "\x1b[K");
                try writeAll(stdout_fd, desc_nl);
            }
        } else {
            try writeAll(stdout_fd, palette.bg);
            try writeAll(stdout_fd, "\x1b[K");
            try writeAll(stdout_fd, desc_nl);
        }

        // Optional bottom border row — last line, no trailing \r\n for same reason.
        if (show_border) {
            try writeAll(stdout_fd, palette.border_bg);
            try writeAll(stdout_fd, "\x1b[K");
        }

        // Reposition cursor to search bar input (row 2 + row_off, col 4 + query_len).
        var cursor_buf: [48]u8 = undefined;
        const cursor_seq = try std.fmt.bufPrint(&cursor_buf,
            "\x1b[{d};{d}H\x1b[?12h\x1b[?25h",
            .{ 2 + row_off, 4 + query_len });
        try writeAll(stdout_fd, cursor_seq);

        // ----------------------------------------------------------------
        // Copy & exit deferred action (rendered one frame first)
        // ----------------------------------------------------------------
        if (should_copy_and_exit) {
            if (selected_idx) |sel| {
                if (top_count > 0 and sel < top_count) {
                    const selected = emojig.EmojiDb.getEntry(top_matches[sel].index);
                    mru.save(selected.emoji);
                    copyToClipboard(init, selected.emoji) catch {};
                }
            } else if (top_count > 0) {
                const selected = emojig.EmojiDb.getEntry(top_matches[0].index);
                mru.save(selected.emoji);
                copyToClipboard(init, selected.emoji) catch {};
            }
            break;
        }

        // ----------------------------------------------------------------
        // Read input
        // ----------------------------------------------------------------
        const n = try std.posix.read(stdin_fd, &read_buf);
        if (n == 0) break;

        const bytes = read_buf[0..n];

        if (bytes[0] == 27) {
            if (n == 1) {
                // ESC key
                break;
            } else if (n > 2 and bytes[1] == '[') {
                if (bytes[2] == 'A' or bytes[2] == 'B' or bytes[2] == 'C' or bytes[2] == 'D') {
                    // Arrow keys
                    if (selected_idx == null) {
                        if (top_count > 0) selected_idx = 0;
                        continue;
                    }
                    var sel = selected_idx.?;
                    if (bytes[2] == 'A') {
                        if (top_count > 0) {
                            if (sel >= cols) {
                                sel -= cols;
                            } else {
                                const target = sel + (rows - 1) * cols;
                                sel = if (target < top_count) target else top_count - 1;
                            }
                        }
                    } else if (bytes[2] == 'B') {
                        if (top_count > 0) {
                            const target = sel + cols;
                            sel = if (target < top_count) target else sel % cols;
                        }
                    } else if (bytes[2] == 'C') {
                        if (top_count > 0) {
                            sel = if (sel < top_count - 1) sel + 1 else 0;
                        }
                    } else if (bytes[2] == 'D') {
                        if (top_count > 0) {
                            sel = if (sel > 0) sel - 1 else top_count - 1;
                        }
                    }
                    selected_idx = sel;
                } else if (bytes[2] == '<') {
                    // SGR Mouse event — find first terminator to handle batched events.
                    const sgr_data = bytes[3..n];
                    var term_pos: usize = 0;
                    var term_char: u8 = 0;
                    while (term_pos < sgr_data.len) : (term_pos += 1) {
                        if (sgr_data[term_pos] == 'M' or sgr_data[term_pos] == 'm') {
                            term_char = sgr_data[term_pos];
                            break;
                        }
                    }
                    if (term_char == 0) continue;

                    var it = std.mem.splitScalar(u8, sgr_data[0..term_pos], ';');
                    const button_str = it.next() orelse continue;
                    const col_str   = it.next() orelse continue;
                    const row_str   = it.next() orelse continue;

                    const button    = std.fmt.parseInt(i32, button_str, 10) catch continue;
                    const click_col = std.fmt.parseInt(i32, col_str,    10) catch continue;
                    const click_row = std.fmt.parseInt(i32, row_str,    10) catch continue;

                    const is_motion = (button & 32) != 0;
                    const btn_id    = button & 3; // 0=left, 1=mid, 2=right, 3=no-button

                    if (is_motion and term_char == 'M') {
                        // Hover: update selection to cell under cursor (no copy).
                        // Each cell is 4 display columns wide: leading-space + emoji(2) + trailing-space.
                        const grid_first_row: i32 = 4 + row_off;
                        const grid_last_row:  i32 = 7 + row_off;
                        if (click_row >= grid_first_row and click_row <= grid_last_row) {
                            const grid_row = @as(usize, @intCast(click_row - grid_first_row));
                            const grid_col = @as(usize, @intCast(@max(0, click_col - 1))) / 4;
                            if (grid_col < cols) {
                                const hovered = grid_row * cols + grid_col;
                                if (hovered < top_count) selected_idx = hovered;
                            }
                        }
                    } else if (!is_motion and btn_id == 0 and term_char == 'M') {
                        // Left click press.
                        const search_row: i32 = 2 + row_off;
                        const grid_first_row: i32 = 4 + row_off;
                        const grid_last_row:  i32 = 7 + row_off;

                        if (click_row == search_row and
                            click_col >= @as(i32, @intCast(term_width)) - 3)
                        {
                            // Theme toggle icon — cycle and persist to config.
                            theme = switch (theme) {
                                .dark   => .light,
                                .light  => .system,
                                .system => .dark,
                            };
                            saveThemeToConfig(theme);
                            if (theme == .system)
                                system_theme = detectSystemTheme(stdin_fd, stdout_fd, raw);
                        } else if (click_row >= grid_first_row and click_row <= grid_last_row) {
                            const grid_row = @as(usize, @intCast(click_row - grid_first_row));
                            const grid_col = @as(usize, @intCast(@max(0, click_col - 1))) / 4;
                            if (grid_col < cols) {
                                const clicked_idx = grid_row * cols + grid_col;
                                if (clicked_idx < top_count) {
                                    selected_idx = clicked_idx;
                                    should_copy_and_exit = true;
                                }
                            }
                        }
                    }
                }
            }
        } else if (bytes[0] == 127 or bytes[0] == 8) {
            // Backspace
            if (query_len > 0) {
                query_len -= 1;
                selected_idx = if (query_len == 0) null else 0;
                emojig.search(query_buf[0..query_len], &top_matches, &top_count, total_cells);
            }
        } else if (bytes[0] == 10 or bytes[0] == 13) {
            // Enter
            should_copy_and_exit = true;
        } else if (bytes[0] == 3 or bytes[0] == 4) {
            // Ctrl-C / Ctrl-D
            break;
        } else {
            for (bytes) |b| {
                if (b >= 32 and b <= 126 and query_len < 63) {
                    query_buf[query_len] = b;
                    query_len += 1;
                    selected_idx = 0;
                    emojig.search(query_buf[0..query_len], &top_matches, &top_count, total_cells);
                }
            }
        }
    }
}

fn copyToClipboard(init: std.process.Init, text: []const u8) !void {
    const io = init.io;
    if (std.process.spawn(io, .{
        .argv   = &.{"wl-copy"},
        .stdin  = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    })) |spawned| {
        var child = spawned;
        try writeAll(child.stdin.?.handle, text);
        child.stdin.?.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
        return;
    } else |_| {}

    var child = try std.process.spawn(io, .{
        .argv   = &.{ "xclip", "-selection", "clipboard" },
        .stdin  = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try writeAll(child.stdin.?.handle, text);
    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);
}
