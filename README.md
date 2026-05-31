# emojig

A fast, low-memory emoji picker for the terminal. Fuzzy search across 1,870 emojis,
pick with arrow keys or mouse, get the emoji in your clipboard or shell prompt.

| Dark | Light |
|------|-------|
| ![emojig dark theme](docs/emojig-dark.png) | ![emojig light theme](docs/emojig-light.png) |

## Install

```sh
curl -L https://codeberg.org/ubunatic/emojig/releases/latest/download/emojig -o emojig
chmod +x emojig
./emojig --install
```

`--install` copies the binary to `~/.local/bin/emojig` and writes shell integration
scripts to `~/.local/share/emojig/shell/`.

## Shell integration (Ctrl+E)

Add one line to your shell rc file:

```zsh
# zsh — ~/.zshrc
source ~/.local/share/emojig/shell/emojig.zsh
```

```bash
# bash — ~/.bashrc
source ~/.local/share/emojig/shell/emojig.bash
```

```fish
# fish — ~/.config/fish/config.fish
source ~/.local/share/emojig/shell/emojig.fish
```

Then reload your shell and press **Ctrl+E** at any prompt — the picker opens inline,
pick an emoji, it lands at your cursor. Also copies to clipboard if available.

To use a different key: `export EMOJIG_KEY='^F'` (zsh/bash format) before sourcing.

## Usage

```sh
emojig                  # auto: floating window (GUI) or inline TUI (terminal)
emojig --tui            # force inline TUI — works over SSH, in VT, anywhere
emojig --gui            # force floating foot window (Wayland/X11)
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
- **GUI mode** (`--gui`): `foot` terminal + Wayland or X11 session
- **Clipboard**: `wl-copy` (Wayland) or `xclip` (X11) — optional

## Performance

- Binary: **278 KB** (static, no runtime deps)
- RAM: **< 700 KB RSS** during operation, 0 when idle
- Database: 1,870 emojis embedded at compile time — no data files

## License

AGPL-3.0-or-later. See [LICENSES/](LICENSES/).
