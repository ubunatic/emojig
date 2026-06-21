// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

extern fn getuid() c_uint;
extern fn getpid() c_int;
extern fn unlink(path: [*:0]const u8) c_int;

pub var global_picker_pid_path: ?[:0]const u8 = null;
pub var global_picker_pid_path_buf: [64]u8 = undefined;

pub fn pickerPidPath(buf: []u8) ?[:0]const u8 {
    const path = std.fmt.bufPrint(buf, "/tmp/emojig-picker-{d}.pid", .{getuid()}) catch return null;
    if (path.len + 1 > buf.len) return null;
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn writePickerPidFile() void {
    const path = pickerPidPath(&global_picker_pid_path_buf) orelse return;
    const wf = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, wf, 0o600) catch return;
    defer _ = std.posix.system.close(fd);
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{getpid()}) catch return;
    _ = std.posix.system.write(fd, pid_str.ptr, pid_str.len);
    global_picker_pid_path = path;
}

pub fn removePickerPidFile() void {
    if (global_picker_pid_path) |path| {
        _ = unlink(path);
        global_picker_pid_path = null;
    }
}

/// If a previously spawned GUI picker is still alive (live PID recorded in
/// the pidfile), terminate it and return true so the launcher exits instead
/// of opening a second window. Stale pidfiles (dead or recycled PID) are
/// removed and ignored.
pub fn toggleRunningPicker() bool {
    var path_buf: [64]u8 = undefined;
    const path = pickerPidPath(&path_buf) orelse return false;
    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, rf, 0) catch return false;
    var pid_buf: [16]u8 = undefined;
    const n = std.posix.system.read(fd, &pid_buf, pid_buf.len);
    _ = std.posix.system.close(fd);
    if (n <= 0) return false;
    const pid_str = std.mem.trim(u8, pid_buf[0..@intCast(n)], &std.ascii.whitespace);
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch return false;
    if (pid <= 1) return false;

    // Guard against PID reuse: the recorded PID must still be an emojig process.
    var proc_buf: [48]u8 = undefined;
    const proc_path = std.fmt.bufPrint(&proc_buf, "/proc/{d}/cmdline", .{pid}) catch return false;
    const pfd = std.posix.openat(std.posix.AT.FDCWD, proc_path, rf, 0) catch {
        _ = unlink(path);
        return false;
    };
    var cmd_buf: [256]u8 = undefined;
    const cn = std.posix.system.read(pfd, &cmd_buf, cmd_buf.len);
    _ = std.posix.system.close(pfd);
    if (cn <= 0 or std.mem.indexOf(u8, cmd_buf[0..@intCast(cn)], "emojig") == null) {
        _ = unlink(path);
        return false;
    }

    std.posix.kill(pid, .TERM) catch return false;
    return true;
}
