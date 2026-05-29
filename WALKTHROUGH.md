# Emojig: Walkthrough & Wayland Integration Guide

This guide explains how to install, configure, and integrate the compiled **Emojig** picker into your Wayland desktop environment (GNOME, Sway, Hyprland).

---

## 1. Project Achievements & Performance

We successfully implemented **Option A (Floating TUI Client)** configured as a premium **6x4 2D Icon Grid** with outstanding metrics:
* **Binary Size**: Only **235 KB** (compiled with `-Doptimize=ReleaseSmall`).
* **RAM Footprint**: Under **700 KB** (RSS = 0.69 MB, Virtual = 3.46 MB) during active operation!
* **Database Size**: The database containing 1,870 emojis is fully compressed, deduplicated, and embedded inside the binary, taking up only 82 KB of data.
* **Layout**: A search input box on top, followed by a beautiful, borderless 6x4 2D icon grid showing the top 24 matches.
* **Controls**:
  * **Fuzzy Typing**: Start typing characters to search in real time.
  * **2D Navigation**: Use arrow keys (`Up`, `Down`, `Left`, `Right`) to move selection in 2D across the grid.
  * **Mouse click**: Click directly on any emoji in the grid to select it!
  * **Action**: Pressing `[Enter]` or clicking an emoji copies it directly to your clipboard using native Wayland `wl-copy` (or `xclip` fallback) and exits.
  * **Exit**: Press `[Escape]` or `[Ctrl+C]` to close without copying.

### Terminal UI Demo (Borderless Mock-up)

Below is a visualization of the interactive 6x4 emoji grid:

```text
🔍 Search: fire
 🧑‍🚒  🚒 █🔥█ 🎆  🧨  🧯 
 👨‍🚒  👩‍🚒  ❤️‍🔥  🇮🇪  🙄  🌓 
 🙄  🙄  🙄  🙄  🙄  🙄 
 🙄  🙄  🙄  🙄  🙄  🙄 
```
> [!NOTE]
> The reverse-video block `█🔥█` indicates the currently highlighted emoji. Navigating using Arrow Keys updates the selection in real-time, and clicking directly on any cell will instantly select and copy that emoji.

---

## 2. Memory Usage & Logging

On close (exit or panic), Emojig reads `/proc/self/statm` using low-level, zero-allocation system calls and logs its resource consumption to `/tmp/emojig.log` with a timestamp:
```text
[1780083139] Emojig closed. Memory Usage: VIRT = 3.46 MB, RSS = 0.69 MB
```

To view your logs:
```bash
cat /tmp/emojig.log
```

---

## 3. Recommended Wayland Launchers

To run the interactive picker as a overlay floating window, run it inside a lightweight, Wayland-native terminal emulator like `foot` or `alacritty`.

### Choice 1: `foot` (Highly Recommended)
`foot` is a Wayland-native terminal emulator that starts in under 15ms.
```bash
foot --app-id=emojig-picker --title="Emoji Picker" --window-size-chars=18x5 zig-out/bin/emojig
```

### Choice 2: `alacritty`
```bash
alacritty --class emojig-picker --title "Emoji Picker" --command zig-out/bin/emojig
```

---

## 4. Desktop Integration & Window Rules (Taskbar Hiding)

To make sure the emoji picker pops up instantly on a hotkey and **does not appear in the taskbar/dock**, configure your compositor/window manager with the following rules:

### A. Sway Config
Add these lines to your `~/.config/sway/config`:
```sway
# Force the emoji picker to float, center, and hide from taskbar
for_window [app_id="emojig-picker"] {
    floating enable
    border pixel 2
    sticky enable
    move position center
    resize set 200 150
}

# Bind a global hotkey (e.g., Mod4 + Period) to launch it
bindsym Mod4+period exec foot --app-id=emojig-picker --title="Emoji Picker" --window-size-chars=18x5 /absolute/path/to/emojig
```

### B. Hyprland Config
Add these lines to your `~/.config/hypr/hyprland.conf`:
```ini
# Window Rules for Emojig
windowrulev2 = float, class:^(emojig-picker)$
windowrulev2 = size 200 150, class:^(emojig-picker)$
windowrulev2 = center, class:^(emojig-picker)$
windowrulev2 = pin, class:^(emojig-picker)$
windowrulev2 = stayfocused, class:^(emojig-picker)$

# Bind hotkey to toggle (Super + Dot)
bind = SUPER, period, exec, foot --app-id=emojig-picker --title="Emoji Picker" --window-size-chars=18x5 /absolute/path/to/emojig
```

### C. Ubuntu GNOME Wayland
GNOME doesn't natively support rule-based window filtering like tiling managers, but you can achieve perfect floating overlay status and taskbar-hiding:
1. **Global Hotkey Setup**:
   * Open **Settings** -> **Keyboard** -> **Keyboard Shortcuts** -> **Custom Shortcuts**.
   * Add a new shortcut named `Emoji Picker`.
   * Set Command to:
     ```bash
     gnome-terminal --class=emojig-picker --geometry=18x5 -- /absolute/path/to/emojig
     ```
   * Set your desired hotkey (e.g., `Super + .`).
2. **Hide from Taskbar & Force Float**:
   * Install the popular GNOME Shell Extension: **[Auto Move Windows](https://extensions.gnome.org/extension/16/auto-move-windows/)** or **[Window Rules](https://extensions.gnome.org/extension/4736/window-rules/)**.
   * Configure a rule targeting the class `emojig-picker` to set it as a **Utility / Floating Dialog** and enable `skip-taskbar`.
