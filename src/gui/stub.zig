// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Zero-dependency headless GUI stub module for -Dgui=false builds.
//! All declarations match the GUI engine interface but return GuiDisabledAtBuildTime error.

const std = @import("std");

pub const GuiError = error{
    GuiDisabledAtBuildTime,
};

pub const NativeGuiWindow = struct {
    pub fn init(_: std.mem.Allocator, _: usize, _: usize) GuiError!NativeGuiWindow {
        return error.GuiDisabledAtBuildTime;
    }

    pub fn run(_: *NativeGuiWindow) GuiError!void {
        return error.GuiDisabledAtBuildTime;
    }

    pub fn deinit(_: *NativeGuiWindow) void {}
};

pub fn isSupported() bool {
    return false;
}

pub fn runNativeGui(_: std.mem.Allocator, _: u32, _: u32) GuiError!void {
    return error.GuiDisabledAtBuildTime;
}
