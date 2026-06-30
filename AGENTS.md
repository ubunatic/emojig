# Emojig: Agent Conventions & Architecture Guidelines

> **Note:** `CLAUDE.md` is always a symlink to `AGENTS.md`. All content lives here in `AGENTS.md` — never edit `CLAUDE.md` directly.

This document details the architectural decisions, coding standards, and safety requirements established for the **Emojig** project. Any agent resuming work on this repository must adhere strictly to these conventions.

## Quickstart
* See `make help` for common build tasks (and use/extend these targets as needed)
* Always run `make install` after making changes to compile and update the installed binary, shell integrations, and desktop launcher.
* Make sure --tui scrollback logic is always super safe!
* Make sure --gui/--tui mouse hover logic is always safe!
* Make sure --tui close behavour is safe!
* **Before touching search, emoji data, or ranking:** read [`docs/SearchEngine.md`](docs/SearchEngine.md) — documents non-obvious pitfalls (word-order trap, `isBoxArt` codepoint range, synonym-vs-tag tradeoffs, greedy-matcher behaviour) that are easy to re-derive incorrectly from scratch.
* **Before touching theme/palette fields:** read [`docs/SpecDrivenConfig.md §13`](docs/SpecDrivenConfig.md) — documents the null-color "punch-through" contract, cap vs. sep fallback distinction, and field tables. Changing fallback chains without reading it can reintroduce the near-black separator bug.
* **Before writing any Zig subprocess, pipe, fd, or process-spawn code:** read [`docs/Zig.md`](docs/Zig.md) — documents non-obvious Zig 0.16 API shapes (`pipe2`, `StdIo.file`, `posix.system.close`, `mem.trim` constness, etc.) that cause hard-to-diagnose compile errors.

## Assumptions for Agentic Work
* Assume all tools you need are installed (ffmpeg, go, zig, terminal emulators).
  Do not always probe for tools with `command -v`. Just call them when needed.
* Assume recent versions of all tools (modern Go, latest Rust, fresh OS tools, etc.)

---

## 1. Programming Languages & Scripting Constraints

* **Core TUI Application**: Written in **Zig** (`src/main.zig`, `src/root.zig`, `src/mru.zig`).
  * Aim for zero-allocation performance in the main interactive loop.
  * Optimize compilation for minimal size (`-Doptimize=ReleaseSmall`) to keep the binary under 650 KB and Resident Set Size (RSS) under 2.5 MB (measured June 2026: 603 KB musl-static, 2.3-2.4 MB RSS, 2,249 embedded emojis).
* **Helper Scripts & Utilities**: Located under `./scripts/`.
  * **No Python, No Perl, No Heredocs**:
    All helpers must be written in Go or Zig (or POSIX-compliant Shell for installers).
    Do not introduce Python scripts or packages.
    Do not use big inine scripts when exploring/testing code.
    Do not use heredoc scripts when exploring/testing code.
  * **Go Scripts**: Written as flat, self-contained single files. Execute them using `go run scripts/<name>.go`.
  * **Zero Dependencies**: Go scripts must rely purely on the Go Standard Library without external module requirements.
  * **Zig Scripts**: Written as executable Zig source files. Execute them using `zig run scripts/<name>.zig`.
  * **Shell Scripts** (e.g., `scripts/install.sh`): Written for POSIX compatibility.
    Follow **@docs/Bash.md** for all style rules. Key points:
    * Use `test` instead of `[` / `]` or `[[` / `]]`.
    * 3-line if-then-fi: `then stmt` on the same line as `then`, never a semicolon before `then`.
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
  * Row 2 (/ 3): search bar — left cap + `🔍` prompt + query text area + `search_theme_sep` + theme icon + `theme_settings_sep` + menu `≡` + right cap; entire row uses `search_bg`; blinking cursor at col `4 + query_len`. Cap and sep glyphs/colors are fully configurable via `spec/strings.json` and `spec/theme.json` — see `docs/SpecDrivenConfig.md §13`. Null sep/cap bg or fg resolves to `cap_fallback_idx` (app bg) for the canvas "punch-through" effect, **not** `search_bg`.
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
  * **Null color contract for caps and separators**: a `null` value on any cap (`search_{left,right}_cap_{fg,bg}`) or sep (`search_theme_sep_{fg,bg}`, `theme_settings_sep_{fg,bg}`) color resolves to `cap_fallback_idx` — the app canvas color (`app_bg` index if set, else nearest xterm-256 to `terminal_bg2`). This "punch-through" effect makes the canvas show through at that slot. Never use `search_bg` as the fallback for null sep/cap colors — that was the source of the near-black separator bug (cap_fallback ≈ 236 for dark theme looked black against search_bg=238).
  * **Dark Theme**: bg=234, fg=248, selection=24+white, search=238+white, border=236.
  * **Light Theme**: bg=255, fg=238, selection=111+black, search=251+black, border=252.
  * **Named colors** (`spec/colors.json`, generated by `scripts/gen_colors` → `make gen-colors`, embedded): documents all 256 xterm palette slots with a long `name`, a 3-letter `short` (`grn`, `blu`, `blk`), a `hex`, a human `desc`, and `alt` aliases. System colors (0–15) and popular colors (`orange`=208, `teal`, `forest`, `navy`…) get friendly names; the rest use systematic `rgbRGB` (cube level digits 0–5) / `grayN` names. Any color spec value (`multi_select_bg`, styles `bg=`/`fg=`, …) resolves through `appendBgCodes`/`appendFgCodes`: the 8 basic ANSI names (`colorNameToBasic`) keep the compact `3X`/`4X` form; everything else goes through `colorNameToIndex` → `spec.ColorsSpec.indexOf` (long/short/alias, first match = lowest index wins) → `38;5;N`/`48;5;N`, falling back to a literal numeric index. The lookup is null-guarded via the `g_colors` global so it is safe before the spec loads (and in tests).
* **Mouse Tracking**:
  * Enabled with `\x1b[?1003h` (any-event, reports button + motion) + `\x1b[?1006h` (SGR coordinates).
  * **Hover**: motion events (SGR Cb bit 5 set) update `selected_idx` to the cell under cursor without triggering copy/exit.
  * **Click**: left-button press (`Cb & ~32 & 3 == 0`, action `M`) on a grid cell copies that emoji and exits; click on the theme icon (right 3 cols of search row) cycles theme.
  * **Wheel** (`Cb & 64`): scrolls whichever pane is shown (grid / settings / categories / help-about-status popups) by a fixed 3-row step, independent of keyboard focus. Direction is `Cb & 1` (0=up, 1=down).
  * **Scrollbar drag**: a left-press or left-drag on the grid scrollbar column (`local_col == content_width`) maps the track row to `grid_scroll_top` via `scrollbarThumb` travel — click-to-jump and drag-to-scroll share one formula.
  * The parser scans for the first `M`/`m` terminator so that batched motion events from `?1003h` do not corrupt parsing.
  * All three exit paths (defer, sigHandler, panic) emit `\x1b[?1003l\x1b[?1006l` to disable tracking.
* **2D Grid Navigation, Scrolling & Focus**:
  * **Result buffer**: `runSearch` fetches up to `defaults.MAX_RESULTS` (5×`MAX_CELLS` = 1280) matches; the visible `cols×rows` grid is a virtualized viewport over them, offset by `grid_scroll_top` (a *row* offset). Cell index = `(grid_scroll_top + r) * cols + c`.
  * **Prompt vs. grid focus**: `selected_idx == null` ⇒ the prompt owns the arrows (real text cursor `query_cursor`); non-null ⇒ the grid owns them. Typing any character always returns focus to the prompt (`selected_idx = null`, `grid_scroll_top = 0`).
  * **`Space` is focus-dependent on the search screen**: with the *prompt* focused (`selected_idx == null`) it types a literal space into the query (multi-term AND search); with the *grid* focused (`selected_idx != null`) it starts multi-select mode and toggles the focused emoji in/out of `multi_selected_emojis` (spacebar-to-select, copying the joined run on each change). The byte-`32` decoder still only maps `space`→logical on non-search screens; the search-screen Space is intercepted in the printable-char branch *before* the query-insert loop, gated on grid focus. Discoverability: help page 1 lists `␣ (Space) Multi-select`, page 2 lists `␣/↵ pick  ⇧↵ done`, and the wide grid-focus status uses `default.on_grid_wide` (`␣:multi` hint); narrow layouts keep the concise status and rely on the help screen.
  * **Configurable cursor box & multi-select highlight** (`spec/strings.json`, embedded — rebuild after editing): the focused/first-hit emoji is wrapped in `cursor_left`…`cursor_right` (default `⌜`…`⌟`; each side **must be exactly one display cell** so the 4-col grid stays aligned — e.g. `[ ]`, `⟨ ⟩`, `▏ ▕`). Picked multi-select cells are prefixed with `multi_select_mark` (default `✓`, also one cell). When `multi_select_mark` is `""` the glyph is dropped and picked cells are instead tinted with `multi_select_bg` (a color name like `green`/`blue` or a 0-255 palette index, resolved via `bgEscape`); the cursor-on-picked cell then keeps the bracket box and gets the `multi_select_bg` tint so brackets=cursor, bg=picked. The closing `cursor_right` is always emitted on the cursor cell (a dropped end-char was the source of the earlier cursor-row misalignment).
  * **Prompt editor**: `Left`/`Right` move `query_cursor`, characters insert at the cursor, Backspace/`delete` removes the byte before it (`deleteAtCursor`), `Home`/`End` jump to start/end. A horizontal scroll window (`query_view_start`) keeps the cursor visible for long queries.
  * **Soft marker vs. hard highlight**: while the prompt has focus and the query is non-empty, the first hit shows plain brackets `[emoji]` in grid colors (no highlight) — the fast path (`type query, Enter` copies hit #1) is unchanged. Arrow-down from the prompt jumps the grid cursor onto that hit and restores the `selection_bg` highlight. Empty query ⇒ no marker (preserved startup state per §3 Startup State).
  * **Keys**: `Up`/`Down`/`Left`/`Right` wrap across the *full* result set (`navSelect` takes the total row count); `PageUp`/`PageDown` move one viewport of rows; `Home`/`End` jump first/last result when grid-focused (cursor start/end when prompt-focused). After any nav, `adjustScrollTop(selected_row, &grid_scroll_top, rows, total_rows)` keeps the selection visible. The same keys scroll the help/about/status/settings/categories panes.
  * **Prompt `Up` is a no-op** (the grid is *below*, so entering it on `Up` reads backwards): only `Down` enters the grid at hit #0. An ignored `Up` rings the bell via `ringBell`, but only once per run of consecutive presses — `bell_suppressed` is re-armed by any other key. The terminal's own bell config decides audible/visual/silent.
  * **Doc screens are pager-like** (`help`/`about`/`status`): `Up`/`Down`/`PageUp`/`PageDown`/`Home`/`End` scroll; `q`/`Esc`/`Enter`/`Space` close → search; **any other printable char jumps back to search and seeds the query** (so the screen never traps the user); unbound keys ring the dead-key bell. Status hint: `view.scrollable` when the content overflows the viewport, else `view.default` (`q/Esc:close`). There is a single `about` page (the quad-block art generated from `spec/art.json` into `about_lines` via `make gen-art`); the former `about2`-`4` multi-page sequence was removed.
* **Scrollbar styles** (`ScrollbarStyle`, `scrollbarThumb`):
  * `.expand` — proportional thumb (`viewport²/total`); `.bar` — fixed single-cell `▐`. One helper drives all six scrollbars (grid + help/about×4/status).
  * Configurable via the Settings screen (6th row), `EMOJIG_SCROLLBAR=expand|bar`, or the `scrollbar_style=` config line — resolved env → config → default `.expand`, persisted with `saveKeyToConfig`.
* **Unified grid size** (`cols`/`rows`):
  * One size drives both the in-TUI grid and the GUI foot window (`content_width = cols*4 + 1`), because users work on one screen. Resolution per axis: `EMOJIG_COLS`/`EMOJIG_ROWS` env → config (`cols=`/`rows=`) → spec default (`spec/layout.json` `tui`/`gui`). Each axis is clamped to `[MIN_COLS, MAX_COLS]`/`[MIN_ROWS, MAX_ROWS]` on load — the **minimum 5×3** (`defaults.MIN_COLS`/`MIN_ROWS`) is enforced even when a config/env value is smaller, so a misconfigured tiny grid can never reach the renderer.
  * The `--gui` parent resolves the size, sizes the foot window via `--window-size-chars`, and passes `EMOJIG_COLS/ROWS` to the child `--tui` so the grid matches the window exactly (`host.spawnGuiWindow` takes explicit `cols_val`/`rows_val`).
  * Settings screen rows 7 & 8 ("grid width (cols)" / "grid height (rows)", rendered `[‹ NN ›]`). Editing, all persisted via `saveUsizeToConfig`:
    * **Left/Right adjust ±1** (`stepGridDim`, clamped to `[MIN, MAX]`); **Space/Enter step coarsely** (`cycleGridDim` by `grid_dim_step`, wraps back to the axis minimum).
    * **Type a digit** to set the value directly — handled in the printable-char branch when a grid-size row is selected; consecutive digits build a number (`typeGridDim`, `griddim_typing` chains "1" then "2" → 12, clamped to the axis max). Typing allows a transient sub-minimum value (a lone "1" en route to "12"); the minimum is enforced on commit via `finalizeGridTyping`/`clampGridDim` when any nav/select/esc key clears `griddim_typing`.
    * **Click the `‹` / `›`** halves to ±1 (`applyGridDimClick` by `local_col` hit-zone: 3–5 `‹`, 8–10 `›`, the digits in between just select for typing).
  * **No per-step popup.** A grid-size change sets `griddim_changed`; the settings status hint then shows the live value + "applies on next launch" (the live grid keeps its launch dimensions, since mid-session grid resizing is unsafe for inline-TUI scrollback reservation — §2). The new size takes effect on the next launch (GUI: reopen; TUI: re-run).
* **Settings interaction model** (no confirm popups):
  * **No per-change confirmation popup.** Toggling/cycling a setting just applies + persists it silently (`toggleSetting` handles the booleans & 2-state enums — shell integration, show-categories, ambiguous chars, scrollbar — without writing `popup_msg`; theme is handled inline for its terminal-colour side effects; key binding saves on Enter without a popup). The only remaining popups are genuine command output (e.g. the update command).
  * **`?` / `h` / `F1` toggle a context-sensitive help modal** for the *selected* row (`settingHelp(idx)` → short enum-value/explanation text shown via the existing `popup_msg` overlay). The **same key closes it again** (press `?` to open, `?` to close): `?`/`h` flip `popup_msg` null↔text in the printable-char branch; `F1` (`\x1bOP` → logical `f1`) opens via the settings key dispatch and is also listed in the popup-dismiss key set, so it closes an open modal. Space/Enter/Esc also dismiss. This is the *settings-screen* help only — the search-prompt inline `?`/`??` help (query text → help page 1 / page 2) is a different code path and is unaffected. The rc-sourcing reminder for shell integration now lives in the help modal, not in a toggle popup.
  * **Left/Right change the selected setting's value**, mirroring Space/Enter: ±1 on grid dims (`stepGridDim`), forward/back cycle on theme (`cycleTheme(t, forward)`), and a plain toggle on the booleans/2-state enums (`toggleSetting`, direction ignored). Row 1 (key binding text input) ignores Left/Right.
  * **Grid-dim `‹` / `›` arrows are always bold** as a clickable affordance, and gain an underline (`\x1b[1;4m…\x1b[22;24m`) while hovered on the *selected* row. `renderSettingRow` takes `hover_left`/`hover_right`; the motion handler sets them by `local_col` hit-zone (3–5 `‹`, 8–10 `›`, matching `applyGridDimClick`), and keyboard nav (`nav_up`/`nav_down`) clears them so no stale underline lingers.
* **Variation Selectors & Reset Sequences**:
  * To prevent terminal rendering engines from dropping or vanishing emoji glyphs that utilize Variation Selectors (e.g., VS15/VS16 like `✈️`, `⚙️`, `8️⃣`, `☺︎`, `✳︎`), never emit terminal reset sequences (`\x1b[0m`) between a cell cursor prefix/bracket and the emoji base character.
  * If the highlight backgrounds of the prefix and body cell match, merge their color properties into a single continuous escape sequence block rather than resetting between them.

---

## 4. Fuzzy Search Engine

> **Read [`docs/SearchEngine.md`](docs/SearchEngine.md) before editing search logic, `spec/boxart.json`, `data/emoji.json`, or `spec/synonyms.json`.** It documents the greedy word-order trap, `isBoxArt` codepoint range (U+2500–U+259F only — keyboard symbols are exempt), synonym-vs-direct-tag tradeoffs, and ranking test guidelines.

Implemented at query time in `src/root.zig` with **zero heap allocations**:
* **Subsequence Scoring** (`matchTermDirect`): Matches a search term as a subsequence of the target with bonuses for word-start positions and consecutive character runs. A late-start penalty discourages sparse matches.
* **Plural Fallback** (`matchTerm`): If a term ending in `s` fails, the engine retries with the singular (`cars` → `car`), including `es` and `ies` endings.
* **Word Stem Fallback** (`matchTerm`): If a term ending in `ing` fails, the engine retries with the bare stem (`rac`) and stem + `e` form (`race`). Double-consonant stems are also handled (`running` → `run`).
* **Query Stem Fallback** (`matchTerm`): If a term ending in `e` fails, the engine retries without the trailing `e`.
* **Multi-term Support** (`fuzzyMatch`): Space-separated terms must all match (AND semantics).
* **Width Filters**: `e:` restricts to double-width emojis, `t:` to single-width text symbols (incl. the VS15 plain twins).
* **Box Art & `b:` Filter**: `spec/boxart.json` adds 68 box-drawing/block glyphs (U+2500–U+259F) with systematic names (`top left double border`, `bottom right border round`, `dark shade`, …). The `b:` prefix filters to them; in general searches a fixed score penalty (`box_art_penalty`) ranks them below genuine emoji matches. `isBoxArt` (Zig) / `IsBoxArt` (Go) classify by codepoint range; the Go port appends the entries in `internal/emoji.Load()`.

---

## 5. Database Packer & Compiler Embedding

* **Compile-Time Embedding**:
  * We do not read JSON or CSV files at runtime. The emoji database is serialized by a custom packer into a binary stream and embedded directly into the binary with `@embedFile("emojis.bin")`.
* **Database Design (`scripts/pack_emojis.go`)**:
  * Translates raw JSON in `data/emoji.json` into a compressed layout.
  * Uses a unified, deduplicated string table containing all names, keywords, and emoji characters.
  * Employs a fixed-size index array of offsets pointing into the string table.
  * **Plain twins**: for every simple VS16 entry (single base codepoint + `U+FE0F`, no ZWJ/keycaps), the packer derives a text-presentation twin (`base + U+FE0E`/VS15) named `<name> plain` with extra `plain text` keywords. VS15 means width 1 in all three width functions (Zig/Go/JS), so the `t:` filter lists the twins. The Go port mirrors this derivation in `internal/emoji.Load()` because it builds its DB from the embedded `data/emoji.json`, not from `emojis.bin`.
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
   * **Single-instance toggle**: a GUI-spawned picker records its PID in `/tmp/emojig-picker-<uid>.pid` (removed on every exit path: defer, sigHandler, panic). A second `emojig --gui` finds the live PID (verified against `/proc/<pid>/cmdline` to guard against PID reuse), SIGTERMs it, and exits 0 — so the same desktop hotkey opens *and* closes the picker. Stale pidfiles are unlinked and launch proceeds normally. No daemon, no IPC (§8-compliant).

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


<!-- claudeconfig:begin Language Conventions -->
Adhere to the following conventions.

- Rust @docs/Rust.md,
  cargo fmt + clippy; safe Rust; avoid .unwrap() in library code
- Bash/Shell @docs/Bash.md,
  No ";", break before then/else/docs
  No "if [[]]", No "if []", Use "if test"
  smart indent!
- Go/Golang @docs/Go.md,
  Modern Go, avoid deps but use Cobra, add tests
<!-- claudeconfig:end Language Conventions -->
