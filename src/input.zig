// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub const KeySeq = struct {
    seq: []const u8,
    name: []const u8,
};

/// Decode an escape sequence into the logical key name defined in the spec's
/// `key_sequences` table. Returns null for unrecognised sequences. The table
/// is authoritative — all variants (CSI, SS3, Kitty, XTerm modifyOtherKeys)
/// must be listed in spec/input.yaml; there is no hardcoded fallback.
pub fn decodeEscapeKeySpec(bytes: []const u8, key_sequences: []const KeySeq) ?[]const u8 {
    if (bytes.len == 0 or bytes[0] != 27) return null;
    for (key_sequences) |ks| {
        if (std.mem.eql(u8, ks.seq, bytes)) return ks.name;
    }
    return null;
}

pub const SgrMouseEvent = struct {
    button: i32,
    click_col: i32,
    click_row_raw: i32,
    term_char: u8,
    has_more: bool,
};

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

const test_key_sequences = [_]KeySeq{
    .{ .seq = "\x1b", .name = "esc" },
    .{ .seq = "\x1b[A", .name = "up" },
    .{ .seq = "\x1bOA", .name = "up" },
    .{ .seq = "\x1b[B", .name = "down" },
    .{ .seq = "\x1bOB", .name = "down" },
    .{ .seq = "\x1bOP", .name = "f1" },
    .{ .seq = "\x1b[1;5C", .name = "ctrl-right" },
    .{ .seq = "\x1b[5C", .name = "ctrl-right" },
    .{ .seq = "\x1bOc", .name = "ctrl-right" },
    .{ .seq = "\x1b[27;5;46~", .name = "ctrl-." },
    .{ .seq = "\x1b[13;2u", .name = "shift-enter" },
    .{ .seq = "\x1b[H", .name = "home" },
    .{ .seq = "\x1b[7~", .name = "home" },
    .{ .seq = "\x1bOH", .name = "home" },
};

test "decodeEscapeKeySpec resolves all variants from the spec table" {
    try std.testing.expectEqualStrings("esc", decodeEscapeKeySpec("\x1b", &test_key_sequences).?);
    // CSI canonical
    try std.testing.expectEqualStrings("up", decodeEscapeKeySpec("\x1b[A", &test_key_sequences).?);
    // SS3 variant (would have needed hardcoded fallback before)
    try std.testing.expectEqualStrings("up", decodeEscapeKeySpec("\x1bOA", &test_key_sequences).?);
    try std.testing.expectEqualStrings("down", decodeEscapeKeySpec("\x1bOB", &test_key_sequences).?);
    try std.testing.expectEqualStrings("f1", decodeEscapeKeySpec("\x1bOP", &test_key_sequences).?);
    // ctrl-right variants
    try std.testing.expectEqualStrings("ctrl-right", decodeEscapeKeySpec("\x1b[1;5C", &test_key_sequences).?);
    try std.testing.expectEqualStrings("ctrl-right", decodeEscapeKeySpec("\x1b[5C", &test_key_sequences).?);
    try std.testing.expectEqualStrings("ctrl-right", decodeEscapeKeySpec("\x1bOc", &test_key_sequences).?);
    // Kitty/XTerm extended sequences
    try std.testing.expectEqualStrings("ctrl-.", decodeEscapeKeySpec("\x1b[27;5;46~", &test_key_sequences).?);
    try std.testing.expectEqualStrings("shift-enter", decodeEscapeKeySpec("\x1b[13;2u", &test_key_sequences).?);
    // home variants
    try std.testing.expectEqualStrings("home", decodeEscapeKeySpec("\x1b[H", &test_key_sequences).?);
    try std.testing.expectEqualStrings("home", decodeEscapeKeySpec("\x1b[7~", &test_key_sequences).?);
    try std.testing.expectEqualStrings("home", decodeEscapeKeySpec("\x1bOH", &test_key_sequences).?);
    // unknown sequence returns null — no fallback
    try std.testing.expect(decodeEscapeKeySpec("\x1b[1;9S", &test_key_sequences) == null);
}
