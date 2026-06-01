// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const emojig = @import("emojig");
const build_options = @import("build_options");
const mru = emojig.mru;

// ---------------------------------------------------------------------------
// Embedded shell integration scripts
// ---------------------------------------------------------------------------

const shell_zsh = @embedFile("shell/emojig.zsh");
const shell_bash = @embedFile("shell/emojig.bash");
const shell_fish = @embedFile("shell/emojig.fish");

// ---------------------------------------------------------------------------
// Theme & Palette
// ---------------------------------------------------------------------------

const Theme = enum { dark, light, system };

const Palette = struct {
    bg: []const u8, // grid rows + description row
    fg: []const u8, // text color for grid rows (reset after selection)
    selection_bg: []const u8,
    search_bg: []const u8, // entire search-bar row
    border_bg: []const u8, // optional border rows
};

const dark_palette = Palette{
    .bg = "",
    .fg = "\x1b[38;5;248m",
    .selection_bg = "\x1b[48;5;24m\x1b[38;5;255m",
    .search_bg = "\x1b[48;5;238m\x1b[38;5;255m",
    .border_bg = "",
};

const light_palette = Palette{
    .bg = "",
    .fg = "\x1b[38;5;238m",
    .selection_bg = "\x1b[48;5;111m\x1b[38;5;232m",
    .search_bg = "\x1b[48;5;251m\x1b[38;5;232m",
    .border_bg = "",
};

fn themeIcon(t: Theme) []const u8 {
    return switch (t) {
        .dark => "🌙",
        .light => "🌞",
        .system => "🔆",
    };
}

fn effectivePalette(t: Theme, sys: Theme) Palette {
    const eff = if (t == .system) sys else t;
    return switch (eff) {
        .light => light_palette,
        .dark, .system => dark_palette,
    };
}

fn applyTerminalColors(stdout_fd: std.posix.fd_t, t: Theme, sys: Theme) void {
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

var global_orig_termios: ?std.posix.termios = null;
var global_tty_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

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
const MOUSE_OFF = "\x1b[?1003l\x1b[?1006l";
const RESTORE = MOUSE_OFF ++ "\x1b[0q\x1b[?25h\x1b]111\x1b\\\x1b]110\x1b\\";

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(global_tty_fd, .NOW, &orig);
    }
    _ = std.posix.system.write(global_tty_fd, RESTORE, RESTORE.len);
    logMemoryUsage();
    std.process.exit(1);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(global_tty_fd, .NOW, &orig);
    }
    _ = std.posix.system.write(global_tty_fd, RESTORE, RESTORE.len);
    logMemoryUsage();
    std.debug.defaultPanic(msg, ret_addr);
}

/// Query the terminal background colour via OSC 11, detect dark/light.
fn detectSystemTheme(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) Theme {
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

const Config = struct {
    theme: ?Theme = null,
    width: ?usize = null,
    height: ?usize = null,
    border: ?bool = null,
    safe: ?bool = null,
};

/// Read configuration from the config file in a single pass.
fn loadConfig(io: std.Io) Config {
    var cfg = Config{};
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return cfg;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return cfg;
    defer file.close(io);
    var file_buf: [4096]u8 = undefined;
    const len = file.readPositionalAll(io, &file_buf, 0) catch return cfg;
    // If buffer is full the file may be larger; skip parsing to avoid acting on truncated data.
    if (len == file_buf.len) return cfg;
    var it = std.mem.splitScalar(u8, file_buf[0..len], '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const key = line[0..eq_idx];
            const val = line[eq_idx + 1 ..];
            if (std.mem.eql(u8, key, "theme")) {
                if (std.mem.eql(u8, val, "light")) cfg.theme = .light else if (std.mem.eql(u8, val, "dark")) cfg.theme = .dark else if (std.mem.eql(u8, val, "system")) cfg.theme = .system;
            } else if (std.mem.eql(u8, key, "width")) {
                cfg.width = std.fmt.parseInt(usize, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "height")) {
                cfg.height = std.fmt.parseInt(usize, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "border")) {
                cfg.border = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            } else if (std.mem.eql(u8, key, "safe")) {
                cfg.safe = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            }
        }
    }
    return cfg;
}

/// Rewrite the config file with an updated theme= line, preserving other keys.
fn saveThemeToConfig(io: std.Io, t: Theme) void {
    const theme_str: []const u8 = switch (t) {
        .dark => "dark",
        .light => "light",
        .system => "system",
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
    var old_buf: [4096]u8 = undefined;
    var old_len: usize = 0;
    if (std.Io.Dir.openFileAbsolute(io, path, .{})) |rfile| {
        old_len = rfile.readPositionalAll(io, &old_buf, 0) catch 0;
        rfile.close(io);
        // If buffer is full the file may be larger; abort to avoid silently truncating it.
        if (old_len == old_buf.len) return;
    } else |_| {}

    // Rebuild: every non-theme, non-blank line, then the updated theme line.
    var out: [4096 + 32]u8 = undefined;
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

    const wfile = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return;
    defer wfile.close(io);
    wfile.writePositionalAll(io, out[0..pos], 0) catch {};
}

fn ensureDirExists(home: []const u8, sub_path: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, sub_path }) catch return;
    if (path.len + 1 > path_buf.len) return;
    path_buf[path.len] = 0;
    _ = std.c.mkdir(path_buf[0..path.len :0], 0o755);
}

fn ensureDesktopIntegration(home: []const u8, exe_path: []const u8) void {
    ensureDirExists(home, ".local");
    ensureDirExists(home, ".local/share");
    ensureDirExists(home, ".local/share/applications");
    ensureDirExists(home, ".local/share/icons");
    ensureDirExists(home, ".local/share/icons/hicolor");
    ensureDirExists(home, ".local/share/icons/hicolor/scalable");
    ensureDirExists(home, ".local/share/icons/hicolor/scalable/apps");

    // Write .desktop entry
    var desktop_path_buf: [512]u8 = undefined;
    const desktop_path = std.fmt.bufPrint(&desktop_path_buf, "{s}/.local/share/applications/emojig-picker.desktop", .{home}) catch return;
    var desktop_content: [2048]u8 = undefined;
    const desktop_text = std.fmt.bufPrint(&desktop_content,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Emojig Picker
        \\Comment=Interactive emoji picker
        \\Exec={s} --gui
        \\Icon=emojig-picker
        \\Terminal=false
        \\Categories=Utility;
        \\StartupWMClass=emojig-picker
        \\
    , .{exe_path}) catch return;

    if (desktop_path.len + 1 <= desktop_path_buf.len) {
        desktop_path_buf[desktop_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, desktop_path_buf[0..desktop_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, desktop_text.ptr, desktop_text.len);
        } else |_| {}
    }

    // Write SVG icon
    var svg_path_buf: [512]u8 = undefined;
    const svg_path = std.fmt.bufPrint(&svg_path_buf, "{s}/.local/share/icons/hicolor/scalable/apps/emojig-picker.svg", .{home}) catch return;
    const svg_text =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
        \\  <text y="0.9em" font-size="80">😀</text>
        \\</svg>
        \\
    ;
    if (svg_path.len + 1 <= svg_path_buf.len) {
        svg_path_buf[svg_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, svg_path_buf[0..svg_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, svg_text.ptr, svg_text.len);
        } else |_| {}
    }
}

fn spawnFootWindow(
    init: std.process.Init,
    exe_path: []const u8,
    width: usize,
    height: usize,
    theme: Theme,
    border: bool,
    safe: bool,
    wait: bool,
) !void {
    const io = init.io;
    const theme_str: []const u8 = switch (theme) {
        .dark => "dark",
        .light => "light",
        .system => "system",
    };

    const foot_bg = if (theme == .light) "eeeeee" else "1c1c1c";
    const foot_fg = if (theme == .light) "444444" else "a8a8a8";

    const final_h = if (border) height + 2 else height;

    var size_buf: [64]u8 = undefined;
    const size_arg = try std.fmt.bufPrint(&size_buf, "--window-size-chars={d}x{d}", .{ width + 2, final_h });

    var bg_buf: [64]u8 = undefined;
    const bg_arg = try std.fmt.bufPrint(&bg_buf, "--override=colors.background={s}", .{foot_bg});

    var fg_buf: [64]u8 = undefined;
    const fg_arg = try std.fmt.bufPrint(&fg_buf, "--override=colors.foreground={s}", .{foot_fg});

    var env_w: [64]u8 = undefined;
    const env_w_arg = try std.fmt.bufPrint(&env_w, "EMOJIG_WIDTH={d}", .{width});

    var env_h: [64]u8 = undefined;
    const env_h_arg = try std.fmt.bufPrint(&env_h, "EMOJIG_HEIGHT={d}", .{height});

    var env_theme: [64]u8 = undefined;
    const env_theme_arg = try std.fmt.bufPrint(&env_theme, "EMOJIG_THEME={s}", .{theme_str});

    var env_border: [64]u8 = undefined;
    const env_border_arg = try std.fmt.bufPrint(&env_border, "EMOJIG_BORDER={s}", .{if (border) "1" else "0"});

    var env_safe: [64]u8 = undefined;
    const env_safe_arg = try std.fmt.bufPrint(&env_safe, "EMOJIG_SAFE={s}", .{if (safe) "1" else "0"});

    const timeout_val = init.environ_map.get("EMOJIG_PICKER_TIMEOUT") orelse "60";

    const argv = &.{
        "timeout",
        timeout_val,
        "foot",
        "--app-id=emojig-picker",
        size_arg,
        "--override=font=monospace:size=14",
        "--override=cursor.blink=yes",
        "--override=pad=8x4",
        "--override=csd.size=0",
        bg_arg,
        fg_arg,
        "env",
        env_w_arg,
        env_h_arg,
        env_theme_arg,
        env_border_arg,
        env_safe_arg,
        exe_path,
        "--tui",
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    if (wait) {
        _ = try child.wait(io);
    }
}

// ---------------------------------------------------------------------------
// Shell integration install
// ---------------------------------------------------------------------------

fn writeFile(path_buf: []u8, path: []const u8, content: []const u8) bool {
    if (path.len + 1 > path_buf.len) return false;
    path_buf[path.len] = 0;
    const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], wf, 0o644) catch return false;
    defer _ = std.posix.system.close(fd);
    _ = std.posix.system.write(fd, content.ptr, content.len);
    return true;
}

fn copyBinary(io: std.Io, home: []const u8) bool {
    var src_buf: [1024]u8 = undefined;
    const src_len = std.process.executablePath(io, &src_buf) catch return false;
    const src_path = src_buf[0..src_len];

    var dst_buf: [1024]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/.local/bin/emojig", .{home}) catch return false;

    // Skip copy if already running from the destination.
    if (std.mem.eql(u8, src_path, dst_path)) return true;

    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    if (src_path.len + 1 > src_buf.len) return false;
    src_buf[src_len] = 0;
    const src_fd = std.posix.openat(std.posix.AT.FDCWD, src_buf[0..src_len :0], rf, 0) catch return false;
    defer _ = std.posix.system.close(src_fd);

    if (dst_path.len + 1 > dst_buf.len) return false;
    dst_buf[dst_path.len] = 0;
    const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const dst_fd = std.posix.openat(std.posix.AT.FDCWD, dst_buf[0..dst_path.len :0], wf, 0o755) catch return false;
    defer _ = std.posix.system.close(dst_fd);

    var copy_buf: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(src_fd, &copy_buf) catch break;
        if (n == 0) break;
        _ = std.posix.system.write(dst_fd, copy_buf[0..n].ptr, n);
    }
    return true;
}

fn installShellIntegration(io: std.Io, home: []const u8) void {
    ensureDirExists(home, ".local");
    ensureDirExists(home, ".local/bin");
    ensureDirExists(home, ".local/share");
    ensureDirExists(home, ".local/share/emojig");
    ensureDirExists(home, ".local/share/emojig/shell");

    const bin_ok = copyBinary(io, home);

    var buf: [512]u8 = undefined;

    const zsh_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.zsh", .{home}) catch return;
    _ = writeFile(&buf, zsh_path, shell_zsh);

    const bash_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.bash", .{home}) catch return;
    _ = writeFile(&buf, bash_path, shell_bash);

    const fish_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.fish", .{home}) catch return;
    _ = writeFile(&buf, fish_path, shell_fish);

    if (bin_ok) {
        writeAll(std.posix.STDOUT_FILENO, "Installed binary to ~/.local/bin/emojig\n") catch {};
    } else {
        writeAll(std.posix.STDOUT_FILENO, "Warning: could not copy binary to ~/.local/bin/emojig\n") catch {};
    }

    writeAll(std.posix.STDOUT_FILENO, "Installed shell integration to ~/.local/share/emojig/shell/\n\n" ++
        "Add one line to your shell rc file:\n\n" ++
        "  zsh  (~/.zshrc):\n" ++
        "    source ~/.local/share/emojig/shell/emojig.zsh\n\n" ++
        "  bash (~/.bashrc):\n" ++
        "    source ~/.local/share/emojig/shell/emojig.bash\n\n" ++
        "  fish (~/.config/fish/config.fish):\n" ++
        "    source ~/.local/share/emojig/shell/emojig.fish\n\n" ++
        "Then reload your shell and press Ctrl+E at any prompt.\n") catch {};
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var opt_tui = false;
    var opt_gui = false;
    var opt_wait = false;
    var opt_install = false;
    var opt_theme: ?Theme = null;
    var opt_width: ?usize = null;
    var opt_height: ?usize = null;
    var opt_border: ?bool = null;
    var opt_safe = false;

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // Skip executable path
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tui")) {
            opt_tui = true;
        } else if (std.mem.eql(u8, arg, "--install")) {
            opt_install = true;
        } else if (std.mem.eql(u8, arg, "--gui")) {
            opt_gui = true;
        } else if (std.mem.eql(u8, arg, "--wait")) {
            opt_wait = true;
        } else if (std.mem.eql(u8, arg, "--safe")) {
            opt_safe = true;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            if (args_it.next()) |v| {
                if (std.mem.eql(u8, v, "light")) opt_theme = .light else if (std.mem.eql(u8, v, "dark")) opt_theme = .dark else if (std.mem.eql(u8, v, "system")) opt_theme = .system else {
                    try writeAll(std.posix.STDERR_FILENO, "Error: invalid theme. Supported values are 'dark', 'light', or 'system'.\n");
                    std.process.exit(1);
                }
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --theme requires an argument ('dark', 'light', or 'system').\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--width")) {
            if (args_it.next()) |v| {
                opt_width = std.fmt.parseInt(usize, v, 10) catch {
                    try writeAll(std.posix.STDERR_FILENO, "Error: invalid width. Must be an integer.\n");
                    std.process.exit(1);
                };
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --width requires an argument.\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--height")) {
            if (args_it.next()) |v| {
                opt_height = std.fmt.parseInt(usize, v, 10) catch {
                    try writeAll(std.posix.STDERR_FILENO, "Error: invalid height. Must be an integer.\n");
                    std.process.exit(1);
                };
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --height requires an argument.\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--border")) {
            if (args_it.next()) |v| {
                if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
                    opt_border = true;
                } else if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) {
                    opt_border = false;
                } else {
                    try writeAll(std.posix.STDERR_FILENO, "Error: invalid border. Must be 1/0 or true/false.\n");
                    std.process.exit(1);
                }
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --border requires an argument.\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try writeAll(std.posix.STDOUT_FILENO, "emojig " ++ build_options.version ++ "\n");
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try writeAll(std.posix.STDOUT_FILENO, "Emojig - Premium Zero-Allocation Emoji Picker\n\n" ++
                "Usage: emojig [options]\n\n" ++
                "Options:\n" ++
                "  --theme [dark|light|system]  Set the UI theme\n" ++
                "  --width [number]             Set the width of the picker\n" ++
                "  --height [number]            Set the height of the picker\n" ++
                "  --border [1|0|true|false]    Enable or disable the border\n" ++
                "  --safe                       Safe mode: strip U+FE0F variation selector from screen rendering too\n" ++
                "  --tui                        Force local interactive TUI session\n" ++
                "  --gui                        Force floating terminal window (spawns foot)\n" ++
                "  --wait                       Wait for spawned window to close (with --gui)\n" ++
                "  --install                    Install shell integration scripts to ~/.local/share/emojig/shell/\n" ++
                "  -v, --version                Show version and exit\n" ++
                "  -h, --help                   Show this help message\n");
            std.process.exit(0);
        } else {
            try writeAll(std.posix.STDERR_FILENO, "Error: unknown argument '");
            try writeAll(std.posix.STDERR_FILENO, arg);
            try writeAll(std.posix.STDERR_FILENO, "'. Use -h or --help for usage.\n");
            std.process.exit(1);
        }
    }

    if (opt_install) {
        const home = std.mem.span(std.c.getenv("HOME") orelse {
            try writeAll(std.posix.STDERR_FILENO, "Error: HOME not set.\n");
            std.process.exit(1);
        });
        installShellIntegration(init.io, home);
        std.process.exit(0);
    }

    const cfg = loadConfig(init.io);

    const env_theme: ?Theme = blk: {
        if (init.environ_map.get("EMOJIG_THEME")) |env_val| {
            if (std.mem.eql(u8, env_val, "light")) break :blk .light else if (std.mem.eql(u8, env_val, "dark")) break :blk .dark else if (std.mem.eql(u8, env_val, "system")) break :blk .system;
        }
        break :blk null;
    };

    const env_width: ?usize = blk: {
        if (init.environ_map.get("EMOJIG_WIDTH")) |env_val| {
            break :blk std.fmt.parseInt(usize, env_val, 10) catch null;
        }
        break :blk null;
    };

    const env_height: ?usize = blk: {
        if (init.environ_map.get("EMOJIG_HEIGHT")) |env_val| {
            break :blk std.fmt.parseInt(usize, env_val, 10) catch null;
        }
        break :blk null;
    };

    const env_border: ?bool = blk: {
        if (init.environ_map.get("EMOJIG_BORDER")) |env_val| {
            break :blk std.mem.eql(u8, env_val, "1") or std.mem.eql(u8, env_val, "true");
        }
        break :blk null;
    };

    const env_safe: ?bool = blk: {
        if (init.environ_map.get("EMOJIG_SAFE")) |env_val| {
            break :blk std.mem.eql(u8, env_val, "1") or std.mem.eql(u8, env_val, "true");
        }
        break :blk null;
    };

    const final_theme = opt_theme orelse env_theme orelse cfg.theme orelse .dark;
    const final_width = opt_width orelse env_width orelse cfg.width orelse 25;
    const final_height = opt_height orelse env_height orelse cfg.height orelse 8;
    const final_border = opt_border orelse env_border orelse cfg.border orelse false;
    const final_safe = opt_safe or (env_safe orelse cfg.safe orelse false);

    const has_gui_session = blk: {
        const wayland = init.environ_map.get("WAYLAND_DISPLAY");
        const x11 = init.environ_map.get("DISPLAY");
        break :blk (wayland != null and wayland.?.len > 0) or (x11 != null and x11.?.len > 0);
    };

    const can_use_tty = blk: {
        const flags = std.posix.O{ .ACCMODE = .RDWR };
        if (std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", flags, 0)) |fd| {
            _ = std.posix.system.close(fd);
            break :blk true;
        } else |_| break :blk false;
    };

    const is_linux_vt = blk: {
        const term = init.environ_map.get("TERM");
        break :blk term != null and std.mem.eql(u8, term.?, "linux");
    };

    const is_ssh = init.environ_map.get("SSH_CONNECTION") != null or init.environ_map.get("SSH_CLIENT") != null or init.environ_map.get("SSH_TTY") != null;

    const force_stdout = is_ssh or is_linux_vt or (std.c.isatty(std.posix.STDOUT_FILENO) == 0);

    if (is_linux_vt and !opt_gui and !opt_tui) {
        try writeAll(std.posix.STDERR_FILENO,
            \\emojig: Linux virtual console detected (TERM=linux).
            \\Emoji glyphs cannot render in the kernel console font.
            \\
            \\Please switch to a graphical terminal emulator (foot, alacritty, kitty, ...)
            \\or connect via SSH from a machine with a terminal emulator.
            \\
        );
        std.process.exit(1);
    }

    var run_gui = false;
    if (opt_tui) {
        if (!can_use_tty) {
            try writeAll(std.posix.STDERR_FILENO, "Error: TUI requires an interactive terminal.\n");
            std.process.exit(1);
        }
    } else if (opt_gui) {
        if (!has_gui_session) {
            try writeAll(std.posix.STDERR_FILENO, "Error: No graphical (GUI) session detected.\n");
            std.process.exit(1);
        }
        run_gui = true;
    } else {
        if (can_use_tty) {
            // run TUI in-place
        } else if (has_gui_session) {
            run_gui = true;
        } else {
            try writeAll(std.posix.STDERR_FILENO, "Error: TUI requires an interactive terminal and no GUI session was detected.\n");
            std.process.exit(1);
        }
    }

    if (run_gui) {
        var exe_path_buf: [1024]u8 = undefined;
        const exe_path_len = std.process.executablePath(init.io, &exe_path_buf) catch |err| {
            try writeAll(std.posix.STDERR_FILENO, "Error: failed to resolve own executable path: ");
            try writeAll(std.posix.STDERR_FILENO, @errorName(err));
            try writeAll(std.posix.STDERR_FILENO, "\n");
            std.process.exit(1);
        };
        const exe_path = exe_path_buf[0..exe_path_len];

        if (std.c.getenv("HOME")) |home_c| {
            const home = std.mem.span(home_c);
            ensureDesktopIntegration(home, exe_path);
        }

        spawnFootWindow(
            init,
            exe_path,
            final_width,
            final_height,
            final_theme,
            final_border,
            final_safe,
            opt_wait,
        ) catch |err| {
            try writeAll(std.posix.STDERR_FILENO, "Error: failed to launch terminal window. Make sure 'foot' and 'timeout' are installed and in your PATH (");
            try writeAll(std.posix.STDERR_FILENO, @errorName(err));
            try writeAll(std.posix.STDERR_FILENO, ").\n");
            std.process.exit(1);
        };
        std.process.exit(0);
    }

    var theme = final_theme;
    const term_width = final_width;
    const show_border = final_border;

    // Row offset: when border is shown, all content rows shift down by 1.
    const row_off: i32 = if (show_border) 1 else 0;

    var result_emoji: ?[]const u8 = null;
    var result_safe_buf: [64]u8 = undefined;

    const tty_flags = std.posix.O{ .ACCMODE = .RDWR };
    const tty_fd = try std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", tty_flags, 0);
    defer _ = std.posix.system.close(tty_fd);
    global_tty_fd = tty_fd;
    const stdout_fd = tty_fd;
    const stdin_fd = tty_fd;

    {
        mru.load();

        const orig_termios = try std.posix.tcgetattr(stdin_fd);
        global_orig_termios = orig_termios;

        var act = std.posix.Sigaction{
            .handler = .{ .handler = sigHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);

        var raw = orig_termios;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        const system = std.posix.system;
        raw.cc[@intFromEnum(system.V.MIN)] = 1;
        raw.cc[@intFromEnum(system.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin_fd, .NOW, raw);

        var system_theme: Theme = if (theme == .system)
            detectSystemTheme(stdin_fd, stdout_fd, raw)
        else
            theme;

        const content_rows: usize = 8;
        const final_h = if (show_border) content_rows + 2 else content_rows;
        var is_first_render = true;

        defer {
            std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
            if (!is_first_render) {
                // Move cursor to top of our TUI region from the search bar line where we are
                var move_buf: [32]u8 = undefined;
                const move_seq = std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{1 + row_off}) catch "";
                _ = std.posix.system.write(stdout_fd, move_seq.ptr, move_seq.len);

                // Clear each of the final_h lines
                var k: usize = 0;
                while (k < final_h) : (k += 1) {
                    const clear_seq = "\x1b[2K";
                    _ = std.posix.system.write(stdout_fd, clear_seq.ptr, clear_seq.len);
                    if (k < final_h - 1) {
                        const down_seq = "\x1b[B\r";
                        _ = std.posix.system.write(stdout_fd, down_seq.ptr, down_seq.len);
                    }
                }
                // Move cursor back up to the top start position so the new prompt is printed there
                if (final_h > 1) {
                    const move_up = std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{final_h - 1}) catch "";
                    _ = std.posix.system.write(stdout_fd, move_up.ptr, move_up.len);
                }
            }
            writeAll(stdout_fd, RESTORE) catch {};
            logMemoryUsage();
        }

        // Enable any-motion mouse tracking (1003), SGR coords, blinking cursor, hide cursor.
        // Must come after defer is registered so RESTORE is guaranteed to disable tracking.
        try writeAll(stdout_fd, "\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l");

        applyTerminalColors(stdout_fd, theme, system_theme);

        var query_buf: [64]u8 = undefined;
        var query_len: usize = 0;

        const cols = 6;
        const rows = 4;
        const total_cells = cols * rows;

        var selected_idx: ?usize = null;
        var top_matches: [total_cells]emojig.Match = undefined;
        var top_count: usize = 0;

        var should_copy_and_exit = false;
        var theme_hovered = false;

        emojig.search(query_buf[0..query_len], &top_matches, &top_count, total_cells);

        var read_buf: [64]u8 = undefined;
        const spaces = " " ** 512;
        const content_width = term_width;

        while (true) {
            const palette = effectivePalette(theme, system_theme);

            // ----------------------------------------------------------------
            // Render
            // ----------------------------------------------------------------
            try writeAll(stdout_fd, "\x1b[?25l");
            if (!is_first_render) {
                var move_buf: [32]u8 = undefined;
                const move_seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{1 + row_off});
                try writeAll(stdout_fd, move_seq);
            } else {
                is_first_render = false;
            }

            var line_buf: [1024]u8 = undefined;

            // Optional top border row.
            if (show_border) {
                try writeAll(stdout_fd, " ");
                try writeAll(stdout_fd, palette.border_bg);
                try writeAll(stdout_fd, spaces[0..@min(content_width, spaces.len)]);
                try writeAll(stdout_fd, "\x1b[0m \r\n");
            }

            // Blank top padding row.
            try writeAll(stdout_fd, " ");
            try writeAll(stdout_fd, palette.bg);
            try writeAll(stdout_fd, palette.fg);
            try writeAll(stdout_fd, spaces[0..@min(content_width, spaces.len)]);
            try writeAll(stdout_fd, "\x1b[0m \r\n");

            // Search bar — entire row uses search_bg for a clean "menu row" look.
            const prefix_cols = 3;
            const icon_cols = 4;
            const max_query_cols = if (content_width > prefix_cols + icon_cols) content_width - prefix_cols - icon_cols else 0;
            const display_query_len = @min(query_len, max_query_cols);
            const pad_len = if (content_width > prefix_cols + icon_cols)
                content_width - prefix_cols - icon_cols - display_query_len
            else
                0;

            try writeAll(stdout_fd, " ");
            try writeAll(stdout_fd, palette.search_bg);
            try writeAll(stdout_fd, "🔍 ");
            try writeAll(stdout_fd, query_buf[0..display_query_len]);
            try writeAll(stdout_fd, spaces[0..pad_len]);
            const icon_hl = if (theme_hovered) palette.selection_bg else "";
            const icon_buf = try std.fmt.bufPrint(&line_buf, " {s}{s}{s} ", .{ icon_hl, themeIcon(theme), palette.search_bg });
            try writeAll(stdout_fd, icon_buf);
            try writeAll(stdout_fd, "\x1b[0m \r\n");

            // Blank spacer row.
            try writeAll(stdout_fd, " ");
            try writeAll(stdout_fd, palette.bg);
            try writeAll(stdout_fd, palette.fg);
            try writeAll(stdout_fd, spaces[0..@min(content_width, spaces.len)]);
            try writeAll(stdout_fd, "\x1b[0m \r\n");

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
                        var strip_buf: [32]u8 = undefined;
                        const render_emoji = if (final_safe) emojig.stripVariationSelectors(entry.emoji, &strip_buf) else entry.emoji;
                        if (selected_idx) |sel| {
                            if (idx == sel) {
                                cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s}{s}\x1b[0m{s}{s} ", .{ palette.selection_bg, render_emoji, palette.bg, palette.fg });
                            } else {
                                cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s} ", .{render_emoji});
                            }
                        } else {
                            cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s} ", .{render_emoji});
                        }
                    } else {
                        cell_strings[c] = "    ";
                    }
                }

                const grid_rem = if (content_width > 24) content_width - 24 else 0;
                const grid_line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}{s}{s}{s}{s}{s}\x1b[0m \r\n", .{ palette.bg, palette.fg, cell_strings[0], cell_strings[1], cell_strings[2], cell_strings[3], cell_strings[4], cell_strings[5], spaces[0..grid_rem] });
                try writeAll(stdout_fd, grid_line);
            }

            // Description row.
            const desc_suffix = if (show_border) " \r\n" else " ";
            const max_len = if (content_width > 1) content_width - 1 else 0;
            if (selected_idx) |sel| {
                if (top_count > 0 and sel < top_count) {
                    const name = emojig.EmojiDb.getEntry(top_matches[sel].index).name;
                    if (name.len > max_len and max_len >= 3) {
                        const display_name = name[0 .. max_len - 3];
                        const printed_cols = 1 + display_name.len + 3;
                        const pad_len_desc = if (content_width > printed_cols) content_width - printed_cols else 0;
                        const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}...{s}\x1b[0m{s}", .{ palette.bg, palette.fg, display_name, spaces[0..pad_len_desc], desc_suffix });
                        try writeAll(stdout_fd, name_line);
                    } else {
                        const printed_cols = 1 + name.len;
                        const pad_len_desc = if (content_width > printed_cols) content_width - printed_cols else 0;
                        const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}{s}\x1b[0m{s}", .{ palette.bg, palette.fg, name, spaces[0..pad_len_desc], desc_suffix });
                        try writeAll(stdout_fd, name_line);
                    }
                } else {
                    const pad_len_desc = content_width;
                    const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s}\x1b[0m{s}", .{ palette.bg, spaces[0..pad_len_desc], desc_suffix });
                    try writeAll(stdout_fd, name_line);
                }
            } else {
                const pad_len_desc = content_width;
                const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s}\x1b[0m{s}", .{ palette.bg, spaces[0..pad_len_desc], desc_suffix });
                try writeAll(stdout_fd, name_line);
            }

            // Optional bottom border row.
            if (show_border) {
                try writeAll(stdout_fd, " ");
                try writeAll(stdout_fd, palette.border_bg);
                try writeAll(stdout_fd, spaces[0..@min(content_width, spaces.len)]);
                try writeAll(stdout_fd, "\x1b[0m ");
            }

            // Reposition cursor to search bar input (relative up, horizontal absolute column).
            var cursor_buf: [48]u8 = undefined;
            const cursor_up = final_h - @as(usize, @intCast(2 + row_off));
            const cursor_seq = try std.fmt.bufPrint(&cursor_buf, "\x1b[{d}A\x1b[{d}G\x1b[?12h\x1b[?25h", .{ cursor_up, 5 + query_len });
            try writeAll(stdout_fd, cursor_seq);

            // ----------------------------------------------------------------
            // Copy & exit deferred action (rendered one frame first)
            // ----------------------------------------------------------------
            if (should_copy_and_exit) {
                const sel_idx = selected_idx orelse if (top_count > 0) @as(usize, 0) else null;
                if (sel_idx) |sel| {
                    if (sel < top_count) {
                        const selected = emojig.EmojiDb.getEntry(top_matches[sel].index);
                        mru.save(selected.emoji);
                        if (!force_stdout) {
                            // Standalone: stdout is the terminal — copy to clipboard only.
                            copyToClipboard(init, selected.emoji, final_safe) catch {
                                // If copy fails (e.g. over SSH/VT, or without clipboard tools), fall back to printing to stdout
                                result_emoji = if (final_safe)
                                    emojig.stripVariationSelectors(selected.emoji, &result_safe_buf)
                                else
                                    selected.emoji;
                            };
                        } else {
                            // SSH, VT, or piped/captured: print to stdout, also try clipboard in background.
                            result_emoji = if (final_safe)
                                emojig.stripVariationSelectors(selected.emoji, &result_safe_buf)
                            else
                                selected.emoji;
                            copyToClipboard(init, selected.emoji, final_safe) catch {};
                        }
                    }
                }
                break;
            }

            // ----------------------------------------------------------------
            // Read input
            // ----------------------------------------------------------------
            var n = try std.posix.read(stdin_fd, &read_buf);
            if (n == 0) break;

            // If we got a lone ESC, wait briefly for the rest of an escape sequence.
            // Arrow keys send ESC [ A/B/C/D; in some contexts (e.g. ZLE widgets) the
            // bytes can arrive in separate reads.
            if (n == 1 and read_buf[0] == 27) {
                var timed = raw;
                timed.cc[@intFromEnum(system.V.MIN)] = 0;
                timed.cc[@intFromEnum(system.V.TIME)] = 1; // 100 ms
                std.posix.tcsetattr(stdin_fd, .NOW, timed) catch {};
                const n_rest = std.posix.read(stdin_fd, read_buf[1..]) catch 0;
                std.posix.tcsetattr(stdin_fd, .NOW, raw) catch {};
                n += n_rest;
            }

            const bytes = read_buf[0..n];

            if (bytes[0] == 27) {
                if (n == 1) {
                    // ESC key
                    break;
                } else if (n > 2 and bytes[1] == '[') {
                    // Alt+F4: \x1b[1;3S (XTerm mod=3) or \x1b[1;9S (kitty mod=9)
                    if (n >= 6 and bytes[2] == '1' and bytes[3] == ';' and bytes[5] == 'S' and
                        (bytes[4] == '3' or bytes[4] == '9'))
                    {
                        break;
                    } else if (bytes[2] == 'A' or bytes[2] == 'B' or bytes[2] == 'C' or bytes[2] == 'D') {
                        // Arrow keys — normal cursor key mode (\x1b[A/B/C/D)
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
                        const col_str = it.next() orelse continue;
                        const row_str = it.next() orelse continue;

                        const button = std.fmt.parseInt(i32, button_str, 10) catch continue;
                        const click_col = std.fmt.parseInt(i32, col_str, 10) catch continue;
                        const click_row = std.fmt.parseInt(i32, row_str, 10) catch continue;
                        const local_col = click_col - 1;

                        const is_motion = (button & 32) != 0;
                        const btn_id = button & 3; // 0=left, 1=mid, 2=right, 3=no-button

                        if (is_motion and term_char == 'M') {
                            // Theme button hover.
                            const search_row_m: i32 = 2 + row_off;
                            theme_hovered = (click_row == search_row_m and
                                local_col >= @as(i32, @intCast(content_width)) - 4);

                            // Grid hover: update selection to cell under cursor (no copy).
                            // Each cell is 4 display columns wide: leading-space + emoji(2) + trailing-space.
                            const grid_first_row: i32 = 4 + row_off;
                            const grid_last_row: i32 = 7 + row_off;
                            if (click_row >= grid_first_row and click_row <= grid_last_row) {
                                const grid_row = @as(usize, @intCast(click_row - grid_first_row));
                                const grid_col = @as(usize, @intCast(@max(0, local_col - 1))) / 4;
                                if (grid_col < cols) {
                                    const hovered = grid_row * cols + grid_col;
                                    if (hovered < top_count) selected_idx = hovered;
                                }
                            }
                        } else if (!is_motion and btn_id == 0 and term_char == 'M') {
                            // Left click press.
                            const search_row: i32 = 2 + row_off;
                            const grid_first_row: i32 = 4 + row_off;
                            const grid_last_row: i32 = 7 + row_off;

                            if (click_row == search_row and
                                local_col >= @as(i32, @intCast(content_width)) - 4)
                            {
                                // Theme toggle icon — cycle and persist to config.
                                theme = switch (theme) {
                                    .dark => .light,
                                    .light => .system,
                                    .system => .dark,
                                };
                                saveThemeToConfig(init.io, theme);
                                if (theme == .system)
                                    system_theme = detectSystemTheme(stdin_fd, stdout_fd, raw);
                                applyTerminalColors(stdout_fd, theme, system_theme);
                            } else if (click_row >= grid_first_row and click_row <= grid_last_row) {
                                const grid_row = @as(usize, @intCast(click_row - grid_first_row));
                                const grid_col = @as(usize, @intCast(@max(0, local_col - 1))) / 4;
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
                } else if (n > 2 and bytes[1] == 'O') {
                    // Arrow keys — application cursor key mode (\x1bOA/B/C/D)
                    // ZLE keeps the terminal in smkx (application mode) during widget execution.
                    if (bytes[2] == 'A' or bytes[2] == 'B' or bytes[2] == 'C' or bytes[2] == 'D') {
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
            } else if (bytes[0] == 9) {
                // Tab: Cycle theme
                theme = switch (theme) {
                    .dark => .light,
                    .light => .system,
                    .system => .dark,
                };
                saveThemeToConfig(init.io, theme);
                if (theme == .system) {
                    system_theme = detectSystemTheme(stdin_fd, stdout_fd, raw);
                }
                applyTerminalColors(stdout_fd, theme, system_theme);
            } else if (bytes[0] == 3 or bytes[0] == 4 or bytes[0] == 0x11 or bytes[0] == 0x17) {
                // Ctrl-C / Ctrl-D / Ctrl-Q / Ctrl-W
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

    if (result_emoji) |emoji| {
        const ts = std.posix.system.timespec{
            .sec = 0,
            .nsec = 20 * std.time.ns_per_ms,
        };
        _ = std.posix.system.nanosleep(&ts, null);
        writeAll(std.posix.STDOUT_FILENO, emoji) catch {};
        writeAll(std.posix.STDOUT_FILENO, "\n") catch {};
    }
}

fn copyToClipboard(init: std.process.Init, text: []const u8, safe: bool) !void {
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
        try writeAll(child.stdin.?.handle, clean_text);
        child.stdin.?.close(io);
        child.stdin = null;
        if (child.wait(io)) |term| {
            switch (term) {
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
            try writeAll(child.stdin.?.handle, clean_text);
            child.stdin.?.close(io);
            child.stdin = null;
            if (child.wait(io)) |term| {
                switch (term) {
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
                try writeAll(child.stdin.?.handle, clean_text);
                child.stdin.?.close(io);
                child.stdin = null;
                if (child.wait(io)) |term| {
                    switch (term) {
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
        return error.ClipboardFailed;
    }
}
