// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Canary script setting up surface, shm buffer, and xdg_wm_base to present a visible native window on screen.

const std = @import("std");
const posix = std.posix;

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
    .{ .name = "get_toplevel", .signature = "n", .types = &[_]?*const WlInterface{ null } },
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

var compositor: ?*anyopaque = null;
var shm: ?*anyopaque = null;
var xdg_wm_base: ?*anyopaque = null;
var ok_clicked: bool = false;

fn registryHandleGlobal(data: ?*anyopaque, reg: ?*anyopaque, name: u32, interface_ptr: [*:0]const u8, version: u32) callconv(.c) void {
    const wl_ptr: *WaylandLib = @ptrCast(@alignCast(data orelse return));
    const iface_name = std.mem.span(interface_ptr);
    const ver: u32 = @min(version, 4);
    const null_ptr: ?*anyopaque = null;

    if (std.mem.eql(u8, iface_name, "wl_compositor")) {
        compositor = wl_ptr.wl_proxy_marshal_flags(reg orelse return, 0, wl_ptr.wl_compositor_interface, ver, 0, name, wl_ptr.wl_compositor_interface.name, ver, null_ptr);
    } else if (std.mem.eql(u8, iface_name, "wl_shm")) {
        shm = wl_ptr.wl_proxy_marshal_flags(reg orelse return, 0, wl_ptr.wl_shm_interface, 1, 0, name, wl_ptr.wl_shm_interface.name, @as(u32, 1), null_ptr);
    } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
        const xdg_ver: u32 = @min(version, 6);
        const args = [_]WlArgument{
            .{ .u = name },
            .{ .s = xdg_wm_base_interface.name },
            .{ .u = xdg_ver },
            .{ .o = null },
        };
        xdg_wm_base = wl_ptr.wl_proxy_marshal_array_constructor_versioned(reg orelse return, 0, @ptrCast(&args), &xdg_wm_base_interface, xdg_ver);
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

pub fn main() !void {
    var wl = try WaylandLib.load();
    defer wl.unload();

    const display = wl.wl_display_connect(null) orelse wl.wl_display_connect("wayland-0") orelse return error.DisplayConnectFailed;
    defer wl.wl_display_disconnect(display);

    const null_ptr: ?*anyopaque = null;
    const registry = wl.wl_proxy_marshal_flags(display, 1, wl.wl_registry_interface, 1, 0, null_ptr) orelse return error.RegistryFailed;
    _ = wl.wl_proxy_add_listener(registry, @ptrCast(&registry_listener[0]), &wl);

    _ = wl.wl_display_roundtrip(display);

    if (compositor == null or shm == null or xdg_wm_base == null) {
        std.debug.print("CANARY FAIL: Required globals not found\n", .{});
        return;
    }

    // Allocate surface
    const surface = wl.wl_proxy_marshal_flags(compositor.?, 0, wl.wl_surface_interface, 1, 0, null_ptr) orelse return error.SurfaceFailed;

    // Create xdg_surface
    const xdg_surf_args = [_]WlArgument{
        .{ .o = null },
        .{ .o = surface },
    };
    const xdg_surface = wl.wl_proxy_marshal_array_constructor_versioned(xdg_wm_base.?, 2, @ptrCast(&xdg_surf_args), &xdg_surface_interface, 1) orelse return error.XdgSurfaceFailed;

    // Create xdg_toplevel
    const xdg_top_args = [_]WlArgument{
        .{ .o = null },
    };
    const xdg_toplevel = wl.wl_proxy_marshal_array_constructor_versioned(xdg_surface, 1, @ptrCast(&xdg_top_args), &xdg_toplevel_interface, 1) orelse return error.XdgToplevelFailed;
    _ = xdg_toplevel;

    // Create 400x300 SHM buffer
    const width: i32 = 400;
    const height: i32 = 300;
    const stride: i32 = width * 4;
    const size: usize = @intCast(stride * height);

    const shm_name = "/emojig-canary-shm";
    const oflags: u32 = @bitCast(posix.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
    const fd = std.c.shm_open(shm_name, @intCast(oflags), 0o600);
    if (fd < 0) return error.ShmOpenFailed;
    _ = std.c.shm_unlink(shm_name);
    defer _ = posix.system.close(fd);
    _ = posix.system.ftruncate(fd, @intCast(size));

    const prot = posix.PROT{ .READ = true, .WRITE = true };
    const data = try posix.mmap(null, size, prot, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);

    // Fill buffer with dark blue, and a button in the center
    const pixels: []u32 = @ptrCast(@alignCast(data));
    @memset(pixels, 0xFF1E2238);
    // Draw "OK" button
    const btn_x: i32 = 150;
    const btn_y: i32 = 120;
    const btn_w: i32 = 100;
    const btn_h: i32 = 60;
    var r: i32 = btn_y;
    while (r < btn_y + btn_h) : (r += 1) {
        var c: i32 = btn_x;
        while (c < btn_x + btn_w) : (c += 1) {
            pixels[@intCast(r * (stride / 4) + c)] = 0xFF4A4A5A;
        }
    }

    const pool = wl.wl_proxy_marshal_flags(shm.?, 0, wl.wl_shm_pool_interface, 1, 0, @as(c_int, fd), @as(i32, @intCast(size)), null_ptr) orelse return error.PoolFailed;
    const buffer = wl.wl_proxy_marshal_flags(pool, 0, wl.wl_buffer_interface, 1, 0, @as(i32, 0), width, height, stride, @as(u32, 0), null_ptr) orelse return error.BufferFailed;

    // Attach & commit
    _ = wl.wl_proxy_marshal_flags(surface, 1, null, 1, 0, buffer, @as(i32, 0), @as(i32, 0));
    _ = wl.wl_proxy_marshal_flags(surface, 6, null, 1, 0); // commit
    _ = wl.wl_display_flush(display);

    std.debug.print("SUCCESS: Native surface created and committed! Running event loop...\n", .{});

    var count: usize = 0;
    while (count < 1000 and !ok_clicked) : (count += 1) {
        _ = wl.wl_display_dispatch(display);
    }
}
