// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Dynamic loader for libwayland-client.so.0.
//! Provides exported C function pointers and protocol helpers for pure runtime binding.

const std = @import("std");

pub const WaylandLib = struct {
    handle: *anyopaque,

    // Core Wayland exported functions
    wl_display_connect: *const fn (name: ?[*:0]const u8) ?*anyopaque,
    wl_display_disconnect: *const fn (display: *anyopaque) void,
    wl_display_dispatch: *const fn (display: *anyopaque) c_int,
    wl_display_flush: *const fn (display: *anyopaque) c_int,

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
        };
    }

    pub fn unload(self: *WaylandLib) void {
        _ = std.c.dlclose(self.handle);
    }
};
