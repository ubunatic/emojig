<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Agentic Workflows & Zig/TUI Development Learnings

This document summarizes critical learnings, API changes, TUI simulation testing pitfalls, and agentic workflow strategies acquired during the development of Emojig's custom screens and commands.

---

## 1. Zig 0.16.0 API & Type System Insights

### Standard Library File Permissions
In older Zig versions, file creation options like `std.Io.Dir.CreateFileOptions` allowed specifying permissions via a raw POSIX mode field (e.g. `.mode = 0o600`).
* In **Zig 0.16.0**, the field is named `permissions`.
* It takes a `std.Io.Dir.Permissions` (which is an alias for `std.Io.File.Permissions`) enum.
* To create a file with strict permissions (e.g., `-rw-------` or `0o600`), use:
  ```zig
  if (std.Io.Dir.createFileAbsolute(io, path, .{
      .permissions = std.Io.Dir.Permissions.fromMode(0o600)
  })) |wfile| { ... }
  ```

### Error Union Peer-Type Resolution (Slices vs. Array Pointers)
A common helper pattern in Zig is formatting strings into a local buffer:
```zig
query_len = (std.fmt.bufPrint(&query_buf, "c:{s} ", .{cat.short}) catch "").len;
```
This fails to compile with an incompatible types error (`[]u8` vs `*const [0:0]u8`) because:
1. `std.fmt.bufPrint` returns a mutable slice (`[]u8`) referring to the input buffer.
2. the constant string literal `""` is a pointer to an immutable array (`*const [0:0]u8`).
3. Under Zig's coercion rules, a constant string literal cannot coerce to a mutable slice since it points to read-only data.
4. When calling `.len` immediately on the `catch` result without an intermediate assignment, Zig tries to perform peer-type resolution directly on the two operands of `catch` without target coercion guidance, which fails.

**Mitigation**: Use a clean, type-safe inline `if` expression instead:
```zig
query_len = if (std.fmt.bufPrint(&query_buf, "c:{s} ", .{cat.short})) |res| res.len else |_| 0;
```
This ensures both branches evaluate directly to `usize` values (which match perfectly), bypassing slice/pointer-to-array coercion rules entirely.

---

## 2. TUI Simulation & PTY Testing Insights

### Coalescence of Written Bytes in PTYs
When writing test scripts that simulate terminal interaction using a PTY, writing the command query and the trailing Enter keypress in a single buffer write (e.g., `master.Write([]byte(":multi\n"))`) can lead to unexpected failures.
* **Problem**: The operating system reads the coalesced byte array in a single `read()` call. The TUI application's event loop parses the input buffer as text query characters rather than distinct keypress sequences, which leads to the control characters (like `\n`) being treated as printable characters (and ignored) or corrupting state.
* **Mitigation**: Always split query entry and action keypresses (like Enter or Shift-Enter) into separate master PTY write calls, separated by a brief rendering delay:
  ```go
  // Type query string
  master.Write([]byte(":multi"))
  time.Sleep(200 * time.Millisecond)

  // Send execution keypress
  master.Write([]byte("\n"))
  ```

---

## 3. Agentic Workflow Strategy

### Recovery from Context Compaction
When an agent experiences memory/context compaction, it loses fine-grained history.
* **Self-Documentation**: Before compaction, saving the current state, compiler errors, resolved decisions, and planned tasks in a dedicated tracker file (e.g., [issues/17-custom-commands-and-screens.md](file:///home/uwe/projects/emojig/issues/17-custom-commands-and-screens.md)) ensures the next turn or new agent can resume immediately without duplicate investigation.
* **Preflight Hygiene**: Always run `make preflight` (or license lint, unit tests, and code formatting lints) before concluding tasks to ensure standard repository constraints are preserved.
