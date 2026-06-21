// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const term = @import("term.zig");
const spec_mod = @import("spec.zig");

pub const Theme = term.Theme;
pub const Palette = term.Palette;

pub var g_colors: ?*const spec_mod.ColorsSpec = null;

pub fn styleIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn buildSgr(buf: []u8, attrs_str: []const u8, styles: *const spec_mod.StylesSpec) []const u8 {
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

pub fn collectSgrCodes(
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
pub fn appendIndexedColor(codes: []u16, n: *usize, idx: u16, normal: u16, bright: u16, ext: u16) void {
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
pub fn colorNameToIndex(val: []const u8) ?u16 {
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

pub fn appendFgCodes(codes: []u16, n: *usize, val: []const u8) void {
    if (n.* + 3 > codes.len) return;
    if (colorNameToBasic(val)) |basic| {
        codes[n.*] = 30 + basic;
        n.* += 1;
    } else if (colorNameToIndex(val)) |idx| {
        appendIndexedColor(codes, n, idx, 30, 90, 38);
    }
}

pub fn appendBgCodes(codes: []u16, n: *usize, val: []const u8) void {
    if (n.* + 3 > codes.len) return;
    if (colorNameToBasic(val)) |basic| {
        codes[n.*] = 40 + basic;
        n.* += 1;
    } else if (colorNameToIndex(val)) |idx| {
        appendIndexedColor(codes, n, idx, 40, 100, 48);
    }
}

pub fn colorNameToBasic(name: []const u8) ?u16 {
    const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
    for (names, 0..) |nm, idx| {
        if (std.mem.eql(u8, name, nm)) return @intCast(idx);
    }
    return null;
}

/// Build a standalone SGR background-color escape from a color name (`green`)
/// or a 0-255 palette index (`22`). Returns "" for an empty or invalid value.
pub fn bgEscape(buf: []u8, val: []const u8) []const u8 {
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
pub const VarSubst = struct { key: []const u8, val: []const u8 };

/// Expand `$name` placeholders in `tmpl` using the provided key-value pairs.
/// Writes the result into `buf` and returns the populated slice. Longer key
/// names must appear before shorter ones that share a prefix (e.g.
/// `shell_integration` before `shell`) to get the right match.
pub fn expandVars(buf: []u8, tmpl: []const u8, vars: []const VarSubst) []const u8 {
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

pub fn effectivePalette(spec: *const spec_mod.Spec, t: Theme, sys: Theme, dim: bool) Palette {
    return spec.paletteFor(t, sys, dim);
}

pub fn applyTerminalColors(spec: *const spec_mod.Spec, stdout_fd: std.posix.fd_t, t: Theme, sys: Theme, alt_screen: bool) void {
    if (alt_screen) {
        const c = spec.terminalColors(t, sys);
        term.applyTerminalColors(stdout_fd, c.bg, c.fg);
    }
}

pub fn queryCursorRow(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) ?i32 {
    return term.queryCursorRow(stdin_fd, stdout_fd, raw);
}

pub fn detectSystemTheme(stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, raw: std.posix.termios) Theme {
    return term.detectSystemTheme(stdin_fd, stdout_fd, raw);
}

test "color names from spec/colors.json resolve to palette indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec = try spec_mod.load(arena.allocator(), null);
    g_colors = &spec.colors;
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
