// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Manual, on-demand canary for researching font rendering on the *real*
//! desktop compositor — no wayreel, no nested sway, no Xvfb.
//!
//! It opens a native Wayland surface directly on the developer's own real
//! compositor session (dlopen'd libwayland-client, same pattern as
//! canary_gui.zig), renders a line of text into it via Cairo+Pango
//! (dlopen'd libcairo / libpango-1.0 / libpangocairo-1.0 — fontconfig+
//! FreeType underneath, so whichever font family is named decides vector
//! (COLR/outline) vs bitmap (CBDT) glyph rendering, transparently, exactly
//! like a real desktop app), then shoots *only its own window* and saves a
//! pre-cropped PNG. Two capture tiers, chosen automatically:
//!   - sway/wlroots (SWAYSOCK set): `swaymsg -t get_tree` locates the
//!     window by app-id, `grim -g` shoots exactly that rect.
//!   - GNOME/Mutter (no wlr-screencopy, so grim can't talk to it):
//!     `org.gnome.Shell.Screenshot.ScreenshotWindow` over D-Bus shoots
//!     whichever window currently has focus. Must be run from the real
//!     logged-in session — a sandboxed/CI D-Bus connection gets
//!     AccessDenied, which is fine, since this canary is manual/on-host use
//!     only.
//! If neither works, it falls back to dumping its own pre-composite SHM
//! buffer, clearly labeled — that dump proves nothing about compositor-
//! level rendering, only about the Cairo/Pango/fontconfig stack itself.
//!
//! This isolates one variable at a time: is a font-rendering discrepancy
//! (e.g. issue 57's headless-canary-only VS16 width defect) a property of
//! foot, of the headless nested-sway/Xvfb capture harness, or of the real
//! desktop's font stack? Run this against the real compositor and compare.
//!
//! Usage: zig run scripts/canary_font.zig -lc -- [-font=NAME] [-text=STR] ...
//! Run `zig run scripts/canary_font.zig -lc -- -help` for the full flag list.
//! Not part of `make canary` — this is a manual research tool, see
//! docs/EmojiWidthResearch.md.

const std = @import("std");
const posix = std.posix;

// ---------------------------------------------------------------------------
// Wayland client bindings (subset; mirrors scripts/canary_gui.zig)
// ---------------------------------------------------------------------------

pub const WlArgument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: ?[*:0]const u8,
    o: ?*anyopaque,
    n: u32,
    a: ?*anyopaque,
    h: i32,
};

pub const WlMessage = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const WlInterface,
};

pub const WlInterface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: [*]const WlMessage,
    event_count: c_int,
    events: [*]const WlMessage,
};

pub const WaylandLib = struct {
    handle: *anyopaque,

    wl_display_connect: *const fn (name: ?[*:0]const u8) callconv(.c) ?*anyopaque,
    wl_display_disconnect: *const fn (display: *anyopaque) callconv(.c) void,
    wl_display_dispatch: *const fn (display: *anyopaque) callconv(.c) c_int,
    wl_display_roundtrip: *const fn (display: *anyopaque) callconv(.c) c_int,
    wl_display_flush: *const fn (display: *anyopaque) callconv(.c) c_int,
    wl_display_get_fd: *const fn (display: *anyopaque) callconv(.c) c_int,
    wl_proxy_marshal_array_constructor_versioned: *const fn (proxy: *anyopaque, opcode: u32, args: [*]const WlArgument, interface: ?*const WlInterface, version: u32) callconv(.c) ?*anyopaque,
    wl_proxy_marshal_flags: *const fn (proxy: *anyopaque, opcode: u32, interface: ?*const WlInterface, version: u32, flags: u32, ...) callconv(.c) ?*anyopaque,
    wl_proxy_add_listener: *const fn (proxy: *anyopaque, implementation: ?*const fn () callconv(.c) void, data: ?*anyopaque) callconv(.c) c_int,
    wl_display_interface: *const WlInterface,
    wl_registry_interface: *const WlInterface,
    wl_compositor_interface: *const WlInterface,
    wl_shm_interface: *const WlInterface,
    wl_shm_pool_interface: *const WlInterface,
    wl_buffer_interface: *const WlInterface,
    wl_surface_interface: *const WlInterface,

    pub fn load() !WaylandLib {
        const h = std.c.dlopen("libwayland-client.so.0", @bitCast(@as(u32, 1))) orelse return error.LibraryLoadFailed;
        return .{
            .handle = h,
            .wl_display_connect = @ptrCast(std.c.dlsym(h, "wl_display_connect") orelse return error.SymbolNotFound),
            .wl_display_disconnect = @ptrCast(std.c.dlsym(h, "wl_display_disconnect") orelse return error.SymbolNotFound),
            .wl_display_dispatch = @ptrCast(std.c.dlsym(h, "wl_display_dispatch") orelse return error.SymbolNotFound),
            .wl_display_roundtrip = @ptrCast(std.c.dlsym(h, "wl_display_roundtrip") orelse return error.SymbolNotFound),
            .wl_display_flush = @ptrCast(std.c.dlsym(h, "wl_display_flush") orelse return error.SymbolNotFound),
            .wl_display_get_fd = @ptrCast(std.c.dlsym(h, "wl_display_get_fd") orelse return error.SymbolNotFound),
            .wl_proxy_marshal_array_constructor_versioned = @ptrCast(std.c.dlsym(h, "wl_proxy_marshal_array_constructor_versioned") orelse return error.SymbolNotFound),
            .wl_proxy_marshal_flags = @ptrCast(std.c.dlsym(h, "wl_proxy_marshal_flags") orelse return error.SymbolNotFound),
            .wl_proxy_add_listener = @ptrCast(std.c.dlsym(h, "wl_proxy_add_listener") orelse return error.SymbolNotFound),
            .wl_display_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_display_interface") orelse return error.SymbolNotFound)),
            .wl_registry_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_registry_interface") orelse return error.SymbolNotFound)),
            .wl_compositor_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_compositor_interface") orelse return error.SymbolNotFound)),
            .wl_shm_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_shm_interface") orelse return error.SymbolNotFound)),
            .wl_shm_pool_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_shm_pool_interface") orelse return error.SymbolNotFound)),
            .wl_buffer_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_buffer_interface") orelse return error.SymbolNotFound)),
            .wl_surface_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_surface_interface") orelse return error.SymbolNotFound)),
        };
    }

    pub fn unload(self: *WaylandLib) void {
        _ = std.c.dlclose(self.handle);
    }
};

pub const xdg_wm_base_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = &[_]?*const WlInterface{} },
    .{ .name = "create_positioner", .signature = "n", .types = &[_]?*const WlInterface{null} },
    .{ .name = "get_xdg_surface", .signature = "no", .types = &[_]?*const WlInterface{ null, null } },
    .{ .name = "pong", .signature = "u", .types = &[_]?*const WlInterface{null} },
};
pub const xdg_wm_base_events = [_]WlMessage{
    .{ .name = "ping", .signature = "u", .types = &[_]?*const WlInterface{null} },
};
pub const xdg_wm_base_interface = WlInterface{
    .name = "xdg_wm_base",
    .version = 6,
    .method_count = 4,
    .methods = &xdg_wm_base_requests,
    .event_count = 1,
    .events = &xdg_wm_base_events,
};

pub const xdg_surface_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = &[_]?*const WlInterface{} },
    .{ .name = "get_toplevel", .signature = "n", .types = &[_]?*const WlInterface{null} },
    .{ .name = "get_popup", .signature = "n?oo", .types = &[_]?*const WlInterface{ null, null, null } },
    .{ .name = "set_window_geometry", .signature = "iiii", .types = &[_]?*const WlInterface{ null, null, null, null } },
    .{ .name = "ack_configure", .signature = "u", .types = &[_]?*const WlInterface{null} },
};
pub const xdg_surface_events = [_]WlMessage{
    .{ .name = "configure", .signature = "u", .types = &[_]?*const WlInterface{null} },
};
pub const xdg_surface_interface = WlInterface{
    .name = "xdg_surface",
    .version = 6,
    .method_count = 5,
    .methods = &xdg_surface_requests,
    .event_count = 1,
    .events = &xdg_surface_events,
};

pub const xdg_toplevel_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = &[_]?*const WlInterface{} },
    .{ .name = "set_parent", .signature = "?o", .types = &[_]?*const WlInterface{null} },
    .{ .name = "set_title", .signature = "s", .types = &[_]?*const WlInterface{null} },
    .{ .name = "set_app_id", .signature = "s", .types = &[_]?*const WlInterface{null} },
    .{ .name = "show_window_menu", .signature = "ouii", .types = &[_]?*const WlInterface{ null, null, null, null } },
    .{ .name = "move", .signature = "ou", .types = &[_]?*const WlInterface{ null, null } },
    .{ .name = "resize", .signature = "ouu", .types = &[_]?*const WlInterface{ null, null, null } },
    .{ .name = "set_max_size", .signature = "ii", .types = &[_]?*const WlInterface{ null, null } },
    .{ .name = "set_min_size", .signature = "ii", .types = &[_]?*const WlInterface{ null, null } },
    .{ .name = "set_maximized", .signature = "", .types = &[_]?*const WlInterface{} },
    .{ .name = "unset_maximized", .signature = "", .types = &[_]?*const WlInterface{} },
    .{ .name = "set_fullscreen", .signature = "?o", .types = &[_]?*const WlInterface{null} },
    .{ .name = "unset_fullscreen", .signature = "", .types = &[_]?*const WlInterface{} },
    .{ .name = "set_minimized", .signature = "", .types = &[_]?*const WlInterface{} },
};
pub const xdg_toplevel_events = [_]WlMessage{
    .{ .name = "configure", .signature = "iia", .types = &[_]?*const WlInterface{ null, null, null } },
    .{ .name = "close", .signature = "", .types = &[_]?*const WlInterface{} },
    .{ .name = "configure_bounds", .signature = "4ii", .types = &[_]?*const WlInterface{ null, null } },
    .{ .name = "wm_capabilities", .signature = "5a", .types = &[_]?*const WlInterface{null} },
};
pub const xdg_toplevel_interface = WlInterface{
    .name = "xdg_toplevel",
    .version = 6,
    .method_count = 14,
    .methods = &xdg_toplevel_requests,
    .event_count = 4,
    .events = &xdg_toplevel_events,
};

var g_compositor: ?*anyopaque = null;
var g_shm: ?*anyopaque = null;
var g_xdg_wm_base: ?*anyopaque = null;

fn registryHandleGlobal(data: ?*anyopaque, reg: ?*anyopaque, name: u32, interface_ptr: [*:0]const u8, version: u32) callconv(.c) void {
    const wl_ptr: *WaylandLib = @ptrCast(@alignCast(data orelse return));
    const iface_name = std.mem.span(interface_ptr);
    const ver: u32 = @min(version, 4);
    const null_ptr: ?*anyopaque = null;

    if (std.mem.eql(u8, iface_name, "wl_compositor")) {
        g_compositor = wl_ptr.wl_proxy_marshal_flags(reg orelse return, 0, wl_ptr.wl_compositor_interface, ver, 0, name, wl_ptr.wl_compositor_interface.name, ver, null_ptr);
    } else if (std.mem.eql(u8, iface_name, "wl_shm")) {
        g_shm = wl_ptr.wl_proxy_marshal_flags(reg orelse return, 0, wl_ptr.wl_shm_interface, 1, 0, name, wl_ptr.wl_shm_interface.name, @as(u32, 1), null_ptr);
    } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
        const xdg_ver: u32 = @min(version, 6);
        const args = [_]WlArgument{
            .{ .u = name },
            .{ .s = xdg_wm_base_interface.name },
            .{ .u = xdg_ver },
            .{ .o = null },
        };
        g_xdg_wm_base = wl_ptr.wl_proxy_marshal_array_constructor_versioned(reg orelse return, 0, @ptrCast(&args), &xdg_wm_base_interface, xdg_ver);
    }
}

fn registryHandleGlobalRemove(data: ?*anyopaque, reg: ?*anyopaque, name: u32) callconv(.c) void {
    _ = data;
    _ = reg;
    _ = name;
}

const registry_listener = [2]*const fn () callconv(.c) void{
    @ptrCast(&registryHandleGlobal),
    @ptrCast(&registryHandleGlobalRemove),
};

// xdg_surface only has one event (configure); ack it and, on the *first*
// occurrence, attach+commit the pre-rendered buffer (xdg-shell forbids
// attaching a buffer before the surface has been configured at least once).
var g_wl: *WaylandLib = undefined;
var g_display: *anyopaque = undefined;
var g_surface: *anyopaque = undefined;
var g_buffer: *anyopaque = undefined;
var g_committed_content = false;

fn xdgSurfaceHandleConfigure(data: ?*anyopaque, xdg_surface: ?*anyopaque, serial: u32) callconv(.c) void {
    _ = data;
    const xs = xdg_surface orelse return;
    _ = g_wl.wl_proxy_marshal_flags(xs, 4, null, 1, 0, serial); // ack_configure
    if (!g_committed_content) {
        _ = g_wl.wl_proxy_marshal_flags(g_surface, 1, null, 1, 0, g_buffer, @as(i32, 0), @as(i32, 0)); // attach
        _ = g_wl.wl_proxy_marshal_flags(g_surface, 6, null, 1, 0); // commit
        _ = g_wl.wl_display_flush(g_display);
        g_committed_content = true;
    }
}

const xdg_surface_listener = [1]*const fn () callconv(.c) void{
    @ptrCast(&xdgSurfaceHandleConfigure),
};

fn toplevelNoop0() callconv(.c) void {}
const xdg_toplevel_listener = [4]*const fn () callconv(.c) void{
    @ptrCast(&toplevelNoop0),
    @ptrCast(&toplevelNoop0),
    @ptrCast(&toplevelNoop0),
    @ptrCast(&toplevelNoop0),
};

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
    app_id: []const u8 = "emojig-font-canary",
    out: ?[]const u8 = null,
    help: bool = false,
};

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
        } else if (std.mem.startsWith(u8, arg, "-app-id=")) {
            a.app_id = arg["-app-id=".len..];
        } else if (std.mem.startsWith(u8, arg, "-out=")) {
            a.out = arg["-out=".len..];
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
        \\bitmap switch) into a real on-screen Wayland window on the current
        \\desktop session, screenshots only that window (sway: swaymsg+grim;
        \\GNOME/Mutter: org.gnome.Shell.Screenshot D-Bus), and saves a
        \\pre-cropped PNG.
        \\
        \\  -font=NAME     Pango font family (default: monospace)
        \\  -text=STR      text/emoji to render (default: ASCII + smiling-face pair)
        \\  -size=PX       pixel font size (default: 48)
        \\  -pad=PX        padding around the text (default: 16)
        \\  -bg=RRGGBB     background hex color (default: 1e1e24)
        \\  -fg=RRGGBB     text hex color (default: eaeae6)
        \\  -app-id=ID     sway app_id for the window (default: emojig-font-canary)
        \\  -out=PATH      output PNG path (default: scripts/canary_font/shots/<font>.png)
        \\
        \\Manual/on-demand only — not part of `make canary`. Must be run from
        \\your real logged-in desktop session (sandboxed/CI shells can't reach
        \\the compositor's screenshot mechanism). See docs/EmojiWidthResearch.md.
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
/// errors are reported but never abort the canary (sway/swaymsg absence is
/// reported once, clearly, by the caller instead).
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

/// Runs `argv` and returns its captured stdout (arena-allocated).
fn runCapturing(io: anytype, alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    const pipe_rc = std.os.linux.pipe2(&pipe_fds, .{});
    if (std.posix.errno(pipe_rc) != .SUCCESS) return error.PipeFailed;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    });
    _ = std.posix.system.close(pipe_fds[1]);

    var list = std.array_list.Managed(u8).init(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(pipe_fds[0], &buf) catch break;
        if (n == 0) break;
        try list.appendSlice(buf[0..n]);
    }
    _ = std.posix.system.close(pipe_fds[0]);
    _ = child.wait(io) catch {};
    return try list.toOwnedSlice();
}

const Rect = struct { x: i64, y: i64, w: i64, h: i64 };

/// Recursively walks a sway `get_tree` JSON value looking for the node whose
/// "app_id" equals `target`, returning its "rect" ({x,y,width,height}).
fn findWindowRect(value: std.json.Value, target: []const u8) ?Rect {
    switch (value) {
        .object => |obj| {
            if (obj.get("app_id")) |app_id_val| {
                if (app_id_val == .string and std.mem.eql(u8, app_id_val.string, target)) {
                    if (obj.get("rect")) |rect_val| {
                        if (rect_val == .object) {
                            const r = rect_val.object;
                            return Rect{
                                .x = intOf(r.get("x")),
                                .y = intOf(r.get("y")),
                                .w = intOf(r.get("width")),
                                .h = intOf(r.get("height")),
                            };
                        }
                    }
                }
            }
            if (obj.get("nodes")) |nodes| {
                if (findWindowRect(nodes, target)) |r| return r;
            }
            if (obj.get("floating_nodes")) |nodes| {
                if (findWindowRect(nodes, target)) |r| return r;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findWindowRect(item, target)) |r| return r;
            }
        },
        else => {},
    }
    return null;
}

fn intOf(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => val.integer,
        .float => @intFromFloat(val.float),
        else => 0,
    };
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
    runIgnoring(io, &[_][]const u8{ "mkdir", "-p", std.fs.path.dirname(out_path) orelse "." });

    var cairo = try CairoLib.load();

    // Measure the text first (against a tiny scratch surface) so the real
    // window is sized exactly to its content plus padding — a pre-cropped
    // capture rather than a fixed pane with stray blank margins.
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
    cairo.destroy(scratch_cr);
    cairo.surface_destroy(scratch_surface);

    const width: i32 = text_w + @as(i32, @intFromFloat(args.pad * 2));
    const height: i32 = text_h + @as(i32, @intFromFloat(args.pad * 2));
    std.debug.print("canary_font: measured text {d}x{d}px, window {d}x{d}px, font={s}\n", .{ text_w, text_h, width, height, args.font });

    // Ensure our window gets no sway-drawn border/titlebar, so the swaymsg
    // "rect" below is exactly our own client-surface pixel content.
    const criteria = try std.fmt.allocPrint(alloc, "for_window [app_id=\"^{s}$\"] border none, floating enable", .{args.app_id});
    runIgnoring(io, &[_][]const u8{ "swaymsg", criteria });

    var wl = try WaylandLib.load();
    defer wl.unload();
    g_wl = &wl;

    const display = wl.wl_display_connect(null) orelse return error.DisplayConnectFailed;
    defer wl.wl_display_disconnect(display);
    g_display = display;

    const null_ptr: ?*anyopaque = null;
    const registry = wl.wl_proxy_marshal_flags(display, 1, wl.wl_registry_interface, 1, 0, null_ptr) orelse return error.RegistryFailed;
    _ = wl.wl_proxy_add_listener(registry, @ptrCast(&registry_listener[0]), &wl);
    _ = wl.wl_display_roundtrip(display);

    if (g_compositor == null or g_shm == null or g_xdg_wm_base == null) {
        return error.RequiredGlobalsMissing;
    }

    const surface = wl.wl_proxy_marshal_flags(g_compositor.?, 0, wl.wl_surface_interface, 1, 0, null_ptr) orelse return error.SurfaceFailed;
    g_surface = surface;

    const xdg_surf_args = [_]WlArgument{ .{ .o = null }, .{ .o = surface } };
    const xdg_surface = wl.wl_proxy_marshal_array_constructor_versioned(g_xdg_wm_base.?, 2, @ptrCast(&xdg_surf_args), &xdg_surface_interface, 1) orelse return error.XdgSurfaceFailed;
    _ = wl.wl_proxy_add_listener(xdg_surface, @ptrCast(&xdg_surface_listener[0]), null);

    const xdg_top_args = [_]WlArgument{.{ .o = null }};
    const xdg_toplevel = wl.wl_proxy_marshal_array_constructor_versioned(xdg_surface, 1, @ptrCast(&xdg_top_args), &xdg_toplevel_interface, 1) orelse return error.XdgToplevelFailed;
    _ = wl.wl_proxy_add_listener(xdg_toplevel, @ptrCast(&xdg_toplevel_listener[0]), null);

    const app_id_z = try alloc.dupeZ(u8, args.app_id);
    _ = wl.wl_proxy_marshal_flags(xdg_toplevel, 3, null, 1, 0, @as([*:0]const u8, app_id_z)); // set_app_id
    const title_z = try alloc.dupeZ(u8, "emojig font canary");
    _ = wl.wl_proxy_marshal_flags(xdg_toplevel, 2, null, 1, 0, @as([*:0]const u8, title_z)); // set_title

    // Null commit — required before the compositor will send the first
    // xdg_surface.configure event (xdg-shell forbids an initial buffer).
    _ = wl.wl_proxy_marshal_flags(surface, 6, null, 1, 0);
    _ = wl.wl_display_flush(display);

    // Allocate + render the SHM buffer *before* the configure round-trip so
    // the callback can attach it the instant it's safe to.
    const stride: i32 = width * 4;
    const size: usize = @intCast(stride * height);
    const shm_name = "/emojig-font-canary-shm";
    const oflags: u32 = @bitCast(posix.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
    const fd = std.c.shm_open(shm_name, @intCast(oflags), 0o600);
    if (fd < 0) return error.ShmOpenFailed;
    _ = std.c.shm_unlink(shm_name);
    defer _ = posix.system.close(fd);
    _ = posix.system.ftruncate(fd, @intCast(size));

    const prot = posix.PROT{ .READ = true, .WRITE = true };
    const data = try posix.mmap(null, size, prot, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);

    // Cairo draws directly into the mmap'd SHM buffer — no extra copy, and
    // exactly what gets presented is exactly what we asked Pango to render.
    const real_surface = cairo.image_surface_create_for_data(data.ptr, CAIRO_FORMAT_ARGB32, width, height, stride) orelse return error.CairoSurfaceFailed;
    const real_cr = cairo.create(real_surface) orelse return error.CairoContextFailed;
    cairo.set_source_rgb(real_cr, args.bg[0], args.bg[1], args.bg[2]);
    cairo.paint(real_cr);
    cairo.set_source_rgb(real_cr, args.fg[0], args.fg[1], args.fg[2]);
    cairo.move_to(real_cr, args.pad, args.pad);
    const real_layout = cairo.cairo_create_layout(real_cr) orelse return error.PangoLayoutFailed;
    cairo.layout_set_font_description(real_layout, font_desc);
    cairo.layout_set_text(real_layout, args.text.ptr, @intCast(args.text.len));
    cairo.cairo_show_layout(real_cr, real_layout);
    cairo.surface_flush(real_surface);
    cairo.destroy(real_cr);
    cairo.surface_destroy(real_surface);
    cairo.font_description_free(font_desc);

    // Passed via an explicit WlArgument array (not the variadic
    // wl_proxy_marshal_flags(...) form) because the 'h' (fd) argument's
    // value must land exactly where libwayland's marshaller dup()s it from
    // — a plain struct field is unambiguous, whereas routing an fd through
    // Zig's C-variadic-call ABI reliably corrupted it here (observed as
    // "dup failed: Bad file descriptor" even for a freshly opened, valid fd).
    const pool_args = [_]WlArgument{ .{ .o = null }, .{ .h = fd }, .{ .i = @intCast(size) } };
    const pool = wl.wl_proxy_marshal_array_constructor_versioned(g_shm.?, 0, @ptrCast(&pool_args), wl.wl_shm_pool_interface, 1) orelse return error.PoolFailed;
    const buffer_args = [_]WlArgument{ .{ .o = null }, .{ .i = 0 }, .{ .i = width }, .{ .i = height }, .{ .i = stride }, .{ .u = 0 } };
    const buffer = wl.wl_proxy_marshal_array_constructor_versioned(pool, 0, @ptrCast(&buffer_args), wl.wl_buffer_interface, 1) orelse return error.BufferFailed;
    g_buffer = buffer;

    // wl_display_dispatch() blocks on a socket read when nothing is queued,
    // so bound every wait with poll() on the display fd (2s deadline) —
    // a compositor that never sends our configure event must not hang this
    // canary forever (see docs/Zig.md's "bounded probe" pattern).
    const wl_fd = wl.wl_display_get_fd(display);
    var pfd = [_]posix.pollfd{.{ .fd = wl_fd, .events = posix.POLL.IN, .revents = 0 }};
    var waited_ms: i32 = 0;
    while (!g_committed_content and waited_ms < 2000) {
        const n = posix.poll(&pfd, 50) catch break;
        if (n > 0) _ = wl.wl_display_dispatch(display);
        waited_ms += 50;
    }
    if (!g_committed_content) return error.NeverConfigured;

    // Give sway a moment to actually map + present the surface before we
    // ask swaymsg/grim to find and shoot it (matches the ~300ms warm-up
    // already used by scripts/screenshot per AGENTS.md).
    var settled_ms: i32 = 0;
    while (settled_ms < 300) : (settled_ms += 50) {
        _ = wl.wl_display_flush(display);
        const n = posix.poll(&pfd, 50) catch break;
        if (n > 0) _ = wl.wl_display_dispatch(display);
    }

    // Compositor-specific real-screenshot tiers, in order of preference —
    // both actually rasterize the *presented* frame through the real
    // compositor (the whole point of this canary), unlike the final
    // fallback which just dumps our own SHM buffer back out:
    //   1. sway/wlroots: swaymsg locates our window by app_id, grim -g
    //      shoots exactly that rect (pre-cropped, no host chrome).
    //   2. GNOME/Mutter: grim has no wlr-screencopy to talk to, so use
    //      GNOME Shell's own ScreenshotWindow D-Bus method, which shoots
    //      whichever window currently has focus (must be run from the
    //      real logged-in session — a sandboxed/CI D-Bus connection gets
    //      AccessDenied here, which is fine: this canary is manual/on-host
    //      only, see docs/EmojiWidthResearch.md).
    if (std.c.getenv("SWAYSOCK") != null) {
        if (try captureViaSway(io, alloc, args.app_id, out_path)) return;
        std.debug.print("warn: sway app_id lookup failed; falling back to full-screen grim capture\n", .{});
        runIgnoring(io, &[_][]const u8{ "grim", out_path });
        std.debug.print("canary_font: saved (uncropped) {s}\n", .{out_path});
        return;
    }

    if (captureViaGnomeShell(io, alloc, out_path)) return;

    std.debug.print(
        "warn: no working real-compositor screenshot path found (not sway, and\n" ++
            "GNOME Shell's ScreenshotWindow was denied or unavailable) — dumping our\n" ++
            "own pre-composite SHM buffer instead. This is NOT a real on-screen\n" ++
            "capture and proves nothing about compositor-level rendering; re-run this\n" ++
            "from your actual logged-in desktop session, not a sandboxed/CI shell.\n",
        .{},
    );
    const png_path_z = try alloc.dupeZ(u8, out_path);
    const dump_surface = cairo.image_surface_create_for_data(data.ptr, CAIRO_FORMAT_ARGB32, width, height, stride) orelse return error.CairoSurfaceFailed;
    _ = cairo.surface_write_to_png(dump_surface, png_path_z);
    cairo.surface_destroy(dump_surface);
    std.debug.print("canary_font: saved (OFFLINE RENDER ONLY) {s}\n", .{out_path});
}

/// Locates our window by app_id via `swaymsg -t get_tree` and shoots exactly
/// its rect with `grim -g`. Returns false (not an error) if sway's tree
/// doesn't contain our app_id, so the caller can fall back cleanly.
fn captureViaSway(io: anytype, alloc: std.mem.Allocator, app_id: []const u8, out_path: []const u8) !bool {
    const tree_json = try runCapturing(io, alloc, &[_][]const u8{ "swaymsg", "-t", "get_tree" });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, tree_json, .{}) catch return false;
    defer parsed.deinit();

    const rect = findWindowRect(parsed.value, app_id) orelse return false;
    const geom = try std.fmt.allocPrint(alloc, "{d},{d} {d}x{d}", .{ rect.x, rect.y, rect.w, rect.h });
    runIgnoring(io, &[_][]const u8{ "grim", "-g", geom, out_path });
    std.debug.print("canary_font: saved {s} (grim -g \"{s}\")\n", .{ out_path, geom });
    return true;
}

/// Shoots the currently focused window via GNOME Shell's own D-Bus
/// screenshot method (grim has nothing to talk to on Mutter — no
/// wlr-screencopy). Returns true only once we've confirmed `gdbus` itself
/// reported success (its own stdout line starts with "(true,").
fn captureViaGnomeShell(io: anytype, alloc: std.mem.Allocator, out_path: []const u8) bool {
    const abs_out = std.fs.path.resolve(alloc, &[_][]const u8{out_path}) catch return false;
    const argv = [_][]const u8{
        "gdbus",                                       "call",
        "--session",                                   "--dest",
        "org.gnome.Shell",                             "--object-path",
        "/org/gnome/Shell/Screenshot",                 "--method",
        "org.gnome.Shell.Screenshot.ScreenshotWindow", "true",
        "true",                                        "false",
        abs_out,
    };
    const out = runCapturing(io, alloc, &argv) catch return false;
    if (std.mem.startsWith(u8, out, "(true,")) {
        std.debug.print("canary_font: saved {s} (org.gnome.Shell.Screenshot.ScreenshotWindow)\n", .{out_path});
        return true;
    }
    return false;
}
