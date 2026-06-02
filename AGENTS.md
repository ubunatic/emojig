# Emojig: Agent Conventions & Architecture Guidelines

This document details the architectural decisions, coding standards, and safety requirements established for the **Emojig** project. Any agent resuming work on this repository must adhere strictly to these conventions.

---

## 1. Programming Languages & Scripting Constraints

* **Core TUI Application**: Written in **Zig** (`src/main.zig`, `src/root.zig`, `src/mru.zig`).
  * Aim for zero-allocation performance in the main interactive loop.
  * Optimize compilation for minimal size (`-Doptimize=ReleaseSmall`) to keep the binary under 350 KB and Resident Set Size (RSS) under 2.0 MB.
* **Helper Scripts & Utilities**: Located under `./scripts/`.
  * **No Python**: All helpers must be written in Go or Zig (or POSIX-compliant Shell for installers). Do not introduce Python scripts or packages.
  * **Go Scripts**: Written as flat, self-contained single files. Execute them using `go run scripts/<name>.go`.
  * **Zero Dependencies**: Go scripts must rely purely on the Go Standard Library without external module requirements.
  * **Zig Scripts**: Written as executable Zig source files. Execute them using `zig run scripts/<name>.zig`.
  * **Shell Scripts** (e.g., `scripts/install.sh`): Written for POSIX compatibility.
    * Use the `test` command (e.g., `if test "$OS" != "linux"`) instead of the bracket syntax `[` / `]`.
    * Place the `then` keyword on its own line immediately following the `if` condition, rather than on the same line with a semicolon (`; then`).
* **Licensing & Compliance**:
  * Every source file, helper script, utility, and shell script must include compliant SPDX copyright and licensing headers (e.g., `SPDX-FileCopyrightText` and `SPDX-License-Identifier`).
  * Ensure that the `make preflight` task (which validates REUSE compliance via `reuse lint` and checks formatting via `zig fmt`) passes successfully before finalizing any modifications.

---

## 2. Safe Terminal State Restoration

Because the emoji picker configures raw terminal input (uncooked mode) and enables raw mouse tracking (SGR coordinate tracking), it is critical that the terminal state is fully restored on shutdown or crash.

To prevent leaving the user's terminal session in a broken state:
* **Custom `panic` Override**: You must override Zig's standard panic handler in `src/main.zig` with `pub fn panic(...)`. This handler must restore standard termios attributes, disable mouse tracking, reset cursor style (`\x1b[0q`), show the cursor, and print the panic message.
* **POSIX Signal Handlers**: Register custom POSIX signal actions for `SIGINT` and `SIGTERM`. The handlers must safely restore the terminal and exit.
* **Child Spawning**: When launching external commands (such as clipboard copy utilities), handle stdin carefully. Close pipes properly and do not double-close file descriptors.

---

## 3. Terminal UI (TUI) Layout & Navigation

* **Borderless 2D Grid**:
  * Emojis must be drawn directly on grid rows separated by single spaces (e.g., ` 🧑‍🚒  🚒  🔥 `).
  * Do not use box-drawing border characters (like `│` or `┌`). Double-width emojis render unpredictably in different terminals, and borders cause alignment skewing.
  * The current dimensions are configured as a **6x4 grid** (6 columns, 4 rows) displaying the top 24 matches.
  * This custom spacing and borderless layout guarantees that all emoji icons render in perfect, clean alignment inside the `foot` terminal, avoiding double-width character skewing.
* **Optional Border** (`EMOJIG_BORDER=1`):
  * When the env var is set, one full-width colored row (`palette.border_bg`) is drawn before and after all content rows, adding 2 to the window height.
  * No box-drawing characters are used — the border is implemented as background-colored blank lines.
  * The foot launcher (`zig build picker`) detects `EMOJIG_BORDER=1` and adds 2 to the `--window-size-chars` height automatically.
  * All click/hover row coordinates are offset by `row_off = 1` when border is enabled.
* **Row Layout** (border off / border on):
  * Row 1 (/ 1): top border row (border on only)
  * Row 1 (/ 2): blank top padding row
  * Row 2 (/ 3): search bar — `🔍` prompt + query; theme-toggle icon on the right; entire row uses `search_bg` for a clean menu-row look; blinking cursor positioned at col `4 + query_len`
  * Row 3 (/ 4): blank spacer row
  * Rows 4–7 (/ 5–8): 6×4 emoji grid
  * Row 8 (/ 9): blank spacer row between grid and description
  * Row 9 (/ 10): description row (shows selected emoji name; blank when nothing selected)
  * Row 10 (/ 11): status bar — dense information row displaying matches count, arrows navigation hint, Tab theme shortcut, and Ctrl-C exit cue; uses `search_bg` for clean top/bottom visual consistency
  * Row 11 (/ 12): bottom border row (border on only)
* **Startup State**:
  * On launch, **no emoji is preselected** (`selected_idx` starts as `null`) and the bottom name/description row is empty.
  * The first arrow key press or first typed character initialises the selection to index 0.
* **Selection Highlight & Theming**:
  * Emojig supports high-performance, zero-allocation dark and light theme palettes.
  * Theme selection is determined by `--theme [dark|light|system]`, then `EMOJIG_THEME` env var, defaulting to `dark`.
  * `system` theme queries the terminal background via OSC 11 and auto-selects dark or light.
  * Selection highlight uses highlighted brackets `[emoji]` (with `selection_bg` spanning the brackets and glyph) for maximum clarity while matching cell width columns perfectly.
  * Palette fields: `bg` (grid/desc row background), `fg` (grid/desc text colour), `selection_bg` (selected cell), `search_bg` (entire search-bar and status-bar rows), `border_bg` (optional border rows).
  * **Dark Theme**: bg=234, fg=248, selection=24+white, search=238+white, border=236.
  * **Light Theme**: bg=255, fg=238, selection=111+black, search=251+black, border=252.
* **Mouse Tracking**:
  * Enabled with `\x1b[?1003h` (any-event, reports button + motion) + `\x1b[?1006h` (SGR coordinates).
  * **Hover**: motion events (SGR Cb bit 5 set) update `selected_idx` to the cell under cursor without triggering copy/exit.
  * **Click**: left-button press (`Cb & ~32 & 3 == 0`, action `M`) on a grid cell copies that emoji and exits; click on the theme icon (right 3 cols of search row) cycles theme.
  * The parser scans for the first `M`/`m` terminator so that batched motion events from `?1003h` do not corrupt parsing.
  * All three exit paths (defer, sigHandler, panic) emit `\x1b[?1003l\x1b[?1006l` to disable tracking.
* **2D Grid Navigation**:
  * Support horizontal (`Left`/`Right`) and vertical (`Up`/`Down`) arrow key movement.
  * Selection wraps around boundaries (e.g., pressing `Right` on column 6 wraps to the start of the next row; pressing `Down` on the bottom row wraps to the top row).

---

## 4. Fuzzy Search Engine

Implemented at query time in `src/root.zig` with **zero heap allocations**:
* **Subsequence Scoring** (`matchTermDirect`): Matches a search term as a subsequence of the target with bonuses for word-start positions and consecutive character runs. A late-start penalty discourages sparse matches.
* **Plural Fallback** (`matchTerm`): If a term ending in `s` fails, the engine retries with the singular (`cars` → `car`), including `es` and `ies` endings.
* **Word Stem Fallback** (`matchTerm`): If a term ending in `ing` fails, the engine retries with the bare stem (`rac`) and stem + `e` form (`race`). Double-consonant stems are also handled (`running` → `run`).
* **Query Stem Fallback** (`matchTerm`): If a term ending in `e` fails, the engine retries without the trailing `e`.
* **Multi-term Support** (`fuzzyMatch`): Space-separated terms must all match (AND semantics).

---

## 5. Database Packer & Compiler Embedding

* **Compile-Time Embedding**:
  * We do not read JSON or CSV files at runtime. The emoji database is serialized by a custom packer into a binary stream and embedded directly into the binary with `@embedFile("emojis.bin")`.
* **Database Design (`scripts/pack_emojis.go`)**:
  * Translates raw JSON in `data/emoji.json` into a compressed layout.
  * Uses a unified, deduplicated string table containing all names, keywords, and emoji characters.
  * Employs a fixed-size index array of offsets pointing into the string table.
* **Zero-Allocation Queries**:
  * Querying entries from the embedded `EmojiDb` must return direct string slices pointing straight into the embedded binary memory segment without any heap allocations.

---

## 6. Memory Auditing & Logging

* **Retrieval Mode**:
  * Upon any exit (normal exit, signal termination, or panic), the app must query its own resident memory usage by reading `/proc/self/statm`.
  * Use raw POSIX `openat` and `read` system calls to avoid memory allocations during cleanup.
* **Logging Location**:
  * Append a single-line memory usage log formatted as `[timestamp] Emojig closed. Memory Usage: VIRT = X MB, RSS = Y MB` to `/tmp/emojig.log`.

---

## 7. Testing Protocol

All diagnostics, simulations, and unit tests must reside in-tree:
* **`zig build test`**: Runs built-in test blocks verifying match scoring, search subsequence alignment, embedded binary offsets, plural/stem fallbacks, and startup state.
* **TUI Simulation (`scripts/test_tui.go`)**:
  * Spawns the CLI inside a programmatic Unix pseudo-terminal (PTY).
  * Writes key inputs, captures output buffers, verifies clean zero exit status, and outputs terminal frames for visual confirmation.
* **Agent Screenshot (`zig build screenshot` or `go run scripts/screenshot.go`)**:
  * Runs the app in a PTY, waits ~300 ms for the initial render, captures the output, then kills the process.
  * Saves the raw ANSI frame to `/tmp/emojig_frame.ansi` and a plain-text (ANSI-stripped) version to `/tmp/emojig_frame.txt`.
  * Prints the plain-text frame to stdout, allowing a coding agent to read it directly via the Bash tool and verify layout/content without a pixel-level screenshot.
  * Use this to close the agentic loop after UI changes: run it, read the output, confirm the layout is correct.
  * The step has a hard 10-second timeout so it never blocks the agent loop.
* **Non-Blocking Picker (`zig build picker`)**:
  * Launches foot in the background (fire-and-forget). Returns in under 100 ms.
  * Auto-kills after `EMOJIG_PICKER_TIMEOUT` seconds (default 60) of inactivity via native POSIX `alarm` and `SIGALRM` handling, resetting the timer on any user interaction.
  * To kill after inspecting: `pkill -f emojig-picker`.

---

## 8. Standalone Architecture Constraint

* **No Background Daemon or IPC**:
  * The application must remain a zero-allocation, self-contained standalone executable.
  * Do not implement local Unix domain sockets, TCP services, or background daemons.
  * State management (such as the MRU list and theme selection) must continue to be handled via direct, zero-allocation POSIX file writes to the disk at startup/shutdown, rather than caching state in a background service.

---

## 9. Execution & Launch Modes

To ensure seamless operation across CLI environments, graphical desktops, and custom keybind triggers, `emojig` supports three distinct launch modes:

1. **Auto-Mode (`emojig` without arguments)**:
   * **In-place TUI**: If standard input is an interactive terminal (`isatty` / `can_use_tty` is true), the picker launches immediately within the active terminal session.
   * **Floating GUI**: If executed from a non-interactive context (e.g., desktop shortcut or desktop environment hotkey where `can_use_tty` is false) and a Wayland/X11 session is active, it opens a floating GUI window via `--gui`.
2. **Forced TUI Mode (`emojig --tui`)**:
   * Bypasses environment checks and forces execution in-place in the current terminal. Fails with an exit code of `1` if standard input is not a terminal.
3. **Forced GUI Mode (`emojig --gui`)**:
   * Bypasses TTY checks and forces the launching of a new floating GUI window. The host terminal is chosen by precedence — `EMOJIG_TERMINAL`, then `$TERMINAL` (if on PATH), then auto-detection (`foot` preferred, else `kitty`/`alacritty`/`wezterm`/`ghostty`/`konsole`/`gnome-terminal`/`ptyxis`/`xterm`). `foot` keeps cell-precise sizing; others adapt via altscreen. Fails if no active Wayland or X11 graphical session is detected, or if no supported terminal is found (`EMOJIG_TERMINAL` hint is printed).
   * **`--borderless[=true|false]`** (default `true`) spawns the host terminal without window decorations, for terminals that expose a CLI flag (foot `csd.*`, kitty `hide_window_decorations`, alacritty `window.decorations`, ghostty `window-decoration`, wezterm `window_decorations`). gnome-terminal/ptyxis/konsole/xterm have no such flag and ignore it. This is **unrelated** to the in-TUI `--border` / `EMOJIG_BORDER` colored row.

### Design Rationale: Why "fzf-like" Auto-Detection is Used
* **CLI Composability**: Standard shell utilities must respect Unix piping idioms. Launching in-place when a TTY is active mimics standard tools like `fzf` and `skim`, enabling users to seamlessly integrate the picker into shell scripts or run it directly in splits/multiplexers without popup window disruption.
* **Hotkey and Widget Ergonomics**: Desktop hotkeys are spawned in non-TTY environments. By auto-detecting the absence of a TTY and automatically launching the floating graphical window fallback, `emojig` acts as both a CLI tool and a global graphical widget under a single unified executable name.

---

## 10. Git Worktrees (parallel & agent work)

When running parallel branches or spawning agents with `isolation: "worktree"`, read
**[`docs/Worktrees.md`](docs/Worktrees.md)** first. Critical points:

* **Preparation**: a fresh worktree builds with no bootstrap because `src/emojis.bin`
  is *tracked*. The gitignored `data/` dir (needed only by `make pack`) is **not**
  present — use `make worktree NAME=...`, which creates a sibling worktree and
  symlinks `data/`.
* **Merging agent work back — do not `cp` the agent's file over `main`.** Agent
  worktrees are branched from a base commit and may be **stale** (missing commits you
  landed after launch). Diff against the agent's **merge-base** and `git apply` the
  patch, then re-run `zig build test` + `zig fmt --check src/` in `main`. A naive copy
  can silently revert newer features.
* **Hygiene**: `.claude/worktrees/` is gitignored so transient agent worktrees don't
  pollute `git status` or get scanned by `reuse lint` (which otherwise reports false
  non-compliance). Stage commits by explicit path — never `git add -A` — because other
  agents may have uncommitted changes in the shared `main` tree at the same time.


