<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# Environment Detection: What's Actually There vs What We Check

Two real launch paths reach `emojig`, and each hands it a genuinely different
environment. This doc lists what's actually present in each, then walks
every place the source reads that environment to pick a mode or apply a
workaround — so a change to detection logic can be checked against the real
inputs instead of assumptions. See also [`Canary.md`](Canary.md) for why the
CI env-leak bug this doc partly grew out of was a test-harness artifact, not
a real-user risk (§3 below).

## 1. The two launch paths

### A. GUI, spawned directly by the desktop shell (no terminal in the chain)

A GNOME custom keybinding (or similar compositor shortcut) runs `emojig`
directly — `exec emojig`, no shell, no terminal. The process is a direct
child of `gnome-shell`/`mutter` and inherits *that* process's environment:
the graphical login session's env, not a shell's.

Present: `DISPLAY`/`WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, `LANG`/
`LC_*`, `HOME`, `PATH`, whatever `EMOJIG_*` vars were exported at login
(`~/.profile`/systemd user env — **not** `~/.bashrc`, since no shell ran).

Absent: `TERM` (no controlling terminal was ever opened), `VTE_VERSION`,
`TILIX_ID`, and — critically, for a *raw* keybinding specifically —
`XDG_ACTIVATION_TOKEN` and `DESKTOP_STARTUP_ID` (those only appear when the
desktop's own launch machinery, e.g. `gtk-launch`/app-grid activation, starts
the process; a bare `exec` bypasses it).

### B. TUI, run directly inside the user's already-open terminal

The user is sitting at a shell prompt in some terminal emulator and types
`emojig` (or `emojig --tui`). The process is a direct child of that shell,
inheriting the *entire* real environment: every var the terminal itself set
plus everything the user's shell rc exported.

Present: `TERM` (`foot`, `xterm-256color`, …), `VTE_VERSION`/`TILIX_ID` —
**only** if the terminal genuinely is VTE-based (gnome-terminal, tilix,
ptyxis, xfce4-terminal) — `WAYLAND_DISPLAY`/`DISPLAY` if graphical, and any
`EMOJIG_*` vars the user exported. A bare Linux VT console (`Ctrl-Alt-F2`)
is the degenerate case of this path: `TERM=linux`, no Wayland/X11 at all.

## 2. What the source actually checks

### Mode selection — `src/cli.zig:444–486`

```
has_gui_session := WAYLAND_DISPLAY or DISPLAY non-empty
can_use_tty     := openat("/dev/tty", O_RDWR) succeeds   -- NOT an env check, a real fd probe
is_linux_vt     := TERM == "linux" exactly               -- refuses to run at all (no glyphs in kernel console font)
```
Auto (no `--tui`/`--gui`): `can_use_tty` → stay in place as TUI; else
`has_gui_session` → floating GUI; else error.

- **Path A** has no controlling tty (`can_use_tty=false`) but a GUI session
  → auto-picks floating GUI. Matches AGENTS.md §9.
- **Path B** always has a controlling tty (`can_use_tty=true`) → stays
  in-place as TUI regardless of `has_gui_session`.

### VTE/Tilix ZWJ workaround — `src/root.zig:132–144`

```
EMOJIG_DISABLE_ZWJ=1/true → force on, =0/false → force off, else:
TILIX_ID or VTE_VERSION set → disable_zwj = true
```

This runs inside whichever process actually renders the picker grid — the
`--tui` process, which in Path A is a child of whatever terminal
`spawnGuiWindow` launched (foot by default), and in Path B is the user's own
shell's direct child.

- **Path A**: foot never sets `VTE_VERSION`/`TILIX_ID` for its children, so
  `disable_zwj` stays false (correct — ZWJ enabled) *unless*
  `EMOJIG_TERMINAL`/`$TERMINAL`/the `spec/host.yaml` detection list actually
  resolved to a VTE-based terminal, in which case that terminal asserts its
  own identity for the picker's child — also correct, since it genuinely is
  VTE then.
- **Path B**: reflects the real terminal the user is sitting in, directly.

### Terminal selection for `--gui` — `src/host.zig:88–111`

Precedence: `EMOJIG_TERMINAL` → `$TERMINAL` (if on `PATH`) →
`spec/host.yaml` `detection` list (foot preferred). Only relevant to Path A —
Path B never calls this, it's already inside a terminal.

### `--theme system` — two *different* mechanisms, not one env check

- **TUI** (Path B, or the picker's own `--tui` child in Path A): OSC 11 query
  to the terminal itself (`term.zig` `detectSystemTheme`/
  `last_system_theme_color`) — a live terminal-protocol round trip, not an
  env var.
- **GUI parent, before spawning** (Path A only, `host.zig:423`
  `detectDesktopTheme`): runs `gsettings get org.gnome.desktop.interface
  color-scheme` (`prefer-dark` → dark) then falls back to the `gtk-theme`
  name containing "dark" — a real subprocess probe. A non-GNOME desktop
  without `gsettings` falls through to the hardcoded dark default.

### GNOME focus-stealing workaround — `src/main.zig:618–706`

The mechanism most directly aimed at Path A. If `--gui` is running in a GUI
session and **neither** `XDG_ACTIVATION_TOKEN` nor `DESKTOP_STARTUP_ID` is
present, emojig assumes it was launched via a raw keybinding and re-execs
itself through `gtk-launch emojig-picker` (falling back to `gio launch
<desktop-file>`) specifically to obtain a real activation token, so Mutter
grants the new foot window focus instead of stealing-focus-preventing it. A
`/tmp/emojig-relaunch-<uid>.lock` file with a 5-second window stops this from
looping. **This is already the auto-fix for exactly the "spawned directly by
GNOME/Mutter" case** — not something missing.

### Grid size / GUI font — `EMOJIG_COLS`/`EMOJIG_ROWS`/`EMOJIG_GUI_FONT_SIZE`

Resolution order (`src/main.zig:718–743`, `src/cli.zig:401–427`): env →
config file → `spec/layout.yaml` default. Same precedence in both paths, but
in Path A the *resolved* values get baked into the spawned terminal's own
command line as a fixed `env VAR=... exe --tui` tail
(`src/host.zig:547–585`) — the picker's `--tui` child sees only that fixed
snapshot, not whatever the desktop environment ambiently had set. This
deliberately decouples the child from the parent's ambient env.

### `tmux` clipboard path — `src/clipboard.zig:58`

Checks `TMUX` to pick OSC 52 vs a native clipboard tool. Only relevant when
Path B's terminal happens to be running inside a tmux session.

## 3. Why the CI VTE-leak bug doesn't apply to real usage

The bug found while building the row-length canary (`VTE_VERSION`/
`TILIX_ID` leaking through `os.Environ()` from the *automation's own* host
terminal into an unrelated nested foot session) cannot happen to a real
user, in either path:

- **Path A**: the picker's `--tui` child's identity vars come from whichever
  terminal `host.zig` actually spawned. That terminal either doesn't set
  them (foot/kitty/…, correctly no ZWJ workaround) or does set them because
  it genuinely is VTE-based — there is no unrelated ancestor shell in the
  chain to leak from.
- **Path B**: the vars are inherited directly and authentically from the
  terminal the user is actually sitting in.

The CI bug required a third thing neither real path has: an automation
script puppeting a *fresh* foot instance from inside an *already-running,
unrelated* shell (the operator's own Tilix-hosted terminal), so that shell's
identity leaked into a process meant to represent a clean target terminal.
That's why the fix belongs in the *reel*'s `env=` scrubbing
(`scripts/vte_canary/canary-foot.reel`, `spec/reels/canary-gui-*.reel`), not
in emojig's own detection logic — the detection logic is correct for both
real launch paths.
