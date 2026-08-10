// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Manual, on-demand canary comparing how different width-computation
//! models sum a mixed plain-text + emoji string — the actual question
//! issue 57 raised, which scripts/canary_font.zig (isolating a single
//! font's rendering) cannot answer: does the *combined* width of a run
//! like "abc☺️ ☺︎🚀def" come out the same across models, or does a VS16/
//! ZWJ/keycap sequence throw off the sum?
//!
//! Four columns:
//!
//!   1. Pango/HarfBuzz shaping (dlopen'd libpango/libcairo, same as
//!      canary_font.zig) — cluster-aware, what GTK apps and VTE-based
//!      terminals' *text layout* approximates (not their *grid*, which
//!      most terminals compute separately per cell — see scope note).
//!   2. Naive per-codepoint summation — a deliberately dumb wcwidth()-
//!      style model: each Unicode codepoint gets an independent width
//!      (0/1/2) with NO clustering, matching the "per-codepoint width"
//!      camp of terminals (VTE, Alacritty, kitty, tmux, xterm — see
//!      docs/EmojiWidthResearch.md) that do not collapse ZWJ/VS16
//!      sequences into one cell.
//!   3. Raw HarfBuzz only, via the `hb-shape` CLI against the actual
//!      resolved font file (no Pango layout/itemization involved) — closer
//!      to what a lower-level renderer (e.g. foot's libfcft) does.
//!   4. foot's own library, libfcft, dlopen'd directly and called with
//!      fcft_rasterize_text_run_utf32 — foot's actual glyph-shaping code,
//!      not an inference from a screenshot. No terminal, no compositor, no
//!      wayreel: same offscreen-pixbuffer approach as columns 1-3, just
//!      calling foot's own library instead of Pango. Each returned glyph
//!      carries both `.cols` (fcft's own wcwidth()-equivalent decision)
//!      and `.advance.x` (the actual pixel advance) — this column reports
//!      both.
//!
//!      IMPORTANT CAVEAT, found immediately on first use: this measures
//!      *fcft's own default* `.cols` decision, which is NOT the same as
//!      foot's full width behavior. foot's `[tweak]
//!      grapheme-width-method=double-width` (issue 53) is applied by
//!      foot's *own* source on top of fcft's raw per-grapheme result —
//!      it does not exist in fcft.h's public API at all (grep confirms
//!      no "grapheme_width" symbol). Observed directly: fcft alone
//!      reports `cols=1` for `☺️` (VS16) with Twemoji — the *opposite* of
//!      what issue 53's fix assumes foot ends up doing end-to-end. This
//!      column is a real, direct measurement of one real layer foot
//!      depends on, not a full substitute for foot's own behavior.
//!
//! Per-cluster/per-codepoint breakdowns are printed for all four, plus a
//! naive-column-count-to-pixels estimate (using the advance of a plain
//! "0" in the same font as one reference "cell") so columns 1/3/4 end up
//! in comparable pixel units alongside column 4's own `.cols` figure.
//!
//! Usage: zig run scripts/canary_width_compare.zig -lc -- [-text=STR] ...
//! Run `zig run scripts/canary_width_compare.zig -lc -- -help` for flags.
//! Not part of `make canary` — manual research tool, see
//! docs/EmojiWidthResearch.md.

const std = @import("std");

// ---------------------------------------------------------------------------
// Cairo + Pango bindings (opaque-pointer C APIs — no struct-layout guessing,
// except PangoRectangle: a small, stable, public 4-int struct)
// ---------------------------------------------------------------------------

const PangoRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

const PangoLib = struct {
    cairo_h: *anyopaque,
    pango_h: *anyopaque,
    pangocairo_h: *anyopaque,

    image_surface_create_for_data: *const fn (data: [*]u8, format: c_int, width: c_int, height: c_int, stride: c_int) callconv(.c) ?*anyopaque,
    create: *const fn (surface: ?*anyopaque) callconv(.c) ?*anyopaque,
    destroy: *const fn (cr: ?*anyopaque) callconv(.c) void,
    surface_destroy: *const fn (surface: ?*anyopaque) callconv(.c) void,

    font_description_new: *const fn () callconv(.c) ?*anyopaque,
    font_description_set_family: *const fn (desc: ?*anyopaque, family: [*:0]const u8) callconv(.c) void,
    font_description_set_absolute_size: *const fn (desc: ?*anyopaque, size: f64) callconv(.c) void,
    font_description_free: *const fn (desc: ?*anyopaque) callconv(.c) void,

    cairo_create_layout: *const fn (cr: ?*anyopaque) callconv(.c) ?*anyopaque,
    layout_set_font_description: *const fn (layout: ?*anyopaque, desc: ?*anyopaque) callconv(.c) void,
    layout_set_text: *const fn (layout: ?*anyopaque, text: [*]const u8, length: c_int) callconv(.c) void,
    layout_get_pixel_size: *const fn (layout: ?*anyopaque, width: *c_int, height: *c_int) callconv(.c) void,
    layout_set_attributes: *const fn (layout: ?*anyopaque, attrs: ?*anyopaque) callconv(.c) void,

    layout_get_iter: *const fn (layout: ?*anyopaque) callconv(.c) ?*anyopaque,
    iter_free: *const fn (iter: ?*anyopaque) callconv(.c) void,
    iter_next_cluster: *const fn (iter: ?*anyopaque) callconv(.c) c_int,
    iter_get_cluster_extents: *const fn (iter: ?*anyopaque, ink_rect: ?*PangoRectangle, logical_rect: ?*PangoRectangle) callconv(.c) void,
    iter_get_index: *const fn (iter: ?*anyopaque) callconv(.c) c_int,

    attr_list_new: *const fn () callconv(.c) ?*anyopaque,
    attr_list_insert: *const fn (list: ?*anyopaque, attr: ?*anyopaque) callconv(.c) void,
    attr_fallback_new: *const fn (enable_fallback: c_int) callconv(.c) ?*anyopaque,

    fn sym(h: *anyopaque, name: [*:0]const u8) !*anyopaque {
        return std.c.dlsym(h, name) orelse return error.SymbolNotFound;
    }

    pub fn load() !PangoLib {
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
            .font_description_new = @ptrCast(try sym(pango_h, "pango_font_description_new")),
            .font_description_set_family = @ptrCast(try sym(pango_h, "pango_font_description_set_family")),
            .font_description_set_absolute_size = @ptrCast(try sym(pango_h, "pango_font_description_set_absolute_size")),
            .font_description_free = @ptrCast(try sym(pango_h, "pango_font_description_free")),
            .cairo_create_layout = @ptrCast(try sym(pangocairo_h, "pango_cairo_create_layout")),
            .layout_set_font_description = @ptrCast(try sym(pango_h, "pango_layout_set_font_description")),
            .layout_set_text = @ptrCast(try sym(pango_h, "pango_layout_set_text")),
            .layout_get_pixel_size = @ptrCast(try sym(pango_h, "pango_layout_get_pixel_size")),
            .layout_set_attributes = @ptrCast(try sym(pango_h, "pango_layout_set_attributes")),
            .layout_get_iter = @ptrCast(try sym(pango_h, "pango_layout_get_iter")),
            .iter_free = @ptrCast(try sym(pango_h, "pango_layout_iter_free")),
            .iter_next_cluster = @ptrCast(try sym(pango_h, "pango_layout_iter_next_cluster")),
            .iter_get_cluster_extents = @ptrCast(try sym(pango_h, "pango_layout_iter_get_cluster_extents")),
            .iter_get_index = @ptrCast(try sym(pango_h, "pango_layout_iter_get_index")),
            .attr_list_new = @ptrCast(try sym(pango_h, "pango_attr_list_new")),
            .attr_list_insert = @ptrCast(try sym(pango_h, "pango_attr_list_insert")),
            .attr_fallback_new = @ptrCast(try sym(pango_h, "pango_attr_fallback_new")),
        };
    }
};

const CAIRO_FORMAT_ARGB32: c_int = 0;
const PANGO_SCALE: f64 = 1024.0;

fn disableFallback(p: *const PangoLib, layout: ?*anyopaque) void {
    const attrs = p.attr_list_new() orelse return;
    const attr = p.attr_fallback_new(0) orelse return; // gboolean FALSE
    p.attr_list_insert(attrs, attr);
    p.layout_set_attributes(layout, attrs);
}

// ---------------------------------------------------------------------------
// Column 1: Pango/HarfBuzz shaping, with per-cluster breakdown
// ---------------------------------------------------------------------------

const ClusterInfo = struct {
    start: usize,
    end: usize,
    width_px: f64,
};

fn pangoMeasure(alloc: std.mem.Allocator, p: *const PangoLib, font: []const u8, text: []const u8, size_px: f64, allow_fallback: bool) !struct { total_px: f64, clusters: []ClusterInfo } {
    var scratch_pixels: [4]u8 = undefined;
    const surface = p.image_surface_create_for_data(&scratch_pixels, CAIRO_FORMAT_ARGB32, 1, 1, 4) orelse return error.CairoSurfaceFailed;
    defer p.surface_destroy(surface);
    const cr = p.create(surface) orelse return error.CairoContextFailed;
    defer p.destroy(cr);

    const desc = p.font_description_new() orelse return error.PangoFontDescFailed;
    const font_z = try alloc.dupeZ(u8, font);
    p.font_description_set_family(desc, font_z);
    p.font_description_set_absolute_size(desc, size_px * PANGO_SCALE);

    const layout = p.cairo_create_layout(cr) orelse return error.PangoLayoutFailed;
    p.layout_set_font_description(layout, desc);
    if (!allow_fallback) disableFallback(p, layout);
    p.layout_set_text(layout, text.ptr, @intCast(text.len));

    var total_w: c_int = 0;
    var total_h: c_int = 0;
    p.layout_get_pixel_size(layout, &total_w, &total_h);

    var clusters = std.array_list.Managed(ClusterInfo).init(alloc);
    const iter = p.layout_get_iter(layout) orelse return error.PangoIterFailed;
    defer p.iter_free(iter);
    while (true) {
        const start_idx: usize = @intCast(p.iter_get_index(iter));
        var logical: PangoRectangle = undefined;
        p.iter_get_cluster_extents(iter, null, &logical);
        const has_next = p.iter_next_cluster(iter) != 0;
        const end_idx: usize = if (has_next) @intCast(p.iter_get_index(iter)) else text.len;
        try clusters.append(.{ .start = start_idx, .end = end_idx, .width_px = @as(f64, @floatFromInt(logical.width)) / PANGO_SCALE });
        if (!has_next) break;
    }

    return .{ .total_px = @as(f64, @floatFromInt(total_w)), .clusters = try clusters.toOwnedSlice() };
}

// ---------------------------------------------------------------------------
// Column 2: naive per-codepoint summation (deliberately no clustering)
// ---------------------------------------------------------------------------

/// A deliberately dumb East-Asian-Width-style classifier: default width 1,
/// combining/variation-selector/ZWJ codepoints width 0, wide CJK/emoji
/// ranges width 2. This is NOT authoritative Unicode UAX#11 data — it's a
/// simplified stand-in for "what a terminal that sums per-codepoint widths
/// without clustering would compute," which is exactly the model this
/// column exists to represent (see docs/EmojiWidthResearch.md).
fn naiveCodepointWidth(cp: u21) u8 {
    // Variation selectors, ZWJ, combining enclosing keycap, combining marks.
    if (cp == 0x200D or cp == 0x20E3 or (cp >= 0xFE00 and cp <= 0xFE0F)) return 0;
    if ((cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF)) return 0;
    // Emoji block and other wide symbol ranges.
    if (cp >= 0x1F000) return 2;
    if (cp == 0x231A or cp == 0x231B or cp == 0x23F0 or cp == 0x23F3 or
        (cp >= 0x23E9 and cp <= 0x23EC) or cp == 0x2B50 or cp == 0x2B55 or
        cp == 0x2B1B or cp == 0x2B1C or (cp >= 0x3000 and cp <= 0x32FF)) return 2;
    // CJK / Hangul / fullwidth wide ranges (East Asian Wide, abbreviated).
    if ((cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0xFFE0 and cp <= 0xFFE6)) return 2;
    return 1;
}

const NaiveItem = struct { cp: u21, width: u8, byte_start: usize, byte_len: usize };

fn naiveMeasure(alloc: std.mem.Allocator, text: []const u8) !struct { total_cols: usize, items: []NaiveItem } {
    var items = std.array_list.Managed(NaiveItem).init(alloc);
    var total: usize = 0;
    const view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        const w = naiveCodepointWidth(cp);
        total += w;
        try items.append(.{ .cp = cp, .width = w, .byte_start = @intFromPtr(slice.ptr) - @intFromPtr(text.ptr), .byte_len = slice.len });
    }
    return .{ .total_cols = total, .items = try items.toOwnedSlice() };
}

// ---------------------------------------------------------------------------
// Column 3: raw HarfBuzz via `hb-shape` CLI against the resolved font file
// ---------------------------------------------------------------------------

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

fn resolveFontFile(io: anytype, alloc: std.mem.Allocator, font: []const u8) ![]const u8 {
    const out = try runCapturing(io, alloc, &[_][]const u8{ "fc-match", "-f", "%{file}", font });
    return std.mem.trim(u8, out, " \t\r\n");
}

const HbCluster = struct { start: usize, width_px: f64 };

fn harfbuzzMeasure(io: anytype, alloc: std.mem.Allocator, font: []const u8, text: []const u8, size_px: f64) !struct { total_px: f64, clusters: []HbCluster, font_file: []const u8 } {
    const font_file = try resolveFontFile(io, alloc, font);
    const size_arg = try std.fmt.allocPrint(alloc, "--font-size={d}", .{@as(i64, @intFromFloat(size_px))});
    const out = try runCapturing(io, alloc, &[_][]const u8{
        // --utf8-clusters: hb-shape's "cl" field defaults to a codepoint
        // INDEX, not a byte offset — without this flag, cluster byte-slices
        // below silently misalign on any multi-byte character.
        "hb-shape", font_file, "--text", text, size_arg, "--output-format=json", "--no-glyph-names", "--utf8-clusters",
    });

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();

    var clusters = std.array_list.Managed(HbCluster).init(alloc);
    var total: f64 = 0;
    if (parsed.value == .array) {
        var i: usize = 0;
        while (i < parsed.value.array.items.len) {
            const item = parsed.value.array.items[i];
            const cl: usize = @intCast(item.object.get("cl").?.integer);
            var cluster_width: f64 = 0;
            while (i < parsed.value.array.items.len) {
                const it2 = parsed.value.array.items[i];
                const it_cl: usize = @intCast(it2.object.get("cl").?.integer);
                if (it_cl != cl) break;
                const ax = it2.object.get("ax").?;
                cluster_width += switch (ax) {
                    .integer => @as(f64, @floatFromInt(ax.integer)),
                    .float => ax.float,
                    else => 0,
                };
                i += 1;
            }
            try clusters.append(.{ .start = cl, .width_px = cluster_width });
            total += cluster_width;
        }
    }
    return .{ .total_px = total, .clusters = try clusters.toOwnedSlice(), .font_file = font_file };
}

// ---------------------------------------------------------------------------
// Column 4: foot's own library, libfcft, dlopen'd directly — no terminal,
// no compositor, no wayreel. Struct layouts below are transcribed directly
// from /usr/include/fcft/fcft.h (fcft-devel), not guessed: fcft's structs
// expose public fields (unlike Cairo/Pango's opaque pointers), so getting
// them wrong would silently misread real data rather than fail loudly.
// ---------------------------------------------------------------------------

const FcftGlyph = extern struct {
    cp: u32,
    cols: c_int, // wcwidth(cp) — foot's actual terminal-column decision
    font_name: ?[*:0]const u8,
    pix: ?*anyopaque, // pixman_image_t* — unused here, we only read metrics
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    advance: extern struct { x: c_int, y: c_int },
    is_color_glyph: bool,
};

const FcftTextRun = extern struct {
    glyphs: [*]?*const FcftGlyph,
    cluster: [*]c_int, // per-glyph index into the INPUT CODEPOINT array
    count: usize,
};

const FcftLib = struct {
    handle: *anyopaque,
    init: *const fn (colorize: c_int, do_syslog: bool, log_level: c_int) callconv(.c) bool,
    from_name: *const fn (count: usize, names: [*]const [*:0]const u8, attributes: ?[*:0]const u8) callconv(.c) ?*anyopaque,
    destroy: *const fn (font: ?*anyopaque) callconv(.c) void,
    rasterize_text_run_utf32: *const fn (font: ?*anyopaque, len: usize, text: [*]const u32, subpixel: c_int) callconv(.c) ?*FcftTextRun,
    text_run_destroy: *const fn (run: ?*FcftTextRun) callconv(.c) void,

    fn sym(h: *anyopaque, name: [*:0]const u8) !*anyopaque {
        return std.c.dlsym(h, name) orelse return error.SymbolNotFound;
    }

    pub fn load() !FcftLib {
        const h = std.c.dlopen("libfcft.so.4", @bitCast(@as(u32, 1))) orelse return error.LibraryLoadFailed;
        return .{
            .handle = h,
            .init = @ptrCast(try sym(h, "fcft_init")),
            .from_name = @ptrCast(try sym(h, "fcft_from_name")),
            .destroy = @ptrCast(try sym(h, "fcft_destroy")),
            .rasterize_text_run_utf32 = @ptrCast(try sym(h, "fcft_rasterize_text_run_utf32")),
            .text_run_destroy = @ptrCast(try sym(h, "fcft_text_run_destroy")),
        };
    }
};

const FcftCluster = struct { cp_index: usize, cols: i64, advance_px: f64 };

fn fcftMeasure(alloc: std.mem.Allocator, font: []const u8, text: []const u8, size_px: f64) !struct { total_cols: i64, total_advance_px: f64, clusters: []FcftCluster, cp_byte_offsets: []usize } {
    const fcft = try FcftLib.load();
    // FCFT_LOG_COLORIZE_NEVER=0, FCFT_LOG_CLASS_NONE=0 — quiet by default.
    if (!fcft.init(0, false, 0)) return error.FcftInitFailed;

    // `names` holds plain family names (fcft's own fallback-list concept);
    // `attributes` is a *separate* fontconfig-format string. Concatenating
    // "FAMILY:size=N" into one name entry — the mistake this comment
    // replaces — fails outright for any family containing a space.
    const name_z = try alloc.dupeZ(u8, font);
    var names = [_][*:0]const u8{name_z.ptr};
    const attrs_str = try std.fmt.allocPrintSentinel(alloc, "size={d}", .{size_px}, 0);
    const fcft_font = fcft.from_name(1, &names, attrs_str.ptr) orelse return error.FcftFromNameFailed;
    defer fcft.destroy(fcft_font);

    // Decode UTF-8 -> UTF-32 codepoints (fcft's API takes uint32_t text),
    // recording each codepoint's starting byte offset so cluster indices
    // (which fcft reports as codepoint indices, like hb-shape without
    // --utf8-clusters) can be mapped back to byte ranges for display.
    var codepoints = std.array_list.Managed(u32).init(alloc);
    var cp_byte_offsets = std.array_list.Managed(usize).init(alloc);
    const view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        try codepoints.append(cp);
        try cp_byte_offsets.append(@intFromPtr(slice.ptr) - @intFromPtr(text.ptr));
    }
    try cp_byte_offsets.append(text.len); // sentinel for the last cluster's end

    const run = fcft.rasterize_text_run_utf32(fcft_font, codepoints.items.len, codepoints.items.ptr, 0) orelse return error.FcftRasterizeFailed;
    defer fcft.text_run_destroy(run);

    var clusters = std.array_list.Managed(FcftCluster).init(alloc);
    var total_cols: i64 = 0;
    var total_advance: f64 = 0;
    var gi: usize = 0;
    while (gi < run.count) {
        const cp_index: usize = @intCast(run.cluster[gi]);
        var cluster_cols: i64 = 0;
        var cluster_advance: f64 = 0;
        while (gi < run.count and @as(usize, @intCast(run.cluster[gi])) == cp_index) {
            const glyph = run.glyphs[gi] orelse {
                gi += 1;
                continue;
            };
            cluster_cols += glyph.cols;
            cluster_advance += @floatFromInt(glyph.advance.x);
            gi += 1;
        }
        try clusters.append(.{ .cp_index = cp_index, .cols = cluster_cols, .advance_px = cluster_advance });
        total_cols += cluster_cols;
        total_advance += cluster_advance;
    }

    return .{ .total_cols = total_cols, .total_advance_px = total_advance, .clusters = try clusters.toOwnedSlice(), .cp_byte_offsets = try cp_byte_offsets.toOwnedSlice() };
}

// ---------------------------------------------------------------------------
// CLI + main
// ---------------------------------------------------------------------------

const Args = struct {
    text: []const u8 = "abc\u{263a}\u{fe0f} \u{263a}\u{fe0e}\u{1f680}def",
    // Twemoji (CBDT) by default, not a COLRv1 font like unpatched "Noto
    // Color Emoji" — fcft (column 4, foot's own library) cannot load
    // COLRv1 at all ("COLRv1 not supported", confirmed directly), so a
    // COLRv1 default would silently break column 4 out of the box.
    font: []const u8 = "Twemoji",
    size_px: f64 = 48.0,
    allow_fallback: bool = true,
    help: bool = false,
};

fn parseArgs(init: std.process.Init) Args {
    var a = Args{};
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-help") or std.mem.eql(u8, arg, "-h")) {
            a.help = true;
        } else if (std.mem.startsWith(u8, arg, "-text=")) {
            a.text = arg["-text=".len..];
        } else if (std.mem.startsWith(u8, arg, "-font=")) {
            a.font = arg["-font=".len..];
        } else if (std.mem.startsWith(u8, arg, "-size=")) {
            a.size_px = std.fmt.parseFloat(f64, arg["-size=".len..]) catch a.size_px;
        } else if (std.mem.eql(u8, arg, "-no-fallback")) {
            a.allow_fallback = false;
        }
    }
    return a;
}

fn printHelp() void {
    std.debug.print(
        \\Usage: zig run scripts/canary_width_compare.zig -lc -- [flags]
        \\
        \\Feeds -text to four independent width-computation models and prints
        \\each one's total + per-cluster/per-codepoint breakdown side by side:
        \\  1. Pango/HarfBuzz shaping (cluster-aware, full fallback chain)
        \\  2. Naive per-codepoint summation (no clustering — the "per-codepoint
        \\     width" camp of terminals: VTE, Alacritty, kitty, tmux, xterm)
        \\  3. Raw HarfBuzz (hb-shape CLI) against the resolved font file
        \\  4. libfcft — foot's own library, dlopen'd directly, no terminal/
        \\     compositor/wayreel involved. NOTE: this is fcft's own default
        \\     .cols decision, NOT foot's full behavior — foot's own [tweak]
        \\     grapheme-width-method (issue 53) is applied by foot's *own*
        \\     source on top of this, not inside fcft. Also: fcft cannot load
        \\     COLRv1 fonts at all ("COLRv1 not supported") — use a CBDT font
        \\     like Twemoji (the default) for this column to work.
        \\
        \\  -text=STR      text/emoji to measure (default: "abc☺️ ☺︎🚀def")
        \\  -font=NAME     font family for columns 1/3/4 (default: Twemoji —
        \\                 a COLRv1 font like unpatched "Noto Color Emoji"
        \\                 will fail column 4 outright)
        \\  -size=PX       pixel font size (default: 48)
        \\  -no-fallback   disable Pango/fontconfig font substitution (default:
        \\                 fallback ALLOWED here — unlike canary_font, this tool
        \\                 wants realistic mixed-text width, not single-font
        \\                 isolation; see docs/EmojiWidthResearch.md)
        \\
        \\Manual/on-demand only — not part of `make canary`.
        \\
    , .{});
}

fn printClustersPango(text: []const u8, clusters: []const ClusterInfo) void {
    for (clusters) |c| {
        std.debug.print("    [{d:>3}:{d:<3}] {s:<12} {d:.1}px\n", .{ c.start, c.end, text[c.start..c.end], c.width_px });
    }
}

fn printClustersNaive(items: []const NaiveItem) void {
    for (items) |it| {
        std.debug.print("    U+{X:0>4} width={d}\n", .{ it.cp, it.width });
    }
}

fn printClustersHb(text: []const u8, clusters: []const HbCluster) void {
    for (clusters, 0..) |c, i| {
        const end = if (i + 1 < clusters.len) clusters[i + 1].start else text.len;
        std.debug.print("    [{d:>3}:{d:<3}] {s:<12} {d:.1}px\n", .{ c.start, end, text[c.start..end], c.width_px });
    }
}

fn printClustersFcft(text: []const u8, clusters: []const FcftCluster, cp_byte_offsets: []const usize) void {
    for (clusters, 0..) |c, i| {
        const start = cp_byte_offsets[c.cp_index];
        const end_cp_index = if (i + 1 < clusters.len) clusters[i + 1].cp_index else cp_byte_offsets.len - 1;
        const end = cp_byte_offsets[end_cp_index];
        std.debug.print("    [{d:>3}:{d:<3}] {s:<12} cols={d} {d:.1}px\n", .{ start, end, text[start..end], c.cols, c.advance_px });
    }
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

    std.debug.print("canary_width_compare: text={s} font={s} size={d}px allow_fallback={}\n\n", .{ args.text, args.font, args.size_px, args.allow_fallback });

    const pango = try PangoLib.load();
    const pango_result = try pangoMeasure(alloc, &pango, args.font, args.text, args.size_px, args.allow_fallback);
    std.debug.print("1. Pango/HarfBuzz shaping — total {d:.1}px\n", .{pango_result.total_px});
    printClustersPango(args.text, pango_result.clusters);

    const naive_result = try naiveMeasure(alloc, args.text);
    std.debug.print("\n2. Naive per-codepoint summation — total {d} cols\n", .{naive_result.total_cols});
    printClustersNaive(naive_result.items);

    const hb_result = harfbuzzMeasure(io, alloc, args.font, args.text, args.size_px) catch |err| {
        std.debug.print("\n3. Raw HarfBuzz (hb-shape) — FAILED: {t}\n", .{err});
        return;
    };
    std.debug.print("\n3. Raw HarfBuzz (hb-shape, font={s}) — total {d:.1}px\n", .{ hb_result.font_file, hb_result.total_px });
    printClustersHb(args.text, hb_result.clusters);

    const fcft_result = fcftMeasure(alloc, args.font, args.text, args.size_px) catch |err| {
        std.debug.print("\n4. libfcft (foot's own library) — FAILED: {t}\n", .{err});
        return;
    };
    std.debug.print("\n4. libfcft (foot's own library) — total {d} cols, {d:.1}px\n", .{ fcft_result.total_cols, fcft_result.total_advance_px });
    printClustersFcft(args.text, fcft_result.clusters, fcft_result.cp_byte_offsets);

    // Reference "cell" width for converting the naive column count into a
    // comparable pixel estimate: the advance of a plain "M" in the same
    // font (fallback allowed, since we just need a stable narrow reference
    // glyph, not to test this font's own coverage). NOT "0" — Twemoji's
    // bare digit glyphs are intentionally zero-width (they're keycap-
    // sequence bases, see issue 59), which silently zeroed this estimate
    // for the tool's own default font until caught here.
    const cell_result = try pangoMeasure(alloc, &pango, args.font, "M", args.size_px, true);
    const cell_px = cell_result.total_px;
    const naive_px_estimate = @as(f64, @floatFromInt(naive_result.total_cols)) * cell_px;

    std.debug.print("\nSummary (pixel units; naive converted via reference cell {d:.1}px):\n", .{cell_px});
    std.debug.print("  Pango/HarfBuzz shaping : {d:.1}px\n", .{pango_result.total_px});
    std.debug.print("  Naive per-codepoint sum: {d} cols (~{d:.1}px)\n", .{ naive_result.total_cols, naive_px_estimate });
    std.debug.print("  Raw HarfBuzz (hb-shape): {d:.1}px\n", .{hb_result.total_px});
    std.debug.print("  libfcft (foot's library): {d} cols, {d:.1}px\n", .{ fcft_result.total_cols, fcft_result.total_advance_px });
    std.debug.print(
        \\
        \\Note: column 1 (Pango) uses fontconfig's *fallback chain* — a
        \\missing glyph in -font is silently substituted from a whole set of
        \\fonts, same as a real GTK app. Columns 3/4 (raw hb-shape, libfcft)
        \\each shape against exactly one font file with no fallback chain at
        \\all (that concept doesn't exist below Pango) — a missing glyph
        \\there becomes .notdef at that font's own default advance. The
        \\totals disagreeing is therefore not itself a bug; it reflects a
        \\genuine difference in what each layer is capable of, which is
        \\exactly the kind of tech-stack difference this tool exists to
        \\surface. Column 4's "cols" figure is fcft's own wcwidth()-
        \\equivalent decision — real, but NOT the same as foot's full
        \\behavior: foot's own [tweak] grapheme-width-method=double-width
        \\(issue 53) is applied by foot's *own* source on top of this, not
        \\inside fcft. Treat column 4 as one real layer foot depends on,
        \\not a full stand-in for foot end-to-end.
        \\
    , .{});
}
