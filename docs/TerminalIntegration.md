<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Terminal Integration & Deployment Stories

This document explains the integration mechanics of Emojig across terminal sessions, shell setups, graphical desktop environments (Wayland/X11), and the local system clipboard.

---

## 1. Universal Launch Modes: Auto-Detection (TUI vs. GUI)

Emojig operates as a single executable that adapts its launch interface dynamically. It mimics standard tools like `fzf` to support both command-line composition and floating window triggers.

```mermaid
flowchart TD
    A["Run emojig"] --> B{"Is stdin a TTY?"}
    B -- "Yes (interactive terminal)" --> C["In-Place TUI mode"]
    B -- "No (hotkey / script)" --> D{"Wayland or X11 active?"}
    D -- "Yes" --> E["Spawn Floating GUI Window"]
    D -- "No" --> F["Fail with Exit Code 1"]
```

### In-Place TUI Mode (`emojig --tui`)
When executed directly inside an active terminal session, Emojig runs in-place, drawing its interface directly beneath the shell prompt. This allows it to be piped:
```sh
# Copy search result directly to clipboard
emojig | wl-copy
```

### Floating GUI Popup (`emojig --gui`)
When invoked from a desktop hotkey or launcher shortcut, standard input is non-interactive (`can_use_tty == false`). Emojig automatically detects the graphical session and spawns a new instance of a lightweight terminal window (prefers `foot`, fallback to others like `kitty`, `alacritty`, `ghostty`) running `emojig --tui` in a borderless popup configuration by default.

* **Borderless GUI Option** (`--borderless`): Hides window decorations for terminals that expose CLI control flags (e.g. `foot -D csd.server-side=none`, `kitty --o hide_window_decorations=yes`, etc.).
* **Decorated GUI Option** (`--decorated` / `--window-decorations`): Keeps the terminal's normal title bar/window decorations so the picker can be dragged by the window manager. This is equivalent to `--borderless=false`.
* **Placement**: On Wayland, exact caret-relative popup placement is not a stable cross-desktop primitive. Focused-window placement should be compositor-specific and best-effort; see `issues/40-wayland-focused-window-placement.md`.
* **Auto-Dismiss**: Once an emoji is chosen, the terminal helper exits, auto-closing the popup instantly.

---

## 2. Shell Integrations (Bash, Zsh, Fish)

Shell integration scripts live in `src/shell/` and are embedded in the binary.
The key binding defaults to `Ctrl+E`; override with `EMOJIG_KEY`.

### Generic dispatcher: `emojig.sh`

`emojig.sh` is a POSIX-compatible dispatcher that sources the right
shell-specific script at runtime:

```sh
if test -n "$ZSH_VERSION"
then source ~/.local/share/emojig/shell/emojig.zsh
elif test -n "$BASH_VERSION"
then source ~/.local/share/emojig/shell/emojig.bash
fi
```

**Fish cannot parse POSIX `if/then/fi`** — fish always gets a direct
`source emojig.fish` line, never via `emojig.sh`.

### Installing

`--install` auto-detects `$SHELL`, writes an `if test -f` guard to the
appropriate rc file, and exits:

```
emojig --install
# → detects zsh, writes to ~/.zshrc (or ~/.userrc if it exists):
#   if test -f ~/.local/share/emojig/shell/emojig.sh
#   then source ~/.local/share/emojig/shell/emojig.sh
#   fi
```

**RC file resolution order** (non-fish):
1. `--rc FILE` override (relative to `$HOME` or absolute)
2. `~/.userrc` if it exists
3. `~/.zshrc` (zsh) or `~/.bashrc` (bash)

Fish always writes to `~/.config/fish/config.fish` (ignores `~/.userrc`).

`--install` is idempotent — it scans the first 16 KiB of the target file for
the marker string (`emojig/shell/emojig.sh` or `emojig/shell/emojig.fish`)
before appending.

### Eval workflow

As an alternative to `--install`, print the script to stdout for `eval`:

```sh
eval "$(emojig --completion)"            # auto-detect from $SHELL
eval "$(emojig --completion=zsh)"        # explicit shell
eval "$(emojig --completion --key '^Y')" # custom key: prepends EMOJIG_KEY='^Y'
```

`--completion` accepts `sh`, `zsh`, `bash`, or `fish`.

---

## 3. Desktop and App Icon Integration

To appear in desktop application menus, Emojig generates a standard `.desktop` entry and registers application icon formats on installation.

### Dual SVG/PNG Icon Strategies

1. **SVG (Scalable Vector Graphics)**: Main icon target written to `~/.local/share/icons/hicolor/scalable/apps/emojig-picker.svg`. This provides high-quality scaling for modern desktop environments.
2. **PNG (Portable Network Graphics) Fallback**: Many legacy launchers and notification daemons do not support SVG icons. To prevent broken or missing icons, Emojig compiles a 128x128 pixel PNG asset (baked into the binary) and writes it on install to:
   * `~/.local/share/icons/hicolor/128x128/apps/emojig-picker.png`
   * `~/.local/share/icons/emojig-picker.png` (direct local fallback)

The `.desktop` launcher utilizes the absolute path to this fallback PNG icon to guarantee compatibility across all window managers.

---

## 4. Safe Clipboard Integration (Spawning Child Pipes)

When copying an emoji to the clipboard, Emojig must invoke system utilities like `wl-copy` (Wayland), `xclip` / `xsel` (X11), or `pbcopy` (macOS).

### Safe Pipe Management Pitfalls
Spawning external clipboard utilities in Zig requires careful management of file descriptors. 

* **Pipe Lifecycle**: Do not double-close file descriptors. When you spawn a child process, writing the selected emoji sequence to the process's standard input pipe must be done by explicitly closing the write end after sending, signaling an EOF to the clipboard utility.
* **Non-blocking Execution**: Clipboard tools should be spawned asynchronously, allowing the main TUI binary to exit immediately once the copy command is handed off.

---

## 5. Terminal State Restoration on Exit

Tearing down the inline TUI without leaving artifacts (orphaned rows, a
displaced cursor, leaked mouse events, wiped scrollback) is its own minefield,
and the failure modes are **terminal-specific** — e.g. an unmatched
`\x1b[?1049l` is harmless in foot/tmux but displaces the cursor in every VTE
terminal (Tilix, GNOME Terminal, Ptyxis).

See [`TerminalRestore.md`](./TerminalRestore.md) for the teardown contract,
the cross-terminal pitfalls we hit, and the test matrix for teardown changes.
