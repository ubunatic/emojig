# Codebase Modularization & Refactoring

**Status:** Open  
**Priority:** P2  

---

## 🔍 Context and Refactoring Goals

During the initial development phases of **Emojig**, `src/main.zig` grew to a monolithic size of over 5,100 lines. Similarly, the primary unit testing suite `src/root_test.zig` reached more than 1,000 lines. This concentration of logic in single files caused several issues:
1. **High Cognitive Load**: Understanding or tracing the TUI event loop required navigating through unrelated layout calculations, helper parsing tests, and OS subprocess clipboard triggers.
2. **Slow Test Iteration**: Ranking and performance benchmarks ran concurrently with every simple unit test, cluttering debugging output.
3. **Harder Maintenance**: Changes to subprocess execution or formatting rules directly risked breaking event loop safety invariants.

---

## 🟢 Work Completed in this Session

We successfully initiated the modularization plan by separating concerns into dedicated, single-responsibility files:

### 1. Extraction of UI Layout/Sizing Helpers
* **Refactoring**: Moved the `adjustScrollTop` viewport calculation logic out of `src/main.zig` into `src/tui_draw.zig` and made it public.
* **Test Isolation**: Moved all associated utility unit tests (`deleteAtCursor`, `wordLeft`, `wordRight`, `scrollbarThumb`, `scrollbarCell`, etc.) to the bottom of the files they test (`src/tui_draw.zig` and `src/config.zig`).

### 2. Clipboard Integration Isolation
* **Refactoring**: Moved all clipboard piping and spawning logic (including `wl-copy`, `xclip`, `tmux`, and the OSC 52 escape code fallback) from the bottom of `src/main.zig` into a new dedicated module, [`src/clipboard.zig`](file:///home/uwe/projects/emojig/src/clipboard.zig).

### 3. Test Suite Splitting
* **Refactoring**: Moved search ranking datasets, localization checks, and throughput benchmarks out of `src/root_test.zig` into a dedicated file, [`src/ranking_test.zig`](file:///home/uwe/projects/emojig/src/ranking_test.zig).
* **Test Graph Integration**: Wired `src/ranking_test.zig` into `src/root.zig`'s root test block.
* **Outcome**: Reduced `src/root_test.zig` to ~330 lines, focusing it strictly on core library algorithms.

---

## 🔴 Remaining Refactoring Tasks

To complete the modularization proposal, the following splits should be performed in future sessions:

### 1. CLI Parsing & Env Resolution (`src/cli.zig`)
* **What to move**: The CLI flag iteration (`args_it.next()`), environment variables resolution (`EMOJIG_THEME`, `EMOJIG_WIDTH`, etc.), config loading (`loadConfig`), and final settings resolution.
* **Goal**: Isolate entry-point handling and subcommand execution from the interactive loop, outputting a clean read-only `Config` or `Args` struct.

### 2. Escape Sequence Decoder & Keyboard Dispatch (`src/input.zig`)
* **What to move**: The SGR mouse tracking parser (`sgr_loop` for coordinate parsing) and key sequence translation tables.
* **Goal**: Isolate terminal input decoding, making mouse hover/click actions testable independently.

### 3. Canvas Layout & Screen Renderers (`src/render.zig`)
* **What to move**: Page-specific drawing routines, settings row renderers, border rendering, and choice dropdown overlays.
* **Goal**: Decouple the TUI rendering loop from event-handling state machines.
