# Design Guide: Inline Terminal UIs (TUI) & Clean Viewport Management

> [!NOTE]
> **Currency Status:** Current as of May 31, 2026. Matches the inline viewport management and TUI drawing routines of **Emojig v0.1.0**.

How emojig renders an inline TUI that does not hijack the screen or alternate buffer,
preserves scrollback history, and cleans up after itself on exit.

---

## 1. Core Mechanics

An inline TUI occupies a fixed region of lines directly beneath the shell command
that invoked it. It lives in the normal screen buffer (no `\x1b[?1049h`).

### Key lifecycle phases

1. **First frame**: draw lines downward from the current cursor position.
2. **Subsequent frames**: move cursor back to the top of the TUI region with
   `\x1b[{N}A\r`, then overwrite each line in place.
3. **Teardown**: move to top of TUI region, clear each line with `\x1b[2K` +
   `\x1b[B\r` (cursor-down without scroll), then move back up.

### /dev/tty vs stdout

TUI output goes to a `/dev/tty` file descriptor opened with `O_RDWR`, not to
`STDOUT_FILENO`. This keeps stdout clean for shell capture:

```sh
emoji=$(emojig)   # TUI appears on terminal; emoji captured from stdout
```

The selected emoji is written to `STDOUT_FILENO` after the TUI teardown defer
completes. Signal handlers and the panic handler use the same `/dev/tty` fd
(stored in `global_tty_fd`) so the terminal is always restored correctly.

---

## 2. Terminal Session Lifecycle

### Before launch

```
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig --tui█
```

### Active TUI (execution)

```
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig --tui
 🔍 fir█              🔆

  🚒  🔥  🎆  🧨  🧯  🇮🇪
  ⚙️  ⛸️  😝  🎭  😚  😍
  😗  🏎️  😃  😀  😄  😁
  😆  😅  🤣  😂  🙂  🙃
 fire
```

### Clean exit — stdout capture

After teardown the TUI lines are cleared and the emoji appears on stdout.
When called as `$(emojig)`, the shell captures the emoji; when called directly,
it prints on the terminal where the prompt will appear:

```
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig --tui
🔥
user@host:~$ █
```

---

## 3. ANSI Sequences

### Frame relocation (each frame after the first)

```zig
const move_seq = try std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{ 1 + row_off });
```

### Teardown — line-by-line clear without scrolling

```zig
var k: usize = 0;
while (k < final_h) : (k += 1) {
    _ = std.posix.system.write(stdout_fd, "\x1b[2K", 4);
    if (k < final_h - 1) {
        _ = std.posix.system.write(stdout_fd, "\x1b[B\r", 4);
    }
}
const move_up = std.fmt.bufPrint(&move_buf, "\x1b[{d}A\r", .{ final_h - 1 }) catch "";
_ = std.posix.system.write(stdout_fd, move_up.ptr, move_up.len);
```

---

## 4. Pitfalls & Solutions

### Alternate screen buffer (`\x1b[?1049l`)

Never include `\x1b[?1049h`/`\x1b[?1049l` in an inline TUI. Sending `\x1b[?1049l`
without having entered the alt screen clears the screen and resets scrollback in
VTE-based terminals (GNOME Terminal, Tilix).

### Erase-in-display (`\x1b[J`)

Do not use. Erases all content below the cursor including scrollback. Use `\x1b[2K`
(erase line) per line instead.

### Save/restore cursor (`\x1b7` / `\x1b8`)

Do not use for inline TUIs. If the terminal scrolls during the first frame render
(cursor at bottom of window), saved absolute coordinates do not adjust — subsequent
restores land at the wrong position. Use only relative movements (`\x1b[A`, `\x1b[B`,
`\x1b[G`).

### Natural scrolling on line print

Do not use `\n` for vertical movement during the render loop. `\n` at the bottom of
the terminal window causes the viewport to scroll, invalidating all relative cursor
math. Use `\x1b[B\r` (cursor down + carriage return) instead.

### Line wrap

Ensure rendered lines never exceed the terminal width. Overflow causes the terminal
to wrap onto a new line, creating an implicit scroll and corrupting the layout.
