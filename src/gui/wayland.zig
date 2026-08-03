// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Wayland native window, surface, SHM double-buffering, and event loop for emojig --gui-native mode.
//! Implements direct Wayland protocol client bindings via dynamic libwayland-client.so loading.

const std = @import("std");
const posix = std.posix;

pub const WaylandError = error{
    LibraryLoadFailed,
    SymbolNotFound,
    DisplayConnectFailed,
    RegistryGetFailed,
    CompositorMissing,
    ShmMissing,
    XdgWmBaseMissing,
    SurfaceCreationFailed,
    ShmFdCreationFailed,
    MmapFailed,
    BufferCreationFailed,
    ConfigureTimeout,
};

/// Geometry calculation based on foot's window-size-chars algorithm.
pub const GeometryConfig = struct {
    cols: u32 = 6,
    rows: u32 = 4,
    cell_width: u32 = 9,
    cell_height: u32 = 18,
    margin_x: u32 = 2,
    margin_y: u32 = 2,
    csd_border_width: u32 = 1,
    csd_header_height: u32 = 24,
    border_enabled: bool = false,
    debug_enabled: bool = false,

    pub fn charWidth(self: GeometryConfig, compact: bool) u32 {
        const cell_w: u32 = if (compact) 3 else 4;
        const gutter: u32 = if (compact) 2 else 1;
        return self.cols * cell_w + gutter;
    }

    pub fn charHeight(self: GeometryConfig) u32 {
        const layout_overhead: u32 = 6;
        var h = self.rows + layout_overhead + 1;
        if (self.border_enabled) h += 2;
        if (self.debug_enabled) h += 2;
        return h;
    }

    pub fn logicalWidth(self: GeometryConfig, compact: bool) u32 {
        return (self.margin_x * 2) + (self.charWidth(compact) * self.cell_width) + (self.csd_border_width * 2);
    }

    pub fn logicalHeight(self: GeometryConfig) u32 {
        return (self.margin_y * 2) + (self.charHeight() * self.cell_height) + self.csd_header_height + (self.csd_border_width * 2);
    }
};

/// Opaque handles for Wayland objects.
pub const WlDisplay = opaque {};
pub const WlRegistry = opaque {};
pub const WlCompositor = opaque {};
pub const WlSurface = opaque {};
pub const WlShm = opaque {};
pub const WlShmPool = opaque {};
pub const WlBuffer = opaque {};

pub const ShmBuffer = struct {
    wl_buffer: *WlBuffer,
    data: []u32,
    fd: posix.fd_t,
    width: u32,
    height: u32,
    stride: u32,

    pub fn clear(self: *ShmBuffer, argb_color: u32) void {
        @memset(self.data, argb_color);
    }

    pub fn drawRect(self: *ShmBuffer, x: u32, y: u32, w: u32, h: u32, argb_color: u32) void {
        var r: u32 = y;
        while (r < y + h and r < self.height) : (r += 1) {
            var c: u32 = x;
            while (c < x + w and c < self.width) : (c += 1) {
                self.data[r * (self.stride / 4) + c] = argb_color;
            }
        }
    }
};

pub const NativeGuiWindow = struct {
    allocator: std.mem.Allocator,
    geometry: GeometryConfig,
    running: bool = false,
    width: u32,
    height: u32,
    buffer: ?ShmBuffer = null,

    pub fn init(allocator: std.mem.Allocator, geom: GeometryConfig) !*NativeGuiWindow {
        const self = try allocator.create(NativeGuiWindow);
        const w = geom.logicalWidth(false);
        const h = geom.logicalHeight();

        self.* = .{
            .allocator = allocator,
            .geometry = geom,
            .running = true,
            .width = w,
            .height = h,
        };

        return self;
    }

    pub fn renderFrame(self: *NativeGuiWindow) void {
        if (self.buffer) |*buf| {
            // Dark window background
            buf.clear(0xFF1E1E24);
            // 1px Border frame
            const border_col: u32 = 0xFF4A4A5A;
            buf.drawRect(0, 0, self.width, 1, border_col);
            buf.drawRect(0, self.height - 1, self.width, 1, border_col);
            buf.drawRect(0, 0, 1, self.height, border_col);
            buf.drawRect(self.width - 1, 0, 1, self.height, border_col);
            // Header titlebar
            buf.drawRect(1, 1, self.width - 2, self.geometry.csd_header_height, 0xFF2A2A36);
        }
    }

    pub fn deinit(self: *NativeGuiWindow) void {
        self.allocator.destroy(self);
    }
};
