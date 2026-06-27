// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const term_lib = @import("term.zig");
const Theme = term_lib.Theme;
const writeAll = term_lib.writeAll;
const spec_mod = @import("spec.zig");

/// Known terminal emulators with specific argv layouts.
pub const HostKind = enum {
    foot,
    kitty,
    alacritty,
    wezterm,
    ghostty,
    konsole,
    gnome_terminal,
    ptyxis,
    xfce4_terminal,
    xterm,
    generic,
};

/// Check whether `name` (a basename like "kitty") exists as an executable on
/// `$PATH`. Uses only stack buffers — no heap allocation.
pub fn whichOnPath(path_env: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const joined = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        const rc = std.posix.system.faccessat(std.posix.AT.FDCWD, joined, std.posix.X_OK, 0);
        if (std.posix.errno(rc) == .SUCCESS) return true;
    }
    return false;
}

/// Select the terminal host to use, following this precedence:
///   1. EMOJIG_TERMINAL (absolute path or name; used as-is, no PATH check needed)
///   2. $TERMINAL env var if the program exists on PATH
///   3. Detection list: foot, kitty, alacritty, wezterm, ghostty, konsole,
///      gnome-terminal, xterm — first found on PATH wins.
/// Returns the terminal executable string and its HostKind.
/// Returns null if no usable terminal could be found.
pub const TerminalSelection = struct {
    exe: []const u8,
    kind: HostKind,
};

pub fn selectTerminalHost(environ_map: anytype) ?TerminalSelection {
    const path_env = environ_map.get("PATH") orelse "";

    // 1. EMOJIG_TERMINAL — explicit override, no PATH check
    if (environ_map.get("EMOJIG_TERMINAL")) |t| {
        if (t.len > 0) {
            const base = std.fs.path.basename(t);
            return .{ .exe = t, .kind = hostKindFromName(base) };
        }
    }

    // 2. $TERMINAL if it exists on PATH
    if (environ_map.get("TERMINAL")) |t| {
        if (t.len > 0 and whichOnPath(path_env, t)) {
            return .{ .exe = t, .kind = hostKindFromName(t) };
        }
    }

    // 3. Detection list — foot preferred (listed first)
    const candidates = [_][]const u8{
        "foot",
        "ptyxis",
        "kitty",
        "alacritty",
        "wezterm",
        "ghostty",
        "konsole",
        "gnome-terminal",
        "xterm",
    };
    for (candidates) |name| {
        if (whichOnPath(path_env, name)) {
            return .{ .exe = name, .kind = hostKindFromName(name) };
        }
    }

    return null;
}

pub fn hostKindFromName(name: []const u8) HostKind {
    if (std.mem.eql(u8, name, "foot")) return .foot;
    if (std.mem.eql(u8, name, "kitty")) return .kitty;
    if (std.mem.eql(u8, name, "alacritty")) return .alacritty;
    if (std.mem.eql(u8, name, "wezterm")) return .wezterm;
    if (std.mem.eql(u8, name, "ghostty")) return .ghostty;
    if (std.mem.eql(u8, name, "konsole")) return .konsole;
    if (std.mem.eql(u8, name, "gnome-terminal")) return .gnome_terminal;
    if (std.mem.eql(u8, name, "ptyxis")) return .ptyxis;
    if (std.mem.eql(u8, name, "xfce4-terminal")) return .xfce4_terminal;
    if (std.mem.eql(u8, name, "xterm")) return .xterm;
    return .generic;
}

/// Maximum argv length — foot (borderless) is the largest at ~10 prefix tokens
/// plus a 15-token tail (25 total); 32 gives safe headroom.
pub const MAX_ARGV = 32;

/// Assemble the full launch argv into `out[0..N]` and return the live slice.
/// All string arguments must have lifetimes at least as long as `out`.
/// `tail` is the terminal-independent suffix: "env" VARS... exe_path "--tui".
///
/// `borderless` requests a window with no decorations / title bar (default behaviour).
/// It is honoured only for terminals that expose a CLI flag for it (foot, kitty,
/// alacritty, ghostty, wezterm); gnome-terminal, ptyxis, konsole and xterm have no
/// such flag, so the request is silently ignored for them. This is unrelated to the
/// in-TUI `--border` / `EMOJIG_BORDER` colored row.
///
/// NOTE: Cell-precise window sizing is foot-only. Other terminals receive the
/// `env EMOJIG_RESIZE_MODE=altscreen` tail and adapt via altscreen mode.
pub fn buildGuiArgv(
    out: *[MAX_ARGV][]const u8,
    kind: HostKind,
    term: []const u8,
    borderless: bool,
    size_arg: []const u8,
    bg_arg: []const u8,
    fg_arg: []const u8,
    border_color_arg: []const u8,
    font_arg: []const u8,
    tail: []const []const u8,
) []const []const u8 {
    var n: usize = 0;
    switch (kind) {
        .foot => {
            out[n] = term;
            n += 1;
            out[n] = "--app-id=emojig-picker";
            n += 1;
            out[n] = size_arg;
            n += 1;
            out[n] = font_arg;
            n += 1;
            out[n] = "--override=cursor.blink=yes";
            n += 1;
            out[n] = "--override=scrollback.lines=0";
            n += 1;
            out[n] = "--override=pad=0x4";
            n += 1;
            out[n] = "--override=csd.preferred=none";
            n += 1;
            if (borderless) {
                // Disable client-side decorations (no title bar),
                // but request CSD with a 1px border so drop shadows are drawn.
                out[n] = "--override=csd.size=0";
                n += 1;
                out[n] = "--override=csd.preferred=client";
                n += 1;
                out[n] = "--override=csd.border-width=1";
                n += 1;
                if (border_color_arg.len > 0) {
                    out[n] = border_color_arg;
                    n += 1;
                }
            }
            if (bg_arg.len > 0) {
                out[n] = bg_arg;
                n += 1;
            }
            if (fg_arg.len > 0) {
                out[n] = fg_arg;
                n += 1;
            }
            // foot runs the command as plain positional args (no -e)
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .kitty => {
            out[n] = term;
            n += 1;
            out[n] = "--class";
            n += 1;
            out[n] = "emojig-picker";
            n += 1;
            if (borderless) {
                out[n] = "-o";
                n += 1;
                out[n] = "hide_window_decorations=titlebar-only";
                n += 1;
            }
            out[n] = "-e";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .alacritty => {
            out[n] = term;
            n += 1;
            out[n] = "--class";
            n += 1;
            out[n] = "emojig-picker";
            n += 1;
            if (borderless) {
                out[n] = "-o";
                n += 1;
                out[n] = "window.decorations=None";
                n += 1;
            }
            out[n] = "-e";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .wezterm => {
            out[n] = term;
            n += 1;
            out[n] = "start";
            n += 1;
            out[n] = "--class";
            n += 1;
            out[n] = "emojig-picker";
            n += 1;
            if (borderless) {
                out[n] = "--config";
                n += 1;
                out[n] = "window_decorations=\"RESIZE\"";
                n += 1;
            }
            out[n] = "--";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .ghostty => {
            out[n] = term;
            n += 1;
            out[n] = "--class=emojig-picker";
            n += 1;
            if (borderless) {
                out[n] = "--window-decoration=false";
                n += 1;
            }
            out[n] = "-e";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .konsole => {
            // konsole has no CLI flag to disable window decorations.
            out[n] = term;
            n += 1;
            out[n] = "-e";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .gnome_terminal => {
            // gnome-terminal (GTK CSD) has no CLI flag to disable decorations.
            out[n] = term;
            n += 1;
            out[n] = "--";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .ptyxis => {
            // ptyxis (GTK4/libadwaita) has no CLI flag to disable decorations.
            out[n] = term;
            n += 1;
            out[n] = "--";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .xfce4_terminal => {
            out[n] = term;
            n += 1;
            out[n] = "-x";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .xterm => {
            // xterm decorations are WM-controlled; no CLI borderless flag.
            out[n] = term;
            n += 1;
            out[n] = "-class";
            n += 1;
            out[n] = "emojig";
            n += 1;
            out[n] = "-e";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
        .generic => {
            // Generic fallback: <term> -e <tail>
            out[n] = term;
            n += 1;
            out[n] = "-e";
            n += 1;
            for (tail) |s| {
                out[n] = s;
                n += 1;
            }
        },
    }
    return out[0..n];
}

/// Strip leading '#' and expand 3-char CSS shorthand to 6-digit RGB.
/// "#abc" → "aabbcc", "#aabbcc" → "aabbcc", "" / no '#' → "".
/// `buf` must be at least 8 bytes. Returns the bare hex slice (no '#').
fn expandHex(raw: []const u8, buf: *[8]u8) []const u8 {
    const hex = if (raw.len > 0 and raw[0] == '#') raw[1..] else raw;
    if (hex.len == 3) {
        buf[0] = hex[0];
        buf[1] = hex[0];
        buf[2] = hex[1];
        buf[3] = hex[1];
        buf[4] = hex[2];
        buf[5] = hex[2];
        return buf[0..6];
    }
    if (hex.len == 6 or hex.len == 8) return hex;
    return "";
}

pub fn spawnGuiWindow(
    init: std.process.Init,
    exe_path: []const u8,
    theme: Theme,
    border: bool,
    safe: bool,
    debug: bool,
    wait: bool,
    borderless: bool,
    cols_val: usize,
    rows_val: usize,
    compact: bool,
    spec: *const spec_mod.Spec,
    show_switcher: bool,
    font_size: usize,
) !void {
    const io = init.io;
    const theme_str: []const u8 = switch (theme) {
        .dark => "dark",
        .light => "light",
        .system => "system",
    };

    // GUI window colors come from spec/theme.json (foot wants bare hex, so we
    // strip the leading '#'). `system` falls back to the dark palette here.
    // Foot requires full 6-digit RGB (rrggbb) or 8-digit ARGB — 3-char shorthand
    // like "#ccc" must be expanded to "#cccccc" before stripping.
    const gui_pal = if (theme == .light) spec.theme.themes.light else spec.theme.themes.dark;
    const foot_bg_raw = gui_pal.terminal_bg2 orelse gui_pal.terminal_bg;
    var foot_bg_exp: [8]u8 = undefined;
    var foot_fg_exp: [8]u8 = undefined;
    var foot_bd_exp: [8]u8 = undefined;
    const foot_bg = expandHex(foot_bg_raw orelse "", &foot_bg_exp);
    const foot_fg = expandHex(gui_pal.terminal_fg orelse "", &foot_fg_exp);
    const foot_border = expandHex(gui_pal.terminal_border orelse "", &foot_bd_exp);

    // GUI grid dimensions are resolved by the caller (config → spec) and passed
    // in so the foot window matches the picker's unified grid size exactly.
    // Content width follows the column count (one trailing scrollbar gutter
    // column), mirroring the in-picker `content_width = cols*cell_w + 1`.
    const cell_w = if (compact) @as(usize, 3) else 4;
    const width_val = cols_val * cell_w + (if (compact) @as(usize, 2) else 1);

    // Derive the window height from the GUI grid rows.
    // GUI always shows the switcher, which adds 1 extra hline row between grid and switcher.
    const gui_content_rows: usize = rows_val + spec.layout.layout_overhead + 1;
    var final_h = if (border) gui_content_rows + 2 else gui_content_rows;
    if (debug) final_h += 2;

    var size_buf: [64]u8 = undefined;
    const size_arg = try std.fmt.bufPrint(&size_buf, "--window-size-chars={d}x{d}", .{ width_val + 1, final_h });

    var bg_buf: [64]u8 = undefined;
    const bg_arg = if (foot_bg.len > 0)
        try std.fmt.bufPrint(&bg_buf, "--override=colors.background={s}", .{foot_bg})
    else
        "";

    var fg_buf: [64]u8 = undefined;
    const fg_arg = if (foot_fg.len > 0)
        try std.fmt.bufPrint(&fg_buf, "--override=colors.foreground={s}", .{foot_fg})
    else
        "";

    var border_color_buf: [64]u8 = undefined;
    const border_color_arg = if (foot_border.len > 0)
        try std.fmt.bufPrint(&border_color_buf, "--override=csd.border-color={s}", .{foot_border})
    else
        "";

    var env_w: [64]u8 = undefined;
    const env_w_arg = try std.fmt.bufPrint(&env_w, "EMOJIG_WIDTH={d}", .{width_val});

    var env_h: [64]u8 = undefined;
    const env_h_arg = try std.fmt.bufPrint(&env_h, "EMOJIG_HEIGHT={d}", .{gui_content_rows});

    var env_theme: [64]u8 = undefined;
    const env_theme_arg = try std.fmt.bufPrint(&env_theme, "EMOJIG_THEME={s}", .{theme_str});

    var env_border: [64]u8 = undefined;
    const env_border_arg = try std.fmt.bufPrint(&env_border, "EMOJIG_BORDER={s}", .{if (border) "1" else "0"});

    var env_safe: [64]u8 = undefined;
    const env_safe_arg = try std.fmt.bufPrint(&env_safe, "EMOJIG_SAFE={s}", .{if (safe) "1" else "0"});

    var env_debug: [64]u8 = undefined;
    const env_debug_arg = try std.fmt.bufPrint(&env_debug, "EMOJIG_DEBUG={s}", .{if (debug) "1" else "0"});

    const timeout_val = init.environ_map.get("EMOJIG_PICKER_TIMEOUT") orelse "60";

    var env_timeout: [64]u8 = undefined;
    const env_timeout_arg = try std.fmt.bufPrint(&env_timeout, "EMOJIG_PICKER_TIMEOUT={s}", .{timeout_val});

    var font_buf: [64]u8 = undefined;
    const font_arg = try std.fmt.bufPrint(&font_buf, "--override=font=monospace:size={d}", .{font_size});

    var env_cols: [64]u8 = undefined;
    const env_cols_arg = try std.fmt.bufPrint(&env_cols, "EMOJIG_COLS={d}", .{cols_val});

    var env_rows: [64]u8 = undefined;
    const env_rows_arg = try std.fmt.bufPrint(&env_rows, "EMOJIG_ROWS={d}", .{rows_val});

    // Propagate the GUI exit-preview default from spec/layout.json → animation.exit_preview_gui.
    // The child process (running --tui inside the spawned window) will see this env var and
    // use it as its override, bypassing the TUI default (animation.exit_preview_tui).
    var env_exit_preview: [64]u8 = undefined;
    const env_exit_preview_arg = try std.fmt.bufPrint(
        &env_exit_preview,
        "EMOJIG_EXIT_PREVIEW={s}",
        .{if (spec.layout.animation.exit_preview_gui) "1" else "0"},
    );

    const switcher_arg = if (show_switcher) "EMOJIG_SHOW_SWITCHER=1" else "EMOJIG_SHOW_SWITCHER=0";

    var env_compact: [64]u8 = undefined;
    const env_compact_arg = try std.fmt.bufPrint(&env_compact, "EMOJIG_COMPACT={s}", .{if (compact) "1" else "0"});

    // Terminal-independent tail: env VARS... exe_path --tui
    const tail = [_][]const u8{
        "env",
        env_w_arg,
        env_h_arg,
        env_theme_arg,
        env_border_arg,
        env_safe_arg,
        env_debug_arg,
        env_timeout_arg,
        "EMOJIG_RESIZE_MODE=altscreen",
        env_cols_arg,
        env_rows_arg,
        env_exit_preview_arg,
        switcher_arg,
        "EMOJIG_GUI_SPAWNED=1",
        env_compact_arg,
        exe_path,
        "--tui",
    };

    // Select terminal host
    const sel = selectTerminalHost(init.environ_map) orelse {
        try writeAll(std.posix.STDERR_FILENO, "Error: no terminal emulator found. Set EMOJIG_TERMINAL to your terminal executable.\n");
        std.process.exit(1);
    };

    var argv_out: [MAX_ARGV][]const u8 = undefined;
    const argv = buildGuiArgv(&argv_out, sel.kind, sel.exe, borderless, size_arg, bg_arg, fg_arg, border_color_arg, font_arg, &tail);

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

fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, needle)) return true;
    }
    return false;
}

test "buildGuiArgv: foot borderless adds csd overrides" {
    var out: [MAX_ARGV][]const u8 = undefined;
    const tail = [_][]const u8{ "env", "EMOJIG_WIDTH=25", "EMOJIG_RESIZE_MODE=altscreen", "/usr/bin/emojig", "--tui" };
    const argv = buildGuiArgv(&out, .foot, "foot", true, "--window-size-chars=27x10", "--override=colors.background=1c1c1c", "--override=colors.foreground=a8a8a8", "--override=csd.border-color=3c3c3c", "--override=font=monospace:size=14", &tail);
    try std.testing.expectEqualStrings("foot", argv[0]);
    try std.testing.expectEqualStrings("--app-id=emojig-picker", argv[1]);
    try std.testing.expectEqualStrings("--window-size-chars=27x10", argv[2]);
    try std.testing.expect(argvContains(argv, "--override=csd.size=0"));
    try std.testing.expect(argvContains(argv, "--override=csd.preferred=client"));
    try std.testing.expect(argvContains(argv, "--override=csd.border-width=1"));
    try std.testing.expect(argvContains(argv, "--override=csd.border-color=3c3c3c"));
    try std.testing.expectEqualStrings("--tui", argv[argv.len - 1]);
}

test "buildGuiArgv: foot non-borderless omits csd overrides" {
    var out: [MAX_ARGV][]const u8 = undefined;
    const tail = [_][]const u8{ "env", "/usr/bin/emojig", "--tui" };
    const argv = buildGuiArgv(&out, .foot, "foot", false, "--window-size-chars=27x10", "bg", "fg", "border", "--override=font=monospace:size=14", &tail);
    try std.testing.expect(!argvContains(argv, "--override=csd.size=0"));
    try std.testing.expect(!argvContains(argv, "--override=csd.preferred=client"));
}

test "buildGuiArgv: kitty borderless toggles hide_window_decorations" {
    var on_out: [MAX_ARGV][]const u8 = undefined;
    var off_out: [MAX_ARGV][]const u8 = undefined;
    const tail = [_][]const u8{ "env", "/usr/bin/emojig", "--tui" };
    const on = buildGuiArgv(&on_out, .kitty, "kitty", true, "", "", "", "", "", &tail);
    try std.testing.expect(argvContains(on, "hide_window_decorations=titlebar-only"));
    const off = buildGuiArgv(&off_out, .kitty, "kitty", false, "", "", "", "", "", &tail);
    try std.testing.expect(!argvContains(off, "hide_window_decorations=titlebar-only"));
    try std.testing.expectEqualStrings("kitty", off[0]);
    try std.testing.expectEqualStrings("-e", off[3]);
}

test "buildGuiArgv: xterm argv starts with expected tokens" {
    var out: [MAX_ARGV][]const u8 = undefined;
    const tail = [_][]const u8{ "env", "EMOJIG_WIDTH=25", "EMOJIG_RESIZE_MODE=altscreen", "/usr/bin/emojig", "--tui" };
    const argv = buildGuiArgv(&out, .xterm, "xterm", true, "", "", "", "", "", &tail);
    try std.testing.expect(argv.len >= 2);
    try std.testing.expectEqualStrings("xterm", argv[0]);
    try std.testing.expectEqualStrings("-class", argv[1]);
    try std.testing.expectEqualStrings("emojig", argv[2]);
    try std.testing.expectEqualStrings("-e", argv[3]);
    try std.testing.expectEqualStrings("env", argv[4]);
    try std.testing.expectEqualStrings("--tui", argv[argv.len - 1]);
}

test "buildGuiArgv: ptyxis uses -- separator" {
    var out: [MAX_ARGV][]const u8 = undefined;
    const tail = [_][]const u8{ "env", "/bin/true", "--tui" };
    const argv = buildGuiArgv(&out, .ptyxis, "ptyxis", true, "", "", "", "", "", &tail);
    try std.testing.expectEqualStrings("ptyxis", argv[0]);
    try std.testing.expectEqualStrings("--", argv[1]);
    try std.testing.expectEqualStrings("env", argv[2]);
}

test "whichOnPath finds and rejects" {
    const path = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
    try std.testing.expect(whichOnPath(path, "sh"));
    try std.testing.expect(!whichOnPath(path, "zzz_no_such_binary_zzz"));
}

test "buildGuiArgv: generic argv uses -e" {
    var out: [MAX_ARGV][]const u8 = undefined;
    const tail = [_][]const u8{ "env", "EMOJIG_RESIZE_MODE=altscreen", "/bin/true", "--tui" };
    const argv = buildGuiArgv(&out, .generic, "/bin/true", true, "", "", "", "", "", &tail);
    try std.testing.expectEqualStrings("/bin/true", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    try std.testing.expectEqualStrings("env", argv[2]);
    try std.testing.expectEqualStrings("--tui", argv[argv.len - 1]);
}
