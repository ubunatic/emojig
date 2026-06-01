<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Linux Desktop Integration & App Icon Compatibility

This document captures the architectural decisions, system learnings, and integration patterns established for Emojig's application launcher (`.desktop`) and icon packaging system on Linux desktop environments.

---

## 1. Overview

To deliver a premium, native-feeling user experience, Emojig supports launching as a floating window (`emojig --gui`) directly from desktop environments (e.g., GNOME, KDE Plasma, XFCE). 

Ensuring that the correct application icon is displayed in the desktop application menu, system dash, and window manager taskbars/docks requires handling several Linux-specific system integration constraints.

---

## 2. Icon Formats & Compatibility (SVG vs. PNG Fallback)

### The Learning
While SVG (Scalable Vector Graphics) is the modern standard for high-DPI desktop assets, its support is highly fragmented across the Linux ecosystem:
* Streamlined Wayland compositors, traditional window managers (e.g., i3, dwm, AwesomeWM), custom docks (e.g., Plank, Tint2), and simple launchers (e.g., Rofi, dmenu) often do not embed SVG rendering engines (such as `librsvg`) or fail to parse SVG assets stored in user-local directories.
* Standard desktop environments (GNOME, KDE) support SVG fully, but rely on the system icon cache to discover them.

### The Solution
We implement a **dual-format installation** strategy that writes both SVG and PNG assets:
* **SVG (Scalable Vector Graphics)**: Placed in the standard scalable directory (`~/.local/share/icons/hicolor/scalable/apps/emojig-picker.svg`) for standard compositors.
* **PNG (Portable Network Graphics)**: Generated as a lightweight, highly compatible **128x128 pixel PNG** (only **8.0 KB**) and written to:
  * The standard hicolor themed app directory: `~/.local/share/icons/hicolor/128x128/apps/emojig-picker.png`
  * A fallback user-local icons directory: `~/.local/share/icons/emojig-picker.png`

This hybrid approach ensures high-DPI crispness on Retina/4K displays while providing robust rendering fallbacks on systems lacking SVG libraries.

---

## 3. Path Resolution: Absolute vs. Theme-Relative Docks

### The Learning
Standard desktop integration suggests referencing icons by their theme name (e.g., `Icon=emojig-picker`). This tells the desktop environment to look up the asset in registered system directories using the XDG Icon Theme Specification.

However, this method frequently fails for user-local applications because:
1. Some custom launchers and minimal window manager docks bypass XDG icon theme resolution completely.
2. Freshly installed icons are not immediately picked up if the user has not refreshed the system icon database.

### The Solution
We specify the **absolute path** to the fallback PNG icon inside the `.desktop` file:
```ini
Icon=/home/username/.local/share/icons/emojig-picker.png
```
By mapping the icon to a fixed, absolute filepath, we completely bypass the complex XDG theme lookup process. Docks and taskbars can resolve the file directly from disk, guaranteeing that the application icon renders correctly on 100% of desktop setups.

---

## 4. Overwriting Busy Executables (`ETXTBSY`)

### The Learning
When installing or updating a binary on Linux (e.g., overwriting `~/.local/bin/emojig` while the picker is running or currently monitored by a dock), writing to the existing file using standard write modes (e.g., `O_WRONLY` with `O_TRUNC`) fails with the OS error **"Text file busy"** (`ETXTBSY`).

### The Solution
We modify the installation script to **unlink (delete)** the target binary first before creating the new one. 
```zig
_ = std.posix.system.unlink(dst_buf[0..dst_path.len :0]);
```
On POSIX systems, unlinking a busy file removes the path name from the directory structure immediately. Active running processes still hold their inode reference in memory, but the directory entry is freed, allowing the installer to successfully write the new executable without errors.

---

## 5. Unconditional Installation Flow

### The Learning
Initially, Emojig only generated `.desktop` entries and icon assets when the user launched the GUI for the first time. This introduced two critical issues:
1. The application was invisible in the desktop's launcher menu immediately after installing via `make install`.
2. Running the tool from a build directory (e.g., during development or `make install gui`) resolved `executablePath` to the temporary build cache (e.g., `.zig-cache/o/.../emojig`), causing the `.desktop` file's `Exec` parameter to reference a path that would break upon running `make clean`.

### The Solution
* **Install-Time Generation**: Emojig's installer (`emojig --install`) proactively triggers `ensureDesktopIntegration`, writing the `.desktop` file and SVG/PNG icon assets immediately upon installation.
* **Canonical Path Fallback**: During generation, the app checks if `exe_path` contains `.zig-cache` or `zig-out` build directories. If a development path is detected, it automatically falls back to mapping the canonical installed binary path (`~/.local/bin/emojig`) for the `Exec` launcher value:
```zig
if (std.mem.indexOf(u8, exe_path, ".zig-cache") != null or std.mem.indexOf(u8, exe_path, "zig-out") != null) {
    exec_path = "/home/username/.local/bin/emojig";
}
```
* **Database Caching**: The installer immediately runs `update-desktop-database` and `gtk-update-icon-cache` in the background to register and display the application immediately:
```zig
// Refreshing launchers and icon theme caches
_ = std.process.spawn(io, .{ .argv = &.{ "update-desktop-database", app_dir }, ... });
_ = std.process.spawn(io, .{ .argv = &.{ "gtk-update-icon-cache", "-f", "-t", icon_dir }, ... });
```
