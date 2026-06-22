// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const config = @import("config.zig");
const spec_mod = @import("spec.zig");
const color = @import("color.zig");

pub const ScrollbarStyle = config.ScrollbarStyle;

pub var g_wide_ambiguous: bool = true;

pub fn scrollbarThumb(style: ScrollbarStyle, viewport_h: usize, total: usize) struct { thumb_h: usize, travel: usize } {
    if (total <= viewport_h or viewport_h == 0) return .{ .thumb_h = viewport_h, .travel = 0 };
    const thumb_h: usize = switch (style) {
        .bar => 1,
        .expand => @max(1, viewport_h * viewport_h / total),
    };
    const th = @min(thumb_h, viewport_h);
    return .{ .thumb_h = th, .travel = viewport_h - th };
}

/// Delete the byte immediately before the text cursor and shift the tail left
/// (a backspace at an arbitrary cursor position). No-op when the cursor is at
/// the start. Mutates query_len and query_cursor in lock-step.
pub fn deleteAtCursor(query_buf: []u8, query_len: *usize, query_cursor: *usize) void {
    if (query_cursor.* == 0 or query_len.* == 0) return;
    const c = query_cursor.*;
    if (c < query_len.*) {
        std.mem.copyForwards(u8, query_buf[c - 1 .. query_len.* - 1], query_buf[c..query_len.*]);
    }
    query_len.* -= 1;
    query_cursor.* -= 1;
}

pub fn forwardDeleteAtCursor(query_buf: []u8, query_len: *usize, query_cursor: *usize) void {
    const c = query_cursor.*;
    if (c >= query_len.*) return;
    std.mem.copyForwards(u8, query_buf[c .. query_len.* - 1], query_buf[c + 1 .. query_len.*]);
    query_len.* -= 1;
}

pub fn wordLeft(buf: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0 and buf[i - 1] == ' ') i -= 1;
    while (i > 0 and buf[i - 1] != ' ') i -= 1;
    return i;
}

pub fn wordRight(buf: []const u8, len: usize, cursor: usize) usize {
    var i = cursor;
    while (i < len and buf[i] != ' ') i += 1;
    while (i < len and buf[i] == ' ') i += 1;
    return i;
}

/// Emit a single BEL to acknowledge an ignored/dead key, but only once per run
/// of consecutive ignored keys. `armed` is true when the previous key event was
/// *not* itself an ignored key; this routine then re-suppresses so a repeat is
/// silent. The terminal's own bell config decides audible vs. visual vs. silent.
pub fn ringBell(armed: bool, suppressed: *bool) void {
    if (armed) {
        _ = std.posix.system.write(std.posix.STDOUT_FILENO, "\x07", 1);
    }
    suppressed.* = true;
}

/// Apply a "nav_*" action (from spec/keys.json) to the current grid selection,
/// returning the new index. Wrapping mirrors the historical arrow-key behavior.
pub fn navSelect(action: []const u8, sel_in: usize, count: usize, cols: usize, rows: usize) usize {
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

pub fn ansiDisplayWidth(text: []const u8) usize {
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
pub fn formatStatus(buf: []u8, tmpl: []const u8, total: usize) ![]const u8 {
    const ph = "{count}";
    if (std.mem.indexOf(u8, tmpl, ph)) |pos| {
        return std.fmt.bufPrint(buf, "{s}{d}{s}", .{ tmpl[0..pos], total, tmpl[pos + ph.len ..] });
    }
    return tmpl;
}

/// Expand a status template with variable substitution and style spans.
pub fn expandTemplate(
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
                while (j < tmpl.len and color.styleIdentChar(tmpl[j])) j += 1;
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
                    const sgr = color.buildSgr(&sgr_buf, attrs_str, styles);
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
