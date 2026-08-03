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
    wl_display_flush: *const fn (display: *anyopaque) callconv(.c) c_int,
    wl_proxy_marshal_flags: *const fn (proxy: *anyopaque, opcode: u32, interface: ?*const WlInterface, version: u32, flags: u32, ...) callconv(.c) ?*anyopaque,
    wl_proxy_add_listener: *const fn (proxy: *anyopaque, implementation: ?*const fn () callconv(.c) void, data: ?*anyopaque) callconv(.c) c_int,
    wl_display_interface: *const WlInterface,
    wl_registry_interface: *const WlInterface,
    wl_compositor_interface: *const WlInterface,
    wl_shm_interface: *const WlInterface,
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
            .wl_display_flush = @ptrCast(std.c.dlsym(h, "wl_display_flush") orelse return error.SymbolNotFound),
            .wl_proxy_marshal_flags = @ptrCast(std.c.dlsym(h, "wl_proxy_marshal_flags") orelse return error.SymbolNotFound),
            .wl_proxy_add_listener = @ptrCast(std.c.dlsym(h, "wl_proxy_add_listener") orelse return error.SymbolNotFound),
            .wl_display_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_display_interface") orelse return error.SymbolNotFound)),
            .wl_registry_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_registry_interface") orelse return error.SymbolNotFound)),
            .wl_compositor_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_compositor_interface") orelse return error.SymbolNotFound)),
            .wl_shm_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_shm_interface") orelse return error.SymbolNotFound)),
            .wl_surface_interface = @ptrCast(@alignCast(std.c.dlsym(h, "wl_surface_interface") orelse return error.SymbolNotFound)),
        };
    }

    pub fn unload(self: *WaylandLib) void {
        _ = std.c.dlclose(self.handle);
    }
};
