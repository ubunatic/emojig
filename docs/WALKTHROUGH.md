# Emojig: Walkthrough & Integration Guide

How to install, run, and integrate emojig in your terminal environment.

---

## 1. Performance

- **Binary size**: ~235 KB (`-Doptimize=ReleaseSmall`)
- **RAM footprint**: < 700 KB RSS during active operation; 0 KB when idle
- **Database**: 1,870 emojis in an 82 KB embedded binary — no data files to install

---

## 2. Controls

| Action | Input |
|--------|-------|
| Filter | Type any characters — fuzzy match updates live |
| Navigate | Arrow keys (2D: up/down move by row, left/right by cell) |
| Select + confirm | Enter or mouse click on a cell |
| Cancel | Escape, Ctrl+C, Ctrl+D |
| Cycle theme | Tab or click the theme icon (🌙 / 🌞 / 🔆) |

On startup: no emoji is preselected, the name row is empty. First arrow keypress selects index 0.

Plural and stem fallbacks apply: `cars` → `car`, `racing` → `race`, `buses` → `bus`.

---

## 3. Running emojig

### Auto-detect mode (recommended)

```sh
emojig
```

- If a Wayland/X11 session is detected: spawns a floating `foot` window
- If running in an interactive terminal with no GUI session: runs inline TUI
- If `TERM=linux` (bare virtual console): prints a diagnostic and exits

### Force TUI mode

```sh
emojig --tui
```

Runs the inline TUI in the current terminal. Useful in SSH sessions or when you want
to capture output via command substitution.

### Force GUI mode

```sh
emojig --gui          # spawn foot window, exit immediately
emojig --gui --wait   # spawn foot window, wait for it to close
```

Requires `foot` and a Wayland or X11 session.

### Stdout capture (fzf-style)

```sh
emoji=$(emojig)
echo "you picked: $emoji"
git commit -m "$emoji fix thing"
emojig | wl-copy
```

The TUI renders on `/dev/tty` so it appears on your terminal even when stdout is piped.
The selected emoji is printed to stdout after the TUI exits.

---

## 4. Shell Integration (Ctrl+E widget)

The recommended way to use emojig day-to-day: bind it to a key so you can invoke it
mid-command and have the picked emoji inserted at the cursor.

### zsh

```zsh
source /path/to/emojig/shell/emojig.zsh
```

Or add to `~/.zshrc`:
```zsh
source ~/.local/share/emojig/shell/emojig.zsh
```

Press **Ctrl+E** at any prompt — the picker opens, pick an emoji, it lands at your cursor.

### bash

```bash
source /path/to/emojig/shell/emojig.bash
```

### fish

```fish
source /path/to/emojig/shell/emojig.fish
```

See `shell/` in the repository for the snippet sources.

---

## 5. GUI / Wayland Integration

`emojig --gui` launches a floating `foot` terminal window sized and styled as a picker.
On first launch it writes a `.desktop` entry and SVG icon to `~/.local/share/` so the
window gets the correct icon in your taskbar.

### Sway

```sway
for_window [app_id="emojig-picker"] floating enable; sticky enable; move position center
bindsym Mod4+period exec emojig --gui
```

### Hyprland

```ini
windowrulev2 = float, class:^(emojig-picker)$
windowrulev2 = center, class:^(emojig-picker)$
windowrulev2 = pin, class:^(emojig-picker)$
bind = SUPER, period, exec, emojig --gui
```

### GNOME

Settings → Keyboard → Custom Shortcuts → add `emojig --gui` with your preferred key.

---

## 6. Theming

```sh
emojig --theme dark     # default: dark cyan selection highlight
emojig --theme light    # light blue highlight, dark text
emojig --theme system   # detect from terminal background colour (OSC 11)
```

Theme is persisted to `~/.config/emojig/config`. Tab-cycling in the TUI also saves it.
`EMOJIG_THEME` env var is also honoured.

---

## 7. Memory Usage

```sh
cat /tmp/emojig.log
# [1780083139] Emojig closed. Memory Usage: VIRT = 3.46 MB, RSS = 0.69 MB
```

---

## Disclaimer

This document may lag behind the code as emojig evolves. The `issues/` directory
contains detailed write-ups for specific topics (VT support, xterm, shell integration,
distribution).
