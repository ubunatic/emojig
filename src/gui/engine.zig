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
