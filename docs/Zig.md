---
title: Zig Conventions
weight: 60
---

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

---

## 8. Calling libc `unsetenv()` desyncs `std.process.spawn`'s own `environ` cache

`std.Io.Threaded` (the default `Io` implementation) keeps its own cached
view of `environ` for building a spawned child's env block. Calling libc's
`unsetenv()` directly (e.g. via `extern "c" fn unsetenv(...)`) mutates
libc's copy — and Zig's cache goes stale as a result. The **next**
`std.process.spawn` call then segfaults inside `Environ.createPosixBlock`.

**Corrected mechanism** (an independent review caught the original theory
here was wrong — see "Independent review" in
`issues/58-zig-unsetenv-environ-desync.md` for the full derivation):
`std/start.zig` measures `environ`'s length **once at process startup**
into a fixed-length slice and never re-reads `std.c.environ` afterwards.
glibc's `unsetenv()` does **not** reallocate or free anything here — it
shifts the remaining entries down one slot in place and writes `NULL` one
slot earlier (confirmed directly: the `environ` array's address is
byte-identical before/after). Zig's stale cached *length* then walks one
slot past the real terminator, reading the `NULL` glibc just wrote.
`Environ.PosixBlock.view()` `@ptrCast`s that slot from `?[*:0]const u8` to
`[*:0]const u8`, silently discarding the null-check — which is why the
segfault reports `address 0x0` specifically, not a garbage address.

Separately, `std.debug.print`'s *first* call in a process lazily scans
`environ` to locate self debug-info search paths (for pretty stack
traces), and that scan can **panic** if a var like `LANG` is absent —
which then **deadlocks**, because the panic handler's own attempt to
print the panic message recurses into the same lazy-init path and
re-locks a mutex it's already holding.

The `std.debug.print` panic+deadlock is avoided by one warm-up
`std.debug.print("", .{})` call **before** any `unsetenv()` — that
one-time call is enough to make every *later* `debug.print` call safe too
(verified: a second `debug.print` after `unsetenv`, following the
warm-up, does not panic).

The `std.process.spawn` segfault is **not** fixable this way — there is
no priming call that makes a *later* spawn safe. A spawn issued before
`unsetenv` does not protect a spawn issued after it; both still segfault
identically. The only way to avoid it is to never call
`std.process.spawn` after any `unsetenv()` call anywhere in the process's
lifetime — i.e. do all of a program's spawns first, then treat
`unsetenv()` as one-way:

```zig
runIgnoring(io, &[_][]const u8{ "mkdir", "-p", dir }); // every spawn, before unsetenv
std.debug.print("", .{}); // one warm-up call, before unsetenv — makes later debug.print calls safe
applyUnset(alloc, args.unset); // now safe to call libc unsetenv() — but no more spawns after this
```

Reference: `../fontwidth/canaries/canary_font.zig` (`-unset=` flag, moved
there per [issue 62](../issues/closed/62-move-font-width-experiments-to-fontwidth.md);
note it never spawns again after `applyUnset`); `scripts/zig_unsetenv_bug_repro.zig` is
a minimal, no-application-code reproduction of both failure modes plus the
two experiments above (`print-workaround` succeeds,
`spawn-still-broken-after-print-warmup` and a pre-unset warm-up spawn both
still segfault) — see issues/58-zig-unsetenv-environ-desync.md for the
full writeup. Go's `os.Unsetenv` has no equivalent issue since Go
maintains its own environment consistently.

---

## 9. dlopen'd C libraries with *public* struct fields need the real header — opaque-pointer APIs don't

Cairo/Pango's C API is entirely opaque-pointer-based (every function takes
and returns `void*`-equivalent handles), so `canary_font.zig` (now in
`../fontwidth/canaries/`, see
[issue 62](../issues/closed/62-move-font-width-experiments-to-fontwidth.md))
could safely declare every binding as `?*anyopaque` and never risk a
struct-layout mismatch. `libfcft` (foot's own font-shaping library,
`canary_width_compare.zig`'s column 4, same new location) is different: its structs
(`fcft_glyph`, `fcft_text_run`, `fcft_font`) expose **public fields**
(`.cols`, `.advance.x`, `.count`, …) that calling code reads directly —
guessing that layout instead of transcribing it from the real header
would silently misread real memory rather than fail loudly.

Rule of thumb: before writing `extern struct` bindings for a C library,
check whether its public API is opaque-pointer-only (safe to guess/treat
as `?*anyopaque` throughout) or exposes readable struct fields (get the
real header — install the `-devel`/`-dev` package if needed, e.g. via
`../fontwidth/scripts/install_fcft_dev.sh`'s pattern — and transcribe field
order, types, and nested anonymous structs exactly). The dlopen'd runtime
`.so` itself never requires the header at build or run time either way;
the header is purely for getting the Zig-side struct declaration right.

Reference: `canary_width_compare.zig`'s `FcftGlyph`/`FcftTextRun`
(transcribed from `/usr/include/fcft/fcft.h`, `fcft-devel` package) vs.
`PangoLib`'s all-opaque-pointer function table in the same file (both now
in `../fontwidth/canaries/`).
