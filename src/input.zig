// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

/// Spec-driven escape-key decoder. Tries a reverse-lookup in the YAML-spec's
/// `key_aliases` table (sequence → name) before falling back to the hardcoded
/// table in `decodeEscapeKey` for alternative terminal encodings (SS3 cursor
/// keys, Kitty protocol sequences, etc.) not listed in the spec.
pub fn decodeEscapeKeySpec(
    bytes: []const u8,
    key_aliases: std.json.ArrayHashMap([]const u8),
) ?[]const u8 {
    if (bytes.len == 0 or bytes[0] != 27) return null;
    var it = key_aliases.map.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, bytes)) return entry.key_ptr.*;
    }
    return decodeEscapeKey(bytes);
}

pub const SgrMouseEvent = struct {
    button: i32,
    click_col: i32,
    click_row_raw: i32,
    term_char: u8,
    has_more: bool,
};

/// Translate escape-sequence bytes into the logical key names used by the
/// binding table. Returns null for sequences that are not handled here.
pub fn decodeEscapeKey(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[0] != 27) return null;
    if (bytes.len == 1) return "esc";
    if (bytes.len == 2 and bytes[1] == '.') return "ctrl-.";
    if (bytes.len > 2 and bytes[1] == '[') {
        if (std.mem.eql(u8, bytes[2..], "27;5;46~") or std.mem.eql(u8, bytes[2..], "46;5u")) {
            return "ctrl-.";
        }
        if (std.mem.eql(u8, bytes[2..], "27;2;13~") or std.mem.eql(u8, bytes[2..], "13;2u")) {
            return "shift-enter";
        }
        if (std.mem.eql(u8, bytes[2..], "27;5;13~") or std.mem.eql(u8, bytes[2..], "13;5u")) {
            return "ctrl-enter";
        }
        if (bytes.len >= 6 and bytes[2] == '1' and bytes[3] == ';' and bytes[5] == 'S' and
            (bytes[4] == '3' or bytes[4] == '9'))
        {
            return null;
        }
        if (std.mem.eql(u8, bytes[2..], "1;5C") or std.mem.eql(u8, bytes[2..], "5C")) {
            return "ctrl-right";
        }
        if (std.mem.eql(u8, bytes[2..], "1;5D") or std.mem.eql(u8, bytes[2..], "5D")) {
            return "ctrl-left";
        }
        if (bytes[2] == 'A') return "up";
        if (bytes[2] == 'B') return "down";
        if (bytes[2] == 'C') return "right";
        if (bytes[2] == 'D') return "left";
        if (bytes[2] == 'Z') return "shift-tab";
        if (std.mem.eql(u8, bytes[2..], "3~")) return "del";
        if (std.mem.eql(u8, bytes[2..], "5~")) return "pageup";
        if (std.mem.eql(u8, bytes[2..], "6~")) return "pagedown";
        if (bytes[2] == 'H' or std.mem.eql(u8, bytes[2..], "1~") or std.mem.eql(u8, bytes[2..], "7~")) return "home";
        if (bytes[2] == 'F' or std.mem.eql(u8, bytes[2..], "4~") or std.mem.eql(u8, bytes[2..], "8~")) return "end";
    } else if (bytes.len > 2 and bytes[1] == 'O') {
        if (bytes[2] == 'c') return "ctrl-right";
        if (bytes[2] == 'd') return "ctrl-left";
        if (bytes[2] == 'A') return "up";
        if (bytes[2] == 'B') return "down";
        if (bytes[2] == 'C') return "right";
        if (bytes[2] == 'D') return "left";
        if (bytes[2] == 'H') return "home";
        if (bytes[2] == 'F') return "end";
        if (bytes[2] == 'P') return "f1";
    }
    return null;
}

/// Parse the next SGR mouse event from a read buffer that begins with ESC[<.
/// `sgr_off` is updated to the byte position after the parsed event, and
/// `has_more` reports whether another complete event follows immediately.
pub fn nextSgrMouseEvent(bytes: []const u8, sgr_off: *usize, carry: []u8, carry_len: *usize) ?SgrMouseEvent {
    const base = 3 + sgr_off.*;
    if (base >= bytes.len) return null;
    const sgr_data = bytes[base..];

    var term_pos: usize = 0;
    var term_char: u8 = 0;
    while (term_pos < sgr_data.len) : (term_pos += 1) {
        if (sgr_data[term_pos] == 'M' or sgr_data[term_pos] == 'm') {
            term_char = sgr_data[term_pos];
            break;
        }
    }
    if (term_char == 0) {
        const tail_len = 3 + sgr_data.len;
        if (tail_len <= carry.len) {
            carry[0] = 0x1b;
            carry[1] = '[';
            carry[2] = '<';
            @memcpy(carry[3..][0..sgr_data.len], sgr_data);
            carry_len.* = tail_len;
        }
        return null;
    }

    var it = std.mem.splitScalar(u8, sgr_data[0..term_pos], ';');
    const button_str = it.next() orelse return null;
    const col_str = it.next() orelse return null;
    const row_str = it.next() orelse return null;

    const button = std.fmt.parseInt(i32, button_str, 10) catch return null;
    const click_col = std.fmt.parseInt(i32, col_str, 10) catch return null;
    const click_row_raw = std.fmt.parseInt(i32, row_str, 10) catch return null;

    sgr_off.* += term_pos + 1;
    const next = 3 + sgr_off.*;
    const has_more = next + 2 < bytes.len and bytes[next] == 0x1b and bytes[next + 1] == '[' and bytes[next + 2] == '<';
    if (has_more) sgr_off.* += 3;

    return .{
        .button = button,
        .click_col = click_col,
        .click_row_raw = click_row_raw,
        .term_char = term_char,
        .has_more = has_more,
    };
}

test "decodeEscapeKey maps cursor and function keys" {
    try std.testing.expectEqualStrings("up", decodeEscapeKey("\x1b[A").?);
    try std.testing.expectEqualStrings("down", decodeEscapeKey("\x1bOB").?);
    try std.testing.expectEqualStrings("f1", decodeEscapeKey("\x1bOP").?);
    try std.testing.expectEqualStrings("ctrl-right", decodeEscapeKey("\x1b[1;5C").?);
}

test "decodeEscapeKeySpec uses spec aliases then falls back to hardcoded" {
    var map = std.json.ArrayHashMap([]const u8){};
    try map.map.put(std.testing.allocator, "up", "\x1b[A");
    try map.map.put(std.testing.allocator, "pageup", "\x1b[5~");
    defer map.map.deinit(std.testing.allocator);

    // spec hit: canonical CSI form
    try std.testing.expectEqualStrings("up", decodeEscapeKeySpec("\x1b[A", map).?);
    // spec hit: pageup
    try std.testing.expectEqualStrings("pageup", decodeEscapeKeySpec("\x1b[5~", map).?);
    // fallback: SS3 down not in spec
    try std.testing.expectEqualStrings("down", decodeEscapeKeySpec("\x1bOB", map).?);
    // fallback: ctrl-right not in spec
    try std.testing.expectEqualStrings("ctrl-right", decodeEscapeKeySpec("\x1b[1;5C", map).?);
}
