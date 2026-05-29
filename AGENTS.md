# Emojig: Agent Conventions & Architecture Guidelines

This document details the architectural decisions, coding standards, and safety requirements established for the **Emojig** project. Any agent resuming work on this repository must adhere strictly to these conventions.

---

## 1. Programming Languages & Scripting Constraints

* **Core TUI Application**: Written in **Zig** (`src/main.zig`, `src/root.zig`).
  * Aim for zero-allocation performance in the main interactive loop.
  * Optimize compilation for minimal size (`-Doptimize=ReleaseSmall`) to keep the binary under 250 KB and Resident Set Size (RSS) under 700 KB.
* **Helper Scripts & Utilities**: Located under `./scripts/`.
  * **No Python**: All helpers must be written in Go or Zig. Do not introduce Python scripts or packages.
  * **Go Scripts**: Written as flat, self-contained single files. Execute them using `go run scripts/<name>.go`.
  * **Zero Dependencies**: Go scripts must rely purely on the Go Standard Library without external module requirements.
  * **Zig Scripts**: Written as executable Zig source files. Execute them using `zig run scripts/<name>.zig`.

---

## 2. Safe Terminal State Restoration

Because the emoji picker configures raw terminal input (uncooked mode) and enables raw mouse tracking (SGR coordinate tracking), it is critical that the terminal state is fully restored on shutdown or crash. 

To prevent leaving the user's terminal session in a broken state:
* **Custom `panic` Override**: You must override Zig's standard panic handler in `src/main.zig` with `pub fn panic(...)`. This handler must restore standard termios attributes, disable mouse tracking, show the cursor, and print the panic message.
* **POSIX Signal Handlers**: Register custom POSIX signal actions for `SIGINT` and `SIGTERM`. The handlers must safely restore the terminal and exit.
* **Child Spawning**: When launching external commands (such as clipboard copy utilities), handle stdin carefully. Close pipes properly and do not double-close file descriptors.

---

## 3. Terminal UI (TUI) Layout & Navigation

* **Borderless 2D Grid**:
  * Emojis must be drawn directly on grid rows separated by single spaces (e.g., ` 🧑‍🚒  🚒  🔥 `).
  * Do not use box-drawing border characters (like `│` or `┌`). Double-width emojis render unpredictably in different terminals, and borders cause alignment skewing.
  * The current dimensions are configured as a **6x4 grid** (6 columns, 4 rows) displaying the top 24 matches.
  * This custom spacing and borderless layout guarantees that all emoji icons render in perfect, clean alignment inside the `foot` terminal, avoiding double-width character skewing.
* **Selection Highlight & Theming**:
  * Emojig supports high-performance, zero-allocation dark and light theme palettes.
  * Theme selection is determined by checking the `--theme [dark|light]` command-line argument, with the `EMOJIG_THEME` environment variable used as a fallback. If neither is specified, it defaults to the `dark` theme.
  * **Dark Theme**:
    * Selection Highlight: The premium dark cyan background block (`\x1b[48;5;30m`) which provides excellent visibility and contrast against dark backgrounds.
    * Search Prompt: Standard white prompt (`🔍:`).
  * **Light Theme**:
    * Selection Highlight: A soft light blue/gray background highlight block (`\x1b[48;5;153m\x1b[38;5;235m`) with dark text for high contrast.
    * Search Prompt: Dark-colored text prompt (`\x1b[38;5;235m🔍:\x1b[0m`) designed for comfort on light backgrounds.
* **2D Grid Navigation**:
  * Support horizontal (`Left`/`Right`) and vertical (`Up`/`Down`) arrow key movement.
  * Selection wraps around boundaries (e.g., pressing `Right` on column 6 wraps to the start of the next row; pressing `Down` on the bottom row wraps to the top row).
* **Mouse Selection**:
  * Support left-click coordinates via raw SGR mouse input tracking parsing. Clicking an emoji cell copies it and exits instantly.

---

## 4. Database Packer & Compiler Embedding

* **Compile-Time Embedding**:
  * We do not read JSON or CSV files at runtime. The emoji database is serialized by a custom packer into a binary stream and embedded directly into the binary with `@embedFile("emojis.bin")`.
* **Database Design (`scripts/pack_emojis.go`)**:
  * Translates raw JSON in `data/emoji.json` into a compressed layout.
  * Uses a unified, deduplicated string table containing all names, keywords, and emoji characters.
  * Employs a fixed-size index array of offsets pointing into the string table.
* **Zero-Allocation Queries**:
  * Querying entries from the embedded `EmojiDb` must return direct string slices pointing straight into the embedded binary memory segment without any heap allocations.

---

## 5. Memory Auditing & Logging

* **Retrieval Mode**:
  * Upon any exit (normal exit, signal termination, or panic), the app must query its own resident memory usage by reading `/proc/self/statm`.
  * Use raw POSIX `openat` and `read` system calls to avoid memory allocations during cleanup.
* **Logging Location**:
  * Append a single-line memory usage log formatted as `[timestamp] Emojig closed. Memory Usage: VIRT = X MB, RSS = Y MB` to `/tmp/emojig.log`.

---

## 6. Testing Protocol

All diagnostics, simulations, and unit tests must reside in-tree:
* **`zig build test`**: Runs built-in test blocks verifying match scoring, search subsequence alignment, and embedded binary offsets.
* **TUI Simulation (`scripts/test_tui.go`)**:
  * Spawns the CLI inside a programmatic Unix pseudo-terminal (PTY).
  * Writes key inputs, captures output buffers, verifies clean zero exit status, and outputs terminal frames for visual confirmation.
