<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "emojig update fails on systems that reject writes to a still-open binary"
status: open
priority: p2
---

# 064 — `emojig update` fails on systems that reject writes to a still-open binary

**Status**: Open
**Priority**: P2 (Medium)
**Severity**: Major
**Category**: Bug
**Related**: 026

---

## Problem

Reported by the user on an Omarchy/Arch-based Wayland distro, installed via
the `curl | sh` line: running `emojig update` (or the in-app update action)
fails instead of completing.

The curl-install update path re-runs the installer while the currently
running `emojig` process still has its own executable open:

- `src/integration.zig:286` — `cmd = "curl -sSf https://ubunatic.com/emojig/install.sh | sh";`
- `scripts/install.sh:68` — `cp "$TMP_DIR/emojig" "$INSTALL_DIR/emojig"`

`cp` opens the existing `$INSTALL_DIR/emojig` for writing and truncates it in
place. Some systems enforce ETXTBSY-style "text file busy" semantics more
strictly for in-place writes to a running executable's inode than others do
(the user's report on Omarchy/Arch is the concrete case in hand — kernel/FS
combination not yet pinned down). Linux generally allows *replacing* the
directory entry with `rename()` even while the old inode is still executing
(the running process keeps the old, now-unlinked inode open), but an in-place
`open()+truncate()+write()` onto the same inode is exactly the case that gets
rejected on stricter systems.

## Evidence

- `src/integration.zig:274-295` (`runUpdate`) — curl-install branch just shells
  out to the installer and captures its output; no ETXTBSY handling or retry.
- `scripts/install.sh:68-69` — `cp` + `chmod +x` write in place, no
  write-to-temp-then-rename.

## Reproduction

Not yet reproduced locally (needs an Omarchy/Arch VM or a filesystem that
enforces this). User-reported: `emojig update` (installed via
`curl -sSf https://ubunatic.com/emojig/install.sh | sh`) fails while the
picker binary is running.

## Why this matters

Self-update is the main upgrade path for the curl-install channel (see
[Issue 26](26-install-and-update-integrity-gap.md) for the related
verification gap on the same path). If it silently or loudly fails on some
distros, those users are stuck on stale binaries with no working remediation
other than re-running the installer manually and hoping it works outside the
running app.

## Suggested fix

Make `scripts/install.sh` write the new binary to a temp file in the same
directory as the target, then atomically `mv`/`rename` it into place:

```sh
tmp_bin="$INSTALL_DIR/.emojig.new.$$"
cp "$TMP_DIR/emojig" "$tmp_bin"
chmod +x "$tmp_bin"
mv "$tmp_bin" "$INSTALL_DIR/emojig"
```

`rename()` within the same filesystem is atomic and does not require the
target to be closed, so this should be safe even while the old binary is
still executing (POSIX unlink-while-open semantics apply). Apply the same
pattern anywhere else the installer or a future self-update path writes
directly over the live executable.

## Related

- [Issue 26](26-install-and-update-integrity-gap.md) — install/update path
  also skips checksum/signature verification; both issues touch
  `scripts/install.sh`'s binary-write step and could be fixed together.
