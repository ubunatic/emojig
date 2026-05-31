# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-31

### Added
- Zero-allocation high-performance dark and light theme system (`--theme [dark|light|system]`, `EMOJIG_THEME` environment variable).
- Automatic terminal background color query via OSC 11 to set system dark/light theme.
- Support for inline TUI (`--tui`) and automated Wayland floating window GUI mode (`--gui`) utilizing the foot terminal.
- Zero-allocation fuzzy search engine supporting space-separated multi-term search (AND semantics).
- Advanced fuzzy search fallbacks: plural matching (`cars` -> `car`), word stem matching (`running`/`racing` -> `run`/`race`), and trailing 'e' query stem matching.
- Borderless 2D grid navigation for emojis supporting arrow keys, mouse hover, and click selection.
- Optional colored border layout when `EMOJIG_BORDER=1` is configured.
- Dynamic selected emoji name description bar at the bottom of the grid.
- Compile-time emoji database packer (`scripts/pack_emojis.go`) and embedding (`@embedFile("emojis.bin")`) to achieve zero runtime file reads.
- Shell widget integration (Ctrl+E by default) with custom key binding support via `EMOJIG_KEY` for `zsh`, `bash`, and `fish`.
- Clipboard copying using `wl-copy` or `xclip` in standalone, piped, or shell widget mode.
- Self-install flag (`emojig --install`) to copy the binary to `~/.local/bin/emojig` and install shell integration files.
- Programmatic TUI simulation script (`scripts/test_tui.go`) and TUI screenshot capturing utilities.
- POSIX signal handlers (`SIGINT`, `SIGTERM`, `SIGHUP`) and standard panic function overrides to guarantee terminal state restoration.
- Resident memory auditing on exit via raw POSIX system calls to `/proc/self/statm`, appending to `/tmp/emojig.log`.
- Build automation with Makefile targets and customized packaging using GoReleaser.

### Fixed
- Double-close stdin panic on process wait during clipboard copying.
- Option and code injection vulnerability in shell widget key bindings (`EMOJIG_KEY`).
- Layout rendering staircase effect in uncooked terminal mode by using `\r\n` line endings.

## [0.0.0] - 2026-05-31

### Added
- Initial project initialization (`zig init`) and basic repository skeleton.

