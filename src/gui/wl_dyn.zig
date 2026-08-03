// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Wayland C API and symbol bindings for native window creation.

const std = @import("std");

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
        const names = [_][]const u8{
            "libwayland-client.so.0",
            "libwayland-client.so",
        };

        var handle: ?*anyopaque = null;
        for (names) |name| {
            var name_z: [64]u8 = undefined;
            if (name.len >= name_z.len) continue;
            @memcpy(name_z[0..name.len], name);
            name_z[name.len] = 0;

            const mode: std.c.RTLD = @bitCast(@as(u32, 1));
            if (std.c.dlopen(name_z[0..name.len :0].ptr, mode)) |h| {
                handle = h;
                break;
            }
        }

        const h = handle orelse return error.LibraryLoadFailed;

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

pub const wl_pointer_requests = [_]WlMessage{
    .{ .name = "set_cursor", .signature = "u?oii", .types = &[_]?*const WlInterface{ null, null, null, null } },
    .{ .name = "release", .signature = "3", .types = &[_]?*const WlInterface{} },
};
pub const wl_pointer_events = [_]WlMessage{
    .{ .name = "enter", .signature = "uoff", .types = &[_]?*const WlInterface{ null, null, null, null } },
    .{ .name = "leave", .signature = "uo", .types = &[_]?*const WlInterface{ null, null } },
    .{ .name = "motion", .signature = "uff", .types = &[_]?*const WlInterface{ null, null, null } },
    .{ .name = "button", .signature = "uuuu", .types = &[_]?*const WlInterface{ null, null, null, null } },
    .{ .name = "axis", .signature = "uuf", .types = &[_]?*const WlInterface{ null, null, null } },
};
pub const wl_pointer_interface = WlInterface{
    .name = "wl_pointer",
    .version = 9,
    .method_count = 2,
    .methods = &wl_pointer_requests,
    .event_count = 5,
    .events = &wl_pointer_events,
};
pub const wl_seat_requests = [_]WlMessage{
    .{ .name = "get_pointer", .signature = "n", .types = &[_]?*const WlInterface{&wl_pointer_interface} },
    .{ .name = "get_keyboard", .signature = "n", .types = &[_]?*const WlInterface{null} },
    .{ .name = "get_touch", .signature = "n", .types = &[_]?*const WlInterface{null} },
    .{ .name = "release", .signature = "5", .types = &[_]?*const WlInterface{} },
};
pub const wl_seat_events = [_]WlMessage{
    .{ .name = "capabilities", .signature = "u", .types = &[_]?*const WlInterface{null} },
    .{ .name = "name", .signature = "2s", .types = &[_]?*const WlInterface{null} },
};
pub const wl_seat_interface = WlInterface{
    .name = "wl_seat",
    .version = 9,
    .method_count = 4,
    .methods = &wl_seat_requests,
    .event_count = 2,
    .events = &wl_seat_events,
};
