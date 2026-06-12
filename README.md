# <img src="src/assets/emojig-icon.web.svg" width="38" height="38" align="center" alt="emojig logo" /> emojig - *all your emoji are belong to us!*

[![Codeberg](https://img.shields.io/badge/Codeberg-Repository-3a8fcb?logo=codeberg&logoColor=white)](https://codeberg.org/ubunatic/emojig)
[![Release](https://img.shields.io/badge/Release-v0.1.5-blue?logo=semver&logoColor=white)](https://codeberg.org/ubunatic/emojig/releases)
[![License](https://img.shields.io/badge/License-AGPL--3.0--or--later-brightgreen?logo=open-source-initiative&logoColor=white)](https://codeberg.org/ubunatic/emojig/src/branch/main/LICENSES)
[![Language](https://img.shields.io/badge/Language-Zig_0.16-orange?logo=zig&logoColor=white)](https://ziglang.org)
[![Memory Usage](https://img.shields.io/badge/RAM-%3C%202.5%20MB%20RSS-violet?logo=speedtest&logoColor=white)](#performance)

Emojig is your zig-based, low-memory, instant-popup, terminal-based, daemon-free GUI+TUI emoji picker on all your Linux systems.

**Website:** https://ubunatic.com/emojig

<img src="docs/media/emojig-screen-gui-editor-light-v0.1.4.png" height="300"/>
<img src="docs/media/emojig-screen-tui-tilix-dark-v0.1.4.png" height="300"/>


## Features

* **🏎️ Zero-Allocation Performance**: Built in Zig, compile-time optimized (`ReleaseSmall`) to keep the static binary under 600 KB and Resident Set Size (RSS) under 2.5 MB.
* **🌐 Universal Launch Modes**: Runs in-place in active terminals (TUI) or automatically spawns a borderless popup window (GUI) via `foot`, `kitty`, `alacritty`, `ghostty`, or other standard terminals when triggered from hotkeys or desktop environments.
* **📦 Embedded Database**: 2,181 emojis packed directly at compile time via `@embedFile("emojis.bin")` for zero-allocation, instant runtime access.
* **🔍 Intelligent Fuzzy Search**: Multi-term space-separated search with automatic plural (`cars` -> `car`), stem (`running` -> `run`), and query-stem (trailing `e`) fallbacks.
* **↔️ 2D Grid & Mouse Navigation**: Navigate the borderless 2D grid using arrow keys or standard mouse interactions (hover to select, click to confirm, click theme button to toggle).
* **🌓 Automatic Theming**: Sleek light, dark, and system themes. OSC 11 terminal background detection selects the correct theme automatically, while <kbd>Tab</kbd> toggles and persists choice.
* **🛡️ Terminal Restoration**: Complete signal (`SIGINT`, `SIGTERM`) and custom panic handling guarantees raw terminal state is fully restored on crash or exit.
* **📊 Memory Auditing**: Audits resident memory usage on exit via raw POSIX `/proc/self/statm` reads, appending clean statistics to `/tmp/emojig.log`.

## Install

> [!Important]
> GUI mode needs a graphical session (Wayland or X11), a supported terminal
> (`foot`, `kitty`, `alacritty`, `wezterm`, `ghostty`, `konsole`, `gnome-terminal`,
> `ptyxis`, or `xterm` — override with `EMOJIG_TERMINAL`), and a clipboard tool (`wl-copy` / `xclip`).

The recommended install is the static-binary script below. Distro packages
(`.deb` / `.rpm`) ship with each release; a Homebrew formula is planned.

To download the latest static binary and install it:

```sh
curl -fsSL https://ubunatic.com/emojig/install.sh | sh
```

`--install` copies the binary to `~/.local/bin/emojig` and writes shell integration
scripts to `~/.local/share/emojig/shell/`.

### Fonts

emojig only uses standard Unicode emoji — no Nerd Fonts or special symbols needed.
If emojis appear as boxes, install a color emoji font:

```sh
sudo apt install fonts-noto-color-emoji      # Debian / Ubuntu / Mint
sudo pacman -S noto-fonts-emoji              # Arch / Manjaro
sudo dnf install google-noto-emoji-color-fonts  # Fedora
sudo zypper install noto-coloremoji-fonts    # openSUSE
```

## The TUI-GUI
The *GUI* mode hosts the emoji *TUI* in a borderless terminal window.

[`foot`](https://codeberg.org/dnkl/foot) is preferred — it launches instantly, uses
minimal resources, and gives pixel-perfect cell sizing. If `foot` isn't installed,
emojig auto-detects `kitty`, `alacritty`, `wezterm`, `ghostty`, `konsole`,
`gnome-terminal`, `ptyxis`, or `xterm`. Force a specific one with `EMOJIG_TERMINAL=kitty`.

The window is spawned **borderless** (no title bar) by default for a clean popup look,
where the terminal supports it (foot, kitty, alacritty, ghostty, wezterm). Disable it
with `--borderless=false` if your compositor needs the decorations to move the window.

**💻**  Bind a desktop key to run `emojig --gui` \
`>_`  Run `emojig --tui` inline in the terminal \
✨  Or just `emojig` — it picks GUI or inline TUI automatically

## Shell integration (Ctrl+E)

Add one line to your shell rc file:

```sh
# zsh — ~/.zshrc
source ~/.local/share/emojig/shell/emojig.zsh
```

```sh
# bash — ~/.bashrc
source ~/.local/share/emojig/shell/emojig.bash
```

```sh
# fish — ~/.config/fish/config.fish
source ~/.local/share/emojig/shell/emojig.fish
```

Then reload your shell and press **Ctrl+E** at any prompt — the picker opens inline,
pick an emoji, it lands at your cursor. Also copies to clipboard if available.

To use a different key: `export EMOJIG_KEY='^F'` (zsh/bash format) before sourcing.

## Desktop hotkey

For a system-wide picker, bind a key to emojig. The right path depends on your desktop —
emojig works with whatever you already run, it doesn't ask you to switch launchers.

### Stock desktops (GNOME, KDE, Cinnamon …)

These ship a launcher that can't be piped to, so bind a keyboard shortcut straight to
the floating picker:

- **GNOME** (e.g. Ubuntu): Settings → Keyboard → *Keyboard Shortcuts* → *Custom
  Shortcuts* → add one running `emojig --gui`.
- **KDE Plasma**: System Settings → Shortcuts → *Custom Shortcuts* → command `emojig --gui`.

`emojig --gui` opens the picker in a small floating window — via `foot` if installed,
otherwise your detected terminal (kitty, alacritty, …), or set `EMOJIG_TERMINAL`. Pick
an emoji and it lands on your clipboard.

> Tip: inside a terminal you need no hotkey at all — the **Ctrl+E** shell widget
> (above) fuzzy-picks and drops the emoji right at your cursor.

### If you already use a dmenu-style launcher (rofi / wofi / fuzzel / bemenu)

Common on tiling WMs (sway, i3, Hyprland). `emojig --list` prints every emoji as
`emoji<TAB>name` with no UI, so you can feed it to the launcher you **already** run —
no new dependency:

```sh
# wofi (Wayland)
emojig --list | wofi --dmenu | cut -f1 | tr -d '\n' | wl-copy

# rofi (X11)
emojig --list | rofi -dmenu -i | cut -f1 | tr -d '\n' | xclip -selection clipboard

# fuzzel (Wayland)
emojig --list | fuzzel --dmenu | cut -f1 | tr -d '\n' | wl-copy
```

`cut -f1` keeps the emoji (the name is only there so you can search for it). Bind your
favourite line to a hotkey. If you *don't* already use such a launcher, prefer
`emojig --gui` above — don't install one just to pick emoji.

## Usage

```sh
emojig                  # auto: floating window (GUI) or inline TUI (terminal)
emojig --tui            # force inline TUI — works over SSH, in VT, anywhere
emojig --gui            # force floating window (foot/kitty/alacritty/…; $EMOJIG_TERMINAL)
emojig --list           # print all emojis as 'emoji<TAB>name' (for rofi/wofi/dmenu)
emojig --install        # install binary + shell scripts to ~/.local/
$(emojig)               # stdout capture — emoji goes to the calling shell
emojig | wl-copy        # pipe to clipboard tool directly
```

## Controls

| Key | Action |
|-----|--------|
| Type | Fuzzy filter |
| Arrow keys | Navigate grid (2D) |
| Enter | Confirm selection |
| Mouse click | Select and confirm |
| Tab | Cycle theme (dark / light / system) |
| Escape, Ctrl+C | Cancel |

Plural and stem fallbacks apply: `cars` → `car`, `racing` → `race`.

## Output

| Context | Behaviour |
|---------|-----------|
| Standalone at prompt | Copy to clipboard (`wl-copy` / `xclip`) |
| Shell widget / `$(emojig)` | Print to stdout + try clipboard |
| `emojig \| cmd` | Pipe to `cmd` |

## Theming

Dark, light, and system (auto-detected via OSC 11) themes. Tab-toggle in the TUI
saves your choice to `~/.config/emojig/config`. Override with `--theme` or
`EMOJIG_THEME`.

## Requirements

- Linux (x86\_64 or aarch64)
- **GUI mode** (`--gui`): a supported terminal (`foot`/`kitty`/`alacritty`/`wezterm`/… or `EMOJIG_TERMINAL`) + Wayland or X11 session
- **Clipboard**: `wl-copy` (Wayland) or `xclip` (X11) — optional

## Performance

- Binary: **596 KB** (static musl, no runtime deps; ~535 KB native dynamic)
- RAM: **< 2.5 MB RSS** during operation (self-reported to `/tmp/emojig.log` at exit), 0 when idle (excl. launcher/foot memory usage, which adds ~16 MB for foot)
- Database: 2,181 emojis embedded at compile time — no data files

## License

AGPL-3.0-or-later. See [LICENSES/](LICENSES/).
