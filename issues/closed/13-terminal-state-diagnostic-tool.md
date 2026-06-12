# Terminal State Diagnostic Tool

**Status:** Closed (Implemented) — `scripts/termstate.sh` exists and reports
per-mode `OK` / `⚠ LEAKED` / unknown states via DECRQM/DECRQSS queries
against `/dev/tty`, as specified below.

## Problem

When investigating terminal state corruption (e.g. scroll region leak, stale
mouse tracking, raw mode not restored — see issue #12), there is no way to
inspect what terminal modes are currently active. The terminal gives no
feedback. This makes it hard to:

- Confirm whether emojig left a dirty state after exiting.
- Identify *which* mode was not restored.
- Write a reliable regression test for cleanup bugs.
- Reproduce and bisect issue #12 (Bug 4: scroll region leak).

## Proposed Fix

A lightweight diagnostic script `scripts/termstate.sh` (POSIX shell) that
prints a human-readable summary of the terminal's current state. It should be
runnable at any time from the shell prompt — before and after an emojig run —
so the user can diff the output and immediately see what changed.

### What to report

| Category | How to query |
|---|---|
| **Raw/cooked mode** | `stty -a` — check `icanon`, `echo`, `-raw`, etc. |
| **Mouse tracking** (`?1003`) | `DECRQM`: `\x1b[?1003$p` → terminal replies `\x1b[?1003;N$y` (N=1 set, N=2 reset) |
| **Mouse SGR** (`?1006`) | `DECRQM`: `\x1b[?1006$p` |
| **Scroll region** (DECSTBM) | `DECRQSS`: `\x1b[P$qr\x1b\\` → terminal replies with current `Pt;Pbr` values |
| **Cursor visibility** (`?25`) | `DECRQM`: `\x1b[?25$p` |
| **Cursor style** | `DECRQSS`: `\x1b[P$q SP q\x1b\\` |
| **Bracketed paste** (`?2004`) | `DECRQM`: `\x1b[?2004$p` |
| **Alternate screen** (`?1049`) | `DECRQM`: `\x1b[?1049$p` |

DECRQM (DEC Request Mode) and DECRQSS (Request Status String) are widely
supported by `foot`, `kitty`, `alacritty`, `xterm`, `wezterm`. Terminals that
do not support a query simply do not reply — the script must use a short
timeout (`read -t 0.2`) to avoid hanging.

### Example output

```
=== Terminal State ===
stty:         icanon echo  (cooked — OK)
Scroll region: 1;24r        ← SET (full terminal = 1;48r → LEAKED if mismatched)
Mouse ?1003:  RESET (2)     OK
Mouse ?1006:  RESET (2)     OK
Cursor vis:   SET (1)       OK (visible)
Alt screen:   RESET (2)     OK
```

### Usage workflow for debugging issue #12

```sh
scripts/termstate.sh          # baseline — all modes should be reset
emojig --tui                  # run and exit
scripts/termstate.sh          # compare — leaked modes appear as SET/changed
```

## Implementation Notes

- **POSIX shell only** — no Python. Follow `AGENTS.md §1` shell conventions
  (`test` instead of `[`, `then` on its own line).
- Must include SPDX headers for REUSE compliance (`make preflight`).
- Use `stty -F /dev/tty` so the script works even when stdout is redirected.
- Each DECRQM/DECRQSS query must write to `/dev/tty` and read from `/dev/tty`
  directly (not stdin/stdout), so the script is safe inside pipelines.
- A `read -t 0.2` timeout per query prevents hangs on unsupported terminals.
- Print a clear `OK` / `⚠ LEAKED` / `UNKNOWN (terminal did not reply)`
  annotation beside each line for at-a-glance reading.

## Acceptance Criteria

- [ ] `scripts/termstate.sh` runs without error in a clean terminal session
- [ ] Reports `OK` for all modes in a clean session
- [ ] After an emojig run with cleanup bug present, reports `⚠ LEAKED` for the
      affected mode(s) (scroll region, mouse tracking, etc.)
- [ ] Script does not hang if the terminal does not support a DECRQM query
- [ ] Works inside `foot`, `kitty`, `alacritty`, `xterm`
- [ ] SPDX headers present — `make preflight` passes
- [ ] Running before/after `emojig --tui` produces a diff that pinpoints the
      leaked mode, enabling reliable regression testing for issue #12
