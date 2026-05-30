// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub fn main() !void {
    var ts = std.mem.zeroes(std.posix.system.timespec);
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    std.debug.print("Time now from system: {d}\n", .{ts.sec});
}
