// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Wayland native window and surface engine for emojig --gui-native mode.
//! Implements cell-precise character geometry sizing (foot algorithm)
//! and direct xdg_toplevel surface management without host terminal dependencies.

const std = @import("std");
const posix = std.posix;

/// Wayland client C API bindings.
const c = if (@import("builtin").link_libc) @cImport({
    @cInclude("wayland-client.h");
}) else struct {};

pub const WaylandError = error{
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
    csd_header_height: u32 = 0,
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

pub const ShmBuffer = struct {
    wl_buffer: *c.wl_buffer,
    data: []u8,
    fd: posix.fd_t,
    width: u32,
    height: u32,
    stride: u32,
    busy: bool = false,

    pub fn deinit(self: *ShmBuffer) void {
        _ = posix.munmap(@alignCast(self.data));
        posix.close(self.fd);
        c.wl_buffer_destroy(self.wl_buffer);
    }
};

pub const NativeGuiWindow = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    geometry: GeometryConfig,
    scale: u32 = 1,
    configured: bool = false,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, geom: GeometryConfig) !*NativeGuiWindow {
        const display = c.wl_display_connect(null) orelse return WaylandError.DisplayConnectFailed;
        errdefer c.wl_display_disconnect(display);

        const self = try allocator.create(NativeGuiWindow);
        errdefer allocator.destroy(self);

        const registry = c.wl_display_get_registry(display) orelse return WaylandError.RegistryGetFailed;

        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .geometry = geom,
        };

        return self;
    }

    pub fn deinit(self: *NativeGuiWindow) void {
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        self.allocator.destroy(self);
    }
};
