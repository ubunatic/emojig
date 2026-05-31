# Issue: Emoji rendering fails in Linux virtual console (VT)

## Problem

When `emojig` is run in a Linux virtual console (e.g. Ctrl+Alt+F3, no desktop
session active), no emojis are visible. The TUI renders but all emoji cells are
blank or replaced by placeholder glyphs.

Note: this is the kernel VT / virtual terminal, not a virtual console terminal
emulator. The VT driver does sit on top of virtual console hardware internally,
but from the app's perspective the relevant fact is the console font constraint,
not the display hardware.

**Root cause**: The Linux kernel console uses PSF bitmap fonts. PSF2 supports
at most 512 glyphs — emoji codepoints are nowhere in that space. This is a
hard constraint of the kernel VT driver; no amount of ANSI/Unicode output from
emojig can work around it.

## Detection signal

`TERM=linux` is the reliable indicator. In a terminal emulator (foot, alacritty,
kitty, xterm, etc.) `TERM` is always set to something else even when there is no
GUI session (e.g. SSH). Combined with the existing no-`DISPLAY`/no-`WAYLAND_DISPLAY`
check this unambiguously identifies the Linux console.

A secondary check — stdin/stdout pointing to `/dev/ttyN` rather than `/dev/pts/N`
— can confirm, but `TERM=linux` alone is sufficient in practice.

## Options

### Option A — Detect and warn (recommended, implement now)

In the TUI entry path, check `TERM == "linux"`. If true, print a short
diagnostic to stderr and exit with a non-zero code before entering raw mode:

```
emojig: Linux virtual console detected (TERM=linux).
Emoji glyphs cannot render in the kernel console font.

Options:
  • Install fbterm:  sudo apt install fbterm
    Then run:        fbterm -- emojig
  • Or switch to a terminal emulator (foot, alacritty, kitty, …)
  • Or connect via SSH from a machine with a terminal emulator
```

**Effort**: ~5 lines of Zig — one env var check before `tcsetattr`.
**Trade-off**: user must act; emojig does not fix it automatically.

### Option B — Auto-launch fbterm (mirrors --gui/foot pattern)

`fbterm` (available in Ubuntu/Debian apt universe) uses fontconfig + freetype
and supports Unicode. Like `--gui` spawns `foot`, a `--fb` flag (or
auto-detect when `TERM=linux` and `/dev/fb0` exists) could spawn:

```
fbterm -s 14 -- emojig --tui
```

**Caveat**: fbterm renders glyphs via freetype but does NOT support color emoji
(NotoColorEmoji renders monochrome). The UX improves (glyphs appear) but
color is lost. fbterm also requires the user to be in the `video` group or run
as root for `/dev/fb0` access.

**Effort**: medium — same subprocess-spawn pattern already used for foot.
**Trade-off**: silent degradation to monochrome; group membership friction.

### Option C — `emojig --setup` mode (longer term)

A guided setup subcommand that detects the environment and installs/configures
what is needed:

```
emojig --setup          # auto-detect context, guide interactively
emojig --setup fb       # virtual console: check fbterm, font, group membership
emojig --setup gui      # Wayland/X11: ensure foot, .desktop, icon
```

This fits naturally into the existing auto-install pattern (the binary already
writes `.desktop` and SVG icon files on first run). Scripts in `scripts/` are
a dev-repo stepping stone toward this.

**Effort**: large — new subcommand, interactive prompts, privilege checks.
**Trade-off**: best long-term UX; overkill until there is user demand.

## Recommended plan

1. **Now**: implement Option A (the `TERM=linux` check + error message).
2. **Soon**: add `scripts/setup-fbterm.sh` as a dev-repo helper for anyone
   who genuinely needs virtual console use.
3. **Later**: revisit Option B or C if virtual console usage becomes a real
   user need — the `--setup` shape from Option C generalises well and
   aligns with the existing desktop-integration auto-install behaviour.
