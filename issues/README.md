# Emojig Issues & Backlog Tracker

This directory serves as the centralized backlog for bugs, features, and platform support analysis for the **Emojig** zero-allocation emoji picker.

---

## 🟢 Open Issues (Active Backlog)

| Issue | Title | Priority | Summary |
|---|---|---|---|
| [**02**](02-distribution-and-release.md) | [Distribution & Release Plan](02-distribution-and-release.md) | **P1** | Outlines target package channels (AUR, Nix, Homebrew) and cross-compilation pipeline tasks for tagged releases. |
| [**09**](09-wasm-build-rootless-mknod.md) | [WASM build fails under rootless podman (`mknod` blocked in userns)](09-wasm-build-rootless-mknod.md) | **P1** | c2w's `rootfs` stage `mknod /dev/null` returns EPERM because rootless podman runs in a user namespace; needs a rootful runtime or build VM. |
| [**10**](10-synonym-search-ranking.md) | [Synonym Support for Better Search Ranking](10-synonym-search-ranking.md) | **P2** | Typing "car" surfaces `🚋 tram car` before `🚗 automobile` due to late-match penalty; fix via synonym expansion at match time. |
| [**11**](11-german-search-pferd-fails.md) | [German search "pferd" fails](11-german-search-pferd-fails.md) | **P2** | Non-English search terms fail to match emoji because the database only contains English keywords. |
| [**12**](12-tui-line-cleanup-and-terminal-restoration.md) | [TUI line cleanup & terminal restoration](12-tui-line-cleanup-and-terminal-restoration.md) | **P1** | TUI rows not erased on exit; selected emoji left floating after fade; cursor not restored to pre-launch position — emoji bleeds into shell prompt on Ctrl-E keybind. |
| [**13**](13-terminal-state-diagnostic-tool.md) | [Terminal state diagnostic tool](13-terminal-state-diagnostic-tool.md) | **P1** | No tool exists to inspect active terminal modes (scroll region, mouse tracking, raw mode). Makes it impossible to confirm or reproduce issue #12 cleanup bugs without guessing. |

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
| [**08**](closed/08-install-destination-binary.md) | [Shadowing global system binary on `--install`](closed/08-install-destination-binary.md) | **Closed (Fixed)** | Fixed binary duplication by skipping the local `~/.local/bin` copy when executing from standard system paths (`/usr/bin/`, `/bin/`). |

