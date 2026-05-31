# Design Guide: Inline Terminal UIs (TUI) & Clean Viewport Management

This document details the architectural guidelines, implementation mechanics, and terminal-specific pitfalls for rendering **inline terminal user interfaces** (TUIs) that do not hijack the screen or alternate screen buffer (`\x1b[?1049h`).

Instead, they render naturally within the normal screen buffer, preserve the user's active terminal history (e.g., `ls` outputs), and clean up after themselves on exit—leaving the command prompt returned exactly to where the tool was executed.

---

## 1. Core Mechanics of Inline TUIs

An inline TUI occupies a fixed region of lines directly beneath the shell command that invoked it. Unlike traditional fullscreen TUIs (which use `\x1b[?1049h`), an inline TUI sits within the active scrollback buffer.

### Key Lifecycle Phases

1. **Inline Rendering Loop**:
   * On the first frame, lines are drawn downward.
   * On subsequent frames, the cursor is moved back to the top of the TUI region using relative vertical cursor movement sequences (`\x1b[{N}A\r`).
   * Content lines are overwritten directly using standard horizontal returns and horizontal absolute positions (`\x1b[{col}G`).

2. **Non-Scrolling Output**:
   * Standard newlines (`\n`) cause the entire terminal viewport to scroll up if the cursor is at the bottom of the screen.
   * Overwriting or clearing operations must avoid `\n` to prevent natural scrolling from shifting the TUI region relative to the terminal's physical viewport.

3. **Restoring Viewport & Cursor on Exit**:
   * The program moves the cursor to the top line of the TUI region (Row 0).
   * It clears each line of the TUI downwards, moving the cursor to the next line using non-scrolling vertical movements.
   * Finally, it returns the cursor to Row 0, restoring standard terminal attributes and cursor visibility.

---

## 2. Text-Based Terminal Session Lifecycle

Below are plain-text examples showing the state of the terminal buffer at each phase of the inline TUI session.

### Phase 2.1: Before Launching the TUI
The user is working in their standard shell. Previous commands and their outputs are fully visible.

```text
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 .
drwxr-xr-x 22 user user 4096 May 30 17:50 ..
-rw-r--r--  1 user user  120 May 30 18:00 Makefile
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig --tui█
```

### Phase 2.2: Active Inline TUI (During Execution)
The TUI is printed directly underneath the previous output. The command prompt remains visible above, and the cursor is kept active inside the search/input row of the TUI.

```text
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 .
drwxr-xr-x 22 user user 4096 May 30 17:50 ..
-rw-r--r--  1 user user  120 May 30 18:00 Makefile
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig --tui
 🔍 fir█              🔆
 
  🚒  🔥  🎆  🧨  🧯  🇮🇪
  ⚙️  ⛸️  😝  🎭  😚  😍
  😗  🏎️  😃  😀  😄  😁
  😆  😅  🤣  😂  🙂  🙃
 fire
```

### Phase 2.3: Clean Exit (After Completion)
Upon exit (e.g., selecting an emoji or pressing `Escape`), the TUI clears its own allocated lines, restoring the shell cursor exactly where the prompt was entered. All previous scrollback history remains untouched and fully readable.

```text
user@host:~$ ls -la
total 16
drwxr-xr-x  3 user user 4096 May 30 18:00 .
drwxr-xr-x 22 user user 4096 May 30 17:50 ..
-rw-r--r--  1 user user  120 May 30 18:00 Makefile
drwxr-xr-x  3 user user 4096 May 30 18:00 src
user@host:~$ emojig --tui
user@host:~$ █
```

---

## 3. Implementation Blueprint & ANSI Sequences

### 3.1 Loop Relocation
At the beginning of each frame (except the very first), reposition the cursor back to the top of the TUI region using a relative move sequence:

* **Cursor Up** (`\x1b[{rows}A`): Moves the cursor vertically up.
* **Carriage Return** (`\r`): Moves the cursor to the first column.

```zig
// Move UP from the search input line back to the TUI's Row 0
const move_seq = "\x1b[1A\r";
```

### 3.2 Non-Scrolling Downward Clearance (TUI Teardown)
During exit, you must clear the exact number of lines printed.
1. Move the cursor up to Row 0 of the TUI.
2. For each line, clear it using **Erase in Line** (`\x1b[2K`).
3. Move down to the next line using **Cursor Down** (`\x1b[B`) instead of a newline (`\n`).

```zig
// Loop to clear lines without scrolling
var k: usize = 0;
while (k < final_h) : (k += 1) {
    // Clear entire active line
    _ = std.posix.system.write(stdout_fd, "\x1b[2K", 4);
    if (k < final_h - 1) {
        // Move cursor down 1 row and return to column 1
        _ = std.posix.system.write(stdout_fd, "\x1b[B\r", 4);
    }
}
// Return cursor to Row 0 so shell prints there
const move_up = "\x1b[7A\r";
_ = std.posix.system.write(stdout_fd, move_up, move_up.len);
```

---

## 4. Key Pitfalls & Solutions

### 4.1 Pitfall: Alternate Screen Buffer Residual Commands (`\x1b[?1049l`)
* **The Bug**: Leaving `\x1b[?1049l` in the shutdown/restore escape sequence when the TUI does *not* enable it at startup.
* **The Symptom**: Works perfectly in some terminal emulators (like `foot` or `xterm`), but completely clears the screen, resets scrollbars, or corrupts active viewports in VTE-based terminals (like `Tilix` or `GNOME Terminal`).
* **The Solution**: Completely strip all `\x1b[?1049h` (alt screen enable) and `\x1b[?1049l` (alt screen disable) escape sequences from startup and cleanup operations.

### 4.2 Pitfall: Erase-in-Display Sequence (`\x1b[J`)
* **The Bug**: Using `\x1b[J` (Erase from cursor to end of screen) to clear TUI lines.
* **The Symptom**: Clears all scrollback content below the top of the TUI region. If the terminal scrolled naturally during launch, this completely wipes out the user's previous shell command history (e.g. the command output from `ls` that triggered the scroll).
* **The Solution**: Use exact line-by-line clears via `\x1b[2K` combined with vertical non-scrolling moves (`\x1b[B\r`).

### 4.3 Pitfall: Natural Scrolling & Save/Restore Cursor Mismatch
* **The Bug**: Relying on ANSI Save Cursor (`\x1b[s` or `\x1b7`) and Restore Cursor (`\x1b[u` or `\x1b8`) inside the normal buffer.
* **The Symptom**: If the TUI is launched at the bottom of the terminal window, printing the first frame forces the terminal viewport to scroll up. In VTE-based terminals, saved cursor coordinates do not scale relatively with viewport scrolling, resulting in duplicated rendering grids and floating lines.
* **The Solution**: Never use absolute saved coordinate sequences when rendering inline. Rely entirely on relative vertical movements (`\x1b[A`, `\x1b[B`) and absolute horizontal column overrides (`\x1b[G`).

### 4.4 Pitfall: Horizontal Character Wrapping
* **The Bug**: Printing a TUI line that contains more columns than the terminal window width.
* **The Symptom**: The terminal automatically wraps the excess characters to a new line. Since this new line is created at the bottom of the terminal screen, it triggers a natural viewport scroll, corrupting all relative vertical movement calculations.
* **The Solution**: Dynamically restrict TUI drawing widths (`term_width`) or add padding limits, ensuring lines never exceed the active terminal width.

### 4.5 Pitfall: Startup Empty-Line Pre-allocations
* **The Bug**: Writing dummy newlines (`\n`) at startup to pre-allocate blank space below the cursor.
* **The Symptom**: Pushes previous shell command output unnecessarily far up the scrollback buffer even when the TUI has plenty of physical terminal space to draw inline.
* **The Solution**: Enable natural rendering by writing the TUI inline starting on the current cursor line.
