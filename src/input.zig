// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub const KeySeq = struct {
    seq: []const u8,
    name: []const u8,
};

/// Semantic key action, the target of a `spec/input.yaml` `bindings:` entry.
/// A load-time spec test (spec.zig) and the Go spec lint assert that every
/// bound action name parses into this enum — adding a new action means adding
/// it here, in the spec, and in the dispatch switch that consumes it.
pub const Action = enum {
    quit,
    select,
    confirm_multi_exit,
    delete,
    cycle_theme,
    open_settings,
    nav_up,
    nav_down,
    nav_left,
    nav_right,
    nav_home,
    nav_end,
    scroll_pageup,
    scroll_pagedown,
    /// The key is not bound to any action (or the name is unknown).
    none,

    /// Whether this is one of the four directional/home/end grid-nav actions.
    pub fn isNav(self: Action) bool {
        return switch (self) {
            .nav_up, .nav_down, .nav_left, .nav_right, .nav_home, .nav_end => true,
            else => false,
        };
    }
};

const action_map = std.StaticStringMap(Action).initComptime(.{
    .{ "quit", .quit },
    .{ "select", .select },
    .{ "confirm_multi_exit", .confirm_multi_exit },
    .{ "delete", .delete },
    .{ "cycle_theme", .cycle_theme },
    .{ "open_settings", .open_settings },
    .{ "nav_up", .nav_up },
    .{ "nav_down", .nav_down },
    .{ "nav_left", .nav_left },
    .{ "nav_right", .nav_right },
    .{ "nav_home", .nav_home },
    .{ "nav_end", .nav_end },
    .{ "scroll_pageup", .scroll_pageup },
    .{ "scroll_pagedown", .scroll_pagedown },
});

/// Resolve a spec action string to the enum; unknown/empty names map to .none.
pub fn actionFromName(name: []const u8) Action {
    return action_map.get(name) orelse .none;
}

/// Logical key, decoded from terminal bytes (spec key_sequences table or the
/// hardcoded single-byte decode in main.zig). Only the names the dispatch
/// chain matches on directly get a tag; everything else is .other — those
/// keys are either handled via their bound Action or intentionally dead.
pub const Key = enum {
    esc,
    enter,
    space,
    tab,
    shift_tab,
    backspace,
    del,
    up,
    down,
    f1,
    ctrl_t,
    ctrl_left,
    ctrl_right,
    other,
};

const key_map = std.StaticStringMap(Key).initComptime(.{
    .{ "esc", .esc },
    .{ "enter", .enter },
    .{ "space", .space },
    .{ "tab", .tab },
    .{ "shift-tab", .shift_tab },
    .{ "backspace", .backspace },
    .{ "del", .del },
    .{ "up", .up },
    .{ "down", .down },
    .{ "f1", .f1 },
    .{ "ctrl-t", .ctrl_t },
    .{ "ctrl-left", .ctrl_left },
    .{ "ctrl-right", .ctrl_right },
});

/// Resolve a decoded logical key name to the enum; unmatched names are .other.
pub fn keyFromName(name: []const u8) Key {
    return key_map.get(name) orelse .other;
}

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

test "actionFromName resolves every Action tag and rejects unknowns" {
    // Every enum tag except .none must round-trip through its own name, so
    // the comptime table can never silently miss a newly added action.
    inline for (@typeInfo(Action).@"enum".fields) |f| {
        const tag: Action = @enumFromInt(f.value);
        if (tag != .none) try std.testing.expectEqual(tag, actionFromName(f.name));
    }
    try std.testing.expectEqual(Action.none, actionFromName(""));
    try std.testing.expectEqual(Action.none, actionFromName("warp_drive"));
    try std.testing.expect(Action.nav_left.isNav());
    try std.testing.expect(Action.nav_end.isNav());
    try std.testing.expect(!Action.scroll_pageup.isNav());
    try std.testing.expect(!Action.none.isNav());
}

test "keyFromName resolves dispatch keys and maps the rest to .other" {
    try std.testing.expectEqual(Key.esc, keyFromName("esc"));
    try std.testing.expectEqual(Key.shift_tab, keyFromName("shift-tab"));
    try std.testing.expectEqual(Key.ctrl_left, keyFromName("ctrl-left"));
    try std.testing.expectEqual(Key.del, keyFromName("del"));
    // Keys without a direct dispatch branch fall through to .other.
    try std.testing.expectEqual(Key.other, keyFromName("f5"));
    try std.testing.expectEqual(Key.other, keyFromName("pageup"));
    try std.testing.expectEqual(Key.other, keyFromName(""));
}

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
