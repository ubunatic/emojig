// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Manual, on-demand canary for researching font *alignment* — glyph shape,
//! metrics, and subsequence positioning — independent of any terminal
//! emulator or compositor.
//!
//! Renders -text with -font via Cairo+Pango (dlopen'd libcairo /
//! libpango-1.0 / libpangocairo-1.0 — fontconfig+FreeType underneath, so
//! whichever font family is named decides vector (COLR/outline) vs bitmap
//! (CBDT) glyph rendering, transparently, exactly like a real desktop app)
//! straight into an offscreen image surface, and saves it as a PNG. No
//! Wayland window, no compositor, no screenshot tool: alignment is decided
//! entirely by Pango/Cairo/FreeType before anything is ever presented on
//! screen, so a compositor-level round trip (which only adds presentation
//! effects like fractional-scale upscaling or colour management — see
//! docs/EmojiWidthResearch.md) is irrelevant to the question this canary
//! answers and was dropped as unneeded complexity.
//!
//! Every render bakes a small metadata label into the image itself
//! (detected terminal emulator, $TERM, session type/desktop) so a PNG
//! saved or shared elsewhere still carries which host/terminal it came
//! from, and writes a companion `<out>.env.txt` with the fuller env dump.
//! `-unset=A,B,C` unsets specific env vars before rendering, to isolate
//! whether one of them (see the font-stack vars in the dump list) is
//! actually responsible for a difference.
//!
//! This isolates one variable at a time: is a font-alignment discrepancy
//! (e.g. issue 57's headless-canary-only VS16 width defect) a property of
//! foot, of the headless nested-sway/Xvfb capture harness, or of the font
//! stack itself? Run this on any host and compare.
//!
//! See also `scripts/canary_font/main.go` — same behavior, built with Go+cgo
//! instead of Zig+dlopen, so a discrepancy can be attributed to one
//! implementation's binding code rather than to the font stack itself.
//!
//! Usage: zig run scripts/canary_font.zig -lc -- [-font=NAME] [-text=STR] ...
//! Run `zig run scripts/canary_font.zig -lc -- -help` for the full flag list.
//! Not part of `make canary` — this is a manual research tool, see
//! docs/EmojiWidthResearch.md.

const std = @import("std");

// ---------------------------------------------------------------------------
// Cairo + Pango bindings (opaque-pointer C APIs — no struct-layout guessing)
// ---------------------------------------------------------------------------

const CairoLib = struct {
    cairo_h: *anyopaque,
    pango_h: *anyopaque,
    pangocairo_h: *anyopaque,

    image_surface_create_for_data: *const fn (data: [*]u8, format: c_int, width: c_int, height: c_int, stride: c_int) callconv(.c) ?*anyopaque,
    create: *const fn (surface: ?*anyopaque) callconv(.c) ?*anyopaque,
    destroy: *const fn (cr: ?*anyopaque) callconv(.c) void,
    surface_destroy: *const fn (surface: ?*anyopaque) callconv(.c) void,
    surface_flush: *const fn (surface: ?*anyopaque) callconv(.c) void,
    surface_write_to_png: *const fn (surface: ?*anyopaque, filename: [*:0]const u8) callconv(.c) c_int,
    set_source_rgb: *const fn (cr: ?*anyopaque, r: f64, g: f64, b: f64) callconv(.c) void,
    paint: *const fn (cr: ?*anyopaque) callconv(.c) void,
    move_to: *const fn (cr: ?*anyopaque, x: f64, y: f64) callconv(.c) void,

    font_description_new: *const fn () callconv(.c) ?*anyopaque,
    font_description_set_family: *const fn (desc: ?*anyopaque, family: [*:0]const u8) callconv(.c) void,
    font_description_set_absolute_size: *const fn (desc: ?*anyopaque, size: f64) callconv(.c) void,
    font_description_free: *const fn (desc: ?*anyopaque) callconv(.c) void,

    cairo_create_layout: *const fn (cr: ?*anyopaque) callconv(.c) ?*anyopaque,
    layout_set_font_description: *const fn (layout: ?*anyopaque, desc: ?*anyopaque) callconv(.c) void,
    layout_set_text: *const fn (layout: ?*anyopaque, text: [*]const u8, length: c_int) callconv(.c) void,
    layout_get_pixel_size: *const fn (layout: ?*anyopaque, width: *c_int, height: *c_int) callconv(.c) void,
    cairo_show_layout: *const fn (cr: ?*anyopaque, layout: ?*anyopaque) callconv(.c) void,

    fn sym(h: *anyopaque, name: [*:0]const u8) !*anyopaque {
        return std.c.dlsym(h, name) orelse return error.SymbolNotFound;
    }

    pub fn load() !CairoLib {
        const cairo_h = std.c.dlopen("libcairo.so.2", @bitCast(@as(u32, 1))) orelse return error.LibraryLoadFailed;
        const pango_h = std.c.dlopen("libpango-1.0.so.0", @bitCast(@as(u32, 1))) orelse return error.LibraryLoadFailed;
        const pangocairo_h = std.c.dlopen("libpangocairo-1.0.so.0", @bitCast(@as(u32, 1))) orelse return error.LibraryLoadFailed;
        return .{
            .cairo_h = cairo_h,
            .pango_h = pango_h,
            .pangocairo_h = pangocairo_h,
            .image_surface_create_for_data = @ptrCast(try sym(cairo_h, "cairo_image_surface_create_for_data")),
            .create = @ptrCast(try sym(cairo_h, "cairo_create")),
            .destroy = @ptrCast(try sym(cairo_h, "cairo_destroy")),
            .surface_destroy = @ptrCast(try sym(cairo_h, "cairo_surface_destroy")),
            .surface_flush = @ptrCast(try sym(cairo_h, "cairo_surface_flush")),
            .surface_write_to_png = @ptrCast(try sym(cairo_h, "cairo_surface_write_to_png")),
            .set_source_rgb = @ptrCast(try sym(cairo_h, "cairo_set_source_rgb")),
            .paint = @ptrCast(try sym(cairo_h, "cairo_paint")),
            .move_to = @ptrCast(try sym(cairo_h, "cairo_move_to")),
            .font_description_new = @ptrCast(try sym(pango_h, "pango_font_description_new")),
            .font_description_set_family = @ptrCast(try sym(pango_h, "pango_font_description_set_family")),
            .font_description_set_absolute_size = @ptrCast(try sym(pango_h, "pango_font_description_set_absolute_size")),
            .font_description_free = @ptrCast(try sym(pango_h, "pango_font_description_free")),
            .cairo_create_layout = @ptrCast(try sym(pangocairo_h, "pango_cairo_create_layout")),
            .layout_set_font_description = @ptrCast(try sym(pango_h, "pango_layout_set_font_description")),
            .layout_set_text = @ptrCast(try sym(pango_h, "pango_layout_set_text")),
            .layout_get_pixel_size = @ptrCast(try sym(pango_h, "pango_layout_get_pixel_size")),
            .cairo_show_layout = @ptrCast(try sym(pangocairo_h, "pango_cairo_show_layout")),
        };
    }
};

const CAIRO_FORMAT_ARGB32: c_int = 0;

// ---------------------------------------------------------------------------
// CLI + main
// ---------------------------------------------------------------------------

const Args = struct {
    font: []const u8 = "monospace",
    text: []const u8 = "abc ABC 123 \u{263a}\u{fe0f} \u{263a}\u{fe0e} \u{1f600} \u{1f680}",
    size_px: f64 = 48.0,
    pad: f64 = 16.0,
    bg: [3]f64 = .{ 0.12, 0.12, 0.14 },
    fg: [3]f64 = .{ 0.92, 0.92, 0.90 },
    out: ?[]const u8 = null,
    unset: []const u8 = "",
    help: bool = false,
};

// Not declared in std.c — call the libc symbol directly (same dlopen-free
// approach as any other libc function this file uses through std.c).
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Unsets each comma-separated name in `-unset=...` before any rendering
/// happens, so a run can isolate whether a specific font-stack env var
/// (fontconfig/FreeType/Pango — see docs/EmojiWidthResearch.md) is actually
/// responsible for an alignment difference, rather than guessing from
/// presence/absence alone.
fn applyUnset(alloc: std.mem.Allocator, spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const name_z = alloc.dupeZ(u8, name) catch continue;
        _ = unsetenv(name_z);
        std.debug.print("canary_font: unset {s}\n", .{name});
    }
}

fn hexToUnit(hex: []const u8) f64 {
    const v = std.fmt.parseInt(u16, hex, 16) catch return 0;
    return @as(f64, @floatFromInt(v)) / 255.0;
}

fn parseColor(hex6: []const u8) [3]f64 {
    if (hex6.len != 6) return .{ 0, 0, 0 };
    return .{ hexToUnit(hex6[0..2]), hexToUnit(hex6[2..4]), hexToUnit(hex6[4..6]) };
}

fn parseArgs(init: std.process.Init) Args {
    var a = Args{};
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-help") or std.mem.eql(u8, arg, "-h")) {
            a.help = true;
        } else if (std.mem.startsWith(u8, arg, "-font=")) {
            a.font = arg["-font=".len..];
        } else if (std.mem.startsWith(u8, arg, "-text=")) {
            a.text = arg["-text=".len..];
        } else if (std.mem.startsWith(u8, arg, "-size=")) {
            a.size_px = std.fmt.parseFloat(f64, arg["-size=".len..]) catch a.size_px;
        } else if (std.mem.startsWith(u8, arg, "-pad=")) {
            a.pad = std.fmt.parseFloat(f64, arg["-pad=".len..]) catch a.pad;
        } else if (std.mem.startsWith(u8, arg, "-bg=")) {
            a.bg = parseColor(arg["-bg=".len..]);
        } else if (std.mem.startsWith(u8, arg, "-fg=")) {
            a.fg = parseColor(arg["-fg=".len..]);
        } else if (std.mem.startsWith(u8, arg, "-out=")) {
            a.out = arg["-out=".len..];
        } else if (std.mem.startsWith(u8, arg, "-unset=")) {
            a.unset = arg["-unset=".len..];
        }
    }
    return a;
}

fn printHelp() void {
    std.debug.print(
        \\Usage: zig run scripts/canary_font.zig -lc -- [flags]
        \\
        \\Renders -text with -font (a Pango family name — fontconfig resolves it
        \\to a real installed font; vector families like "DejaVu Sans Mono" or
        \\"Noto Color Emoji" and bitmap/CBDT families like "Twemoji" both go
        \\through the same Cairo/Pango path, so the flag *is* the vector-vs-
        \\bitmap switch) into an offscreen image and saves it as a PNG — no
        \\Wayland window, no compositor, no screenshot tool, since alignment is
        \\decided entirely by Pango/Cairo/FreeType before presentation.
        \\Every render bakes a terminal/session label into the image and
        \\writes a companion <out>.env.txt env-var dump.
        \\
        \\  -font=NAME     Pango font family (default: monospace)
        \\  -text=STR      text/emoji to render (default: ASCII + smiling-face pair)
        \\  -size=PX       pixel font size (default: 48)
        \\  -pad=PX        padding around the text (default: 16)
        \\  -bg=RRGGBB     background hex color (default: 1e1e24)
        \\  -fg=RRGGBB     text hex color (default: eaeae6)
        \\  -out=PATH      output PNG path (default: scripts/canary_font/shots/<font>.png)
        \\  -unset=A,B,C   unset these env vars before rendering (e.g. to test
        \\                 whether FREETYPE_PROPERTIES/FONTCONFIG_FILE/etc. is
        \\                 responsible for an alignment difference)
        \\
        \\Manual/on-demand only — not part of `make canary`. See
        \\docs/EmojiWidthResearch.md.
        \\
    , .{});
}

fn sanitizeForFilename(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '-';
    }
    return out;
}

/// Runs `argv`, discarding stdout/stderr, and waits for exit. Best-effort:
/// only used for `mkdir -p`, so a failure just means the later file write
/// fails with its own clear error.
fn runIgnoring(io: anytype, argv: []const []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.debug.print("warn: failed to spawn {s}: {t}\n", .{ argv[0], err });
        return;
    };
    _ = child.wait(io) catch {};
}

/// Returns an env var's value, or "(unset)" — used for both the companion
/// dump and terminal-name detection, so a missing var is always visible
/// rather than silently absent from the record.
fn envOr(name: [*:0]const u8) []const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else "(unset)";
}

/// Best-effort terminal-emulator label from the env vars each emulator is
/// known to set (checked in roughly "most specific first" order so e.g.
/// TILIX_ID wins over the generic VTE_VERSION every VTE-based terminal
/// sets). Falls back to $TERM, then "unknown" — this is a research label
/// for comparing renders across hosts/terminals, not a detection mechanism
/// anything else in emojig depends on.
fn detectTerminalName() []const u8 {
    if (std.c.getenv("TILIX_ID") != null) return "tilix";
    if (std.c.getenv("KONSOLE_VERSION") != null) return "konsole";
    if (std.c.getenv("GNOME_TERMINAL_SCREEN") != null or std.c.getenv("GNOME_TERMINAL_SERVICE") != null) return "gnome-terminal";
    if (std.c.getenv("WEZTERM_EXECUTABLE") != null or std.c.getenv("WEZTERM_PANE") != null) return "wezterm";
    if (std.c.getenv("KITTY_WINDOW_ID") != null) return "kitty";
    if (std.c.getenv("ALACRITTY_SOCKET") != null or std.c.getenv("ALACRITTY_LOG") != null) return "alacritty";
    if (std.c.getenv("GHOSTTY_RESOURCES_DIR") != null) return "ghostty";
    if (std.c.getenv("VTE_VERSION") != null) return "vte-based";
    if (std.c.getenv("TERM_PROGRAM")) |tp| return std.mem.span(tp);
    if (std.c.getenv("TERM")) |t| return std.mem.span(t);
    return "unknown";
}

/// Writes a companion text file next to the PNG recording the env vars
/// most likely to matter when comparing renders across hosts/terminals
/// later — the whole point of this canary is host-to-host comparison, and
/// a bare PNG filename doesn't carry that context on its own.
fn writeEnvDump(io: std.Io, alloc: std.mem.Allocator, out_path: []const u8, args: Args, terminal_name: []const u8) !void {
    const dump_path = if (std.mem.endsWith(u8, out_path, ".png"))
        try std.fmt.allocPrint(alloc, "{s}.env.txt", .{out_path[0 .. out_path.len - 4]})
    else
        try std.fmt.allocPrint(alloc, "{s}.env.txt", .{out_path});

    const body = try std.fmt.allocPrint(alloc,
        \\# canary_font companion env dump
        \\terminal={s}
        \\font={s}
        \\text={s}
        \\size_px={d}
        \\TERM={s}
        \\TERM_PROGRAM={s}
        \\WAYLAND_DISPLAY={s}
        \\DISPLAY={s}
        \\XDG_SESSION_TYPE={s}
        \\XDG_CURRENT_DESKTOP={s}
        \\DESKTOP_SESSION={s}
        \\SWAYSOCK={s}
        \\GDK_BACKEND={s}
        \\QT_QPA_PLATFORM={s}
        \\LANG={s}
        \\LC_ALL={s}
        \\FREETYPE_PROPERTIES={s}
        \\FONTCONFIG_PATH={s}
        \\FONTCONFIG_FILE={s}
        \\FONTCONFIG_SYSROOT={s}
        \\FC_LANG={s}
        \\PANGOCAIRO_BACKEND={s}
        \\VTE_VERSION={s}
        \\TILIX_ID={s}
        \\KONSOLE_VERSION={s}
        \\WEZTERM_EXECUTABLE={s}
        \\KITTY_WINDOW_ID={s}
        \\ALACRITTY_SOCKET={s}
        \\GHOSTTY_RESOURCES_DIR={s}
        \\GNOME_TERMINAL_SCREEN={s}
        \\
    , .{
        terminal_name,
        args.font,
        args.text,
        args.size_px,
        envOr("TERM"),
        envOr("TERM_PROGRAM"),
        envOr("WAYLAND_DISPLAY"),
        envOr("DISPLAY"),
        envOr("XDG_SESSION_TYPE"),
        envOr("XDG_CURRENT_DESKTOP"),
        envOr("DESKTOP_SESSION"),
        envOr("SWAYSOCK"),
        envOr("GDK_BACKEND"),
        envOr("QT_QPA_PLATFORM"),
        envOr("LANG"),
        envOr("LC_ALL"),
        envOr("FREETYPE_PROPERTIES"),
        envOr("FONTCONFIG_PATH"),
        envOr("FONTCONFIG_FILE"),
        envOr("FONTCONFIG_SYSROOT"),
        envOr("FC_LANG"),
        envOr("PANGOCAIRO_BACKEND"),
        envOr("VTE_VERSION"),
        envOr("TILIX_ID"),
        envOr("KONSOLE_VERSION"),
        envOr("WEZTERM_EXECUTABLE"),
        envOr("KITTY_WINDOW_ID"),
        envOr("ALACRITTY_SOCKET"),
        envOr("GHOSTTY_RESOURCES_DIR"),
        envOr("GNOME_TERMINAL_SCREEN"),
    });
    const f = try std.Io.Dir.cwd().createFile(io, dump_path, .{});
    _ = try f.writePositionalAll(io, body, 0);
    f.close(io);
    std.debug.print("canary_font: saved {s}\n", .{dump_path});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = parseArgs(init);
    if (args.help) {
        printHelp();
        return;
    }

    const out_path = args.out orelse blk: {
        const safe_font = try sanitizeForFilename(alloc, args.font);
        break :blk try std.fmt.allocPrint(alloc, "scripts/canary_font/shots/{s}.png", .{safe_font});
    };
    // The one and only std.process.spawn in this program must run *before*
    // -unset: Zig 0.16's spawn path builds the child's env block from its
    // own cached view of `environ` (`Io.Threaded.environ`), which is a
    // separate copy from libc's — calling libc's `unsetenv()` (below)
    // mutates libc's copy only, desyncing the two, and a later spawn then
    // segfaults reading dangling pointers into memory glibc already freed.
    runIgnoring(io, &[_][]const u8{ "mkdir", "-p", std.fs.path.dirname(out_path) orelse "." });

    // Also run before -unset for a related but separate reason:
    // std.debug.print lazily scans `environ` on its *first* call, to
    // locate self debug-info search paths for pretty stack traces — and
    // that scan panics if certain env vars are absent (e.g. LANG), which
    // then deadlocks trying to print the panic itself (the panic handler
    // recurses into the same lazy-init path and self-deadlocks on its own
    // mutex). Unlike the spawn issue above, this one warm-up call *does*
    // make every later debug.print call safe too — see
    // issues/58-zig-unsetenv-environ-desync.md and
    // scripts/zig_unsetenv_bug_repro.zig for both failure modes isolated
    // with zero application code, and proof neither has a priming
    // workaround for spawn specifically.
    std.debug.print("", .{});
    applyUnset(alloc, args.unset);

    // Baked into the image itself (not just the filename) so a PNG
    // saved/renamed/shared elsewhere still carries which terminal emulator
    // and desktop session it came from — the whole point of this canary is
    // comparing renders across hosts, and a bare PNG carries none of that
    // context on its own.
    const terminal_name = detectTerminalName();
    const label_text = try std.fmt.allocPrint(alloc, "term={s}  TERM={s}  session={s}/{s}", .{
        terminal_name, envOr("TERM"), envOr("XDG_SESSION_TYPE"), envOr("XDG_CURRENT_DESKTOP"),
    });
    try writeEnvDump(io, alloc, out_path, args, terminal_name);

    var cairo = try CairoLib.load();

    // Measure the text and the label (against a tiny scratch surface) so
    // the real image is sized exactly to its content plus padding — a
    // pre-cropped PNG rather than a fixed canvas with stray blank margins.
    var scratch_pixels: [4]u8 = undefined;
    const scratch_surface = cairo.image_surface_create_for_data(&scratch_pixels, CAIRO_FORMAT_ARGB32, 1, 1, 4) orelse return error.CairoSurfaceFailed;
    const scratch_cr = cairo.create(scratch_surface) orelse return error.CairoContextFailed;
    const font_desc = cairo.font_description_new() orelse return error.PangoFontDescFailed;
    const font_family_z = try alloc.dupeZ(u8, args.font);
    cairo.font_description_set_family(font_desc, font_family_z);
    cairo.font_description_set_absolute_size(font_desc, args.size_px * 1024.0);
    const scratch_layout = cairo.cairo_create_layout(scratch_cr) orelse return error.PangoLayoutFailed;
    cairo.layout_set_font_description(scratch_layout, font_desc);
    cairo.layout_set_text(scratch_layout, args.text.ptr, @intCast(args.text.len));
    var text_w: c_int = 0;
    var text_h: c_int = 0;
    cairo.layout_get_pixel_size(scratch_layout, &text_w, &text_h);

    // Label uses a plain system font (not -font) at a small fixed size —
    // it's metadata chrome, not part of the thing being measured.
    const label_size_px = 13.0;
    const label_desc = cairo.font_description_new() orelse return error.PangoFontDescFailed;
    cairo.font_description_set_family(label_desc, "sans-serif");
    cairo.font_description_set_absolute_size(label_desc, label_size_px * 1024.0);
    const scratch_label_layout = cairo.cairo_create_layout(scratch_cr) orelse return error.PangoLayoutFailed;
    cairo.layout_set_font_description(scratch_label_layout, label_desc);
    cairo.layout_set_text(scratch_label_layout, label_text.ptr, @intCast(label_text.len));
    var label_w: c_int = 0;
    var label_h: c_int = 0;
    cairo.layout_get_pixel_size(scratch_label_layout, &label_w, &label_h);

    cairo.destroy(scratch_cr);
    cairo.surface_destroy(scratch_surface);

    const label_gap: i32 = 6;
    const pad_i: i32 = @intFromFloat(args.pad);
    const width: i32 = @max(text_w, label_w) + pad_i * 2;
    const height: i32 = text_h + label_gap + label_h + pad_i * 2;
    std.debug.print("canary_font: measured text {d}x{d}px, label {d}x{d}px, image {d}x{d}px, font={s}, terminal={s}\n", .{ text_w, text_h, label_w, label_h, width, height, args.font, terminal_name });

    const stride: i32 = width * 4;
    const size: usize = @intCast(stride * height);
    const pixels = try alloc.alloc(u8, size);

    const real_surface = cairo.image_surface_create_for_data(pixels.ptr, CAIRO_FORMAT_ARGB32, width, height, stride) orelse return error.CairoSurfaceFailed;
    const real_cr = cairo.create(real_surface) orelse return error.CairoContextFailed;
    cairo.set_source_rgb(real_cr, args.bg[0], args.bg[1], args.bg[2]);
    cairo.paint(real_cr);
    cairo.set_source_rgb(real_cr, args.fg[0], args.fg[1], args.fg[2]);
    cairo.move_to(real_cr, args.pad, args.pad);
    const real_layout = cairo.cairo_create_layout(real_cr) orelse return error.PangoLayoutFailed;
    cairo.layout_set_font_description(real_layout, font_desc);
    cairo.layout_set_text(real_layout, args.text.ptr, @intCast(args.text.len));
    cairo.cairo_show_layout(real_cr, real_layout);

    // Dimmer than the main text so it reads as metadata, not content.
    cairo.set_source_rgb(real_cr, args.fg[0] * 0.55, args.fg[1] * 0.55, args.fg[2] * 0.55);
    cairo.move_to(real_cr, args.pad, args.pad + @as(f64, @floatFromInt(text_h)) + @as(f64, @floatFromInt(label_gap)));
    const real_label_layout = cairo.cairo_create_layout(real_cr) orelse return error.PangoLayoutFailed;
    cairo.layout_set_font_description(real_label_layout, label_desc);
    cairo.layout_set_text(real_label_layout, label_text.ptr, @intCast(label_text.len));
    cairo.cairo_show_layout(real_cr, real_label_layout);

    cairo.surface_flush(real_surface);
    cairo.destroy(real_cr);

    const out_path_z = try alloc.dupeZ(u8, out_path);
    _ = cairo.surface_write_to_png(real_surface, out_path_z);
    cairo.surface_destroy(real_surface);
    cairo.font_description_free(font_desc);
    cairo.font_description_free(label_desc);

    std.debug.print("canary_font: saved {s}\n", .{out_path});
}
