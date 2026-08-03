// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Client-Side Decoration (CSD) 1px border framing and titlebar renderer for emojig GUI.
//! Uses spec/gui_csd.yaml as the single source of truth.

const std = @import("std");
const spec_mod = @import("../spec.zig");

pub const HitZone = enum {
    none,
    titlebar,
    button_close,
    button_minimize,
    button_maximize,
    border_top,
    border_bottom,
    border_left,
    border_right,
    content,
};

pub const CsdRenderer = struct {
    allocator: std.mem.Allocator,
    border_width: u32 = 1,
    header_height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) CsdRenderer {
        return .{
            .allocator = allocator,
        };
    }

    pub fn getHitZone(self: *const CsdRenderer, x: i32, y: i32, width: u32, height: u32) HitZone {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) {
            return .none;
        }

        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);

        if (uy < self.border_width) return .border_top;
        if (uy >= height - self.border_width) return .border_bottom;
        if (ux < self.border_width) return .border_left;
        if (ux >= width - self.border_width) return .border_right;

        if (self.header_height > 0 and uy < self.border_width + self.header_height) {
            return .titlebar;
        }

        return .content;
    }
};
