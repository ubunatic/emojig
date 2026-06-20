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
// Points at g_spec.colors once the spec is loaded; null beforehand (and in
// tests that never load) so the color-name lookup is safe to consult anywhere.
var g_colors: ?*const spec_mod.ColorsSpec = null;
var g_wide_ambiguous: bool = true;

// Search dedup cache (see searchDedup). The "search key" is the query with
// outer spaces trimmed, plus the disabled-category mask — the only two inputs
// that change the result set. Re-running an identical search is skipped.
var g_search_key_buf: [defaults.MAX_QUERY_LEN]u8 = undefined;
var g_search_key_len: usize = 0;
var g_search_disabled: [32]bool = undefined;
var g_search_total: usize = 0;
var g_search_initialized: bool = false;

// ---------------------------------------------------------------------------
// Embedded shell integration scripts
// ---------------------------------------------------------------------------

const shell_sh = @embedFile("shell/emojig.sh");
const shell_zsh = @embedFile("shell/emojig.zsh");
const shell_bash = @embedFile("shell/emojig.bash");
const shell_fish = @embedFile("shell/emojig.fish");

// Desktop/launcher icon — edit src/assets/emojig-icon.svg to change it.
// The web-compatible (plain SVG) variant is embedded; regenerate it with
// scripts/web_logo.sh whenever the source icon changes.
const icon_svg = @embedFile("assets/emojig-icon.web.svg");
const icon_png = @embedFile("assets/emojig-icon.png");

// ---------------------------------------------------------------------------
// Theme, Palette & Terminal Wrappers
// ---------------------------------------------------------------------------

const Theme = term_lib.Theme;
const Palette = term_lib.Palette;

/// Scrollbar rendering style, configurable via the Settings screen, the
/// `EMOJIG_SCROLLBAR` env var, or the `scrollbar_style=` config line.
///   .expand — proportional thumb whose height tracks the visible fraction
///   .bar    — fixed single-cell `▐` thumb that slides along the track
const ScrollbarStyle = enum { expand, bar };

/// Thumb geometry for a scrollable viewport. `viewport_h` is the number of
/// visible rows, `total` the number of scrollable rows. For `.bar` the thumb
/// is always one cell tall; for `.expand` it grows with the visible fraction.
/// `travel` is the number of track cells the thumb top may move through.
fn scrollbarThumb(style: ScrollbarStyle, viewport_h: usize, total: usize) struct { thumb_h: usize, travel: usize } {
    if (total <= viewport_h or viewport_h == 0) return .{ .thumb_h = viewport_h, .travel = 0 };
    const thumb_h: usize = switch (style) {
        .bar => 1,
        .expand => @max(1, viewport_h * viewport_h / total),
    };
    const th = @min(thumb_h, viewport_h);
    return .{ .thumb_h = th, .travel = viewport_h - th };
}
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

/// Delete the byte immediately before the text cursor and shift the tail left
/// (a backspace at an arbitrary cursor position). No-op when the cursor is at
/// the start. Mutates query_len and query_cursor in lock-step.
fn deleteAtCursor(query_buf: []u8, query_len: *usize, query_cursor: *usize) void {
    if (query_cursor.* == 0 or query_len.* == 0) return;
    const c = query_cursor.*;
    if (c < query_len.*) {
        std.mem.copyForwards(u8, query_buf[c - 1 .. query_len.* - 1], query_buf[c..query_len.*]);
    }
    query_len.* -= 1;
    query_cursor.* -= 1;
}

/// Emit a single BEL to acknowledge an ignored/dead key, but only once per run
/// of consecutive ignored keys. `armed` is true when the previous key event was
/// *not* itself an ignored key; this routine then re-suppresses so a repeat is
/// silent. The terminal's own bell config decides audible vs. visual vs. silent.
fn ringBell(armed: bool, suppressed: *bool) void {
    if (armed) writeAll(std.posix.STDOUT_FILENO, "\x07") catch {};
    suppressed.* = true;
}

/// Apply a "nav_*" action (from spec/keys.json) to the current grid selection,
/// returning the new index. Wrapping mirrors the historical arrow-key behavior.
fn navSelect(action: []const u8, sel_in: usize, count: usize, cols: usize, rows: usize) usize {
    if (count == 0) return sel_in;
    var sel = sel_in;
    if (std.mem.eql(u8, action, "nav_up")) {
        if (sel >= cols) {
            sel -= cols;
        } else {
            const target = sel + (rows - 1) * cols;
            sel = if (target < count) target else count - 1;
        }
    } else if (std.mem.eql(u8, action, "nav_down")) {
        const target = sel + cols;
        sel = if (target < count) target else sel % cols;
    } else if (std.mem.eql(u8, action, "nav_left")) {
        sel = if (sel > 0) sel - 1 else count - 1;
    } else if (std.mem.eql(u8, action, "nav_right")) {
        sel = if (sel < count - 1) sel + 1 else 0;
    }
    return sel;
}

fn ansiDisplayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == 0x1b) {
            i += 1;
            if (i < text.len) {
                const next = text[i];
                if (next == '[') { // CSI
                    i += 1;
                    while (i < text.len) : (i += 1) {
                        const c = text[i];
                        if (c >= 0x40 and c <= 0x7e) {
                            i += 1;
                            break;
                        }
                    }
                } else if (next == ']') { // OSC
                    i += 1;
                    while (i < text.len) {
                        if (text[i] == 0x07) {
                            i += 1;
                            break;
                        }
                        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                } else {
                    i += 1;
                }
            }
        } else {
            const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (i + len <= text.len) {
                const cp_bytes = text[i .. i + len];
                const cp = std.unicode.utf8Decode(cp_bytes) catch '?';
                if (cp == 0xFE0F) {
                    // Variation Selector-16: 0 width
                } else if (cp >= 0x2E80) {
                    // CJK and beyond: always double-width
                    width += 2;
                } else if (cp >= 0x2000) {
                    // Ambiguous-width range (arrows, math, symbols, box-drawing…)
                    width += if (g_wide_ambiguous) @as(usize, 2) else @as(usize, 1);
                } else if (cp >= 0x20) {
                    width += 1;
                }
                i += len;
            } else {
                i += 1;
            }
        }
    }
    return width;
}

/// Render a status-bar template from spec/strings.json, substituting the live
/// match count for a "{count}" placeholder. Templates without the placeholder
/// (the help hints) are returned unchanged, avoiding a copy.
fn formatStatus(buf: []u8, tmpl: []const u8, total: usize) ![]const u8 {
    const ph = "{count}";
    if (std.mem.indexOf(u8, tmpl, ph)) |pos| {
        return std.fmt.bufPrint(buf, "{s}{d}{s}", .{ tmpl[0..pos], total, tmpl[pos + ph.len ..] });
    }
    return tmpl;
}

/// Expand a status template with variable substitution and style spans.
///
/// Variables: `{count}` → emoji count, `{search_bg}` → theme palette escape.
/// Style spans: `$name{text}` or `$[attr1,attr2,fg=N]{text}`.
///   Named styles are looked up from `spec/styles.json`.
///   Built-in attrs: bold, dim, italic, underline, blink, reverse, strike.
///   Key-value: fg=N or color=N (0-255 or color name), bg=N.
///   Color names: black, red, green, yellow, blue, magenta, cyan, white.
///   After each span, `\x1b[0m` + `search_bg` are emitted automatically.
fn expandTemplate(
    buf: []u8,
    tmpl: []const u8,
    styles: *const spec_mod.StylesSpec,
    count: usize,
    search_bg: []const u8,
) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < tmpl.len and out < buf.len) {
        if (tmpl[i] == '{') {
            if (std.mem.startsWith(u8, tmpl[i..], "{count}")) {
                var num_buf: [20]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch "";
                const n = @min(num_str.len, buf.len - out);
                @memcpy(buf[out..][0..n], num_str[0..n]);
                out += n;
                i += "{count}".len;
                continue;
            } else if (std.mem.startsWith(u8, tmpl[i..], "{search_bg}")) {
                const n = @min(search_bg.len, buf.len - out);
                @memcpy(buf[out..][0..n], search_bg[0..n]);
                out += n;
                i += "{search_bg}".len;
                continue;
            }
        }
        if (tmpl[i] == '$') {
            var j = i + 1;
            var attrs_str: []const u8 = "";
            var valid = false;
            if (j < tmpl.len and tmpl[j] == '[') {
                j += 1;
                const start = j;
                while (j < tmpl.len and tmpl[j] != ']') j += 1;
                if (j < tmpl.len) {
                    attrs_str = tmpl[start..j];
                    j += 1;
                    valid = true;
                }
            } else {
                const start = j;
                while (j < tmpl.len and styleIdentChar(tmpl[j])) j += 1;
                if (j > start) {
                    attrs_str = tmpl[start..j];
                    valid = true;
                }
            }
            if (valid and j < tmpl.len and tmpl[j] == '{') {
                j += 1;
                const content_start = j;
                var depth: usize = 1;
                while (j < tmpl.len) {
                    if (tmpl[j] == '{') {
                        depth += 1;
                    } else if (tmpl[j] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    j += 1;
                }
                if (depth == 0) {
                    const content = tmpl[content_start..j];
                    j += 1;
                    var sgr_buf: [128]u8 = undefined;
                    const sgr = buildSgr(&sgr_buf, attrs_str, styles);
                    var n: usize = @min(sgr.len, buf.len - out);
                    @memcpy(buf[out..][0..n], sgr[0..n]);
                    out += n;
                    n = @min(content.len, buf.len - out);
                    @memcpy(buf[out..][0..n], content[0..n]);
                    out += n;
                    const reset = "\x1b[0m";
                    n = @min(reset.len, buf.len - out);
                    @memcpy(buf[out..][0..n], reset[0..n]);
                    out += n;
                    n = @min(search_bg.len, buf.len - out);
                    @memcpy(buf[out..][0..n], search_bg[0..n]);
                    out += n;
                    i = j;
                    continue;
                }
            }
        }
        buf[out] = tmpl[i];
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

fn styleIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn buildSgr(buf: []u8, attrs_str: []const u8, styles: *const spec_mod.StylesSpec) []const u8 {
    var codes: [32]u16 = undefined;
    var n: usize = 0;
    collectSgrCodes(attrs_str, styles, &codes, &n, 0);
    if (n == 0 or buf.len < 4) return "";
    var out: usize = 0;
    buf[out] = 0x1b;
    out += 1;
    buf[out] = '[';
    out += 1;
    for (codes[0..n], 0..) |code, ci| {
        if (ci > 0) {
            if (out < buf.len) {
                buf[out] = ';';
                out += 1;
            }
        }
        const s = std.fmt.bufPrint(buf[out..], "{d}", .{code}) catch break;
        out += s.len;
    }
    if (out < buf.len) {
        buf[out] = 'm';
        out += 1;
    }
    return buf[0..out];
}

fn collectSgrCodes(
    attrs_str: []const u8,
    styles: *const spec_mod.StylesSpec,
    codes: []u16,
    n: *usize,
    depth: usize,
) void {
    if (depth > 4) return;
    var it = std.mem.splitScalar(u8, attrs_str, ',');
    while (it.next()) |raw| {
        if (n.* + 4 > codes.len) break;
        const attr = std.mem.trim(u8, raw, " \t");
        if (attr.len == 0) continue;
        if (std.mem.indexOfScalar(u8, attr, '=')) |eq| {
            const key = attr[0..eq];
            const val = attr[eq + 1 ..];
            if (std.mem.eql(u8, key, "fg") or std.mem.eql(u8, key, "color")) {
                appendFgCodes(codes, n, val);
            } else if (std.mem.eql(u8, key, "bg")) {
                appendBgCodes(codes, n, val);
            }
        } else if (std.mem.eql(u8, attr, "bold")) {
            codes[n.*] = 1;
            n.* += 1;
        } else if (std.mem.eql(u8, attr, "dim")) {
            codes[n.*] = 2;
            n.* += 1;
        } else if (std.mem.eql(u8, attr, "italic")) {
            codes[n.*] = 3;
            n.* += 1;
        } else if (std.mem.eql(u8, attr, "underline")) {
            codes[n.*] = 4;
            n.* += 1;
        } else if (std.mem.eql(u8, attr, "blink")) {
            codes[n.*] = 5;
            n.* += 1;
        } else if (std.mem.eql(u8, attr, "reverse")) {
            codes[n.*] = 7;
            n.* += 1;
        } else if (std.mem.eql(u8, attr, "strike")) {
            codes[n.*] = 9;
            n.* += 1;
        } else if (styles.styles.map.get(attr)) |def| {
            collectSgrCodes(def, styles, codes, n, depth + 1);
        }
    }
}

/// Emit SGR codes for a 0-255 palette index: the compact 30-37/40-47 (normal)
/// and 90-97/100-107 (bright) forms for the 16 system colours, else the
/// `38;5;N` / `48;5;N` extended form. `normal`/`bright`/`ext` are 30/90/38 for
/// foreground, 40/100/48 for background.
fn appendIndexedColor(codes: []u16, n: *usize, idx: u16, normal: u16, bright: u16, ext: u16) void {
    if (idx < 8) {
        codes[n.*] = normal + idx;
        n.* += 1;
    } else if (idx < 16) {
        codes[n.*] = bright + idx - 8;
        n.* += 1;
    } else {
        codes[n.*] = ext;
        codes[n.* + 1] = 5;
        codes[n.* + 2] = idx;
        n.* += 3;
    }
}

/// Resolve a color spec value to a 0-255 palette index: a name from
/// spec/colors.json (long/short/alias) or a literal numeric index. Returns null
/// for anything unrecognised. The 8 basic ANSI names are handled separately by
/// the callers (they prefer the compact 3X/4X form), so they never reach here.
fn colorNameToIndex(val: []const u8) ?u16 {
    if (g_colors) |c| {
        if (c.indexOf(val)) |idx| return idx;
        if (val.len > 0 and val[0] == '#') {
            if (spec_mod.parseHex(val)) |rgb| {
                for (c.colors) |gc| {
                    if (spec_mod.parseHex(gc.hex)) |g_rgb| {
                        if (g_rgb[0] == rgb[0] and g_rgb[1] == rgb[1] and g_rgb[2] == rgb[2]) {
                            return gc.i;
                        }
                    }
                }
                return c.closestColorIndex(rgb);
            }
        }
    }
    return std.fmt.parseInt(u16, val, 10) catch null;
}

fn appendFgCodes(codes: []u16, n: *usize, val: []const u8) void {
    if (n.* + 3 > codes.len) return;
    if (colorNameToBasic(val)) |basic| {
        codes[n.*] = 30 + basic;
        n.* += 1;
    } else if (colorNameToIndex(val)) |idx| {
        appendIndexedColor(codes, n, idx, 30, 90, 38);
    }
}

fn appendBgCodes(codes: []u16, n: *usize, val: []const u8) void {
    if (n.* + 3 > codes.len) return;
    if (colorNameToBasic(val)) |basic| {
        codes[n.*] = 40 + basic;
        n.* += 1;
    } else if (colorNameToIndex(val)) |idx| {
        appendIndexedColor(codes, n, idx, 40, 100, 48);
    }
}

fn colorNameToBasic(name: []const u8) ?u16 {
    const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
    for (names, 0..) |nm, idx| {
        if (std.mem.eql(u8, name, nm)) return @intCast(idx);
    }
    return null;
}

/// Build a standalone SGR background-color escape from a color name (`green`)
/// or a 0-255 palette index (`22`). Returns "" for an empty or invalid value.
fn bgEscape(buf: []u8, val: []const u8) []const u8 {
    if (val.len == 0) return "";
    var codes: [4]u16 = undefined;
    var n: usize = 0;
    appendBgCodes(&codes, &n, val);
    if (n == 0) return "";
    var pos: usize = 0;
    const prefix = "\x1b[";
    if (pos + prefix.len > buf.len) return "";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    for (codes[0..n], 0..) |code, i| {
        if (i > 0) {
            if (pos >= buf.len) return "";
            buf[pos] = ';';
            pos += 1;
        }
        const s = std.fmt.bufPrint(buf[pos..], "{d}", .{code}) catch return "";
        pos += s.len;
    }
    if (pos >= buf.len) return "";
    buf[pos] = 'm';
    pos += 1;
    return buf[0..pos];
}

/// A single `$name` → value substitution entry for expandVars.
const VarSubst = struct { key: []const u8, val: []const u8 };

/// Expand `$name` placeholders in `tmpl` using the provided key-value pairs.
/// Writes the result into `buf` and returns the populated slice. Longer key
/// names must appear before shorter ones that share a prefix (e.g.
/// `shell_integration` before `shell`) to get the right match.
fn expandVars(buf: []u8, tmpl: []const u8, vars: []const VarSubst) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < tmpl.len and out < buf.len) {
        if (tmpl[i] == '$') {
            var matched = false;
            for (vars) |v| {
                if (i + 1 + v.key.len <= tmpl.len and
                    std.mem.eql(u8, tmpl[i + 1 ..][0..v.key.len], v.key))
                {
                    const copy_len = @min(v.val.len, buf.len - out);
                    @memcpy(buf[out..][0..copy_len], v.val[0..copy_len]);
                    out += copy_len;
                    i += 1 + v.key.len;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                buf[out] = tmpl[i];
                out += 1;
                i += 1;
            }
        } else {
            buf[out] = tmpl[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

inline fn effectivePalette(t: Theme, sys: Theme, dim: bool) Palette {
    return g_spec.paletteFor(t, sys, dim);
}

inline fn applyTerminalColors(stdout_fd: std.posix.fd_t, t: Theme, sys: Theme, alt_screen: bool) void {
    if (alt_screen) {
        const c = g_spec.terminalColors(t, sys);
        term_lib.applyTerminalColors(stdout_fd, c.bg, c.fg);
    }
}

inline fn queryCursorRow(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) ?i32 {
    return term_lib.queryCursorRow(stdin_fd, stdout_fd, raw);
}

inline fn detectSystemTheme(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) Theme {
    return term_lib.detectSystemTheme(stdin_fd, stdout_fd, raw);
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
    _ = sig;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(global_tty_fd, .NOW, &orig);
    }
    removePickerPidFile();
    logMemoryUsage();
    std.process.exit(1);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    if (global_orig_termios) |orig| {
        _ = std.posix.system.tcsetattr(global_tty_fd, .NOW, &orig);
    }
    clearTuiRows(global_tty_fd, global_tui_height, global_row_off);
    const seq = restoreSeq();
    _ = std.posix.system.write(global_tty_fd, seq.ptr, seq.len);
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
// POSIX file write at startup and an unlink on every exit path (§8).
// ---------------------------------------------------------------------------

fn pickerPidPath(buf: []u8) ?[:0]const u8 {
    const path = std.fmt.bufPrint(buf, "/tmp/emojig-picker-{d}.pid", .{getuid()}) catch return null;
    if (path.len + 1 > buf.len) return null;
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn writePickerPidFile() void {
    const path = pickerPidPath(&global_picker_pid_path_buf) orelse return;
    const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, wf, 0o600) catch return;
    defer _ = std.posix.system.close(fd);
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{getpid()}) catch return;
    _ = std.posix.system.write(fd, pid_str.ptr, pid_str.len);
    global_picker_pid_path = path;
}

fn removePickerPidFile() void {
    if (global_picker_pid_path) |path| {
        _ = unlink(path);
        global_picker_pid_path = null;
    }
}

/// If a previously spawned GUI picker is still alive (live PID recorded in
/// the pidfile), terminate it and return true so the launcher exits instead
/// of opening a second window. Stale pidfiles (dead or recycled PID) are
/// removed and ignored.
fn toggleRunningPicker() bool {
    var path_buf: [64]u8 = undefined;
    const path = pickerPidPath(&path_buf) orelse return false;
    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, rf, 0) catch return false;
    var pid_buf: [16]u8 = undefined;
    const n = std.posix.system.read(fd, &pid_buf, pid_buf.len);
    _ = std.posix.system.close(fd);
    if (n <= 0) return false;
    const pid_str = std.mem.trim(u8, pid_buf[0..@intCast(n)], &std.ascii.whitespace);
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch return false;
    if (pid <= 1) return false;

    // Guard against PID reuse: the recorded PID must still be an emojig process.
    var proc_buf: [48]u8 = undefined;
    const proc_path = std.fmt.bufPrint(&proc_buf, "/proc/{d}/cmdline", .{pid}) catch return false;
    const pfd = std.posix.openat(std.posix.AT.FDCWD, proc_path, rf, 0) catch {
        _ = unlink(path);
        return false;
    };
    var cmd_buf: [256]u8 = undefined;
    const cn = std.posix.system.read(pfd, &cmd_buf, cmd_buf.len);
    _ = std.posix.system.close(pfd);
    if (cn <= 0 or std.mem.indexOf(u8, cmd_buf[0..@intCast(cn)], "emojig") == null) {
        _ = unlink(path);
        return false;
    }

    std.posix.kill(pid, .TERM) catch return false;
    return true;
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
    cols: ?usize = null,
    rows: ?usize = null,
    border: ?bool = null,
    safe: ?bool = null,
    shell_integration: ?bool = null,
    shell_key_binding: ?[]const u8 = null,
    show_all_categories: ?bool = null,
    ambiguous_chars: ?[]const u8 = null,
    disabled_categories: ?[]const u8 = null,
    update_cmd: ?[]const u8 = null,
    scrollbar_style: ?ScrollbarStyle = null,
};

/// Look up the default value for a setting by ID from the loaded spec.
fn settingDefault(id: []const u8) []const u8 {
    for (g_spec.settings.options) |opt| {
        if (std.mem.eql(u8, opt.id, id)) return opt.default;
    }
    return "";
}

fn settingDefaultBool(id: []const u8) bool {
    const v = settingDefault(id);
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

/// Read configuration from the config file in a single pass.
fn loadConfig(arena: std.mem.Allocator, io: std.Io) Config {
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
            } else if (std.mem.eql(u8, key, "cols")) {
                cfg.cols = std.fmt.parseInt(usize, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "rows")) {
                cfg.rows = std.fmt.parseInt(usize, val, 10) catch null;
            } else if (std.mem.eql(u8, key, "border")) {
                cfg.border = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            } else if (std.mem.eql(u8, key, "safe")) {
                cfg.safe = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            } else if (std.mem.eql(u8, key, "shell_integration")) {
                cfg.shell_integration = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            } else if (std.mem.eql(u8, key, "shell_key_binding")) {
                cfg.shell_key_binding = arena.dupe(u8, val) catch null;
            } else if (std.mem.eql(u8, key, "show_all_categories")) {
                cfg.show_all_categories = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            } else if (std.mem.eql(u8, key, "ambiguous_chars")) {
                cfg.ambiguous_chars = arena.dupe(u8, val) catch null;
            } else if (std.mem.eql(u8, key, "disabled_categories")) {
                cfg.disabled_categories = arena.dupe(u8, val) catch null;
            } else if (std.mem.eql(u8, key, "update_cmd") or std.mem.eql(u8, key, "upd_cmd")) {
                cfg.update_cmd = arena.dupe(u8, val) catch null;
            } else if (std.mem.eql(u8, key, "scrollbar_style")) {
                if (std.mem.eql(u8, val, "bar")) cfg.scrollbar_style = .bar else if (std.mem.eql(u8, val, "expand")) cfg.scrollbar_style = .expand;
            }
        }
    }
    return cfg;
}

fn saveKeyToConfig(io: std.Io, key: []const u8, val: []const u8) void {
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

    // Read existing content
    var old_buf: [4096]u8 = undefined;
    var old_len: usize = 0;
    if (std.Io.Dir.openFileAbsolute(io, path, .{})) |rfile| {
        old_len = rfile.readPositionalAll(io, &old_buf, 0) catch 0;
        rfile.close(io);
        if (old_len == old_buf.len) return;
    } else |_| {}

    // Rebuild: every non-matching key, non-blank line, then the updated line.
    var out: [4096 + 128]u8 = undefined;
    var pos: usize = 0;
    var lines = std.mem.splitScalar(u8, old_buf[0..old_len], '\n');
    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}=", .{key}) catch return;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, prefix)) continue;
        if (pos + line.len + 1 >= out.len) break;
        @memcpy(out[pos..][0..line.len], line);
        pos += line.len;
        out[pos] = '\n';
        pos += 1;
    }

    // Append the updated key
    const val_line = std.fmt.bufPrint(out[pos..], "{s}={s}\n", .{ key, val }) catch "";
    pos += val_line.len;

    if (std.Io.Dir.createFileAbsolute(io, path, .{ .permissions = std.Io.Dir.Permissions.fromMode(0o600) })) |wfile| {
        _ = wfile.writePositionalAll(io, out[0..pos], 0) catch {};
        wfile.close(io);
    } else |_| {}
}

/// Rewrite the config file with an updated theme= line, preserving other keys.
fn saveThemeToConfig(io: std.Io, t: Theme) void {
    const theme_str: []const u8 = switch (t) {
        .dark => "dark",
        .light => "light",
        .system => "system",
    };
    saveKeyToConfig(io, "theme", theme_str);
}

fn ensureDirExists(home: []const u8, sub_path: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, sub_path }) catch return;
    if (path.len + 1 > path_buf.len) return;
    path_buf[path.len] = 0;
    _ = std.c.mkdir(path_buf[0..path.len :0], 0o755);
}

fn ensureDesktopIntegration(io: std.Io, home: []const u8, exe_path: []const u8) void {
    ensureDirExists(home, ".local");
    ensureDirExists(home, ".local/share");
    ensureDirExists(home, ".local/share/applications");
    ensureDirExists(home, ".local/share/icons");
    ensureDirExists(home, ".local/share/icons/hicolor");
    ensureDirExists(home, ".local/share/icons/hicolor/scalable");
    ensureDirExists(home, ".local/share/icons/hicolor/scalable/apps");
    ensureDirExists(home, ".local/share/icons/hicolor/128x128");
    ensureDirExists(home, ".local/share/icons/hicolor/128x128/apps");

    var exec_path_buf: [1024]u8 = undefined;
    var exec_path: []const u8 = exe_path;
    if (std.mem.indexOf(u8, exe_path, ".zig-cache") != null or std.mem.indexOf(u8, exe_path, "zig-out") != null) {
        const local_bin = std.fmt.bufPrint(&exec_path_buf, "{s}/.local/bin/emojig", .{home}) catch "";
        if (local_bin.len > 0) {
            if (std.posix.openat(std.posix.AT.FDCWD, local_bin, std.posix.O{ .ACCMODE = .RDONLY }, 0)) |fd| {
                _ = std.posix.system.close(fd);
                exec_path = local_bin;
            } else |_| {}
        }
    }

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
        \\Icon={s}/.local/share/icons/emojig-picker.png
        \\Terminal=false
        \\Categories=Utility;
        \\StartupWMClass=emojig-picker
        \\
    , .{ exec_path, home }) catch return;

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
    const svg_text = icon_svg;
    if (svg_path.len + 1 <= svg_path_buf.len) {
        svg_path_buf[svg_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, svg_path_buf[0..svg_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, svg_text.ptr, svg_text.len);
        } else |_| {}
    }

    // Write PNG icon to hicolor 128x128/apps
    var png_path_buf: [512]u8 = undefined;
    const png_path = std.fmt.bufPrint(&png_path_buf, "{s}/.local/share/icons/hicolor/128x128/apps/emojig-picker.png", .{home}) catch return;
    const png_data = icon_png;
    if (png_path.len + 1 <= png_path_buf.len) {
        png_path_buf[png_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, png_path_buf[0..png_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, png_data.ptr, png_data.len);
        } else |_| {}
    }

    // Write PNG icon directly to share/icons fallback
    var png_fallback_buf: [512]u8 = undefined;
    const png_fallback_path = std.fmt.bufPrint(&png_fallback_buf, "{s}/.local/share/icons/emojig-picker.png", .{home}) catch return;
    if (png_fallback_path.len + 1 <= png_fallback_buf.len) {
        png_fallback_buf[png_fallback_path.len] = 0;
        const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        if (std.posix.openat(std.posix.AT.FDCWD, png_fallback_buf[0..png_fallback_path.len :0], wf, 0o644)) |fd| {
            defer _ = std.posix.system.close(fd);
            _ = std.posix.system.write(fd, png_data.ptr, png_data.len);
        } else |_| {}
    }

    // Run update-desktop-database
    var app_dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&app_dir_buf, "{s}/.local/share/applications", .{home})) |app_dir| {
        var child = std.process.spawn(io, .{
            .argv = &.{ "update-desktop-database", app_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
        if (child) |*c| {
            _ = c.wait(io) catch {};
        }
    } else |_| {}

    // Run gtk-update-icon-cache
    var icon_dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&icon_dir_buf, "{s}/.local/share/icons/hicolor", .{home})) |icon_dir| {
        var child = std.process.spawn(io, .{
            .argv = &.{ "gtk-update-icon-cache", "-f", "-t", icon_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
        if (child) |*c| {
            _ = c.wait(io) catch {};
        }
    } else |_| {}
}

// ---------------------------------------------------------------------------
// Shell integration print / install
// ---------------------------------------------------------------------------

fn printCompletion(shell: []const u8, key: ?[]const u8) void {
    if (key) |k| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "EMOJIG_KEY='{s}'\n", .{k}) catch return;
        writeAll(std.posix.STDOUT_FILENO, line) catch {};
    }
    const script = if (std.mem.eql(u8, shell, "bash"))
        shell_bash
    else if (std.mem.eql(u8, shell, "fish"))
        shell_fish
    else if (std.mem.eql(u8, shell, "sh"))
        shell_sh
    else
        shell_zsh;
    writeAll(std.posix.STDOUT_FILENO, script) catch {};
}

fn detectShell(environ: anytype) []const u8 {
    const shell_env = environ.get("SHELL") orelse return "zsh";
    var it = std.mem.splitScalar(u8, shell_env, '/');
    var last: []const u8 = shell_env;
    while (it.next()) |part| {
        if (part.len > 0) last = part;
    }
    if (std.mem.eql(u8, last, "bash")) return "bash";
    if (std.mem.eql(u8, last, "fish")) return "fish";
    return "zsh";
}

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
    _ = std.posix.system.unlink(dst_buf[0..dst_path.len :0]);
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

/// Appends `line` to the file at `path` unless `marker` already appears in
/// the first 16 KiB.  Returns true when written, false when already present or
/// on error.
fn fileExists(home: []const u8, rel: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, rel }) catch return false;
    if (path.len + 1 > path_buf.len) return false;
    path_buf[path.len] = 0;
    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_buf[0..path.len :0], rf, 0) catch return false;
    _ = std.posix.system.close(fd);
    return true;
}

fn fileExistsAbs(comptime path: [:0]const u8) bool {
    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, rf, 0) catch return false;
    _ = std.posix.system.close(fd);
    return true;
}

fn captureShellCmd(io: std.Io, home: []const u8, cmd: []const u8, out: []u8) []const u8 {
    const log = "/tmp/emojig-update.log";
    var sh_buf: [2048]u8 = undefined;
    // Prepend well-known tool directories so the command finds zig/brew/etc.
    // even when launched from a desktop GUI with a stripped PATH.
    const sh_cmd = std.fmt.bufPrint(
        &sh_buf,
        "export PATH=\"/home/linuxbrew/.linuxbrew/bin:{s}/.linuxbrew/bin:{s}/.local/bin:/usr/local/bin:$PATH\"; {s} >{s} 2>&1",
        .{ home, home, cmd, log },
    ) catch {
        const msg = "Command string too long.";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    };
    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", sh_cmd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        const msg = "Failed to start update process.";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    };
    _ = child.wait(io) catch {};

    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, log, rf, 0) catch {
        const msg = "Update complete (no log).";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    };
    defer _ = std.posix.system.close(fd);
    const n = std.posix.system.read(fd, out.ptr, out.len);
    const read_len = if (n > 0) @as(usize, @intCast(n)) else 0;
    if (read_len == 0) {
        const msg = "Update complete.";
        @memcpy(out[0..msg.len], msg);
        return out[0..msg.len];
    }
    return out[0..read_len];
}

fn runUpdate(io: std.Io, home: []const u8, cfg_cmd: ?[]const u8, spec_cmd: ?[]const u8, out: []u8) []const u8 {
    var cmd_buf: [512]u8 = undefined;
    // Priority: config file > spec/commands.json cmd > auto-detect.
    var cmd: ?[]const u8 = if (cfg_cmd != null) cfg_cmd else spec_cmd;

    if (cmd != null) {
        // Explicit command configured — skip auto-detection.
    } else if (fileExists(home, "projects/emojig")) {
        cmd = std.fmt.bufPrint(&cmd_buf, "make -C '{s}/projects/emojig' update", .{home}) catch null;
    } else if (fileExistsAbs("/var/lib/dpkg/info/emojig.list")) {
        cmd = "sudo apt-get install -y emojig";
    } else if (fileExists(home, ".local/bin/emojig")) {
        cmd = "curl -sSf https://ubunatic.com/emojig/install.sh | sh";
    }

    if (cmd) |c| return captureShellCmd(io, home, c, out);

    const msg = "Unknown install mode.\nSee ~/.local/share/emojig/ for details.";
    const len = @min(msg.len, out.len);
    @memcpy(out[0..len], msg[0..len]);
    return out[0..len];
}

fn sourceRcFileAbs(path: []const u8, line: []const u8, marker: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    if (path.len + 1 > path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z = path_buf[0..path.len :0];

    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    if (std.posix.openat(std.posix.AT.FDCWD, path_z, rf, 0)) |rfd| {
        defer _ = std.posix.system.close(rfd);
        var content: [16384]u8 = undefined;
        const n = std.posix.read(rfd, &content) catch 0;
        if (std.mem.indexOf(u8, content[0..n], marker) != null) return false;
    } else |_| {}

    const af = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const afd = std.posix.openat(std.posix.AT.FDCWD, path_z, af, 0o644) catch return false;
    defer _ = std.posix.system.close(afd);
    _ = std.posix.system.write(afd, line.ptr, line.len);
    return true;
}

fn sourceRcFile(home: []const u8, rc_rel: []const u8, line: []const u8, marker: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, rc_rel }) catch return false;
    return sourceRcFileAbs(path, line, marker);
}

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

fn installShellIntegration(io: std.Io, home: []const u8, shell: []const u8, rc_override: ?[]const u8, writer: anytype) void {
    ensureDirExists(home, ".local");
    ensureDirExists(home, ".local/bin");
    ensureDirExists(home, ".local/share");
    ensureDirExists(home, ".local/share/emojig");
    ensureDirExists(home, ".local/share/emojig/shell");

    const bin_ok = copyBinary(io, home);

    var buf: [512]u8 = undefined;

    const sh_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.sh", .{home}) catch return;
    _ = writeFile(&buf, sh_path, shell_sh);

    const zsh_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.zsh", .{home}) catch return;
    _ = writeFile(&buf, zsh_path, shell_zsh);

    const bash_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.bash", .{home}) catch return;
    _ = writeFile(&buf, bash_path, shell_bash);

    const fish_path = std.fmt.bufPrint(&buf, "{s}/.local/share/emojig/shell/emojig.fish", .{home}) catch return;
    _ = writeFile(&buf, fish_path, shell_fish);

    var dst_buf: [1024]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/.local/bin/emojig", .{home}) catch "";
    if (dst_path.len > 0) {
        ensureDesktopIntegration(io, home, dst_path);
    }

    if (bin_ok) {
        writer.writeAll("Installed binary to ~/.local/bin/emojig\n") catch {};
    } else {
        writer.writeAll("Warning: could not copy binary to ~/.local/bin/emojig\n") catch {};
    }

    writer.writeAll("Installed shell integration to ~/.local/share/emojig/shell/\n") catch {};

    // Fish cannot source POSIX sh — use emojig.fish directly in config.fish.
    // All other shells (zsh, bash, unknown) use the generic emojig.sh dispatcher.
    const is_fish = std.mem.eql(u8, shell, "fish");
    const sh_source_line = "\nif test -f ~/.local/share/emojig/shell/emojig.sh\nthen source ~/.local/share/emojig/shell/emojig.sh\nfi\n";
    const sh_marker = "emojig/shell/emojig.sh";
    const fish_source_line = "\nif test -f ~/.local/share/emojig/shell/emojig.fish\n  source ~/.local/share/emojig/shell/emojig.fish\nend\n";
    const fish_marker = "emojig/shell/emojig.fish";

    if (rc_override) |rc| {
        // --rc always uses the sh dispatcher (fish users don't set --rc to a sh file).
        var abs_buf: [512]u8 = undefined;
        const abs_path = if (rc[0] == '/')
            rc
        else
            (std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ home, rc }) catch return);
        const added = sourceRcFileAbs(abs_path, sh_source_line, sh_marker);
        var msg_buf: [512]u8 = undefined;
        const display = if (rc[0] == '/') rc else (std.fmt.bufPrint(&msg_buf, "~/{s}", .{rc}) catch rc);
        var out_buf: [600]u8 = undefined;
        if (added) {
            const out = std.fmt.bufPrint(&out_buf, "Added to {s} — reload your shell and press Ctrl+E.\n", .{display}) catch return;
            writer.writeAll(out) catch {};
        } else {
            const out = std.fmt.bufPrint(&out_buf, "Already in {s} — press Ctrl+E at any prompt.\n", .{display}) catch return;
            writer.writeAll(out) catch {};
        }
    } else if (is_fish) {
        ensureDirExists(home, ".config");
        ensureDirExists(home, ".config/fish");
        const added = sourceRcFile(home, ".config/fish/config.fish", fish_source_line, fish_marker);
        if (added) {
            writer.writeAll("Added to ~/.config/fish/config.fish — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.config/fish/config.fish — press Ctrl+E at any prompt.\n") catch {};
        }
    } else if (fileExists(home, ".userrc")) {
        const added = sourceRcFile(home, ".userrc", sh_source_line, sh_marker);
        if (added) {
            writer.writeAll("Added to ~/.userrc — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.userrc — press Ctrl+E at any prompt.\n") catch {};
        }
    } else if (std.mem.eql(u8, shell, "zsh")) {
        const added = sourceRcFile(home, ".zshrc", sh_source_line, sh_marker);
        if (added) {
            writer.writeAll("Added to ~/.zshrc — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.zshrc — press Ctrl+E at any prompt.\n") catch {};
        }
    } else if (std.mem.eql(u8, shell, "bash")) {
        const added = sourceRcFile(home, ".bashrc", sh_source_line, sh_marker);
        if (added) {
            writer.writeAll("Added to ~/.bashrc — reload your shell and press Ctrl+E.\n") catch {};
        } else {
            writer.writeAll("Already in ~/.bashrc — press Ctrl+E at any prompt.\n") catch {};
        }
    } else {
        writer.writeAll("\nAdd one line to your shell rc file:\n\n" ++
            "  zsh/bash  (~/.zshrc or ~/.bashrc):\n" ++
            "    source ~/.local/share/emojig/shell/emojig.sh\n\n" ++
            "  fish (~/.config/fish/config.fish):\n" ++
            "    source ~/.local/share/emojig/shell/emojig.fish\n\n" ++
            "Then reload your shell and press Ctrl+E at any prompt.\n") catch {};
    }
}

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
            g_wide_ambiguous = !std.mem.eql(u8, amb_chars.*, "narrow");
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

/// Persist a numeric setting (e.g. grid `cols`/`rows`) to the config file.
fn saveUsizeToConfig(io: std.Io, key: []const u8, val: usize) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
    saveKeyToConfig(io, key, s);
}

/// Nudge a grid dimension by ±1 within `[min, max]` (Left/Right fine-tune).
fn stepGridDim(val: usize, increase: bool, min: usize, max: usize) usize {
    const next = if (increase) val + 1 else (if (val > min) val - 1 else min);
    return @max(min, @min(next, max));
}

/// Cycle a grid dimension by a larger step within `[min, max]`, wrapping back
/// to `min` once it would overflow (Space/Enter coarse adjust).
fn cycleGridDim(val: usize, step: usize, min: usize, max: usize) usize {
    return if (val + step > max) min else @max(min, val + step);
}

/// Clamp a freshly edited grid dimension to `[min, max]`, persisting the
/// corrected value if it changed. Called when a digit-typing run ends so a
/// transient sub-minimum entry (e.g. a lone "1" en route to "12") is fixed up.
fn clampGridDim(val: usize, min: usize, max: usize) usize {
    return @max(min, @min(val, max));
}

fn finalizeGridDim(io: std.Io, val: *usize, key: []const u8, min: usize, max: usize) void {
    const clamped = clampGridDim(val.*, min, max);
    if (clamped != val.*) {
        val.* = clamped;
        saveUsizeToConfig(io, key, clamped);
    }
}

/// End a digit-typing run on whichever grid-size settings row (`sel` 6 = cols,
/// 7 = rows) was being edited, clamping the value up to its minimum. A lone "1"
/// typed en route to "12" stays below the minimum while typing; this fixes it
/// the moment focus leaves the row.
fn finalizeGridTyping(io: std.Io, sel: ?usize, cols: *usize, rows: *usize) void {
    const s = sel orelse return;
    if (s == 6) finalizeGridDim(io, cols, "cols", defaults.MIN_COLS, defaults.MAX_COLS);
    if (s == 7) finalizeGridDim(io, rows, "rows", defaults.MIN_ROWS, defaults.MAX_ROWS);
}

/// Apply a grid-dimension mouse click on a settings row by hit-zone:
/// the `[‹ NN ›]` widget splits into `‹` (decrement), the number (select-only,
/// for keyboard entry), and `›` (increment). `local_col` is the 0-indexed
/// display column of the click. Returns true if the value changed.
fn applyGridDimClick(io: std.Io, is_cols: bool, local_col: i32, val: *usize) bool {
    const min = if (is_cols) defaults.MIN_COLS else defaults.MIN_ROWS;
    const max = if (is_cols) defaults.MAX_COLS else defaults.MAX_ROWS;
    if (local_col >= 3 and local_col <= 5) {
        val.* = stepGridDim(val.*, false, min, max);
    } else if (local_col >= 8 and local_col <= 10) {
        val.* = stepGridDim(val.*, true, min, max);
    } else {
        return false; // middle (the digits): just select for keyboard entry
    }
    saveUsizeToConfig(io, if (is_cols) "cols" else "rows", val.*);
    return true;
}

/// Append a digit to a grid dimension, clamped to `[1, max]`. `continuing`
/// chains digits within one typing run (1 then 2 → 12); otherwise the digit
/// starts a fresh value.
fn typeGridDim(val: *usize, digit: u8, continuing: bool, max: usize) void {
    const d: usize = digit - '0';
    var nv: usize = if (continuing) val.* * 10 + d else d;
    if (nv > max) nv = max;
    val.* = @max(1, nv);
}

fn saveDisabledCategories(io: std.Io, cats: []const emojig.CategorySpec, disabled_cats: []const bool) void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();
    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(allocator);
    for (cats, 0..) |cat, i| {
        if (i < disabled_cats.len and disabled_cats[i]) {
            list.append(allocator, cat.name) catch {};
        }
    }
    const joined = std.mem.join(allocator, ",", list.items) catch "";
    saveKeyToConfig(io, "disabled_categories", joined);
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
    g_colors = &g_spec.colors;

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
        var rctx = resize.ResizeContext.init(resize_mode);
        var last_drawn_h: usize = final_h;
        // Declared here (before the defer) so the defer body can read it.
        // Set to true when the user selects an emoji (copy-and-exit path).
        var should_copy_and_exit = false;

        defer {
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

        var current_screen: ScreenState = .search;
        var cat_scroll_top: usize = 0;
        var settings_scroll_top: usize = 0;
        // Number of rows on the Settings screen (JSON toggles + theme + scrollbar).
        const settings_count: usize = 8;
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
        g_wide_ambiguous = !std.mem.eql(u8, ambiguous_chars, "narrow");

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

        var read_buf: [64]u8 = undefined;
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
            var cmd_matches: [8]usize = undefined;
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
            const skip_render = !is_first_render and !exit_preview and
                last_was_motion and
                (tui.poll(stdin_fd, pipe_rd, 0) == .tty);
            if (!skip_render and (exit_preview or !should_copy_and_exit)) {
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
                }

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
                            // The spec prompt carries a leading margin space for mojigo's
                            // layout; the Zig renderer emits its own margin above, so trim it.
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
                                const name = emojig.EmojiDb.getEntry(top_matches[sel].index).name;
                                if (name.len > max_len and max_len >= 3) {
                                    const display_name = name[0 .. max_len - 3];
                                    const printed_cols = 1 + display_name.len + 3;
                                    const pad_len_desc = if (content_width > printed_cols) content_width - printed_cols else 0;
                                    const name_line = try std.fmt.bufPrint(&line_buf, " {s}{s} {s}...{s}", .{ palette.info_bg, palette.info_fg, display_name, spaces[0..@min(pad_len_desc, spaces.len)] });
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
            var timeout_ms: i32 = if (active_timeout) |t_sec|
                @as(i32, @intCast(@min(t_sec, @as(c_uint, 2_147)))) * 1_000
            else
                -1;

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

            var n = readStdin(stdin_fd, &read_buf) catch |err| {
                if (err == error.SystemResources or err == error.Interrupted) continue;
                return err;
            };
            if (n == 0) break;

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
                    } else if (bytes[2] == 'A') {
                        logical = "up";
                    } else if (bytes[2] == 'B') {
                        logical = "down";
                    } else if (bytes[2] == 'C') {
                        logical = "right";
                    } else if (bytes[2] == 'D') {
                        logical = "left";
                    } else if (std.mem.eql(u8, bytes[2..n], "5~")) {
                        logical = "pageup";
                    } else if (std.mem.eql(u8, bytes[2..n], "6~")) {
                        logical = "pagedown";
                    } else if (bytes[2] == 'H' or std.mem.eql(u8, bytes[2..n], "1~") or std.mem.eql(u8, bytes[2..n], "7~")) {
                        logical = "home";
                    } else if (bytes[2] == 'F' or std.mem.eql(u8, bytes[2..n], "4~") or std.mem.eql(u8, bytes[2..n], "8~")) {
                        logical = "end";
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
                        const click_row_raw = std.fmt.parseInt(i32, row_str, 10) catch continue;
                        const local_col = click_col - 1;

                        // Map absolute viewport row to TUI-relative row (accounting for cursor start and potential scroll).
                        const click_row = term_lib.mapSgrRow(click_row_raw, global_tui_start_row, global_tty_fd, final_h);

                        const is_motion = (button & 32) != 0;
                        const btn_id = button & 3; // 0=left, 1=mid, 2=right, 3=no-button
                        const is_wheel = (button & 64) != 0;
                        last_was_motion = is_motion;

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
                                const on_sb = btn_id == 0 and local_col == @as(i32, @intCast(content_width)) and total_rows > rows;
                                if (on_sb) {
                                    // Scrollbar drag: map the track row to a scroll offset.
                                    const tg = scrollbarThumb(scrollbar_style, rows, total_rows);
                                    const max_scroll = total_rows - rows;
                                    const track_row = @as(usize, @intCast(click_row - grid_first_row));
                                    if (tg.travel > 0) grid_scroll_top = @min(track_row * max_scroll / tg.travel, max_scroll);
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
                                continue;
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
                                        // Scrollbar click-to-jump.
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
                    }
                } else if (n > 2 and bytes[1] == 'O') {
                    // Arrow keys — application cursor key mode (\x1bOA/B/C/D).
                    // ZLE keeps the terminal in smkx (application mode) during widget execution.
                    if (bytes[2] == 'A') {
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
                                }
                            }
                        } else if (std.mem.eql(u8, action, "delete")) {
                            if (query_cursor > 0) {
                                deleteAtCursor(&query_buf, &query_len, &query_cursor);
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
                                if (selected_idx) |sel| {
                                    if (sel < top_count) {
                                        const entry = emojig.EmojiDb.getEntry(top_matches[sel].index);
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
                                // no cursor → no-op
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
                                    if (query_cursor < query_len) query_cursor += 1;
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
                                } else {
                                    selected_idx = navSelect(action, sel, top_count, cols, trows);
                                }
                                if (selected_idx) |s| {
                                    adjustScrollTop(s / cc, &grid_scroll_top, vp, trows);
                                } else {
                                    grid_scroll_top = 0;
                                }
                            }
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

test "color names from spec/colors.json resolve to palette indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    g_spec = try spec_mod.load(arena.allocator(), null);
    g_colors = &g_spec.colors;
    defer g_colors = null;

    // Long names, 3-letter shorts, popular names, and systematic cube/gray names.
    try std.testing.expectEqual(@as(?u16, 2), colorNameToIndex("grn"));
    try std.testing.expectEqual(@as(?u16, 208), colorNameToIndex("orange"));
    try std.testing.expectEqual(@as(?u16, 208), colorNameToIndex("org"));
    try std.testing.expectEqual(@as(?u16, 22), colorNameToIndex("forest"));
    try std.testing.expectEqual(@as(?u16, 232), colorNameToIndex("gray0"));
    // alt alias keeps the systematic name reachable for renamed slots.
    try std.testing.expectEqual(@as(?u16, 208), colorNameToIndex("rgb520"));
    // Numeric fallback and unknown names.
    try std.testing.expectEqual(@as(?u16, 240), colorNameToIndex("240"));
    try std.testing.expectEqual(@as(?u16, null), colorNameToIndex("not-a-color"));

    // Verify refactored color system:
    // a) long name "Midnight Blue" (case-insensitive & space/punctuation-insensitive)
    try std.testing.expectEqual(@as(?u16, 24), colorNameToIndex("Midnight Blue"));
    try std.testing.expectEqual(@as(?u16, 24), colorNameToIndex("midnight blue"));
    try std.testing.expectEqual(@as(?u16, 24), colorNameToIndex("midnight-blue"));
    // b) short name "blue"
    try std.testing.expectEqual(@as(?u16, 12), colorNameToIndex("blue"));
    // c) 3-letter names "blu"
    try std.testing.expectEqual(@as(?u16, 12), colorNameToIndex("blu"));
    // d) ansi color number: 220
    try std.testing.expectEqual(@as(?u16, 220), colorNameToIndex("220"));
    // e) short or long hex: "#fff" "#ffffff"
    try std.testing.expectEqual(@as(?u16, 15), colorNameToIndex("#fff"));
    try std.testing.expectEqual(@as(?u16, 15), colorNameToIndex("#ffffff"));
    // hex closest match fallback
    try std.testing.expectEqual(@as(?u16, 24), colorNameToIndex("#005f86"));

    // Extended-form escape for a named colour beyond the 16 system slots.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[48;5;208m", bgEscape(&buf, "orange"));
    // A 3-letter short for a system colour uses the compact 4X form.
    try std.testing.expectEqualStrings("\x1b[42m", bgEscape(&buf, "grn"));
}
