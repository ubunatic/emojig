<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Key Dispatch: Adding New Keyboard Features

Architecture notes and gotchas for adding new key bindings or text-editing
operations to the TUI event loop in `src/main.zig`.

---

## 1. Two-variable dispatch: `name` vs `action`

Every key event produces two strings before reaching the dispatch chain:

| Variable | Source | Example |
|----------|--------|---------|
| `name`   | Escape-sequence decoder in `main.zig` | `"ctrl-left"`, `"del"`, `"f1"` |
| `action` | `g_spec.actionFor(name)` → lookup in `spec/keys.json` | `"nav_left"`, `"delete"`, `""` |

`action` is empty (`""`) for any key not listed in `spec/keys.json`.

**The critical rule**: the `else if (std.mem.startsWith(u8, action, "nav_"))` block
is only entered when `action` starts with `"nav_"`.  A key whose `action` is `""`
never enters this block — even if you place handlers inside it.  Any new key that
does not (or should not) have a `keys.json` entry must be dispatched in a **sibling
`else if`** branch that tests `name` directly:

```zig
} else if (std.mem.startsWith(u8, action, "nav_")) {
    // ... existing grid navigation ...
} else if (std.mem.eql(u8, name, "ctrl-left")) {
    // word-left: must be here, NOT inside the nav_ block above
    if (selected_idx == null)
        query_cursor = wordLeft(query_buf[0..query_len], query_cursor);
} else if (std.mem.eql(u8, name, "ctrl-right")) {
    if (selected_idx == null)
        query_cursor = wordRight(query_buf[0..query_len], query_len, query_cursor);
}
```

Placing a handler inside the `nav_` block for an unbound key is a silent no-op —
the block is never entered, the feature appears broken, and there is no compile or
runtime error.

---

## 2. Escape-sequence decoder locations

Terminal keys arrive as raw byte sequences.  They must be decoded to a logical `name`
string before dispatch.  The decoder lives in the `readKey` / `readInput` section of
`main.zig`.  Two sub-branches handle `\x1b[` (CSI) and `\x1b O` (SS3 / application
cursor mode):

```
\x1b [          →  CSI sequences  →  bytes[2..n] match patterns
\x1b O          →  SS3 sequences  →  bytes[2] character
```

Common additions:

| Key         | CSI form(s)              | SS3 form | Logical name  |
|-------------|--------------------------|----------|---------------|
| Del (fwd)   | `\x1b[3~`                | —        | `"del"`       |
| Ctrl+Right  | `\x1b[1;5C`, `\x1b[5C`  | `\x1bOc` | `"ctrl-right"`|
| Ctrl+Left   | `\x1b[1;5D`, `\x1b[5D`  | `\x1bOd` | `"ctrl-left"` |

Terminals vary.  Emit both CSI and SS3 forms when in doubt — the additional `eql`
checks are free.

---

## 3. `"del"` vs `"delete"`: distinguish forward-delete from backspace/dismiss

`spec/keys.json` maps `"backspace"` → `action = "delete"`.  The `"delete"` action is
also used as a generic dismiss action on non-search screens (settings, help, etc.).
**Do not reuse `"delete"` for the Del (forward-delete) key.**

The Del key must decode to its own logical name (`"del"`) and be handled separately:

```zig
// backspace: uses action == "delete"
// Del key: dispatched on name == "del"
} else if (std.mem.eql(u8, name, "del")) {
    if (query_cursor < query_len) {
        forwardDeleteAtCursor(&query_buf, &query_len, &query_cursor);
        // ... re-search ...
    }
}
```

This ensures Del on a non-search screen does nothing (falls through to the default
case) rather than accidentally dismissing a popup or clearing a field.

---

## 4. Text-editing helpers in `src/tui_draw.zig`

All stateless cursor/buffer manipulation lives in `tui_draw.zig` and is imported
into `main.zig`:

| Function               | What it does                                    |
|------------------------|-------------------------------------------------|
| `deleteAtCursor`       | Backspace: remove byte *before* cursor, decrement cursor |
| `forwardDeleteAtCursor`| Del: remove byte *at* cursor, cursor unchanged  |
| `wordLeft`             | Move cursor to start of previous/current word   |
| `wordRight`            | Move cursor past end of current/next word       |

Word boundaries are defined as space characters (ASCII 0x20).  The semantics follow
readline / bash:

- `wordLeft`: skip trailing spaces backward, then skip non-spaces backward.
  Cursor lands at the start of the word.
- `wordRight`: skip non-spaces forward, then skip spaces forward.
  Cursor lands at the start of the *next* word (or `len` if at the last word).

These operate on the raw byte buffer.  Multi-byte UTF-8 sequences are not split —
any byte that is not 0x20 is treated as a non-space — which is correct for the
space-separated query strings emojig uses.

---

## 5. Focus gates on prompt-level keys

Word movement and character insertion only apply when the **prompt owns focus**
(`selected_idx == null`).  Always guard prompt-editing operations:

```zig
if (selected_idx == null)
    query_cursor = wordLeft(query_buf[0..query_len], query_cursor);
```

Without the guard, pressing Ctrl+Left while a grid cell is highlighted would silently
move the cursor inside the invisible prompt, causing confusing state on the next
keystroke that returns focus to the prompt.
