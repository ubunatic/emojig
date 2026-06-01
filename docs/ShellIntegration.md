# Shell Integration: fzf-style Stdout Mode

> [!NOTE]
> **Currency Status:** Current as of May 31, 2026. Matches the shell widget integrations and stdout capture behavior of **Emojig v0.1.0**.

How emojig integrates with shells via stdout capture, and the technical details
discovered during implementation.

---

## 1. The Design

emojig follows the fzf model:

- **TUI** renders on `/dev/tty` (opened directly, bypassing stdin/stdout)
- **Selected emoji** is printed to `STDOUT_FILENO` after teardown

This means `emoji=$(emojig)` works correctly: the TUI appears on the terminal
while the shell captures only the emoji from stdout. No clipboard required,
no kernel privileges needed, works in any terminal including VT and SSH.

### What fzf does (verified from source)

fzf's binary opens `/dev/tty` for both its input reader and its output renderer.
Its zsh widget is ~3 lines with no `zle -I`:

```zsh
fzf-file-widget() {
  LBUFFER="${LBUFFER}$(__fzf_select)"
  zle reset-prompt
}
```

fzf handles escape sequences with a **non-blocking poll loop** in Go:
after reading a lone ESC byte, it retries with `O_NONBLOCK` reads at 5 ms
intervals for up to `$ESCDELAY` (default 100 ms). emojig uses a simpler
`VTIME=1` (`tcsetattr`) approach that achieves the same effect.

---

## 2. ZLE and Application Cursor Keys (`smkx`)

### The problem

Arrow keys work in standalone mode but not when emojig is invoked via a
zsh ZLE widget (`bindkey '^E' _emojig_widget`).

### Root cause

When ZLE is active it sends `smkx` (application keypad mode, `\x1b[?1h`) to
the terminal. In this mode cursor keys send `\x1bOA/B/C/D` instead of the
standard `\x1b[A/B/C/D`. ZLE keeps the terminal in `smkx` during widget
execution — it does not restore normal mode before running the subcommand.

emojig originally only handled `\x1b[` sequences, so arrow keys were silently
ignored inside ZLE widgets.

### Fix

Handle both escape sequence forms:

| Mode | Up | Down | Left | Right |
|------|----|------|------|-------|
| Normal (standalone) | `\x1b[A` | `\x1b[B` | `\x1b[D` | `\x1b[C` |
| Application (ZLE widget) | `\x1bOA` | `\x1bOB` | `\x1bOD` | `\x1bOC` |

Both are handled in `src/main.zig`'s input loop since commit `c2aa663`.

---

## 3. Shell Snippets

Ready-made snippets live in `shell/`. Each binds **Ctrl+E** to an emojig widget.

### zsh (`shell/emojig.zsh`)

```zsh
emojig() {
  if test $# -eq 0 && test -t 1
  then
    local emoji
    emoji=$(command emojig)
    if test -n "$emoji"
    then
      print -z -n "$emoji"
    fi
  else
    command emojig "$@"
  fi
}

_emojig_widget() {
  local emoji
  zle -I
  emoji=$(emojig)
  test -n "$emoji" && LBUFFER+="$emoji"
  zle reset-prompt
}
zle -N _emojig_widget
bindkey -- "${EMOJIG_KEY:-^E}" _emojig_widget
```

`zle -I` inhibits further ZLE input processing while emojig runs.
`LBUFFER` is the text to the left of the cursor — appending to it inserts at the cursor position.

#### Why the Zsh function wrapper is needed

When `emojig` is run plain (standalone) over SSH or in a VT without any piped destination (e.g. `$ emojig`), printing the emoji directly to `stdout` is highly problematic:
- **TTY/PTY Race Conditions**: Writing to standard output `STDOUT_FILENO` (fd `1`) and restoring the terminal attributes via `/dev/tty` happen almost simultaneously. Because direct socket writes bypass the kernel's controlling-tty lookups, the emoji write often wins the race against the terminal restoration sequence. The screen-clearing sequences (`\x1b[1A\r\x1b[2K...`) are then processed by the terminal *after* the emoji has already been printed, instantly erasing the emoji from the terminal screen.
- **Prompt Pollution**: Even if the race is won, a direct print simply dumps the emoji on a line by itself above a new shell prompt. The user cannot edit it or execute it immediately; they have to manually select and copy it.

By using the Zsh function wrapper:
- It detects when `emojig` is executed plain and interactively in the terminal (`test $# -eq 0 && test -t 1`).
- It captures the selected emoji via stdout pipe redirection (command substitution).
- It uses the Zsh `print -z -n "$emoji"` built-in to push the selected emoji directly into the next prompt's input buffer.
This makes a plain run of `emojig` behave cleanly and seamlessly, auto-inserting the selected emoji directly at your next active command prompt.

### bash (`shell/emojig.bash`)

```bash
_emojig_widget() {
  local emoji
  emoji=$(emojig </dev/tty)
  if test -n "$emoji"
  then
    READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${emoji}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$(( READLINE_POINT + ${#emoji} ))
  fi
}
bind -x '"\C-e": _emojig_widget'
```

### fish (`shell/emojig.fish`)

```fish
function _emojig_widget
  set emoji (emojig </dev/tty)
  if test -n "$emoji"
    commandline --insert $emoji
  end
end
bind \ce _emojig_widget
```

---

## 4. Installation

```sh
# zsh — add to ~/.zshrc:
source /path/to/emojig/shell/emojig.zsh

# bash — add to ~/.bashrc:
source /path/to/emojig/shell/emojig.bash

# fish — add to ~/.config/fish/config.fish:
source /path/to/emojig/shell/emojig.fish
```

Reload your shell (`exec zsh` / `exec bash`) then press **Ctrl+E** at any prompt.

---

## 5. Use Cases

| Context | Works? | How |
|---------|--------|-----|
| Shell prompt (zsh/bash/fish) | ✓ | Key binding + `LBUFFER` / `READLINE_LINE` |
| Command substitution `$(emojig)` | ✓ | stdout capture |
| Pipe `emojig \| wl-copy` | ✓ | stdout |
| GUI floating window | ✓ | `--gui` mode, clipboard copy |
| VT (no GUI, no clipboard) | ✓ | stdout + shell widget |
| SSH session | ✓ | stdout + shell widget |
| Inside another TUI (vim, mc) | ✗ | No cross-TUI overlay without host app support |

The "inside another TUI" case would require either the host app to integrate with
an external picker API (like vim's fzf plugin), or emojig to run as a PTY wrapper
(mc-style) — a much larger scope discussed in `issues/06-vt-copy-paste-and-output-modes.md`.
