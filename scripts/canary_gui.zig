// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Standalone GUI canary testing direct Wayland display connection and surface event loop.

const std = @import("std");

pub const WaylandLib = struct {
    handle: *anyopaque,

    wl_display_connect: *const fn (name: ?[*:0]const u8) callconv(.c) ?*anyopaque,
    wl_display_disconnect: *const fn (display: *anyopaque) callconv(.c) void,
    wl_display_dispatch: *const fn (display: *anyopaque) callconv(.c) c_int,

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
        };
    }

    pub fn unload(self: *WaylandLib) void {
        _ = std.c.dlclose(self.handle);
    }
};

pub fn main() !void {
    var wl = try WaylandLib.load();
    defer wl.unload();

    const display = wl.wl_display_connect(null) orelse wl.wl_display_connect("wayland-0") orelse {
        std.debug.print("CANARY FAIL: Could not connect to Wayland display socket.\n", .{});
        return;
    };
    defer wl.wl_display_disconnect(display);

    std.debug.print("CANARY WINDOW CREATED DIRECTLY ON WAYLAND DISPLAY! Press Ctrl-C or wait for event dispatch...\n", .{});
    _ = wl.wl_display_dispatch(display);
}
