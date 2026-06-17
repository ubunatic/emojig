<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Advanced Usage

> Back to the main [README](../README.md).

---

## Table of contents

- [CLI reference](#cli-reference)
- [Desktop hotkey](#desktop-hotkey)
- [dmenu-style launchers](#dmenu-style-launchers-rofi--wofi--fuzzel--bemenu)
- [Output modes](#output-modes)
- [Theming & configuration](#theming--configuration)
- [Search tips](#search-tips)
- [Requirements](#requirements)

---

## CLI reference

```sh
emojig                  # auto: floating window (GUI) or inline TUI (terminal)
emojig --tui            # force inline TUI — works over SSH, in VT, anywhere
emojig --gui            # force floating window (foot/kitty/alacritty/…; $EMOJIG_TERMINAL)
emojig --list           # print all emojis as 'emoji<TAB>name' (for rofi/wofi/dmenu)
emojig --install        # install binary + shell scripts to ~/.local/
$(emojig)               # stdout capture — emoji goes to the calling shell
emojig | wl-copy        # pipe to clipboard tool directly
```

### Auto mode (`emojig` without arguments)

- **Interactive terminal** (`isatty` true): launches the TUI in-place.
- **Non-interactive context** (desktop shortcut, hotkey): opens a floating GUI
  window via `--gui`.

### `--gui` terminal selection

The GUI hosts the TUI inside a borderless terminal window. The host terminal is
chosen by precedence:

1. `EMOJIG_TERMINAL` environment variable
2. `$TERMINAL` (if on `PATH`)
3. Auto-detection — `foot` preferred, then `kitty` / `alacritty` / `wezterm` /
   `ghostty` / `konsole` / `gnome-terminal` / `ptyxis` / `xterm`

[`foot`](https://codeberg.org/dnkl/foot) is recommended — it launches
instantly, uses minimal resources, and gives pixel-perfect cell sizing.

### Borderless mode

The window spawns **borderless** (no title bar) by default for a clean popup
look, where the terminal supports it (foot, kitty, alacritty, ghostty, wezterm).

Disable with `--borderless=false` if your compositor needs the decorations to
move the window.

### Single-instance toggle

A second `emojig --gui` while a picker is already running will close the
existing instance and exit — acting as a toggle, ideal for keybinds.

---

## Desktop hotkey

For a system-wide picker, bind a key to emojig. The right path depends on your
desktop — emojig works with whatever you already run.

### Stock desktops (GNOME, KDE, Cinnamon …)

These ship a launcher that can't be piped to, so bind a keyboard shortcut
straight to the floating picker:

- **GNOME** (e.g. Ubuntu): Settings → Keyboard → *Keyboard Shortcuts* → *Custom
  Shortcuts* → add one running `emojig --gui`.
- **KDE Plasma**: System Settings → Shortcuts → *Custom Shortcuts* → command
  `emojig --gui`.

`emojig --gui` opens the picker in a small floating window — via `foot` if
installed, otherwise your detected terminal, or set `EMOJIG_TERMINAL`. Pick an
emoji and it lands on your clipboard.

> [!Tip]
> Inside a terminal you need no hotkey — the **Ctrl+E** shell widget fuzzy-picks
> and drops the emoji right at your cursor.

### dmenu-style launchers (rofi / wofi / fuzzel / bemenu)

Common on tiling WMs (sway, i3, Hyprland). `emojig --list` prints every emoji
as `emoji<TAB>name` with no UI, so you can feed it to the launcher you
**already** run — no new dependency:

```sh
# wofi (Wayland)
emojig --list | wofi --dmenu | cut -f1 | tr -d '\n' | wl-copy

# rofi (X11)
emojig --list | rofi -dmenu -i | cut -f1 | tr -d '\n' | xclip -selection clipboard

# fuzzel (Wayland)
emojig --list | fuzzel --dmenu | cut -f1 | tr -d '\n' | wl-copy
```

`cut -f1` keeps the emoji (the name is only there so you can search for it).
Bind your favourite line to a hotkey. If you *don't* already use such a
launcher, prefer `emojig --gui` — don't install one just to pick emoji.

---

## Output modes

| Context | Behaviour |
|---------|-----------|
| Standalone at prompt | Copy to clipboard (`wl-copy` / `xclip`) |
| Shell widget / `$(emojig)` | Print to stdout + try clipboard |
| `emojig \| cmd` | Pipe to `cmd` |

---

## Theming & configuration

### Theme modes

Dark, light, and system (auto-detected via OSC 11) themes are available.
<kbd>Tab</kbd> toggles in the TUI and saves your choice to
`~/.config/emojig/config`.

Override with `--theme [dark|light|system]` or `EMOJIG_THEME` env var.

### Grid size

The grid size (columns × rows) is configurable via:

- `EMOJIG_COLS` / `EMOJIG_ROWS` env vars
- `cols=` / `rows=` in the config file
- The in-app Settings screen (adjust with arrows, type digits, or click `‹`/`›`)

Changes apply on next launch.

### Scrollbar style

Choose between `expand` (proportional thumb) and `bar` (fixed single-cell `▐`)
via:

- `EMOJIG_SCROLLBAR=expand|bar`
- `scrollbar_style=` in config
- Settings screen toggle

### Optional border

Set `EMOJIG_BORDER=1` or `--border` to draw colored border rows above and below
the content. No box-drawing characters — just background-colored blank lines.

---

## Search tips

- **Multi-term**: separate words with spaces for AND matching (`red heart`).
- **Plurals**: trailing `s` is stripped automatically (`cars` → `car`).
- **Stems**: `-ing` endings try the bare stem and stem + `e` (`racing` → `race`).
- **Query stem**: trailing `e` is retried without it.
- **Width filters**: `e:` restricts to double-width emojis, `t:` to single-width
  text symbols.
- **Box art**: `b:` filters to box-drawing / block characters.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| OS | Linux (x86\_64 or aarch64) |
| GUI mode | Supported terminal + Wayland or X11 session |
| Clipboard | `wl-copy` (Wayland) or `xclip` (X11) — optional |
