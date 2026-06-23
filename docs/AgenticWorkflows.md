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

## 4. Large-Scale Zig Refactoring & Core TUI Integrity

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

---

## 5. Input Parsing & Vim Muscle Integration

Developers using terminal tools frequently have deep Vim muscle memory. Forcing a developer to exit using a specific desktop key binding (like standard `Ctrl-C`) when they are used to typing `:q` can cause user frustration.
* **Direct Input Buffer Traversal**: Check for specific command sequences (e.g., `:q`, `:quit`, `/quit`) at the entry of the keyboard input loop.
* **Pre-emptive Interception**: By checking if the input buffer starts with or matches these patterns *before* passing characters to the query search engine, the application can exit immediately with standard return status 0 without rendering false search queries or flashing empty screens.

---

## 6. Programmatic Schema Generation & Resource Validation

Emojig defines a custom 256-color palette spec (`spec/colors.json`) mapping xterm-256 indices to names, shorts, hex values, and description aliases.
* **Schema Generation from Master Specs**: Hardcoding valid values in multiple schemas (e.g., themes and pixel-art definitions) is a maintenance hazard. We solved this by having the color generation tool (`scripts/gen_colors/main.go`) auto-generate `spec/theme.schema.json` and `spec/art.schema.json` using the master colors database. This programmatically embeds valid xterm color names, hex patterns, and short codes into the schemas, ensuring immediate validation using standard JSON Schema tooling.
* **Animation Warn-Once Suppression**: When compiling half-block pixel art frames from PNG images, we verify that every non-transparent pixel maps to an exact color in our schema. If an incompatible color is found, we warn and match to the closest schema color. To avoid flooding stdout with thousands of identical warnings (one per pixel per frame), we maintain a cache of warned colors and alert the developer *only once* per color/animation.

---

## 7. Ecosystem Focus & Complexity Reduction

Historically, the repository contained a concurrent Go-based clone of the picker (`mojigo`).
* **Technical Debt & Focus**: Dual-language implementations of identical interactive behaviors lead to divergence. Differences in search score calculations, layouts, and window metrics crop up over time.
* **Decision**: Deleting `mojigo` to focus 100% of TUI efforts on Zig. This lowered repository lines of code, simplified the build process, and ensured that performance optimization resides solely in the zero-allocation Zig codebase.

---

## 8. PTY Testing & Timing Stability in Async Harnesses

Simulating keyboard/mouse interactions in terminal apps using Unix pseudo-terminals (PTYs) is notoriously timing-sensitive.
* **Coalesced Reads**: If a test harness writes multiple keystrokes (like typing a query and then pressing Enter) in quick succession without a yield, the operating system kernel merges these bytes into a single read event inside the target application's buffer. The application sees this as a single chunk, bypassing distinct state changes (e.g., query typed -> result list updated -> enter pressed).
* **Mitigation**: Introduce short pauses (e.g., 200ms) between keystroke writes to let the application process events and update its internal render tree.
* **Timing Conservatism**: On local fast machines, 100-200ms sleep is usually enough. However, in automated test harnesses (CI/CD, sandboxed tasks, virtualized environments), scheduling drift can delay the TUI renderer. Standardizing on conservative delays (e.g., 300-500ms) during startup and large viewport updates eliminates test flakiness.

---

## 9. Decoupling Development Schema Warnings from TUI Runtime Streams

When loading structured layout specifications or themes (e.g., `spec/theme.json`), properties may trigger validation checks (such as color mapping or xterm-256 color index compatibility).
* **Stderr Pollution**: Printing diagnostic warnings directly to `stderr` during terminal execution is useful for developers running locally. However, if the app is launched via standard scripts or graphical wrappers (e.g., `--gui` or inside a launcher), these warnings pollute standard error and can cause visual corruption or console errors.
* **Logging Delegation**: Separate warnings by build context. During unit testing (`builtin.is_test`), print validations directly to `stderr` for developer visibility. At runtime, write them silently to a diagnostic log file (such as `/tmp/emojig.log` via `term.appendLog`) to ensure production terminal execution streams remain clean.

## 10. Subsequence Matcher Collision Audits

When implementing multi-word alias lists or synonym expansions, subsequence matcher rules can collide.
* **Greedy Character Theft**: The subsequence matching algorithm processes strings left-to-right. A short alias in a prior slot (e.g., `"glass"`) can match characters (like the first `'s'`) intended for a subsequent keyword (e.g., `"sparkling"`), breaking consecutive character bonuses.
* **Tag Isolation**: Keep aliases concise. If an alias causes character theft regressions on primary keywords, move the offending alias to the `tags` list or position it after the primary keyword in the database.


