# Issue: Silent config file truncation and partial reads due to fixed stack buffers

> [!NOTE]
> **Currency Status:** Current as of May 31, 2026. Details the fixed-size buffer limitation in config file handling for **Emojig v0.1.0**.

## Problem

To satisfy the zero-allocation constraint, the configuration file loader and saver in [src/main.zig](file:///home/uwe/projects/emojig/src/main.zig) bypasses Zig's standard dynamic-allocator-backed file system wrappers. Instead, it reads configuration data directly into a fixed-size stack buffer of `1024` bytes using a single POSIX `read` call:

```zig
// Line 214 in src/main.zig (loadConfig)
var file_buf: [1024]u8 = undefined;
const len = std.posix.read(fd, &file_buf) catch return cfg;
```

Similarly, when saving the theme selection back to the file to persist user preferences:

```zig
// Line 270 in src/main.zig (saveThemeToConfig)
var old_buf: [1024]u8 = undefined;
var old_len: usize = 0;
{
    const rf = std.posix.O{ .ACCMODE = .RDONLY };
    if (std.posix.openat(std.posix.AT.FDCWD, path, rf, 0)) |rfd| {
        old_len = std.posix.read(rfd, &old_buf) catch 0;
        _ = std.posix.system.close(rfd);
    } else |_| {}
}
```

This introduces two distinct, high-impact bugs:

### 1. Silent File Truncation on Theme Save
If the configuration file (`~/.config/emojig/config`) grows beyond `1024` bytes (which can easily happen if a user adds verbose comments, annotations, or unused layout/behavior flags), `saveThemeToConfig` will only read the first `1024` bytes. When it parses and rewrites the file, it will write back **only** the lines it successfully read, permanently truncating and discarding all configurations and comments that were located past the 1024-byte mark.

### 2. Unhandled Partial Reads
The POSIX `read` system call does not guarantee reading the entire file or even the full requested chunk in a single invocation. Although regular files on local filesystems usually read completely in one call, POSIX allows `read` to return fewer bytes than requested (e.g. if interrupted by a signal or under heavy system disk load). By not looping and checking for EOF, `emojig` risks performing a partial read, resulting in missing properties or corrupted config values during start or update.

---

## Fix

We can resolve both issues without violating the zero-heap-allocation architectural constraint by using a larger, safer stack-allocated buffer (e.g., `4096` bytes, matching a typical OS page size) and leveraging Zig's built-in standard library function `std.fs.File.readAll`. 

`readAll` is a zero-allocation utility that reads from the file repeatedly into a pre-allocated slice until EOF is reached, preventing partial reads while preserving full stack allocation constraints.

There are two clean ways to implement this standard library fix:

### Option A: Open with standard stack-allocated functions
Instead of raw POSIX `openat`, we can use `std.fs.openFileAbsolute` which operates entirely on the stack and returns a `std.fs.File`:

```zig
const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
defer file.close();

var file_buf: [4096]u8 = undefined;
const bytes_read = try file.readAll(&file_buf);
```

### Option B: Wrap raw POSIX file descriptor on the stack
If we want to preserve the exact POSIX flags used in the current implementation, we can wrap the raw file descriptor `fd` inside a stack-based `std.fs.File` copy. This operation is free and requires no heap allocations:

```zig
const fd = try std.posix.openat(std.posix.AT.FDCWD, path, flags, 0);
defer _ = std.posix.system.close(fd);

// Zero-allocation stack wrap
const file = std.fs.File{ .handle = fd };

var file_buf: [4096]u8 = undefined;
const bytes_read = try file.readAll(&file_buf);
```

Both options eliminate the need for custom looping logic, leverage heavily tested standard library paths, and guarantee full file safety with absolute zero heap allocations.

**Effort**: Low (requires increasing the buffer size and replacing `std.posix.read` with wrapper/standard file usage).  
**Risk**: None — preserves existing zero-allocation guarantees while using standard, robust file I/O interfaces.
