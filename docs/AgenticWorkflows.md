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
* **Self-Documentation**: Before context compaction, saving the current state, compiler errors, resolved decisions, and planned tasks in a dedicated tracker file (e.g., [issues/17-custom-commands-and-screens.md](file:///home/uwe/projects/emojig/issues/17-custom-commands-and-screens.md)) ensures the next turn or new agent can resume immediately without duplicate investigation.
* **Preflight Hygiene**: Always run `make preflight` (or license lint, unit tests, and code formatting lints) before concluding tasks to ensure standard repository constraints are preserved.

---

## 4. Large-Scale Zig Refactoring & TUI Timing Stability

### Safely Splitting Monolithic Files
When refactoring large files (e.g., modularizing `src/main.zig`'s 5,000+ lines or `src/root.zig`'s 1,200+ lines), modifying hundreds of call sites is highly error-prone.
* **Forwarding Aliases**: Define aliases and inline forwarding wrappers at the top of the refactored monolithic files (e.g., `const scrollbarThumb = tui_draw.scrollbarThumb;` or `inline fn effectivePalette(...) Palette`). This isolates changes to the file imports without modifying call sites inside massive loops.
* **Separate Test Files in Zig**: Unit tests and benchmarks can be cleanly isolated into a separate test file (e.g. `src/root_test.zig`) by using a forwarding test block in the main file:
  ```zig
  test {
      std.testing.refAllDecls(@This());
      _ = @import("root_test.zig");
  }
  ```
  This forces the compiler to include and run tests defined in the separate file while keeping the library file clean of test blocks.

### Fallback Default Restorations
* **Prompt-to-Grid Keyboard Fallback**: Ensure that keyboard actions (like pressing Enter to `select` on the search screen) preserve original fallback logic such as `selected_idx orelse 0`. If this is refactored to strictly check if `selected_idx` is non-null, keyboard-only/prompt-focused flows will silently break because typing reset the selection index to `null`.

### Timing Stability in PTY Test Harnesses
* TUI test scripts running in programmatic PTYs require conservative sleep intervals (e.g., `300ms` to `500ms` instead of `200ms`) during startup and render transitions to prevent race conditions where `collectAvailable()` reads an empty or incomplete buffer.
