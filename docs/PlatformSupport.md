# Linux Platform Support and Market Analysis

> [!NOTE]
> **Currency Status:** Current as of May 31, 2026. Matches the technical requirements and platform compatibility of **Emojig v0.1.0**.

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
Due to the hardcoded dependency on `foot` for the floating window:
*   **Theoretical GUI Addressable Market**: Limited to Wayland users (approximately **50% to 80%** of Linux installations).
*   **Practical GUI Addressable Market**: Less than **5%** of users, as `foot` is rarely pre-installed on GNOME or KDE Plasma installations, and the app fails silently or exits with a launcher error if `foot` is missing or the session is X11-only.

---

## 3. Recommended Actions to Broaden Support

To expand the addressable user base and ensure GUI mode works across all major Linux desktop environments, the following technical actions are recommended:

### A. Implement Multi-Terminal Spawning (Short-Term)
Modify `spawnFootWindow` to become a more generic `spawnGuiWindow` function. Instead of hardcoding `foot`, the launcher should detect available terminals and use configuration parameters matched to each:
1.  **Wayland Fallbacks**:
    *   If `foot` is missing, check for `alacritty` (spawning with `--class emojig-picker`) or `kitty` (spawning with `--class emojig-picker`).
2.  **X11 Support**:
    *   If an X11 session is detected (e.g., `DISPLAY` is set and `WAYLAND_DISPLAY` is empty), query for standard X11-compatible terminal emulators:
        *   `alacritty`
        *   `kitty`
        *   `xfce4-terminal`
        *   `gnome-terminal`
3.  **Generic Wrapper**:
    *   Check the `$TERMINAL` environment variable or search for system defaults like `x-terminal-emulator`.

### B. Decouple Terminal Customizations
Terminal-specific styling (such as `--override=colors.background`, `--override=pad`, and `csd.size`) is currently coupled directly with `foot` flags.
*   **Solution**: Abstract the window spawning configuration so that each supported terminal receives its appropriate geometry, padding, and styling flags, or fall back to standard terminal window settings.

### C. Support Dedicated Menu Pickers (Integration)
For users who do not want to install another terminal emulator, document and implement native launcher integrations with standard Linux desktop pickers:
*   **Wayland**: Provide configurations or helper scripts for `fuzzel`, `wofi`, or `tofi`.
*   **X11**: Provide configuration examples using `rofi` or `dmenu`.

### D. Package-Level Dependencies
Configure distribution packages (e.g., AUR, Nix derivation, Debian package) to list necessary terminal wrappers or clipboard utilities (`wl-copy`/`xclip`) as recommended or required dependencies.
