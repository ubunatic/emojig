---
title: Zig Conventions
weight: 63
---

<!-- harnez:bundled -->
# Zig Conventions

> ⚠️ **Version banner: Zig 0.16.0, verified 2026-07. These APIs move.**
> The conventions in the first section are stable house rules. The API shapes in
> the second section (`pipe2`, `StdIo.file` flags, `Permissions.fromMode`,
> peer-type resolution) are notes from a moving target — they were true against
> 0.16.0 and the compiler, not this page, is the authority. If your compiler
> disagrees, your compiler is right.

> **Who this is for** — anyone writing Zig in these repositories. Reference material: grep it, don't read it.
>
> **Read this if** — you hit a 0.16.0 API that does not look like the docs.
>
> **Takeaways**
> 1. Allocations are always explicit; hot paths allocate nothing.
> 2. Utility binaries ship `-O ReleaseSmall`, under 1 MB, under 5 MB RSS.
> 3. Treat every pinned API shape below as dated evidence, not as doctrine.

---

## Language & Allocation Conventions
- **Explicit Allocation**: Never hide allocations. Pass an `Allocator` explicitly to functions that need to allocate memory.
- **Zero-Allocation Cores**: For hot paths (such as fuzzy search engines or rendering loops), design a zero-allocation core. Prefetch data or use stack-allocated buffers.
- **ReleaseSmall Optimization**: For utility binaries, optimize using `-O ReleaseSmall`. A typical statically linked binary should be under 1 MB and use less than 5 MB of RSS RAM.
- **Clean Namespace Separation**: Avoid monolithic root files. Move helper logic to dedicated files and use `std.testing.refAllDecls(@This())` in your main test blocks to run tests in separated modules.

---

## Zig 0.16.0 API Pitfalls & Patterns

### 1. Pipes — Use `std.os.linux.pipe2` on Linux
In Zig 0.16.0, `std.posix` does not expose `pipe2`. Use the Linux-specific syscall wrapper for non-blocking execution:
```zig
var fds: [2]std.posix.fd_t = undefined;
const flags = std.os.linux.O{ .NONBLOCK = true, .CLOEXEC = true };
const rc = std.os.linux.pipe2(&fds, flags);
switch (std.posix.errno(rc)) {
    .SUCCESS => {},
    else => return error.SystemResources,
}
```

### 2. Spawning Subprocesses with Stdout Redirection
When redirecting standard I/O to a file descriptor using `StdIo.file`, Zig 0.16.0 requires providing a `flags` field:
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
*Note: Close the write end of the pipe in the parent process immediately after spawning, or the read end will block forever on EOF.*

### 3. `close` and `read` — Use `std.posix.system.*`
`std.posix.close` and `std.posix.read` do not exist directly in Zig 0.16. Use `system` sub-namespace for raw syscall wrappers:
```zig
_ = std.posix.system.close(fd);
```

### 4. File Permissions via Permissions Enum
Do not use raw numeric modes (e.g. `0o600`) when creating or modifying files in Zig 0.16.0. Use the `std.fs` types wrapper:
```zig
const file = try std.fs.createFileAbsolute(io, path, .{
    .permissions = std.fs.File.Permissions.fromMode(0o600),
});
```

### 5. Slice vs. Array Pointer Peer-Type Resolution
Constant string literals (e.g., `""`) are of type `*const [0:0]u8`. Standard library formatting tools (like `std.fmt.bufPrint`) return mutable slices (`[]u8`). Peer-type resolution will fail if both are evaluated in a simple `catch` expression:
```zig
// ❌ Compile error: incompatible types
const s = std.fmt.bufPrint(&buf, "{s}", .{val}) catch "";

// ✓ Fix: Use an if-expression to yield identical types
const s = if (std.fmt.bufPrint(&buf, "{s}", .{val})) |res| res else |_| buf[0..0];
```

### 6. `std.mem.trim` Const/Mutable Safety
`std.mem.trim` always returns `[]const u8`. If you are trimming a mutable buffer and require a mutable slice as a result, wrap the returned slice in `@constCast`:
```zig
const trimmed = std.mem.trim(u8, buf[0..len], " \t\n\r");
return @constCast(trimmed); // Safe: the underlying buffer is mutable
```

### 7. `gsettings` Floating-Point Output Precision
`gsettings get org.gnome.desktop.interface text-scaling-factor` returns full IEEE 754 noise (`1.0999999999999999` instead of `1.1`). Parse first two decimal digits and round to nearest tenth:
```zig
const d1: usize = if (d + 1 < s.len) (s[d + 1] - '0') else 0;
const d2: usize = if (d + 2 < s.len) (s[d + 2] - '0') else 0;
const frac = if (d2 >= 5) d1 + 1 else d1;
const scale10 = int_part * 10 + frac; // e.g. 11 for 1.1
```

### 8. Calling libc `unsetenv()` desyncs `std.process.spawn`'s own `environ` cache
`std.Io.Threaded` (default `Io`) caches its view of `environ`. Calling libc's `unsetenv()` directly mutates libc's table while Zig's cache goes stale, causing subsequent `std.process.spawn` calls to segfault.
- Avoid calling `unsetenv()` after `std.process.spawn`. Perform all initial spawns first, then treat `unsetenv()` as one-way.
- Call a warm-up `std.debug.print("", .{})` prior to `unsetenv()` to avoid a lazy debug-info scan deadlock.

### 9. dlopen'd C Libraries with Struct Fields
- When writing `extern struct` bindings for dynamic libraries (e.g. font shaping), if the API exposes public struct fields (e.g. `.cols`, `.advance.x`), transcribe the exact layout from the real C header rather than treating handles as `?*anyopaque`.
- For opaque-pointer C APIs, `?*anyopaque` is safe and eliminates header dependencies.

### 10. `@ptrCast`ing a `dlsym` result to a function pointer needs `@alignCast`, and only fails on some targets
`std.c.dlsym` returns `?*anyopaque`, alignment 1. Casting that straight to a function-pointer field type (`@ptrCast(dlsym(...) orelse ...)`, no `@alignCast`) compiles fine on `x86_64` (function pointers there have alignment 1) but fails with `error: @ptrCast increases pointer alignment` on `aarch64` (function pointers need alignment 4 — ARM instructions are 4-byte aligned). Found in `src/gui/wl_dyn.zig` (issue 070) only when `harnez release` cross-compiled the `aarch64-linux-musl` target — every native `zig build test`/`make preflight` run on `x86_64` stayed green.
- Always `@ptrCast(@alignCast(dlsym(...) orelse ...))` for a dlsym'd **function** pointer, the same as you would for a dlsym'd struct/interface pointer field.
- Native-target-only testing cannot catch this class of bug. If a project ships more than one target, cross-compiling every target (even just a compile, no run) belongs in `make preflight` or CI — not only in the release pipeline.
