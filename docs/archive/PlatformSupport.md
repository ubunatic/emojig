
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [TerminalIntegration.md](file:///home/uwe/projects/emojig/docs/TerminalIntegration.md)
> - **Extra Content Covered Here:** Terminal compatibility matrices (Tilix, Ptyxis, Alacritty, Foot, Xterm), keyboard shortcuts support, and Wayland/X11 clipboard tool mappings.
> - **Outdated Information:** None.

---
# Linux Platform Support and Market Analysis

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026. Matches the technical requirements and platform compatibility of **Emojig v0.1.5**.

This document provides a technical evaluation of Emojig's platform compatibility, assesses our current addressable Linux desktop market share, and outlines steps to extend support to additional environments.

---

## 1. Platform Compatibility by Mode

Emojig operates in two distinct modes, each with unique system requirements and platform limitations.

### A. Terminal-Only (TUI) Mode
TUI mode runs directly within an interactive shell session.

*   **Requirements**:
    *   An interactive TTY (`/dev/tty`).
    *   A modern terminal emulator with UTF-8 support and unicode emoji display capabilities (e.g., Alacritty, Kitty, Foot, Konsole, GNOME Terminal).
    *   A terminal font that includes emoji glyphs (e.g., Noto Color Emoji, Twemoji).
*   **Limitations**:
    *   **Linux Virtual Console (`TERM=linux`)**: Does not support rendering complex emoji glyphs in the default kernel console font. Emojig exits with a diagnostic error.
*   **Compatibility**: Compatible with virtually all Linux distributions and desktop environments when executed inside a supported terminal window or via SSH.

### B. Graphical (GUI) Mode
GUI mode spawns a temporary floating terminal window to serve the picker as a desktop popup.

*   **Requirements**:
    *   An active Wayland or X11 graphical session (detected via `WAYLAND_DISPLAY` or `DISPLAY` environment variables).
    *   The `foot` terminal emulator installed in the system `PATH`.
    *   `wl-copy` (for Wayland sessions) or `xclip` (for X11 sessions) to enable clipboard pasting.
*   **Limitations**:
    *   **Hardcoded Terminal Spawning**: The GUI picker launcher (`spawnFootWindow` in `src/main.zig`) specifically spawns `foot`.
    *   **Wayland Only**: `foot` is a Wayland-native terminal emulator and does not run under X11 environments. If launched on an X11-only desktop, the application fails to spawn the window.
    *   **Dependency Requirement**: `foot` is not pre-installed by default on major Linux distributions (such as Ubuntu, Fedora Workstation, Debian, or Linux Mint). Users must manually install it to enable GUI functionality.
*   **Compatibility**: Works out of the box only on Wayland-based desktop sessions where the user has manually installed the `foot` package.

---

## 2. Market Share Analysis

### A. General Linux Desktop Market
In 2025/2026, the global Linux desktop market share is estimated at **4.7%** of all desktop operating systems. The ecosystem is highly fragmented but dominated by two primary desktop environments:
1.  **GNOME**: The default desktop environment for Ubuntu and Fedora Workstation. Represents the largest segment of active desktop installations.
2.  **KDE Plasma**: The second most popular desktop environment, favored by power users and standard on distributions like Fedora KDE spin and Arch Linux.
3.  **Cinnamon / XFCE / MATE / LXQt**: Traditional desktop environments that power distributions like Linux Mint and MX Linux. These environments remain highly popular for traditional workflows and low-resource hardware.

### B. Display Server Protocols: Wayland vs. X11
*   **Wayland**: Serving as the default display protocol on most mainstream distributions including Fedora Workstation, Ubuntu Desktop, Debian, and Arch Linux configurations. Studies and surveys indicate that Wayland default adoption covers **50% to 60%** of Linux desktop installations. In developer-centric communities (such as Arch Linux), Wayland usage is reported up to **80%**.
*   **X11**: Currently in maintenance-only mode. However, X11 remains widely used on systems like Linux Mint (Cinnamon is currently X11-only or features experimental Wayland support) and MX Linux (XFCE). It is estimated that **20% to 40%** of Linux desktop users still operate under X11 sessions.

### C. Emojig GUI Market Reach
Due to the multi-terminal spawning capability introduced in v0.1.5:
*   **Theoretical GUI Addressable Market**: Fully compatible with both Wayland and X11 sessions (reaching **100%** of Linux desktop installations).
*   **Practical GUI Addressable Market**: Highly robust, since the application dynamically leverages standard pre-installed terminals (e.g., GNOME Terminal, Ptyxis, Konsole, Alacritty, Kitty, Xterm, Ghostty) and respects the `EMOJIG_TERMINAL` override. Silent failures are completely eliminated.

---

## 3. Recommended Actions & Implementation Status

To expand the addressable user base and ensure GUI mode works across all major Linux desktop environments, the following technical actions were executed:

### A. Implement Multi-Terminal Spawning — **[DONE in v0.1.5]**
The window spawning has been generalized into a robust `spawnGuiWindow` implementation. Instead of hardcoding `foot`, the launcher automatically scans and builds customized arg arrays for:
1.  **Wayland & X11 Hosts**: Supports `foot`, `kitty`, `alacritty`, `wezterm`, `ghostty`, `konsole`, `gnome-terminal`, `ptyxis`, `xfce4-terminal`, and `xterm`.
2.  **Fallback & Overrides**: Respects custom user-configured terminals in `EMOJIG_TERMINAL` and `$TERMINAL` environment variables.

### B. Decouple Terminal Customizations — **[DONE in v0.1.5]**
Terminal-specific styling (such as window decorations, app IDs, overrides, and sizes) has been completely abstracted into HostKind match branches in the new `src/host.zig` module. Clean margins and decorations are disabled where the emulator supports client-side or configuration-level window decoration overrides (foot, kitty, alacritty, ghostty, wezterm).

### C. Support Dedicated Menu Pickers — **[DONE in v0.1.5]**
Direct support for standard dmenu-style tools has been implemented via the `emojig --list` command. Emojig can be piped into wofi, rofi, fuzzel, and dmenu as:
```sh
emojig --list | wofi --dmenu | cut -f1 | tr -d '\n' | wl-copy
```

### D. Package-Level Dependencies — **[DONE in v0.1.5]**
Distro packages generated via nfpm (`.deb` / `.rpm` under `dist/`) specify the recommended terminal and clipboard utility relationships correctly in packaging metadata.
