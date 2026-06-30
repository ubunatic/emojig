# <img src="src/assets/emojig-icon.web.svg" width="38" height="38" align="center" alt="emojig logo" /> emojig — *all your emoji are belong to us!*

[![Codeberg](https://img.shields.io/badge/Codeberg-Repository-3a8fcb?logo=codeberg&logoColor=white)](https://codeberg.org/ubunatic/emojig)
[![Release](https://img.shields.io/badge/Release-v0.2.0-blue?logo=semver&logoColor=white)](https://codeberg.org/ubunatic/emojig/releases)
[![License](https://img.shields.io/badge/License-AGPL--3.0--or--later-brightgreen?logo=open-source-initiative&logoColor=white)](https://codeberg.org/ubunatic/emojig/src/branch/main/LICENSES)
[![Language](https://img.shields.io/badge/Language-Zig_0.16-orange?logo=zig&logoColor=white)](https://ziglang.org)
[![Memory Usage](https://img.shields.io/badge/RAM-%3C%205%20MB%20RSS-violet?logo=speedtest&logoColor=white)](#performance)

A zig-based, low-memory, instant-popup, daemon-free GUI + TUI emoji picker for Linux.

**Website:** https://ubunatic.com/emojig

<img src="docs/media/emojig-screen-gui-editor-light-v0.1.4.png" height="300"/>
<img src="docs/media/emojig-screen-tui-tilix-dark-v0.1.4.png" height="300"/>

## Highlights

| | |
|-|-|
| 🏎️ **900 KB static binary, < 5 MB RSS** | Zero-allocation Zig core, `ReleaseSmall` optimized |
| 🌐 **GUI + TUI in one binary** | Auto-detects terminal vs. desktop and picks the right mode |
| 🔍 **Instant fuzzy search** | Multi-term, plural / stem fallbacks (`cars`→`car`, `racing`→`race`) |
| 📦 **2,249 emojis embedded** | Compile-time `@embedFile` — no data files, no network |
| 🌓 **Dark / light / system themes** | OSC 11 auto-detection; <kbd>Tab</kbd> to toggle |
| 🖱️ **Full mouse + keyboard nav** | Hover, click, scroll wheel, 2D arrow-key grid |
| 🛡️ **Crash-safe terminal restore** | Custom panic handler + signal traps restore raw mode |

## Install

```sh
curl -fsSL https://ubunatic.com/emojig/install.sh | sh
```

This downloads a static binary to `~/.local/bin/emojig` and writes shell
integration scripts to `~/.local/share/emojig/shell/`.

> [!Important]
> GUI mode needs a graphical session (Wayland or X11), a supported terminal
> (`foot`, `kitty`, `alacritty`, `wezterm`, `ghostty`, `konsole`, `gnome-terminal`,
> `ptyxis`, or `xterm` — override with `EMOJIG_TERMINAL`), and a clipboard tool
> (`wl-copy` / `xclip`).

### Fonts

emojig uses standard Unicode emoji — no Nerd Fonts needed.
If emojis appear as boxes, install a color emoji font:

```sh
sudo apt install fonts-noto-color-emoji        # Debian / Ubuntu / Mint
sudo pacman -S noto-fonts-emoji                # Arch / Manjaro
sudo dnf install google-noto-emoji-color-fonts # Fedora
sudo zypper install noto-coloremoji-fonts      # openSUSE
```

## Quick start

```sh
emojig              # auto: GUI popup or inline TUI
emojig --tui        # force inline TUI (SSH, VT, anywhere)
emojig --gui        # force floating popup window
emojig --gui --decorated  # show terminal title bar for dragging
```

Type to search, arrows to navigate, <kbd>Enter</kbd> to pick. Done.

## Controls

| Key | Action |
|-----|--------|
| Type | Fuzzy search / filter |
| Arrow keys | Navigate the 2D grid |
| Enter | Confirm selection |
| Mouse click | Select + confirm |
| <kbd>Space</kbd> (grid focus) | Multi-select mode |
| Tab | Cycle theme |
| Esc / Ctrl+C | Cancel |

## Shell integration (Ctrl+E)

Add one line to your shell rc file and press **Ctrl+E** at any prompt — the
picker opens inline, and the emoji lands at your cursor:

```sh
# ~/.zshrc
source ~/.local/share/emojig/shell/emojig.zsh

# ~/.bashrc
source ~/.local/share/emojig/shell/emojig.bash

# ~/.config/fish/config.fish
source ~/.local/share/emojig/shell/emojig.fish
```

Custom key: `export EMOJIG_KEY='^F'` before sourcing.

## More

See **[Advanced Usage](docs/Advanced.md)** for:

- Desktop hotkey setup (GNOME, KDE, tiling WMs)
- dmenu / rofi / wofi / fuzzel integration
- Theming & configuration
- Output modes (clipboard, stdout, pipe)
- All CLI flags
- GUI terminal selection & window decorations
- Requirements & system compatibility

## Performance

| Metric | Value |
|--------|-------|
| Binary size | **900 KB** (static musl, no runtime deps) |
| RAM | **< 5 MB RSS** during operation |
| Database | 2,249 emojis embedded at compile time |

Memory usage is self-reported to `/tmp/emojig.log` at exit.

## License

AGPL-3.0-or-later. See [LICENSES/](LICENSES/).
