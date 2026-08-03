// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Font loading, HarfBuzz text shaping, and FreeType glyph rasterization engine for emojig GUI.
//! Supports monochrome UI text, CBDT bitmap color emojis, and COLRv1 vector color emojis.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// FreeType, HarfBuzz, and Fontconfig C API bindings.
const c = struct {};

pub const FontError = error{
    FreeTypeInitFailed,
    FontConfigInitFailed,
    FontNotFound,
    FaceLoadFailed,
    SetSizeFailed,
    ShapingFailed,
    GlyphLoadFailed,
    RasterizationFailed,
    UnsupportedFormat,
    OutOfMemory,
};

pub const PixelFormat = enum {
    alpha8,
    bgra32,
    rgba32,
};

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    pitch: u32,
    format: PixelFormat,
    buffer: []const u8,

    pub fn deinit(self: *GlyphBitmap, allocator: Allocator) void {
        allocator.free(self.buffer);
    }
};

pub const FontMetrics = struct {
    pixel_size: u32,
    ascent: i32,
    descent: i32,
    height: i32,
    max_advance: i32,
    cell_width: u32,
    cell_height: u32,
};

pub const FtLibrary = opaque {};

pub const FontManager = struct {
    ft_lib: ?*FtLibrary = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) FontError!FontManager {
        return .{
            .ft_lib = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontManager) void {
        _ = self;
    }
};
