// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const build_options = @import("build_options");
const defaults = @import("defaults.zig");
const resize = @import("resize.zig");
const term = @import("term.zig");
const config = @import("config.zig");
const spec_mod = @import("spec.zig");

pub const Theme = term.Theme;
pub const ScrollbarStyle = config.ScrollbarStyle;

pub const ParsedArgs = struct {
    tui: bool = false,
    gui: bool = false,
    wait: bool = false,
    install: bool = false,
    rc: ?[]const u8 = null,
    list: bool = false,
    theme: ?Theme = null,
    width: ?usize = null,
    height: ?usize = null,
    border: ?bool = null,
    safe: bool = false,
    debug: bool = false,
    alt_screen: bool = false,
    simple: bool = false,
    completion: bool = false,
    completion_shell: ?[]const u8 = null,
    key: ?[]const u8 = null,
    borderless: ?bool = null,
    title_size: usize = 0,
    lang: ?[]const u8 = null,
    show_switcher: ?bool = null,
};

pub const Runtime = struct {
    opt_tui: bool,
    opt_gui: bool,
    opt_wait: bool,
    opt_install: bool,
    opt_rc: ?[]const u8,
    opt_list: bool,
    opt_theme: ?Theme,
    opt_width: ?usize,
    opt_height: ?usize,
    opt_border: ?bool,
    opt_safe: bool,
    opt_debug: bool,
    opt_alt_screen: bool,
    opt_simple: bool,
    opt_completion: bool,
    opt_completion_shell: ?[]const u8,
    opt_key: ?[]const u8,
    opt_borderless: bool,
    opt_title_size: usize,
    opt_lang: ?[]const u8,
    opt_show_switcher: ?bool,
    lang: ?[]const u8,
    cfg: config.Config,
    env_scrollbar: ?ScrollbarStyle,
    height_override: ?usize,
    final_theme: Theme,
    base_cols: usize,
    base_rows: usize,
    final_compact: bool,
    final_width: usize,
    final_border: bool,
    final_show_switcher_pref: ?bool,
    final_safe: bool,
    final_debug: bool,
    final_alt_screen: bool,
    final_simple: bool,
    has_gui_session: bool,
    can_use_tty: bool,
    is_linux_vt: bool,
    run_gui: bool,
    resize_mode: resize.Mode,
};

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    term.writeAll(fd, bytes) catch {};
}

fn fail(fd: std.posix.fd_t, msg: []const u8) noreturn {
    writeAll(fd, msg);
    std.process.exit(1);
}

fn exitOk(fd: std.posix.fd_t, msg: []const u8) noreturn {
    writeAll(fd, msg);
    std.process.exit(0);
}

const BoolFlagParse = enum {
    no_match,
    invalid,
    true_value,
    false_value,
};

fn parseBorderlessFlag(arg: []const u8) BoolFlagParse {
    if (std.mem.eql(u8, arg, "--borderless")) return .true_value;
    if (std.mem.eql(u8, arg, "--no-borderless")) return .false_value;
    if (std.mem.eql(u8, arg, "--decorated") or std.mem.eql(u8, arg, "--window-decorations")) return .false_value;
    if (std.mem.startsWith(u8, arg, "--borderless=")) {
        const v = arg["--borderless=".len..];
        if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return .true_value;
        if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return .false_value;
        return .invalid;
    }
    return .no_match;
}

pub fn parseArgs(init: std.process.Init) ParsedArgs {
    var parsed = ParsedArgs{};
    var args_it = init.minimal.args.iterate();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tui")) {
            parsed.tui = true;
        } else if (std.mem.eql(u8, arg, "--install")) {
            parsed.install = true;
        } else if (std.mem.eql(u8, arg, "--rc")) {
            if (args_it.next()) |v| {
                parsed.rc = v;
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --rc requires a filename (e.g. .userrc).\n");
            }
        } else if (std.mem.startsWith(u8, arg, "--rc=")) {
            parsed.rc = arg["--rc=".len..];
        } else if (std.mem.eql(u8, arg, "--list")) {
            parsed.list = true;
        } else if (std.mem.eql(u8, arg, "--gui")) {
            parsed.gui = true;
        } else if (std.mem.eql(u8, arg, "--wait")) {
            parsed.wait = true;
        } else if (std.mem.eql(u8, arg, "--safe")) {
            parsed.safe = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            parsed.debug = true;
        } else if (std.mem.eql(u8, arg, "--alt-screen")) {
            parsed.alt_screen = true;
        } else if (std.mem.eql(u8, arg, "--simple")) {
            parsed.simple = true;
        } else if (std.mem.eql(u8, arg, "--completion")) {
            parsed.completion = true;
        } else if (std.mem.startsWith(u8, arg, "--completion=")) {
            parsed.completion = true;
            const v = arg["--completion=".len..];
            if (std.mem.eql(u8, v, "zsh") or std.mem.eql(u8, v, "bash") or std.mem.eql(u8, v, "fish") or std.mem.eql(u8, v, "sh")) {
                parsed.completion_shell = v;
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --completion= accepts sh, zsh, bash, or fish.\n");
            }
        } else if (std.mem.eql(u8, arg, "--key")) {
            if (args_it.next()) |v| {
                parsed.key = v;
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --key requires an argument (e.g. '^E').\n");
            }
        } else if (std.mem.eql(u8, arg, "--theme")) {
            if (args_it.next()) |v| {
                if (std.mem.eql(u8, v, "light")) parsed.theme = .light else if (std.mem.eql(u8, v, "dark")) parsed.theme = .dark else if (std.mem.eql(u8, v, "system")) parsed.theme = .system else {
                    fail(std.posix.STDERR_FILENO, "Error: invalid theme. Supported values are 'dark', 'light', or 'system'.\n");
                }
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --theme requires an argument ('dark', 'light', or 'system').\n");
            }
        } else if (std.mem.eql(u8, arg, "--width")) {
            if (args_it.next()) |v| {
                parsed.width = std.fmt.parseInt(usize, v, 10) catch fail(std.posix.STDERR_FILENO, "Error: invalid width. Must be an integer.\n");
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --width requires an argument.\n");
            }
        } else if (std.mem.eql(u8, arg, "--height")) {
            if (args_it.next()) |v| {
                parsed.height = std.fmt.parseInt(usize, v, 10) catch fail(std.posix.STDERR_FILENO, "Error: invalid height. Must be an integer.\n");
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --height requires an argument.\n");
            }
        } else if (std.mem.eql(u8, arg, "--title-size")) {
            if (args_it.next()) |v| {
                parsed.title_size = std.fmt.parseInt(usize, v, 10) catch fail(std.posix.STDERR_FILENO, "Error: invalid title-size. Must be an integer.\n");
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --title-size requires an argument.\n");
            }
        } else if (std.mem.startsWith(u8, arg, "--title-size=")) {
            parsed.title_size = std.fmt.parseInt(usize, arg["--title-size=".len..], 10) catch fail(std.posix.STDERR_FILENO, "Error: invalid title-size. Must be an integer.\n");
        } else if (std.mem.eql(u8, arg, "--border")) {
            if (args_it.next()) |v| {
                if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
                    parsed.border = true;
                } else if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) {
                    parsed.border = false;
                } else {
                    fail(std.posix.STDERR_FILENO, "Error: invalid border. Must be 1/0 or true/false.\n");
                }
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --border requires an argument.\n");
            }
        } else if (std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "-l")) {
            if (args_it.next()) |v| {
                parsed.lang = v;
            } else {
                fail(std.posix.STDERR_FILENO, "Error: --lang/-l requires an argument (e.g. 'de', 'es').\n");
            }
        } else if (std.mem.startsWith(u8, arg, "--lang=")) {
            parsed.lang = arg["--lang=".len..];
        } else if (std.mem.eql(u8, arg, "--show-switcher")) {
            parsed.show_switcher = true;
        } else if (std.mem.eql(u8, arg, "--no-show-switcher")) {
            parsed.show_switcher = false;
        } else if (std.mem.startsWith(u8, arg, "--show-switcher=")) {
            const v = arg["--show-switcher=".len..];
            parsed.show_switcher = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            exitOk(std.posix.STDOUT_FILENO, "emojig " ++ build_options.version ++ "\n");
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            exitOk(std.posix.STDOUT_FILENO, "Emojig - Premium Zero-Allocation Emoji Picker\n\n" ++
                "Usage: emojig [options]\n\n" ++
                "Options:\n" ++
                "  --theme [dark|light|system]  Set the UI theme\n" ++
                "  --width [number]             Set the width of the picker\n" ++
                "  --height [number]            Set the height of the picker\n" ++
                "  --border [1|0|true|false]    Enable or disable the border\n" ++
                "  --lang, -l [code]            Set UI language (de, es, fr, it, pt, pl, ru, uk, nl, tr)\n" ++
                "  --safe                       Safe mode: strip U+FE0F variation selector from screen rendering too\n" ++
                "  --debug                      Debug mode: show terminal dimensions at bottom\n" ++
                "  --tui                        Force local interactive TUI session\n" ++
                "  --gui                        Force floating window (uses $EMOJIG_TERMINAL, else foot/kitty/ghostty/ptyxis/...)\n" ++
                "  --borderless[=true|false]    Spawn the GUI terminal without window decorations (default: true)\n" ++
                "  --decorated                  Spawn the GUI terminal with its title bar/window decorations\n" ++
                "  --window-decorations         Alias for --decorated\n" ++
                "  --title-size N               Title bar height in pixels (default: auto from system font)\n" ++
                "  --alt-screen                 Use alternate screen buffer (full-screen TUI mode)\n" ++
                "  --show-switcher[=true|false] Show horizontal category switcher bar (implied by --gui)\n" ++
                "  --simple                     Simple fzf/sk-like list picker (use with --height)\n" ++
                "  --wait                       Wait for spawned window to close (with --gui)\n" ++
                "  --completion[=sh|zsh|bash|fish]  Print shell integration to stdout (auto-detects $SHELL)\n" ++
                "  --key KEY                    Key binding to embed in --completion output (e.g. '^E')\n" ++
                "  --install                    Install shell integration and source it in your shell rc file\n" ++
                "  --rc FILE                    RC file for --install (e.g. .userrc); default: .zshrc/.bashrc/config.fish\n" ++
                "  --list                       Print all emojis as 'emoji<TAB>name' for rofi/wofi/dmenu\n" ++
                "  -v, --version                Show version and exit\n" ++
                "  -h, --help                   Show this help message\n");
        } else {
            switch (parseBorderlessFlag(arg)) {
                .true_value => parsed.borderless = true,
                .false_value => parsed.borderless = false,
                .invalid => fail(std.posix.STDERR_FILENO, "Error: invalid --borderless value. Use true/false or 1/0.\n"),
                .no_match => {
                    writeAll(std.posix.STDERR_FILENO, "Error: unknown argument '");
                    writeAll(std.posix.STDERR_FILENO, arg);
                    fail(std.posix.STDERR_FILENO, "'. Use -h or --help for usage.\n");
                },
            }
        }
    }

    return parsed;
}

test "parseBorderlessFlag handles decorated aliases" {
    try std.testing.expectEqual(BoolFlagParse.false_value, parseBorderlessFlag("--decorated"));
    try std.testing.expectEqual(BoolFlagParse.false_value, parseBorderlessFlag("--window-decorations"));
    try std.testing.expectEqual(BoolFlagParse.false_value, parseBorderlessFlag("--no-borderless"));
    try std.testing.expectEqual(BoolFlagParse.true_value, parseBorderlessFlag("--borderless"));
    try std.testing.expectEqual(BoolFlagParse.true_value, parseBorderlessFlag("--borderless=1"));
    try std.testing.expectEqual(BoolFlagParse.false_value, parseBorderlessFlag("--borderless=false"));
    try std.testing.expectEqual(BoolFlagParse.invalid, parseBorderlessFlag("--borderless=maybe"));
    try std.testing.expectEqual(BoolFlagParse.no_match, parseBorderlessFlag("--gui"));
}

pub fn resolveLanguage(environ_map: anytype, opt_lang: ?[]const u8) ?[]const u8 {
    return opt_lang orelse blk: {
        if (environ_map.get("EMOJIG_LANG")) |v| break :blk v;
        if (environ_map.get("LANG")) |v| break :blk v;
        if (environ_map.get("LC_ALL")) |v| break :blk v;
        if (environ_map.get("LC_MESSAGES")) |v| break :blk v;
        break :blk null;
    };
}

fn parseTheme(v: []const u8) ?Theme {
    if (std.mem.eql(u8, v, "light")) return .light;
    if (std.mem.eql(u8, v, "dark")) return .dark;
    if (std.mem.eql(u8, v, "system")) return .system;
    return null;
}

fn parseScrollbar(v: []const u8) ?ScrollbarStyle {
    if (std.mem.eql(u8, v, "bar")) return .bar;
    if (std.mem.eql(u8, v, "expand")) return .expand;
    return null;
}

fn parseBool(v: []const u8) bool {
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

pub fn resolveRuntime(init: std.process.Init, arena: std.mem.Allocator, spec: *const spec_mod.Spec, parsed: ParsedArgs, lang: ?[]const u8) Runtime {
    const cfg = config.loadConfig(arena, init.io);

    const env_theme: ?Theme = blk: {
        if (init.environ_map.get("EMOJIG_THEME")) |env_val| {
            if (parseTheme(env_val)) |t| break :blk t;
        }
        break :blk null;
    };

    const env_scrollbar: ?ScrollbarStyle = blk: {
        if (init.environ_map.get("EMOJIG_SCROLLBAR")) |env_val| {
            if (parseScrollbar(env_val)) |s| break :blk s;
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
            break :blk parseBool(env_val);
        }
        break :blk null;
    };

    const env_safe: ?bool = blk: {
        if (init.environ_map.get("EMOJIG_SAFE")) |env_val| {
            break :blk parseBool(env_val);
        }
        break :blk null;
    };

    const env_show_switcher: ?bool = blk: {
        if (init.environ_map.get("EMOJIG_SHOW_SWITCHER")) |env_val| {
            break :blk parseBool(env_val);
        }
        break :blk null;
    };

    const env_debug: ?bool = blk: {
        if (init.environ_map.get("EMOJIG_DEBUG")) |env_val| {
            break :blk parseBool(env_val);
        }
        break :blk null;
    };

    const resize_mode: resize.Mode = blk: {
        if (parsed.alt_screen) break :blk .altscreen;
        if (init.environ_map.get("EMOJIG_ALT_SCREEN")) |v| {
            if (parseBool(v)) break :blk resize.Mode.altscreen;
        }
        break :blk resize.parseMode(init.environ_map.get("EMOJIG_RESIZE_MODE"));
    };

    const height_override: ?usize = parsed.height orelse env_height orelse cfg.height;
    const final_theme = parsed.theme orelse env_theme orelse cfg.theme orelse .dark;

    const base_cols: usize = blk: {
        const raw: usize = blk_raw: {
            if (init.environ_map.get("EMOJIG_COLS")) |v| {
                if (std.fmt.parseInt(usize, v, 10)) |n| break :blk_raw n else |_| {}
            }
            if (cfg.cols) |c| break :blk_raw c;
            break :blk_raw spec.layout.tui.cols;
        };
        break :blk @max(defaults.MIN_COLS, @min(raw, defaults.MAX_COLS));
    };

    const base_rows: usize = blk: {
        const raw: usize = blk_raw: {
            if (init.environ_map.get("EMOJIG_ROWS")) |v| {
                if (std.fmt.parseInt(usize, v, 10)) |n| break :blk_raw n else |_| {}
            }
            if (height_override) |h| break :blk_raw if (h > spec.layout.layout_overhead) h - spec.layout.layout_overhead else 0;
            if (cfg.rows) |r| break :blk_raw r;
            break :blk_raw spec.layout.tui.rows;
        };
        break :blk @max(defaults.MIN_ROWS, @min(raw, defaults.MAX_ROWS));
    };

    const env_compact: ?bool = blk: {
        if (init.environ_map.get("EMOJIG_COMPACT")) |env_val| {
            break :blk parseBool(env_val);
        }
        break :blk null;
    };
    const final_compact = env_compact orelse cfg.compact orelse false;

    const final_width = parsed.width orelse env_width orelse cfg.width orelse (base_cols * (if (final_compact) @as(usize, 3) else 4) + (if (final_compact) @as(usize, 2) else 1));
    const final_border = parsed.border orelse env_border orelse cfg.border orelse false;
    const final_show_switcher_pref: ?bool = parsed.show_switcher orelse env_show_switcher;
    const final_safe = parsed.safe or (env_safe orelse cfg.safe orelse false);
    const final_debug = parsed.debug or (env_debug orelse false);
    const final_alt_screen = (resize_mode == .altscreen);
    const final_simple = parsed.simple;

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
        const term_env = init.environ_map.get("TERM");
        break :blk term_env != null and std.mem.eql(u8, term_env.?, "linux");
    };

    if (is_linux_vt and !parsed.gui and !parsed.tui) {
        writeAll(
            std.posix.STDERR_FILENO,
            "emojig: Linux virtual console detected (TERM=linux).\n" ++
                "Emoji glyphs cannot render in the kernel console font.\n\n" ++
                "Please switch to a graphical terminal emulator (foot, alacritty, kitty, ...)\n" ++
                "or connect via SSH from a machine with a terminal emulator.\n\n",
        );
        std.process.exit(1);
    }

    var run_gui = false;
    if (parsed.tui) {
        if (!can_use_tty) {
            fail(std.posix.STDERR_FILENO, "Error: TUI requires an interactive terminal.\n");
        }
    } else if (parsed.gui) {
        if (!has_gui_session) {
            fail(std.posix.STDERR_FILENO, "Error: No graphical (GUI) session detected.\n");
        }
        run_gui = true;
    } else {
        if (can_use_tty) {} else if (has_gui_session) {
            run_gui = true;
        } else {
            fail(std.posix.STDERR_FILENO, "Error: TUI requires an interactive terminal and no GUI session was detected.\n");
        }
    }

    return .{
        .opt_tui = parsed.tui,
        .opt_gui = parsed.gui,
        .opt_wait = parsed.wait,
        .opt_install = parsed.install,
        .opt_rc = parsed.rc,
        .opt_list = parsed.list,
        .opt_theme = parsed.theme,
        .opt_width = parsed.width,
        .opt_height = parsed.height,
        .opt_border = parsed.border,
        .opt_safe = parsed.safe,
        .opt_debug = parsed.debug,
        .opt_alt_screen = parsed.alt_screen,
        .opt_simple = parsed.simple,
        .opt_completion = parsed.completion,
        .opt_completion_shell = parsed.completion_shell,
        .opt_key = parsed.key,
        .opt_borderless = parsed.borderless orelse (if (cfg.decorated) |d| !d else true),
        .opt_title_size = parsed.title_size,
        .opt_lang = parsed.lang,
        .opt_show_switcher = parsed.show_switcher,
        .lang = lang,
        .cfg = cfg,
        .env_scrollbar = env_scrollbar,
        .height_override = height_override,
        .final_theme = final_theme,
        .base_cols = base_cols,
        .base_rows = base_rows,
        .final_compact = final_compact,
        .final_width = final_width,
        .final_border = final_border,
        .final_show_switcher_pref = final_show_switcher_pref,
        .final_safe = final_safe,
        .final_debug = final_debug,
        .final_alt_screen = final_alt_screen,
        .final_simple = final_simple,
        .has_gui_session = has_gui_session,
        .can_use_tty = can_use_tty,
        .is_linux_vt = is_linux_vt,
        .run_gui = run_gui,
        .resize_mode = resize_mode,
    };
}
