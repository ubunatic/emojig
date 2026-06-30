// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const config = @import("config.zig");
const spec_mod = @import("spec.zig");
const term_lib = @import("term.zig");
const tui_draw = @import("tui_draw.zig");

pub const ScrollbarStyle = config.ScrollbarStyle;
pub const Theme = term_lib.Theme;

pub fn renderSettingRow(
    buf: []u8,
    spec: *const spec_mod.Spec,
    idx: usize,
    is_sel: bool,
    shell_int: bool,
    key_bind: []const u8,
    key_bind_editing: bool,
    show_cats: bool,
    amb_chars: []const u8,
    theme: Theme,
    scrollbar: ScrollbarStyle,
    grid_cols: usize,
    grid_rows: usize,
    grid_compact: bool,
    gui_decorated: bool,
    hover_left: bool,
    hover_right: bool,
    app_bg_val: []const u8,
    title_bg_val: []const u8,
    palette: term_lib.Palette,
) ![]const u8 {
    const sel_prefix = if (is_sel) "> " else "  ";
    const bg = if (is_sel) palette.selection_bg else palette.view_bg;

    // The grid-size `‹`/`›` are clickable buttons: always bold so they read as
    // controls, and underlined while hovered (only on the selected/hovered row).
    const lq = if (is_sel and hover_left) "\x1b[1;4m\u{2039}\x1b[22;24m" else "\x1b[1m\u{2039}\x1b[22m";
    const rq = if (is_sel and hover_right) "\x1b[1;4m\u{203a}\x1b[22;24m" else "\x1b[1m\u{203a}\x1b[22m";

    const opt = spec.settings.options[idx];
    var val_buf: [128]u8 = undefined;
    var val_str: []const u8 = "";

    if (std.mem.eql(u8, opt.type, "boolean")) {
        const val = if (std.mem.eql(u8, opt.id, "shell_integration"))
            shell_int
        else if (std.mem.eql(u8, opt.id, "show_all_categories"))
            show_cats
        else if (std.mem.eql(u8, opt.id, "compact"))
            grid_compact
        else if (std.mem.eql(u8, opt.id, "decorated"))
            gui_decorated
        else
            false;
        val_str = try std.fmt.bufPrint(&val_buf, "[{s}]", .{if (val) "✔" else " "});
    } else if (std.mem.eql(u8, opt.type, "choice")) {
        const val = if (std.mem.eql(u8, opt.id, "shell_key_binding"))
            key_bind
        else if (std.mem.eql(u8, opt.id, "ambiguous_chars"))
            amb_chars
        else if (std.mem.eql(u8, opt.id, "theme"))
            @tagName(theme)
        else if (std.mem.eql(u8, opt.id, "scrollbar_style"))
            @tagName(scrollbar)
        else if (std.mem.eql(u8, opt.id, "app_bg"))
            app_bg_val
        else if (std.mem.eql(u8, opt.id, "title_bg"))
            title_bg_val
        else
            "";
        val_str = if (std.mem.eql(u8, opt.id, "shell_key_binding") and key_bind_editing)
            try std.fmt.bufPrint(&val_buf, "[{s}▋]", .{val})
        else
            try std.fmt.bufPrint(&val_buf, "[{s}]", .{val});
    } else if (std.mem.eql(u8, opt.type, "integer")) {
        const val = if (std.mem.eql(u8, opt.id, "cols"))
            grid_cols
        else
            grid_rows;
        val_str = try std.fmt.bufPrint(&val_buf, "[{s} {d:>2} {s}]", .{ lq, val, rq });
    } else if (std.mem.eql(u8, opt.type, "action")) {
        val_str = try std.fmt.bufPrint(&val_buf, "[{s}]", .{opt.default});
    }

    const w = tui_draw.ansiDisplayWidth(val_str);
    var spaces_buf: [10]u8 = undefined;
    const pad_count = if (w < 9) 9 - w else 0;
    for (0..pad_count) |j| spaces_buf[j] = ' ';
    const padded = try std.fmt.bufPrint(buf[300..], "{s}{s}", .{ val_str, spaces_buf[0..pad_count] });
    return std.fmt.bufPrint(buf, "{s} {s}{s}{s}  {s}\x1b[0m", .{ palette.app_bg, bg, sel_prefix, padded, opt.label });
}

test "renderSettingRow formats grid rows" {
    _ = renderSettingRow;
}
