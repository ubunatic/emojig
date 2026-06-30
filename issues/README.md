# Emojig Issues & Backlog Tracker

This directory serves as the centralized backlog for bugs, features, and platform support analysis for the **Emojig** zero-allocation emoji picker.

---

## 📝 Review Reports

| Report | Title | Summary |
|---|---|---|
| [**24**](24-ux-and-resilience-review-2026-06.md) | [UX & Resilience Review — 2026-06-21](24-ux-and-resilience-review-2026-06.md) | Consolidated repo review covering current UX/resilience risks, validated new issues, and stale backlog entries. |

---

## 🟢 Open Issues (Active Backlog)

| Issue | Title | Priority | Summary |
|---|---|---|---|
| [**02**](02-distribution-and-release.md) | [Distribution & Release Plan](02-distribution-and-release.md) | **P3** | Release flow exists (GoReleaser + `fj` draft, see `docs/Release.md`). AUR/Nix dropped, Homebrew very low priority; active channels are the `curl \| sh` installer and `.deb`/`.rpm`. |
| [**09**](09-wasm-build-rootless-mknod.md) | [WASM build fails under rootless podman (`mknod` blocked in userns)](09-wasm-build-rootless-mknod.md) | **P1** | c2w's `rootfs` stage `mknod /dev/null` returns EPERM because rootless podman runs in a user namespace; needs a rootful runtime or build VM. |
| [**11**](11-german-search-pferd-fails.md) | [German search "pferd" fails](11-german-search-pferd-fails.md) | **P2** | Non-English search terms fail to match emoji because the database only contains English keywords. |
| [**12**](12-tui-line-cleanup-and-terminal-restoration.md) | [TUI line cleanup & terminal restoration](12-tui-line-cleanup-and-terminal-restoration.md) | **P1** | TUI rows not erased on exit; selected emoji left floating after fade; cursor not restored to pre-launch position — emoji bleeds into shell prompt on Ctrl-E keybind. |
| [**14**](14-gui-desktop-scenario-recording.md) | [GUI desktop scenario recording](14-gui-desktop-scenario-recording.md) | **P3** | New `recordScenarioDemo` records a full desktop story (nested sway + gedit + foot popup + paste) to a webm. Documents headless gotchas: wf-recorder vs x11grab (black frame), wtype modifier no-ops, middle-click PRIMARY paste. Implemented. |
| [**15**](15-mojigo-inline-height-mode.md) | [mojigo inline `--height` mode + `/dev/tty` I/O](15-mojigo-inline-height-mode.md) | **P2** | Ports skim's four inline-TUI mechanics (cursor query, scroll-by-deficit, fixed absolute-coordinate region, clean teardown) into mojigo as an opt-in `--height N\|N%`; routes UI/input through `/dev/tty` so `e=$(mojigo)` is clean. Implemented. |
| [**16**](16-tui-flicker.md) | [Zig TUI flickering during rapid redraws](16-tui-flicker.md) | **P2** | Redundant pre-clearing of lines (`\x1b[2K\r`) at the start of drawing each row causes visual flicker. Rely entirely on trailing clear (`\x1b[K`) instead. |
| [**18**](18-update-rpm-mode.md) | [`:update` command: RPM install mode](18-update-rpm-mode.md) | **P3** | `:update` detects dev/deb/curl modes but not RPM. Documents detection heuristic, `dnf upgrade` vs manual `.rpm` download path, and `captureShellCmd` wiring needed. |
| [**19**](19-update-brew-mode.md) | [`:update` command: Homebrew install mode](19-update-brew-mode.md) | **P3 (blocked)** | `:update` has no Homebrew branch. Blocked on issue 02 (tap not live) and Linux-only build. Documents detection via Cellar path and `brew upgrade` command. |
| [**20**](20-wl-clipboard-opens-as-desk-app.md) | [Fast Multi-Select calls wl-clipboard as visible desktop app](20-wl-clipboard-opens-as-desk-app.md) | **P2** | `copyToClipboard` still spawns raw `wl-copy` with no debounce or child-env cleanup, so GNOME/Wayland notification and dock-noise behavior remains relevant. |
| [**21**](21-color-system-simplification.md) | [Color System Simplification](21-color-system-simplification.md) | **P2** | Consolidate the color definitions and conversions, eliminate hardcoded overrides in the generator, and use `spec/colors.json` as the single source of truth. |
| [**25**](25-xfce4-terminal-autodetect-gap.md) | [GUI auto-mode misses `xfce4-terminal` despite built-in host support](25-xfce4-terminal-autodetect-gap.md) | **P2** | The host kind and argv builder support `xfce4-terminal`, but `selectTerminalHost()` never auto-detects it. |
| [**26**](26-install-and-update-integrity-gap.md) | [`install.sh` and self-update still skip artifact verification](26-install-and-update-integrity-gap.md) | **P1** | The release plan promises verification, but the installer still downloads and extracts without `SHA256SUMS`/`minisign`, and curl-update inherits the same gap. |
| [**27**](27-persistence-buffer-edges.md) | [Config and MRU persistence still have silent 4 KB edge behavior](27-persistence-buffer-edges.md) | **P2** | The config loader still hard-bails on a full 4 KB read, and MRU still uses the same fixed-size single-read pattern without a full-buffer guard. |
| [**38**](38-more-common-search-tests.md) | [Tests for common searches](38-more-common-search-tests.md) | **P2** | Phase 1+2 done: 55 ranking tests + 23 synonyms added; Phase 3 open (food/drinks/feelings: ~20 more tests need synonyms/tags). |

---

## 🔴 Closed / Resolved Issues

These issues have been fully resolved, finalized, or closed by design. Their technical designs and analysis are preserved under `./closed/` for reference.

| Issue | Title | Status | Summary |
|---|---|---|---|
| [**01**](closed/01-config-file-silent-truncation.md) | [Silent config file truncation & partial reads](closed/01-config-file-silent-truncation.md) | **Closed (Fixed)** | Upgraded stack buffers to 4KB and wrapped reading in POSIX loop to prevent silent truncation during theme saves and handle partial reads. |
| [**03**](closed/03-mouse-tracking-enable-ordering.md) | [Mouse tracking enabled before raw-mode setup](closed/03-mouse-tracking-enable-ordering.md) | **Closed (Fixed)** | Reordered terminal sequence emission so that mouse tracking is enabled only after raw mode is active and the restoration `defer` is registered. |
| [**04**](closed/04-plain-terminal-support.md) | [Plain Terminal & Self-Sustained Window Management](closed/04-plain-terminal-support.md) | **Closed (Fixed)** | Completed standalone subprocess execution modes. Implemented `fzf`-like auto-detection to default to inline-TUI in shells and GUI popup on hotkeys. |
| [**05**](closed/05-virtual-console-emoji-support.md) | [Virtual Console Emoji Support](closed/05-virtual-console-emoji-support.md) | **Closed (Fixed)** | Added `TERM=linux` detection and diagnostic warning. Framebuffer `fbterm` auto-spawning was dropped by design to preserve zero-dependency architecture. |
| [**06**](closed/06-vt-copy-paste-and-output-modes.md) | [VT Copy/Paste and Output Modes](closed/06-vt-copy-paste-and-output-modes.md) | **Closed (Fixed)** | Completed clean stdout piping (inline TUI renders on `/dev/tty`) and integrated tmux clipboard fallback (`tmux load-buffer -`). |
| [**07**](closed/07-xterm-emoji-support.md) | [Xterm Emoji Support Analysis](closed/07-xterm-emoji-support.md) | **Closed (Resolved)** | Documented xterm core font limitations, width sequence overrides (`+emoji_width`), and monochrome fontconfig rules. |
| [**08**](closed/08-install-destination-binary.md) | [Shadowing global system binary on `--install`](closed/08-install-destination-binary.md) | **Closed (Fixed)** | Fixed duplication of binary install by selecting `~/.local/bin` only if the active executable is not already in standard PATH. |
| [**10**](closed/10-synonym-search-ranking.md) | [Synonym Support for Better Search Ranking](closed/10-synonym-search-ranking.md) | **Closed (Implemented)** | `spec/synonyms.json` synonym expansion at match time in both engines; 🚗 outranks 🚋 for "car", asserted by Zig and Go tests. Broader ranking work continues on the website roadmap. |
| [**13**](closed/13-terminal-state-diagnostic-tool.md) | [Terminal state diagnostic tool](closed/13-terminal-state-diagnostic-tool.md) | **Closed (Implemented)** | `scripts/termstate.sh` reports raw mode, mouse tracking, scroll region, cursor, paste and altscreen state via DECRQM/DECRQSS with `OK` / `⚠ LEAKED` annotations. |
| [**17**](closed/17-screenshot-keys-and-go-fd-blocking.md) | [Screenshot harness: typed keys + Go `Fd()` blocking gotcha](closed/17-screenshot-keys-and-go-fd-blocking.md) | **Closed (Implemented)** | `scripts/screenshot` types an optional keys arg (e.g. `'??'`) before capturing. Documents two Go PTY traps: poller-parked `os.File.Read` and `Fd()` resetting the fd to blocking. |
| [**17b**](closed/17b-custom-commands-and-screens.md) | [Custom Commands and Interactive Screens](closed/17b-custom-commands-and-screens.md) | **Closed (Implemented)** | Fixed compiler warnings and type mismatches during initial settings layout integration, added Screenshot and REUSE preflights for custom category screens. |
| [**22**](closed/22-category-switcher.md) | [Category Switcher UI](closed/22-category-switcher.md) | **Closed (Implemented)** | Implemented horizontal category switcher bar in TUI/GUI, cycling with Tab/Shift-Tab, and supporting explicit/implicit category filters. |
| [**23**](closed/23-picker-timeout-fires-during-drag.md) | [Picker Timeout Fires During Scrollbar Drag](closed/23-picker-timeout-fires-during-drag.md) | **Closed (Implemented)** | Resolved the bug where picker inactivity timeout fired during active scrollbar drag by updating the timeout clock on any stdin/TTY event. |
| [**28**](closed/28-keyboard-key-symbol-discoverability.md) | [Keyboard key symbol discoverability](closed/28-keyboard-key-symbol-discoverability.md) | **Closed (Implemented)** | Added ↵ ⭾ ⎀ ⇞ ⇟ ⇱ ⇲; fixed `cmd`→⌘ word-order trap; added `"key"` tag to arrow emoji. All key symbols rank #1-3. `findRank` test covers 16 symbols. |
| [**29**](closed/29-category-synonym-search-ranking.md) | [Category synonym search ranking bug](closed/29-category-synonym-search-ranking.md) | **Closed (Fixed)** | Fixed category synonym implicit detection. Synonyms are no longer stripped from queries, resolving search ranking degradation (e.g. for "car"). |
| [**30**](closed/30-compact-grid-mode.md) | [Compact Grid Mode (EMOJIG_COMPACT=1)](closed/30-compact-grid-mode.md) | **Closed (Implemented)** | Implemented togglable compact grid layout, unified grid dimensions settings, resolved scrollbar/bracket layout alignment, and fixed variation-selector rendering bugs. |
| [**31**](closed/31-configurable-scrollbar-and-padding-with-viewport-clamping-fix.md) | [Configurable Scrollbar & Padding with Viewport Clamping Fix](closed/31-configurable-scrollbar-and-padding-with-viewport-clamping-fix.md) | **Closed (Implemented)** | Made the scrollbar thumb character and top padding row configurable via specs, and fixed grid viewport/scrollbar height clamping when category switcher is active. |
| [**32**](closed/32-toolbar-ui-hamburger-separator-end-cap.md) | [Search Bar Toolbar: Hamburger Menu, Separator & End Cap](closed/32-toolbar-ui-hamburger-separator-end-cap.md) | **Closed (Implemented)** | Added `≡` hamburger icon (toggle settings), `toolbar_sep` configurable separator, `▐` end cap for visual transition to terminal bg. Fixed `endRowFull()` bug: `\x1b[K` from pending-wrap erased the cap in exact-width GUI windows. |
| [**33**](closed/33-configurable-pane-separators-and-developer-watch-mode.md) | [Configurable Pane Separators & Developer watch-run Mode](closed/33-configurable-pane-separators-and-developer-watch-mode.md) | **Closed (Implemented)** | Implemented `"hline_char"` spec configuration in TUI layout rendering to allow custom horizontal separating lines, and added `make watch-run` watcher task to automatically compile and run GUI on file modifications. |
| [**35**](closed/35-color-overhaul-container-controls-system.md) | [Color Overhaul & Container/Controls Styling System](closed/35-color-overhaul-container-controls-system.md) | **Closed (Implemented)** | Centralized all app margins, grid container, settings view, scrollbar rail, and search bar separator/caps styling under `spec/theme.json`, and silenced runtime color compatibility warnings. |
| [**36**](closed/36-searchbar-granular-color-and-char-config.md) | [Searchbar Granular Color & Character Configuration](closed/36-searchbar-granular-color-and-char-config.md) | **Closed (Implemented)** | Added per-segment sep colors, configurable cap glyphs, text-area fg overrides, and fixed null-color fallback to app bg ("punch-through") for seps and caps. |
| [**34**](closed/34-configurable-cmd-start-chars.md) | [Configurable Command Start Characters](closed/34-configurable-cmd-start-chars.md) | **Closed (Implemented)** | `spec/commands.json` `cmd_start_chars` field; `src/main.zig` uses `indexOfScalar`; PTY tests updated from `:cmd` to `/cmd`. |
| [**37**](closed/37-codebase-modularization.md) | [Codebase Modularization & Refactoring](closed/37-codebase-modularization.md) | **Closed (Implemented)** | `src/cli.zig`, `src/input.zig`, `src/render.zig` extracted; hardcoded key table deleted, replaced by `spec/input.yaml` spec-table decoder. |

