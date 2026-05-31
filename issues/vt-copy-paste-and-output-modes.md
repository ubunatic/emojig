# Issue: Copy/paste and output delivery in VT and non-GUI environments

## What we learned

### VT has no OS clipboard

A Linux virtual console (VT) has no clipboard abstraction at all. The options are:

- **GPM daemon**: if running, left-click-drag selects, middle-click pastes — but this is raw
  terminal text selection, not a named buffer any application can write to programmatically.
- **tmux/screen copy buffer**: internal to the multiplexer, not accessible cross-process.
- **Nothing else**: `wl-copy`, `xclip`, `xdotool` all require a Wayland or X11 session.

`emojig`'s current `copyToClipboard` tries `wl-copy` then `xclip`. Both silently fail in VT.
The emoji is picked and then silently lost.

### TIOCSTI is not the "fzf approach"

TIOCSTI (`ioctl(fd, 0x5412, &byte)`) injects a byte into the tty's input queue as if typed.
It would let the binary "type" the emoji into the parent shell after exiting.

**Kernel restriction**: since Linux 6.2, TIOCSTI requires `CAP_SYS_ADMIN` or
`sysctl dev.tty.legacy_tiocsti=1`. The project's target machine runs kernel 7.0 — TIOCSTI
is off by default and would silently fail without a sysctl change, making it unreliable as a
default fallback.

**fzf does not use TIOCSTI.** The fzf binary prints only the selection to stdout and exits.
The "typing into the prompt" magic is entirely in the shell widget:
- bash: `READLINE_LINE`/`READLINE_POINT` via a `bind -x` binding
- zsh: `LBUFFER+=$(fzf)` or `print -z` in a ZLE widget
- fish: `commandline --insert (fzf)`

No ioctls, no privileges, works on every kernel, every terminal.

### The TUI overlay problem

A TUI emoji picker is only useful if the selected emoji can reach the thing the user is
currently editing. In a GUI session the clipboard is the universal bridge.
In a VT or plain terminal there is no such bridge — with one important exception:
the **shell prompt**.

You **cannot** overlay emojig on top of another TUI (vim, mc, helix, etc.) unless that
app explicitly supports calling out to an external picker and re-ingesting its output.
The terminal has no concept of "modal overlay" between two independent processes.
mc's `C-o` works because mc *implements* the subshell itself; it is not a general mechanism.

## Current behaviour

`copyToClipboard` in `src/main.zig:1096`:
1. Try `wl-copy` (Wayland)
2. Try `xclip -selection clipboard` (X11)
3. Fail silently

In VT: step 1 and 2 both fail; the emoji disappears.

## Options

### Option A — stdout mode (real fzf approach)

Render the TUI on `/dev/tty`, emit only the selected emoji on stdout. Ship shell snippets.

```sh
# .zshrc
bindkey '^E' _emojig_widget
_emojig_widget() { LBUFFER+="$(emojig 2>/dev/tty)" }

# bash
bind -x '"\C-e": READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}$(emojig 2>/dev/tty)${READLINE_LINE:$READLINE_POINT}"; READLINE_POINT=$((READLINE_POINT + ${#$(emojig)}))'
```

- Works everywhere a shell prompt exists: GUI terminal, VT, SSH session.
- Only works at a shell prompt — not inside vim, mc, etc.
- Requires a small refactor: redirect TUI output to `/dev/tty` so stdout is clean.
- Requires users to source a shell snippet.

### Option B — TIOCSTI injection

Inject bytes into the tty input queue before exiting. Works without shell config changes.

- Disabled by default on Linux 6.2+ (needs `sysctl dev.tty.legacy_tiocsti=1`).
- Security-sensitive (used in escape-sequence injection attacks historically).
- No shell config needed — magic happens in the binary.
- Must NOT silently fail: if ioctl returns EPERM, fall back to stdout print.

### Option C — tmux integration

If `$TMUX` is set, use `tmux load-buffer -` and `tmux paste-buffer` to deliver the emoji.
Works in any tmux pane regardless of what is running there.

- Zero kernel constraints, zero shell config.
- tmux-only; does nothing in bare VT without tmux.

### Option D — emojig as a terminal / compositor overlay

Run emojig itself as the terminal (framebuffer compositor) that summons the picker on a
global hotkey, like a quake-style dropdown. Or integrate with a Wayland compositor via
layer-shell (wlr-layer-shell) for a true floating overlay in GUI sessions.

- Massive scope change; separate project territory.
- Solves the overlay problem completely for the environments it targets.

## Recommended direction

For VT + shell prompt use: **Option A** (stdout + shell snippet) is the right default.
It is kernel-independent, composable, and is exactly how every well-designed TUI picker
works (fzf, skim, zf). The refactor is small (write TUI to `/dev/tty`; stdout is silent
until selection is confirmed).

**Option C** (tmux buffer) is a cheap add-on that covers "I am inside tmux and not at a
shell prompt" — worth doing alongside Option A.

**Option B** (TIOCSTI) could be an opt-in `--type` flag with a clear warning; do not make
it a silent default fallback.

**Option D** is a future separate discussion.
