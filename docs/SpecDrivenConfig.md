<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
description: "All spec/*.json (and spec/input.yaml) fields, embedding pipeline, null-color punch-through contract, and edit map"
---

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
| Vertical overhead, max query length, top padding | `spec/layout.json`                | `layout_overhead`, `max_query_len`, `top_padding` |
| Exit-fade in TUI / GUI / both / neither | `spec/layout.json`                | `animation.exit_preview_tui`, `animation.exit_preview_gui` |
| Theme icons (🌙🌞🔆≡) + hamburger menu icon | `spec/theme.json`               | `icons` |
| Grid/selection/search/margins/layout colors | `spec/theme.json`                 | `themes.{dark,light}.*` (256-color ints / hex) |
| Color *names* (`grn`, `orange`, hex map)| `spec/colors.json` (generated)    | regenerate with `make gen-colors`; see §9 |
| Terminal bg/fg/border (OSC + GUI window)| `spec/theme.json`                 | `terminal_{bg,fg,border}` (hex) |
| Raw byte sequence → logical key name    | `spec/input.yaml` (→ gen-input)   | `input.key_sequences[].{seq,name}` — add terminal variants here; see §4 |
| Mouse encoding (masks, enable seqs)     | `spec/input.yaml`                 | `input.mouse.*` |
| What a key does                         | `spec/keys.json`                  | `bindings.<logical-name>` |
| Command start chars (`:` vs `/`)        | `spec/commands.json`              | `cmd_start_chars` |
| Search prompt, status bar, help text, scrollbar char | `spec/strings.json`               | see §5, `scrollbar_char` |
| Toolbar separator char (between theme/menu icons) | `spec/strings.json`             | `toolbar_sep` (must be exactly 1 display cell) |
| Pane separator hline character                 | `spec/strings.json`               | `hline_char` (custom separator line glyph) |
| Container/controls backgrounds, margins, separators, caps | `spec/theme.json` | `app_bg`, `view_bg`, `search_{left,right}_cap_{fg,bg}`, `search_sep_fg`, `hline_fg`, etc. (see §13) |
| Search bar text area fg colors (cursor, text, placeholder) | `spec/theme.json` | `search_cursor_fg`, `search_text_fg`, `search_placeholder_fg` (see §13) |
| Search bar per-segment sep char and colors | `spec/theme.json` + `spec/strings.json` | `search_theme_sep_{fg,bg}`, `theme_settings_sep_{fg,bg}`; chars `search_theme_sep`, `theme_settings_sep` (see §13) |
| Search bar left/right cap character | `spec/strings.json` | `search_left_cap`, `search_right_cap` (default `▌`/`▐`, must be exactly 1 display cell) |
| Named inline styles for templates       | `spec/styles.json`                | see §10 |
| Warning/success text colors             | `spec/theme.json`                 | `themes.{dark,light}.{warning_fg,success_fg}` (256-color ints) |
| Focus lost (startup/runtime) warnings   | `spec/strings.json`               | `focus_lost_startup_lines`, `focus_lost_runtime_lines` |
| Category switcher bar layout            | `spec/categories.json`            | see §11 |
| Category synonyms / search keywords     | `spec/categories.json`            | `categories[].synonyms` |

The compile-time file `src/defaults.zig` is **not** a layout copy anymore — it only
holds spec-independent upper bounds (`MAX_COLS`, `MAX_ROWS`, `MAX_CELLS`,
`MAX_QUERY_LEN`) used to size stack buffers. See §3.

---

## 2. How it's consumed: embed + parse at startup

`src/spec.zig` `@embedFile`s the spec JSON files and parses them **once at startup**
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

### User-configurable grid size (`cols`/`rows`)

The `spec/layout.json` `cols`/`rows` are *defaults*. The end user overrides them
per machine via `~/.config/emojig/config` (`cols=`/`rows=`) or the **Settings**
screen ("grid width (cols)" / "grid height (rows)" rows — Left/Right adjust ±1,
Space/Enter steps coarsely). Both axes are clamped to `[MIN_COLS, MAX_COLS]` /
`[MIN_ROWS, MAX_ROWS]` on load: the MAX keeps the comptime buffers in bounds, and
the **minimum 5×3** is enforced even when a config/env value is smaller, so a
misconfigured tiny grid can never reach the renderer.

Resolution order per axis: `EMOJIG_COLS`/`EMOJIG_ROWS` env → config → spec
default. The GUI launcher (`--gui`) resolves the same value and sizes the foot
window to it (`content_width = cols*4 + 1`), then passes `EMOJIG_COLS/ROWS` to
the child `--tui` so the picker grid matches the window exactly — one size for
GUI and TUI, because users work on one screen. A settings edit persists to
config and takes effect on the **next launch**; the live grid keeps its launch
dimensions because mid-session grid resizing is unsafe for inline-TUI scrollback
reservation (the terminal-state-safety rule in `AGENTS.md`).

---

## 4. Keys: bytes → logical name → action

The picker loop has **two spec layers** for keyboard input:

### Layer 1 — raw bytes → logical name (`spec/input.yaml`)

`spec/input.yaml` `input.key_sequences` is a flat ordered array of `{seq, name}`
pairs. `input.decodeEscapeKeySpec(bytes, g_spec.input.key_sequences)` linearly scans
it and returns the first matching name. There is **no hardcoded fallback**: all
terminal variants (CSI, SS3, rxvt alternates, XTerm modifyOtherKeys, Kitty protocol)
must be listed in the YAML.

```yaml
key_sequences:
  - seq: "\x1b[A"    # CSI
    name: up
  - seq: "\x1bOA"    # SS3 / application mode
    name: up
```

The YAML is compiled to `spec/input.generated.json` by
`go run ./scripts/gen_input_spec/` and embedded via `build.zig`:

```zig
exe.root_module.addAnonymousImport("spec_input_generated",
    .{ .root_source_file = b.path("spec/input.generated.json") });
```

`spec/input.yaml` also carries the mouse encoding spec (`mouse.enable_motion`,
`mouse.btn_button_mask`, `mouse.btn_motion_flag`, …) and tokenizer rules.

### Layer 2 — logical name → action (`spec/keys.json`)

`keys.json` maps logical names to semantic actions (`quit`, `select`, `delete`,
`cycle_theme`, `nav_*`). `g_spec.actionFor(name)` returns `""` for unbound keys.
The dispatcher branches on `action` first, then on `name` for keys that intentionally
have no binding (see [KeyDispatch.md](KeyDispatch.md)).

The two steps combined:

```
raw bytes
  → decodeEscapeKeySpec(bytes, g_spec.input.key_sequences)  → name
  → g_spec.actionFor(name)                                  → action
  → dispatch
```

A side benefit: the two duplicated arrow-key navigation blocks (CSI `\x1b[A` and SS3
`\x1bOA`) collapsed into a single `navSelect(action, …)` helper, because both now
produce `name="up"` from the spec table.

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
| `scrollbar_char`           | both (Scrollbar thumb character, default ▐) |
| `toolbar_sep`              | Zig only (separator between toolbar icons, default `" "`, must be 1 display cell) |
| `hline_char`               | Zig only (horizontal separator line character, default `"─"`) |

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

## 9. Named colors (`spec/colors.json`)

Any color value in a spec — `multi_select_bg` in `strings.json`, the `bg=`/`fg=`
attributes in `styles.json`, etc. — accepts a **name**, not just a 0-255 palette
index. The names are documented in `spec/colors.json`, one entry per xterm slot:

```json
{ "i": 208, "name": "orange", "short": "org", "hex": "#ff8700", "desc": "orange",
  "alt": ["rgb520"] }
```

- **`name`** — long name. System colors 0-15 (`black`, `maroon`, `green`, …) and a
  curated set of popular colors (`orange`=208, `teal`, `forest`, `navy`, `skyblue`,
  `crimson`, `slate`, …) get friendly names; everything else gets a systematic
  `rgbRGB` name where `R`/`G`/`B` are the cube level digits 0-5 (the six levels are
  `0,95,135,175,215,255`), and grays are `gray0`-`gray23`.
- **`short`** — a 3-letter alias (`grn`, `blu`, `blk`, `org`, `fst`…) for quick typing.
- **`alt`** — extra aliases; renamed cube slots keep their systematic `rgbRGB` name
  reachable here.
- **`hex`/`desc`** — documentation only (hex value + human color family like
  "dark green"); not used for resolution.

### Generation

`spec/colors.json` is **generated**, never hand-edited — run `make gen-colors`
(`go run ./scripts/gen_colors/`, stdlib-only). The generator owns the system-color
table, the popular-name overrides, the cube/gray math (hex), and an HSV-based
`desc` classifier. To rename a color or add a popular alias, edit
`scripts/gen_colors/main.go` and regenerate. Rebuild (`zig build`) afterwards
since the JSON is `@embedFile`'d (registered as `spec_colors` in `build.zig`, like
the other specs — see §2).

### Resolution path (Zig)

`spec.ColorsSpec.indexOf(name)` linear-scans the parsed entries (name → short →
alt), **first match wins** so the lowest index resolves on collision. In
`main.zig` every color value flows through `appendBgCodes`/`appendFgCodes`:

1. the **8 basic ANSI names** (`colorNameToBasic`) keep the compact `3X`/`4X`
   form — so existing `theme.json` behavior is byte-identical;
2. otherwise `colorNameToIndex` consults `spec.ColorsSpec.indexOf`, then falls
   back to `std.fmt.parseInt` (a literal numeric index);
3. the resulting index emits via `appendIndexedColor`: `3X`/`4X` for 0-7,
   `9X`/`10X` for 8-15, else the extended `38;5;N` / `48;5;N`.

The lookup is guarded by a module-level `g_colors: ?*const ColorsSpec` set after
`g_spec` loads, so the color helpers are safe to call before the spec is parsed
and in unit tests that never load it (it just returns `null` → numeric fallback).

> The 256 entries are parsed into the startup arena (~10 KB) — fine against the
> RSS budget, and off the hot path (color names resolve at config/render time,
> never per emoji cell). The Go `mojigo` port ignores `colors.json` (unknown spec
> file); the name system is a Zig-app feature.

## 10. Named styles and the `$fmtvars` template system (`spec/styles.json`)

`spec/styles.json` defines **named SGR style aliases** used by any string field that
accepts `$fmtvars` syntax (status-bar templates, switcher patterns, etc.):

```json
{
  "styles": {
    "primary": "bold,fg=white,bg=24",
    "dim":     "fg=240"
  }
}
```

### `$fmtvars` syntax (in string fields)

| Pattern | Meaning |
|---------|---------|
| `$name{text}` | apply named style from `styles.json` around `text`, then reset |
| `$[attrs]{text}` | apply inline attrs (see below) around `text`, then reset |
| `{count}` | substituted with the live match count (status templates only) |
| `{search_bg}` | substituted with the current search-bar SGR bg escape |
| `{icon}` | substituted with the slot icon (switcher `hl_pattern`/`select_pattern`) |

After the styled span the renderer emits `\x1b[0m` + the ambient background
(`search_bg` or `status_bg`) so subsequent text is unaffected.

### Attrs string format

Attrs are comma-separated tokens resolved by `color.buildSgr()`:

| Token | SGR effect |
|-------|------------|
| `bold` | SGR 1 |
| `dim` / `faint` | SGR 2 |
| `italic` | SGR 3 |
| `underline` | SGR 4 |
| `reverse` | SGR 7 |
| `fg=<color>` | foreground — color name, short, or 0-255 index |
| `bg=<color>` | background — same |

Color names resolve via `spec/colors.json` (§9): `fg=white`, `fg=24`, `fg=grn`,
`fg=orange` all work.

### Special value `"none"` (switcher patterns only)

In `spec/categories.json` `select_pattern`/`hl_pattern`, the value `"none"` means
*use `status_bg` — no highlight at all*. Useful when visual selection is conveyed
by bracket chars (`select_left`/`select_right`) rather than a bg color change.

---

## 11. Category switcher bar (`spec/categories.json`)

The switcher is a single row rendered below the emoji grid (visible in `--gui` mode
by default; toggle with `--switcher` / `EMOJIG_SWITCHER`). Its layout and appearance
are fully declarative.

### Slot geometry

Every slot is: **`pad_left` (1 col) + icon (2 cols) = `sw_slot_w` cols**.

- **Slot 0**: "All" (no category filter), icon from `all_icon`
- **Slots 1..n**: the categories where `"switcher": true`

Total row width = `row_pad_left + n_slots × sw_slot_w + fill + row_pad_right`.
This must stay ≤ `content_width` (`cols × 4 + 1`). With the default 8-col grid,
`content_width = 33`. Default `pad_left = " "` → `sw_slot_w = 3` → 10 slots × 3 = 30 ≤ 33.

### Prefix-theft — adding brackets without changing row width

`select_left` / `select_right` (and `hl_left` / `hl_right` for hover) replace
`pad_left` for the **active slot** and the **slot immediately after** it. Because
the "stolen" right bracket occupies the neighbor's `pad_left` column, total width is
unchanged — the same trick as `cursor_left` / `cursor_right` in the emoji grid.

**Width constraint**: `select_left.len == select_right.len == pad_left.len` (all
exactly 1 display col). E.g. `pad_left=" "`, `select_left="["`, `select_right="]"`.

### Highlight scope

| `select_scope` / `hl_scope` | What gets the bg color |
|-----------------------------|------------------------|
| `"all"` (default) | `left + icon + right` — the right bracket (in the next slot) also gets the highlight bg |
| `"icon"` | The 2-col icon only; left/right stay in `status_bg` |

When a slot is **both** active and hovered, hover wins for the bg color
(brackets already communicate active state visually).

### Complete field reference

| Field | Default | Description |
|-------|---------|-------------|
| `row_pad_left` | `""` | Text written before the first slot in `status_bg` (outer left margin) |
| `row_pad_right` | `""` | Text written after the fill in `status_bg` (outer right margin) |
| `all_icon` | `"✱ "` | Icon for the All slot — must be **exactly 2 display cols** (1-wide char + space, or a 2-wide emoji) |
| `pad_left` | `" "` | Normal slot prefix — 1 display col |
| `select_left` | `""` | Replaces `pad_left` on the active slot |
| `select_right` | `""` | Replaces `pad_left` on the slot after the active one |
| `select_scope` | `"all"` | How far the active bg color extends: `"all"` or `"icon"` |
| `hl_left` | `""` | Replaces `pad_left` on the hovered slot |
| `hl_right` | `""` | Replaces `pad_left` on the slot after the hovered one |
| `hl_scope` | `"all"` | Same as `select_scope` but for hover |
| `hl_pattern` | `""` | $fmtvars attrs for hovered-slot bg; `""` = `palette.selection_bg`; `"none"` = `status_bg` |
| `select_pattern` | `""` | $fmtvars attrs for active-slot bg; same sentinel values |
| `categories` | — | Array of `{name, short, icon, switcher, synonyms}` entries |

### Example — bracket selection, color hover

```json
"pad_left":       " ",
"select_left":    "[",
"select_right":   "]",
"select_scope":   "icon",
"select_pattern": "none",
"hl_scope":       "all",
"hl_pattern":     ""
```

Result: active slot shows `[icon]` in `status_bg` (brackets only, no color change);
hovered slot highlights the whole bracket group in `palette.selection_bg`.

---

## 13. Container/Controls Palette Fields

All layout cell colors are semantic theme variables in `spec/theme.json`, resolved in `buildPalette` (`src/spec.zig`). The key fallback rule: **`null` = use `cap_fallback_idx`** (= `app_bg` if set, else the nearest xterm-256 index to `terminal_bg2`). This is the "punch-through" semantics — a null color lets the canvas background show through the search bar.

### Layout background fields

| Field | Fallback | Effect |
|-------|----------|--------|
| `app_bg` | terminal bg | Canvas: margins, blank rows, borders |
| `app_topline_bg` | `border_bg` → `app_bg` | First row (top padding / top border) |
| `emoji_pane_bg` | `app_bg` | Emoji grid viewport |
| `scrollbar_rail_bg` | `app_bg` | Scrollbar track column |
| `view_bg` | `app_bg` | Help / about / settings / categories panes |
| `hline_fg` | `240` | Foreground of horizontal separator lines (`─`) |

### Search bar cap fields

Caps (`▌` left, `▐` right) are the half-block characters at the edges of the search bar. Their glyph comes from `spec/strings.json` (`search_left_cap` / `search_right_cap`, default `▌`/`▐`, each must be exactly 1 display cell); the color from `spec/theme.json`:

| Field | Fallback | Effect |
|-------|----------|--------|
| `search_left_cap_fg` | `cap_fallback_idx` | Left cap foreground — set to app bg to blend into canvas |
| `search_left_cap_bg` | `search_bg` | Left cap background |
| `search_right_cap_fg` | `cap_fallback_idx` | Right cap foreground — set to app bg to blend into canvas |
| `search_right_cap_bg` | `search_bg` | Right cap background |

`cap_fallback_idx` = `app_bg` index if configured, else closest xterm-256 to `terminal_bg2`. This makes null fg "show through" to the canvas — correct for the half-block blend illusion.

### Search bar separator fields

The toolbar has two separator slots: **search↔theme-icon** (`search_theme_sep`) and **theme-icon↔settings-menu** (`theme_settings_sep`). Both the glyph and the colors are configurable:

| Spec file | Field | Fallback | Effect |
|-----------|-------|----------|--------|
| `strings.json` | `search_theme_sep` | `toolbar_sep` | Glyph between search area and theme icon |
| `strings.json` | `theme_settings_sep` | `toolbar_sep` | Glyph between theme icon and menu icon |
| `theme.json` | `search_theme_sep_fg` | `search_sep_fg` → `cap_fallback_idx` | Sep fg (null = app bg "punch-through") |
| `theme.json` | `search_theme_sep_bg` | `cap_fallback_idx` | Sep bg (null = app bg, creating a gap) |
| `theme.json` | `theme_settings_sep_fg` | `search_sep_fg` → `cap_fallback_idx` | Sep fg |
| `theme.json` | `theme_settings_sep_bg` | `cap_fallback_idx` | Sep bg |
| `theme.json` | `search_sep_fg` | — | Shared fg override for all sep segments |

**Critical pitfall**: the null fallback for sep fg and bg is `cap_fallback_idx` (app bg), NOT `search_bg`. Setting both to null produces a "slot" in the search bar showing the canvas color, matching the visual behaviour of the caps. Setting sep bg to `search_bg` and sep fg to null gives app-bg-colored text on search-bar-bg — a visible hairline.

### Search bar text area fields

| Field | Fallback | Effect |
|-------|----------|--------|
| `search_cursor_fg` | — (inherit from `search_bg` fg) | Cursor and text fg when query is empty |
| `search_text_fg` | `search_cursor_fg` | Query text fg when query is non-empty |
| `search_placeholder_fg` | `search_cursor_fg` → `grid_fg` | Placeholder text fg ("search…") |

### Schema Validation

If a theme hex color (e.g. `terminal_bg2: "#2c2c2c"`) has no exact xterm-256 match, `buildPalette` maps it to the closest index. In unit tests the mismatch prints to stderr; at runtime it logs silently to `/tmp/emojig.log`.


---

## 12. Files touched

```
build.zig               anonymous imports for all spec files (incl. spec_colors, spec_categories, spec_styles)
src/spec.zig            embed + parse all specs; palette/binding builders; Animation struct;
                        dark_palette_dim/light_palette_dim; ColorsSpec.indexOf(); CategoriesSpec re-export
src/root.zig            CategoriesSpec + CategorySpec structs (source of truth)
src/color.zig           buildSgr(buf, attrs, styles): resolves $fmtvars attrs → SGR escape
src/tui_draw.zig        expandTemplate / expandTemplateIcon: $fmtvars substitution including {icon}
src/main.zig            switcher bar renderer (swRenderSlot, prefix-theft, scope logic);
                        g_spec load; g_colors + colorNameToIndex/appendIndexedColor;
                        switcher_cat_idx, switcher_hover_idx, switcher_row_hovered state;
                        GUI font size: gui_font_size from EMOJIG_GUI_FONT_SIZE env / cfg.font_size
src/config.zig          font_size: ?usize field; parsed from config key font_size=
src/host.zig            spawnGuiWindow takes font_size: usize; --override=font=monospace:size={d};
                        --override=csd.preferred=none; --override=pad=0x4
src/defaults.zig        comptime MAX_* bounds only
src/term.zig            Palette fields: search_{left,right}_cap_seq (color-only, no glyph); search_theme_sep;
                        theme_settings_sep; search_{cursor,text,placeholder}_fg; toolbar_sep_fg; hline
scripts/gen_colors/     generates spec/colors.json (make gen-colors); see §9
spec/colors.json        generated full xterm-256 palette with name/short/hex/desc/alt
spec/categories.json    category switcher bar layout + category synonyms; see §11
spec/styles.json        named SGR style aliases for $fmtvars templates; see §10
spec/layout.json        animation.{exit_preview_tui,exit_preview_gui}
spec/theme.json         terminal_border, warning_fg, success_fg; icons.menu; terminal_bg2 (cap_fallback source);
                        search_{left,right}_cap_{fg,bg}; search_{cursor,text,placeholder}_fg;
                        search_theme_sep_{fg,bg}; theme_settings_sep_{fg,bg}; search_sep_fg
spec/strings.json       status_*_wide, focus_lost_*_lines, help_lines_more, on_grid_wide (Tab:cat hint); toolbar_sep;
                        search_left_cap, search_right_cap (cap glyphs, 1 cell each);
                        search_theme_sep, theme_settings_sep (sep glyphs, fallback to toolbar_sep)
internal/spec/spec.go   Go structs mirror theme and strings fields
```
