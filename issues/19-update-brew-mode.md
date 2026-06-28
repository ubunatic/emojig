---
title: ":update command: Homebrew install mode"
status: blocked
priority: p3
---

# Issue 19 — `:update` command: Homebrew install mode

**Priority:** P3 (blocked on brew tap being set up — see issue 02)
**Status:** Open (blocked)

## Summary

The `:update` command cannot self-update when emojig was installed via Homebrew. Homebrew is low priority per issue 02, but the update path should be documented and stubbed for when the tap is live.

## Detection

```sh
brew list emojig >/dev/null 2>&1
# or check for the Cellar entry:
test -d "$(brew --cellar)/emojig"
```

From Zig, detecting Homebrew is harder since `brew --cellar` requires spawning a process. A reasonable heuristic: check if the running binary path contains `/Cellar/emojig/`:

```zig
// get own exe path via std.process.executablePath
// check if it contains "/Cellar/emojig/"
```

## Update Command

```sh
brew upgrade emojig
```

If the tap is configured:
```sh
brew upgrade ubunatic/tap/emojig
```

## Implementation Notes

- Add a detection branch in `runUpdate` (in `src/main.zig`) after the deb check and before the curl-install fallback.
- Homebrew is macOS-primary; emojig currently only supports Linux (see install.sh). If/when macOS support lands, this becomes relevant. For now, the detection can be gated on `uname -s == Darwin`.
- The Homebrew tap repo (`codeberg.org/ubunatic/homebrew-tap`) must be live and the formula must publish a binary bottle for this to work without source compilation.

## Blocking Dependencies

- Issue 02: Homebrew tap not yet set up.
- macOS/ARM support: emojig's POSIX system calls and musl-static build are Linux-only.
