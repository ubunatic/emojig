// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const term = @import("term.zig");
const defaults = @import("defaults.zig");
const spec_mod = @import("spec.zig");
const emojig = @import("emojig");

pub const Theme = term.Theme;

pub const ScrollbarStyle = enum { expand, bar };

pub const Config = struct {
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

pub fn configPath(buf: []u8) ?[:0]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    const path = std.fmt.bufPrint(buf, "{s}/.config/emojig/config", .{home}) catch return null;
    if (path.len + 1 > buf.len) return null;
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// Look up the default value for a setting by ID from the loaded spec.
pub fn settingDefault(spec: *const spec_mod.Spec, id: []const u8) []const u8 {
    for (spec.settings.options) |opt| {
        if (std.mem.eql(u8, opt.id, id)) return opt.default;
    }
    return "";
}

pub fn settingDefaultBool(spec: *const spec_mod.Spec, id: []const u8) bool {
    const v = settingDefault(spec, id);
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

/// Read configuration from the config file in a single pass.
pub fn loadConfig(arena: std.mem.Allocator, io: std.Io) Config {
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

pub fn saveKeyToConfig(io: std.Io, key: []const u8, val: []const u8) void {
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

pub fn saveThemeToConfig(io: std.Io, t: Theme) void {
    const theme_str: []const u8 = switch (t) {
        .dark => "dark",
        .light => "light",
        .system => "system",
    };
    saveKeyToConfig(io, "theme", theme_str);
}

pub fn saveUsizeToConfig(io: std.Io, key: []const u8, val: usize) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
    saveKeyToConfig(io, key, s);
}

pub fn saveDisabledCategories(io: std.Io, cats: []const emojig.CategorySpec, disabled_cats: []const bool) void {
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

pub fn stepGridDim(val: usize, increase: bool, min: usize, max: usize) usize {
    const next = if (increase) val + 1 else (if (val > min) val - 1 else min);
    return @max(min, @min(next, max));
}

pub fn cycleGridDim(val: usize, step: usize, min: usize, max: usize) usize {
    return if (val + step > max) min else @max(min, val + step);
}

pub fn clampGridDim(val: usize, min: usize, max: usize) usize {
    return @max(min, @min(val, max));
}

pub fn finalizeGridDim(io: std.Io, val: *usize, key: []const u8, min: usize, max: usize) void {
    const clamped = clampGridDim(val.*, min, max);
    if (clamped != val.*) {
        val.* = clamped;
        saveUsizeToConfig(io, key, clamped);
    }
}

pub fn finalizeGridTyping(io: std.Io, sel: ?usize, cols: *usize, rows: *usize) void {
    const s = sel orelse return;
    if (s == 6) finalizeGridDim(io, cols, "cols", defaults.MIN_COLS, defaults.MAX_COLS);
    if (s == 7) finalizeGridDim(io, rows, "rows", defaults.MIN_ROWS, defaults.MAX_ROWS);
}

pub fn applyGridDimClick(io: std.Io, is_cols: bool, local_col: i32, val: *usize) bool {
    const min = if (is_cols) defaults.MIN_COLS else defaults.MIN_ROWS;
    const max = if (is_cols) defaults.MAX_COLS else defaults.MAX_ROWS;
    if (local_col >= 3 and local_col <= 5) {
        val.* = stepGridDim(val.*, false, min, max);
    } else if (local_col >= 8 and local_col <= 10) {
        val.* = stepGridDim(val.*, true, min, max);
    } else {
        return false;
    }
    saveUsizeToConfig(io, if (is_cols) "cols" else "rows", val.*);
    return true;
}

pub fn typeGridDim(val: *usize, digit: u8, continuing: bool, max: usize) void {
    const d: usize = digit - '0';
    var nv: usize = if (continuing) val.* * 10 + d else d;
    if (nv > max) nv = max;
    val.* = @max(1, nv);
}
