<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# `--simple` List Mode

`--simple` replaces the default 6×4 emoji grid with an fzf/sk-style flat list:
one `emoji name` row per result, a count row, and a search prompt at the bottom.
Navigation is linear (up/down only). Clipboard and MRU behaviour are unchanged.

Implemented in both `src/main.zig` and `internal/tui/tui.go`; activated via
`--simple` in `cmd/mojigo/main.go`.

---

## Layout

```
  > 😀 grinning face        ← selected row (selection_bg colours)
    😁 beaming face          ← unselected rows (grid_fg)
    😂 face with tears       ←
    ...
  3/1872                     ← count row (status_bg)
> query_                     ← prompt row (search_bg), cursor at end
```

Height: `list_rows + 2` where `list_rows = final_h - 2`.

---

## Cursor repositioning (the critical difference from grid mode)

In grid mode the cursor is parked at the **search bar row**, which sits
`1 + row_off` rows from the top of the TUI. The re-render jump is therefore
`1 + row_off` rows up.

In simple mode the cursor is parked at the **prompt row** — the very last row
of the TUI. The re-render must jump up `last_drawn_h - 1` rows instead.
Using the grid formula here causes each keypress to render at a progressively
wrong position, making navigation appear broken.

Zig (`src/main.zig`):
```zig
const up_rows = if ((exit_preview or final_simple) and last_drawn_h > 1)
    last_drawn_h - 1
else
    @as(usize, @intCast(1 + row_off));
```

Go (`internal/tui/tui.go`): analogous logic in the inline frame emitter.

---

## Zig palette encoding gotcha

`term.Palette.selection_bg` encodes **both** the background and foreground
escape sequences in a single string. `buildPalette` in `src/spec.zig` merges
`PaletteSpec.selection_bg` (optional bg index) and `PaletteSpec.selection_fg`
(fg index) into one combined sequence:

```zig
const sel_bg = if (p.selection_bg) |bg_val|
    try std.fmt.allocPrint(arena, "\x1b[48;5;{d}m\x1b[38;5;{d}m", .{ bg_val, p.selection_fg })
else
    try std.fmt.allocPrint(arena, "\x1b[38;5;{d}m", .{p.selection_fg});
```

There is **no** `palette.selection_fg` field on `term.Palette`. Only reference
fields that exist on the struct (check `src/term.zig`).

---

## Zig iterator: no `peek()`

`std.process.Args.Iterator` (Zig 0.16) has no `.peek()` method. For flags with
optional values, use `--flag=value` syntax parsed with `startsWith`:

```zig
} else if (std.mem.startsWith(u8, arg, "--completion=")) {
    opt_completion_shell = arg["--completion=".len..];
```

Trying to speculatively consume the next arg and "un-consume" it is not possible.
