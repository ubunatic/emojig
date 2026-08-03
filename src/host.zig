// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const term_lib = @import("term.zig");
const Theme = term_lib.Theme;
const writeAll = term_lib.writeAll;
const spec_mod = @import("spec.zig");

// ---------------------------------------------------------------------------
// Host terminal spec (spec/host.yaml → spec/.gen/host.json, embedded)
// ---------------------------------------------------------------------------

const host_json = @embedFile("spec_host");

/// One terminal's launch argv template (see spec/host.yaml for the
/// placeholder contract). All lists default to empty so a minimal entry is
/// just a name plus tail_separator.
pub const TerminalSpec = struct {
    name: []const u8,
    args: []const []const u8 = &.{},
    borderless_args: []const []const u8 = &.{},
    decorated_args: []const []const u8 = &.{},
    post_args: []const []const u8 = &.{},
    tail_separator: []const u8 = "",
};

pub const HostSpec = struct {
    detection: []const []const u8 = &.{},
    terminals: []const TerminalSpec = &.{},
};

var parsed_host_spec: ?HostSpec = null;
var host_arena_bytes: [16 * 1024]u8 = undefined;

/// Lazily parse the embedded host spec. The parsed slices point into the
/// global fixed buffer, so no heap allocation and process lifetime.
pub fn getGlobalHostSpec() *const HostSpec {
    if (parsed_host_spec == null) {
        var fba = std.heap.FixedBufferAllocator.init(&host_arena_bytes);
        parsed_host_spec = std.json.parseFromSliceLeaky(HostSpec, fba.allocator(), host_json, .{ .ignore_unknown_fields = true }) catch unreachable;
    }
    return &parsed_host_spec.?;
}

/// Last-resort template when spec/host.yaml has no `generic` entry: run the
/// terminal as `<term> -e <tail>` like the spec's own generic fallback.
const generic_terminal = TerminalSpec{ .name = "generic", .tail_separator = "-e" };

/// Find the argv template for a terminal basename ("kitty"), falling back to
/// the spec's `generic` entry (or a built-in equivalent as a safety net).
pub fn terminalSpecFor(name: []const u8) *const TerminalSpec {
    const hspec = getGlobalHostSpec();
    for (hspec.terminals) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    for (hspec.terminals) |*t| {
        if (std.mem.eql(u8, t.name, "generic")) return t;
    }
    return &generic_terminal;
}

/// Check whether `name` (a basename like "kitty") exists as an executable on
/// `$PATH`. Uses only stack buffers — no heap allocation.
pub fn whichOnPath(path_env: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const joined = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        const rc = std.posix.system.faccessat(std.posix.AT.FDCWD, joined, std.posix.X_OK, 0);
        if (std.posix.errno(rc) == .SUCCESS) return true;
    }
    return false;
}

/// Select the terminal host to use, following this precedence:
///   1. EMOJIG_TERMINAL (absolute path or name; used as-is, no PATH check needed)
///   2. $TERMINAL env var if the program exists on PATH
///   3. spec/host.yaml `detection` list — first found on PATH wins.
/// Returns the terminal executable string and its argv template.
/// Returns null if no usable terminal could be found.
pub const TerminalSelection = struct {
    exe: []const u8,
    tspec: *const TerminalSpec,
};

pub fn selectTerminalHost(environ_map: anytype) ?TerminalSelection {
    const path_env = environ_map.get("PATH") orelse "";

    // 1. EMOJIG_TERMINAL — explicit override, no PATH check
    if (environ_map.get("EMOJIG_TERMINAL")) |t| {
        if (t.len > 0) {
            const base = std.fs.path.basename(t);
            return .{ .exe = t, .tspec = terminalSpecFor(base) };
        }
    }

    // 2. $TERMINAL if it exists on PATH
    if (environ_map.get("TERMINAL")) |t| {
        if (t.len > 0 and whichOnPath(path_env, t)) {
            return .{ .exe = t, .tspec = terminalSpecFor(t) };
        }
    }

    // 3. Detection list from spec/host.yaml — foot preferred (listed first)
    for (getGlobalHostSpec().detection) |name| {
        if (whichOnPath(path_env, name)) {
            return .{ .exe = name, .tspec = terminalSpecFor(name) };
        }
    }

    return null;
}

fn concreteThemeString(theme: Theme) []const u8 {
    return switch (theme) {
        .dark => "dark",
        .light => "light",
        .system => unreachable,
    };
}

const ColorPair = struct { name: []const u8, dark: []const u8, light: []const u8 };

const app_bg_table = [_]ColorPair{
    .{ .name = "default", .dark = "2c2c2c", .light = "d0d0df" },
    .{ .name = "deep", .dark = "1c1c1c", .light = "c8c8dc" },
    .{ .name = "navy", .dark = "1e2030", .light = "d8ddf0" },
    .{ .name = "slate", .dark = "252535", .light = "dcdce8" },
};

const title_bg_table = [_]ColorPair{
    .{ .name = "accent", .dark = "243060", .light = "c8d0f8" },
    .{ .name = "dark", .dark = "141414", .light = "e8e8f8" },
};

fn lightenHex(hex6: []const u8, delta: i32, out: *[6]u8) []const u8 {
    if (hex6.len < 6) return hex6;
    const r = std.fmt.parseInt(u8, hex6[0..2], 16) catch return hex6;
    const g = std.fmt.parseInt(u8, hex6[2..4], 16) catch return hex6;
    const b = std.fmt.parseInt(u8, hex6[4..6], 16) catch return hex6;
    const cl = struct {
        fn f(v: i32) u8 {
            return @intCast(@max(0, @min(255, v)));
        }
    }.f;
    return std.fmt.bufPrint(out, "{x:0>2}{x:0>2}{x:0>2}", .{
        cl(@as(i32, r) + delta),
        cl(@as(i32, g) + delta),
        cl(@as(i32, b) + delta),
    }) catch hex6;
}

/// Returns a bare 6-hex-digit string (no leading #) for the foot terminal background.
pub fn resolveAppBgHex(choice: []const u8, is_dark: bool) []const u8 {
    for (app_bg_table) |p| {
        if (std.mem.eql(u8, p.name, choice))
            return if (is_dark) p.dark else p.light;
    }
    return if (is_dark) "2c2c2c" else "d0d0df";
}

/// Returns a bare 6-hex-digit string for the CSD title bar color.
/// `app_hex` must be the result of resolveAppBgHex; `buf` is scratch for derived values.
pub fn resolveTitleBgHex(choice: []const u8, app_hex: []const u8, is_dark: bool, buf: *[6]u8) []const u8 {
    if (std.mem.eql(u8, choice, "same")) return app_hex;
    if (std.mem.eql(u8, choice, "raised")) {
        const delta: i32 = if (is_dark) 18 else -18;
        return lightenHex(app_hex, delta, buf);
    }
    for (title_bg_table) |p| {
        if (std.mem.eql(u8, p.name, choice))
            return if (is_dark) p.dark else p.light;
    }
    // Fallback: raised
    const delta: i32 = if (is_dark) 18 else -18;
    return lightenHex(app_hex, delta, buf);
}

/// Choose a legible title-bar text color based on the background luminance.
/// Returns a bare 6-hex-digit string for use as `colors.background` (foot
/// renders the CSD title text using that color — no csd.foreground option exists).
/// `fg_on_dark`/`fg_on_light` are bare hex strings (no '#'); `threshold` is 0–255.
pub fn csdTitleFgHex(
    title_hex: []const u8,
    fg_on_dark: []const u8,
    fg_on_light: []const u8,
    threshold: u32,
) []const u8 {
    if (title_hex.len < 6) return fg_on_dark;
    const r = std.fmt.parseInt(u32, title_hex[0..2], 16) catch return fg_on_dark;
    const g = std.fmt.parseInt(u32, title_hex[2..4], 16) catch return fg_on_dark;
    const b = std.fmt.parseInt(u32, title_hex[4..6], 16) catch return fg_on_dark;
    // Perceptual luminance (ITU-R BT.709 coefficients × 10000)
    const lum = (r * 2126 + g * 7152 + b * 722) / 10000;
    return if (lum < threshold) fg_on_dark else fg_on_light;
}

/// Maximum argv length — foot (borderless) is the largest at ~14 prefix tokens
/// plus a 17-token tail; 40 gives safe headroom for spec-added flags.
pub const MAX_ARGV = 40;

/// Longest substituted argv token (placeholder templates only; literal
/// entries are passed through without copying).
pub const MAX_ARG_LEN = 192;

/// Values available to spec/host.yaml `{placeholder}` argv templates. Every
/// field holds a fully formatted argument fragment; an empty value drops the
/// template entry that references it.
pub const ArgValues = struct {
    title: []const u8 = "",
    size: []const u8 = "",
    font: []const u8 = "",
    bg: []const u8 = "",
    fg: []const u8 = "",
    border_color: []const u8 = "",
    csd_size: []const u8 = "",
    csd_color: []const u8 = "",
    csd_title_font: []const u8 = "",
};

fn argValueFor(values: ArgValues, name: []const u8) ?[]const u8 {
    inline for (std.meta.fields(ArgValues)) |f| {
        if (std.mem.eql(u8, f.name, name)) return @field(values, f.name);
    }
    return null;
}

/// Substitute `{placeholder}` occurrences in one argv template entry.
/// Returns null when the entry must be dropped: unknown/malformed placeholder,
/// empty placeholder value, or overflow of `buf`. Entries without any
/// placeholder are returned as-is (no copy).
fn renderArg(template: []const u8, values: ArgValues, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, template, '{') == null) return template;
    var len: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, template, i, '}') orelse return null;
            const value = argValueFor(values, template[i + 1 .. end]) orelse return null;
            if (value.len == 0) return null;
            if (len + value.len > buf.len) return null;
            @memcpy(buf[len..][0..value.len], value);
            len += value.len;
            i = end + 1;
        } else {
            if (len >= buf.len) return null;
            buf[len] = template[i];
            len += 1;
            i += 1;
        }
    }
    return buf[0..len];
}

fn appendTemplated(
    out: *[MAX_ARGV][]const u8,
    bufs: *[MAX_ARGV][MAX_ARG_LEN]u8,
    n: usize,
    templates: []const []const u8,
    values: ArgValues,
) usize {
    var m = n;
    for (templates) |t| {
        if (m >= out.len) return m;
        if (renderArg(t, values, &bufs[m])) |arg| {
            out[m] = arg;
            m += 1;
        }
    }
    return m;
}

/// Assemble the full launch argv into `out[0..N]` and return the live slice.
/// Argument strings are either literals from the embedded host spec, slices
/// of `values` inputs copied into `bufs`, or `tail` entries — all with
/// lifetimes at least as long as `out`.
///
/// `borderless` selects `borderless_args` over `decorated_args` (see
/// spec/host.yaml). Terminals without a decorations CLI flag simply have no
/// mode args, so the request is silently ignored for them. This is unrelated
/// to the in-TUI `--border` / `EMOJIG_BORDER` colored row.
///
/// NOTE: Cell-precise window sizing is foot-only. Other terminals receive the
/// `env EMOJIG_RESIZE_MODE=altscreen` tail and adapt via altscreen mode.
pub fn buildGuiArgv(
    out: *[MAX_ARGV][]const u8,
    bufs: *[MAX_ARGV][MAX_ARG_LEN]u8,
    tspec: *const TerminalSpec,
    term: []const u8,
    borderless: bool,
    values: ArgValues,
    tail: []const []const u8,
) []const []const u8 {
    var n: usize = 0;
    out[n] = term;
    n += 1;
    n = appendTemplated(out, bufs, n, tspec.args, values);
    n = appendTemplated(out, bufs, n, if (borderless) tspec.borderless_args else tspec.decorated_args, values);
    n = appendTemplated(out, bufs, n, tspec.post_args, values);
    if (tspec.tail_separator.len > 0 and n < out.len) {
        out[n] = tspec.tail_separator;
        n += 1;
    }
    for (tail) |s| {
        if (n >= out.len) break;
        out[n] = s;
        n += 1;
    }
    return out[0..n];
}

/// Strip leading '#' and expand 3-char CSS shorthand to 6-digit RGB.
/// "#abc" → "aabbcc", "#aabbcc" → "aabbcc", "" / no '#' → "".
/// `buf` must be at least 8 bytes. Returns the bare hex slice (no '#').
fn expandHex(raw: []const u8, buf: *[8]u8) []const u8 {
    const hex = if (raw.len > 0 and raw[0] == '#') raw[1..] else raw;
    if (hex.len == 3) {
        buf[0] = hex[0];
        buf[1] = hex[0];
        buf[2] = hex[1];
        buf[3] = hex[1];
        buf[4] = hex[2];
        buf[5] = hex[2];
        return buf[0..6];
    }
    if (hex.len == 6 or hex.len == 8) return hex;
    return "";
}

/// Run `gsettings get SCHEMA KEY` and return the output (stripped) in `buf`.
/// Returns a slice into `buf`, or empty on failure.
fn gsettingsGet(io: anytype, schema: []const u8, key: []const u8, buf: []u8) []u8 {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    const pipe_rc = std.os.linux.pipe2(&pipe_fds, .{});
    if (std.posix.errno(pipe_rc) != .SUCCESS) return buf[0..0];

    const argv = [_][]const u8{ "gsettings", "get", schema, key };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    }) catch {
        _ = std.posix.system.close(pipe_fds[1]);
        _ = std.posix.system.close(pipe_fds[0]);
        return buf[0..0];
    };
    _ = std.posix.system.close(pipe_fds[1]);

    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(pipe_fds[0], buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = std.posix.system.close(pipe_fds[0]);
    _ = child.wait(io) catch {};
    const trimmed = std.mem.trim(u8, buf[0..total], " \t\n\r'\"");
    return @constCast(trimmed);
}

/// Query GNOME's UI font size and text scaling factor from gsettings, then
/// return a comfortable CSD title bar height in pixels (ratio 2.5×).
/// Falls back to `fallback` if gsettings is unavailable or unparseable.
fn detectCsdSize(io: anytype, fallback: usize, pt_factor: usize) usize {
    var font_buf: [64]u8 = undefined;
    const font_str = gsettingsGet(io, "org.gnome.desktop.interface", "font-name", &font_buf);
    if (font_str.len == 0) return fallback;

    // font-name is like: 'Ubuntu Sans 11' — last word is the pt size.
    const last_space = std.mem.lastIndexOfScalar(u8, font_str, ' ') orelse return fallback;
    const pt = std.fmt.parseInt(usize, font_str[last_space + 1 ..], 10) catch return fallback;
    if (pt == 0) return fallback;

    // text-scaling-factor is like: 1.1 — parse integer + first decimal digit.
    // Represent as fixed-point tenths: "1.0999..." → 11, "1.25" → 12.
    var scale_buf: [32]u8 = undefined;
    const scale_str = gsettingsGet(io, "org.gnome.desktop.interface", "text-scaling-factor", &scale_buf);
    var scale10: usize = 10; // default 1.0 × 10
    if (scale_str.len > 0) {
        const dot = std.mem.indexOfScalar(u8, scale_str, '.');
        const int_part = std.fmt.parseInt(usize, if (dot) |d| scale_str[0..d] else scale_str, 10) catch 1;
        // Round to nearest tenth: read first two decimal digits.
        const frac_digit: usize = if (dot) |d| blk: {
            const d1: usize = if (d + 1 < scale_str.len) (scale_str[d + 1] - '0') else 0;
            const d2: usize = if (d + 2 < scale_str.len) (scale_str[d + 2] - '0') else 0;
            break :blk if (d2 >= 5) d1 + 1 else d1;
        } else 0;
        scale10 = int_part * 10 + frac_digit;
    }

    // csd.size = pt × scale × (pt_factor/100), e.g. factor=25 → 2.5×
    return pt * scale10 * pt_factor / 100;
}

pub fn spawnGuiWindow(
    init: std.process.Init,
    exe_path: []const u8,
    theme: Theme,
    border: bool,
    safe: bool,
    debug: bool,
    wait: bool,
    borderless: bool,
    cols_val: usize,
    rows_val: usize,
    compact: bool,
    spec: *const spec_mod.Spec,
    show_switcher: bool,
    font_size: usize,
    title_size: usize,
    app_bg_choice: []const u8,
    title_bg_choice: []const u8,
) !void {
    const io = init.io;

    // GUI window colors come from spec/theme.yaml (foot wants bare hex, so we
    // strip the leading '#'). Resolve `system` from GNOME before spawning so
    // the host window starts with the same effective palette as the child TUI.
    // Foot requires full 6-digit RGB (rrggbb) or 8-digit ARGB — 3-char shorthand
    // like "#ccc" must be expanded to "#cccccc" before stripping.
    const effective_theme = if (theme == .system) (term_lib.detectDesktopTheme(io) orelse .dark) else theme;
    const theme_str: []const u8 = switch (theme) {
        .dark => "dark",
        .light => "light",
        .system => "system",
    };
    const effective_theme_str = concreteThemeString(effective_theme);
    const gui_pal = if (effective_theme == .light) spec.theme.themes.light else spec.theme.themes.dark;
    const is_dark = effective_theme != .light;
    const app_hex = resolveAppBgHex(app_bg_choice, is_dark);
    var foot_bg_exp: [8]u8 = undefined;
    const foot_bg = if (app_hex.len > 0) app_hex else expandHex(gui_pal.terminal_bg2 orelse "", &foot_bg_exp);
    var foot_fg_exp: [8]u8 = undefined;
    var foot_bd_exp: [8]u8 = undefined;
    const foot_fg = expandHex(gui_pal.terminal_fg orelse "", &foot_fg_exp);
    const foot_border = expandHex(gui_pal.terminal_border orelse "", &foot_bd_exp);

    // GUI grid dimensions are resolved by the caller (config → spec) and passed
    // in so the foot window matches the picker's unified grid size exactly.
    // Content width follows the column count (one trailing scrollbar gutter
    // column), mirroring the in-picker `content_width = cols*cell_w + 1`.
    const cell_w = if (compact) @as(usize, 3) else 4;
    const width_val = cols_val * cell_w + (if (compact) @as(usize, 2) else 1);

    // Derive the window height from the GUI grid rows.
    // GUI always shows the switcher, which adds 1 extra hline row between grid and switcher.
    const gui_content_rows: usize = rows_val + spec.layout.layout_overhead + 1;
    var final_h = if (border) gui_content_rows + 2 else gui_content_rows;
    if (debug) final_h += 2;

    var size_buf: [64]u8 = undefined;
    const size_arg = try std.fmt.bufPrint(&size_buf, "--window-size-chars={d}x{d}", .{ width_val + 1, final_h });

    // Resolve the title bar hex early — needed for both csd.color and the
    // colors.background contrast override below.
    var title_hex_buf_early: [6]u8 = undefined;
    const title_hex_early = resolveTitleBgHex(title_bg_choice, app_hex, is_dark, &title_hex_buf_early);

    // In decorated mode foot renders the CSD title text using colors.background
    // (confirmed by testing — foot has no csd.foreground option).  Override it
    // with a luminance-computed contrast color so the title text is legible on
    // any title-bar preset.  The TUI is unaffected: emojig paints every cell
    // with explicit ANSI escape codes so colors.background is never visible
    // inside the terminal content area.
    const csd = spec.theme.csd;
    var bg_buf: [64]u8 = undefined;
    var csd_fg_dark_exp: [8]u8 = undefined;
    var csd_fg_light_exp: [8]u8 = undefined;
    const csd_fg_dark = expandHex(csd.title_fg_on_dark, &csd_fg_dark_exp);
    const csd_fg_light = expandHex(csd.title_fg_on_light, &csd_fg_light_exp);
    const csd_threshold: u32 = csd.title_luminance_threshold;
    const bg_arg: []const u8 = if (!borderless and title_hex_early.len == 6)
        try std.fmt.bufPrint(&bg_buf, "--override=colors.background={s}", .{csdTitleFgHex(title_hex_early, csd_fg_dark, csd_fg_light, csd_threshold)})
    else if (foot_bg.len > 0)
        try std.fmt.bufPrint(&bg_buf, "--override=colors.background={s}", .{foot_bg})
    else
        "";

    var fg_buf: [64]u8 = undefined;
    const fg_arg: []const u8 = if (foot_fg.len > 0)
        try std.fmt.bufPrint(&fg_buf, "--override=colors.foreground={s}", .{foot_fg})
    else
        "";

    var border_color_buf: [64]u8 = undefined;
    const border_color_arg = if (foot_border.len > 0)
        try std.fmt.bufPrint(&border_color_buf, "--override=csd.border-color={s}", .{foot_border})
    else
        "";

    var env_w: [64]u8 = undefined;
    const env_w_arg = try std.fmt.bufPrint(&env_w, "EMOJIG_WIDTH={d}", .{width_val});

    var env_h: [64]u8 = undefined;
    const env_h_arg = try std.fmt.bufPrint(&env_h, "EMOJIG_HEIGHT={d}", .{gui_content_rows});

    var env_theme: [64]u8 = undefined;
    const env_theme_arg = try std.fmt.bufPrint(&env_theme, "EMOJIG_THEME={s}", .{theme_str});

    var env_effective_theme: [64]u8 = undefined;
    const env_effective_theme_arg = try std.fmt.bufPrint(&env_effective_theme, "EMOJIG_EFFECTIVE_THEME={s}", .{effective_theme_str});

    var env_border: [64]u8 = undefined;
    const env_border_arg = try std.fmt.bufPrint(&env_border, "EMOJIG_BORDER={s}", .{if (border) "1" else "0"});

    var env_safe: [64]u8 = undefined;
    const env_safe_arg = try std.fmt.bufPrint(&env_safe, "EMOJIG_SAFE={s}", .{if (safe) "1" else "0"});

    var env_debug: [64]u8 = undefined;
    const env_debug_arg = try std.fmt.bufPrint(&env_debug, "EMOJIG_DEBUG={s}", .{if (debug) "1" else "0"});

    const timeout_val = init.environ_map.get("EMOJIG_PICKER_TIMEOUT") orelse "60";

    var env_timeout: [64]u8 = undefined;
    const env_timeout_arg = try std.fmt.bufPrint(&env_timeout, "EMOJIG_PICKER_TIMEOUT={s}", .{timeout_val});

    var font_buf: [256]u8 = undefined;
    const font_arg = try std.fmt.bufPrint(
        &font_buf,
        "--override=font=monospace:size={d}, Noto Color Emoji:size={d}, Twitter Color Emoji:size={d}, Twemoji:size={d}, OpenMoji:size={d}, JoyPixels:size={d}",
        .{ font_size, font_size, font_size, font_size, font_size, font_size },
    );

    const effective_csd_size = if (title_size > 0) title_size else detectCsdSize(io, csd.size_fallback, csd.size_pt_factor);
    var csd_size_buf: [64]u8 = undefined;
    const csd_size_arg = if (!borderless)
        try std.fmt.bufPrint(&csd_size_buf, "--override=csd.size={d}", .{effective_csd_size})
    else
        "";

    var csd_title_font_buf: [64]u8 = undefined;
    // Bold title font; :size is ignored by foot for CSD (auto-scales to csd.size).
    const csd_title_font_arg = if (!borderless)
        try std.fmt.bufPrint(&csd_title_font_buf, "--override=csd.font=monospace{s}", .{if (csd.title_bold) ":bold" else ""})
    else
        "";

    var csd_color_buf: [48]u8 = undefined;
    const csd_color_arg = if (!borderless and title_hex_early.len == 6)
        try std.fmt.bufPrint(&csd_color_buf, "--override=csd.color=ff{s}", .{title_hex_early})
    else
        "";

    var env_cols: [64]u8 = undefined;
    const env_cols_arg = try std.fmt.bufPrint(&env_cols, "EMOJIG_COLS={d}", .{cols_val});

    var env_rows: [64]u8 = undefined;
    const env_rows_arg = try std.fmt.bufPrint(&env_rows, "EMOJIG_ROWS={d}", .{rows_val});

    // Propagate the GUI exit-preview default from spec/layout.yaml → animation.exit_preview_gui.
    // The child process (running --tui inside the spawned window) will see this env var and
    // use it as its override, bypassing the TUI default (animation.exit_preview_tui).
    var env_exit_preview: [64]u8 = undefined;
    const env_exit_preview_arg = try std.fmt.bufPrint(
        &env_exit_preview,
        "EMOJIG_EXIT_PREVIEW={s}",
        .{if (spec.layout.animation.exit_preview_gui) "1" else "0"},
    );

    const switcher_arg = if (show_switcher) "EMOJIG_SHOW_SWITCHER=1" else "EMOJIG_SHOW_SWITCHER=0";

    var env_compact: [64]u8 = undefined;
    const env_compact_arg = try std.fmt.bufPrint(&env_compact, "EMOJIG_COMPACT={s}", .{if (compact) "1" else "0"});

    // Terminal-independent tail: env VARS... exe_path --tui
    const tail = [_][]const u8{
        "env",
        env_w_arg,
        env_h_arg,
        env_theme_arg,
        env_effective_theme_arg,
        env_border_arg,
        env_safe_arg,
        env_debug_arg,
        env_timeout_arg,
        "EMOJIG_RESIZE_MODE=altscreen",
        env_cols_arg,
        env_rows_arg,
        env_exit_preview_arg,
        switcher_arg,
        "EMOJIG_GUI_SPAWNED=1",
        env_compact_arg,
        exe_path,
        "--tui",
    };

    // Select terminal host
    const sel = selectTerminalHost(init.environ_map) orelse {
        try writeAll(std.posix.STDERR_FILENO, "Error: no terminal emulator found. Set EMOJIG_TERMINAL to your terminal executable.\n");
        std.process.exit(1);
    };

    var argv_out: [MAX_ARGV][]const u8 = undefined;
    var arg_bufs: [MAX_ARGV][MAX_ARG_LEN]u8 = undefined;
    const argv = buildGuiArgv(&argv_out, &arg_bufs, sel.tspec, sel.exe, borderless, .{
        .title = spec.strings.gui_title,
        .size = size_arg,
        .font = font_arg,
        .bg = bg_arg,
        .fg = fg_arg,
        .border_color = border_color_arg,
        .csd_size = csd_size_arg,
        .csd_color = csd_color_arg,
        .csd_title_font = csd_title_font_arg,
    }, &tail);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    if (wait) {
        _ = try child.wait(io);
    }
}

fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, needle)) return true;
    }
    return false;
}

test "GUI child theme env uses concrete theme names" {
    try std.testing.expectEqualStrings("dark", concreteThemeString(.dark));
    try std.testing.expectEqualStrings("light", concreteThemeString(.light));
}

test "buildGuiArgv: foot borderless adds csd overrides" {
    var out: [MAX_ARGV][]const u8 = undefined;
    var bufs: [MAX_ARGV][MAX_ARG_LEN]u8 = undefined;
    const tail = [_][]const u8{ "env", "EMOJIG_WIDTH=25", "EMOJIG_RESIZE_MODE=altscreen", "/usr/bin/emojig", "--tui" };
    const argv = buildGuiArgv(&out, &bufs, terminalSpecFor("foot"), "foot", true, .{
        .title = "\xf0\x9f\x98\x80 Emojig",
        .size = "--window-size-chars=27x10",
        .font = "--override=font=monospace:size=14",
        .bg = "--override=colors.background=1c1c1c",
        .fg = "--override=colors.foreground=a8a8a8",
        .border_color = "--override=csd.border-color=3c3c3c",
    }, &tail);
    try std.testing.expectEqualStrings("foot", argv[0]);
    try std.testing.expectEqualStrings("--app-id=emojig-picker", argv[1]);
    try std.testing.expectEqualStrings("--override=title=\xf0\x9f\x98\x80 Emojig", argv[2]);
    try std.testing.expectEqualStrings("--window-size-chars=27x10", argv[3]);
    try std.testing.expect(argvContains(argv, "--override=csd.size=0"));
    try std.testing.expect(argvContains(argv, "--override=csd.preferred=client"));
    try std.testing.expect(argvContains(argv, "--override=csd.border-width=1"));
    try std.testing.expect(argvContains(argv, "--override=csd.border-color=3c3c3c"));
    try std.testing.expectEqualStrings("--tui", argv[argv.len - 1]);
}

test "buildGuiArgv: foot non-borderless uses csd client with explicit size" {
    var out: [MAX_ARGV][]const u8 = undefined;
    var bufs: [MAX_ARGV][MAX_ARG_LEN]u8 = undefined;
    const tail = [_][]const u8{ "env", "/usr/bin/emojig", "--tui" };
    const argv = buildGuiArgv(&out, &bufs, terminalSpecFor("foot"), "foot", false, .{
        .title = "Emojig",
        .size = "--window-size-chars=27x10",
        .font = "--override=font=monospace:size=14",
        .bg = "bg",
        .fg = "fg",
        .border_color = "border",
        .csd_size = "--override=csd.size=40",
        .csd_color = "--override=csd.color=ff3c3c3c",
        .csd_title_font = "--override=csd.font=monospace:bold",
    }, &tail);
    try std.testing.expect(!argvContains(argv, "--override=csd.size=0"));
    try std.testing.expect(argvContains(argv, "--override=csd.preferred=client"));
    try std.testing.expect(argvContains(argv, "--override=csd.size=40"));
    try std.testing.expect(argvContains(argv, "--override=csd.font=monospace:bold"));
}

test "buildGuiArgv: kitty borderless toggles hide_window_decorations" {
    var on_out: [MAX_ARGV][]const u8 = undefined;
    var off_out: [MAX_ARGV][]const u8 = undefined;
    var bufs: [MAX_ARGV][MAX_ARG_LEN]u8 = undefined;
    const tail = [_][]const u8{ "env", "/usr/bin/emojig", "--tui" };
    const on = buildGuiArgv(&on_out, &bufs, terminalSpecFor("kitty"), "kitty", true, .{}, &tail);
    try std.testing.expect(argvContains(on, "hide_window_decorations=titlebar-only"));
    const off = buildGuiArgv(&off_out, &bufs, terminalSpecFor("kitty"), "kitty", false, .{}, &tail);
    try std.testing.expect(!argvContains(off, "hide_window_decorations=titlebar-only"));
    try std.testing.expectEqualStrings("kitty", off[0]);
    try std.testing.expectEqualStrings("-e", off[3]);
}

test "buildGuiArgv: xterm argv starts with expected tokens" {
    var out: [MAX_ARGV][]const u8 = undefined;
    var bufs: [MAX_ARGV][MAX_ARG_LEN]u8 = undefined;
    const tail = [_][]const u8{ "env", "EMOJIG_WIDTH=25", "EMOJIG_RESIZE_MODE=altscreen", "/usr/bin/emojig", "--tui" };
    const argv = buildGuiArgv(&out, &bufs, terminalSpecFor("xterm"), "xterm", true, .{}, &tail);
    try std.testing.expect(argv.len >= 2);
    try std.testing.expectEqualStrings("xterm", argv[0]);
    try std.testing.expectEqualStrings("-class", argv[1]);
    try std.testing.expectEqualStrings("emojig", argv[2]);
    try std.testing.expectEqualStrings("-e", argv[3]);
    try std.testing.expectEqualStrings("env", argv[4]);
    try std.testing.expectEqualStrings("--tui", argv[argv.len - 1]);
}

test "buildGuiArgv: ptyxis uses -- separator" {
    var out: [MAX_ARGV][]const u8 = undefined;
    var bufs: [MAX_ARGV][MAX_ARG_LEN]u8 = undefined;
    const tail = [_][]const u8{ "env", "/bin/true", "--tui" };
    const argv = buildGuiArgv(&out, &bufs, terminalSpecFor("ptyxis"), "ptyxis", true, .{}, &tail);
    try std.testing.expectEqualStrings("ptyxis", argv[0]);
    try std.testing.expectEqualStrings("--", argv[1]);
    try std.testing.expectEqualStrings("env", argv[2]);
}

test "whichOnPath finds and rejects" {
    const path = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
    try std.testing.expect(whichOnPath(path, "sh"));
    try std.testing.expect(!whichOnPath(path, "zzz_no_such_binary_zzz"));
}

test "buildGuiArgv: generic argv uses -e" {
    var out: [MAX_ARGV][]const u8 = undefined;
    var bufs: [MAX_ARGV][MAX_ARG_LEN]u8 = undefined;
    const tail = [_][]const u8{ "env", "EMOJIG_RESIZE_MODE=altscreen", "/bin/true", "--tui" };
    const argv = buildGuiArgv(&out, &bufs, terminalSpecFor("zzz-unknown-term"), "/bin/true", true, .{}, &tail);
    try std.testing.expectEqualStrings("/bin/true", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    try std.testing.expectEqualStrings("env", argv[2]);
    try std.testing.expectEqualStrings("--tui", argv[argv.len - 1]);
}

test "host spec: detection list and all referenced terminals exist" {
    const hspec = getGlobalHostSpec();
    try std.testing.expect(hspec.detection.len > 0);
    try std.testing.expectEqualStrings("ptyxis", hspec.detection[0]);
    for (hspec.detection) |name| {
        // Every detection candidate must have a dedicated template (never
        // silently fall through to generic).
        try std.testing.expect(!std.mem.eql(u8, terminalSpecFor(name).name, "generic"));
    }
}

test "renderArg: placeholder substitution and drop semantics" {
    var buf: [MAX_ARG_LEN]u8 = undefined;
    // Literal entries pass through untouched.
    try std.testing.expectEqualStrings("-e", renderArg("-e", .{}, &buf).?);
    // Substitution composes prefix + value.
    try std.testing.expectEqualStrings(
        "--override=title=Emojig",
        renderArg("--override=title={title}", .{ .title = "Emojig" }, &buf).?,
    );
    // Empty value drops the whole entry.
    try std.testing.expect(renderArg("{size}", .{}, &buf) == null);
    // Unknown placeholder drops the entry (misspelled spec stays harmless).
    try std.testing.expect(renderArg("{no_such_value}", .{ .title = "x" }, &buf) == null);
}
