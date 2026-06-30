<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Zig 0.16 API Pitfalls & Patterns

Non-obvious Zig 0.16 API shapes discovered during Emojig development.
Read this before writing any subprocess, pipe, file-descriptor, or process-spawn code in Zig.

---

## 1. Pipes — `std.os.linux.pipe2`, not `std.posix.pipe2`

`std.posix` does **not** expose `pipe2` in Zig 0.16. Use the Linux syscall wrapper:

```zig
var fds: [2]std.posix.fd_t = undefined;
const flags = std.os.linux.O{ .NONBLOCK = true, .CLOEXEC = true };
const rc = std.os.linux.pipe2(&fds, flags);
switch (std.posix.errno(rc)) {
    .SUCCESS => {},
    else => return error.SystemResources,
}
```

Canonical reference in this codebase: `src/tui.zig:setupSelfPipe`.

---

## 2. Spawning a child with stdout redirect — `StdIo.file` needs a `flags` field

To wire a child process's stdout to an existing fd, use `StdIo.file`.
`StdIo.file` is `std.Io.File` (`std/Io/File.zig`), which has **two required fields**:

```zig
var child = try std.process.spawn(io, .{
    .argv  = &argv,
    .stdin = .ignore,
    .stdout = .{ .file = .{
        .handle = pipe_fds[1],
        .flags  = .{ .nonblocking = false },
    }},
    .stderr = .ignore,
});
```

Omitting `flags` gives: `error: missing struct field: flags`.

Close the write end of the pipe **before** reading from the read end, or `read` will block forever waiting for EOF:

```zig
_ = std.posix.system.close(pipe_fds[1]); // close write end in parent
// now read from pipe_fds[0] until EOF
_ = std.posix.system.close(pipe_fds[0]); // close read end when done
_ = child.wait(io) catch {};
```

---

## 3. `close` and `read` — use `std.posix.system.*`

`std.posix.close` and `std.posix.read` do **not** exist in Zig 0.16.
Use the `system` sub-namespace for raw syscall wrappers:

```zig
_ = std.posix.system.close(fd);
```

For `read`, you can use the higher-level `std.posix.read(fd, buf)` which returns `!usize`
and throws on error — or the raw form for non-blocking / ISR contexts:

```zig
const rc: isize = @bitCast(std.posix.system.read(fd, buf.ptr, buf.len));
```

Reference: `src/tui.zig:drainPipe`.

---

## 4. `std.mem.trim` returns `[]const u8`

`std.mem.trim(u8, slice, chars)` always returns `[]const u8` even when `slice` is `[]u8`.
If you need a mutable result, use `@constCast`:

```zig
const trimmed = std.mem.trim(u8, buf[0..total], " \t\n\r'\"");
return @constCast(trimmed); // safe: underlying buf is mutable
```

---

## 5. File permissions — `std.Io.Dir.Permissions`, not a raw mode

In Zig 0.16 `createFile` options use `.permissions` (not `.mode`):

```zig
const f = try std.Io.Dir.createFileAbsolute(io, path, .{
    .permissions = std.Io.Dir.Permissions.fromMode(0o600),
});
```

---

## 6. Error-union peer-type resolution — `[]u8` vs `*const [0:0]u8`

`std.fmt.bufPrint` returns `[]u8`; an empty string literal is `*const [0:0]u8`.
These cannot be peer-resolved in a `catch` expression:

```zig
// ❌ compile error: incompatible types
const s = std.fmt.bufPrint(&buf, "{s}", .{x}) catch "";

// ✓ use an if-expression so both branches are the same type
const s = if (std.fmt.bufPrint(&buf, "{s}", .{x})) |r| r else |_| buf[0..0];
// or just take the length directly
const len = if (std.fmt.bufPrint(&buf, "{s}", .{x})) |r| r.len else |_| 0;
```

---

## 7. `gsettings` floating-point output precision

`gsettings get org.gnome.desktop.interface text-scaling-factor` returns full
IEEE 754 noise: `1.0999999999999999` instead of `1.1`. Parse the first two
decimal digits and round to nearest tenth:

```zig
const d1: usize = if (d + 1 < s.len) (s[d + 1] - '0') else 0;
const d2: usize = if (d + 2 < s.len) (s[d + 2] - '0') else 0;
const frac = if (d2 >= 5) d1 + 1 else d1;
const scale10 = int_part * 10 + frac; // e.g. 11 for 1.1
```

Reference: `src/host.zig:detectCsdSize`.
