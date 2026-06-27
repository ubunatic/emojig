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

// Lower block chars: index = eighths filled from the bottom (0=space, 8=full █).
const lower_blocks = [9][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

pub const SbCell = struct { char: []const u8, invert: bool };

/// Thumb top position in eighths of a cell for `.expand` smooth scrollbars.
/// `travel` is `scrollbarThumb(...).travel` (whole cells).
pub fn smoothScrollPos(scroll_top: usize, max_scroll: usize, travel: usize) usize {
    if (max_scroll == 0 or travel == 0) return 0;
    return scroll_top * travel * 8 / max_scroll;
}

/// Per-row block character for a smooth `.expand` scrollbar.
/// `pos_eighths` = thumb top position (from `smoothScrollPos`).
/// Returns the char to emit and whether to apply reverse-video (for top caps).
pub fn scrollbarCell(pos_eighths: usize, thumb_h: usize, row: usize) SbCell {
    const row_s8 = row * 8;
    const thumb_end = pos_eighths + thumb_h * 8;
    const fill_start: usize = if (pos_eighths > row_s8) @min(pos_eighths - row_s8, 8) else 0;
    const fill_end: usize = if (thumb_end > row_s8) @min(thumb_end - row_s8, 8) else 0;
    if (fill_end <= fill_start) return .{ .char = " ", .invert = false };
    const fill = fill_end - fill_start;
    if (fill >= 8) return .{ .char = "█", .invert = false };
    // top cap: thumb fills top fill_end/8 — use reverse video so rail bg becomes fg
    if (fill_start == 0) return .{ .char = lower_blocks[8 - fill_end], .invert = true };
    // bottom cap: thumb fills bottom (8-fill_start)/8 — normal fg=thumb color
    return .{ .char = lower_blocks[8 - fill_start], .invert = false };
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
/// Substitute {icon} within a raw content slice into out_buf[out..].
/// Returns the new `out` offset.
fn substIcon(out_buf: []u8, out: usize, content: []const u8, icon: []const u8) usize {
    var o = out;
    var k: usize = 0;
    while (k < content.len and o < out_buf.len) {
        if (std.mem.startsWith(u8, content[k..], "{icon}")) {
            const n = @min(icon.len, out_buf.len - o);
            @memcpy(out_buf[o..][0..n], icon[0..n]);
            o += n;
            k += "{icon}".len;
        } else {
            out_buf[o] = content[k];
            o += 1;
            k += 1;
        }
    }
    return o;
}

pub fn expandTemplate(
    buf: []u8,
    tmpl: []const u8,
    styles: *const spec_mod.StylesSpec,
    count: usize,
    search_bg: []const u8,
) []const u8 {
    return expandTemplateIcon(buf, tmpl, styles, count, search_bg, "");
}

pub fn expandTemplateIcon(
    buf: []u8,
    tmpl: []const u8,
    styles: *const spec_mod.StylesSpec,
    count: usize,
    search_bg: []const u8,
    icon: []const u8,
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
            } else if (std.mem.startsWith(u8, tmpl[i..], "{icon}")) {
                const n = @min(icon.len, buf.len - out);
                @memcpy(buf[out..][0..n], icon[0..n]);
                out += n;
                i += "{icon}".len;
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
                    // Expand {icon} within the styled content.
                    out = substIcon(buf, out, content, icon);
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

pub fn adjustScrollTop(selected_idx: usize, scroll_top: *usize, viewport_h: usize, total_items: usize) void {
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

test "scrollbarCell smooth sub-character positioning" {
    // thumb_h=1 at pos_eighths=0: row 0 is a full cell, row 1 is rail.
    const full = scrollbarCell(0, 1, 0);
    try std.testing.expectEqualStrings("█", full.char);
    try std.testing.expect(!full.invert);
    try std.testing.expectEqualStrings(" ", scrollbarCell(0, 1, 1).char);

    // thumb_h=1 at pos_eighths=4 (half a cell down):
    //   row 0: bottom cap — lower 4/8 filled (▄), normal colors
    const bot = scrollbarCell(4, 1, 0);
    try std.testing.expectEqualStrings("▄", bot.char);
    try std.testing.expect(!bot.invert);
    //   row 1: top cap — top 4/8 filled (▄), inverted colors
    const top = scrollbarCell(4, 1, 1);
    try std.testing.expectEqualStrings("▄", top.char);
    try std.testing.expect(top.invert);

    // thumb_h=2 at pos_eighths=0: rows 0 and 1 full, row 2 rail.
    try std.testing.expectEqualStrings("█", scrollbarCell(0, 2, 0).char);
    try std.testing.expectEqualStrings("█", scrollbarCell(0, 2, 1).char);
    try std.testing.expectEqualStrings(" ", scrollbarCell(0, 2, 2).char);

    // thumb_h=1 at pos_eighths=2: bottom 6/8 of row 0 filled (▆), top 2/8 of row 1 filled (inverted ▆).
    const b2 = scrollbarCell(2, 1, 0);
    try std.testing.expectEqualStrings("▆", b2.char);
    try std.testing.expect(!b2.invert);
    const t2 = scrollbarCell(2, 1, 1);
    try std.testing.expectEqualStrings("▆", t2.char);
    try std.testing.expect(t2.invert);

    // smoothScrollPos: at max scroll the thumb sits exactly at the bottom.
    // viewport=4, total=16 -> thumb_h=1, travel=3, max_scroll=12
    const tg = scrollbarThumb(.expand, 4, 16);
    const pos_max = smoothScrollPos(12, 12, tg.travel); // scroll_top == max_scroll
    try std.testing.expectEqual(tg.travel * 8, pos_max); // thumb top at last row*8, no overflow
}
