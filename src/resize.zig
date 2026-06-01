// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Simplified resize strategies for the inline TUI.
//
// eat (default TUI): Fixed-offset erase on shrink (no CPR); collapses to a blank line
//                    with hidden cursor when the TUI physically cannot fit in the current
//                    terminal height.
// altscreen (GUI):    Full ?1049h alternate screen — used for GUI mode.

const std = @import("std");

pub const Mode = enum { eat, altscreen };

// Parse EMOJIG_RESIZE_MODE. Any unknown or missing value falls back to eat.
pub fn parseMode(val: ?[]const u8) Mode {
    const s = val orelse return .eat;
    if (std.mem.eql(u8, s, "altscreen")) return .altscreen;
    return .eat;
}

pub const ResizeContext = struct {
    mode: Mode,
    is_hidden: bool = false,
    was_hidden: bool = false,

    pub fn init(mode: Mode) ResizeContext {
        return .{ .mode = mode, .is_hidden = false, .was_hidden = false };
    }

    // Whether the full TUI body rows (border, padding, grid, description) should be drawn.
    pub fn showBody(self: ResizeContext) bool {
        return !self.is_hidden;
    }

    // Whether the search bar row should be drawn at all.
    pub fn showSearchBar(self: ResizeContext) bool {
        return !self.is_hidden;
    }

    // Whether cursor repositioning code should run.
    pub fn repositionCursor(self: ResizeContext) bool {
        return !self.is_hidden;
    }

    // Effective frame height: 1 when collapsed, full_h otherwise.
    pub fn frameHeight(self: ResizeContext, full_h: usize) usize {
        return if (self.is_hidden) 1 else full_h;
    }
};
