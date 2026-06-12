<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Spec-Driven UI Configuration (`spec/*.json`)

The picker's layout, theme, key bindings, and on-screen text are **not** hardcoded
in the Zig source. They live in four declarative JSON files under `spec/` that are
the single source of truth, shared between the Zig app (`emojig`) and the Go port
(`mojigo`). Edit the JSON, rebuild, and **both** apps change.

```
spec/layout.json   grid dimensions (TUI + GUI), widths, query length, overhead, animation defaults
spec/theme.json    icons, palette color indices (xterm-256), terminal OSC colors
spec/keys.json     logical-key-name -> action bindings
spec/strings.json  search prompt, status bar, help screen text
```

This document records how the Zig app consumes them and the non-obvious things we
learned wiring it up.

---

## 1. What lives where (edit map)

| Want to change…                         | Edit                              | Key(s) |
|-----------------------------------------|-----------------------------------|--------|
| TUI/GUI grid size, content width        | `spec/layout.json`                | `tui`/`gui` `{cols,rows,width}` |
| Vertical overhead, max query length     | `spec/layout.json`                | `layout_overhead`, `max_query_len` |
| Exit-fade in TUI / GUI / both / neither | `spec/layout.json`                | `animation.exit_preview_tui`, `animation.exit_preview_gui` |
| Theme icons (🌙🌞🔆)                     | `spec/theme.json`                 | `icons` |
| Grid/selection/search colors            | `spec/theme.json`                 | `themes.{dark,light}.*` (256-color ints) |
| Terminal bg/fg/border (OSC + GUI window)| `spec/theme.json`                 | `terminal_{bg,fg,border}` (hex) |
| What a key does                         | `spec/keys.json`                  | `bindings.<logical-name>` |
| Search prompt, status bar, help text    | `spec/strings.json`               | see §4 |
| Warning/success text colors             | `spec/theme.json`                 | `themes.{dark,light}.{warning_fg,success_fg}` (256-color ints) |
| Focus lost (startup/runtime) warnings   | `spec/strings.json`               | `focus_lost_startup_lines`, `focus_lost_runtime_lines` |

The compile-time file `src/defaults.zig` is **not** a layout copy anymore — it only
holds spec-independent upper bounds (`MAX_COLS`, `MAX_ROWS`, `MAX_CELLS`,
`MAX_QUERY_LEN`) used to size stack buffers. See §3.

---

## 2. How it's consumed: embed + parse at startup

`src/spec.zig` `@embedFile`s the four JSON files and parses them **once at startup**
into a `Spec`, using a process-lifetime arena (page-allocator backed, never freed —
parsing is off the hot path; the picker render/input loop stays allocation-free).
All renderer/input code reads from a module-level `g_spec`.

We deliberately did **not** use compile-time parsing or build-time codegen:

- **Comptime JSON is impossible in Zig 0.16.** `std.json` allocates via the
  `Allocator` vtable, and vtable calls are *illegal behavior at comptime*
  (`zig build-exe` errors: "use of undefined value here causes illegal behavior").
  Verified directly before committing to an approach.
- **Codegen would be more machinery for no payoff.** Its only real benefit (zero
  runtime cost) is worthless for four tiny files parsed once at launch.

### `@embedFile` cannot cross the module root

The exe's module root is `src/`, so `@embedFile("../spec/x.json")` is rejected. The
files are registered as **anonymous imports** in `build.zig` and embedded by import
name:

```zig
exe.root_module.addAnonymousImport("spec_layout", .{ .root_source_file = b.path("spec/layout.json") });
// …then in src/spec.zig:
const layout_json = @embedFile("spec_layout");
```

### std.json API notes (Zig 0.16)

- `parseFromSliceLeaky(T, allocator, bytes, options)` — the *leaky* variant is right
  here: everything lives in the never-freed arena.
- Pass an explicitly-typed `std.json.ParseOptions{ .ignore_unknown_fields = true }`
  (an anonymous struct literal won't coerce). `ignore_unknown_fields` lets each JSON
  carry a `"description"` key for humans without breaking the struct.
- Dynamic object keys (the `keys.json` bindings) parse cleanly into
  `std.json.ArrayHashMap([]const u8)`; look up with `.map.get(name)`.
- `std.mem.trimLeft`/`trimRight` were renamed to `trimStart`/`trimEnd`.

---

## 3. Comptime bounds vs. runtime layout

Some buffers must be sized at compile time (`[MAX_CELLS]Match`,
`[MAX_COLS][64]u8` cell scratch). The trick: **comptime only needs an upper bound,
not the spec value.** So `src/defaults.zig` defines generous spec-independent
`MAX_*` constants, the actual `cols/rows/width` come from `g_spec.layout` at runtime,
and `main.zig` asserts the runtime layout fits:

```zig
std.debug.assert(cols <= defaults.MAX_COLS);
std.debug.assert(total_cells <= defaults.MAX_CELLS);
```

Raise the `MAX_*` bounds only if a spec grid would ever exceed them.

---

## 4. Keys: bytes → logical name → action

`keys.json` maps **logical** names to actions; it does *not* describe raw bytes —
its own description says decoding bytes into logical names is the input layer's job.
The picker loop therefore:

1. Decodes the raw escape/byte sequence into a logical name
   (`esc`, `up`, `ctrl-c`, `tab`, …). Mouse (SGR `\x1b[<`), Alt+F4, and printable
   text are handled inline, not via bindings.
2. Looks up `g_spec.actionFor(name)` → `quit`/`select`/`delete`/`cycle_theme`/`nav_*`.
3. Dispatches on the action.

A side benefit: the two duplicated arrow-key navigation blocks (CSI `\x1b[A` and SS3
`\x1bOA`) collapsed into a single `navSelect(action, …)` helper.

---

## 5. Strings: status-bar width variants and help pages

The Zig picker renders **two** status bars depending on the rendered content width
(≥35 cols → "wide", else "narrow"); the wide forms carry the extra `e:`/`t:` filter
hints. `mojigo` only renders the narrow form. The help overlay is paged instead of
width-dependent: a query starting with `?` shows the first page (`help_lines`), a
query starting with `??` shows the second page (`help_lines_more`, documenting the
`e:`/`t:` width filters and multi-word AND search) in both apps.

| Field                      | Used by |
|----------------------------|---------|
| `search_prompt`            | both (Zig trims the leading margin space, which mojigo needs for layout) |
| `status_help_hint` / `status_matches` | mojigo + Zig narrow |
| `status_help_hint_wide` / `status_matches_wide` | Zig wide only |
| `help_lines`               | both (help page 1, query `?`) |
| `help_lines_more`          | both (help page 2, query `??`) |

`{count}` in the status templates is substituted with the live match count
(`formatStatus`, which returns the template unchanged when there's no placeholder).
Adding the `*_wide` fields is safe for Go: `encoding/json` ignores unknown fields.

### Focus Warnings

The strings for focus warning screens are also declaratively configured:
- `focus_lost_startup_lines`: Shown on startup when the launcher fails to grab focus (Wayland focus stealing prevention).
- `focus_lost_runtime_lines`: Shown during runtime when focus is lost.

---

## 6. Per-mode animation defaults

The `spec/layout.json` `animation` block controls whether the block-shade
exit-fade animation plays, independently for TUI and GUI:

```json
"animation": {
  "exit_preview_tui": true,
  "exit_preview_gui": true
}
```

| Value | Effect |
|-------|--------|
| both `true` | fade plays in all launch modes (default) |
| `exit_preview_gui: false` | immediate exit in GUI (floating window) mode, fade still plays inline |
| `exit_preview_tui: false` | immediate exit in TUI (inline terminal) mode, fade still plays in GUI |
| both `false` | no fade anywhere — selection triggers an instant clean exit |

### How it propagates

- **TUI path** (`main.zig`): `preview_enabled` falls back to
  `g_spec.layout.animation.exit_preview_tui` when the `EMOJIG_EXIT_PREVIEW`
  env var is absent.
- **GUI path** (`host.zig`): `spawnGuiWindow` injects
  `EMOJIG_EXIT_PREVIEW=1/0` into the child process's environment, derived from
  `spec.layout.animation.exit_preview_gui`. The child (running `--tui` inside
  the spawned terminal window) treats that injected value as an explicit
  override, so the spec GUI default wins over the TUI default.
- **Runtime override still works**: setting `EMOJIG_EXIT_PREVIEW=0` or `=1` in
  the user's environment or shell config overrides the spec regardless of mode.

> [!NOTE]
> The GUI launcher always explicitly sets `EMOJIG_EXIT_PREVIEW` now, even when
> the spec value is `true`. This means a user's ambient `EMOJIG_EXIT_PREVIEW`
> env var will be **shadowed** for GUI launches unless they also update the spec.
> For a per-user override, editing `spec/layout.json` and rebuilding is the
> correct mechanism; `EMOJIG_EXIT_PREVIEW` remains useful for quick one-off
> overrides in TUI mode.

---

## 7. Verifying spec adoption without a human

The TUI renders on `/dev/tty` (the selected emoji goes to stdout — see
`issues/closed/06-vt-copy-paste-and-output-modes.md`), so a piped/redirected stdout
capture is empty by design. Drive it with **tmux** instead:

```sh
tmux new-session -d -s emj -x 80 -y 24 "$(pwd)/zig-out/bin/emojig --tui"
sleep 0.8; tmux send-keys -t emj "cat"; sleep 0.5
tmux capture-pane -t emj -p          # see the 🔍 prompt, 6×4 grid, status bar
```

**JSON-edit proof** (the real "is the spec authoritative?" test): edit
`spec/layout.json` (`cols` 6→4, `rows` 4→3), `zig build`, and the grid renders 4×3 —
no code change. Cross-check `mojigo`: it picks up the same edit because it reads the
same files.

Runtime escape-stream tells too: `\x1b[9A` (height 10 = `rows` 4 + `layout_overhead`
6) and `\x1b]11;#1c1c1c` (terminal bg) both come straight from the JSON.

---

## 8. Dynamic Unfocused Dimming in GUI Mode

To provide a clear visual indication that the floating GUI window is inactive, the entire app dims when focus is lost:
- **Detection**: The render loop checks `!has_focus and gui_spawned`.
- **Faint Escape Sequences**: When loading the theme spec at startup, `buildPalette` creates a dimmed copy of the palette (`dark_palette_dim`, `light_palette_dim`). If dimming is active, the builder appends the SGR code `;2` (faint/dimmed intensity) to the 256-color escape sequences (e.g. `\x1b[38;5;<col>;2m`).
- **Performance**: Pre-building the dimmed palettes at startup preserves zero heap allocations in the hot picker rendering loop.

---

## 9. Files touched

```
build.zig            anonymous imports for the four spec files
src/spec.zig         embed + parse + palette/binding builders; Animation struct; constructs dark_palette_dim and light_palette_dim
src/defaults.zig     reduced to comptime MAX_* bounds
src/term.zig         palettes/icon/colors removed; Palette fields warning_fg and success_fg
src/main.zig         g_spec load; layout/theme/strings/keys consumed; passes !has_focus and gui_spawned to effectivePalette; renders warnings with palette.info_fg
src/root.zig         updated test Strings struct to mirror focus fields
internal/spec/spec.go updated Go structs to mirror new theme and strings fields
spec/layout.json     added animation.{exit_preview_tui,exit_preview_gui}
spec/theme.json      added terminal_border, warning_fg, success_fg
spec/strings.json    added status_*_wide, focus_lost_startup_lines, focus_lost_runtime_lines; help_lines_more (page 2, query "??") later replaced the width-based help_lines_wide
```
