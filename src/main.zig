// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const emojig = @import("emojig");
const build_options = @import("build_options");
const mru = emojig.mru;
const term_lib = @import("term.zig");
const resize = @import("resize.zig");
const host = @import("host.zig");
const defaults = @import("defaults.zig");
const spec_mod = @import("spec.zig");
const tui = @import("tui.zig");

const config = @import("config.zig");
const integration = @import("integration.zig");
const pid_lock = @import("pid_lock.zig");
const color = @import("color.zig");
const tui_draw = @import("tui_draw.zig");

// ---------------------------------------------------------------------------
// Namespaced Module Aliases & Forwarding Wrappers
// ---------------------------------------------------------------------------
const ScrollbarStyle = config.ScrollbarStyle;
const scrollbarThumb = tui_draw.scrollbarThumb;
const deleteAtCursor = tui_draw.deleteAtCursor;
const forwardDeleteAtCursor = tui_draw.forwardDeleteAtCursor;
const wordLeft = tui_draw.wordLeft;
const wordRight = tui_draw.wordRight;
const ringBell = tui_draw.ringBell;
const navSelect = tui_draw.navSelect;
const ansiDisplayWidth = tui_draw.ansiDisplayWidth;
const formatStatus = tui_draw.formatStatus;
const expandTemplate = tui_draw.expandTemplate;

const VarSubst = color.VarSubst;
const expandVars = color.expandVars;
const bgEscape = color.bgEscape;
const queryCursorRow = color.queryCursorRow;
const detectSystemTheme = color.detectSystemTheme;

inline fn effectivePalette(t: Theme, sys: Theme, dim: bool) Palette {
    return color.effectivePalette(&g_spec, t, sys, dim);
}
inline fn applyTerminalColors(stdout_fd: std.posix.fd_t, t: Theme, sys: Theme, alt_screen: bool) void {
    color.applyTerminalColors(&g_spec, stdout_fd, t, sys, alt_screen);
}

const loadConfig = config.loadConfig;
const saveKeyToConfig = config.saveKeyToConfig;
const saveThemeToConfig = config.saveThemeToConfig;
const saveUsizeToConfig = config.saveUsizeToConfig;
const saveDisabledCategories = config.saveDisabledCategories;
const finalizeGridTyping = config.finalizeGridTyping;
const applyGridDimClick = config.applyGridDimClick;
const typeGridDim = config.typeGridDim;
const stepGridDim = config.stepGridDim;
const cycleGridDim = config.cycleGridDim;
const clampGridDim = config.clampGridDim;

inline fn settingDefault(id: []const u8) []const u8 {
    return config.settingDefault(&g_spec, id);
}
inline fn settingDefaultBool(id: []const u8) bool {
    return config.settingDefaultBool(&g_spec, id);
}

const printCompletion = integration.printCompletion;
const detectShell = integration.detectShell;
const installShellIntegration = integration.installShellIntegration;
const runUpdate = integration.runUpdate;
const ensureDesktopIntegration = integration.ensureDesktopIntegration;

const toggleRunningPicker = pid_lock.toggleRunningPicker;
const writePickerPidFile = pid_lock.writePickerPidFile;
const removePickerPidFile = pid_lock.removePickerPidFile;

const ScreenState = enum {
    search,
    help,
    about,
    status,
    settings,
    categories,
};

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn getuid() c_uint;
extern fn getpid() c_int;
extern fn time(t: ?*c_long) c_long;
extern fn unlink(path: [*:0]const u8) c_int;

// The declarative UI spec (spec/*.json), parsed once at startup in main().
// Holds layout dims, theme palettes, key bindings, and UI strings. Lives in a
// process-lifetime arena; read-only after load.
var g_spec: spec_mod.Spec = undefined;
// (g_colors has been migrated to color.g_colors, g_wide_ambiguous to tui_draw.g_wide_ambiguous)

// Search dedup cache (see searchDedup). The "search key" is the query with
// outer spaces trimmed, plus the disabled-category mask — the only two inputs
// that change the result set. Re-running an identical search is skipped.
var g_search_key_buf: [defaults.MAX_QUERY_LEN]u8 = undefined;
var g_search_key_len: usize = 0;
var g_search_disabled: [32]bool = undefined;
var g_search_total: usize = 0;
var g_search_initialized: bool = false;

// ---------------------------------------------------------------------------
// Theme, Palette & Terminal Wrappers
// ---------------------------------------------------------------------------

const Theme = term_lib.Theme;
const Palette = term_lib.Palette;

/// Scrollbar rendering style, configurable via the Settings screen, the
/// `EMOJIG_SCROLLBAR` env var, or the `scrollbar_style=` config line.
///   .expand — proportional thumb whose height tracks the visible fraction
///   .bar    — fixed single-cell `▐` thumb that slides along the track
var global_orig_termios: ?std.posix.termios = null;
var global_tty_fd: std.posix.fd_t = std.posix.STDIN_FILENO;
var global_tui_start_row: ?i32 = null;
var global_tui_height: usize = 0;
var global_row_off: i32 = 0;
// True while the alt screen (?1049h) is active; selects RESTORE_ALT (which
// leaves the alt screen) over RESTORE (which must not touch ?1049 — see term.zig).
var global_alt_screen: bool = false;
// Set while this (GUI-spawned) picker owns the single-instance pidfile, so
// every exit path (defer, sigHandler, panic) can unlink it signal-safely.
var global_picker_pid_path_buf: [64]u8 = undefined;
var global_picker_pid_path: ?[:0]const u8 = null;

inline fn restoreSeq() []const u8 {
    return if (global_alt_screen) term_lib.RESTORE_ALT else term_lib.RESTORE;
}

inline fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    try term_lib.writeAll(fd, bytes);
}

inline fn logMemoryUsage() void {
    term_lib.logMemoryUsage();
}

inline fn themeIcon(t: Theme) []const u8 {
    return g_spec.iconFor(t);
}

inline fn getMonotonicMs() i64 {
    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1000000);
}

inline fn readStdin(fd: std.posix.fd_t, buf: []u8) !usize {
    const rc = std.posix.system.read(fd, buf.ptr, buf.len);
    const err = std.posix.errno(rc);
    if (err == .SUCCESS) {
        return @intCast(rc);
    } else if (err == .INTR) {
        return error.Interrupted;
    } else {
        return error.SystemResources;
    }
}

fn clearTuiRows(fd: std.posix.fd_t, height: usize, row_off: i32) void {
    if (height == 0) return;
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Jump to TUI row 0 absolutely when we have a valid start row (the robust path);
    // fall back to a relative move from the assumed search-bar position otherwise.
    if (global_tui_start_row) |start_row| {
        const abs = std.fmt.bufPrint(buf[pos..], "\x1b[{d};1H", .{start_row}) catch "";
        pos += abs.len;
    } else {
        const up_rows = @as(usize, @intCast(1 + row_off));
        const initial_up = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A\r", .{up_rows}) catch "";
        pos += initial_up.len;
    }

    var i: usize = 0;
    while (i < height) : (i += 1) {
        if (pos + 5 > buf.len) {
            _ = std.posix.system.write(fd, buf[0..pos].ptr, pos);
            pos = 0;
        }
        @memcpy(buf[pos..][0..5], "\r\x1b[2K");
        pos += 5;
        if (i < height - 1) {
            if (pos + 4 > buf.len) {
                _ = std.posix.system.write(fd, buf[0..pos].ptr, pos);
                pos = 0;
            }
            @memcpy(buf[pos..][0..4], "\x1b[B\r");
            pos += 4;
        }
    }
    // Return cursor to TUI row 0.
    if (global_tui_start_row) |start_row| {
        var abs_buf: [32]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "\x1b[{d};1H", .{start_row}) catch "";
        if (abs.len > 0) {
            if (pos + abs.len > buf.len) {
                _ = std.posix.system.write(fd, buf[0..pos].ptr, pos);
                pos = 0;
            }
            @memcpy(buf[pos..][0..abs.len], abs);
            pos += abs.len;
        }
    } else if (height > 1) {
        var up_seq_buf: [32]u8 = undefined;
        const up_seq = std.fmt.bufPrint(&up_seq_buf, "\x1b[{d}A\r", .{height - 1}) catch "";
        if (up_seq.len > 0) {
            if (pos + up_seq.len > buf.len) {
                _ = std.posix.system.write(fd, buf[0..pos].ptr, pos);
                pos = 0;
            }
            @memcpy(buf[pos..][0..up_seq.len], up_seq);
            pos += up_seq.len;
        }
    }
    if (pos > 0) {
        _ = std.posix.system.write(fd, buf[0..pos].ptr, pos);
    }
}

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    // V1 legacy handler — still wired to SIGINT/SIGTERM *before* the TUI block
    // sets up the self-pipe (e.g. when the spec-load or TTY-open fails).  Performs
    // minimal safe cleanup: restore termios only (no terminal I/O in signal context).
    term_lib.appendLog("exit via sigHandler sig={d}", .{@intFromEnum(sig)});
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(global_tty_fd, .NOW, &orig);
    }
    removePickerPidFile();
    logMemoryUsage();
    std.process.exit(1);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    term_lib.appendLog("panic: {s}", .{msg});
    clearTuiRows(global_tty_fd, global_tui_height, global_row_off);
    const seq = restoreSeq();
    _ = std.posix.system.write(global_tty_fd, seq.ptr, seq.len);
    if (global_orig_termios) |orig| {
        var drain_raw = orig;
        const sys = std.posix.system;
        drain_raw.lflag.ICANON = false;
        drain_raw.lflag.ECHO = false;
        drain_raw.cc[@intFromEnum(sys.V.MIN)] = 0;
        drain_raw.cc[@intFromEnum(sys.V.TIME)] = 0;
        _ = sys.tcsetattr(global_tty_fd, .NOW, &drain_raw);
        var drain_buf: [256]u8 = undefined;
        while (true) {
            const rc = sys.read(global_tty_fd, &drain_buf, drain_buf.len);
            if (rc <= 0) break;
        }
        _ = sys.tcsetattr(global_tty_fd, .NOW, &orig);
    }
    removePickerPidFile();
    logMemoryUsage();
    std.debug.defaultPanic(msg, ret_addr);
}

// ---------------------------------------------------------------------------
// GUI single-instance pidfile  (/tmp/emojig-picker-<uid>.pid)
//
// A GUI-spawned picker records its PID so that a second `emojig --gui`
// (e.g. the same desktop hotkey pressed again) toggles the open window
// closed instead of stacking another one. No daemon, no IPC — just one
// ---------------------------------------------------------------------------

const writeAllStdout = writeAll;

const StdoutWriter = struct {
    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        _ = self;
        try writeAllStdout(std.posix.STDOUT_FILENO, bytes);
    }
};

const BufferWriter = struct {
    buf: []u8,
    pos: *usize,

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        if (self.pos.* + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos.*..][0..bytes.len], bytes);
        self.pos.* += bytes.len;
    }
};

fn renderSettingRow(buf: []u8, idx: usize, is_sel: bool, shell_int: bool, key_bind: []const u8, key_bind_editing: bool, show_cats: bool, amb_chars: []const u8, theme: Theme, scrollbar: ScrollbarStyle, grid_cols: usize, grid_rows: usize, hover_left: bool, hover_right: bool, palette: term_lib.Palette) ![]const u8 {
    const sel_prefix = if (is_sel) "> " else "  ";
    const bg = if (is_sel) palette.selection_bg else palette.grid_bg;

    // The grid-size `‹`/`›` are clickable buttons: always bold so they read as
    // controls, and underlined while hovered (only on the selected/hovered row).
    const lq = if (is_sel and hover_left) "\x1b[1;4m\u{2039}\x1b[22;24m" else "\x1b[1m\u{2039}\x1b[22m";
    const rq = if (is_sel and hover_right) "\x1b[1;4m\u{203a}\x1b[22;24m" else "\x1b[1m\u{203a}\x1b[22m";

    switch (idx) {
        0 => {
            const cb = if (shell_int) "✔" else " ";
            const val_str = try std.fmt.bufPrint(buf[200..], "[{s}]", .{cb});
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  shell integration\x1b[0m", .{ bg, sel_prefix, padded });
        },
        1 => {
            const val_str = if (key_bind_editing)
                try std.fmt.bufPrint(buf[200..], "[{s}▋]", .{key_bind})
            else
                try std.fmt.bufPrint(buf[200..], "[{s}]", .{key_bind});
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  shell key binding\x1b[0m", .{ bg, sel_prefix, padded });
        },
        2 => {
            const cb = if (show_cats) "✔" else " ";
            const val_str = try std.fmt.bufPrint(buf[200..], "[{s}]", .{cb});
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  show all categories\x1b[0m", .{ bg, sel_prefix, padded });
        },
        3 => {
            const val_str = try std.fmt.bufPrint(buf[200..], "[{s}]", .{amb_chars});
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  ambiguous chars\x1b[0m", .{ bg, sel_prefix, padded });
        },
        4 => {
            const val_str = try std.fmt.bufPrint(buf[200..], "[{s}]", .{@tagName(theme)});
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  theme\x1b[0m", .{ bg, sel_prefix, padded });
        },
        5 => {
            const val_str = try std.fmt.bufPrint(buf[200..], "[{s}]", .{@tagName(scrollbar)});
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  scrollbar\x1b[0m", .{ bg, sel_prefix, padded });
        },
        6 => {
            const val_str = try std.fmt.bufPrint(buf[200..], "[{s} {d:>2} {s}]", .{ lq, grid_cols, rq });
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  grid width (cols)\x1b[0m", .{ bg, sel_prefix, padded });
        },
        7 => {
            const val_str = try std.fmt.bufPrint(buf[200..], "[{s} {d:>2} {s}]", .{ lq, grid_rows, rq });
            const w = ansiDisplayWidth(val_str);
            var spaces_buf: [10]u8 = undefined;
            const pad_count = if (w < 9) 9 - w else 0;
            for (0..pad_count) |j| spaces_buf[j] = ' ';
            const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
            return std.fmt.bufPrint(buf, " {s}{s}{s}  grid height (rows)\x1b[0m", .{ bg, sel_prefix, padded });
        },
        8 => {
            return std.fmt.bufPrint(buf, " {s}{s}[clear]    recent (MRU) history\x1b[0m", .{ bg, sel_prefix });
        },
        else => unreachable,
    }
}

/// Apply a non-text settings change (toggles and 2-state enums) without any
/// confirmation popup — the per-setting help modal (`?`/`h`/`F1`) explains what
/// each does. `forward` only matters for multi-state enums; 2-state toggles
/// flip regardless of direction. Theme (idx 4) is handled inline in the event
/// loop because it needs terminal-colour side effects.
fn toggleSetting(
    init: std.process.Init,
    idx: usize,
    shell_int: *bool,
    show_cats: *bool,
    amb_chars: *[]const u8,
    scrollbar: *ScrollbarStyle,
    home: []const u8,
    shell_name: []const u8,
) void {
    const io = init.io;
    switch (idx) {
        0 => {
            shell_int.* = !shell_int.*;
            saveKeyToConfig(io, "shell_integration", if (shell_int.*) "true" else "false");
            if (shell_int.*) {
                // Install the integration; the rc-sourcing reminder lives in the
                // settings help modal, so the write output is discarded here.
                var scratch: [1024]u8 = undefined;
                var pos: usize = 0;
                installShellIntegration(io, home, shell_name, null, BufferWriter{ .buf = &scratch, .pos = &pos });
            }
        },
        2 => {
            show_cats.* = !show_cats.*;
            saveKeyToConfig(io, "show_all_categories", if (show_cats.*) "true" else "false");
        },
        3 => {
            amb_chars.* = if (std.mem.eql(u8, amb_chars.*, "wide")) "narrow" else "wide";
            saveKeyToConfig(io, "ambiguous_chars", amb_chars.*);
            tui_draw.g_wide_ambiguous = !std.mem.eql(u8, amb_chars.*, "narrow");
        },
        5 => {
            scrollbar.* = switch (scrollbar.*) {
                .expand => .bar,
                .bar => .expand,
            };
            saveKeyToConfig(io, "scrollbar_style", @tagName(scrollbar.*));
        },
        else => {}, // 1 = text input, 4 = theme, 6/7 = grid dims — handled inline
    }
}

/// Cycle the theme enum forward (dark → light → system) or backward.
fn cycleTheme(t: Theme, forward: bool) Theme {
    if (forward) return switch (t) {
        .dark => .light,
        .light => .system,
        .system => .dark,
    };
    return switch (t) {
        .dark => .system,
        .system => .light,
        .light => .dark,
    };
}

/// Short, context-sensitive help for the selected settings row, shown as a
/// modal when the user presses `?`/`h`/`F1`. Lines stay narrow to fit the popup.
fn settingHelp(idx: usize) []const u8 {
    return switch (idx) {
        0 => "Shell integration\n\nAdds an `emojig` shell\nfunction. Enable, then\n`source` your shell rc.",
        1 => "Shell key binding\n\nEnter edits the keybind\n(e.g. C-e). source your\nshell rc afterwards.",
        2 => "Show all categories\n\non/off — list every\ncategory filter, or only\nmatching/used ones.",
        3 => "Ambiguous chars\n\nwide | narrow\nColumn width of chars\nlike \u{2192} \u{2248} \u{2605}.",
        4 => "Theme\n\ndark | light | system\nsystem follows the\nterminal background.",
        5 => "Scrollbar\n\nexpand | bar\nProportional thumb, or\na fixed single cell.",
        6 => "Grid width (cols)\n\n5\u{2013}16 columns. Type a\nnumber or use \u{2039} \u{203a}.\nApplies on next launch.",
        7 => "Grid height (rows)\n\n3\u{2013}16 rows. Type a\nnumber or use \u{2039} \u{203a}.\nApplies on next launch.",
        8 => "Clear MRU history\n\nEnter/Space clears the\nrecently-used list.\nCannot be undone.",
        else => "Settings\n\n\u{2191}\u{2193} select  \u{2190}\u{2192} change\n? help   Esc back",
    };
}

fn adjustScrollTop(selected_idx: usize, scroll_top: *usize, viewport_h: usize, total_items: usize) void {
    if (total_items <= viewport_h) {
        scroll_top.* = 0;
        return;
    }
    if (selected_idx < scroll_top.*) {
        scroll_top.* = selected_idx;
    } else if (selected_idx >= scroll_top.* + viewport_h) {
        scroll_top.* = selected_idx - viewport_h + 1;
    }
    if (scroll_top.* + viewport_h > total_items) {
        scroll_top.* = total_items - viewport_h;
    }
}

fn runSearch(
    query: []const u8,
    top_matches: []emojig.Match,
    top_count: *usize,
    limit: usize,
    categories: *const spec_mod.CategoriesSpec,
    disabled_cats: [32]bool,
) usize {
    var disabled_cats_names_buf: [32][]const u8 = undefined;
    var disabled_cats_count: usize = 0;
    for (categories.categories, 0..) |cat, idx| {
        if (idx < disabled_cats.len and disabled_cats[idx]) {
            disabled_cats_names_buf[disabled_cats_count] = cat.name;
            disabled_cats_count += 1;
        }
    }
    return emojig.searchOptions(query, top_matches, top_count, limit, categories, disabled_cats_names_buf[0..disabled_cats_count]);
}

/// Search wrapper that skips re-running an identical query. Leading/trailing
/// spaces never add terms (fuzzyMatch splits on spaces, ignoring empties), so
/// the trimmed query plus the disabled-category mask fully determine the result
/// set. Typing a lone space, or returning to search with an unchanged query
/// after closing a screen, reuses the cached results instead of re-querying.
fn searchDedup(
    query: []const u8,
    top_matches: []emojig.Match,
    top_count: *usize,
    limit: usize,
    categories: *const spec_mod.CategoriesSpec,
    disabled_cats: [32]bool,
) usize {
    const key = std.mem.trim(u8, query, " ");
    if (g_search_initialized and
        std.mem.eql(u8, key, g_search_key_buf[0..g_search_key_len]) and
        std.mem.eql(bool, &g_search_disabled, &disabled_cats))
    {
        return g_search_total;
    }
    g_search_total = runSearch(query, top_matches, top_count, limit, categories, disabled_cats);
    @memcpy(g_search_key_buf[0..key.len], key);
    g_search_key_len = key.len;
    g_search_disabled = disabled_cats;
    g_search_initialized = true;
    return g_search_total;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var opt_tui = false;
    var opt_gui = false;
    var opt_wait = false;
    var opt_install = false;
    var opt_rc: ?[]const u8 = null;
    var opt_list = false;
    var opt_theme: ?Theme = null;
    var opt_width: ?usize = null;
    var opt_height: ?usize = null;
    var opt_border: ?bool = null;
    var opt_safe = false;
    var opt_debug = false;
    var opt_alt_screen = false;
    var opt_simple = false;
    var opt_completion = false;
    var opt_completion_shell: ?[]const u8 = null;
    var opt_key: ?[]const u8 = null;
    var opt_borderless = true; // spawn the GUI host terminal without decorations (default)
    var opt_lang: ?[]const u8 = null;

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // Skip executable path
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tui")) {
            opt_tui = true;
        } else if (std.mem.eql(u8, arg, "--install")) {
            opt_install = true;
        } else if (std.mem.eql(u8, arg, "--rc")) {
            if (args_it.next()) |v| {
                opt_rc = v;
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --rc requires a filename (e.g. .userrc).\n");
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--rc=")) {
            opt_rc = arg["--rc=".len..];
        } else if (std.mem.eql(u8, arg, "--list")) {
            opt_list = true;
        } else if (std.mem.eql(u8, arg, "--gui")) {
            opt_gui = true;
        } else if (std.mem.eql(u8, arg, "--wait")) {
            opt_wait = true;
        } else if (std.mem.eql(u8, arg, "--safe")) {
            opt_safe = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            opt_debug = true;
        } else if (std.mem.eql(u8, arg, "--alt-screen")) {
            opt_alt_screen = true;
        } else if (std.mem.eql(u8, arg, "--simple")) {
            opt_simple = true;
        } else if (std.mem.eql(u8, arg, "--completion")) {
            opt_completion = true;
        } else if (std.mem.startsWith(u8, arg, "--completion=")) {
            opt_completion = true;
            const v = arg["--completion=".len..];
            if (std.mem.eql(u8, v, "zsh") or std.mem.eql(u8, v, "bash") or std.mem.eql(u8, v, "fish") or std.mem.eql(u8, v, "sh")) {
                opt_completion_shell = v;
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --completion= accepts sh, zsh, bash, or fish.\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--key")) {
            if (args_it.next()) |v| {
                opt_key = v;
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --key requires an argument (e.g. '^E').\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--borderless")) {
            opt_borderless = true;
        } else if (std.mem.eql(u8, arg, "--no-borderless")) {
            opt_borderless = false;
        } else if (std.mem.startsWith(u8, arg, "--borderless=")) {
            const v = arg["--borderless=".len..];
            if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) {
                opt_borderless = true;
            } else if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) {
                opt_borderless = false;
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: invalid --borderless value. Use true/false or 1/0.\n");
                std.process.exit(1);
            }
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
        } else if (std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "-l")) {
            if (args_it.next()) |v| {
                opt_lang = v;
            } else {
                try writeAll(std.posix.STDERR_FILENO, "Error: --lang/-l requires an argument (e.g. 'de', 'es').\n");
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--lang=")) {
            opt_lang = arg["--lang=".len..];
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
                "  --lang, -l [code]            Set UI language (de, es, fr, it, pt, pl, ru, uk, nl, tr)\n" ++
                "  --safe                       Safe mode: strip U+FE0F variation selector from screen rendering too\n" ++
                "  --debug                      Debug mode: show terminal dimensions at bottom\n" ++
                "  --tui                        Force local interactive TUI session\n" ++
                "  --gui                        Force floating window (uses $EMOJIG_TERMINAL, else foot/kitty/ghostty/ptyxis/...)\n" ++
                "  --borderless[=true|false]    Spawn the GUI terminal without window decorations (default: true)\n" ++
                "  --alt-screen                 Use alternate screen buffer (full-screen TUI mode)\n" ++
                "  --simple                     Simple fzf/sk-like list picker (use with --height)\n" ++
                "  --wait                       Wait for spawned window to close (with --gui)\n" ++
                "  --completion[=sh|zsh|bash|fish]  Print shell integration to stdout (auto-detects $SHELL)\n" ++
                "  --key KEY                    Key binding to embed in --completion output (e.g. '^E')\n" ++
                "  --install                    Install shell integration and source it in your shell rc file\n" ++
                "  --rc FILE                    RC file for --install (e.g. .userrc); default: .zshrc/.bashrc/config.fish\n" ++
                "  --list                       Print all emojis as 'emoji<TAB>name' for rofi/wofi/dmenu\n" ++
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

    // Determine language: CLI option takes precedence, then environment variables
    const lang = opt_lang orelse blk: {
        if (init.environ_map.get("EMOJIG_LANG")) |v| break :blk v;
        if (init.environ_map.get("LANG")) |v| break :blk v;
        if (init.environ_map.get("LC_ALL")) |v| break :blk v;
        if (init.environ_map.get("LC_MESSAGES")) |v| break :blk v;
        break :blk null;
    };

    // Load the declarative UI spec (spec/*.json) once, into a process-lifetime
    // arena. The embedded JSON is trusted (shipped in the binary), so a parse
    // failure is a build-time bug; fail loudly rather than limp on defaults.
    var spec_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    g_spec = spec_mod.load(spec_arena.allocator(), lang) catch |e| {
        try writeAll(std.posix.STDERR_FILENO, "Error: failed to load embedded UI spec: ");
        try writeAll(std.posix.STDERR_FILENO, @errorName(e));
        try writeAll(std.posix.STDERR_FILENO, "\n");
        std.process.exit(1);
    };
    color.g_colors = &g_spec.colors;

    if (opt_completion) {
        const shell = opt_completion_shell orelse detectShell(init.environ_map);
        printCompletion(shell, opt_key);
        std.process.exit(0);
    }

    if (opt_install) {
        const home = std.mem.span(std.c.getenv("HOME") orelse {
            try writeAll(std.posix.STDERR_FILENO, "Error: HOME not set.\n");
            std.process.exit(1);
        });
        const install_shell = detectShell(init.environ_map);
        installShellIntegration(init.io, home, install_shell, opt_rc, StdoutWriter{});
        std.process.exit(0);
    }

    if (opt_list) {
        var buf: [4096]u8 = undefined;
        var buf_pos: usize = 0;
        var i: usize = 0;
        while (i < emojig.EmojiDb.count) : (i += 1) {
            const entry = emojig.EmojiDb.getEntry(i);
            // emoji + tab + name + newline; max emoji ~8 bytes, name ~64 bytes
            const needed = entry.emoji.len + 1 + entry.name.len + 1;
            if (buf_pos + needed > buf.len) {
                try writeAll(std.posix.STDOUT_FILENO, buf[0..buf_pos]);
                buf_pos = 0;
            }
            @memcpy(buf[buf_pos .. buf_pos + entry.emoji.len], entry.emoji);
            buf_pos += entry.emoji.len;
            buf[buf_pos] = '\t';
            buf_pos += 1;
            @memcpy(buf[buf_pos .. buf_pos + entry.name.len], entry.name);
            buf_pos += entry.name.len;
            buf[buf_pos] = '\n';
            buf_pos += 1;
        }
        if (buf_pos > 0) {
            try writeAll(std.posix.STDOUT_FILENO, buf[0..buf_pos]);
        }
        std.process.exit(0);
    }

    const cfg = loadConfig(spec_arena.allocator(), init.io);

    const env_theme: ?Theme = blk: {
        if (init.environ_map.get("EMOJIG_THEME")) |env_val| {
            if (std.mem.eql(u8, env_val, "light")) break :blk .light else if (std.mem.eql(u8, env_val, "dark")) break :blk .dark else if (std.mem.eql(u8, env_val, "system")) break :blk .system;
        }
        break :blk null;
    };

    const env_scrollbar: ?ScrollbarStyle = blk: {
        if (init.environ_map.get("EMOJIG_SCROLLBAR")) |env_val| {
            if (std.mem.eql(u8, env_val, "bar")) break :blk .bar else if (std.mem.eql(u8, env_val, "expand")) break :blk .expand;
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

    const env_debug: ?bool = blk: {
        if (init.environ_map.get("EMOJIG_DEBUG")) |env_val| {
            break :blk std.mem.eql(u8, env_val, "1") or std.mem.eql(u8, env_val, "true");
        }
        break :blk null;
    };

    // Resize strategy — EMOJIG_RESIZE_MODE=freeze|hide|eat|altscreen (default: freeze).
    // EMOJIG_ALT_SCREEN=1 is kept as a backward-compatible alias for altscreen.
    // See src/resize.zig for a full description of each mode.
    const resize_mode: resize.Mode = blk: {
        if (opt_alt_screen) break :blk .altscreen;
        if (init.environ_map.get("EMOJIG_ALT_SCREEN")) |v| {
            if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) break :blk resize.Mode.altscreen;
        }
        break :blk resize.parseMode(init.environ_map.get("EMOJIG_RESIZE_MODE"));
    };

    // An explicit height (CLI --height, EMOJIG_HEIGHT, or config) is a total
    // content-row count; it is converted to a grid-row count where `rows` is
    // derived below. EMOJIG_ROWS (set by the GUI launcher) expresses grid rows
    // directly and takes precedence over this override.
    const height_override: ?usize = opt_height orelse env_height orelse cfg.height;

    const final_theme = opt_theme orelse env_theme orelse cfg.theme orelse .dark;

    // Unified grid size (columns × rows). The single source of truth is the
    // config (`cols=`/`rows=`), overridable per-launch by EMOJIG_COLS/EMOJIG_ROWS
    // (the GUI launcher sets these so the child picker matches the foot window).
    // Both GUI and TUI use the same base because users work on one screen.
    // Each axis is clamped to its compile-time max so all stack buffers stay
    // in bounds; with MAX_COLS*MAX_ROWS == MAX_CELLS the product is safe too.
    // Each axis is clamped to [MIN, MAX]: the MAX keeps stack buffers in bounds,
    // the MIN guarantees a legible grid even if `cols`/`rows` (env or config)
    // is misconfigured below 5×3.
    const base_cols: usize = blk: {
        const raw: usize = raw: {
            if (init.environ_map.get("EMOJIG_COLS")) |v| {
                if (std.fmt.parseInt(usize, v, 10)) |n| break :raw n else |_| {}
            }
            if (cfg.cols) |c| break :raw c;
            break :raw g_spec.layout.tui.cols;
        };
        break :blk @max(defaults.MIN_COLS, @min(raw, defaults.MAX_COLS));
    };
    const base_rows: usize = blk: {
        const raw: usize = raw: {
            if (init.environ_map.get("EMOJIG_ROWS")) |v| {
                if (std.fmt.parseInt(usize, v, 10)) |n| break :raw n else |_| {}
            }
            if (height_override) |h| break :raw if (h > g_spec.layout.layout_overhead) h - g_spec.layout.layout_overhead else 0;
            if (cfg.rows) |r| break :raw r;
            break :raw g_spec.layout.tui.rows;
        };
        break :blk @max(defaults.MIN_ROWS, @min(raw, defaults.MAX_ROWS));
    };

    // Content width follows the column count (one trailing column for the
    // scrollbar gutter) unless an explicit width override is given. For the
    // default 6 columns this reproduces the historical width of 25.
    const final_width = opt_width orelse env_width orelse cfg.width orelse (base_cols * 4 + 1);
    const final_border = opt_border orelse env_border orelse cfg.border orelse false;
    const final_safe = opt_safe or (env_safe orelse cfg.safe orelse false);
    const final_debug = opt_debug or (env_debug orelse false);
    const final_alt_screen = (resize_mode == .altscreen);
    const final_simple = opt_simple;

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

        // Single-instance toggle: if a GUI picker is already open, close it
        // and exit — the same hotkey/command opens and closes the window.
        if (toggleRunningPicker()) {
            std.process.exit(0);
        }

        if (std.c.getenv("HOME")) |home_c| {
            const home = std.mem.span(home_c);
            ensureDesktopIntegration(init.io, home, exe_path);

            // Relaunch workaround for Wayland/X11 focus stealing prevention when launched from raw shortcuts.
            // If we are in a GUI session and have neither XDG_ACTIVATION_TOKEN nor DESKTOP_STARTUP_ID set,
            // it means we were likely launched via a raw keybinding. Re-executing via gtk-launch or gio launch
            // uses GAppLaunchContext, generating the proper activation token so that the spawned window gets focus.
            if (has_gui_session) {
                const has_token = std.c.getenv("XDG_ACTIVATION_TOKEN") != null or std.c.getenv("DESKTOP_STARTUP_ID") != null;
                if (!has_token) {
                    const uid = getuid();
                    const current_ts = time(null);
                    var lock_path_buf: [128]u8 = undefined;
                    const lock_path = std.fmt.bufPrint(&lock_path_buf, "/tmp/emojig-relaunch-{d}.lock", .{uid}) catch "";

                    var already_relaunched = false;

                    if (lock_path.len > 0) {
                        lock_path_buf[lock_path.len] = 0;
                        const rf = std.posix.O{ .ACCMODE = .RDONLY };
                        if (std.posix.openat(std.posix.AT.FDCWD, lock_path, rf, 0)) |fd| {
                            defer _ = std.posix.system.close(fd);
                            var read_buf: [32]u8 = undefined;
                            const n = std.posix.system.read(fd, &read_buf, read_buf.len);
                            if (n > 0) {
                                const read_str = read_buf[0..@intCast(n)];
                                if (std.fmt.parseInt(i64, read_str, 10)) |read_ts| {
                                    if (current_ts - read_ts >= 0 and current_ts - read_ts < 5) {
                                        already_relaunched = true;
                                    }
                                } else |_| {}
                            }
                        } else |_| {}
                    }

                    if (!already_relaunched) {
                        if (lock_path.len > 0) {
                            const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
                            if (std.posix.openat(std.posix.AT.FDCWD, lock_path, wf, 0o600)) |fd| {
                                defer _ = std.posix.system.close(fd);
                                var val_buf: [32]u8 = undefined;
                                const val_str = std.fmt.bufPrint(&val_buf, "{d}", .{current_ts}) catch "";
                                if (val_str.len > 0) {
                                    _ = std.posix.system.write(fd, val_str.ptr, val_str.len);
                                }
                            } else |_| {}
                        }

                        const relaunch_argv = [_][]const u8{ "gtk-launch", "emojig-picker" };
                        var relaunch_child = std.process.spawn(init.io, .{
                            .argv = &relaunch_argv,
                            .stdin = .ignore,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        }) catch blk: {
                            var desktop_path_buf: [512]u8 = undefined;
                            const desktop_path = std.fmt.bufPrint(&desktop_path_buf, "{s}/.local/share/applications/emojig-picker.desktop", .{home}) catch "";
                            if (desktop_path.len > 0) {
                                const gio_argv = [_][]const u8{ "gio", "launch", desktop_path };
                                break :blk std.process.spawn(init.io, .{
                                    .argv = &gio_argv,
                                    .stdin = .ignore,
                                    .stdout = .ignore,
                                    .stderr = .ignore,
                                }) catch null;
                            }
                            break :blk null;
                        };
                        if (relaunch_child) |*c| {
                            _ = c.wait(init.io) catch {};
                            std.process.exit(0);
                        }
                    } else {
                        if (lock_path.len > 0) {
                            _ = unlink(lock_path_buf[0..lock_path.len :0]);
                        }
                    }
                }
            }
        }

        // Unified grid size for the GUI window: config → spec GUI default.
        // (EMOJIG_COLS/ROWS may override, e.g. for scripted launches.)
        const gui_cols: usize = blk: {
            const raw: usize = raw: {
                if (init.environ_map.get("EMOJIG_COLS")) |v| {
                    if (std.fmt.parseInt(usize, v, 10)) |n| break :raw n else |_| {}
                }
                if (cfg.cols) |c| break :raw c;
                break :raw g_spec.layout.gui.cols;
            };
            break :blk @max(defaults.MIN_COLS, @min(raw, defaults.MAX_COLS));
        };
        const gui_rows: usize = blk: {
            const raw: usize = raw: {
                if (init.environ_map.get("EMOJIG_ROWS")) |v| {
                    if (std.fmt.parseInt(usize, v, 10)) |n| break :raw n else |_| {}
                }
                if (cfg.rows) |r| break :raw r;
                break :raw g_spec.layout.gui.rows;
            };
            break :blk @max(defaults.MIN_ROWS, @min(raw, defaults.MAX_ROWS));
        };

        host.spawnGuiWindow(
            init,
            exe_path,
            final_theme,
            final_border,
            final_safe,
            final_debug,
            opt_wait,
            opt_borderless,
            gui_cols,
            gui_rows,
            &g_spec,
        ) catch |err| {
            try writeAll(std.posix.STDERR_FILENO, "Error: failed to launch terminal window. Set EMOJIG_TERMINAL or install a supported terminal (foot, kitty, alacritty, ...) (");
            try writeAll(std.posix.STDERR_FILENO, @errorName(err));
            try writeAll(std.posix.STDERR_FILENO, ").\n");
            std.process.exit(1);
        };
        std.process.exit(0);
    }

    var theme = final_theme;
    var scrollbar_style: ScrollbarStyle = env_scrollbar orelse cfg.scrollbar_style orelse .expand;
    // Pending grid size shown/edited in the Settings screen. Seeded from the
    // resolved launch size; edits persist to config and take effect on the
    // next launch (the live grid keeps its launch dimensions for safety).
    var grid_cols: usize = base_cols;
    var grid_rows: usize = base_rows;
    // Coarse step for Space/Enter on a grid-size row (Left/Right adjust by ±1).
    const grid_dim_step: usize = 2;
    // Set once a grid-size row is edited this session — surfaced in the settings
    // status hint ("applies on next launch") instead of a per-step popup.
    var griddim_changed: bool = false;
    // True while consecutive digits are being typed into a grid-size row, so
    // "1" then "2" builds 12. Any non-digit key (nav/select/esc) clears it.
    var griddim_typing: bool = false;
    const term_width = final_width;
    const show_border = final_border;

    // Row offset: when border is shown, all content rows shift down by 1.
    const row_off: i32 = if (show_border) 1 else 0;
    global_row_off = row_off;

    var result_emoji: ?[]const u8 = null;
    var result_safe_buf: [64]u8 = undefined;
    var has_focus = true;
    var started_unfocused = false;
    var last_focus_gain_ms: i64 = 0;
    const gui_spawned = blk: {
        if (init.environ_map.get("EMOJIG_GUI_SPAWNED")) |v| {
            break :blk std.mem.eql(u8, v, "1");
        }
        break :blk false;
    };
    // Record this picker's PID for the `--gui` single-instance toggle.
    if (gui_spawned) writePickerPidFile();

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

        // ----------------------------------------------------------------
        // Self-pipe signal infrastructure (ZigTuiArchitecture.md §1-3).
        // All signals of interest write one byte (signal number) into the
        // pipe write-end.  The main event loop drains the pipe via poll().
        // ----------------------------------------------------------------
        const pipe_fds = try tui.setupSelfPipe();
        const pipe_rd = pipe_fds[0];
        const pipe_wr = pipe_fds[1];
        defer _ = std.posix.system.close(pipe_rd);
        defer _ = std.posix.system.close(pipe_wr);

        tui.registerSignals(&.{
            std.posix.SIG.INT,
            std.posix.SIG.TERM,
            std.posix.SIG.WINCH,
            std.posix.SIG.ALRM,
        });

        // Inactivity timeout in seconds (EMOJIG_PICKER_TIMEOUT env var).
        // Passed as poll(timeout_ms); no alarm(2) needed.
        var active_timeout: ?c_uint = null;
        if (init.environ_map.get("EMOJIG_PICKER_TIMEOUT")) |timeout_str| {
            if (std.fmt.parseInt(c_uint, timeout_str, 10)) |timeout_val| {
                if (timeout_val > 0) {
                    active_timeout = timeout_val;
                }
            } else |_| {}
        }
        // Tracks the monotonic time of the last received input event so the
        // inactivity countdown resets correctly on any user activity (including
        // scrollbar drags that pause between motion events).
        var last_input_ms: i64 = getMonotonicMs();

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

        // Check for startup focus if spawned inside a GUI terminal window.
        if (gui_spawned) {
            // Enable focus reporting
            try writeAll(stdout_fd, "\x1b[?1004h");

            // Read focus reports from stdin with a 200ms timeout.
            var focus_raw = raw;
            focus_raw.cc[@intFromEnum(system.V.MIN)] = 0;
            focus_raw.cc[@intFromEnum(system.V.TIME)] = 2;
            try std.posix.tcsetattr(stdin_fd, .NOW, focus_raw);

            var focus_buf: [128]u8 = undefined;
            const n = std.posix.read(stdin_fd, &focus_buf) catch 0;

            // Restore standard TUI raw mode
            try std.posix.tcsetattr(stdin_fd, .NOW, raw);

            if (n > 0) {
                const last_in = std.mem.lastIndexOf(u8, focus_buf[0..n], "\x1b[I");
                const last_out = std.mem.lastIndexOf(u8, focus_buf[0..n], "\x1b[O");
                if (last_out) |out_idx| {
                    if (last_in) |in_idx| {
                        if (out_idx > in_idx) {
                            has_focus = false;
                            started_unfocused = true;
                        }
                    } else {
                        has_focus = false;
                        started_unfocused = true;
                    }
                }
            } else {
                has_focus = false;
                started_unfocused = true;
            }
        }

        const cols: usize = base_cols;
        const rows: usize = base_rows;
        // In simple mode: list_rows of results + 1 count row + 1 prompt row.
        // Derive list_rows from height_override if given, else use the grid row count as default.
        const list_rows: usize = if (final_simple) blk: {
            if (height_override) |h| break :blk if (h > 2) h - 2 else 1;
            break :blk g_spec.layout.tui.rows;
        } else rows;
        const content_rows: usize = if (final_simple) list_rows + 2 else rows + g_spec.layout.layout_overhead;
        var final_h = if (final_simple) content_rows else if (show_border) content_rows + 2 else content_rows;
        if (final_debug and !final_simple) final_h += 2;
        global_tui_height = final_h;

        // Query the cursor position first (before drawing or writing any newlines).
        // If the viewport does not fit below the cursor, scroll the terminal up only by the exact deficit.
        if (!final_alt_screen) {
            const cy = queryCursorRow(stdin_fd, stdout_fd, raw) orelse 0;
            if (cy > 0) {
                const cy_usize = @as(usize, @intCast(cy));
                var ws_size = std.mem.zeroes(std.posix.winsize);
                const size_rc = std.posix.system.ioctl(stdout_fd, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws_size));
                const term_height = if (size_rc == 0 and ws_size.row > 0) @as(usize, ws_size.row) else 24;

                const space_below = if (term_height >= cy_usize) term_height - cy_usize else 0;
                if (space_below < final_h) {
                    const to_scroll = final_h - space_below - 1;
                    if (to_scroll > 0) {
                        var scroll_buf: [32]u8 = undefined;
                        // Scroll up by to_scroll lines.
                        const scroll_seq = try std.fmt.bufPrint(&scroll_buf, "\x1b[{d}S", .{to_scroll});
                        try writeAll(stdout_fd, scroll_seq);

                        var move_buf: [32]u8 = undefined;
                        // Move the cursor up by to_scroll lines to park it at the top-left of the viewport.
                        const move_up_seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{to_scroll});
                        try writeAll(stdout_fd, move_up_seq);

                        const y = if (cy_usize > to_scroll) cy_usize - to_scroll else 1;
                        global_tui_start_row = @intCast(y);
                    } else {
                        global_tui_start_row = @intCast(cy_usize);
                    }
                } else {
                    global_tui_start_row = @intCast(cy_usize);
                }
            } else {
                // Fallback: reserve space using newlines if DSR query fails.
                var up_buf: [32]u8 = undefined;
                for (0..final_h - 1) |_| {
                    try writeAll(stdout_fd, "\n");
                }
                const up_seq = try std.fmt.bufPrint(&up_buf, "\x1b[{d}A\r", .{final_h - 1});
                try writeAll(stdout_fd, up_seq);
                global_tui_start_row = null;
            }
        } else {
            global_tui_start_row = 1;
        }

        var system_theme: Theme = if (theme == .system)
            detectSystemTheme(stdin_fd, stdout_fd, raw)
        else
            theme;

        var is_first_render = true;
        var last_was_motion = false; // true only after a mouse-motion event
        var dragging_scrollbar = false; // true while left-button is held on the scrollbar column
        var rctx = resize.ResizeContext.init(resize_mode);
        var last_drawn_h: usize = final_h;
        // Declared here (before the defer) so the defer body can read it.
        // Set to true when the user selects an emoji (copy-and-exit path).
        var should_copy_and_exit = false;

        defer {
            term_lib.appendLog("exit via defer (normal/signal)", .{});
            // CRITICAL HANDSHAKE FOR TERMINAL EXIT SYNCHRONIZATION:
            // 1. Disable mouse tracking immediately.
            // 2. Append a Cursor Position Report query ("\x1b[6n") to stdout.
            _ = std.posix.system.write(stdout_fd, term_lib.MOUSE_OFF ++ "\x1b[6n", term_lib.MOUSE_OFF.len + 5);

            // 3. Configure stdin to raw non-blocking with a 100ms VTIME timeout to read the response.
            var drain_raw = orig_termios;
            drain_raw.lflag.ICANON = false;
            drain_raw.lflag.ECHO = false;
            const sys = std.posix.system;
            drain_raw.cc[@intFromEnum(sys.V.MIN)] = 0;
            drain_raw.cc[@intFromEnum(sys.V.TIME)] = 1;
            std.posix.tcsetattr(stdin_fd, .NOW, drain_raw) catch {};

            // 4. Read stdin until we receive the terminating 'R' byte of the CPR response.
            // Since the terminal processes input streams sequentially in a FIFO queue, receiving the response
            // to "\x1b[6n" guarantees that the terminal emulator has parsed and executed MOUSE_OFF, and that
            // all in-flight mouse events generated prior to mouse disabling have safely arrived in stdin.
            var drain_buf: [256]u8 = undefined;
            var got_response = false;
            while (!got_response) {
                const rc = sys.read(stdin_fd, &drain_buf, drain_buf.len);
                if (rc <= 0) break;
                for (drain_buf[0..@intCast(rc)]) |b| {
                    if (b == 'R') {
                        got_response = true;
                        break;
                    }
                }
            }

            // 5. Sweep any remaining trailing bytes non-blockingly (VTIME=0) before restoring cooked mode.
            // This prevents SGR mouse release or drag motion events from leaking to the shell prompt!
            drain_raw.cc[@intFromEnum(sys.V.TIME)] = 0;
            std.posix.tcsetattr(stdin_fd, .NOW, drain_raw) catch {};
            while (true) {
                const rc = sys.read(stdin_fd, &drain_buf, drain_buf.len);
                if (rc <= 0) break;
            }

            // 6. Restore cooked mode.
            std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};

            if (!is_first_render) {
                var move_buf: [32]u8 = undefined;
                if (rctx.is_hidden) {
                    _ = std.posix.system.write(stdout_fd, "\x1b[2K\r", 5);
                } else {
                    // Jump to TUI row 0 absolutely — no assumptions about current cursor position.
                    // global_tui_start_row is set at TUI startup and kept current on each resize.
                    // This is robust for all exit paths: Esc (cursor at search bar), select/exit_preview
                    // (cursor at TUI bottom), Ctrl-C via binding, etc.
                    var abs_move_buf: [32]u8 = undefined;
                    if (global_tui_start_row) |start_row| {
                        const abs_seq = std.fmt.bufPrint(&abs_move_buf, "\x1b[{d};1H", .{start_row}) catch "";
                        _ = std.posix.system.write(stdout_fd, abs_seq.ptr, abs_seq.len);
                    } else {
                        // Fallback when CPR was unavailable at startup.
                        const up_to_tui_top: usize = if (should_copy_and_exit)
                            if (last_drawn_h > 0) last_drawn_h - 1 else 0
                        else
                            @as(usize, @intCast(1 + row_off));
                        const move_seq = std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{up_to_tui_top}) catch "";
                        _ = std.posix.system.write(stdout_fd, move_seq.ptr, move_seq.len);
                    }

                    var k: usize = 0;
                    while (k < last_drawn_h) : (k += 1) {
                        const clear_seq = "\x1b[2K";
                        _ = std.posix.system.write(stdout_fd, clear_seq.ptr, clear_seq.len);
                        if (k < last_drawn_h - 1) {
                            const down_seq = "\x1b[B\r";
                            _ = std.posix.system.write(stdout_fd, down_seq.ptr, down_seq.len);
                        }
                    }
                    // Return cursor to TUI row 0 (where the shell prompt will appear).
                    if (global_tui_start_row) |start_row| {
                        const abs_seq = std.fmt.bufPrint(&abs_move_buf, "\x1b[{d};1H", .{start_row}) catch "";
                        _ = std.posix.system.write(stdout_fd, abs_seq.ptr, abs_seq.len);
                    } else if (last_drawn_h > 1) {
                        _ = std.posix.system.write(stdout_fd, "\r\n", 2);
                    }
                }
            }
            writeAll(stdout_fd, restoreSeq()) catch {};
            global_alt_screen = false;
            removePickerPidFile();
            logMemoryUsage();
        }

        // Disable line wrap (7l), enable any-motion mouse tracking (1003), SGR coords, blinking cursor, hide cursor.
        // Switch to alternate screen (1049h) if configured.
        if (final_alt_screen) {
            global_alt_screen = true;
            if (gui_spawned) {
                try writeAll(stdout_fd, "\x1b[?1049h\x1b[?7l\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l\x1b[?1004h");
            } else {
                try writeAll(stdout_fd, "\x1b[?1049h\x1b[?7l\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l");
            }
        } else {
            if (gui_spawned) {
                try writeAll(stdout_fd, "\x1b[?7l\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l\x1b[?1004h");
            } else {
                try writeAll(stdout_fd, "\x1b[?7l\x1b[?1003h\x1b[?1006h\x1b[?12h\x1b[?25l");
            }
        }

        applyTerminalColors(stdout_fd, theme, system_theme, final_alt_screen);

        const start_ms = getMonotonicMs();
        const log_mode: []const u8 = if (gui_spawned) "gui" else if (final_simple) "simple" else "tui";
        term_lib.appendLog("start mode={s}", .{log_mode});
        var last_rss_bytes: usize = term_lib.readRssBytes();

        var current_screen: ScreenState = .search;
        var cat_scroll_top: usize = 0;
        var settings_scroll_top: usize = 0;
        // Number of rows on the Settings screen (JSON toggles + theme + scrollbar).
        const settings_count: usize = 9;
        var help_scroll_top: usize = 0;
        var about_scroll_top: usize = 0;
        var anim_frame: usize = 0;
        var anim_timer: i64 = 0;
        var anim_done: bool = true;
        var status_scroll_top: usize = 0;
        var multi_select_active: bool = false;
        var multi_selected_emojis = std.ArrayList([]const u8).empty;
        defer multi_selected_emojis.deinit(spec_arena.allocator());
        var disabled_cats = std.mem.zeroes([32]bool);
        if (cfg.disabled_categories) |dc_str| {
            var it = std.mem.splitScalar(u8, dc_str, ',');
            while (it.next()) |name| {
                for (g_spec.categories.categories, 0..) |cat, idx| {
                    if (std.mem.eql(u8, cat.name, name)) {
                        if (idx < disabled_cats.len) {
                            disabled_cats[idx] = true;
                        }
                    }
                }
            }
        }
        var shell_integration = cfg.shell_integration orelse settingDefaultBool("shell_integration");
        var shell_key_binding = cfg.shell_key_binding orelse settingDefault("shell_key_binding");
        var show_all_categories = cfg.show_all_categories orelse settingDefaultBool("show_all_categories");
        var ambiguous_chars = cfg.ambiguous_chars orelse settingDefault("ambiguous_chars");
        tui_draw.g_wide_ambiguous = !std.mem.eql(u8, ambiguous_chars, "narrow");

        var keybind_editing: bool = false;
        var keybind_input_buf: [32]u8 = undefined;
        var keybind_input_len: usize = 0;
        var keybind_committed_buf: [32]u8 = undefined;
        var keybind_committed_len: usize = 0;

        var popup_msg: ?[]const u8 = null;
        // Title shown on the popup's first row — set alongside `popup_msg` so the
        // modal header reflects what it actually shows (settings help vs. update).
        var popup_title: []const u8 = "💬 emojig message";
        var popup_buf: [1024]u8 = undefined;

        // Pre-formatted emoji count — doesn't change at runtime.
        var emojis_count_buf: [16]u8 = undefined;
        const emojis_count_str = std.fmt.bufPrint(&emojis_count_buf, "{d}", .{emojig.EmojiDb.count}) catch "?";

        var query_buf: [defaults.MAX_QUERY_LEN]u8 = undefined;
        var query_len: usize = 0;
        // Byte offset of the text cursor within query_buf[0..query_len]. The
        // prompt "has focus" (owns Left/Right/Home/End) whenever selected_idx
        // is null; once the grid is navigated, selected_idx becomes non-null
        // and those keys drive the grid instead.
        var query_cursor: usize = 0;
        // Acknowledge ignored/dead keys with a single BEL, re-armed by any other
        // key so a run of repeats stays silent (prompt Up, dead keys on docs).
        var bell_suppressed = false;
        // Effective query cap from the spec, never exceeding the stack buffer.
        const max_query_len: usize = @min(g_spec.layout.max_query_len, query_buf.len);

        // In simple mode we cap at MAX_CELLS list items; grid mode uses cols*rows.
        // total_cells is the *viewport* size (visible cells). The search fetches
        // up to fetch_limit results so the grid/list can scroll past one page.
        const total_cells: usize = if (final_simple) @min(list_rows, defaults.MAX_CELLS) else cols * rows;
        const fetch_limit: usize = defaults.MAX_RESULTS;

        // The spec grid must fit the compile-time scratch buffers (defaults.zig).
        if (!final_simple) {
            std.debug.assert(cols <= defaults.MAX_COLS);
            std.debug.assert(rows <= defaults.MAX_ROWS);
        }
        std.debug.assert(total_cells <= defaults.MAX_CELLS);

        var selected_idx: ?usize = null;
        var top_matches: [defaults.MAX_RESULTS]emojig.Match = undefined;
        var top_count: usize = 0;
        // Row offset of the grid/list viewport into the result set (search
        // screen). Kept in sync with selected_idx via adjustScrollTop, and
        // also driven directly by PageUp/Down, Home/End, wheel, and drag.
        var grid_scroll_top: usize = 0;

        // (declared before defer above)
        var exit_preview = false;
        var exit_preview_step: usize = 0;
        const max_preview_steps: usize = 8;
        var theme_hovered = false;
        // Which grid-size arrow (if any) the mouse is over, for hover feedback.
        var griddim_hover_left = false;
        var griddim_hover_right = false;

        // ---------------------------------------------------------------------------
        // Exit preview configuration (parsed once before the render loop).
        //
        // Priority (highest wins):
        //   1. EMOJIG_EXIT_PREVIEW=0/false  — force-disable (immediate exit)
        //   2. EMOJIG_EXIT_PREVIEW=1/true   — force-enable
        //   3. spec/layout.json animation.exit_preview_tui — per-mode default
        //
        // EMOJIG_EXIT_PREVIEW_MS=N overrides the hold duration in ms (clamped 0–5000).
        // EMOJIG_EXIT_PREVIEW is set to "0" by the GUI launcher when the spec default
        // for GUI mode (animation.exit_preview_gui) is false.
        // ---------------------------------------------------------------------------
        const preview_enabled: bool = blk: {
            if (init.environ_map.get("EMOJIG_EXIT_PREVIEW")) |v| {
                if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) break :blk false;
                if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) break :blk true;
            }
            // Fall back to the spec default for TUI mode.
            break :blk g_spec.layout.animation.exit_preview_tui;
        };
        const preview_hold_ns: u64 = blk: {
            const default_ms: u64 = 200;
            const ns_per_ms: u64 = 1_000_000;
            if (init.environ_map.get("EMOJIG_EXIT_PREVIEW_MS")) |v| {
                const ms = std.fmt.parseInt(u64, v, 10) catch default_ms;
                const clamped: u64 = @min(ms, 5000);
                break :blk clamped * ns_per_ms;
            }
            break :blk default_ms * ns_per_ms;
        };

        var total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
        selected_idx = if (top_count > 0) 0 else null;

        var read_buf: [512]u8 = undefined;
        // Carry buffer: saves the bytes of an incomplete SGR mouse event that
        // arrived at the end of a read and had no M/m terminator yet.  Prepended
        // to the next read so the bytes are never re-interpreted as typed text.
        var mouse_carry: [32]u8 = undefined;
        var mouse_carry_len: usize = 0;
        const spaces = " " ** 512;
        const content_width = term_width;

        var last_w: usize = term_width;
        var last_h: usize = final_h;
        var ws_init = std.mem.zeroes(std.posix.winsize);
        if (std.posix.system.ioctl(stdout_fd, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws_init)) == 0) {
            if (ws_init.col > 0) last_w = ws_init.col;
            if (ws_init.row > 0) last_h = ws_init.row;
        }
        var is_too_small = false;

        while (true) {
            if (current_screen == .search and query_len > 0 and query_buf[0] == '?') {
                top_count = 0;
                total_matches = 0;
                selected_idx = null;
            }

            const is_cmd_autocomplete = (current_screen == .search and query_len > 0 and (query_buf[0] == ':' or query_buf[0] == '/'));
            const cmd_prefix: u8 = if (is_cmd_autocomplete) query_buf[0] else ':';
            var cmd_matches: [16]usize = undefined;
            var cmd_match_count: usize = 0;
            if (is_cmd_autocomplete) {
                const cmd_query = query_buf[1..query_len];
                for (g_spec.commands.commands, 0..) |cmd, idx| {
                    const matches = (cmd_query.len == 0) or
                        std.mem.startsWith(u8, cmd.name, cmd_query) or
                        std.mem.startsWith(u8, cmd.short, cmd_query);
                    if (matches) {
                        cmd_matches[cmd_match_count] = idx;
                        cmd_match_count += 1;
                        if (cmd_match_count == cmd_matches.len) break;
                    }
                }
                top_count = cmd_match_count;
                total_matches = cmd_match_count;
                if (selected_idx != null and selected_idx.? >= cmd_match_count) {
                    selected_idx = if (cmd_match_count > 0) @as(usize, 0) else null;
                }
            }

            const is_cat_autocomplete = (current_screen == .search and query_len >= 2 and (query_buf[0] == 'c' or query_buf[0] == 'C') and query_buf[1] == ':' and std.mem.indexOfScalar(u8, query_buf[2..query_len], ' ') == null);
            var cat_matches: [32]usize = undefined;
            var cat_match_count: usize = 0;
            if (is_cat_autocomplete) {
                const cat_query = query_buf[2..query_len];
                for (g_spec.categories.categories, 0..) |cat, idx| {
                    var matches = (cat_query.len == 0) or
                        std.mem.startsWith(u8, cat.name, cat_query) or
                        std.mem.startsWith(u8, cat.short, cat_query);
                    if (!matches) {
                        for (cat.synonyms) |syn| {
                            if (std.mem.startsWith(u8, syn, cat_query)) {
                                matches = true;
                                break;
                            }
                        }
                    }
                    if (matches) {
                        cat_matches[cat_match_count] = idx;
                        cat_match_count += 1;
                        if (cat_match_count == cat_matches.len) break;
                    }
                }
                top_count = cat_match_count;
                total_matches = cat_match_count;
                if (selected_idx != null and selected_idx.? >= cat_match_count) {
                    selected_idx = if (cat_match_count > 0) @as(usize, 0) else null;
                }
            }

            if (current_screen == .settings) {
                top_count = 4;
                total_matches = 4;
            } else if (current_screen == .categories) {
                top_count = g_spec.categories.categories.len;
                total_matches = g_spec.categories.categories.len;
            }

            const palette = effectivePalette(theme, system_theme, !has_focus and gui_spawned);

            // Keep the text cursor and grid scroll within valid bounds. This is
            // the safety net for every query-reset site: when results shrink or
            // the query is cleared, neither the cursor nor the viewport can
            // point past the live data.
            if (query_cursor > query_len) query_cursor = query_len;
            {
                const cc = if (final_simple) @as(usize, 1) else cols;
                const vp = if (final_simple) total_cells else rows;
                const trows = (top_count + cc - 1) / cc;
                const max_top = if (trows > vp) trows - vp else 0;
                if (grid_scroll_top > max_top) grid_scroll_top = max_top;
            }

            // Focus model: the prompt "owns" the cursor while selected_idx is
            // null. In that state, once a query is typed, the first result
            // still gets a (non-highlighted) bracket marker so Enter's target
            // stays visible — this preserves the fast "type + Enter" path.
            // Navigating the grid sets selected_idx (grid focus) and adds the
            // highlight. effective_idx drives both the marker and the
            // description row; only selected_idx draws the selection_bg.
            const soft_marker: bool = current_screen == .search and selected_idx == null and
                query_len > 0 and top_count > 0 and !multi_select_active;
            const effective_idx: ?usize = selected_idx orelse (if (soft_marker) @as(usize, 0) else null);

            // ----------------------------------------------------------------
            // Render
            // ----------------------------------------------------------------
            // Skip render only when the previous event was a mouse-motion event
            // AND more input is already buffered — coalesces hover storms without
            // delaying keyboard input. Keyboard events always trigger an immediate
            // render so characters appear as they are typed.
            //
            // fast_render: motion events still queued (scrollbar drag / hover storm).
            // Draw the full frame with blank emoji cells so foot can update the
            // scrollbar thumb position instantly — no new glyphs means no
            // rasterization delay. Full emoji cells render once the queue drains.
            const has_pending_input = tui.poll(stdin_fd, pipe_rd, 0) == .tty;
            const fast_render = !is_first_render and !exit_preview and
                (last_was_motion or dragging_scrollbar) and has_pending_input;
            if (exit_preview or !should_copy_and_exit) {
                try writeAll(stdout_fd, "\x1b[?25l");

                var ws_size = std.mem.zeroes(std.posix.winsize);
                const size_rc = std.posix.system.ioctl(stdout_fd, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws_size));
                const current_w = if (size_rc == 0 and ws_size.col > 0) ws_size.col else content_width + 1;
                const current_h = if (size_rc == 0 and ws_size.row > 0) ws_size.row else 10;
                is_too_small = (current_w < content_width + 2);
                const max_w = if (is_too_small) (if (current_w > 3) current_w - 3 else 0) else content_width;

                const prefix_cols = 3;
                const icon_cols = 4;
                const max_query_cols = if (content_width > prefix_cols + icon_cols) content_width - prefix_cols - icon_cols else 0;
                // Horizontal scroll window over the query text so the text
                // cursor stays visible even when the query is longer than the
                // search bar. For short queries (the common case) view_start is
                // 0 and this collapses to the original "show from the start".
                const query_view_start: usize = if (query_cursor > max_query_cols)
                    query_cursor - max_query_cols
                else
                    0;
                const display_query_len = @min(query_len - query_view_start, max_query_cols);
                // Column offset of the cursor within the visible query window.
                const cursor_col_off = query_cursor - query_view_start;

                if (resize_mode == .altscreen) {
                    rctx.is_hidden = false;
                } else {
                    rctx.is_hidden = current_h < final_h + 1;
                }

                const show_top_border = show_border;
                const show_bottom_border = show_border;
                const show_debug = final_debug and !is_too_small;

                var current_total_rows: usize = 0;
                if (!rctx.is_hidden) {
                    if (final_simple) {
                        current_total_rows = total_cells + 2; // list rows + count + prompt
                    } else {
                        if (show_top_border) current_total_rows += 1;
                        current_total_rows += 1; // Top padding
                        current_total_rows += 1; // Search bar
                        current_total_rows += 1; // Spacer
                        current_total_rows += rows; // Grid rows
                        current_total_rows += 1; // Spacer between grid and description
                        current_total_rows += 1; // Description
                        current_total_rows += 1; // Status bar
                        if (show_bottom_border) current_total_rows += 1;
                        if (show_debug) current_total_rows += 2;
                    }
                } else {
                    current_total_rows = 1;
                }

                const height_changed = (current_h != last_h);
                const resized = (current_w != last_w or height_changed);

                if (!is_first_render) {
                    var move_buf: [48]u8 = undefined;
                    if (resize_mode == .altscreen) {
                        if (resized) {
                            try writeAll(stdout_fd, "\x1b[2J\x1b[1;1H");
                            last_w = current_w;
                            last_h = current_h;
                        } else {
                            try writeAll(stdout_fd, "\x1b[1;1H");
                        }
                    } else {
                        if (rctx.is_hidden) {
                            if (rctx.was_hidden) {
                                try writeAll(stdout_fd, "\r");
                            } else {
                                const up_rows = @as(usize, @intCast(1 + row_off));
                                const seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r\x1b[J", .{up_rows});
                                try writeAll(stdout_fd, seq);
                            }
                        } else {
                            if (rctx.was_hidden) {
                                try writeAll(stdout_fd, "\r\x1b[J");
                            } else {
                                // In simple mode the cursor ends on the prompt (last row), so move
                                // up by the full height - 1 to return to the first list row.
                                const up_rows = if ((exit_preview or final_simple) and last_drawn_h > 1) last_drawn_h - 1 else @as(usize, @intCast(1 + row_off));
                                const seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{up_rows});
                                try writeAll(stdout_fd, seq);
                            }
                        }
                        if (resized) {
                            last_w = current_w;
                            last_h = current_h;
                            if (!rctx.is_hidden) {
                                if (queryCursorRow(stdin_fd, stdout_fd, raw)) |tui_top| {
                                    global_tui_start_row = tui_top;
                                }
                            }
                        }
                    }
                } else {
                    is_first_render = false;
                    term_lib.appendLog("first_render latency_ms={d}", .{getMonotonicMs() - start_ms});
                }

                const render_start_ms = getMonotonicMs();
                var line_buf: [1024]u8 = undefined;
                var var_expand_buf: [256]u8 = undefined;
                var tmpl_expand_buf: [512]u8 = undefined;

                var printed_rows: usize = 0;
                const RowWriter = struct {
                    fd: std.posix.fd_t,
                    total: usize,
                    count: *usize,

                    fn endRow(self: @This()) !void {
                        try term_lib.writeAll(self.fd, "\x1b[0m\x1b[K");
                        self.count.* += 1;
                        if (self.count.* < self.total) {
                            try term_lib.writeAll(self.fd, "\x1b[B\r");
                        }
                    }
                };
                const rw = RowWriter{ .fd = stdout_fd, .total = current_total_rows, .count = &printed_rows };

                if (rctx.is_hidden) {
                    try writeAll(stdout_fd, "\x1b[2K\r");
                    try rw.endRow();
                } else if (final_simple) {
                    // -------------------------------------------------------
                    // Simple (fzf/sk-style) layout: list rows, count, prompt
                    // -------------------------------------------------------
                    var si: usize = 0;
                    while (si < total_cells) : (si += 1) {
                        try writeAll(stdout_fd, "\x1b[2K\r");
                        const li = grid_scroll_top + si;
                        if (li < top_count) {
                            const entry = emojig.EmojiDb.getEntry(top_matches[li].index);
                            var strip_buf: [32]u8 = undefined;
                            const render_emoji = if (final_safe) emojig.stripVariationSelectors(entry.emoji, &strip_buf) else entry.emoji;
                            if (selected_idx != null and li == selected_idx.?) {
                                // selection_bg includes both bg and fg color sequences.
                                const row_line = try std.fmt.bufPrint(&line_buf, "{s}  > {s} {s}\x1b[0m", .{ palette.selection_bg, render_emoji, entry.name });
                                try writeAll(stdout_fd, row_line);
                            } else if (effective_idx != null and li == effective_idx.?) {
                                // Soft marker (prompt focus): caret without highlight.
                                const row_line = try std.fmt.bufPrint(&line_buf, "{s}  > {s} {s}\x1b[0m", .{ palette.grid_fg, render_emoji, entry.name });
                                try writeAll(stdout_fd, row_line);
                            } else {
                                const row_line = try std.fmt.bufPrint(&line_buf, "{s}    {s} {s}\x1b[0m", .{ palette.grid_fg, render_emoji, entry.name });
                                try writeAll(stdout_fd, row_line);
                            }
                        }
                        try rw.endRow();
                    }
                    // Count row (status_bg includes bg + fg sequences).
                    try writeAll(stdout_fd, "\x1b[2K\r");
                    var count_buf: [64]u8 = undefined;
                    const count_line = try std.fmt.bufPrint(&count_buf, "{s}  {d}/{d}\x1b[0m", .{ palette.status_bg, top_count, total_matches });
                    try writeAll(stdout_fd, count_line);
                    try rw.endRow();
                    // Prompt row (search_bg includes bg + fg sequences).
                    try writeAll(stdout_fd, "\x1b[2K\r");
                    const prompt_line = try std.fmt.bufPrint(&line_buf, "{s}> {s}\x1b[0m", .{ palette.search_bg, query_buf[0..query_len] });
                    try writeAll(stdout_fd, prompt_line);
                    try rw.endRow();
                } else {
                    // Optional top border row.
                    if (show_top_border) {
                        try writeAll(stdout_fd, "\x1b[2K\r");
                        try writeAll(stdout_fd, " ");
                        if (exit_preview and exit_preview_step >= 3) {
                            try writeAll(stdout_fd, palette.border_bg);
                            try writeAll(stdout_fd, palette.border_shade_fg);
                            const shade_str = switch (exit_preview_step) {
                                3 => "\u{2593}",
                                4 => "\u{2592}",
                                5 => "\u{2591}",
                                else => " ",
                            };
                            var i: usize = 0;
                            while (i < max_w) : (i += 1) {
                                try writeAll(stdout_fd, shade_str);
                            }
                        } else {
                            try writeAll(stdout_fd, palette.border_bg);
                            try writeAll(stdout_fd, spaces[0..@min(max_w, spaces.len)]);
                        }
                        try rw.endRow();
                    }

                    // Blank top padding row.
                    try writeAll(stdout_fd, "\x1b[2K\r");
                    try writeAll(stdout_fd, " ");
                    try writeAll(stdout_fd, palette.grid_bg);
                    try writeAll(stdout_fd, palette.grid_fg);
                    try writeAll(stdout_fd, spaces[0..@min(max_w, spaces.len)]);
                    try rw.endRow();

                    // Search bar row.
                    try writeAll(stdout_fd, "\x1b[2K\r");
                    if (exit_preview and exit_preview_step >= 3) {
                        // Preview: blank/shade the search bar row.
                        try writeAll(stdout_fd, " ");
                        try writeAll(stdout_fd, palette.grid_bg);
                        try writeAll(stdout_fd, palette.status_shade_fg);
                        const shade_str = switch (exit_preview_step) {
                            3 => "\u{2593}",
                            4 => "\u{2592}",
                            5 => "\u{2591}",
                            else => " ",
                        };
                        var i: usize = 0;
                        while (i < max_w) : (i += 1) {
                            try writeAll(stdout_fd, shade_str);
                        }
                    } else {
                        const pad_len = if (content_width > prefix_cols + icon_cols)
                            content_width - prefix_cols - icon_cols - display_query_len
                        else
                            0;

                        if (is_too_small) {
                            try writeAll(stdout_fd, " ");
                            try writeAll(stdout_fd, palette.search_bg);
                            const warn_text = "Too small";
                            const display_warn = if (warn_text.len > max_w) warn_text[0..max_w] else warn_text;
                            try writeAll(stdout_fd, display_warn);
                            const warn_pad = if (max_w > display_warn.len) max_w - display_warn.len else 0;
                            try writeAll(stdout_fd, spaces[0..@min(warn_pad, spaces.len)]);
                        } else {
                            try writeAll(stdout_fd, " ");
                            try writeAll(stdout_fd, palette.search_bg);
                            // The spec prompt carries a leading margin space; trim it
                            // since the Zig renderer emits its own margin above.
                            try writeAll(stdout_fd, std.mem.trimStart(u8, g_spec.strings.search_prompt, " "));
                            if (query_len == 0) {
                                const placeholder = g_spec.strings.search_placeholder;
                                const placeholder_cols = std.unicode.utf8CountCodepoints(placeholder) catch placeholder.len;
                                try writeAll(stdout_fd, palette.grid_fg);
                                try writeAll(stdout_fd, placeholder);
                                try writeAll(stdout_fd, palette.search_bg);
                                const ph_pad = if (pad_len >= placeholder_cols) pad_len - placeholder_cols else 0;
                                try writeAll(stdout_fd, spaces[0..@min(ph_pad, spaces.len)]);
                            } else {
                                try writeAll(stdout_fd, query_buf[query_view_start .. query_view_start + display_query_len]);
                                try writeAll(stdout_fd, spaces[0..@min(pad_len, spaces.len)]);
                            }
                            const icon_hl = if (theme_hovered) palette.selection_bg else "";
                            const icon_buf = try std.fmt.bufPrint(&line_buf, " {s}{s}{s} ", .{ icon_hl, themeIcon(theme), palette.search_bg });
                            try writeAll(stdout_fd, icon_buf);
                        }
                    }
                    try rw.endRow();

                    const is_focus_lost = !has_focus;
                    const is_help_mode = (query_len > 0 and query_buf[0] == '?');
                    if (popup_msg != null and !is_too_small) {
                        const popup_rows = rows + 3;
                        var lines = std.mem.splitScalar(u8, popup_msg.?, '\n');
                        var h_idx: usize = 0;
                        while (h_idx < popup_rows) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            var text: []const u8 = "";
                            if (h_idx == 0) {
                                text = popup_title;
                            } else if (h_idx >= 2) {
                                if (lines.next()) |line| {
                                    text = line;
                                }
                            }
                            const vis_w = ansiDisplayWidth(text);
                            const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                            const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}", .{ palette.grid_bg, palette.grid_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                            try writeAll(stdout_fd, line);
                            try rw.endRow();
                        }
                    } else if (is_focus_lost and !is_too_small) {
                        const warning_rows = rows + 3;

                        const focus_lines = if (started_unfocused) g_spec.strings.focus_lost_startup_lines else g_spec.strings.focus_lost_runtime_lines;

                        var h_idx: usize = 0;
                        while (h_idx < warning_rows) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            var text: []const u8 = "";
                            const offset = if (warning_rows >= focus_lines.len + 3) @as(usize, 2) else 0;
                            if (h_idx >= offset and h_idx - offset < focus_lines.len) {
                                text = focus_lines[h_idx - offset];
                            }
                            const vis_w = ansiDisplayWidth(text);
                            const pad_len = if (content_width > vis_w) content_width - vis_w else 0;

                            const color_fg = palette.info_fg;

                            const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}\x1b[0m", .{ palette.grid_bg, color_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                            try writeAll(stdout_fd, line);
                            try rw.endRow();
                        }
                    } else if (is_help_mode and !is_too_small) {
                        const help_rows = rows + 3;
                        const is_more = (query_len > 1 and query_buf[1] == '?');
                        var h_idx: usize = 0;
                        while (h_idx < help_rows) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            // Help text comes from spec/strings.json: "?" shows the
                            // first page, "??" the second (search filters etc.).
                            var text: []const u8 = "";
                            const help_lines = if (is_more) g_spec.strings.help_lines_more else g_spec.strings.help_lines;
                            // Vertically center when there is spare room (mirrors the
                            // former >=9 wide / >=8 narrow offset thresholds).
                            const center_threshold: usize = help_lines.len + 2;
                            const offset = if (help_rows >= center_threshold) @as(usize, 1) else 0;
                            if (h_idx >= offset and h_idx - offset < help_lines.len) {
                                text = help_lines[h_idx - offset];
                            }
                            const vis_w = ansiDisplayWidth(text);
                            const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                            const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}", .{ palette.grid_bg, palette.grid_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                            try writeAll(stdout_fd, line);
                            try rw.endRow();
                        }
                    } else if (current_screen == .help and !is_too_small) {
                        const help_lines = g_spec.strings.help_lines_more;
                        const viewport_h = rows + 3;
                        const needs_scroll = help_lines.len > viewport_h;
                        const max_scroll_h: usize = if (needs_scroll) help_lines.len - viewport_h else 0;
                        const thumb_h = if (needs_scroll) scrollbarThumb(scrollbar_style, viewport_h, help_lines.len).thumb_h else 0;
                        const travel_h = if (viewport_h > thumb_h) viewport_h - thumb_h else 0;
                        const thumb_start = if (needs_scroll and max_scroll_h > 0) help_scroll_top * travel_h / max_scroll_h else 0;
                        var h_idx: usize = 0;
                        while (h_idx < viewport_h) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            var text: []const u8 = "";
                            if (needs_scroll) {
                                const li = help_scroll_top + h_idx;
                                if (li < help_lines.len) text = help_lines[li];
                            } else {
                                const center_threshold: usize = help_lines.len + 2;
                                const offset = if (viewport_h >= center_threshold) @as(usize, 1) else 0;
                                if (h_idx >= offset and h_idx - offset < help_lines.len) text = help_lines[h_idx - offset];
                            }
                            const vis_w = ansiDisplayWidth(text);
                            const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                            const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}", .{ palette.grid_bg, palette.grid_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                            try writeAll(stdout_fd, line);
                            if (needs_scroll and content_width >= 2) {
                                // CHA to col content_width-1 (second-to-last); after writing sb,
                                // cursor lands at content_width for endRow's \x1b[K — preserving sb.
                                const sb: []const u8 = if (h_idx >= thumb_start and h_idx < thumb_start + thumb_h) "▐" else " ";
                                var sb_buf: [16]u8 = undefined;
                                const sb_seq = try std.fmt.bufPrint(&sb_buf, "\x1b[{d}G{s}", .{ content_width + 1, sb });
                                try writeAll(stdout_fd, sb_seq);
                            }
                            try rw.endRow();
                        }
                    } else if (current_screen == .about and !is_too_small) {
                        const theme_str: []const u8 = switch (theme) {
                            .dark => "dark",
                            .light => "light",
                            .system => "system",
                        };
                        const spec_vars = [_]VarSubst{
                            .{ .key = "version", .val = build_options.version },
                            .{ .key = "theme", .val = theme_str },
                        };
                        const about_frames = g_spec.strings.about_frames;
                        const cur_frame: usize = if (about_frames.len > 0) @min(anim_frame, about_frames.len - 1) else 0;
                        const about_lines = if (about_frames.len > 0) about_frames[cur_frame] else &[_][]const u8{};
                        const viewport_h = rows + 3;
                        const needs_scroll = about_lines.len > viewport_h;
                        const max_scroll_a: usize = if (needs_scroll) about_lines.len - viewport_h else 0;
                        const thumb_h = if (needs_scroll) scrollbarThumb(scrollbar_style, viewport_h, about_lines.len).thumb_h else 0;
                        const travel_a = if (viewport_h > thumb_h) viewport_h - thumb_h else 0;
                        const thumb_start = if (needs_scroll and max_scroll_a > 0) about_scroll_top * travel_a / max_scroll_a else 0;
                        var h_idx: usize = 0;
                        while (h_idx < viewport_h) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            var text: []const u8 = "";
                            if (needs_scroll) {
                                const li = about_scroll_top + h_idx;
                                if (li < about_lines.len) {
                                    const after_vars = expandVars(&var_expand_buf, about_lines[li], &spec_vars);
                                    text = expandTemplate(&tmpl_expand_buf, after_vars, &g_spec.styles, 0, "");
                                }
                            } else {
                                const center_threshold: usize = about_lines.len + 2;
                                const offset = if (viewport_h >= center_threshold) @as(usize, 1) else 0;
                                if (h_idx >= offset and h_idx - offset < about_lines.len) {
                                    const after_vars = expandVars(&var_expand_buf, about_lines[h_idx - offset], &spec_vars);
                                    text = expandTemplate(&tmpl_expand_buf, after_vars, &g_spec.styles, 0, "");
                                }
                            }
                            const vis_w = ansiDisplayWidth(text);
                            const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                            const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}", .{ palette.grid_bg, palette.grid_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                            try writeAll(stdout_fd, line);
                            if (needs_scroll and content_width >= 2) {
                                const sb: []const u8 = if (h_idx >= thumb_start and h_idx < thumb_start + thumb_h) "▐" else " ";
                                var sb_buf: [16]u8 = undefined;
                                const sb_seq = try std.fmt.bufPrint(&sb_buf, "\x1b[{d}G{s}", .{ content_width + 1, sb });
                                try writeAll(stdout_fd, sb_seq);
                            }
                            try rw.endRow();
                        }
                    } else if (current_screen == .status and !is_too_small) {
                        const theme_str: []const u8 = switch (theme) {
                            .dark => "dark",
                            .light => "light",
                            .system => "system",
                        };
                        const spec_vars = [_]VarSubst{
                            .{ .key = "shell_integration", .val = if (shell_integration) "true" else "false" },
                            .{ .key = "shell_key_binding", .val = shell_key_binding },
                            .{ .key = "show_all_categories", .val = if (show_all_categories) "true" else "false" },
                            .{ .key = "ambiguous_chars", .val = ambiguous_chars },
                            .{ .key = "update_cmd", .val = cfg.update_cmd orelse "(auto)" },
                            .{ .key = "version", .val = build_options.version },
                            .{ .key = "emojis", .val = emojis_count_str },
                            .{ .key = "shell", .val = detectShell(init.environ_map) },
                            .{ .key = "theme", .val = theme_str },
                        };
                        const status_lines = g_spec.strings.status_lines;
                        const viewport_h = rows + 3;
                        const needs_scroll = status_lines.len > viewport_h;
                        const max_scroll_s: usize = if (needs_scroll) status_lines.len - viewport_h else 0;
                        const thumb_h = if (needs_scroll) scrollbarThumb(scrollbar_style, viewport_h, status_lines.len).thumb_h else 0;
                        const travel_s = if (viewport_h > thumb_h) viewport_h - thumb_h else 0;
                        const thumb_start = if (needs_scroll and max_scroll_s > 0) status_scroll_top * travel_s / max_scroll_s else 0;
                        var h_idx: usize = 0;
                        while (h_idx < viewport_h) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            var text: []const u8 = "";
                            if (needs_scroll) {
                                const li = status_scroll_top + h_idx;
                                if (li < status_lines.len) text = expandVars(&var_expand_buf, status_lines[li], &spec_vars);
                            } else {
                                const center_threshold: usize = status_lines.len + 2;
                                const offset = if (viewport_h >= center_threshold) @as(usize, 1) else 0;
                                if (h_idx >= offset and h_idx - offset < status_lines.len) text = expandVars(&var_expand_buf, status_lines[h_idx - offset], &spec_vars);
                            }
                            const vis_w = ansiDisplayWidth(text);
                            const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                            const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}", .{ palette.grid_bg, palette.grid_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                            try writeAll(stdout_fd, line);
                            if (needs_scroll and content_width >= 2) {
                                const sb: []const u8 = if (h_idx >= thumb_start and h_idx < thumb_start + thumb_h) "▐" else " ";
                                var sb_buf: [16]u8 = undefined;
                                const sb_seq = try std.fmt.bufPrint(&sb_buf, "\x1b[{d}G{s}", .{ content_width + 1, sb });
                                try writeAll(stdout_fd, sb_seq);
                            }
                            try rw.endRow();
                        }
                    } else if (current_screen == .settings and !is_too_small) {
                        const settings_rows = rows + 4;
                        var h_idx: usize = 0;
                        while (h_idx < settings_rows) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            var text: []const u8 = "";
                            var custom_rendered = false;

                            if (h_idx == 0) {
                                // Empty line on top
                                custom_rendered = true;
                            } else if (h_idx == 1) {
                                text = "⚙️ emojig settings";
                            } else if (h_idx == 2) {
                                // Empty separator row
                                custom_rendered = true;
                            } else if (h_idx >= 3 and h_idx - 3 < rows) {
                                const slot_idx = h_idx - 3;
                                const opt_idx = settings_scroll_top + slot_idx;
                                if (opt_idx < settings_count) {
                                    const is_sel = (selected_idx != null and selected_idx.? == opt_idx);
                                    const row = try renderSettingRow(&line_buf, opt_idx, is_sel, shell_integration, shell_key_binding, keybind_editing, show_all_categories, ambiguous_chars, theme, scrollbar_style, grid_cols, grid_rows, griddim_hover_left, griddim_hover_right, palette);
                                    try writeAll(stdout_fd, row);
                                    const vis_w = ansiDisplayWidth(row);
                                    const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                                    try writeAll(stdout_fd, spaces[0..@min(pad_len, spaces.len)]);
                                    custom_rendered = true;
                                }
                            }

                            if (!custom_rendered) {
                                const vis_w = ansiDisplayWidth(text);
                                const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                                const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}", .{ palette.grid_bg, palette.grid_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                                try writeAll(stdout_fd, line);
                            }
                            try rw.endRow();
                        }
                    } else if (current_screen == .categories and !is_too_small) {
                        const cats_rows = rows + 4;
                        var h_idx: usize = 0;
                        while (h_idx < cats_rows) : (h_idx += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            var text: []const u8 = "";
                            var custom_rendered = false;

                            if (h_idx == 0) {
                                // Empty line on top
                                custom_rendered = true;
                            } else if (h_idx == 1) {
                                text = "📁 emojig categories";
                            } else if (h_idx == 2) {
                                // Empty separator row
                                custom_rendered = true;
                            } else if (h_idx >= 3 and h_idx - 3 < rows) {
                                const slot_idx = h_idx - 3;
                                const cat_idx = cat_scroll_top + slot_idx;
                                if (cat_idx < g_spec.categories.categories.len) {
                                    const is_sel = (selected_idx != null and selected_idx.? == cat_idx);
                                    const cat = g_spec.categories.categories[cat_idx];
                                    const is_enabled = !disabled_cats[cat_idx];

                                    const bg = if (is_sel) palette.selection_bg else palette.grid_bg;
                                    const sel_prefix = if (is_sel) "> " else "  ";
                                    const cb = if (is_enabled) "✔" else " ";

                                    const row = try std.fmt.bufPrint(&line_buf, " {s}{s}[{s}] {s}\x1b[0m", .{ bg, sel_prefix, cb, cat.name });
                                    try writeAll(stdout_fd, row);
                                    const vis_w = ansiDisplayWidth(row);
                                    const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                                    try writeAll(stdout_fd, spaces[0..@min(pad_len, spaces.len)]);
                                    custom_rendered = true;
                                }
                            }

                            if (!custom_rendered) {
                                const vis_w = ansiDisplayWidth(text);
                                const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                                const line = try std.fmt.bufPrint(&line_buf, " {s}{s}{s}{s}", .{ palette.grid_bg, palette.grid_fg, text, spaces[0..@min(pad_len, spaces.len)] });
                                try writeAll(stdout_fd, line);
                            }
                            try rw.endRow();
                        }
                    } else {
                        // Blank spacer row.
                        try writeAll(stdout_fd, "\x1b[2K\r");
                        try writeAll(stdout_fd, " ");
                        try writeAll(stdout_fd, palette.grid_bg);
                        try writeAll(stdout_fd, palette.grid_fg);
                        try writeAll(stdout_fd, spaces[0..@min(max_w, spaces.len)]);
                        try rw.endRow();

                        // Grid rows.
                        // Grid scrollbar geometry (only for the genuine emoji grid,
                        // when the result set spans more rows than the viewport).
                        const grid_total_rows = (top_count + cols - 1) / cols;
                        const grid_needs_scroll = !is_cmd_autocomplete and !is_cat_autocomplete and
                            !is_too_small and !exit_preview and grid_total_rows > rows;
                        const grid_tg = scrollbarThumb(scrollbar_style, rows, grid_total_rows);
                        const grid_max_scroll: usize = if (grid_total_rows > rows) grid_total_rows - rows else 0;
                        const grid_thumb_start: usize = if (grid_needs_scroll and grid_max_scroll > 0)
                            grid_scroll_top * grid_tg.travel / grid_max_scroll
                        else
                            0;

                        // Checkcell highlight used for picked cells when the
                        // multi-select mark glyph is disabled (mark == "").
                        var check_bg_buf: [16]u8 = undefined;
                        const check_bg = bgEscape(&check_bg_buf, g_spec.strings.multi_select_bg);

                        var r: usize = 0;
                        while (r < rows) : (r += 1) {
                            try writeAll(stdout_fd, "\x1b[2K\r");
                            if (is_too_small) {
                                const grid_line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.grid_bg, spaces[0..@min(max_w, spaces.len)] });
                                try writeAll(stdout_fd, grid_line);
                            } else if (is_cmd_autocomplete) {
                                var custom_rendered = false;
                                if (r < cmd_match_count) {
                                    const cmd_idx = cmd_matches[r];
                                    const cmd = g_spec.commands.commands[cmd_idx];
                                    const is_sel = (selected_idx != null and selected_idx.? == r);
                                    const bg = if (is_sel) palette.selection_bg else palette.grid_bg;
                                    const sel_prefix = if (is_sel) "> " else "  ";
                                    const row = try std.fmt.bufPrint(&line_buf, " {s}{s}{c}{s} - {s}\x1b[0m", .{ bg, sel_prefix, cmd_prefix, cmd.name, cmd.action });
                                    try writeAll(stdout_fd, row);
                                    const vis_w = ansiDisplayWidth(row);
                                    const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                                    try writeAll(stdout_fd, spaces[0..@min(pad_len, spaces.len)]);
                                    custom_rendered = true;
                                }
                                if (!custom_rendered) {
                                    const line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.grid_bg, spaces[0..@min(content_width, spaces.len)] });
                                    try writeAll(stdout_fd, line);
                                }
                            } else if (is_cat_autocomplete) {
                                var custom_rendered = false;
                                if (r < cat_match_count) {
                                    const cat_idx = cat_matches[r];
                                    const cat = g_spec.categories.categories[cat_idx];
                                    const is_sel = (selected_idx != null and selected_idx.? == r);
                                    const bg = if (is_sel) palette.selection_bg else palette.grid_bg;
                                    const sel_prefix = if (is_sel) "> " else "  ";

                                    var syn_buf: [128]u8 = undefined;
                                    var syn_len: usize = 0;
                                    for (cat.synonyms, 0..) |syn, s_i| {
                                        if (s_i > 0) {
                                            syn_buf[syn_len] = ',';
                                            syn_buf[syn_len + 1] = ' ';
                                            syn_len += 2;
                                        }
                                        const copy_len = @min(syn.len, syn_buf.len - syn_len);
                                        @memcpy(syn_buf[syn_len..][0..copy_len], syn[0..copy_len]);
                                        syn_len += copy_len;
                                    }
                                    const row = try std.fmt.bufPrint(&line_buf, " {s}{s}c:{s} ({s})\x1b[0m", .{ bg, sel_prefix, cat.name, syn_buf[0..syn_len] });
                                    try writeAll(stdout_fd, row);
                                    const vis_w = ansiDisplayWidth(row);
                                    const pad_len = if (content_width > vis_w) content_width - vis_w else 0;
                                    try writeAll(stdout_fd, spaces[0..@min(pad_len, spaces.len)]);
                                    custom_rendered = true;
                                }
                                if (!custom_rendered) {
                                    const line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.grid_bg, spaces[0..@min(content_width, spaces.len)] });
                                    try writeAll(stdout_fd, line);
                                }
                            } else if (exit_preview) {
                                // Preview frame: show only the selected cell as plain " emoji ",
                                // all other cells blank ("    ").
                                var cell_buffers: [defaults.MAX_COLS][64]u8 = undefined;
                                var cell_strings: [defaults.MAX_COLS][]const u8 = undefined;
                                var c: usize = 0;
                                while (c < cols) : (c += 1) {
                                    const idx = (grid_scroll_top + r) * cols + c;
                                    if (selected_idx) |sel| {
                                        if (idx == sel and idx < top_count) {
                                            const m = top_matches[idx];
                                            const entry = emojig.EmojiDb.getEntry(m.index);
                                            var strip_buf: [32]u8 = undefined;
                                            const render_emoji = if (final_safe) emojig.stripVariationSelectors(entry.emoji, &strip_buf) else entry.emoji;
                                            if (emojig.getEmojiWidth(render_emoji) == 1) {
                                                cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s}  ", .{render_emoji});
                                            } else {
                                                cell_strings[c] = try std.fmt.bufPrint(&cell_buffers[c], " {s} ", .{render_emoji});
                                            }
                                        } else {
                                            cell_strings[c] = "    ";
                                        }
                                    } else {
                                        cell_strings[c] = "    ";
                                    }
                                }
                                var gl_pos: usize = 0;
                                for ([_][]const u8{ " ", palette.grid_bg, palette.grid_fg }) |s| {
                                    @memcpy(line_buf[gl_pos..][0..s.len], s);
                                    gl_pos += s.len;
                                }
                                c = 0;
                                while (c < cols) : (c += 1) {
                                    const cs = cell_strings[c];
                                    @memcpy(line_buf[gl_pos..][0..cs.len], cs);
                                    gl_pos += cs.len;
                                }
                                const grid_rem = if (content_width > cols * 4) content_width - cols * 4 else 0;
                                const rem_sp = spaces[0..@min(grid_rem, spaces.len)];
                                @memcpy(line_buf[gl_pos..][0..rem_sp.len], rem_sp);
                                gl_pos += rem_sp.len;
                                try writeAll(stdout_fd, line_buf[0..gl_pos]);
                            } else if (fast_render) {
                                // Blank cells: background + spaces only, no emoji glyphs.
                                // foot can paint this instantly (nothing to rasterize).
                                // The scrollbar thumb is still written so drag position
                                // tracks live; emojis fill in on the next full render.
                                var gl_pos: usize = 0;
                                for ([_][]const u8{ " ", palette.grid_bg, palette.grid_fg }) |s| {
                                    @memcpy(line_buf[gl_pos..][0..s.len], s);
                                    gl_pos += s.len;
                                }
                                const blank_len = @min(content_width, spaces.len);
                                @memcpy(line_buf[gl_pos..][0..blank_len], spaces[0..blank_len]);
                                gl_pos += blank_len;
                                try writeAll(stdout_fd, line_buf[0..gl_pos]);
                                if (grid_needs_scroll and content_width >= 2) {
                                    const on_thumb = r >= grid_thumb_start and r < grid_thumb_start + grid_tg.thumb_h;
                                    const sb: []const u8 = if (on_thumb) "▐" else " ";
                                    var sb_buf: [16]u8 = undefined;
                                    const sb_seq = try std.fmt.bufPrint(&sb_buf, "\x1b[{d}G{s}", .{ content_width + 1, sb });
                                    try writeAll(stdout_fd, sb_seq);
                                }
                            } else {
                                var cell_buffers: [defaults.MAX_COLS][64]u8 = undefined;
                                var cell_strings: [defaults.MAX_COLS][]const u8 = undefined;

                                var c: usize = 0;
                                while (c < cols) : (c += 1) {
                                    const idx = (grid_scroll_top + r) * cols + c;
                                    if (idx < top_count) {
                                        const m = top_matches[idx];
                                        const entry = emojig.EmojiDb.getEntry(m.index);
                                        var strip_buf: [32]u8 = undefined;
                                        const render_emoji = if (final_safe) emojig.stripVariationSelectors(entry.emoji, &strip_buf) else entry.emoji;

                                        var is_selected_in_multi = false;
                                        if (multi_select_active) {
                                            for (multi_selected_emojis.items) |e| {
                                                if (std.mem.eql(u8, e, entry.emoji)) {
                                                    is_selected_in_multi = true;
                                                    break;
                                                }
                                            }
                                        }

                                        // Hard selection (grid focus) draws the highlight; the
                                        // soft marker (prompt focus, first hit) only draws brackets.
                                        const is_hard = (selected_idx != null and idx == selected_idx.?);
                                        const is_marker = is_hard or (effective_idx != null and idx == effective_idx.?);
                                        const w1 = emojig.getEmojiWidth(render_emoji) == 1;
                                        const mark = g_spec.strings.multi_select_mark;
                                        const use_mark = mark.len > 0;
                                        const cl = g_spec.strings.cursor_left;
                                        const cr = g_spec.strings.cursor_right;

                                        if (is_hard) {
                                            if (is_selected_in_multi and use_mark) {
                                                // Picked + cursor: swap the opening bracket for the
                                                // mark, keep the closing bracket — full 4 cols.
                                                cell_strings[c] = if (w1)
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s}{s}{s} {s}\x1b[0m{s}{s}", .{ palette.selection_bg, mark, render_emoji, cr, palette.grid_bg, palette.grid_fg })
                                                else
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s}{s}{s}{s}\x1b[0m{s}{s}", .{ palette.selection_bg, mark, render_emoji, cr, palette.grid_bg, palette.grid_fg });
                                            } else {
                                                // Cursor box. If also picked (mark disabled), tint it
                                                // with the checkcell highlight instead of selection_bg.
                                                const box_bg = if (is_selected_in_multi) check_bg else palette.selection_bg;
                                                cell_strings[c] = if (w1)
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s}{s}{s} {s}\x1b[0m{s}{s}", .{ box_bg, cl, render_emoji, cr, palette.grid_bg, palette.grid_fg })
                                                else
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s}{s}{s}{s}\x1b[0m{s}{s}", .{ box_bg, cl, render_emoji, cr, palette.grid_bg, palette.grid_fg });
                                            }
                                        } else if (is_marker) {
                                            // Soft marker: brackets in grid colors, no highlight.
                                            cell_strings[c] = if (w1)
                                                try std.fmt.bufPrint(&cell_buffers[c], "{s}{s} {s}", .{ cl, render_emoji, cr })
                                            else
                                                try std.fmt.bufPrint(&cell_buffers[c], "{s}{s}{s}", .{ cl, render_emoji, cr });
                                        } else if (is_selected_in_multi) {
                                            cell_strings[c] = if (use_mark)
                                                (if (w1)
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s}{s}  ", .{ mark, render_emoji })
                                                else
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s}{s} ", .{ mark, render_emoji }))
                                            else
                                                // No mark: highlight the whole cell with checkcell bg.
                                                (if (w1)
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s} {s}  \x1b[0m{s}{s}", .{ check_bg, render_emoji, palette.grid_bg, palette.grid_fg })
                                                else
                                                    try std.fmt.bufPrint(&cell_buffers[c], "{s} {s} \x1b[0m{s}{s}", .{ check_bg, render_emoji, palette.grid_bg, palette.grid_fg }));
                                        } else {
                                            cell_strings[c] = if (w1)
                                                try std.fmt.bufPrint(&cell_buffers[c], " {s}  ", .{render_emoji})
                                            else
                                                try std.fmt.bufPrint(&cell_buffers[c], " {s} ", .{render_emoji});
                                        }
                                    } else {
                                        cell_strings[c] = "    ";
                                    }
                                }

                                var gl_pos: usize = 0;
                                for ([_][]const u8{ " ", palette.grid_bg, palette.grid_fg }) |s| {
                                    @memcpy(line_buf[gl_pos..][0..s.len], s);
                                    gl_pos += s.len;
                                }
                                c = 0;
                                while (c < cols) : (c += 1) {
                                    const cs = cell_strings[c];
                                    @memcpy(line_buf[gl_pos..][0..cs.len], cs);
                                    gl_pos += cs.len;
                                }
                                const grid_rem = if (content_width > cols * 4) content_width - cols * 4 else 0;
                                const rem_sp = spaces[0..@min(grid_rem, spaces.len)];
                                @memcpy(line_buf[gl_pos..][0..rem_sp.len], rem_sp);
                                gl_pos += rem_sp.len;
                                try writeAll(stdout_fd, line_buf[0..gl_pos]);
                                if (grid_needs_scroll and content_width >= 2) {
                                    const on_thumb = r >= grid_thumb_start and r < grid_thumb_start + grid_tg.thumb_h;
                                    const sb: []const u8 = if (on_thumb) "▐" else " ";
                                    var sb_buf: [16]u8 = undefined;
                                    const sb_seq = try std.fmt.bufPrint(&sb_buf, "\x1b[{d}G{s}", .{ content_width + 1, sb });
                                    try writeAll(stdout_fd, sb_seq);
                                }
                            }
                            try rw.endRow();
                        }

                        // Spacer row between grid and description.
                        try writeAll(stdout_fd, "\x1b[2K\r");
                        try writeAll(stdout_fd, " ");
                        try writeAll(stdout_fd, palette.grid_bg);
                        try writeAll(stdout_fd, palette.grid_fg);
                        try writeAll(stdout_fd, spaces[0..@min(max_w, spaces.len)]);
                        try rw.endRow();

                        // Description row.
                        try writeAll(stdout_fd, "\x1b[2K\r");
                        const max_len = if (content_width > 1) content_width - 1 else 0;
                        if ((exit_preview and exit_preview_step >= 3) or (selected_idx == null) or is_too_small) {
                            const pad_len_desc = max_w;
                            const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.info_bg, spaces[0..@min(pad_len_desc, spaces.len)] });
                            try writeAll(stdout_fd, name_line);
                        } else if (is_cmd_autocomplete) {
                            const sel = selected_idx.?;
                            if (sel < cmd_match_count) {
                                const cmd_idx = cmd_matches[sel];
                                const cmd = g_spec.commands.commands[cmd_idx];
                                var desc_buf: [128]u8 = undefined;
                                const desc = try std.fmt.bufPrint(&desc_buf, "Command: {c}{s} -> {s}", .{ cmd_prefix, cmd.name, cmd.action });
                                const pad_len_desc = if (content_width > desc.len + 1) content_width - desc.len - 1 else 0;
                                const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}{s}", .{ palette.info_bg, palette.info_fg, desc, spaces[0..@min(pad_len_desc, spaces.len)] });
                                try writeAll(stdout_fd, name_line);
                            } else {
                                const pad_len_desc = max_w;
                                const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.info_bg, spaces[0..@min(pad_len_desc, spaces.len)] });
                                try writeAll(stdout_fd, name_line);
                            }
                        } else if (is_cat_autocomplete) {
                            const sel = selected_idx.?;
                            if (sel < cat_match_count) {
                                const cat_idx = cat_matches[sel];
                                const cat = g_spec.categories.categories[cat_idx];
                                var syn_buf: [128]u8 = undefined;
                                var syn_len: usize = 0;
                                for (cat.synonyms, 0..) |syn, s_i| {
                                    if (s_i > 0) {
                                        syn_buf[syn_len] = ',';
                                        syn_buf[syn_len + 1] = ' ';
                                        syn_len += 2;
                                    }
                                    const copy_len = @min(syn.len, syn_buf.len - syn_len);
                                    @memcpy(syn_buf[syn_len..][0..copy_len], syn[0..copy_len]);
                                    syn_len += copy_len;
                                }
                                var desc_buf: [256]u8 = undefined;
                                const desc = try std.fmt.bufPrint(&desc_buf, "Category: {s} ({s})", .{ cat.name, syn_buf[0..syn_len] });
                                const pad_len_desc = if (content_width > desc.len + 1) content_width - desc.len - 1 else 0;
                                const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}{s}", .{ palette.info_bg, palette.info_fg, desc, spaces[0..@min(pad_len_desc, spaces.len)] });
                                try writeAll(stdout_fd, name_line);
                            } else {
                                const pad_len_desc = max_w;
                                const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.info_bg, spaces[0..@min(pad_len_desc, spaces.len)] });
                                try writeAll(stdout_fd, name_line);
                            }
                        } else if (effective_idx != null and !is_too_small) {
                            const sel = effective_idx.?;
                            if (top_count > 0 and sel < top_count) {
                                const db_entry = emojig.EmojiDb.getEntry(top_matches[sel].index);
                                const name = db_entry.name;
                                const search_str = db_entry.search;

                                // Derive extra tags: words in search not present as words in name.
                                // Pad name with spaces so word boundary checks are simple indexOf.
                                var name_pad_buf: [130]u8 = undefined;
                                name_pad_buf[0] = ' ';
                                const name_pad_len = blk: {
                                    var i: usize = 0;
                                    while (i < name.len and i + 1 < name_pad_buf.len - 1) : (i += 1) {
                                        name_pad_buf[i + 1] = std.ascii.toLower(name[i]);
                                    }
                                    name_pad_buf[i + 1] = ' ';
                                    break :blk i + 2;
                                };
                                const name_padded = name_pad_buf[0..name_pad_len];

                                var tags_buf: [80]u8 = undefined;
                                var tags_len: usize = 0;
                                var sit = std.mem.splitScalar(u8, search_str, ' ');
                                while (sit.next()) |word| {
                                    if (word.len == 0 or word.len + 2 > 66) continue;
                                    var wpad: [66]u8 = undefined;
                                    wpad[0] = ' ';
                                    @memcpy(wpad[1..][0..word.len], word);
                                    wpad[1 + word.len] = ' ';
                                    if (std.mem.indexOf(u8, name_padded, wpad[0 .. word.len + 2]) != null) continue;
                                    if (tags_len + word.len + 1 > tags_buf.len) break;
                                    if (tags_len > 0) {
                                        tags_buf[tags_len] = ' ';
                                        tags_len += 1;
                                    }
                                    @memcpy(tags_buf[tags_len..][0..word.len], word);
                                    tags_len += word.len;
                                }
                                const tags = tags_buf[0..tags_len];
                                const shade = palette.status_shade_fg;

                                // Total visible columns: 1 (leading space) + name + optional "  tags"
                                const suffix_cols = if (tags_len > 0) 2 + tags_len else 0;
                                const full_cols = 1 + name.len + suffix_cols;
                                if (full_cols > max_len) {
                                    if (max_len >= 4 and 1 + name.len > max_len -| 3) {
                                        // Name itself overflows — truncate with "..."
                                        const trunc = max_len -| 4;
                                        const display_name = name[0..@min(trunc, name.len)];
                                        const printed_cols = 1 + display_name.len + 3;
                                        const pad_len_desc = if (content_width > printed_cols) content_width - printed_cols else 0;
                                        const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}...{s}", .{ palette.info_bg, palette.info_fg, display_name, spaces[0..@min(pad_len_desc, spaces.len)] });
                                        try writeAll(stdout_fd, name_line);
                                    } else {
                                        // Name fits but tags overflow — drop tags, show name only
                                        const printed_cols = 1 + name.len;
                                        const pad_len_desc = if (content_width > printed_cols) content_width - printed_cols else 0;
                                        const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}{s}", .{ palette.info_bg, palette.info_fg, name, spaces[0..@min(pad_len_desc, spaces.len)] });
                                        try writeAll(stdout_fd, name_line);
                                    }
                                } else if (tags_len > 0) {
                                    const printed_cols = full_cols;
                                    const pad_len_desc = if (content_width > printed_cols) content_width - printed_cols else 0;
                                    const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}  {s}{s}{s}{s}", .{ palette.info_bg, palette.info_fg, name, shade, tags, palette.info_fg, spaces[0..@min(pad_len_desc, spaces.len)] });
                                    try writeAll(stdout_fd, name_line);
                                } else {
                                    const printed_cols = 1 + name.len;
                                    const pad_len_desc = if (content_width > printed_cols) content_width - printed_cols else 0;
                                    const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}{s}", .{ palette.info_bg, palette.info_fg, name, spaces[0..@min(pad_len_desc, spaces.len)] });
                                    try writeAll(stdout_fd, name_line);
                                }
                            } else {
                                const pad_len_desc = max_w;
                                const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.info_bg, spaces[0..@min(pad_len_desc, spaces.len)] });
                                try writeAll(stdout_fd, name_line);
                            }
                        } else {
                            const pad_len_desc = max_w;
                            const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s}", .{ palette.info_bg, spaces[0..@min(pad_len_desc, spaces.len)] });
                            try writeAll(stdout_fd, name_line);
                        }
                        try rw.endRow();
                    }

                    // Status bar row.
                    try writeAll(stdout_fd, "\x1b[2K\r");
                    if ((exit_preview and exit_preview_step >= 3) or is_too_small) {
                        try writeAll(stdout_fd, " ");
                        try writeAll(stdout_fd, palette.grid_bg);
                        if (exit_preview and exit_preview_step >= 3) {
                            try writeAll(stdout_fd, palette.status_shade_fg);
                            const shade_str = switch (exit_preview_step) {
                                3 => "\u{2593}",
                                4 => "\u{2592}",
                                5 => "\u{2591}",
                                else => " ",
                            };
                            var i: usize = 0;
                            while (i < max_w) : (i += 1) {
                                try writeAll(stdout_fd, shade_str);
                            }
                        } else {
                            try writeAll(stdout_fd, spaces[0..@min(max_w, spaces.len)]);
                        }
                    } else {
                        try writeAll(stdout_fd, " ");
                        try writeAll(stdout_fd, palette.status_bg);

                        var status_text_buf: [512]u8 = undefined;
                        const status_text = blk: {
                            const st = &g_spec.strings.status;
                            if (popup_msg != null) {
                                break :blk st.popup.default;
                            } else if (current_screen == .help) {
                                const vph = rows + 3;
                                break :blk if (g_spec.strings.help_lines_more.len > vph) st.view.scrollable else st.view.default;
                            } else if (current_screen == .about) {
                                const vph = rows + 3;
                                const abl = if (g_spec.strings.about_frames.len > 0) g_spec.strings.about_frames[0].len else 0;
                                break :blk if (abl > vph) st.view.about_scrollable else st.view.about;
                            } else if (current_screen == .status) {
                                const vph = rows + 3;
                                break :blk if (g_spec.strings.status_lines.len > vph) st.view.scrollable else st.view.default;
                            } else if (current_screen == .settings and keybind_editing) {
                                break :blk st.settings.keybind;
                            } else if (current_screen == .settings and selected_idx != null and
                                (selected_idx.? == 6 or selected_idx.? == 7))
                            {
                                // Grid-size row: show the controls and (once edited)
                                // the "applies on next launch" note, instead of a
                                // popup on every step.
                                const lbl = if (selected_idx.? == 6) "width" else "height";
                                const val = if (selected_idx.? == 6) grid_cols else grid_rows;
                                break :blk if (griddim_changed)
                                    std.fmt.bufPrint(&status_text_buf, " grid {s} {d}  \u{2039}\u{203a}/0-9/Bksp ?:help · next launch", .{ lbl, val }) catch st.settings.navigate
                                else
                                    std.fmt.bufPrint(&status_text_buf, " grid {s} {d}  \u{2039} \u{203a}/0-9 ?:help · Esc:back", .{ lbl, val }) catch st.settings.navigate;
                            } else if (current_screen == .settings) {
                                break :blk st.settings.navigate;
                            } else if (current_screen == .categories) {
                                break :blk st.categories.navigate;
                            } else if (is_cmd_autocomplete) {
                                break :blk st.commands.navigate;
                            } else if (is_cat_autocomplete) {
                                break :blk st.cat_filter.navigate;
                            } else {
                                // On a wide layout with the grid focused (cursor on a
                                // cell, not yet in multi-select), advertise that Space
                                // starts multi-select. Narrow layouts keep the concise
                                // status — the help screen documents Space there.
                                const grid_focus = selected_idx != null and !multi_select_active;
                                const status_tmpl: []const u8 = if (content_width >= 35)
                                    (if (grid_focus) st.default.on_grid_wide else if (query_len == 0) st.default.on_view_wide else st.default.on_search_wide)
                                else
                                    (if (query_len == 0) st.default.on_view else st.default.on_search);
                                const base_status = try formatStatus(&status_text_buf, status_tmpl, total_matches);
                                if (multi_select_active) {
                                    const n_sel = multi_selected_emojis.items.len;
                                    if (selected_idx) |sel| {
                                        if (sel < top_count) {
                                            const entry = emojig.EmojiDb.getEntry(top_matches[sel].index);
                                            var on_sel = false;
                                            for (multi_selected_emojis.items) |e| {
                                                if (std.mem.eql(u8, e, entry.emoji)) {
                                                    on_sel = true;
                                                    break;
                                                }
                                            }
                                            const tmpl = if (on_sel) st.multi_select.on_done else st.multi_select.on_add;
                                            break :blk expandTemplate(&status_text_buf, tmpl, &g_spec.styles, n_sel, palette.search_bg);
                                        }
                                    }
                                    break :blk expandTemplate(&status_text_buf, st.multi_select.no_cursor, &g_spec.styles, n_sel, palette.search_bg);
                                } else {
                                    break :blk base_status;
                                }
                            }
                        };

                        const text_cols = ansiDisplayWidth(status_text);

                        try writeAll(stdout_fd, status_text);

                        const pad_len_status = if (content_width > text_cols) content_width - text_cols else 0;
                        try writeAll(stdout_fd, spaces[0..@min(pad_len_status, spaces.len)]);
                    }
                    try rw.endRow();

                    // Optional bottom border row.
                    if (show_bottom_border) {
                        try writeAll(stdout_fd, "\x1b[2K\r");
                        try writeAll(stdout_fd, " ");
                        if (exit_preview and exit_preview_step >= 3) {
                            try writeAll(stdout_fd, palette.border_bg);
                            try writeAll(stdout_fd, palette.border_shade_fg);
                            const shade_str = switch (exit_preview_step) {
                                3 => "\u{2593}",
                                4 => "\u{2592}",
                                5 => "\u{2591}",
                                else => " ",
                            };
                            var i: usize = 0;
                            while (i < max_w) : (i += 1) {
                                try writeAll(stdout_fd, shade_str);
                            }
                        } else {
                            try writeAll(stdout_fd, palette.border_bg);
                            try writeAll(stdout_fd, spaces[0..@min(max_w, spaces.len)]);
                        }
                        try rw.endRow();
                    }

                    // Debug info rows.
                    if (show_debug) {
                        try writeAll(stdout_fd, "\x1b[2K\r");
                        const line1 = " 🐞 Debug Info:";
                        const pad1 = if (current_w >= 16) current_w - 16 else 0;
                        try writeAll(stdout_fd, line1);
                        try writeAll(stdout_fd, spaces[0..@min(pad1, spaces.len)]);
                        try rw.endRow();

                        try writeAll(stdout_fd, "\x1b[2K\r");
                        var dbg_buf: [128]u8 = undefined;
                        const line2 = try std.fmt.bufPrint(&dbg_buf, "    Size: W={d} H={d}", .{ current_w, current_h });
                        const pad2 = if (current_w > line2.len + 1) current_w - 1 - line2.len else 0;
                        try writeAll(stdout_fd, line2);
                        try writeAll(stdout_fd, spaces[0..@min(pad2, spaces.len)]);
                        try rw.endRow();
                    }
                }

                last_drawn_h = current_total_rows;
                global_tui_height = last_drawn_h;
                const render_ms = getMonotonicMs() - render_start_ms;
                if (render_ms > 20) term_lib.appendLog("render_slow ms={d} scroll={d}", .{ render_ms, grid_scroll_top });
                const cur_rss = term_lib.readRssBytes();
                if (cur_rss > last_rss_bytes + 512 * 1024) {
                    term_lib.appendLog("rss_jump +{d}KB -> {d:.2}MB session_ms={d}", .{ (cur_rss - last_rss_bytes) / 1024, @as(f64, @floatFromInt(cur_rss)) / (1024.0 * 1024.0), getMonotonicMs() - start_ms });
                    last_rss_bytes = cur_rss;
                }

                // Reposition cursor to the search bar column.
                if (rctx.repositionCursor()) {
                    var cursor_buf: [64]u8 = undefined;
                    const cursor_up = if (current_total_rows >= @as(usize, @intCast(2 + row_off)))
                        current_total_rows - @as(usize, @intCast(2 + row_off))
                    else
                        @as(usize, 0);

                    const cursor_seq: []const u8 = if (exit_preview or should_copy_and_exit) blk: {
                        // Exit or preview: hide cursor and leave it at the bottom
                        break :blk "\x1b[?25l";
                    } else if (current_screen != .search) blk: {
                        // Non-search screen: park at the search bar (row 2 + row_off) but hide cursor
                        if (cursor_up > 0) {
                            break :blk try std.fmt.bufPrint(&cursor_buf, "\x1b[{d}A\x1b[{d}G\x1b[?25l", .{ cursor_up, 5 + cursor_col_off });
                        } else {
                            break :blk try std.fmt.bufPrint(&cursor_buf, "\x1b[{d}G\x1b[?25l", .{5 + cursor_col_off});
                        }
                    } else if (final_simple) blk: {
                        // Simple mode: prompt is already the last row; just position cursor after "> ".
                        break :blk try std.fmt.bufPrint(&cursor_buf, "\x1b[{d}G\x1b[?12h\x1b[?25h", .{3 + cursor_col_off});
                    } else if (is_too_small) blk: {
                        if (cursor_up > 0) {
                            break :blk try std.fmt.bufPrint(&cursor_buf, "\x1b[{d}A\x1b[1G\x1b[?25l", .{cursor_up});
                        } else {
                            break :blk "\x1b[1G\x1b[?25l";
                        }
                    } else blk: {
                        // Normal full TUI: move up, position cursor, enable blink.
                        if (cursor_up > 0) {
                            break :blk try std.fmt.bufPrint(&cursor_buf, "\x1b[{d}A\x1b[{d}G\x1b[?12h\x1b[?25h", .{ cursor_up, 5 + cursor_col_off });
                        } else {
                            break :blk try std.fmt.bufPrint(&cursor_buf, "\x1b[{d}G\x1b[?12h\x1b[?25h", .{5 + cursor_col_off});
                        }
                    };
                    try writeAll(stdout_fd, cursor_seq);
                }

                rctx.was_hidden = rctx.is_hidden;
            }

            // ----------------------------------------------------------------
            // Copy & exit deferred action (rendered one frame first)
            // ----------------------------------------------------------------
            if (should_copy_and_exit) {
                if (exit_preview) {
                    // Preview frame has been rendered; sleep then exit.
                    if (preview_hold_ns > 0) {
                        const step_ns = preview_hold_ns / max_preview_steps;
                        const hold_ts = std.posix.system.timespec{
                            .sec = @intCast(step_ns / std.time.ns_per_s),
                            .nsec = @intCast(step_ns % std.time.ns_per_s),
                        };
                        _ = std.posix.system.nanosleep(&hold_ts, null);
                    }
                    exit_preview_step += 1;
                    if (exit_preview_step < max_preview_steps) {
                        continue;
                    }
                    break;
                }

                if (multi_select_active) {
                    for (multi_selected_emojis.items) |e| {
                        mru.save(e);
                    }
                    if (result_emoji == null and multi_selected_emojis.items.len > 0) {
                        result_emoji = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                    }
                    break;
                }
                // First pass: copy + MRU, then either show preview or exit.
                const sel_idx = selected_idx orelse if (top_count > 0) @as(usize, 0) else null;
                if (sel_idx) |sel| {
                    if (sel < top_count) {
                        const selected = emojig.EmojiDb.getEntry(top_matches[sel].index);
                        mru.save(selected.emoji);
                        result_emoji = if (final_safe)
                            emojig.stripVariationSelectors(selected.emoji, &result_safe_buf)
                        else
                            selected.emoji;
                        copyToClipboard(init, selected.emoji, final_safe) catch {};
                        term_lib.appendLog("copy emoji={s} name=\"{s}\" q=\"{s}\" session_ms={d}", .{ selected.emoji, selected.name, query_buf[0..query_len], getMonotonicMs() - start_ms });

                        // Decide whether to show exit preview frame.
                        if (preview_enabled and !is_too_small and top_count > 0) {
                            // Ensure selected_idx is set to the confirmed cell for the preview render.
                            selected_idx = sel;
                            exit_preview = true;
                            continue;
                        }
                    }
                }
                break;
            }

            // ----------------------------------------------------------------
            // Poll for input: block on both /dev/tty and the signal self-pipe.
            // The timeout implements EMOJIG_PICKER_TIMEOUT without alarm(2).
            // For animation, shorten the timeout to the next frame deadline.
            // ----------------------------------------------------------------
            var timeout_ms: i32 = if (active_timeout) |t_sec| blk: {
                const deadline = last_input_ms + @as(i64, t_sec) * 1_000;
                const remaining = deadline - getMonotonicMs();
                break :blk if (remaining <= 0) 0 else @intCast(@min(remaining, 2_147_000));
            } else -1;

            // Shorten timeout for animation frame advance.
            if (current_screen == .about and !anim_done) {
                const now_ms = getMonotonicMs();
                const remaining = anim_timer - now_ms;
                const anim_ms: i32 = if (remaining <= 0) 0 else @intCast(@min(remaining, 2_147));
                timeout_ms = if (timeout_ms < 0) anim_ms else @min(timeout_ms, anim_ms);
            }

            switch (tui.poll(stdin_fd, pipe_rd, timeout_ms)) {
                .timeout => {
                    // Advance animation frame on timeout if playing.
                    if (current_screen == .about and !anim_done) {
                        const delays = g_spec.strings.about_delays;
                        const frame_count = g_spec.strings.about_frames.len;
                        if (frame_count > 0 and delays.len > 0) {
                            anim_frame += 1;
                            if (anim_frame >= frame_count) {
                                anim_frame = frame_count - 1;
                                anim_done = true;
                            } else {
                                const d_idx = @min(anim_frame, delays.len - 1);
                                anim_timer = getMonotonicMs() + @as(i64, delays[d_idx]);
                            }
                        } else {
                            anim_done = true;
                        }
                        continue; // re-render with new frame
                    }
                    break; // inactivity timeout → exit cleanly via defer
                },
                .pipe => {
                    // Drain all pending signal bytes and dispatch synchronously.
                    var sig_buf: [16]u8 = undefined;
                    const nsig = tui.drainPipe(pipe_rd, &sig_buf);
                    var do_exit = false;
                    for (sig_buf[0..nsig]) |b| {
                        switch (@as(std.posix.SIG, @enumFromInt(b))) {
                            // SIGINT / SIGTERM / SIGALRM → clean exit through defer.
                            std.posix.SIG.INT,
                            std.posix.SIG.TERM,
                            std.posix.SIG.ALRM,
                            => do_exit = true,
                            // SIGWINCH → just re-render; ioctl gets the new size.
                            std.posix.SIG.WINCH => {},
                            else => {},
                        }
                    }
                    if (do_exit) break;
                    continue; // re-render with current (or new) terminal size
                },
                .tty => {}, // fall through to existing keyboard/mouse handling
            }

            // Prepend any incomplete SGR sequence saved from the previous read.
            if (mouse_carry_len > 0) {
                std.mem.copyBackwards(u8, read_buf[mouse_carry_len..], read_buf[0..0]);
                @memcpy(read_buf[0..mouse_carry_len], mouse_carry[0..mouse_carry_len]);
            }
            var n = (mouse_carry_len + (readStdin(stdin_fd, read_buf[mouse_carry_len..]) catch |err| blk: {
                if (err == error.SystemResources or err == error.Interrupted) break :blk @as(usize, 0);
                return err;
            }));
            mouse_carry_len = 0;
            if (n == 0) break;
            last_input_ms = getMonotonicMs();

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

            // Re-arm the acknowledgement bell on every key event; an ignored key
            // re-suppresses below, so the bell rings only once per run of them.
            const bell_armed = !bell_suppressed;
            bell_suppressed = false;

            // Check for focus events
            var focus_event = false;
            if (std.mem.indexOf(u8, bytes, "\x1b[I") != null) {
                has_focus = true;
                focus_event = true;
                started_unfocused = false;
                last_focus_gain_ms = getMonotonicMs();
            }
            if (std.mem.indexOf(u8, bytes, "\x1b[O") != null) {
                has_focus = false;
                focus_event = true;
            }
            if (!focus_event and !has_focus and bytes.len > 0) {
                has_focus = true;
                started_unfocused = false;
                last_focus_gain_ms = getMonotonicMs();
            }
            if (focus_event and n <= 3) {
                continue;
            }

            // Decode the raw byte sequence into a logical key name; the binding
            // table in spec/keys.json maps that name to an action below. Mouse
            // events and printable text are handled inline (not via bindings).
            // Reset here; the SGR mouse branch sets it to true for motion events.
            last_was_motion = false;
            var logical: ?[]const u8 = null;

            if (bytes[0] == 27) {
                if (n == 1) {
                    logical = "esc";
                } else if (n == 2 and bytes[1] == '.') {
                    logical = "ctrl-.";
                } else if (n > 2 and bytes[1] == '[') {
                    if (std.mem.eql(u8, bytes[2..n], "27;5;46~") or std.mem.eql(u8, bytes[2..n], "46;5u")) {
                        logical = "ctrl-.";
                    } else if (std.mem.eql(u8, bytes[2..n], "27;2;13~") or std.mem.eql(u8, bytes[2..n], "13;2u")) {
                        logical = "shift-enter";
                    } else if (std.mem.eql(u8, bytes[2..n], "27;5;13~") or std.mem.eql(u8, bytes[2..n], "13;5u")) {
                        logical = "ctrl-enter";
                    } else if (n >= 6 and bytes[2] == '1' and bytes[3] == ';' and bytes[5] == 'S' and
                        (bytes[4] == '3' or bytes[4] == '9'))
                    {
                        break;
                    } else if (std.mem.eql(u8, bytes[2..n], "1;5C") or std.mem.eql(u8, bytes[2..n], "5C")) {
                        logical = "ctrl-right";
                    } else if (std.mem.eql(u8, bytes[2..n], "1;5D") or std.mem.eql(u8, bytes[2..n], "5D")) {
                        logical = "ctrl-left";
                    } else if (bytes[2] == 'A') {
                        logical = "up";
                    } else if (bytes[2] == 'B') {
                        logical = "down";
                    } else if (bytes[2] == 'C') {
                        logical = "right";
                    } else if (bytes[2] == 'D') {
                        logical = "left";
                    } else if (std.mem.eql(u8, bytes[2..n], "3~")) {
                        logical = "del";
                    } else if (std.mem.eql(u8, bytes[2..n], "5~")) {
                        logical = "pageup";
                    } else if (std.mem.eql(u8, bytes[2..n], "6~")) {
                        logical = "pagedown";
                    } else if (bytes[2] == 'H' or std.mem.eql(u8, bytes[2..n], "1~") or std.mem.eql(u8, bytes[2..n], "7~")) {
                        logical = "home";
                    } else if (bytes[2] == 'F' or std.mem.eql(u8, bytes[2..n], "4~") or std.mem.eql(u8, bytes[2..n], "8~")) {
                        logical = "end";
                    } else if (bytes[2] == '<') {
                        // SGR Mouse — loop through ALL complete events in the read buffer.
                        // A 512-byte buffer holds ~40 events; the multi-event loop plus the
                        // carry buffer below prevent partial-event tails from reaching the
                        // printable-text path and appearing as typed characters in the query.
                        var sgr_off: usize = 0; // cursor into bytes[3..n]
                        sgr_loop: while (true) {
                            const sgr_data = bytes[3 + sgr_off .. n];
                            var term_pos: usize = 0;
                            var term_char: u8 = 0;
                            while (term_pos < sgr_data.len) : (term_pos += 1) {
                                if (sgr_data[term_pos] == 'M' or sgr_data[term_pos] == 'm') {
                                    term_char = sgr_data[term_pos];
                                    break;
                                }
                            }
                            if (term_char == 0) {
                                // Incomplete event tail — save to carry so next read completes it.
                                const tail_len = 3 + sgr_data.len; // \x1b[< + partial params
                                if (tail_len <= mouse_carry.len) {
                                    mouse_carry[0] = 0x1b;
                                    mouse_carry[1] = '[';
                                    mouse_carry[2] = '<';
                                    @memcpy(mouse_carry[3..][0..sgr_data.len], sgr_data);
                                    mouse_carry_len = tail_len;
                                }
                                break :sgr_loop;
                            }

                            var it = std.mem.splitScalar(u8, sgr_data[0..term_pos], ';');
                            const button_str = it.next() orelse break :sgr_loop;
                            const col_str = it.next() orelse break :sgr_loop;
                            const row_str = it.next() orelse break :sgr_loop;

                            const button = std.fmt.parseInt(i32, button_str, 10) catch break :sgr_loop;
                            const click_col = std.fmt.parseInt(i32, col_str, 10) catch break :sgr_loop;
                            const click_row_raw = std.fmt.parseInt(i32, row_str, 10) catch break :sgr_loop;
                            const local_col = click_col - 1;

                            // Map absolute viewport row to TUI-relative row (accounting for cursor start and potential scroll).
                            const click_row = term_lib.mapSgrRow(click_row_raw, global_tui_start_row, global_tty_fd, final_h);

                            const is_motion = (button & 32) != 0;
                            const btn_id = button & 3; // 0=left, 1=mid, 2=right, 3=no-button
                            const is_wheel = (button & 64) != 0;
                            last_was_motion = is_motion;
                            if (term_char == 'm') dragging_scrollbar = false;

                            if (is_wheel and term_char == 'M' and has_focus and popup_msg == null) {
                                // Mouse wheel: scroll whichever pane is shown by a fixed
                                // step, independent of keyboard focus (normal GUI feel).
                                const wheel_down = (button & 1) != 0;
                                const step: usize = 3;
                                if (current_screen == .search) {
                                    const cc = if (final_simple) @as(usize, 1) else cols;
                                    const vp = if (final_simple) total_cells else rows;
                                    const trows = (top_count + cc - 1) / cc;
                                    const max_top = if (trows > vp) trows - vp else 0;
                                    grid_scroll_top = if (wheel_down)
                                        @min(grid_scroll_top + step, max_top)
                                    else if (grid_scroll_top > step) grid_scroll_top - step else 0;
                                } else if (current_screen == .settings) {
                                    const max_top = if (settings_count > rows) settings_count - rows else 0;
                                    settings_scroll_top = if (wheel_down)
                                        @min(settings_scroll_top + step, max_top)
                                    else if (settings_scroll_top > step) settings_scroll_top - step else 0;
                                } else if (current_screen == .categories) {
                                    const total = g_spec.categories.categories.len;
                                    const max_top = if (total > rows) total - rows else 0;
                                    cat_scroll_top = if (wheel_down)
                                        @min(cat_scroll_top + step, max_top)
                                    else if (cat_scroll_top > step) cat_scroll_top - step else 0;
                                } else {
                                    // help / about* / status popups.
                                    const viewport_h = rows + 3;
                                    const is_about = current_screen == .about;
                                    const sp = if (current_screen == .help) &help_scroll_top else if (is_about) &about_scroll_top else &status_scroll_top;
                                    const about_lines_len: usize = if (g_spec.strings.about_frames.len > 0) g_spec.strings.about_frames[0].len else 0;
                                    const lines_len = if (current_screen == .help) g_spec.strings.help_lines_more.len else if (current_screen == .about) about_lines_len else g_spec.strings.status_lines.len;
                                    const max_scroll: usize = if (lines_len > viewport_h) lines_len - viewport_h else 0;
                                    sp.* = if (wheel_down)
                                        @min(sp.* + step, max_scroll)
                                    else if (sp.* > step) sp.* - step else 0;
                                }
                            } else if (is_motion and term_char == 'M' and has_focus and popup_msg == null) {
                                // Theme button hover.
                                const search_row_m: i32 = 2 + row_off;
                                theme_hovered = (click_row == search_row_m and
                                    local_col >= @as(i32, @intCast(content_width)) - 4);

                                // Hover: update selection to item under cursor (no copy/action).
                                const grid_first_row: i32 = 4 + row_off;
                                const grid_last_row: i32 = grid_first_row + @as(i32, @intCast(rows)) - 1;
                                // Settings/categories have title+blank before first item → offset +1.
                                const list_first_row: i32 = grid_first_row + 1;
                                if (current_screen == .settings) {
                                    griddim_hover_left = false;
                                    griddim_hover_right = false;
                                    if (click_row >= list_first_row) {
                                        const opt_idx = settings_scroll_top + @as(usize, @intCast(click_row - list_first_row));
                                        if (opt_idx < settings_count) selected_idx = opt_idx;
                                        // Bold the grid-size arrow under the cursor (same
                                        // hit-zones as applyGridDimClick: 3–5 ‹, 8–10 ›).
                                        if (opt_idx == 6 or opt_idx == 7) {
                                            griddim_hover_left = local_col >= 3 and local_col <= 5;
                                            griddim_hover_right = local_col >= 8 and local_col <= 10;
                                        }
                                    }
                                } else if (current_screen == .categories) {
                                    if (click_row >= list_first_row) {
                                        const cat_idx = cat_scroll_top + @as(usize, @intCast(click_row - list_first_row));
                                        if (cat_idx < g_spec.categories.categories.len) selected_idx = cat_idx;
                                    }
                                } else if (current_screen == .search and click_row >= grid_first_row and click_row <= grid_last_row) {
                                    const total_rows = (top_count + cols - 1) / cols;
                                    const on_sb = dragging_scrollbar and total_rows > rows;
                                    if (on_sb) {
                                        // Scrollbar drag: map the track row to a scroll offset.
                                        const tg = scrollbarThumb(scrollbar_style, rows, total_rows);
                                        const max_scroll = total_rows - rows;
                                        const track_row = @as(usize, @intCast(click_row - grid_first_row));
                                        if (tg.travel > 0) grid_scroll_top = @min(track_row * max_scroll / tg.travel, max_scroll);
                                        // Write only the scrollbar column so the thumb tracks the
                                        // mouse instantly on every event, without waiting for the
                                        // full-frame render at the end of the batch. Uses absolute
                                        // cursor positioning so the rest of the frame is untouched.
                                        // Cursor is parked back at the search bar row afterward so
                                        // the next render's relative \x1b[NA reposition is correct.
                                        if (global_tui_start_row) |tui_top| {
                                            const new_max = if (max_scroll > 0) max_scroll else 1;
                                            const new_thumb = grid_scroll_top * tg.travel / new_max;
                                            var sb_r: usize = 0;
                                            while (sb_r < rows) : (sb_r += 1) {
                                                const abs_row = @as(usize, @intCast(tui_top)) +
                                                    3 + @as(usize, @intCast(row_off)) + sb_r;
                                                const on_t = sb_r >= new_thumb and sb_r < new_thumb + tg.thumb_h;
                                                const sb_char: []const u8 = if (on_t) "▐" else " ";
                                                var sb_buf: [32]u8 = undefined;
                                                const sb_seq = try std.fmt.bufPrint(&sb_buf, "\x1b[{d};{d}H{s}", .{ abs_row, content_width + 1, sb_char });
                                                try writeAll(stdout_fd, sb_seq);
                                            }
                                            // Park cursor at search-bar row so next render's
                                            // relative move (\x1b[{1+row_off}A\r) lands correctly.
                                            const search_row = @as(usize, @intCast(tui_top)) +
                                                1 + @as(usize, @intCast(row_off));
                                            var park_buf: [24]u8 = undefined;
                                            const park_seq = try std.fmt.bufPrint(&park_buf, "\x1b[{d};1H", .{search_row});
                                            try writeAll(stdout_fd, park_seq);
                                        }
                                    } else {
                                        const grid_row = @as(usize, @intCast(click_row - grid_first_row));
                                        const grid_col = @as(usize, @intCast(@max(0, local_col - 1))) / 4;
                                        if (grid_col < cols) {
                                            const hovered = (grid_scroll_top + grid_row) * cols + grid_col;
                                            if (hovered < top_count) selected_idx = hovered;
                                        }
                                    }
                                }
                            } else if (!is_motion and btn_id == 0 and term_char == 'M' and has_focus) {
                                // Left click press.
                                if (popup_msg != null) {
                                    popup_msg = null;
                                    break :sgr_loop;
                                }
                                const now = getMonotonicMs();
                                if (now - last_focus_gain_ms > 200) {
                                    const search_row: i32 = 2 + row_off;
                                    const grid_first_row: i32 = 4 + row_off;
                                    const grid_last_row: i32 = grid_first_row + @as(i32, @intCast(rows)) - 1;

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
                                        applyTerminalColors(stdout_fd, theme, system_theme, final_alt_screen);
                                        // Settings/categories have title+blank before first item → offset +1.
                                    } else {
                                        const list_first_row: i32 = grid_first_row + 1;
                                        if (current_screen == .settings and click_row >= list_first_row) {
                                            const opt_idx = settings_scroll_top + @as(usize, @intCast(click_row - list_first_row));
                                            if (opt_idx < settings_count) {
                                                selected_idx = opt_idx;
                                                if (opt_idx == 1) {
                                                    keybind_editing = true;
                                                    keybind_input_len = shell_key_binding.len;
                                                    const len = @min(shell_key_binding.len, keybind_input_buf.len);
                                                    @memcpy(keybind_input_buf[0..len], shell_key_binding[0..len]);
                                                    shell_key_binding = keybind_input_buf[0..len];
                                                } else if (opt_idx == 4) {
                                                    theme = cycleTheme(theme, true);
                                                    saveThemeToConfig(init.io, theme);
                                                    if (theme == .system)
                                                        system_theme = detectSystemTheme(stdin_fd, stdout_fd, raw);
                                                    applyTerminalColors(stdout_fd, theme, system_theme, final_alt_screen);
                                                } else if (opt_idx == 6 or opt_idx == 7) {
                                                    griddim_typing = false;
                                                    const v = if (opt_idx == 6) &grid_cols else &grid_rows;
                                                    if (applyGridDimClick(init.io, opt_idx == 6, local_col, v)) {
                                                        griddim_changed = true;
                                                    }
                                                } else {
                                                    const home_s = std.mem.span(std.c.getenv("HOME") orelse "");
                                                    const shell_s = detectShell(init.environ_map);
                                                    toggleSetting(init, opt_idx, &shell_integration, &show_all_categories, &ambiguous_chars, &scrollbar_style, home_s, shell_s);
                                                }
                                            }
                                        } else if (current_screen == .categories and click_row >= list_first_row) {
                                            const cat_idx = cat_scroll_top + @as(usize, @intCast(click_row - list_first_row));
                                            if (cat_idx < g_spec.categories.categories.len) {
                                                selected_idx = cat_idx;
                                                disabled_cats[cat_idx] = !disabled_cats[cat_idx];
                                                saveDisabledCategories(init.io, g_spec.categories.categories, &disabled_cats);
                                            }
                                        } else if (current_screen == .search and click_row >= grid_first_row and click_row <= grid_last_row and
                                            local_col == @as(i32, @intCast(content_width)) and (top_count + cols - 1) / cols > rows)
                                        {
                                            // Scrollbar click-to-jump; mark as drag start so
                                            // subsequent motion events continue scrolling even
                                            // when the cursor strays left or right of the track.
                                            dragging_scrollbar = true;
                                            const total_rows = (top_count + cols - 1) / cols;
                                            const tg = scrollbarThumb(scrollbar_style, rows, total_rows);
                                            const max_scroll = total_rows - rows;
                                            const track_row = @as(usize, @intCast(click_row - grid_first_row));
                                            if (tg.travel > 0) grid_scroll_top = @min(track_row * max_scroll / tg.travel, max_scroll);
                                        } else if (current_screen == .search and click_row >= grid_first_row and click_row <= grid_last_row) {
                                            const grid_row = @as(usize, @intCast(click_row - grid_first_row));
                                            const grid_col = @as(usize, @intCast(@max(0, local_col - 1))) / 4;
                                            if (grid_col < cols) {
                                                const clicked_idx = (grid_scroll_top + grid_row) * cols + grid_col;
                                                if (clicked_idx < top_count) {
                                                    selected_idx = clicked_idx;
                                                    if (multi_select_active) {
                                                        const entry = emojig.EmojiDb.getEntry(top_matches[clicked_idx].index);
                                                        var on_selected = false;
                                                        for (multi_selected_emojis.items) |e| {
                                                            if (std.mem.eql(u8, e, entry.emoji)) {
                                                                on_selected = true;
                                                                break;
                                                            }
                                                        }
                                                        if (on_selected) {
                                                            const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                                                            try copyToClipboard(init, joined, final_safe);
                                                            result_emoji = joined;
                                                            should_copy_and_exit = true;
                                                        } else {
                                                            const dupe_emoji = try spec_arena.allocator().dupe(u8, entry.emoji);
                                                            try multi_selected_emojis.append(spec_arena.allocator(), dupe_emoji);
                                                            const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                                                            try copyToClipboard(init, joined, final_safe);
                                                        }
                                                    } else {
                                                        should_copy_and_exit = true;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // Advance past this event; continue loop if next event follows.
                            sgr_off += term_pos + 1; // skip Cb;Cx;CyM/m
                            const next = 3 + sgr_off;
                            if (next + 2 < n and bytes[next] == 0x1b and bytes[next + 1] == '[' and bytes[next + 2] == '<') {
                                sgr_off += 3; // skip \x1b[< prefix of next event
                            } else {
                                break :sgr_loop;
                            }
                        } // end sgr_loop
                    }
                } else if (n > 2 and bytes[1] == 'O') {
                    // Arrow keys — application cursor key mode (\x1bOA/B/C/D).
                    // ZLE keeps the terminal in smkx (application mode) during widget execution.
                    if (bytes[2] == 'c') {
                        logical = "ctrl-right";
                    } else if (bytes[2] == 'd') {
                        logical = "ctrl-left";
                    } else if (bytes[2] == 'A') {
                        logical = "up";
                    } else if (bytes[2] == 'B') {
                        logical = "down";
                    } else if (bytes[2] == 'C') {
                        logical = "right";
                    } else if (bytes[2] == 'D') {
                        logical = "left";
                    } else if (bytes[2] == 'H') {
                        logical = "home";
                    } else if (bytes[2] == 'F') {
                        logical = "end";
                    } else if (bytes[2] == 'P') {
                        logical = "f1";
                    }
                }
            } else if (bytes[0] == 127 or bytes[0] == 8) {
                logical = "backspace";
            } else if (bytes[0] == 10 or bytes[0] == 13) {
                logical = "enter";
            } else if (bytes[0] == 9) {
                logical = "tab";
            } else if (bytes[0] == ' ' and current_screen != .search) {
                logical = "space";
            } else if (bytes[0] == 3 or bytes[0] == 4 or bytes[0] == 0x11 or bytes[0] == 0x17) {
                logical = switch (bytes[0]) {
                    3 => "ctrl-c",
                    4 => "ctrl-d",
                    0x11 => "ctrl-q",
                    0x17 => "ctrl-w",
                    else => unreachable,
                };
            } else {
                // Printable text — append to keybind input or search query.
                if (has_focus and keybind_editing) {
                    for (bytes) |b| {
                        if (b >= 32 and b <= 126 and keybind_input_len < keybind_input_buf.len) {
                            keybind_input_buf[keybind_input_len] = b;
                            keybind_input_len += 1;
                            shell_key_binding = keybind_input_buf[0..keybind_input_len];
                        }
                    }
                } else if (has_focus and current_screen == .settings) {
                    const on_grid = selected_idx != null and (selected_idx.? == 6 or selected_idx.? == 7);
                    for (bytes) |b| {
                        if (b == '?' or b == 'h') {
                            // Context-sensitive help for the selected setting —
                            // the same key toggles the modal closed again.
                            popup_title = "❔ setting help";
                            popup_msg = if (popup_msg == null) settingHelp(selected_idx orelse 0) else null;
                        } else if (on_grid and b >= '0' and b <= '9') {
                            // Type a number directly into the selected grid-size row.
                            const is_cols = selected_idx.? == 6;
                            const max = if (is_cols) defaults.MAX_COLS else defaults.MAX_ROWS;
                            const v = if (is_cols) &grid_cols else &grid_rows;
                            typeGridDim(v, b, griddim_typing, max);
                            griddim_typing = true;
                            griddim_changed = true;
                            saveUsizeToConfig(init.io, if (is_cols) "cols" else "rows", v.*);
                        }
                    }
                } else if (has_focus and current_screen == .search and
                    selected_idx != null and bytes.len == 1 and bytes[0] == ' ')
                {
                    // Grid focus: Space starts multi-select and toggles the focused
                    // emoji in/out of the selection (spacebar-to-select). On the
                    // prompt (selected_idx == null) Space still types into the query.
                    const sel = selected_idx.?;
                    if (sel < top_count) {
                        multi_select_active = true;
                        const entry = emojig.EmojiDb.getEntry(top_matches[sel].index);
                        var found_at: ?usize = null;
                        for (multi_selected_emojis.items, 0..) |e, i| {
                            if (std.mem.eql(u8, e, entry.emoji)) {
                                found_at = i;
                                break;
                            }
                        }
                        if (found_at) |i| {
                            _ = multi_selected_emojis.orderedRemove(i);
                        } else {
                            const dupe_emoji = try spec_arena.allocator().dupe(u8, entry.emoji);
                            try multi_selected_emojis.append(spec_arena.allocator(), dupe_emoji);
                        }
                        if (multi_selected_emojis.items.len > 0) {
                            const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                            try copyToClipboard(init, joined, final_safe);
                        }
                    }
                } else if (has_focus and current_screen == .search) {
                    for (bytes) |b| {
                        if (b >= 32 and b <= 126 and query_len < max_query_len) {
                            // Insert at the text cursor, shifting the tail right.
                            if (query_cursor < query_len) {
                                std.mem.copyBackwards(u8, query_buf[query_cursor + 1 .. query_len + 1], query_buf[query_cursor..query_len]);
                            }
                            query_buf[query_cursor] = b;
                            query_len += 1;
                            query_cursor += 1;
                            // Typing always returns focus to the prompt and
                            // resets the scroll; Enter still picks the first hit.
                            if (!multi_select_active) selected_idx = null;
                            grid_scroll_top = 0;
                            total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            term_lib.appendLog("search q=\"{s}\" results={d}", .{ query_buf[0..query_len], total_matches });
                        }
                    }
                } else if (has_focus and (current_screen == .help or current_screen == .about or
                    current_screen == .status))
                {
                    // Doc screens are pager-like: a lone 'q' closes (less/man
                    // convention); any other printable jumps back to search and
                    // seeds the query so the screen never traps the user.
                    if (bytes.len == 1 and (bytes[0] == 'q' or bytes[0] == 'Q')) {
                        current_screen = .search;
                        query_len = 0;
                        query_cursor = 0;
                        selected_idx = null;
                        total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                    } else {
                        current_screen = .search;
                        query_len = 0;
                        query_cursor = 0;
                        selected_idx = null;
                        for (bytes) |b| {
                            if (b >= 32 and b <= 126 and query_len < max_query_len) {
                                query_buf[query_len] = b;
                                query_len += 1;
                                query_cursor += 1;
                            }
                        }
                        grid_scroll_top = 0;
                        total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                    }
                }
            }

            // Dispatch the decoded key through the spec/keys.json bindings.
            // Dispatch the decoded key through the spec/keys.json bindings.
            if (logical) |name| {
                const action = g_spec.actionFor(name) orelse "";
                if (popup_msg != null) {
                    if (std.mem.eql(u8, name, "esc") or std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "space") or std.mem.eql(u8, name, "f1") or std.mem.eql(u8, action, "delete") or std.mem.eql(u8, action, "select") or std.mem.eql(u8, action, "quit")) {
                        popup_msg = null;
                    }
                } else if (std.mem.eql(u8, action, "quit")) {
                    if (current_screen != .search) {
                        current_screen = .search;
                        query_len = 0;
                        selected_idx = null;
                        total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                    } else if (multi_select_active and std.mem.eql(u8, name, "esc")) {
                        multi_select_active = false;
                        multi_selected_emojis.clearRetainingCapacity();
                        selected_idx = null;
                    } else {
                        if (multi_select_active and multi_selected_emojis.items.len > 0) {
                            const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                            result_emoji = joined;
                        }
                        break;
                    }
                } else if (has_focus) {
                    if (std.mem.eql(u8, action, "open_settings")) {
                        current_screen = .settings;
                        selected_idx = 0;
                        settings_scroll_top = 0;
                    } else if (current_screen == .settings) {
                        if (keybind_editing) {
                            if (std.mem.eql(u8, name, "backspace")) {
                                if (keybind_input_len > 0) {
                                    keybind_input_len -= 1;
                                    shell_key_binding = keybind_input_buf[0..keybind_input_len];
                                }
                            } else if (std.mem.eql(u8, name, "enter")) {
                                keybind_editing = false;
                                keybind_committed_len = @min(keybind_input_len, keybind_committed_buf.len);
                                @memcpy(keybind_committed_buf[0..keybind_committed_len], keybind_input_buf[0..keybind_committed_len]);
                                shell_key_binding = keybind_committed_buf[0..keybind_committed_len];
                                saveKeyToConfig(init.io, "shell_key_binding", shell_key_binding);
                            } else if (std.mem.eql(u8, name, "esc")) {
                                keybind_editing = false;
                                shell_key_binding = keybind_committed_buf[0..keybind_committed_len];
                            }
                        } else if (std.mem.eql(u8, action, "nav_up") or std.mem.eql(u8, name, "up")) {
                            keybind_editing = false;
                            if (griddim_typing) finalizeGridTyping(init.io, selected_idx, &grid_cols, &grid_rows);
                            griddim_typing = false;
                            griddim_hover_left = false;
                            griddim_hover_right = false;
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? > 0) selected_idx.? - 1 else settings_count - 1;
                            adjustScrollTop(selected_idx.?, &settings_scroll_top, rows, settings_count);
                        } else if (std.mem.eql(u8, action, "nav_down") or std.mem.eql(u8, name, "down")) {
                            keybind_editing = false;
                            if (griddim_typing) finalizeGridTyping(init.io, selected_idx, &grid_cols, &grid_rows);
                            griddim_typing = false;
                            griddim_hover_left = false;
                            griddim_hover_right = false;
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? + 1 < settings_count) selected_idx.? + 1 else 0;
                            adjustScrollTop(selected_idx.?, &settings_scroll_top, rows, settings_count);
                        } else if (std.mem.eql(u8, action, "select") or std.mem.eql(u8, name, "space") or std.mem.eql(u8, name, "enter")) {
                            const opt_idx = selected_idx orelse 0;
                            if (opt_idx == 1) {
                                keybind_editing = true;
                                keybind_committed_len = @min(shell_key_binding.len, keybind_committed_buf.len);
                                @memcpy(keybind_committed_buf[0..keybind_committed_len], shell_key_binding[0..keybind_committed_len]);
                                keybind_input_len = keybind_committed_len;
                                @memcpy(keybind_input_buf[0..keybind_input_len], keybind_committed_buf[0..keybind_committed_len]);
                                shell_key_binding = keybind_input_buf[0..keybind_input_len];
                            } else if (opt_idx == 4) {
                                theme = cycleTheme(theme, true);
                                saveThemeToConfig(init.io, theme);
                                if (theme == .system)
                                    system_theme = detectSystemTheme(stdin_fd, stdout_fd, raw);
                                applyTerminalColors(stdout_fd, theme, system_theme, final_alt_screen);
                            } else if (opt_idx == 6) {
                                grid_cols = cycleGridDim(grid_cols, grid_dim_step, defaults.MIN_COLS, defaults.MAX_COLS);
                                saveUsizeToConfig(init.io, "cols", grid_cols);
                                griddim_changed = true;
                                griddim_typing = false;
                            } else if (opt_idx == 7) {
                                grid_rows = cycleGridDim(grid_rows, grid_dim_step, defaults.MIN_ROWS, defaults.MAX_ROWS);
                                saveUsizeToConfig(init.io, "rows", grid_rows);
                                griddim_changed = true;
                                griddim_typing = false;
                            } else if (opt_idx == 8) {
                                mru.clear();
                                popup_title = "✔ done";
                                popup_msg = "Recent history cleared.";
                            } else {
                                const home_s = std.mem.span(std.c.getenv("HOME") orelse "");
                                const shell_s = detectShell(init.environ_map);
                                toggleSetting(init, opt_idx, &shell_integration, &show_all_categories, &ambiguous_chars, &scrollbar_style, home_s, shell_s);
                            }
                        } else if ((std.mem.eql(u8, action, "nav_left") or std.mem.eql(u8, action, "nav_right")) and selected_idx != null) {
                            // Left/Right change the value of the selected setting:
                            // ±1 on grid dims, forward/back cycle on theme, and a
                            // plain toggle on the booleans and 2-state enums.
                            const opt_idx = selected_idx.?;
                            const increase = std.mem.eql(u8, action, "nav_right");
                            griddim_typing = false;
                            if (opt_idx == 6) {
                                grid_cols = stepGridDim(grid_cols, increase, defaults.MIN_COLS, defaults.MAX_COLS);
                                saveUsizeToConfig(init.io, "cols", grid_cols);
                                griddim_changed = true;
                            } else if (opt_idx == 7) {
                                grid_rows = stepGridDim(grid_rows, increase, defaults.MIN_ROWS, defaults.MAX_ROWS);
                                saveUsizeToConfig(init.io, "rows", grid_rows);
                                griddim_changed = true;
                            } else if (opt_idx == 4) {
                                theme = cycleTheme(theme, increase);
                                saveThemeToConfig(init.io, theme);
                                if (theme == .system)
                                    system_theme = detectSystemTheme(stdin_fd, stdout_fd, raw);
                                applyTerminalColors(stdout_fd, theme, system_theme, final_alt_screen);
                            } else if (opt_idx != 1) {
                                const home_s = std.mem.span(std.c.getenv("HOME") orelse "");
                                const shell_s = detectShell(init.environ_map);
                                toggleSetting(init, opt_idx, &shell_integration, &show_all_categories, &ambiguous_chars, &scrollbar_style, home_s, shell_s);
                            }
                        } else if (std.mem.eql(u8, name, "f1")) {
                            popup_title = "❔ setting help";
                            popup_msg = settingHelp(selected_idx orelse 0);
                        } else if (std.mem.eql(u8, name, "backspace") and selected_idx != null and
                            (selected_idx.? == 6 or selected_idx.? == 7))
                        {
                            // Backspace on a grid-size row resets it to the spec
                            // default and ends the typing run, so the next digit
                            // starts a fresh number rather than appending.
                            if (selected_idx.? == 6) {
                                grid_cols = clampGridDim(g_spec.layout.tui.cols, defaults.MIN_COLS, defaults.MAX_COLS);
                                saveUsizeToConfig(init.io, "cols", grid_cols);
                            } else {
                                grid_rows = clampGridDim(g_spec.layout.tui.rows, defaults.MIN_ROWS, defaults.MAX_ROWS);
                                saveUsizeToConfig(init.io, "rows", grid_rows);
                            }
                            griddim_changed = true;
                            griddim_typing = false;
                        } else if (std.mem.eql(u8, name, "esc") or std.mem.eql(u8, action, "delete")) {
                            keybind_editing = false;
                            if (griddim_typing) finalizeGridTyping(init.io, selected_idx, &grid_cols, &grid_rows);
                            griddim_typing = false;
                            current_screen = .search;
                            query_len = 0;
                            selected_idx = null;
                            total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                        }
                    } else if (current_screen == .categories) {
                        if (std.mem.eql(u8, action, "nav_up") or std.mem.eql(u8, name, "up")) {
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? > 0) selected_idx.? - 1 else g_spec.categories.categories.len - 1;
                            adjustScrollTop(selected_idx.?, &cat_scroll_top, rows, g_spec.categories.categories.len);
                        } else if (std.mem.eql(u8, action, "nav_down") or std.mem.eql(u8, name, "down")) {
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? + 1 < g_spec.categories.categories.len) selected_idx.? + 1 else 0;
                            adjustScrollTop(selected_idx.?, &cat_scroll_top, rows, g_spec.categories.categories.len);
                        } else if (std.mem.eql(u8, action, "select") or std.mem.eql(u8, name, "space") or std.mem.eql(u8, name, "enter")) {
                            const idx = selected_idx orelse 0;
                            if (idx < disabled_cats.len) {
                                disabled_cats[idx] = !disabled_cats[idx];
                                saveDisabledCategories(init.io, g_spec.categories.categories, &disabled_cats);
                            }
                        } else if (std.mem.eql(u8, name, "esc") or std.mem.eql(u8, action, "delete")) {
                            current_screen = .search;
                            query_len = 0;
                            selected_idx = null;
                            total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                        }
                    } else if (current_screen == .about or current_screen == .help or current_screen == .status) {
                        if (current_screen == .about and std.mem.eql(u8, name, "space")) {
                            anim_frame = 0;
                            anim_done = false;
                            const delays = g_spec.strings.about_delays;
                            anim_timer = getMonotonicMs() + @as(i64, if (delays.len > 0) delays[0] else 500);
                        } else if (std.mem.eql(u8, name, "esc") or std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "space") or std.mem.eql(u8, action, "delete")) {
                            current_screen = .search;
                            query_len = 0;
                            selected_idx = null;
                            total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                        } else {
                            const viewport_h = rows + 3;
                            const sp = if (current_screen == .help) &help_scroll_top else if (current_screen == .about) &about_scroll_top else &status_scroll_top;
                            const about_lines_len2: usize = if (g_spec.strings.about_frames.len > 0) g_spec.strings.about_frames[0].len else 0;
                            const lines_len = if (current_screen == .help) g_spec.strings.help_lines_more.len else if (current_screen == .about) about_lines_len2 else g_spec.strings.status_lines.len;
                            const max_scroll: usize = if (lines_len > viewport_h) lines_len - viewport_h else 0;
                            if (std.mem.eql(u8, action, "nav_up") or std.mem.eql(u8, name, "up")) {
                                if (sp.* > 0) sp.* -= 1;
                            } else if (std.mem.eql(u8, action, "nav_down") or std.mem.eql(u8, name, "down")) {
                                if (sp.* < max_scroll) sp.* += 1;
                            } else if (std.mem.eql(u8, action, "scroll_pageup")) {
                                sp.* = if (sp.* > viewport_h) sp.* - viewport_h else 0;
                            } else if (std.mem.eql(u8, action, "scroll_pagedown")) {
                                sp.* = @min(sp.* + viewport_h, max_scroll);
                            } else if (std.mem.eql(u8, action, "nav_home")) {
                                sp.* = 0;
                            } else if (std.mem.eql(u8, action, "nav_end")) {
                                sp.* = max_scroll;
                            } else {
                                // Any other key is dead on a doc screen → bell.
                                ringBell(bell_armed, &bell_suppressed);
                            }
                        }
                    } else if (is_cmd_autocomplete) {
                        if (std.mem.eql(u8, action, "nav_up") or std.mem.eql(u8, name, "up")) {
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? > 0) selected_idx.? - 1 else cmd_match_count - 1;
                        } else if (std.mem.eql(u8, action, "nav_down") or std.mem.eql(u8, name, "down")) {
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? + 1 < cmd_match_count) selected_idx.? + 1 else 0;
                        } else if (std.mem.eql(u8, name, "esc")) {
                            query_len = 0;
                            selected_idx = null;
                            total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                        } else if (std.mem.eql(u8, action, "select") or std.mem.eql(u8, name, "enter")) {
                            // Find the selected command
                            var opt_cmd: ?spec_mod.CommandSpec = null;
                            if (selected_idx != null and selected_idx.? < cmd_match_count) {
                                opt_cmd = g_spec.commands.commands[cmd_matches[selected_idx.?]];
                            } else {
                                // Fallback: prefix match
                                const cmd_query = query_buf[1..query_len];
                                for (g_spec.commands.commands) |cmd| {
                                    if (std.mem.eql(u8, cmd.name, cmd_query) or std.mem.eql(u8, cmd.short, cmd_query)) {
                                        opt_cmd = cmd;
                                        break;
                                    }
                                }
                                if (opt_cmd == null) {
                                    for (g_spec.commands.commands) |cmd| {
                                        if (std.mem.startsWith(u8, cmd.name, cmd_query) or std.mem.startsWith(u8, cmd.short, cmd_query)) {
                                            opt_cmd = cmd;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (opt_cmd) |cmd| {
                                if (std.mem.eql(u8, cmd.action, "open_help")) {
                                    current_screen = .help;
                                    help_scroll_top = 0;
                                    selected_idx = null;
                                } else if (std.mem.eql(u8, cmd.action, "open_about")) {
                                    current_screen = .about;
                                    about_scroll_top = 0;
                                    selected_idx = null;
                                    // Reset animation for replay on re-enter.
                                    anim_frame = 0;
                                    anim_done = false;
                                    const delays = g_spec.strings.about_delays;
                                    anim_timer = getMonotonicMs() + @as(i64, if (delays.len > 0) delays[0] else 500);
                                } else if (std.mem.eql(u8, cmd.action, "open_status")) {
                                    current_screen = .status;
                                    status_scroll_top = 0;
                                    selected_idx = null;
                                } else if (std.mem.eql(u8, cmd.action, "open_settings")) {
                                    current_screen = .settings;
                                    selected_idx = 0;
                                    settings_scroll_top = 0;
                                } else if (std.mem.eql(u8, cmd.action, "open_categories")) {
                                    current_screen = .categories;
                                    selected_idx = 0;
                                    cat_scroll_top = 0;
                                } else if (std.mem.eql(u8, cmd.action, "start_multi_selection")) {
                                    multi_select_active = true;
                                    query_len = 0;
                                    selected_idx = null;
                                    total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                                } else if (std.mem.eql(u8, cmd.action, "run_update")) {
                                    const home_s = std.mem.span(std.c.getenv("HOME") orelse "");
                                    popup_title = "📦 emojig update";
                                    popup_msg = runUpdate(init.io, home_s, cfg.update_cmd, cmd.cmd, &popup_buf);
                                    query_len = 0;
                                    current_screen = .search;
                                    selected_idx = null;
                                    total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                                } else if (std.mem.eql(u8, cmd.action, "quit_app")) {
                                    break;
                                }
                            }
                        } else if (std.mem.eql(u8, action, "delete")) {
                            if (query_cursor > 0) {
                                deleteAtCursor(&query_buf, &query_len, &query_cursor);
                                selected_idx = if (query_len == 0) null else 0;
                                total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            }
                        } else if (std.mem.eql(u8, name, "del")) {
                            if (query_cursor < query_len) {
                                forwardDeleteAtCursor(&query_buf, &query_len, &query_cursor);
                                selected_idx = if (query_len == 0) null else 0;
                                total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            }
                        }
                    } else if (is_cat_autocomplete) {
                        if (std.mem.eql(u8, action, "nav_up") or std.mem.eql(u8, name, "up")) {
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? > 0) selected_idx.? - 1 else cat_match_count - 1;
                        } else if (std.mem.eql(u8, action, "nav_down") or std.mem.eql(u8, name, "down")) {
                            selected_idx = if (selected_idx == null) 0 else if (selected_idx.? + 1 < cat_match_count) selected_idx.? + 1 else 0;
                        } else if (std.mem.eql(u8, name, "esc")) {
                            query_len = 0;
                            selected_idx = null;
                            total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                        } else if (std.mem.eql(u8, action, "select") or std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "space")) {
                            var opt_cat: ?spec_mod.CategorySpec = null;
                            if (selected_idx != null and selected_idx.? < cat_match_count) {
                                opt_cat = g_spec.categories.categories[cat_matches[selected_idx.?]];
                            } else if (cat_match_count > 0) {
                                opt_cat = g_spec.categories.categories[cat_matches[0]];
                            }
                            if (opt_cat) |cat| {
                                query_len = if (std.fmt.bufPrint(&query_buf, "c:{s} ", .{cat.short})) |res| res.len else |_| 0;
                                query_cursor = query_len;
                                selected_idx = null;
                                total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            }
                        } else if (std.mem.eql(u8, action, "delete")) {
                            if (query_cursor > 0) {
                                deleteAtCursor(&query_buf, &query_len, &query_cursor);
                                selected_idx = if (query_len == 0) null else 0;
                                total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            }
                        } else if (std.mem.eql(u8, name, "del")) {
                            if (query_cursor < query_len) {
                                forwardDeleteAtCursor(&query_buf, &query_len, &query_cursor);
                                selected_idx = if (query_len == 0) null else 0;
                                total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            }
                        }
                    } else {
                        // Normal search screen logic
                        if (std.mem.eql(u8, action, "confirm_multi_exit")) {
                            if (multi_select_active) {
                                if (multi_selected_emojis.items.len > 0) {
                                    const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                                    try copyToClipboard(init, joined, final_safe);
                                    result_emoji = joined;
                                }
                                should_copy_and_exit = true;
                            } else {
                                should_copy_and_exit = true;
                            }
                        } else if (std.mem.eql(u8, action, "select")) {
                            if (multi_select_active) {
                                const sel = selected_idx orelse if (top_count > 0) @as(usize, 0) else null;
                                if (sel) |s| {
                                    if (s < top_count) {
                                        const entry = emojig.EmojiDb.getEntry(top_matches[s].index);
                                        var on_selected = false;
                                        for (multi_selected_emojis.items) |e| {
                                            if (std.mem.eql(u8, e, entry.emoji)) {
                                                on_selected = true;
                                                break;
                                            }
                                        }
                                        if (on_selected) {
                                            const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                                            try copyToClipboard(init, joined, final_safe);
                                            result_emoji = joined;
                                            should_copy_and_exit = true;
                                        } else {
                                            const dupe_emoji = try spec_arena.allocator().dupe(u8, entry.emoji);
                                            try multi_selected_emojis.append(spec_arena.allocator(), dupe_emoji);
                                            const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                                            try copyToClipboard(init, joined, final_safe);
                                        }
                                    }
                                }
                            } else {
                                should_copy_and_exit = true;
                            }
                        } else if (std.mem.eql(u8, action, "delete")) {
                            if (multi_select_active) {
                                var removed = false;
                                if (selected_idx) |sel| {
                                    if (sel < top_count) {
                                        const entry = emojig.EmojiDb.getEntry(top_matches[sel].index);
                                        for (multi_selected_emojis.items, 0..) |e, i| {
                                            if (std.mem.eql(u8, e, entry.emoji)) {
                                                _ = multi_selected_emojis.orderedRemove(i);
                                                if (multi_selected_emojis.items.len > 0) {
                                                    const joined = try std.mem.join(spec_arena.allocator(), "", multi_selected_emojis.items);
                                                    try copyToClipboard(init, joined, final_safe);
                                                }
                                                removed = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                                if (!removed and query_cursor > 0) {
                                    deleteAtCursor(&query_buf, &query_len, &query_cursor);
                                    grid_scroll_top = 0;
                                    total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                                }
                            } else if (query_cursor > 0) {
                                deleteAtCursor(&query_buf, &query_len, &query_cursor);
                                selected_idx = null;
                                grid_scroll_top = 0;
                                total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            }
                        } else if (std.mem.eql(u8, name, "del")) {
                            if (query_cursor < query_len) {
                                forwardDeleteAtCursor(&query_buf, &query_len, &query_cursor);
                                selected_idx = null;
                                grid_scroll_top = 0;
                                total_matches = searchDedup(query_buf[0..query_len], &top_matches, &top_count, fetch_limit, &g_spec.categories, disabled_cats);
                            }
                        } else if (std.mem.eql(u8, action, "cycle_theme")) {
                            theme = switch (theme) {
                                .dark => .light,
                                .light => .system,
                                .system => .dark,
                            };
                            saveThemeToConfig(init.io, theme);
                            if (theme == .system) {
                                system_theme = detectSystemTheme(stdin_fd, stdout_fd, raw);
                            }
                            applyTerminalColors(stdout_fd, theme, system_theme, final_alt_screen);
                        } else if (std.mem.eql(u8, action, "scroll_pageup") or std.mem.eql(u8, action, "scroll_pagedown")) {
                            if (top_count > 0) {
                                const down = std.mem.eql(u8, action, "scroll_pagedown");
                                const cc = if (final_simple) @as(usize, 1) else cols;
                                const vp = if (final_simple) total_cells else rows;
                                const trows = (top_count + cc - 1) / cc;
                                const step = vp * cc;
                                const cur = selected_idx orelse 0;
                                selected_idx = if (down)
                                    @min(cur + step, top_count - 1)
                                else if (cur > step) cur - step else 0;
                                adjustScrollTop(selected_idx.? / cc, &grid_scroll_top, vp, trows);
                            }
                        } else if (std.mem.startsWith(u8, action, "nav_")) {
                            const is_home = std.mem.eql(u8, action, "nav_home");
                            const is_end = std.mem.eql(u8, action, "nav_end");
                            const cc = if (final_simple) @as(usize, 1) else cols;
                            const vp = if (final_simple) total_cells else rows;
                            const trows = (top_count + cc - 1) / cc;
                            if (selected_idx == null) {
                                // Prompt focus: Left/Right/Home/End move the text
                                // cursor; Up/Down enter the grid at the first hit.
                                if (std.mem.eql(u8, action, "nav_left")) {
                                    if (query_cursor > 0) query_cursor -= 1;
                                } else if (std.mem.eql(u8, action, "nav_right")) {
                                    if (query_cursor < query_len) {
                                        query_cursor += 1;
                                    } else if (top_count > 0) {
                                        // Cursor already at end of query → enter grid.
                                        selected_idx = 0;
                                        adjustScrollTop(0, &grid_scroll_top, vp, trows);
                                    }
                                } else if (is_home) {
                                    query_cursor = 0;
                                } else if (is_end) {
                                    query_cursor = query_len;
                                } else if (std.mem.eql(u8, action, "nav_down") and top_count > 0) {
                                    // Down enters the grid at the first hit;
                                    // Up is a no-op in the prompt (the grid is
                                    // below, so entering it on Up reads backwards).
                                    selected_idx = 0;
                                    adjustScrollTop(0, &grid_scroll_top, vp, trows);
                                } else if (std.mem.eql(u8, action, "nav_up")) {
                                    // Up is ignored in the prompt, but emit a BEL
                                    // so the terminal's own bell config (audible,
                                    // visual flash, or silent) acknowledges it —
                                    // once per run of consecutive Up presses.
                                    ringBell(bell_armed, &bell_suppressed);
                                }
                            } else {
                                // Grid focus.
                                const sel = selected_idx.?;
                                if (is_home) {
                                    selected_idx = 0;
                                } else if (is_end) {
                                    selected_idx = top_count - 1;
                                } else if (final_simple) {
                                    // Linear prev/next; nav_up off the top releases focus.
                                    if (std.mem.eql(u8, action, "nav_up") or std.mem.eql(u8, action, "nav_left")) {
                                        selected_idx = if (sel == 0) null else sel - 1;
                                    } else {
                                        selected_idx = if (sel + 1 < top_count) sel + 1 else 0;
                                    }
                                } else if (std.mem.eql(u8, action, "nav_up") and sel < cols) {
                                    // Top grid row → release focus back to prompt.
                                    selected_idx = null;
                                } else if (std.mem.eql(u8, action, "nav_left") and sel == 0) {
                                    // First cell → release focus back to prompt instead of wrapping.
                                    selected_idx = null;
                                } else {
                                    selected_idx = navSelect(action, sel, top_count, cols, trows);
                                }
                                if (selected_idx) |s| {
                                    adjustScrollTop(s / cc, &grid_scroll_top, vp, trows);
                                } else {
                                    grid_scroll_top = 0;
                                }
                            }
                        } else if (std.mem.eql(u8, name, "ctrl-left")) {
                            if (selected_idx == null)
                                query_cursor = wordLeft(query_buf[0..query_len], query_cursor);
                        } else if (std.mem.eql(u8, name, "ctrl-right")) {
                            if (selected_idx == null)
                                query_cursor = wordRight(query_buf[0..query_len], query_len, query_cursor);
                        }
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

test "deleteAtCursor removes the byte before the cursor" {
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], "abcd");
    var len: usize = 4;
    var cur: usize = 2; // between 'b' and 'c'
    deleteAtCursor(&buf, &len, &cur);
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqual(@as(usize, 1), cur);
    try std.testing.expectEqualStrings("acd", buf[0..len]);

    // Delete at end (cursor == len) trims the last byte.
    cur = len;
    deleteAtCursor(&buf, &len, &cur);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqualStrings("ac", buf[0..len]);

    // Delete at start is a no-op.
    cur = 0;
    deleteAtCursor(&buf, &len, &cur);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(@as(usize, 0), cur);
}

test "wordLeft moves cursor to start of previous word" {
    const buf = "hello world foo";
    try std.testing.expectEqual(@as(usize, 12), wordLeft(buf, 15)); // "foo" → before 'f'
    try std.testing.expectEqual(@as(usize, 6), wordLeft(buf, 11)); // "world" → before 'w'
    try std.testing.expectEqual(@as(usize, 0), wordLeft(buf, 5)); // "hello" → start
    try std.testing.expectEqual(@as(usize, 0), wordLeft(buf, 0)); // at start → no-op
    try std.testing.expectEqual(@as(usize, 6), wordLeft(buf, 12)); // mid-space → before 'w'
}

test "wordRight moves cursor past next word" {
    const buf = "hello world foo";
    const len = buf.len;
    try std.testing.expectEqual(@as(usize, 6), wordRight(buf, len, 0)); // after "hello " → 'w'
    try std.testing.expectEqual(@as(usize, 12), wordRight(buf, len, 6)); // after "world " → 'f'
    try std.testing.expectEqual(@as(usize, 15), wordRight(buf, len, 12)); // after "foo" → end
    try std.testing.expectEqual(@as(usize, 15), wordRight(buf, len, 15)); // at end → no-op
}

test "grid dimension editing helpers" {
    // stepGridDim clamps to [min, max] on ±1 (min = 5 cols here).
    try std.testing.expectEqual(@as(usize, 7), stepGridDim(6, true, 5, 16));
    try std.testing.expectEqual(@as(usize, 5), stepGridDim(6, false, 5, 16));
    try std.testing.expectEqual(@as(usize, 16), stepGridDim(16, true, 5, 16)); // clamp high
    try std.testing.expectEqual(@as(usize, 5), stepGridDim(5, false, 5, 16)); // clamp to min
    try std.testing.expectEqual(@as(usize, 5), stepGridDim(3, false, 5, 16)); // sub-min snaps up

    // cycleGridDim adds the coarse step and wraps back to min past the max.
    try std.testing.expectEqual(@as(usize, 8), cycleGridDim(6, 2, 5, 16));
    try std.testing.expectEqual(@as(usize, 5), cycleGridDim(16, 2, 5, 16)); // wrap to min

    // typeGridDim allows a transient sub-min value while building a multi-digit
    // entry (1 -> 12); the minimum is enforced separately on commit.
    var v: usize = 9;
    typeGridDim(&v, '1', false, 16); // fresh
    try std.testing.expectEqual(@as(usize, 1), v);
    typeGridDim(&v, '2', true, 16); // 1 -> 12
    try std.testing.expectEqual(@as(usize, 12), v);
    typeGridDim(&v, '9', true, 16); // 129 clamps to 16
    try std.testing.expectEqual(@as(usize, 16), v);
    typeGridDim(&v, '0', false, 16); // fresh 0 -> low bound 1
    try std.testing.expectEqual(@as(usize, 1), v);

    // clampGridDim (used by finalizeGridDim on commit) snaps into [min, max].
    try std.testing.expectEqual(@as(usize, 5), clampGridDim(1, 5, 16)); // sub-min
    try std.testing.expectEqual(@as(usize, 8), clampGridDim(8, 3, 16)); // in range
    try std.testing.expectEqual(@as(usize, 16), clampGridDim(99, 3, 16)); // over max
}

test "navSelect wraps with more rows than one viewport" {
    // 6 columns, 30 results => 5 logical rows. Pass the *total* row count.
    const cols: usize = 6;
    const count: usize = 30;
    const rows: usize = 5;

    // Down from the last row wraps to the same column on the top row.
    try std.testing.expectEqual(@as(usize, 1), navSelect("nav_down", 25, count, cols, rows));
    // Down within range advances one row.
    try std.testing.expectEqual(@as(usize, 7), navSelect("nav_down", 1, count, cols, rows));
    // Up from the top row wraps to the bottom row (same column).
    try std.testing.expectEqual(@as(usize, 25), navSelect("nav_up", 1, count, cols, rows));
    // Left/right wrap at the ends of the whole result set.
    try std.testing.expectEqual(@as(usize, 29), navSelect("nav_left", 0, count, cols, rows));
    try std.testing.expectEqual(@as(usize, 0), navSelect("nav_right", 29, count, cols, rows));
}

test "adjustScrollTop keeps a row selection inside the viewport" {
    var top: usize = 0;
    // Viewport of 4 rows over 8 total rows.
    adjustScrollTop(6, &top, 4, 8); // row 6 -> top must be 3 (rows 3..6)
    try std.testing.expectEqual(@as(usize, 3), top);
    adjustScrollTop(0, &top, 4, 8); // back to top
    try std.testing.expectEqual(@as(usize, 0), top);
    // Selection already visible leaves scroll untouched.
    top = 2;
    adjustScrollTop(3, &top, 4, 8);
    try std.testing.expectEqual(@as(usize, 2), top);
}

test "scrollbarThumb geometry for both styles" {
    // Expand: thumb height tracks the visible fraction.
    const e = scrollbarThumb(.expand, 4, 16);
    try std.testing.expectEqual(@as(usize, 1), e.thumb_h);
    try std.testing.expectEqual(@as(usize, 3), e.travel);

    // Bar: always a single cell, full travel.
    const b = scrollbarThumb(.bar, 4, 16);
    try std.testing.expectEqual(@as(usize, 1), b.thumb_h);
    try std.testing.expectEqual(@as(usize, 3), b.travel);

    // Larger viewport relative to total -> taller expand thumb.
    const e2 = scrollbarThumb(.expand, 8, 12);
    try std.testing.expectEqual(@as(usize, 5), e2.thumb_h); // 8*8/12 = 5
    try std.testing.expectEqual(@as(usize, 3), e2.travel);

    // No scrolling needed -> thumb fills the viewport, no travel.
    const none = scrollbarThumb(.expand, 6, 6);
    try std.testing.expectEqual(@as(usize, 6), none.thumb_h);
    try std.testing.expectEqual(@as(usize, 0), none.travel);
}
