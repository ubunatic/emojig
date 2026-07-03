// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Debug screen model (issue 44 item 2): turns live app state (`DebugCtx`)
//! plus the spec/debug.yaml field table into formatted pane lines. Pure
//! buffer-in/string-out — no terminal I/O — so line formatting is unit-
//! testable without driving the TUI.

const std = @import("std");
const emojig = @import("emojig");
const mru = emojig.mru;
const term = @import("term.zig");
const host = @import("host.zig");
const spec_mod = @import("spec.zig");
const switcher = @import("switcher.zig");
const config = @import("config.zig");
const resize = @import("resize.zig");

pub const Theme = term.Theme;
pub const ScrollbarStyle = config.ScrollbarStyle;

/// Rolling per-query search timing samples, shown on the debug screen.
pub const SearchStats = struct {
    samples: [64]u32 = [_]u32{0} ** 64,
    count: usize = 0,
    next: usize = 0,
    last_us: u32 = 0,
    max_us: u32 = 0,

    pub fn record(self: *@This(), elapsed_us: u32) void {
        self.last_us = elapsed_us;
        if (elapsed_us > self.max_us) self.max_us = elapsed_us;
        self.samples[self.next] = elapsed_us;
        self.next = (self.next + 1) % self.samples.len;
        if (self.count < self.samples.len) self.count += 1;
    }

    pub fn percentile(self: *const @This(), pct: usize) u32 {
        if (self.count == 0) return 0;
        var tmp: [64]u32 = undefined;
        @memcpy(tmp[0..self.count], self.samples[0..self.count]);
        std.mem.sort(u32, tmp[0..self.count], {}, std.sort.asc(u32));
        const idx = @min((pct * (self.count - 1) + 50) / 100, self.count - 1);
        return tmp[idx];
    }
};

/// Snapshot of the app state the debug fields read from. Constructed at the
/// render call site in main(); `screen_name` is pre-resolved so this module
/// stays independent of main's ScreenState enum.
pub const DebugCtx = struct {
    spec: *const spec_mod.Spec,
    theme: Theme,
    system_theme: Theme,
    gui_effective_theme: ?Theme,
    screen_name: []const u8,
    has_focus: bool,
    gui_spawned: bool,
    final_simple: bool,
    final_safe: bool,
    final_compact: bool,
    show_switcher: bool,
    show_border: bool,
    scrollbar_style: ScrollbarStyle,
    resize_mode: resize.Mode,
    final_alt_screen: bool,
    query: []const u8,
    query_cursor: usize,
    selected_idx: ?usize,
    grid_scroll_top: usize,
    total_matches: usize,
    top_count: usize,
    fetch_limit: usize,
    content_width: usize,
    current_w: usize,
    current_h: usize,
    final_h: usize,
    cols: usize,
    rows: usize,
    visible_rows: usize,
    total_cells: usize,
    search_stats: *const SearchStats,
    disabled_cats: [32]bool,
    app_bg_choice: []const u8,
    title_bg_choice: []const u8,
    multi_select_active: bool,
    multi_selected_count: usize,
};

inline fn boolText(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn categorySynonymCount(spec: *const spec_mod.Spec) usize {
    var count: usize = 0;
    for (spec.categories.categories) |cat| {
        count += cat.synonyms.len;
    }
    return count;
}

fn disabledCategoryCount(spec: *const spec_mod.Spec, disabled_cats: [32]bool) usize {
    var count: usize = 0;
    for (spec.categories.categories, 0..) |_, idx| {
        if (idx < disabled_cats.len and disabled_cats[idx]) count += 1;
    }
    return count;
}

/// Total debug-pane line count for the spec's group/field table.
pub fn lineCount(spec: *const spec_mod.Spec) usize {
    var count: usize = 1; // title
    for (spec.debug.groups) |group| {
        count += 2 + group.fields.len; // blank + group title + fields
    }
    return count;
}

fn value(buf: []u8, id: []const u8, ctx: DebugCtx) []const u8 {
    const spec = ctx.spec;
    if (std.mem.eql(u8, id, "theme_setting")) return term.themeName(ctx.theme);
    if (std.mem.eql(u8, id, "theme_effective") or std.mem.eql(u8, id, "effective_theme")) return term.themeName(if (ctx.theme == .system) ctx.system_theme else ctx.theme);
    if (std.mem.eql(u8, id, "theme_reason")) {
        if (ctx.theme != .system) return "concrete setting";
        if (ctx.gui_effective_theme != null) return "GUI parent resolved desktop theme";
        if (term.last_system_theme_color != null) return "TUI OSC 11 terminal background";
        return "TUI OSC 11 unavailable; fallback dark";
    }
    if (std.mem.eql(u8, id, "gui_effective_theme")) return if (ctx.gui_effective_theme) |t| term.themeName(t) else "none";
    if (std.mem.eql(u8, id, "term_detected_theme")) return if (term.last_system_theme_color) |c| term.themeName(c.theme) else "none";
    if (std.mem.eql(u8, id, "term_detected_rgb")) {
        if (term.last_system_theme_color) |c| return std.fmt.bufPrint(buf, "rgb:{x:0>4}/{x:0>4}/{x:0>4}", .{ c.r, c.g, c.b }) catch "?";
        return "none";
    }
    if (std.mem.eql(u8, id, "term_detected_luma")) {
        if (term.last_system_theme_color) |c| return std.fmt.bufPrint(buf, "{d}/65535", .{c.luma}) catch "?";
        return "none";
    }
    if (std.mem.eql(u8, id, "terminal_bg")) {
        const tc = spec.terminalColors(ctx.theme, ctx.system_theme);
        return tc.bg orelse "none";
    }
    if (std.mem.eql(u8, id, "terminal_fg")) {
        const tc = spec.terminalColors(ctx.theme, ctx.system_theme);
        return tc.fg orelse "none";
    }
    if (std.mem.eql(u8, id, "app_bg_choice")) return ctx.app_bg_choice;
    if (std.mem.eql(u8, id, "app_bg_hex")) return host.resolveAppBgHex(ctx.app_bg_choice, (if (ctx.theme == .system) ctx.system_theme else ctx.theme) != .light);
    if (std.mem.eql(u8, id, "title_bg_choice")) return ctx.title_bg_choice;
    if (std.mem.eql(u8, id, "title_bg_hex")) {
        const is_dark = (if (ctx.theme == .system) ctx.system_theme else ctx.theme) != .light;
        const app_hex = host.resolveAppBgHex(ctx.app_bg_choice, is_dark);
        var title_buf: [6]u8 = undefined;
        return std.fmt.bufPrint(buf, "#{s}", .{host.resolveTitleBgHex(ctx.title_bg_choice, app_hex, is_dark, &title_buf)}) catch "?";
    }
    if (std.mem.eql(u8, id, "search_last_us")) return std.fmt.bufPrint(buf, "{d} us", .{ctx.search_stats.last_us}) catch "?";
    if (std.mem.eql(u8, id, "search_p50_us")) return std.fmt.bufPrint(buf, "{d} us", .{ctx.search_stats.percentile(50)}) catch "?";
    if (std.mem.eql(u8, id, "search_p90_us")) return std.fmt.bufPrint(buf, "{d} us", .{ctx.search_stats.percentile(90)}) catch "?";
    if (std.mem.eql(u8, id, "search_max_us")) return std.fmt.bufPrint(buf, "{d} us", .{ctx.search_stats.max_us}) catch "?";
    if (std.mem.eql(u8, id, "search_samples")) return std.fmt.bufPrint(buf, "{d}/64", .{ctx.search_stats.count}) catch "?";
    if (std.mem.eql(u8, id, "total_matches")) return std.fmt.bufPrint(buf, "{d}", .{ctx.total_matches}) catch "?";
    if (std.mem.eql(u8, id, "visible_matches")) return std.fmt.bufPrint(buf, "{d}", .{ctx.top_count}) catch "?";
    if (std.mem.eql(u8, id, "fetch_limit")) return std.fmt.bufPrint(buf, "{d}", .{ctx.fetch_limit}) catch "?";
    if (std.mem.eql(u8, id, "emoji_count")) return std.fmt.bufPrint(buf, "{d}", .{emojig.EmojiDb.count}) catch "?";
    if (std.mem.eql(u8, id, "synonym_pairs")) return std.fmt.bufPrint(buf, "{d}", .{emojig.SynonymDb.synonym_count}) catch "?";
    if (std.mem.eql(u8, id, "stem_exclusions")) return std.fmt.bufPrint(buf, "{d}", .{emojig.SynonymDb.stem_excl_count}) catch "?";
    if (std.mem.eql(u8, id, "category_count")) return std.fmt.bufPrint(buf, "{d}", .{spec.categories.categories.len}) catch "?";
    if (std.mem.eql(u8, id, "switcher_category_count")) return std.fmt.bufPrint(buf, "{d}", .{switcher.catCount(spec)}) catch "?";
    if (std.mem.eql(u8, id, "category_synonyms")) return std.fmt.bufPrint(buf, "{d}", .{categorySynonymCount(spec)}) catch "?";
    if (std.mem.eql(u8, id, "disabled_categories")) return std.fmt.bufPrint(buf, "{d}", .{disabledCategoryCount(spec, ctx.disabled_cats)}) catch "?";
    if (std.mem.eql(u8, id, "command_count")) return std.fmt.bufPrint(buf, "{d}", .{spec.commands.commands.len}) catch "?";
    if (std.mem.eql(u8, id, "setting_count")) return std.fmt.bufPrint(buf, "{d}", .{spec.settings.options.len}) catch "?";
    if (std.mem.eql(u8, id, "color_count")) return std.fmt.bufPrint(buf, "{d}", .{spec.colors.colors.len}) catch "?";
    if (std.mem.eql(u8, id, "term_size")) return std.fmt.bufPrint(buf, "{d}x{d}", .{ ctx.current_w, ctx.current_h }) catch "?";
    if (std.mem.eql(u8, id, "emojig_size")) return std.fmt.bufPrint(buf, "{d}x{d}", .{ ctx.content_width + 1, ctx.final_h }) catch "?";
    if (std.mem.eql(u8, id, "content_width")) return std.fmt.bufPrint(buf, "{d}", .{ctx.content_width}) catch "?";
    if (std.mem.eql(u8, id, "grid_size")) return std.fmt.bufPrint(buf, "{d}x{d}", .{ ctx.cols, ctx.rows }) catch "?";
    if (std.mem.eql(u8, id, "visible_rows")) return std.fmt.bufPrint(buf, "{d}", .{ctx.visible_rows}) catch "?";
    if (std.mem.eql(u8, id, "cell_width")) return std.fmt.bufPrint(buf, "{d}", .{if (ctx.final_compact) @as(usize, 3) else 4}) catch "?";
    if (std.mem.eql(u8, id, "total_cells")) return std.fmt.bufPrint(buf, "{d}", .{ctx.total_cells}) catch "?";
    if (std.mem.eql(u8, id, "top_padding")) return boolText(spec.layout.top_padding);
    if (std.mem.eql(u8, id, "border")) return boolText(ctx.show_border);
    if (std.mem.eql(u8, id, "resize_mode")) return @tagName(ctx.resize_mode);
    if (std.mem.eql(u8, id, "alt_screen")) return boolText(ctx.final_alt_screen);
    if (std.mem.eql(u8, id, "screen")) return ctx.screen_name;
    if (std.mem.eql(u8, id, "focus")) return if (ctx.has_focus) "focused" else "unfocused";
    if (std.mem.eql(u8, id, "gui_spawned")) return boolText(ctx.gui_spawned);
    if (std.mem.eql(u8, id, "simple_mode")) return boolText(ctx.final_simple);
    if (std.mem.eql(u8, id, "safe_mode")) return boolText(ctx.final_safe);
    if (std.mem.eql(u8, id, "compact_mode")) return boolText(ctx.final_compact);
    if (std.mem.eql(u8, id, "show_switcher")) return boolText(ctx.show_switcher);
    if (std.mem.eql(u8, id, "scrollbar_style")) return @tagName(ctx.scrollbar_style);
    if (std.mem.eql(u8, id, "query")) return if (ctx.query.len > 0) ctx.query else "(empty)";
    if (std.mem.eql(u8, id, "query_len")) return std.fmt.bufPrint(buf, "{d}", .{ctx.query.len}) catch "?";
    if (std.mem.eql(u8, id, "query_cursor")) return std.fmt.bufPrint(buf, "{d}", .{ctx.query_cursor}) catch "?";
    if (std.mem.eql(u8, id, "selected_idx")) return if (ctx.selected_idx) |s| std.fmt.bufPrint(buf, "{d}", .{s}) catch "?" else "none";
    if (std.mem.eql(u8, id, "grid_scroll_top")) return std.fmt.bufPrint(buf, "{d}", .{ctx.grid_scroll_top}) catch "?";
    if (std.mem.eql(u8, id, "multi_select")) return std.fmt.bufPrint(buf, "{s} ({d} selected)", .{ boolText(ctx.multi_select_active), ctx.multi_selected_count }) catch "?";
    if (std.mem.eql(u8, id, "mru_count")) return std.fmt.bufPrint(buf, "{d}", .{mru.getCount()}) catch "?";
    return "(unknown)";
}

/// Format debug-pane line `idx`: 0 is the pane title, then per group a group
/// title, its fields ("  label: value"), and a blank separator line.
pub fn line(buf: []u8, idx: usize, ctx: DebugCtx) []const u8 {
    if (idx == 0) return ctx.spec.debug.title;
    var rem = idx - 1;
    for (ctx.spec.debug.groups) |group| {
        if (rem == 0) return std.fmt.bufPrint(buf, "{s}", .{group.title}) catch group.title;
        rem -= 1;
        if (rem < group.fields.len) {
            const field = group.fields[rem];
            var val_buf: [160]u8 = undefined;
            const val = value(&val_buf, field.id, ctx);
            return std.fmt.bufPrint(buf, "  {s}: {s}", .{ field.label, val }) catch field.label;
        }
        rem -= group.fields.len;
        if (rem == 0) return "";
        rem -= 1;
    }
    return "";
}

// Alias so DebugLinesPane.line can call the file-level formatter without
// shadowing itself.
const formatLine = line;

/// Line source for tui_draw.renderScrollPane (debug screen).
pub const DebugLinesPane = struct {
    ctx: DebugCtx,
    buf: []u8,
    pub fn count(self: *const @This()) usize {
        return lineCount(self.ctx.spec);
    }
    pub fn line(self: *const @This(), li: usize) []const u8 {
        return formatLine(self.buf, li, self.ctx);
    }
};

// --- tests ----------------------------------------------------------------

fn testCtx(spec: *const spec_mod.Spec, stats: *const SearchStats) DebugCtx {
    return .{
        .spec = spec,
        .theme = .dark,
        .system_theme = .dark,
        .gui_effective_theme = null,
        .screen_name = "debug",
        .has_focus = true,
        .gui_spawned = false,
        .final_simple = false,
        .final_safe = false,
        .final_compact = false,
        .show_switcher = false,
        .show_border = false,
        .scrollbar_style = .expand,
        .resize_mode = .eat,
        .final_alt_screen = false,
        .query = "hello",
        .query_cursor = 5,
        .selected_idx = 7,
        .grid_scroll_top = 2,
        .total_matches = 42,
        .top_count = 24,
        .fetch_limit = 1280,
        .content_width = 33,
        .current_w = 80,
        .current_h = 24,
        .final_h = 12,
        .cols = 8,
        .rows = 10,
        .visible_rows = 10,
        .total_cells = 80,
        .search_stats = stats,
        .disabled_cats = [_]bool{false} ** 32,
        .app_bg_choice = "default",
        .title_bg_choice = "default",
        .multi_select_active = true,
        .multi_selected_count = 2,
    };
}

test "lineCount and line walk title, group title, fields, and blank rows" {
    var s: spec_mod.Spec = undefined;
    s.debug = .{
        .title = "dbg title",
        .groups = &.{
            .{ .id = "g", .title = "grp", .fields = &.{
                .{ .id = "query_len", .label = "qlen" },
                .{ .id = "focus", .label = "focus" },
            } },
        },
    };
    const stats = SearchStats{};
    const ctx = testCtx(&s, &stats);

    try std.testing.expectEqual(@as(usize, 5), lineCount(&s)); // title + blank + group title + 2 fields

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("dbg title", line(&buf, 0, ctx));
    try std.testing.expectEqualStrings("grp", line(&buf, 1, ctx));
    try std.testing.expectEqualStrings("  qlen: 5", line(&buf, 2, ctx));
    try std.testing.expectEqualStrings("  focus: focused", line(&buf, 3, ctx));
    try std.testing.expectEqualStrings("", line(&buf, 4, ctx));
}

test "value formats state fields without touching the spec" {
    var s: spec_mod.Spec = undefined;
    var stats = SearchStats{};
    stats.record(100);
    stats.record(300);
    const ctx = testCtx(&s, &stats);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("80x24", value(&buf, "term_size", ctx));
    try std.testing.expectEqualStrings("34x12", value(&buf, "emojig_size", ctx));
    try std.testing.expectEqualStrings("8x10", value(&buf, "grid_size", ctx));
    try std.testing.expectEqualStrings("hello", value(&buf, "query", ctx));
    try std.testing.expectEqualStrings("7", value(&buf, "selected_idx", ctx));
    try std.testing.expectEqualStrings("true (2 selected)", value(&buf, "multi_select", ctx));
    try std.testing.expectEqualStrings("dark", value(&buf, "theme_setting", ctx));
    try std.testing.expectEqualStrings("debug", value(&buf, "screen", ctx));
    try std.testing.expectEqualStrings("300 us", value(&buf, "search_last_us", ctx));
    try std.testing.expectEqualStrings("2/64", value(&buf, "search_samples", ctx));
    try std.testing.expectEqualStrings("(unknown)", value(&buf, "no_such_field", ctx));
}

test "SearchStats percentile over recorded samples" {
    var stats = SearchStats{};
    try std.testing.expectEqual(@as(u32, 0), stats.percentile(50));
    stats.record(10);
    stats.record(20);
    stats.record(30);
    stats.record(40);
    try std.testing.expectEqual(@as(u32, 40), stats.last_us);
    try std.testing.expectEqual(@as(u32, 40), stats.max_us);
    try std.testing.expectEqual(@as(u32, 30), stats.percentile(50));
    try std.testing.expectEqual(@as(u32, 40), stats.percentile(90));
}
