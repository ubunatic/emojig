// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Wayland native window, surface, SHM double-buffering, and event loop for emojig --gui-native mode.
//! Implements direct Wayland protocol client bindings via dynamic libwayland-client.so loading.

const std = @import("std");
const posix = std.posix;
pub const wl_dyn = @import("wl_dyn.zig");

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
    XdgSurfaceFailed,
    XdgToplevelFailed,
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

pub const ShmBuffer = struct {
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
    wl: wl_dyn.WaylandLib,
    display: *anyopaque,
    registry: ?*anyopaque = null,
    compositor: ?*anyopaque = null,
    shm: ?*anyopaque = null,
    xdg_wm_base: ?*anyopaque = null,
    seat: ?*anyopaque = null,
    pointer: ?*anyopaque = null,
    surface: ?*anyopaque = null,
    xdg_surface: ?*anyopaque = null,
    xdg_toplevel: ?*anyopaque = null,
    geometry: GeometryConfig,
    running: bool = false,
    width: u32,
    height: u32,
    buffer: ?ShmBuffer = null,
    btn_x: u32 = 0,
    btn_y: u32 = 0,
    btn_w: u32 = 100,
    btn_h: u32 = 40,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,

    fn registryHandleGlobal(data: ?*anyopaque, reg: ?*anyopaque, name: u32, interface_ptr: [*:0]const u8, version: u32) callconv(.c) void {
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        const iface_name = std.mem.span(interface_ptr);
        const ver: u32 = @min(version, 4);
        const null_ptr: ?*anyopaque = null;

        if (std.mem.eql(u8, iface_name, "wl_compositor")) {
            self.compositor = self.wl.wl_proxy_marshal_flags(reg orelse return, 0, self.wl.wl_compositor_interface, ver, 0, name, self.wl.wl_compositor_interface.name, ver, null_ptr);
        } else if (std.mem.eql(u8, iface_name, "wl_shm")) {
            self.shm = self.wl.wl_proxy_marshal_flags(reg orelse return, 0, self.wl.wl_shm_interface, 1, 0, name, self.wl.wl_shm_interface.name, @as(u32, 1), null_ptr);
        } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
            const xdg_ver: u32 = @min(version, 6);
            const args = [_]wl_dyn.WlArgument{
                .{ .u = name },
                .{ .s = wl_dyn.xdg_wm_base_interface.name },
                .{ .u = xdg_ver },
                .{ .o = null },
            };
            self.xdg_wm_base = self.wl.wl_proxy_marshal_array_constructor_versioned(reg orelse return, 0, @ptrCast(&args), &wl_dyn.xdg_wm_base_interface, xdg_ver);

            const xdg_listener = [2]*const fn () callconv(.c) void{
                @ptrCast(&xdgWmBasePing),
                @ptrCast(&xdgWmBasePing), // dummy for unused events if any
            };
            _ = self.wl.wl_proxy_add_listener(self.xdg_wm_base.?, @ptrCast(&xdg_listener[0]), self);
        } else if (std.mem.eql(u8, iface_name, "wl_seat")) {
            const seat_ver: u32 = @min(version, 9);
            const args = [_]wl_dyn.WlArgument{
                .{ .u = name },
                .{ .s = wl_dyn.wl_seat_interface.name },
                .{ .u = seat_ver },
                .{ .o = null },
            };
            self.seat = self.wl.wl_proxy_marshal_array_constructor_versioned(reg orelse return, 0, @ptrCast(&args), &wl_dyn.wl_seat_interface, seat_ver);
            const seat_listener = [2]*const fn () callconv(.c) void{
                @ptrCast(&seatHandleCapabilities),
                @ptrCast(&seatHandleCapabilities), // name unused
            };
            _ = self.wl.wl_proxy_add_listener(self.seat.?, @ptrCast(&seat_listener[0]), self);
        }
    }

    fn registryHandleGlobalRemove(data: ?*anyopaque, reg: ?*anyopaque, name: u32) callconv(.c) void {
        _ = data;
        _ = reg;
        _ = name;
    }

    fn xdgWmBasePing(data: ?*anyopaque, proxy: ?*anyopaque, serial: u32) callconv(.c) void {
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        const args = [_]wl_dyn.WlArgument{
            .{ .u = serial },
        };
        // pong
        _ = self.wl.wl_proxy_marshal_array_constructor_versioned(proxy orelse return, 3, @ptrCast(&args), null, 6);
    }

    fn seatHandleCapabilities(data: ?*anyopaque, proxy: ?*anyopaque, caps: u32) callconv(.c) void {
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        if (caps & 1 != 0 and self.pointer == null) {
            const args = [_]wl_dyn.WlArgument{
                .{ .o = null },
            };
            self.pointer = self.wl.wl_proxy_marshal_array_constructor_versioned(proxy orelse return, 0, @ptrCast(&args), &wl_dyn.wl_pointer_interface, 9);
            const ptr_listener = [5]*const fn () callconv(.c) void{
                @ptrCast(&pointerHandleEnter),
                @ptrCast(&pointerHandleLeave),
                @ptrCast(&pointerHandleMotion),
                @ptrCast(&pointerHandleButton),
                @ptrCast(&pointerHandleAxis),
            };
            _ = self.wl.wl_proxy_add_listener(self.pointer.?, @ptrCast(&ptr_listener[0]), self);
        }
    }

    fn pointerHandleEnter(data: ?*anyopaque, proxy: ?*anyopaque, serial: u32, surface: ?*anyopaque, sx: i32, sy: i32) callconv(.c) void {
        _ = proxy;
        _ = serial;
        _ = surface;
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        self.pointer_x = @as(f64, @floatFromInt(sx)) / 256.0;
        self.pointer_y = @as(f64, @floatFromInt(sy)) / 256.0;
    }
    fn pointerHandleLeave(data: ?*anyopaque, proxy: ?*anyopaque, serial: u32, surface: ?*anyopaque) callconv(.c) void {
        _ = data;
        _ = proxy;
        _ = serial;
        _ = surface;
    }
    fn pointerHandleMotion(data: ?*anyopaque, proxy: ?*anyopaque, time: u32, sx: i32, sy: i32) callconv(.c) void {
        _ = proxy;
        _ = time;
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        self.pointer_x = @as(f64, @floatFromInt(sx)) / 256.0;
        self.pointer_y = @as(f64, @floatFromInt(sy)) / 256.0;
    }
    fn pointerHandleButton(data: ?*anyopaque, proxy: ?*anyopaque, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = proxy;
        _ = serial;
        _ = time;
        _ = button;
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        if (state == 1) { // PRESSED
            const px: u32 = @intFromFloat(self.pointer_x);
            const py: u32 = @intFromFloat(self.pointer_y);
            if (px >= self.btn_x and px <= self.btn_x + self.btn_w and py >= self.btn_y and py <= self.btn_y + self.btn_h) {
                self.running = false;
            }
        }
    }
    fn pointerHandleAxis(data: ?*anyopaque, proxy: ?*anyopaque, time: u32, axis: u32, value: i32) callconv(.c) void {
        _ = data;
        _ = proxy;
        _ = time;
        _ = axis;
        _ = value;
    }

    fn xdgSurfaceConfigure(data: ?*anyopaque, proxy: ?*anyopaque, serial: u32) callconv(.c) void {
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        const args = [_]wl_dyn.WlArgument{
            .{ .u = serial },
        };
        // ack_configure
        _ = self.wl.wl_proxy_marshal_array_constructor_versioned(proxy orelse return, 4, @ptrCast(&args), null, 6);
        self.renderFrame();
    }

    fn xdgToplevelConfigure(data: ?*anyopaque, proxy: ?*anyopaque, w: i32, h: i32, states: ?*anyopaque) callconv(.c) void {
        _ = proxy;
        _ = states;
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        if (w > 0 and h > 0) {
            self.width = @intCast(w);
            self.height = @intCast(h);
        }
    }

    fn xdgToplevelClose(data: ?*anyopaque, proxy: ?*anyopaque) callconv(.c) void {
        _ = proxy;
        const self: *NativeGuiWindow = @ptrCast(@alignCast(data orelse return));
        self.running = false;
    }

    pub fn init(allocator: std.mem.Allocator, geom: GeometryConfig) !*NativeGuiWindow {
        var wl = try wl_dyn.WaylandLib.load();
        errdefer wl.unload();

        const display = wl.wl_display_connect(null) orelse wl.wl_display_connect("wayland-0") orelse return WaylandError.DisplayConnectFailed;
        errdefer wl.wl_display_disconnect(display);

        const null_ptr: ?*anyopaque = null;
        const registry = wl.wl_proxy_marshal_flags(display, 1, wl.wl_registry_interface, 1, 0, null_ptr) orelse return WaylandError.RegistryGetFailed;

        const self = try allocator.create(NativeGuiWindow);
        const w = geom.logicalWidth(false);
        const h = geom.logicalHeight();

        self.* = .{
            .allocator = allocator,
            .wl = wl,
            .display = display,
            .registry = registry,
            .geometry = geom,
            .running = true,
            .width = w,
            .height = h,
            .btn_x = w / 2 - 50,
            .btn_y = h / 2 - 20,
            .btn_w = 100,
            .btn_h = 40,
        };

        const registry_listener = [2]*const fn () callconv(.c) void{
            @ptrCast(&registryHandleGlobal),
            @ptrCast(&registryHandleGlobalRemove),
        };
        _ = wl.wl_proxy_add_listener(registry, @ptrCast(&registry_listener[0]), self);

        _ = wl.wl_display_roundtrip(display);

        if (self.compositor == null) return WaylandError.CompositorMissing;
        if (self.shm == null) return WaylandError.ShmMissing;
        if (self.xdg_wm_base == null) return WaylandError.XdgWmBaseMissing;

        self.surface = wl.wl_proxy_marshal_flags(self.compositor.?, 0, wl.wl_surface_interface, 1, 0, null_ptr) orelse return WaylandError.SurfaceCreationFailed;

        const xdg_surf_args = [_]wl_dyn.WlArgument{
            .{ .o = null },
            .{ .o = self.surface },
        };
        self.xdg_surface = wl.wl_proxy_marshal_array_constructor_versioned(self.xdg_wm_base.?, 2, @ptrCast(&xdg_surf_args), &wl_dyn.xdg_surface_interface, 1) orelse return WaylandError.XdgSurfaceFailed;

        const xdg_surf_listener = [1]*const fn () callconv(.c) void{
            @ptrCast(&xdgSurfaceConfigure),
        };
        _ = wl.wl_proxy_add_listener(self.xdg_surface.?, @ptrCast(&xdg_surf_listener[0]), self);

        const xdg_top_args = [_]wl_dyn.WlArgument{
            .{ .o = null },
        };
        self.xdg_toplevel = wl.wl_proxy_marshal_array_constructor_versioned(self.xdg_surface.?, 1, @ptrCast(&xdg_top_args), &wl_dyn.xdg_toplevel_interface, 1) orelse return WaylandError.XdgToplevelFailed;

        const xdg_top_listener = [4]*const fn () callconv(.c) void{
            @ptrCast(&xdgToplevelConfigure),
            @ptrCast(&xdgToplevelClose),
            @ptrCast(&xdgToplevelClose),
            @ptrCast(&xdgToplevelClose),
        };
        _ = wl.wl_proxy_add_listener(self.xdg_toplevel.?, @ptrCast(&xdg_top_listener[0]), self);

        // set title
        const title_args = [_]wl_dyn.WlArgument{
            .{ .s = @constCast("emojig") },
        };
        _ = wl.wl_proxy_marshal_array_constructor_versioned(self.xdg_toplevel.?, 2, @ptrCast(&title_args), null, 1);

        // commit
        _ = wl.wl_proxy_marshal_flags(self.surface.?, 6, null, 1, 0);
        _ = wl.wl_display_roundtrip(display);

        // create shm buffer
        const stride: u32 = self.width * 4;
        const size: usize = @intCast(stride * self.height);

        const shm_name = "/emojig-gui-shm";
        const oflags: u32 = @bitCast(posix.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
        const fd = std.c.shm_open(shm_name, @intCast(oflags), 0o600);
        if (fd < 0) return WaylandError.ShmFdCreationFailed;
        _ = std.c.shm_unlink(shm_name);
        _ = posix.system.ftruncate(fd, @intCast(size));

        const prot = posix.PROT{ .READ = true, .WRITE = true };
        const data = try posix.mmap(null, size, prot, .{ .TYPE = .SHARED }, fd, 0);

        self.buffer = ShmBuffer{
            .data = @ptrCast(@alignCast(data)),
            .fd = fd,
            .width = self.width,
            .height = self.height,
            .stride = stride,
        };

        const pool_args = [_]wl_dyn.WlArgument{
            .{ .h = fd },
            .{ .i = @as(i32, @intCast(size)) },
        };
        const pool = wl.wl_proxy_marshal_array_constructor_versioned(self.shm.?, 0, @ptrCast(&pool_args), wl.wl_shm_pool_interface, 1) orelse return WaylandError.BufferCreationFailed;
        const buf_args = [_]wl_dyn.WlArgument{
            .{ .i = 0 },
            .{ .i = @as(i32, @intCast(self.width)) },
            .{ .i = @as(i32, @intCast(self.height)) },
            .{ .i = @as(i32, @intCast(stride)) },
            .{ .u = 0 },
        };
        const buffer = wl.wl_proxy_marshal_array_constructor_versioned(pool, 0, @ptrCast(&buf_args), wl.wl_buffer_interface, 1) orelse return WaylandError.BufferCreationFailed;

        const attach_args = [_]wl_dyn.WlArgument{
            .{ .o = buffer },
            .{ .i = 0 },
            .{ .i = 0 },
        };
        _ = wl.wl_proxy_marshal_array_constructor_versioned(self.surface.?, 1, @ptrCast(&attach_args), null, 1);
        self.renderFrame();

        return self;
    }

    pub fn renderFrame(self: *NativeGuiWindow) void {
        if (self.buffer) |*buf| {
            buf.clear(0xFF1E1E24);
            const border_col: u32 = 0xFF4A4A5A;
            buf.drawRect(0, 0, self.width, 1, border_col);
            buf.drawRect(0, self.height - 1, self.width, 1, border_col);
            buf.drawRect(0, 0, 1, self.height, border_col);
            buf.drawRect(self.width - 1, 0, 1, self.height, border_col);
            buf.drawRect(1, 1, self.width - 2, self.geometry.csd_header_height, 0xFF2A2A36);

            buf.drawRect(self.btn_x, self.btn_y, self.btn_w, self.btn_h, 0xFF3D3D8E);
        }
        if (self.surface != null) {
            _ = self.wl.wl_proxy_marshal_flags(self.surface.?, 6, null, 1, 0); // commit
            _ = self.wl.wl_display_flush(self.display);
        }
    }

    pub fn dispatch(self: *NativeGuiWindow) i32 {
        if (self.running) {
            return self.wl.wl_display_dispatch(self.display);
        }
        return -1;
    }

    pub fn deinit(self: *NativeGuiWindow) void {
        self.wl.wl_display_disconnect(self.display);
        self.wl.unload();
        self.allocator.destroy(self);
    }
};
