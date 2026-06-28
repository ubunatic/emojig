<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 34 — Configurable Command Start Characters

**Status:** Closed  
**Priority:** P2

## Problem

Currently, the TUI command autocomplete and execution trigger characters are hardcoded in `src/main.zig` to accept both `:` and `/`:

```zig
const is_cmd_autocomplete = (current_screen == .search and query_len > 0 and (query_buf[0] == ':' or query_buf[0] == '/'));
```

The user wants to reclaim the `:` character for a future, yet-to-be-disclosed feature. As a result, all current `:commands` should be removed, leaving only `/commands` as the default. To achieve this cleanly and maintain flexibility, the command start character(s) should be configurable in `spec/` (e.g., `spec/commands.json`) rather than hardcoded.

## Evidence

- **Hardcoded logic:** `src/main.zig` lines 1689–1690:
  ```zig
  const is_cmd_autocomplete = (current_screen == .search and query_len > 0 and (query_buf[0] == ':' or query_buf[0] == '/'));
  const cmd_prefix: u8 = if (is_cmd_autocomplete) query_buf[0] else ':';
  ```
- **Execution dispatch fallback:** `src/main.zig` line 4331:
  ```zig
  const cmd_query = query_buf[1..query_len];
  ```
  *(Note that this assumes a single-character command prefix)*
- **PTY TUI Simulations:** `scripts/test_tui/main.go` simulates typing `:` commands in multiple places (lines 609 and 766):
  ```go
  master.Write([]byte(":multi"))
  // ...
  master.Write([]byte(":q"))
  ```
- **Configuration Spec:** `spec/commands.json` defines the commands mapping but lacks a way to configure the prefix characters:
  ```json
  {
    "description": "Custom commands mapping. Each command is matched as a prefix of the typed text after ':' and executed on Enter (<cr>).",
    "commands": [ ... ]
  }
  ```

## Suggested Fix

1. **Update `spec/commands.json`:**
   Add a configuration field, e.g., `"cmd_start_chars"` (or `"command_start_chars"`):
   ```json
   {
     "description": "Custom commands mapping...",
     "cmd_start_chars": "/",
     "commands": [ ... ]
   }
   ```
2. **Update `src/spec.zig`:**
   Add `cmd_start_chars: []const u8 = "/"` to the `Commands` struct so the Zig application can read it from the embedded spec.
3. **Refactor command detection in `src/main.zig`:**
   Replace the hardcoded checks with a lookup against the configured `cmd_start_chars`.
   For example, we can check if the first character of the query is present in `g_spec.commands.cmd_start_chars`:
   ```zig
   const is_cmd_autocomplete = (current_screen == .search and query_len > 0 and std.mem.indexOfScalar(u8, g_spec.commands.cmd_start_chars, query_buf[0]) != null);
   ```
4. **Fix PTY tests:**
   Update `scripts/test_tui/main.go` to use the `/` prefix instead of `:`:
   - `:multi` -> `/multi`
   - `:q` -> `/q`

## ✅ Resolution (commit `9df4406`)

All four steps implemented:
- `spec/commands.json` gained `"cmd_start_chars": "/:"` (both `/` and `:` are active).
- `src/spec.zig` `Commands` struct has `cmd_start_chars: []const u8 = "/"`.
- `src/main.zig` uses `std.mem.indexOfScalar(u8, g_spec.commands.cmd_start_chars, query_buf[0])`.
- `scripts/test_tui/main.go` updated: `:multi` → `/multi`, `:q` → `/q`.
