// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Runtime loader for the declarative UI spec (`spec/*.json`).
//!
//! These JSON files are the single source of truth for the layout, theme,
//! key bindings, and UI strings, shared with the Go `mojigo` port. They are
//! embedded into the binary (see build.zig anonymous imports) and parsed once
//! at startup into a `Spec`. All allocations are made into a caller-provided
//! arena that lives for the process lifetime (the hot picker loop stays
//! allocation-free; parsing happens only at startup).
//!
//! Edit the JSON to change grid sizes, colors, bindings, or text — both the
//! Zig app and mojigo pick the change up.

const std = @import("std");
const term = @import("term.zig");

const layout_json = @embedFile("spec_layout");
const theme_json = @embedFile("spec_theme");
const keys_json = @embedFile("spec_keys");
const strings_json = @embedFile("spec_strings");
const commands_json = @embedFile("spec_commands");
const settings_json = @embedFile("spec_settings");
const categories_json = @embedFile("spec_categories");
const strings_es = @embedFile("spec_strings_es");
const strings_pt = @embedFile("spec_strings_pt");
const strings_fr = @embedFile("spec_strings_fr");
const strings_it = @embedFile("spec_strings_it");
const strings_de = @embedFile("spec_strings_de");
const strings_pl = @embedFile("spec_strings_pl");
const strings_ru = @embedFile("spec_strings_ru");
const strings_uk = @embedFile("spec_strings_uk");
const strings_nl = @embedFile("spec_strings_nl");
const strings_tr = @embedFile("spec_strings_tr");

const parse_opts = std.json.ParseOptions{ .ignore_unknown_fields = true };

// ---------------------------------------------------------------------------
// Parsed JSON shapes (mirror spec/*.json; unknown "description" keys ignored)
// ---------------------------------------------------------------------------

pub const Dims = struct {
    cols: usize,
    rows: usize,
    width: usize,
};

pub const Animation = struct {
    /// Whether the block-shade exit-fade plays in TUI (inline terminal) mode.
    exit_preview_tui: bool = true,
    /// Whether the block-shade exit-fade plays in GUI (floating window) mode.
    exit_preview_gui: bool = true,
};

pub const Layout = struct {
    tui: Dims,
    gui: Dims,
    layout_overhead: usize,
    max_query_len: usize,
    animation: Animation = .{},
};

pub const PaletteSpec = struct {
    grid_bg: ?u8 = null,
    grid_fg: u8,
    selection_bg: ?u8 = null,
    selection_fg: u8,
    search_bg: ?u8 = null,
    search_fg: u8,
    search_shade_fg: u8,
    info_bg: ?u8 = null,
    info_fg: u8,
    status_bg: ?u8 = null,
    status_fg: u8,
    status_shade_fg: u8,
    border_bg: ?u8 = null,
    border_shade_fg: u8,
    terminal_bg2: ?[]const u8 = null,
    terminal_bg: ?[]const u8 = null,
    terminal_fg: ?[]const u8 = null,
    terminal_border: ?[]const u8 = null,
    warning_fg: u8 = 9,
    success_fg: u8 = 10,
};

pub const Theme = struct {
    icons: struct {
        dark: []const u8,
        light: []const u8,
        system: []const u8,
    },
    themes: struct {
        dark: PaletteSpec,
        light: PaletteSpec,
    },
};

pub const Keys = struct {
    bindings: std.json.ArrayHashMap([]const u8),
};

pub const CommandSpec = struct {
    name: []const u8,
    short: []const u8,
    action: []const u8,
    /// Optional shell command to run when action is "run_update".
    cmd: ?[]const u8 = null,
};

pub const Commands = struct {
    commands: []const CommandSpec,
};

pub const SettingOption = struct {
    id: []const u8,
    type: []const u8,
    label: []const u8,
    choices: ?[]const []const u8 = null,
    default: []const u8,
};

pub const SettingsSpec = struct {
    title: []const u8,
    options: []const SettingOption,
};

const emojig_mod = @import("emojig");
pub const CategorySpec = emojig_mod.CategorySpec;
pub const CategoriesSpec = emojig_mod.CategoriesSpec;

pub const Strings = struct {
    search_prompt: []const u8,
    search_placeholder: []const u8,
    status_help_hint: []const u8,
    status_matches: []const u8,
    status_help_hint_wide: []const u8,
    status_matches_wide: []const u8,
    help_lines: []const []const u8,
    help_lines_more: []const []const u8,
    about_lines: []const []const u8 = &[_][]const u8{},
    focus_lost_startup_lines: []const []const u8 = &[_][]const u8{ "⚠️  Cannot steal Wayland", "popup focus?", "", "Click window to focus!" },
    focus_lost_runtime_lines: []const []const u8 = &[_][]const u8{ "⚠️  Picker unfocused.", "", "", "Click window to focus!" },
};

// ---------------------------------------------------------------------------
// Spec bundle
// ---------------------------------------------------------------------------

pub const Spec = struct {
    layout: Layout,
    theme: Theme,
    keys: Keys,
    strings: Strings,
    commands: Commands,
    settings: SettingsSpec,
    categories: CategoriesSpec,
    // term.Palette escape strings built at load from the color indices above.
    dark_palette: term.Palette,
    light_palette: term.Palette,
    dark_palette_dim: term.Palette,
    light_palette_dim: term.Palette,

    /// Logical key name -> action ("quit", "select", ...), or null if unbound.
    /// The input layer decodes raw terminal bytes into the logical names.
    pub fn actionFor(self: *const Spec, logical_name: []const u8) ?[]const u8 {
        return self.keys.bindings.map.get(logical_name);
    }

    /// Theme toggle icon for the given effective theme.
    pub fn iconFor(self: *const Spec, t: term.Theme) []const u8 {
        return switch (t) {
            .dark => self.theme.icons.dark,
            .light => self.theme.icons.light,
            .system => self.theme.icons.system,
        };
    }

    /// Rendering palette for an effective (non-system) theme, optionally dimmed.
    pub fn paletteFor(self: *const Spec, t: term.Theme, sys: term.Theme, dim: bool) term.Palette {
        const eff = if (t == .system) sys else t;
        return switch (eff) {
            .light => if (dim) self.light_palette_dim else self.light_palette,
            .dark, .system => if (dim) self.dark_palette_dim else self.dark_palette,
        };
    }

    /// Terminal OSC bg/fg hex (with leading '#') for an effective theme.
    pub fn terminalColors(self: *const Spec, t: term.Theme, sys: term.Theme) struct { bg: ?[]const u8, fg: ?[]const u8 } {
        const eff = if (t == .system) sys else t;
        const p = if (eff == .light) self.theme.themes.light else self.theme.themes.dark;
        return .{ .bg = p.terminal_bg2 orelse p.terminal_bg, .fg = p.terminal_fg };
    }
};

/// Parse all four spec files into `arena`. The returned `Spec` (and every slice
/// it references) lives as long as `arena` is not freed — pass a process-lifetime
/// arena and never deinit it.
pub fn load(arena: std.mem.Allocator, lang: ?[]const u8) !Spec {
    const layout = try std.json.parseFromSliceLeaky(Layout, arena, layout_json, parse_opts);
    const theme = try std.json.parseFromSliceLeaky(Theme, arena, theme_json, parse_opts);
    const keys = try std.json.parseFromSliceLeaky(Keys, arena, keys_json, parse_opts);

    var strings_content: []const u8 = strings_json;
    if (lang) |l| {
        var lang_buf: [16]u8 = undefined;
        const len = @min(l.len, lang_buf.len);
        for (l[0..len], 0..len) |c, i| {
            lang_buf[i] = std.ascii.toLower(c);
        }
        const l_norm = lang_buf[0..len];

        if (std.mem.startsWith(u8, l_norm, "es")) {
            strings_content = strings_es;
        } else if (std.mem.startsWith(u8, l_norm, "pt")) {
            strings_content = strings_pt;
        } else if (std.mem.startsWith(u8, l_norm, "fr")) {
            strings_content = strings_fr;
        } else if (std.mem.startsWith(u8, l_norm, "it")) {
            strings_content = strings_it;
        } else if (std.mem.startsWith(u8, l_norm, "de")) {
            strings_content = strings_de;
        } else if (std.mem.startsWith(u8, l_norm, "pl")) {
            strings_content = strings_pl;
        } else if (std.mem.startsWith(u8, l_norm, "ru")) {
            strings_content = strings_ru;
        } else if (std.mem.startsWith(u8, l_norm, "uk")) {
            strings_content = strings_uk;
        } else if (std.mem.startsWith(u8, l_norm, "nl")) {
            strings_content = strings_nl;
        } else if (std.mem.startsWith(u8, l_norm, "tr")) {
            strings_content = strings_tr;
        }
    }

    const strings = try std.json.parseFromSliceLeaky(Strings, arena, strings_content, parse_opts);
    const commands = try std.json.parseFromSliceLeaky(Commands, arena, commands_json, parse_opts);
    const settings = try std.json.parseFromSliceLeaky(SettingsSpec, arena, settings_json, parse_opts);
    const categories = try std.json.parseFromSliceLeaky(CategoriesSpec, arena, categories_json, parse_opts);

    return .{
        .layout = layout,
        .theme = theme,
        .keys = keys,
        .strings = strings,
        .commands = commands,
        .settings = settings,
        .categories = categories,
        .dark_palette = try buildPalette(arena, theme.themes.dark, false),
        .light_palette = try buildPalette(arena, theme.themes.light, false),
        .dark_palette_dim = try buildPalette(arena, theme.themes.dark, true),
        .light_palette_dim = try buildPalette(arena, theme.themes.light, true),
    };
}

/// Build a `term.Palette` (ANSI escape strings) from a `PaletteSpec`'s
/// xterm-256 color indices. Mirrors the former compile-time palettes in
/// src/term.zig: `bg`/`border_bg` are intentionally empty.
fn buildPalette(arena: std.mem.Allocator, p: PaletteSpec, dim: bool) !term.Palette {
    const dim_suffix = if (dim) ";2" else "";
    const dim_suffix_bold = if (dim) ";2" else ";1";

    const g_bg = if (p.grid_bg) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";
    const s_bg = if (p.search_bg) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";
    const st_bg = if (p.status_bg) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";
    const i_bg = if (p.info_bg) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";
    const sel_bg = if (p.selection_bg) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m\x1b[38;5;{d}{s}m", .{ bg_val, p.selection_fg, dim_suffix })
    else
        try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ p.selection_fg, dim_suffix });
    const b_bg = if (p.border_bg) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    return .{
        .grid_bg = g_bg,
        .grid_fg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ g_bg, p.grid_fg, dim_suffix }),
        .selection_bg = sel_bg,
        .search_bg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ s_bg, p.search_fg, dim_suffix }),
        .status_bg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ st_bg, p.status_fg, dim_suffix }),
        .info_bg = i_bg,
        .info_fg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ i_bg, p.info_fg, dim_suffix }),
        .border_bg = b_bg,
        .search_shade_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ p.search_shade_fg, dim_suffix }),
        .status_shade_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ p.status_shade_fg, dim_suffix }),
        .border_shade_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ p.border_shade_fg, dim_suffix }),
        .warning_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ p.warning_fg, dim_suffix_bold }),
        .success_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ p.success_fg, dim_suffix_bold }),
    };
}
