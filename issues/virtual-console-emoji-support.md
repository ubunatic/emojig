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

## Current behaviour (implemented)

On `TERM=linux`, emojig prints a diagnostic to stderr and exits 1 before
entering raw mode, unless `--tui` or `--gui` is passed explicitly:

- `emojig` → exits with the warning below
- `emojig --tui` → bypasses the guard and runs anyway (user accepts degraded rendering)
- `emojig --gui` → bypasses the guard and spawns foot (requires a GUI session)

```
emojig: Linux virtual console detected (TERM=linux).
Emoji glyphs cannot render in the kernel console font.

Options:
  * Install fbterm:  sudo apt install fbterm
    Then run:        fbterm -- emojig
  * Or switch to a terminal emulator (foot, alacritty, kitty, ...)
  * Or connect via SSH from a machine with a terminal emulator
```

## Getting emojis to work on a VT

The only practical path is a framebuffer terminal that uses FreeType for glyph
rendering, bypassing the kernel PSF font entirely.

### fbterm

`fbterm` (Ubuntu/Debian: `sudo apt install fbterm`) renders to `/dev/fb0` via
FreeType/fontconfig. It supports the full Unicode range, so emoji codepoints
render — but **monochrome only**: NotoColorEmoji renders as black-and-white
outlines; color is lost.

**Permission requirement**: fbterm needs read/write access to `/dev/fb0`.
Running as root works but breaks stdin tty detection (`stdin isn't a interactive
tty!`). The correct fix is to add your user to the `video` group:

```sh
sudo usermod -aG video $USER
# log out and back in for the group change to take effect
```

Then run from a real VT (Ctrl+Alt+F3):

```sh
fbterm -- emojig --tui
```

**Important**: fbterm only works on a bare VT. It cannot run inside a Wayland
or X11 session — the compositor owns the display via KMS/DRM and `/dev/fb0`
is inaccessible or invisible behind the compositor. In a graphical session,
use a terminal emulator (foot, kitty, alacritty) that already supports color
emoji natively.

### kmscon

`kmscon` is a userspace VT replacement using KMS/DRM + Pango. It supports full
Unicode including color emoji and is more capable than fbterm, but is less
commonly packaged and heavier. `sudo apt install kmscon` on Ubuntu.

## Options for emojig

### Option A — Detect and warn ✓ done

Implemented. See "Current behaviour" above.

### Option B — Auto-launch fbterm (mirrors --gui/foot pattern)

When `TERM=linux` and `/dev/fb0` is accessible and `fbterm` is in PATH, auto-
spawn `fbterm -- emojig --tui` rather than printing the warning. Same subprocess-
spawn pattern already used for `--gui`/foot.

**Caveat**: monochrome emoji only. Requires user to be in the `video` group —
if `/dev/fb0` is not accessible the fallback is the existing warning.

**Effort**: medium.
**Trade-off**: silent degradation to monochrome; group membership is a one-time
setup step the user must do regardless.

### Option C — `emojig --setup` mode (longer term)

A guided setup subcommand that detects the environment and installs/configures
what is needed:

```
emojig --setup          # auto-detect context, guide interactively
emojig --setup fb       # virtual console: check fbterm, font, group membership
emojig --setup gui      # Wayland/X11: ensure foot, .desktop, icon
```

**Effort**: large — new subcommand, interactive prompts, privilege checks.
**Trade-off**: best long-term UX; overkill until there is user demand.

## Recommended plan

1. **Done**: Option A — `TERM=linux` guard with diagnostic message; `--tui`
   bypasses for users who know what they're doing (e.g. `fbterm -- emojig --tui`).
2. **Next**: Option B — auto-detect `/dev/fb0` accessible + fbterm in PATH and
   spawn fbterm automatically, falling back to the warning if unavailable.
3. **Later**: Option C if virtual console usage becomes a real user need.
