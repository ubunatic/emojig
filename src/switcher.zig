// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Category switcher bar (issue 44 item 4): the row of category icons below
//! the grid. Owns the active/hover state, the Tab/Shift+Tab cycling order,
//! the mouse hit-zone geometry, and the row renderer. Layout knobs come from
//! spec/switcher.yaml (`spec.switcher`), category data (name/icon/switcher
//! flag) from spec/categories.yaml (`spec.categories`).

const std = @import("std");
const spec_mod = @import("spec.zig");
const term = @import("term.zig");
const color = @import("color.zig");
const tui_draw = @import("tui_draw.zig");

pub const State = struct {
    /// Active category filter: null = All; 0..catCount-1 = specific category.
    cat_idx: ?usize = null,
    /// Hovered slot while row_hovered: null = the All slot; catCount = the
    /// fill area right of the last slot (no category under the mouse).
    hover_idx: ?usize = null,
    row_hovered: bool = false,
};

/// Number of categories with switcher:true in the spec.
pub fn catCount(spec: *const spec_mod.Spec) usize {
    var n: usize = 0;
    for (spec.categories.categories) |cat| {
        if (cat.switcher) n += 1;
    }
    return n;
}

/// The i-th switcher category (0-based). Null when out of range.
pub fn catAt(spec: *const spec_mod.Spec, idx: usize) ?spec_mod.CategorySpec {
    var count: usize = 0;
    for (spec.categories.categories) |cat| {
        if (cat.switcher) {
            if (count == idx) return cat;
            count += 1;
        }
    }
    return null;
}

/// Name of the i-th switcher category. Null when out of range.
pub fn catName(spec: *const spec_mod.Spec, idx: usize) ?[]const u8 {
    return if (catAt(spec, idx)) |cat| cat.name else null;
}

/// Icon of the i-th switcher category. Empty slice when out of range.
pub fn catIcon(spec: *const spec_mod.Spec, idx: usize) []const u8 {
    return if (catAt(spec, idx)) |cat| cat.icon else "";
}

/// Tab/Shift+Tab cycling: forward null (All) → 0 → … → n-1 → null, backward
/// the reverse. Returns false (state untouched) when no switcher categories.
pub fn cycle(state: *State, spec: *const spec_mod.Spec, forward: bool) bool {
    const n = catCount(spec);
    if (n == 0) return false;
    if (forward) {
        state.cat_idx = if (state.cat_idx) |cur|
            (if (cur + 1 >= n) null else cur + 1)
        else
            0;
    } else {
        state.cat_idx = if (state.cat_idx) |cur|
            (if (cur == 0) null else cur - 1)
        else
            n - 1;
    }
    return true;
}

/// Category-name filter for the search engine (null = no filter).
pub fn activeFilter(state: *const State, spec: *const spec_mod.Spec) ?[]const u8 {
    return if (state.cat_idx) |i| catName(spec, i) else null;
}

/// Raw slot index under a 1-based row column: 0 = All slot, 1..n = category
/// slots, >n = fill area right of the last slot.
pub fn slotIndexAt(sw: *const spec_mod.SwitcherSpec, local_col: i32) usize {
    const slot_w = sw.pad_left.len + 2;
    const rpl = @as(i32, @intCast(sw.row_pad_left.len));
    const adj = @max(0, local_col - 1 - rpl);
    return @as(usize, @intCast(adj)) / slot_w;
}

/// Motion event on the switcher row: update the hover state.
pub fn hoverAt(state: *State, spec: *const spec_mod.Spec, local_col: i32) void {
    state.row_hovered = true;
    const slot = slotIndexAt(&spec.switcher, local_col);
    const n = catCount(spec);
    state.hover_idx = if (slot == 0) null else if (slot - 1 < n) slot - 1 else n;
}

/// Motion event anywhere else: clear the hover state.
pub fn clearHover(state: *State) void {
    state.row_hovered = false;
    state.hover_idx = null;
}

/// Click on the switcher row: set the active category (All slot → null).
/// Clicks right of the last slot leave the selection unchanged.
pub fn click(state: *State, spec: *const spec_mod.Spec, local_col: i32) void {
    const slot = slotIndexAt(&spec.switcher, local_col);
    const n = catCount(spec);
    if (slot == 0) {
        state.cat_idx = null;
    } else if (slot - 1 < n) {
        state.cat_idx = slot - 1;
    }
}

/// True while the mouse is over the All slot or a category slot (switches
/// the description row to the category hint).
pub fn isHovering(state: *const State, spec: *const spec_mod.Spec) bool {
    if (!state.row_hovered) return false;
    const i = state.hover_idx orelse return true;
    return i < catCount(spec);
}

/// Category under the mouse (null while the All slot is hovered).
pub fn hoveredCat(state: *const State, spec: *const spec_mod.Spec) ?spec_mod.CategorySpec {
    const i = state.hover_idx orelse return null;
    return catAt(spec, i);
}

// --- rendering -------------------------------------------------------------

/// Prefix char(s) for a slot: select_left/select_right (and hl_left/hl_right
/// for hover) replace the pad_left of the active slot and the slot after it,
/// "stealing" one col so the total row width stays constant.
pub fn prefix(sw: *const spec_mod.SwitcherSpec, slot: usize, active: ?usize, hover: ?usize) []const u8 {
    if (active != null and slot == active.?) return if (sw.select_left.len > 0) sw.select_left else sw.pad_left;
    if (active != null and slot > 0 and slot == active.? + 1) return if (sw.select_right.len > 0) sw.select_right else sw.pad_left;
    if (hover != null and slot == hover.?) return if (sw.hl_left.len > 0) sw.hl_left else sw.pad_left;
    if (hover != null and slot > 0 and slot == hover.? + 1) return if (sw.hl_right.len > 0) sw.hl_right else sw.pad_left;
    return sw.pad_left;
}

/// Extract the bg= attribute of a $fmtvars attrs string as a bg-only escape
/// (empty when the pattern has no bg= attribute).
pub fn bgOnlyFromPattern(buf: []u8, pattern: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, pattern, ',');
    while (it.next()) |p_raw| {
        const attr = std.mem.trim(u8, p_raw, " \t");
        if (std.mem.indexOfScalar(u8, attr, '=')) |eq| {
            const key = attr[0..eq];
            const val = attr[eq + 1 ..];
            if (std.mem.eql(u8, key, "bg")) {
                return color.bgEscape(buf, val);
            }
        }
    }
    return "";
}

/// Bg-only escape for a theme.yaml color value (integer index or color name).
fn bgOnlyFromValue(buf: []u8, val: std.json.Value) []const u8 {
    switch (val) {
        .integer => |i| {
            var val_buf: [16]u8 = undefined;
            const val_str = std.fmt.bufPrint(&val_buf, "{d}", .{i}) catch "";
            return color.bgEscape(buf, val_str);
        },
        .string => |s| return color.bgEscape(buf, s),
        else => return "",
    }
}

/// Render one slot. In "all" scope, the slot-after-active also gets sel_bg
/// for its prefix (the stolen right bracket).
fn renderSlot(
    fd: std.posix.fd_t,
    slot: usize,
    icon: []const u8,
    active: ?usize,
    hover: ?usize,
    sel_bg: []const u8,
    hl_bg: []const u8,
    hl_bg_only: []const u8,
    status_bg: []const u8,
    sw: *const spec_mod.SwitcherSpec,
    sel_scope_all: bool,
    hl_scope_all: bool,
) !void {
    const is_active = active != null and slot == active.?;
    const is_hover = hover != null and slot == hover.?;
    const is_after_active = active != null and slot > 0 and slot == active.? + 1;
    const is_after_hover = hover != null and slot > 0 and slot == hover.? + 1;

    const pre = prefix(sw, slot, active, hover);
    const is_active_bracket = is_active or is_after_active;

    // Hover always wins over active for bg color — the brackets already
    // indicate active state visually.
    var prefix_bg_buf: [128]u8 = undefined;
    const prefix_bg: []const u8 = blk: {
        if (hl_scope_all and (is_hover or is_after_hover)) {
            if (is_active_bracket) {
                break :blk std.fmt.bufPrint(&prefix_bg_buf, "{s}{s}", .{ status_bg, hl_bg_only }) catch status_bg;
            } else {
                break :blk hl_bg;
            }
        } else if (sel_scope_all and (is_active or is_after_active)) {
            break :blk sel_bg;
        } else {
            break :blk status_bg;
        }
    };
    const icon_bg: []const u8 = blk: {
        if (is_hover) break :blk hl_bg;
        if (is_active) break :blk sel_bg;
        break :blk status_bg;
    };

    try term.writeAll(fd, "\x1b[0m");
    try term.writeAll(fd, prefix_bg);
    try term.writeAll(fd, pre);
    if (!std.mem.eql(u8, icon_bg, prefix_bg)) {
        try term.writeAll(fd, "\x1b[0m");
        try term.writeAll(fd, icon_bg);
    }
    if (icon.len > 0) try term.writeAll(fd, icon);
}

/// Render the whole switcher row — prefix-theft layout.
/// Every slot: prefix(1 col) + icon(2 cols) = pad_left.len+2 cols. The
/// select/hl brackets replace pad_left of the active/hovered slot and the
/// slot after it (see `prefix`), keeping the total row width constant.
///
/// select_scope / hl_scope control what the bg color covers:
///   "all"  → left + icon + right all get the highlight color. The right
///            bracket is the stolen prefix of the next slot, so that slot's
///            bg is also set to sel/hl color.
///   "icon" → only the 2-col icon gets highlight; left/right stay in
///            status_bg (brackets visible, no bg bleed).
///
/// Ends the row via `rw.endRow()`; the separator hline above the row stays
/// with the caller.
pub fn renderRow(
    fd: std.posix.fd_t,
    rw: tui_draw.RowWriter,
    spec: *const spec_mod.Spec,
    palette: *const term.Palette,
    palette_spec: *const spec_mod.PaletteSpec,
    state: *const State,
    content_width: usize,
    spaces: []const u8,
) !void {
    const sw = &spec.switcher;
    const slot_w = sw.pad_left.len + 2;
    const sel_scope_all = !std.mem.eql(u8, sw.select_scope, "icon");
    const hl_scope_all = !std.mem.eql(u8, sw.hl_scope, "icon");

    // Resolve bg colors (attrs-only). "none" → categories_bg (no highlight).
    var hl_buf: [128]u8 = undefined;
    const hl_bg: []const u8 = if (std.mem.eql(u8, sw.hl_pattern, "none"))
        palette.categories_bg
    else if (sw.hl_pattern.len > 0)
        color.buildSgr(&hl_buf, sw.hl_pattern, &spec.styles)
    else
        palette.selection_bg;
    var sel_buf: [128]u8 = undefined;
    const sel_bg: []const u8 = if (std.mem.eql(u8, sw.select_pattern, "none"))
        palette.categories_bg
    else if (sw.select_pattern.len > 0)
        color.buildSgr(&sel_buf, sw.select_pattern, &spec.styles)
    else
        palette.selection_bg;

    const n = catCount(spec);
    // slot index: 0 = All, 1..n = categories.
    const active_slot: ?usize = if (state.cat_idx == null) 0 else state.cat_idx.? + 1;
    const hover_slot: ?usize = if (!state.row_hovered) null else if (state.hover_idx == null) 0 else state.hover_idx.? + 1;

    var sel_bg_only_buf: [64]u8 = undefined;
    const sel_bg_only = bgOnlyFromValue(&sel_bg_only_buf, palette_spec.selection_bg);

    // categories_bg_only: bg-only escape for the switcher row base color.
    // Reads categories_bg spec first, falls back to search_bg (same default
    // as buildPalette).
    var cat_bg_only_buf: [64]u8 = undefined;
    const cat_bg_only = bgOnlyFromValue(&cat_bg_only_buf, switch (palette_spec.categories_bg) {
        .null => palette_spec.search_bg,
        else => palette_spec.categories_bg,
    });

    var hl_bg_only_buf: [64]u8 = undefined;
    const hl_bg_only: []const u8 = if (std.mem.eql(u8, sw.hl_pattern, "none"))
        cat_bg_only
    else if (sw.hl_pattern.len > 0)
        bgOnlyFromPattern(&hl_bg_only_buf, sw.hl_pattern)
    else
        sel_bg_only;

    try term.writeAll(fd, term.CLEAR_LINE_CR);
    // row_pad_left: outer left margin of the entire switcher row.
    if (sw.row_pad_left.len > 0) {
        try term.writeAll(fd, "\x1b[0m");
        try term.writeAll(fd, palette.app_bg);
        try term.writeAll(fd, sw.row_pad_left);
    }
    // all_icon must be exactly 2 display cols (spec-defined).
    try renderSlot(fd, 0, sw.all_icon, active_slot, hover_slot, sel_bg, hl_bg, hl_bg_only, palette.categories_bg, sw, sel_scope_all, hl_scope_all);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try renderSlot(fd, i + 1, catIcon(spec, i), active_slot, hover_slot, sel_bg, hl_bg, hl_bg_only, palette.categories_bg, sw, sel_scope_all, hl_scope_all);
    }
    // Fill area: always write fill_prefix with fill_bg (even when it equals
    // pad_left) so scope="all" hover color reaches the right boundary of the
    // last slot. Then reset to categories_bg for the remainder.
    const slots_used: usize = slot_w * (1 + n) + sw.row_pad_left.len + sw.row_pad_right.len;
    if (content_width > slots_used) {
        const last_slot = n;
        const fill_prefix = prefix(sw, last_slot + 1, active_slot, hover_slot);
        const is_after_hov = hover_slot != null and last_slot == hover_slot.? and hl_scope_all;
        const is_after_act = active_slot != null and last_slot == active_slot.? and sel_scope_all;
        var fill_bg_buf: [128]u8 = undefined;
        const fill_bg: []const u8 = blk: {
            const is_active_bracket = active_slot != null and last_slot == active_slot.?;
            if (is_after_hov) {
                if (is_active_bracket) {
                    break :blk std.fmt.bufPrint(&fill_bg_buf, "{s}{s}", .{ palette.categories_bg, hl_bg_only }) catch palette.categories_bg;
                } else {
                    break :blk hl_bg;
                }
            } else if (is_after_act) {
                break :blk sel_bg;
            } else {
                break :blk palette.categories_bg;
            }
        };
        // Write fill_prefix with fill_bg — this covers the "right side" of
        // the last slot in scope="all" even when no bracket char is set.
        try term.writeAll(fd, "\x1b[0m");
        try term.writeAll(fd, fill_bg);
        try term.writeAll(fd, fill_prefix);
        // Remaining fill in categories_bg.
        const rem = content_width - slots_used - fill_prefix.len;
        if (rem > 0) {
            try term.writeAll(fd, "\x1b[0m");
            try term.writeAll(fd, palette.categories_bg);
            try term.writeAll(fd, spaces[0..@min(rem, spaces.len)]);
        }
    }
    // row_pad_right: outer right margin.
    if (sw.row_pad_right.len > 0) {
        try term.writeAll(fd, "\x1b[0m");
        try term.writeAll(fd, palette.app_bg);
        try term.writeAll(fd, sw.row_pad_right);
    }
    try rw.endRow();
}

// --- tests ------------------------------------------------------------------

const test_cats = [_]spec_mod.CategorySpec{
    .{ .name = "smileys", .short = "smiley", .synonyms = &.{"face"}, .icon = "😀", .switcher = true },
    .{ .name = "flags", .short = "flag", .synonyms = &.{}, .icon = "🚩", .switcher = false },
    .{ .name = "food", .short = "food", .synonyms = &.{"meal"}, .icon = "🍴", .switcher = true },
};

fn testSpec() spec_mod.Spec {
    var s: spec_mod.Spec = undefined;
    s.categories = .{ .categories = &test_cats };
    s.switcher = .{
        .row_pad_left = " ",
        .all_icon = "✱ ",
        .pad_left = " ",
        .select_left = "[",
        .select_right = "]",
        .select_scope = "icon",
        .hl_scope = "all",
        .select_pattern = "none",
    };
    return s;
}

test "catCount/catName/catIcon walk only switcher:true categories" {
    const s = testSpec();
    try std.testing.expectEqual(@as(usize, 2), catCount(&s));
    try std.testing.expectEqualStrings("smileys", catName(&s, 0).?);
    try std.testing.expectEqualStrings("food", catName(&s, 1).?);
    try std.testing.expect(catName(&s, 2) == null);
    try std.testing.expectEqualStrings("🍴", catIcon(&s, 1));
    try std.testing.expectEqualStrings("", catIcon(&s, 5));
}

test "cycle wraps forward and backward through All" {
    const s = testSpec();
    var st = State{};
    try std.testing.expect(cycle(&st, &s, true));
    try std.testing.expectEqual(@as(?usize, 0), st.cat_idx);
    _ = cycle(&st, &s, true);
    try std.testing.expectEqual(@as(?usize, 1), st.cat_idx);
    _ = cycle(&st, &s, true);
    try std.testing.expectEqual(@as(?usize, null), st.cat_idx);
    _ = cycle(&st, &s, false);
    try std.testing.expectEqual(@as(?usize, 1), st.cat_idx);
    _ = cycle(&st, &s, false);
    try std.testing.expectEqual(@as(?usize, 0), st.cat_idx);
    _ = cycle(&st, &s, false);
    try std.testing.expectEqual(@as(?usize, null), st.cat_idx);
}

test "cycle is a no-op without switcher categories" {
    var s = testSpec();
    s.categories = .{ .categories = &.{} };
    var st = State{ .cat_idx = null };
    try std.testing.expect(!cycle(&st, &s, true));
    try std.testing.expectEqual(@as(?usize, null), st.cat_idx);
}

test "slotIndexAt maps columns through row_pad_left and slot width" {
    const s = testSpec();
    // row_pad_left=" " (1), pad_left=" " → slot_w = 3. Columns are 1-based.
    try std.testing.expectEqual(@as(usize, 0), slotIndexAt(&s.switcher, 1));
    try std.testing.expectEqual(@as(usize, 0), slotIndexAt(&s.switcher, 4));
    try std.testing.expectEqual(@as(usize, 1), slotIndexAt(&s.switcher, 5));
    try std.testing.expectEqual(@as(usize, 1), slotIndexAt(&s.switcher, 7));
    try std.testing.expectEqual(@as(usize, 2), slotIndexAt(&s.switcher, 8));
}

test "hoverAt/click map slots to categories; fill area is inert for click" {
    const s = testSpec();
    var st = State{};
    hoverAt(&st, &s, 2); // All slot
    try std.testing.expect(st.row_hovered);
    try std.testing.expectEqual(@as(?usize, null), st.hover_idx);
    try std.testing.expect(isHovering(&st, &s));
    try std.testing.expect(hoveredCat(&st, &s) == null);

    hoverAt(&st, &s, 6); // slot 1 → category 0
    try std.testing.expectEqual(@as(?usize, 0), st.hover_idx);
    try std.testing.expectEqualStrings("smileys", hoveredCat(&st, &s).?.name);

    hoverAt(&st, &s, 20); // beyond last slot → sentinel n
    try std.testing.expectEqual(@as(?usize, 2), st.hover_idx);
    try std.testing.expect(!isHovering(&st, &s));

    clearHover(&st);
    try std.testing.expect(!st.row_hovered);

    click(&st, &s, 6);
    try std.testing.expectEqual(@as(?usize, 0), st.cat_idx);
    try std.testing.expectEqualStrings("smileys", activeFilter(&st, &s).?);
    click(&st, &s, 20); // fill area: selection unchanged
    try std.testing.expectEqual(@as(?usize, 0), st.cat_idx);
    click(&st, &s, 2); // All slot: filter off
    try std.testing.expectEqual(@as(?usize, null), st.cat_idx);
    try std.testing.expect(activeFilter(&st, &s) == null);
}

test "prefix steals pad_left for active/hover brackets" {
    const s = testSpec();
    const sw = &s.switcher;
    try std.testing.expectEqualStrings("[", prefix(sw, 1, 1, null));
    try std.testing.expectEqualStrings("]", prefix(sw, 2, 1, null));
    try std.testing.expectEqualStrings(" ", prefix(sw, 0, 1, null));
    // hl_left/hl_right are empty → hover falls back to pad_left.
    try std.testing.expectEqualStrings(" ", prefix(sw, 1, null, 1));
    // Active wins over hover on the same slot.
    try std.testing.expectEqualStrings("[", prefix(sw, 1, 1, 1));
}

test "bgOnlyFromPattern extracts only the bg attribute" {
    var buf: [64]u8 = undefined;
    const bg = bgOnlyFromPattern(&buf, "bold, bg=24, fg=white");
    try std.testing.expectEqualStrings("\x1b[48;5;24m", bg);
    var buf2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", bgOnlyFromPattern(&buf2, "bold, fg=white"));
}

fn testPipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.pipe2(&fds, .{});
    if (std.posix.errno(rc) != .SUCCESS) return error.PipeFailed;
    return fds;
}

fn readPipe(fd: std.posix.fd_t, buf: []u8) ![]const u8 {
    var n: usize = 0;
    while (true) {
        const got = try std.posix.read(fd, buf[n..]);
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

test "renderRow: slots, active brackets, fill, and row terminator" {
    const s = testSpec();
    var pal: term.Palette = undefined;
    pal.categories_bg = "<CB>";
    pal.app_bg = "<AB>";
    pal.selection_bg = "<SB>";
    var ps: spec_mod.PaletteSpec = undefined;
    ps.selection_bg = .{ .integer = 24 };
    ps.categories_bg = .null;
    ps.search_bg = .{ .integer = 238 };
    const st = State{ .cat_idx = 0 }; // first category active → slot 1

    const fds = try testPipe();
    defer _ = std.posix.system.close(fds[0]);
    var printed: usize = 0;
    const rw = tui_draw.RowWriter{ .fd = fds[1], .total = 1, .count = &printed };
    try renderRow(fds[1], rw, &s, &pal, &ps, &st, 20, " " ** 32);
    _ = std.posix.system.close(fds[1]);
    var out_buf: [4096]u8 = undefined;
    const out = try readPipe(fds[0], &out_buf);

    try std.testing.expect(std.mem.startsWith(u8, out, term.CLEAR_LINE_CR));
    // Outer left pad in app_bg, then the All slot icon.
    try std.testing.expect(std.mem.indexOf(u8, out, "<AB> ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "✱ ") != null);
    // Active slot 1: "[" bracket prefix, then both category icons in order.
    const lb = std.mem.indexOf(u8, out, "[").?;
    const smiley = std.mem.indexOf(u8, out, "😀").?;
    const rb = std.mem.indexOf(u8, out, "]").?;
    const food = std.mem.indexOf(u8, out, "🍴").?;
    try std.testing.expect(lb < smiley and smiley < rb and rb < food);
    // select_pattern="none" → active icon keeps categories_bg, no <SB> anywhere.
    try std.testing.expect(std.mem.indexOf(u8, out, "<SB>") == null);
    // Row ends via rw.endRow(): reset + clear-to-eol, exactly one row printed.
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[0m\x1b[K"));
    try std.testing.expectEqual(@as(usize, 1), printed);
}
