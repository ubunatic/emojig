# Codebase Modularization & Refactoring

**Status:** Closed  
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

## ✅ Work Completed (Session 2)

The three remaining splits from the original plan were all landed in commit `150f6a6`
and follow-up work:

### 1. CLI Parsing & Env Resolution (`src/cli.zig`) — **DONE**
Extracted CLI flag iteration, env-var resolution (`EMOJIG_THEME`, `EMOJIG_COLS`,
`EMOJIG_ROWS`, etc.), `loadConfig`, and settings finalisation into `src/cli.zig`
(465 lines). `main.zig` now calls `cli.parseArgs()` to get a `Config` struct.

### 2. Escape Sequence Decoder & Keyboard Dispatch (`src/input.zig`) — **DONE**
Extracted `SgrMouseEvent` / `nextSgrMouseEvent` (SGR parser) and `decodeEscapeKeySpec`
into `src/input.zig`. Critically, the hardcoded sequence table was **deleted entirely**
and replaced with a spec-table loaded from `spec/input.yaml` at startup — see
[SpecDrivenConfig.md §4](SpecDrivenConfig.md) and [KeyDispatch.md §2](KeyDispatch.md).
`pub const KeySeq` is defined here and re-exported from `spec.zig`.

### 3. Canvas Layout & Screen Renderers (`src/render.zig`) — **DONE**
Settings row rendering and related display logic extracted to `src/render.zig` (89
lines). `main.zig` calls `render.renderSettingRow(…)` instead of inlining the logic.
