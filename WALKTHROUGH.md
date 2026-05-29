# Emojig: Walkthrough & Wayland Integration Guide

This guide explains how to install, configure, and integrate the compiled **Emojig** picker into your Wayland desktop environment (GNOME, Sway, Hyprland).

---

## 1. Project Achievements & Performance

We successfully implemented **Option A (Floating TUI Client)** configured as a premium **6x4 2D Icon Grid** with outstanding metrics:
* **Binary Size**: Only **235 KB** (compiled with `-Doptimize=ReleaseSmall`).
* **RAM Footprint**: Under **700 KB** (RSS = 0.69 MB, Virtual = 3.46 MB) during active operation.
* **Database Size**: The database containing 1,870 emojis is fully compressed, deduplicated, and embedded inside the binary, taking up only 82 KB of data.
* **Layout**: A search input line on top, followed by a beautiful, borderless 6x4 2D icon grid showing the top 24 matches, and a name display row at the bottom.
* **Controls**:
  * **Fuzzy Typing**: Start typing characters to filter in real time. Plural and word-stem fallbacks ensure natural queries match (`cars` → `car`, `racing` → `race`).
  * **2D Navigation**: Use arrow keys (`Up`, `Down`, `Left`, `Right`) to move selection in 2D across the grid. The selected emoji's name is shown on the bottom row.
  * **Mouse Click**: Click directly on any emoji in the grid to select it instantly.
  * **Action**: Pressing `[Enter]` or clicking an emoji copies it to your clipboard via native Wayland `wl-copy` (or `xclip` fallback) and exits.
  * **Exit**: Press `[Escape]` or `[Ctrl+C]` to close without copying.
  * **Startup State**: No emoji is preselected and the bottom name row is empty on launch — the picker starts clean.
  * **Theme Support**:
    * Run in dark mode (default, premium dark cyan selection highlight):
      ```bash
      zig-out/bin/emojig --theme dark
      ```
    * Run in light mode (soft light blue/gray background highlight, dark text prompt):
      ```bash
      zig-out/bin/emojig --theme light
      ```
    * Environment Variable: Fall back to `EMOJIG_THEME` environment variable (e.g., `export EMOJIG_THEME=light`).

### Terminal UI Demo (Borderless Mock-up)

Below is a visualization of the interactive 6x4 emoji grid (the search line is underlined, the cursor blinks after the prompt):

```text
🔍 fire
 🧑‍🚒  🚒 █🔥█ 🎆  🧨  🧯 
 👨‍🚒  👩‍🚒  ❤️‍🔥  🇮🇪  🙄  🌓 
 🙄  🙄  🙄  🙄  🙄  🙄 
 🙄  🙄  🙄  🙄  🙄  🙄 
 fire engine
```

> [!NOTE]
> The `🔍` prompt line is continuously underlined (`\x1b[4m`) with a blinking cursor positioned immediately after the prompt. No emoji is preselected on startup. The dark cyan background block `█🔥█` indicates the currently highlighted emoji in the `dark` theme. In the `light` theme, this is a soft light blue background block with dark text. Navigating with arrow keys updates the selection and shows the emoji name on the bottom row in real time.

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

To run the interactive picker as an overlay floating window, run it inside a lightweight, Wayland-native terminal emulator like `foot` or `alacritty`.

### Choice 1: The Native Build Helper (Highly Recommended)
You can launch the emoji picker inside a custom-sized, floating `foot` terminal natively via the Zig build system:
```bash
zig build picker
```
This launches `foot` with the correct geometry, font size, padding, and cursor blinking enabled.

### Choice 2: Direct `foot` Invocation
```bash
foot --app-id=emojig-picker --title="Emoji Picker" --window-size-chars=40x7 --override=font=monospace:size=14 --override=cursor.blink=yes --override=pad=12x8 zig-out/bin/emojig
```

### Choice 3: `alacritty`
```bash
alacritty --class emojig-picker --title "Emoji Picker" --command zig-out/bin/emojig
```

---

## 4. Desktop Integration & Window Rules (Taskbar Hiding)

To make the emoji picker pop up instantly on a hotkey and **not appear in the taskbar/dock**, configure your compositor/window manager with the following rules:

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
bindsym Mod4+period exec foot --app-id=emojig-picker --title="Emoji Picker" --window-size-chars=40x7 --override=font=monospace:size=14 --override=cursor.blink=yes --override=pad=12x8 /absolute/path/to/emojig
```

### B. Hyprland Config
Add these lines to your `~/.config/hypr/hyprland.conf`:
```ini
# Window Rules for Emojig
windowrulev2 = float, class:^(emojig-picker)$
windowrulev2 = size 450 200, class:^(emojig-picker)$
windowrulev2 = center, class:^(emojig-picker)$
windowrulev2 = pin, class:^(emojig-picker)$
windowrulev2 = stayfocused, class:^(emojig-picker)$

# Bind hotkey to toggle (Super + Dot)
bind = SUPER, period, exec, foot --app-id=emojig-picker --title="Emoji Picker" --window-size-chars=40x7 --override=font=monospace:size=14 --override=cursor.blink=yes --override=pad=12x8 /absolute/path/to/emojig
```

### C. Ubuntu GNOME Wayland
GNOME doesn't natively support rule-based window filtering like tiling managers, but you can achieve perfect floating overlay status and taskbar-hiding:
1. **Global Hotkey Setup**:
   * Open **Settings** → **Keyboard** → **Keyboard Shortcuts** → **Custom Shortcuts**.
   * Add a new shortcut named `Emoji Picker`.
   * Set Command to:
     ```bash
     foot --app-id=emojig-picker --window-size-chars=40x7 --override=font=monospace:size=14 --override=cursor.blink=yes --override=pad=12x8 /absolute/path/to/emojig
     ```
   * Set your desired hotkey (e.g., `Super + .`).
2. **Hide from Taskbar & Force Float**:
   * Install the popular GNOME Shell Extension: **[Auto Move Windows](https://extensions.gnome.org/extension/16/auto-move-windows/)** or **[Window Rules](https://extensions.gnome.org/extension/4736/window-rules/)**.
   * Configure a rule targeting the class `emojig-picker` to set it as a **Utility / Floating Dialog** and enable `skip-taskbar`.
