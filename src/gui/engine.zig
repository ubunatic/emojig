// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Native GUI engine subsystem entry point for emojig --gui-native mode.

const std = @import("std");
pub const wayland = @import("wayland.zig");
pub const font = @import("font.zig");
pub const csd = @import("csd.zig");

pub const NativeGuiWindow = wayland.NativeGuiWindow;

pub fn isSupported() bool {
    return true;
}

pub fn runNativeGui(
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
) !void {
    const geom = wayland.GeometryConfig{
        .cols = cols,
        .rows = rows,
    };
    var win = try wayland.NativeGuiWindow.init(allocator, geom);
    defer win.deinit();

    win.renderFrame();
    std.debug.print("Native Wayland window created directly (cols={d}, rows={d}, surface={d}x{d}px)\n", .{
        cols,
        rows,
        win.width,
        win.height,
    });
}
