// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Runtime loader for the declarative UI spec (`spec/*.json`).
//!
//! These JSON files are the single source of truth for the layout, theme,
//! key bindings, and UI strings. They are
//! embedded into the binary (see build.zig anonymous imports) and parsed once
//! at startup into a `Spec`. All allocations are made into a caller-provided
//! arena that lives for the process lifetime (the hot picker loop stays
//! allocation-free; parsing happens only at startup).
//!
//! Edit the JSON to change grid sizes, colors, bindings, or text.

const std = @import("std");
const term = @import("term.zig");
const input_mod = @import("input.zig");
pub const KeySeq = input_mod.KeySeq;

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
const styles_json = @embedFile("spec_styles");
const colors_json = @embedFile("spec_colors");
const art_generated_json = @embedFile("spec_art_generated");
const input_generated_json = @embedFile("spec_input_generated");

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
    top_padding: bool = true,
};

pub const PaletteSpec = struct {
    grid_bg: std.json.Value = .null,
    grid_fg: std.json.Value,
    selection_bg: std.json.Value = .null,
    selection_fg: std.json.Value,
    search_bg: std.json.Value = .null,
    search_fg: std.json.Value,
    search_shade_fg: std.json.Value,
    info_bg: std.json.Value = .null,
    info_fg: std.json.Value,
    status_bg: std.json.Value = .null,
    status_fg: std.json.Value,
    status_shade_fg: std.json.Value,
    categories_bg: std.json.Value = .null,
    border_bg: std.json.Value = .null,
    border_shade_fg: std.json.Value,
    app_bg: std.json.Value = .null,
    app_topline_bg: std.json.Value = .null,
    emoji_pane_bg: std.json.Value = .null,
    scrollbar_rail_bg: std.json.Value = .null,
    view_bg: std.json.Value = .null,
    search_cursor_fg: std.json.Value = .null,
    search_text_fg: std.json.Value = .null,
    search_placeholder_fg: std.json.Value = .null,
    search_left_cap_fg: std.json.Value = .null,
    search_left_cap_bg: std.json.Value = .null,
    search_right_cap_fg: std.json.Value = .null,
    search_right_cap_bg: std.json.Value = .null,
    search_sep_fg: std.json.Value = .null,
    search_theme_sep_fg: std.json.Value = .null,
    search_theme_sep_bg: std.json.Value = .null,
    theme_settings_sep_fg: std.json.Value = .null,
    theme_settings_sep_bg: std.json.Value = .null,
    hline_fg: std.json.Value = .null,
    terminal_bg2: ?[]const u8 = null,
    terminal_bg: ?[]const u8 = null,
    terminal_fg: ?[]const u8 = null,
    terminal_border: ?[]const u8 = null,
    warning_fg: std.json.Value = .{ .integer = 9 },
    success_fg: std.json.Value = .{ .integer = 10 },
};

fn resolveColorValue(val: std.json.Value, colors_spec: *const ColorsSpec) !?u8 {
    switch (val) {
        .null => return null,
        .integer => |i| {
            if (i >= 0 and i <= 255) {
                return @intCast(i);
            }
            return error.InvalidColorIndex;
        },
        .string => |s| {
            // 1. Try parsing as integer
            if (std.fmt.parseInt(u8, s, 10)) |idx| {
                return idx;
            } else |_| {}

            // 2. Try parsing as hex
            if (s.len > 0 and s[0] == '#') {
                if (parseHex(s)) |target_rgb| {
                    // Check exact match in colors_spec
                    for (colors_spec.colors) |c| {
                        if (parseHex(c.hex)) |rgb| {
                            if (rgb[0] == target_rgb[0] and rgb[1] == target_rgb[1] and rgb[2] == target_rgb[2]) {
                                return @intCast(c.i);
                            }
                        }
                    }
                    // If no exact match, find closest and warn
                    const closest = colors_spec.closestColorIndex(target_rgb);
                    // Find its name for warning
                    var name: []const u8 = "unknown";
                    var c_hex: []const u8 = "";
                    for (colors_spec.colors) |c| {
                        if (c.i == closest) {
                            name = c.name;
                            c_hex = c.hex;
                            break;
                        }
                    }
                    if (@import("builtin").is_test) {
                        std.debug.print("Warning: color '{s}' is not compatible with the schema, matching to closest color '{s}' (index {d}, hex '{s}')\n", .{ s, name, closest, c_hex });
                    } else {
                        term.appendLog("Warning: color '{s}' is not compatible with the schema, matching to closest color '{s}' (index {d}, hex '{s}')", .{ s, name, closest, c_hex });
                    }
                    return @intCast(closest);
                }
                return error.InvalidHexColor;
            }

            // 3. Look up in colors_spec (by name/short/alt)
            if (colors_spec.indexOf(s)) |idx| {
                return @intCast(idx);
            }

            return error.UnknownColorName;
        },
        else => return error.InvalidColorType,
    }
}

fn resolveRequiredColorValue(val: std.json.Value, colors_spec: *const ColorsSpec, default_val: u8) !u8 {
    if (try resolveColorValue(val, colors_spec)) |idx| {
        return idx;
    }
    return default_val;
}

pub const Theme = struct {
    icons: struct {
        dark: []const u8,
        light: []const u8,
        system: []const u8,
        menu: []const u8,
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
    cmd_start_chars: []const u8 = "/",
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

pub const InputFile = struct {
    input: InputSpec,
};

pub const InputSpec = struct {
    key_aliases: std.json.ArrayHashMap([]const u8),
    key_sequences: []const KeySeq = &.{},
    ctrl_pattern: struct {
        prefix: []const u8,
        base_char: []const u8,
        base_code: u8,
    },
    signals: []const struct {
        name: []const u8,
        number: i32,
        event: []const u8,
    } = &.{},
    terminal_sequences: []const struct {
        seq: []const u8,
        event: []const u8,
    } = &.{},
    mouse: struct {
        prefix: []const u8,
        press_suffix: []const u8,
        release_suffix: []const u8,
        enable_button: []const u8,
        enable_motion: []const u8,
        disable_button: []const u8,
        disable_motion: []const u8,
        btn_button_mask: u8,
        btn_shift_mask: u8,
        btn_meta_mask: u8,
        btn_ctrl_mask: u8,
        btn_motion_flag: u8,
        btn_scroll_flag: u8,
        btn_no_button: u8,
    },
    tokenizer: struct {
        rules: []const struct {
            name: []const u8,
            match: []const u8,
            prefix: ?[]const u8 = null,
            scan_until: ?[]const u8 = null,
            scan_class: ?[]const u8 = null,
            emit: []const u8,
        } = &.{},
    },
};

const emojig_mod = @import("emojig");
pub const CategorySpec = emojig_mod.CategorySpec;
pub const CategoriesSpec = emojig_mod.CategoriesSpec;

pub const AboutArtFile = struct {
    about_frames: []const []const []const u8 = &.{},
    about_delays: []const u16 = &.{},
};

pub const StatusDefault = struct {
    on_view: []const u8 = " ?:help  ↕↔|↵|Esc",
    on_view_wide: []const u8 = " ?:help e:img t:txt  ↕↔|↵|Esc",
    on_search: []const u8 = " {count}  ↕↔|↵|Esc",
    on_search_wide: []const u8 = " {count} e:img t:txt  ↕↔|↵|Esc",
    on_grid_wide: []const u8 = " {count}  Tab:cat  ␣:multi  ↕↔|↵|Esc",
};

pub const StatusMultiSelect = struct {
    no_cursor: []const u8 = " [Multi:{count}] ↕↔",
    on_add: []const u8 = " [Multi:{count}] \x1b[1;34m↵:add\x1b[0m{search_bg}↕↔",
    on_done: []const u8 = " [Multi:{count}] \x1b[1;32m↵:done\x1b[0m{search_bg}⌫:remove",
};

pub const StatusSettings = struct {
    navigate: []const u8 = " ↕:navigate Space:toggle Esc:back",
    keybind: []const u8 = " Type binding  Enter:save  Esc:cancel",
};

pub const StatusCategories = struct {
    navigate: []const u8 = " ↕:navigate Space:toggle Esc:back",
};

pub const StatusView = struct {
    default: []const u8 = " q/Esc:close",
    scrollable: []const u8 = " ↕:scroll  q/Esc:close",
    about: []const u8 = " Space:replay  q/Esc:close",
    about_scrollable: []const u8 = " ↕:scroll Space:replay  q/Esc:close",
};

pub const StatusCommands = struct {
    navigate: []const u8 = " ↕:navigate Enter:run Esc:back",
};

pub const StatusCatFilter = struct {
    navigate: []const u8 = " ↕:navigate Enter/Space:select Esc:back",
};

pub const StatusPopup = struct {
    default: []const u8 = " Space/Enter/Esc:close",
};

pub const StatusStrings = struct {
    default: StatusDefault = .{},
    multi_select: StatusMultiSelect = .{},
    settings: StatusSettings = .{},
    categories: StatusCategories = .{},
    view: StatusView = .{},
    commands: StatusCommands = .{},
    cat_filter: StatusCatFilter = .{},
    popup: StatusPopup = .{},
};

pub const Strings = struct {
    search_prompt: []const u8,
    search_placeholder: []const u8,
    help_lines: []const []const u8,
    help_lines_more: []const []const u8,
    about_frames: []const []const []const u8 = &[_][]const []const u8{},
    about_delays: []const u16 = &[_]u16{},
    status_lines: []const []const u8 = &[_][]const u8{},
    focus_lost_startup_lines: []const []const u8 = &[_][]const u8{ "⚠️  Cannot steal Wayland", "popup focus?", "", "Click window to focus!" },
    focus_lost_runtime_lines: []const []const u8 = &[_][]const u8{ "⚠️  Picker unfocused.", "", "", "Click window to focus!" },
    // Cursor box drawn around the focused / first-hit emoji. Each side must be a
    // single display cell (e.g. ⌜ ⌟, [ ], ⟨ ⟩, ▏ ▕) so the 4-col grid stays aligned.
    cursor_left: []const u8 = "⌜",
    cursor_right: []const u8 = "⌟",
    // Single-width glyph prefixed to emojis picked in multi-select mode. Keep it
    // one cell wide (e.g. ✓ ✔ · • ＊ ▸) so the 4-col grid stays aligned. When set
    // to "" the mark is dropped and picked cells are shown with multi_select_bg.
    multi_select_mark: []const u8 = "✓",
    // Background highlight for picked cells when multi_select_mark is empty —
    // any color name from spec/colors.json (long like `forest`/`teal`, 3-letter
    // short like `grn`/`blu`) or a literal 0-255 palette index.
    multi_select_bg: []const u8 = "green",
    // Scrollbar thumb character (default ▐). Must be exactly one display cell.
    scrollbar_char: []const u8 = "▐",
    // Separator between toolbar buttons (theme icon and menu icon). Must be one
    // display cell wide (e.g. " ", "│", "|", "▏"). Rendered with the grid
    // background color as foreground so it reads as a subtle divider.
    toolbar_sep: []const u8 = " ",
    // Per-segment search-bar separators. Empty string falls back to toolbar_sep.
    search_theme_sep: []const u8 = "",
    theme_settings_sep: []const u8 = "",
    // Search-bar half-block cap characters. Must each be one display cell wide.
    search_left_cap: []const u8 = "▌",
    search_right_cap: []const u8 = "▐",
    // Horizontal separator line character (default ─).
    hline_char: []const u8 = "─",
    status: StatusStrings = .{},
};

pub const StylesSpec = struct {
    styles: std.json.ArrayHashMap([]const u8) = .{},
};

/// One documented xterm-256 palette slot (see spec/colors.json).
pub const ColorEntry = struct {
    i: u16,
    name: []const u8 = "",
    short: []const u8 = "",
    hex: []const u8 = "",
    desc: []const u8 = "",
    alt: []const []const u8 = &.{},
};

pub const ColorsSpec = struct {
    colors: []const ColorEntry = &.{},

    /// Resolve a colour name (long, short, or alias) to its 0-255 palette
    /// index. Case-insensitive, first match wins (lower index). Returns null when
    /// the name is unknown — callers then fall back to numeric parsing.
    pub fn indexOf(self: *const ColorsSpec, name: []const u8) ?u16 {
        var search_buf: [64]u8 = undefined;
        const norm_search = normalizeColorName(name, &search_buf);

        for (self.colors) |c| {
            var c_buf: [64]u8 = undefined;
            if (std.mem.eql(u8, norm_search, normalizeColorName(c.name, &c_buf))) return c.i;
            if (c.short.len != 0) {
                if (std.mem.eql(u8, norm_search, normalizeColorName(c.short, &c_buf))) return c.i;
            }
            for (c.alt) |a| {
                if (std.mem.eql(u8, norm_search, normalizeColorName(a, &c_buf))) return c.i;
            }
        }
        return null;
    }

    pub fn closestColorIndex(self: *const ColorsSpec, target_rgb: [3]u8) u16 {
        var best_idx: u16 = 0;
        var best_dist: u32 = std.math.maxInt(u32);
        for (self.colors) |c| {
            if (parseHex(c.hex)) |rgb| {
                const dr = @as(i32, target_rgb[0]) - rgb[0];
                const dg = @as(i32, target_rgb[1]) - rgb[1];
                const db = @as(i32, target_rgb[2]) - rgb[2];
                const dist = @as(u32, @intCast(dr * dr + dg * dg + db * db));
                if (dist < best_dist) {
                    best_dist = dist;
                    best_idx = c.i;
                }
            }
        }
        return best_idx;
    }
};

fn normalizeColorName(name: []const u8, buf: []u8) []const u8 {
    var out_len: usize = 0;
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') {
            buf[out_len] = c + 32;
            out_len += 1;
        } else if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            buf[out_len] = c;
            out_len += 1;
        }
    }
    return buf[0..out_len];
}

pub fn parseHex(hex_str: []const u8) ?[3]u8 {
    var s = hex_str;
    if (s.len > 0 and s[0] == '#') {
        s = s[1..];
    }
    if (s.len == 3) {
        const r = std.fmt.parseInt(u8, s[0..1], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[1..2], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[2..3], 16) catch return null;
        return [3]u8{ r * 17, g * 17, b * 17 };
    } else if (s.len == 6) {
        const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
        return [3]u8{ r, g, b };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Spec bundle
// ---------------------------------------------------------------------------

pub const Spec = struct {
    layout: Layout,
    theme: Theme,
    keys: Keys,
    strings: Strings,
    input: InputSpec,
    commands: Commands,
    settings: SettingsSpec,
    categories: CategoriesSpec,
    styles: StylesSpec,
    colors: ColorsSpec,
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
    var layout = try std.json.parseFromSliceLeaky(Layout, arena, layout_json, parse_opts);
    if (!layout.top_padding) {
        if (layout.layout_overhead > 0) layout.layout_overhead -= 1;
    }
    const theme = try std.json.parseFromSliceLeaky(Theme, arena, theme_json, parse_opts);
    const keys = try std.json.parseFromSliceLeaky(Keys, arena, keys_json, parse_opts);

    const input_file = try std.json.parseFromSliceLeaky(InputFile, arena, input_generated_json, parse_opts);
    const about_art = try std.json.parseFromSliceLeaky(AboutArtFile, arena, art_generated_json, parse_opts);

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

    var strings = try std.json.parseFromSliceLeaky(Strings, arena, strings_content, parse_opts);
    strings.about_frames = about_art.about_frames;
    strings.about_delays = about_art.about_delays;
    const commands = try std.json.parseFromSliceLeaky(Commands, arena, commands_json, parse_opts);
    const settings = try std.json.parseFromSliceLeaky(SettingsSpec, arena, settings_json, parse_opts);
    const categories = try std.json.parseFromSliceLeaky(CategoriesSpec, arena, categories_json, parse_opts);
    const styles = try std.json.parseFromSliceLeaky(StylesSpec, arena, styles_json, parse_opts);
    const colors = try std.json.parseFromSliceLeaky(ColorsSpec, arena, colors_json, parse_opts);

    return .{
        .layout = layout,
        .theme = theme,
        .keys = keys,
        .strings = strings,
        .input = input_file.input,
        .commands = commands,
        .settings = settings,
        .categories = categories,
        .styles = styles,
        .colors = colors,
        .dark_palette = try buildPalette(arena, theme.themes.dark, &colors, false),
        .light_palette = try buildPalette(arena, theme.themes.light, &colors, false),
        .dark_palette_dim = try buildPalette(arena, theme.themes.dark, &colors, true),
        .light_palette_dim = try buildPalette(arena, theme.themes.light, &colors, true),
    };
}

/// Build a `term.Palette` (ANSI escape strings) from a `PaletteSpec`'s
/// xterm-256 color indices. Mirrors the former compile-time palettes in
/// src/term.zig: `bg`/`border_bg` are intentionally empty.
fn buildPalette(arena: std.mem.Allocator, p: PaletteSpec, colors_spec: *const ColorsSpec, dim: bool) !term.Palette {
    const dim_suffix = if (dim) ";2" else "";
    const dim_suffix_bold = if (dim) ";2" else ";1";

    const g_bg_idx = try resolveColorValue(p.grid_bg, colors_spec);
    const g_bg = if (g_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    // Resolve overall canvas app background color
    const app_bg_idx = try resolveColorValue(p.app_bg, colors_spec);
    const app_bg = if (app_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    // If app_topline_bg is null, default to border_bg (if set) or app_bg.
    const app_topline_bg_idx = try resolveColorValue(p.app_topline_bg, colors_spec) orelse (try resolveColorValue(p.border_bg, colors_spec)) orelse app_bg_idx;
    const app_topline_bg = if (app_topline_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    const emoji_pane_bg_idx = try resolveColorValue(p.emoji_pane_bg, colors_spec) orelse app_bg_idx;
    const emoji_pane_bg = if (emoji_pane_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    const scrollbar_rail_bg_idx = try resolveColorValue(p.scrollbar_rail_bg, colors_spec) orelse app_bg_idx;
    const scrollbar_rail_bg = if (scrollbar_rail_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    const view_bg_idx = try resolveColorValue(p.view_bg, colors_spec) orelse app_bg_idx;
    const view_bg = if (view_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    // Resolve the terminal window background (terminal_bg2 hex → closest 256-color
    // index). Used as the separator fg so │ blends into the terminal background.
    const term_bg_val: std.json.Value = if (p.terminal_bg2) |hex| .{ .string = hex } else .null;
    const term_bg_idx = try resolveColorValue(term_bg_val, colors_spec);

    const s_bg_idx = try resolveColorValue(p.search_bg, colors_spec);
    const s_bg = if (s_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    const st_bg_idx = try resolveColorValue(p.status_bg, colors_spec);
    const st_bg = if (st_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    // categories_bg: null → same as search_bg (both bars share the same accent strip by default).
    const cat_bg_idx = try resolveColorValue(p.categories_bg, colors_spec) orelse s_bg_idx;
    const cat_bg = if (cat_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    const i_bg_idx = try resolveColorValue(p.info_bg, colors_spec);
    const i_bg = if (i_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    const sel_bg_idx = try resolveColorValue(p.selection_bg, colors_spec);
    const sel_fg_idx = try resolveRequiredColorValue(p.selection_fg, colors_spec, 255);
    const sel_bg = if (sel_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m\x1b[38;5;{d}{s}m", .{ bg_val, sel_fg_idx, dim_suffix })
    else
        try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ sel_fg_idx, dim_suffix });

    const b_bg_idx = try resolveColorValue(p.border_bg, colors_spec);
    const b_bg = if (b_bg_idx) |bg_val|
        try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m", .{bg_val})
    else
        "";

    const grid_fg_idx = try resolveRequiredColorValue(p.grid_fg, colors_spec, 248);
    const search_fg_idx = try resolveRequiredColorValue(p.search_fg, colors_spec, 255);
    const status_fg_idx = try resolveRequiredColorValue(p.status_fg, colors_spec, 240);
    const info_fg_idx = try resolveRequiredColorValue(p.info_fg, colors_spec, 248);
    const search_shade_fg_idx = try resolveRequiredColorValue(p.search_shade_fg, colors_spec, 238);
    const status_shade_fg_idx = try resolveRequiredColorValue(p.status_shade_fg, colors_spec, 238);
    const border_shade_fg_idx = try resolveRequiredColorValue(p.border_shade_fg, colors_spec, 236);
    const warning_fg_idx = try resolveRequiredColorValue(p.warning_fg, colors_spec, 9);
    const success_fg_idx = try resolveRequiredColorValue(p.success_fg, colors_spec, 10);

    // cap_fallback: fg for caps (▌/▐) — must match terminal bg so the half-block
    // creates a smooth blend from canvas into the search bar.  Uses terminal_bg2
    // (closest 256-color to the actual window background) or grid bg as proxy.
    const cap_fallback_idx = app_bg_idx orelse term_bg_idx;

    // search_sep_fg: explicit override for ALL separator segments.  Stays null
    // when not configured — seps use \x1b[39m (terminal default fg) so they are
    // visible on the search bar bg without inheriting the near-black cap_fallback.
    const search_sep_fg_idx = try resolveColorValue(p.search_sep_fg, colors_spec);

    // Cap foregrounds — must blend into the canvas, so fall back to cap_fallback.
    const l_cap_fg_idx = try resolveColorValue(p.search_left_cap_fg, colors_spec) orelse cap_fallback_idx;
    const r_cap_fg_idx = try resolveColorValue(p.search_right_cap_fg, colors_spec) orelse cap_fallback_idx;

    // Cap backgrounds — null falls back to search_bg.
    const l_cap_bg_idx = try resolveColorValue(p.search_left_cap_bg, colors_spec) orelse s_bg_idx;
    const r_cap_bg_idx = try resolveColorValue(p.search_right_cap_bg, colors_spec) orelse s_bg_idx;

    // Per-segment separator fgs — null → search_sep_fg → cap_fallback_idx (app bg).
    // This makes a null sep fg "punch through" to the canvas, matching cap semantics.
    const search_theme_sep_fg_idx = try resolveColorValue(p.search_theme_sep_fg, colors_spec) orelse search_sep_fg_idx orelse cap_fallback_idx;
    const theme_settings_sep_fg_idx = try resolveColorValue(p.theme_settings_sep_fg, colors_spec) orelse search_sep_fg_idx orelse cap_fallback_idx;
    // Per-segment separator bgs — null → cap_fallback_idx (app bg), not search_bg.
    const search_theme_sep_bg_idx = try resolveColorValue(p.search_theme_sep_bg, colors_spec) orelse cap_fallback_idx;
    const theme_settings_sep_bg_idx = try resolveColorValue(p.theme_settings_sep_bg, colors_spec) orelse cap_fallback_idx;

    // Search text-area foreground overrides (empty when null — inherit from search_bg).
    const search_cursor_fg_idx = try resolveColorValue(p.search_cursor_fg, colors_spec);
    const search_text_fg_idx = try resolveColorValue(p.search_text_fg, colors_spec);
    const search_placeholder_fg_idx = try resolveColorValue(p.search_placeholder_fg, colors_spec);

    // Resolve hline_fg (defaults to a muted gray)
    const hline_fg_idx = try resolveColorValue(p.hline_fg, colors_spec) orelse 240;

    // Build a bg+fg escape sequence from optional indices. Returns "" when bg is null.
    // Helper closure via inline:
    const buildSeq = struct {
        fn call(alloc: std.mem.Allocator, bg: ?u8, fg: ?u8) ![]const u8 {
            if (bg) |b| {
                if (fg) |f| return std.fmt.allocPrint(alloc, "\x1b[48;5;{d}m\x1b[38;5;{d}m", .{ b, f });
                return std.fmt.allocPrint(alloc, "\x1b[48;5;{d}m\x1b[39m", .{b});
            }
            if (fg) |f| return std.fmt.allocPrint(alloc, "\x1b[38;5;{d}m", .{f});
            return "";
        }
    }.call;

    // Search bar left/right cap escape sequences (colors only — no glyph char).
    const l_cap_seq = try buildSeq(arena, l_cap_bg_idx, l_cap_fg_idx);
    const r_cap_seq = try buildSeq(arena, r_cap_bg_idx, r_cap_fg_idx);

    // Per-segment separator escape sequences.
    const search_theme_sep_seq = try buildSeq(arena, search_theme_sep_bg_idx, search_theme_sep_fg_idx);
    const theme_settings_sep_seq = try buildSeq(arena, theme_settings_sep_bg_idx, theme_settings_sep_fg_idx);

    // Search text-area fg sequences (empty when not configured).
    const search_cursor_fg_seq = if (search_cursor_fg_idx) |i|
        try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{i})
    else
        @as([]const u8, "");
    const search_text_fg_seq = if (search_text_fg_idx) |i|
        try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{i})
    else
        @as([]const u8, "");
    const search_placeholder_fg_seq = if (search_placeholder_fg_idx) |i|
        try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{i})
    else
        @as([]const u8, "");

    // Build hline (background = app_bg, foreground = hline_fg_idx)
    const hline = blk: {
        if (app_bg_idx) |ab| {
            break :blk try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m\x1b[38;5;{d}m", .{ ab, hline_fg_idx });
        } else {
            break :blk try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{hline_fg_idx});
        }
    };

    return .{
        .grid_bg = g_bg,
        .grid_fg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ g_bg, grid_fg_idx, dim_suffix }),
        .grid_fg_only = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ grid_fg_idx, dim_suffix }),
        .selection_bg = sel_bg,
        .search_bg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ s_bg, search_fg_idx, dim_suffix }),
        .status_bg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ st_bg, status_fg_idx, dim_suffix }),
        .categories_bg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ cat_bg, status_fg_idx, dim_suffix }),
        .info_bg = i_bg,
        .info_fg = try std.fmt.allocPrint(arena, "{s}\x1b[38;5;{d}{s}m", .{ i_bg, info_fg_idx, dim_suffix }),
        .border_bg = b_bg,
        .search_shade_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ search_shade_fg_idx, dim_suffix }),
        .status_shade_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ status_shade_fg_idx, dim_suffix }),
        .border_shade_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ border_shade_fg_idx, dim_suffix }),
        .warning_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ warning_fg_idx, dim_suffix_bold }),
        .success_fg = try std.fmt.allocPrint(arena, "\x1b[38;5;{d}{s}m", .{ success_fg_idx, dim_suffix_bold }),
        .toolbar_sep_fg = if (term_bg_idx) |t_val|
            try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{t_val})
        else if (g_bg_idx) |bg_val|
            try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{bg_val})
        else if (b_bg_idx) |b_val|
            try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{b_val})
        else
            try std.fmt.allocPrint(arena, "\x1b[2m", .{}),
        .app_bg = app_bg,
        .app_topline_bg = app_topline_bg,
        .emoji_pane_bg = emoji_pane_bg,
        .scrollbar_rail_bg = scrollbar_rail_bg,
        .view_bg = view_bg,
        .search_left_cap_seq = l_cap_seq,
        .search_right_cap_seq = r_cap_seq,
        .search_theme_sep = search_theme_sep_seq,
        .theme_settings_sep = theme_settings_sep_seq,
        .search_cursor_fg = search_cursor_fg_seq,
        .search_text_fg = search_text_fg_seq,
        .search_placeholder_fg = search_placeholder_fg_seq,
        .hline = hline,
    };
}
