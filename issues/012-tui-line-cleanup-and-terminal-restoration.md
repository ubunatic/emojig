---
status: open
priority: p1
---

# TUI Line Cleanup & Terminal Restoration

**Status**: Open
**Priority**: P1 (High)
**Severity**: Major
**Category**: Bug
**Related**: —

---

## Update 2026-08-11 — audit pass: most of this is implemented; Bug 4's hypothesis is wrong

Source audit only (no manual terminal verification, which is why this stays
open — most remaining acceptance criteria are inherently visual). What the
current tree actually shows:

**Confirmed implemented:**

- The 2026-06-10 `RESTORE` / `RESTORE_ALT` split is in place
  (`src/term.zig:318-319`), selected via `global_alt_screen` through
  `restoreSeq()` (`src/main.zig:143,153`). DECAWM is correctly `\x1b[?7h`
  in both, not the no-op ANSI mode 7.
- Per-row erasure exists and uses **only** `\x1b[2K`, never ED:
  `clearTuiRows` (`src/main.zig:212`) jumps to `global_tui_start_row`
  absolutely, then walks `height` rows emitting `CR_CLEAR_LINE`
  (`\r\x1b[2K`) + `CURSOR_DOWN_CR`, and returns the cursor to TUI row 0.
- **Exit-path wiring, corrected understanding**: `clearTuiRows` is called
  from the `panic` override (`src/main.zig:292`). The normal *and* signal
  exit path is the `defer` block at `src/main.zig:1027`, which does its own
  equivalent absolute-jump + per-row `CLEAR_LINE` loop (~1072-1100) after
  the CPR handshake. `sigHandler` (`src/main.zig:276`) deliberately does
  **not** clear rows — it is documented in-source as a "V1 legacy handler"
  reachable only *before* the TUI block installs its self-pipe (e.g.
  spec-load or TTY-open failure), where no TUI rows have been drawn yet.
  So "rows erased on SIGINT/SIGTERM" is satisfied by the self-pipe → defer
  route, not by `sigHandler`; do not "fix" `sigHandler` to clear rows —
  terminal I/O in signal context is exactly what §2 forbids.

**Bug 4 is based on a false premise — do not chase it as written.**
There is **no DECSTBM anywhere in `src/`**: a grep for `\x1b[...r` /
`DECSTBM` / scroll-region setting across all of `src/*.zig` returns
nothing. Emojig never sets a restricted scroll region, so it cannot leak
one, and the "Scroll region reset to full-screen (`\x1b[r]`) on every exit
path" acceptance criterion below is **moot** — there is nothing to reset.
If the reported symptom (shell output scrolling to the top after emojig
runs) is still reproducible, its cause is something else entirely and needs
re-diagnosing from scratch; `make termstate` reporting scroll region
`1;50r` in the Bug 5 transcript is just the terminal's own full-height
default, not evidence emojig set it.

**Where `\x1b[J`/`\x1b[2J` still appear** — three sites in `src/main.zig`,
all in the *redraw* path, none in exit cleanup:
`term_lib.CLEAR_SCREEN` at 1542 (altscreen mode only, on resize — safe, the
alt screen has its own buffer and never contributes to scrollback), and
`term_lib.CLEAR_BELOW` at 1554 and 1559 (inline mode, on the
hidden↔visible transition). The last two do erase from the TUI's first row
downward and are the only remaining tension with this issue's strict
"per-row `\x1b[2K`, nothing more" invariant; they are a plausible
suspect for Bug 5 if it still reproduces, and are worth re-checking before
anyone re-audits `clearTuiRows` (which is already correct).

## Update 2026-06-10 — residual "extra lines on close" root-caused (VTE terminals)

After the per-row cleanup landed, the TUI still closed with blank lines between
the launching command and the next prompt — but **only in VTE terminals**
(Tilix, GNOME Terminal, Ptyxis). Not reproducible in foot or tmux, in any size,
on any exit path (Enter/Esc/Ctrl-C/mouse click, top/bottom of screen).

**Root cause:** the shared `RESTORE` sequence unconditionally emitted
`\x1b[?1049l` (leave alt screen) on every exit — including `--tui` inline mode,
which never enters the alt screen. VTE executes the "restore saved cursor" half
of `?1049l` even when the alt screen is not active, yanking the cursor away
from the position the cleanup just parked it at. foot and tmux ignore the
unmatched `?1049l`, masking the bug there. The Go `mojigo` inline mode was
immune because its `Restore` never touches `?1049` (the correct behavior —
see `internal/term/term.go`).

**Secondary finding (confirmed by foot's stderr `SM with unimplemented mode: 7`):**
startup sent `\x1b[7l` and RESTORE sent `\x1b[7h` — ANSI mode 7, a no-op
everywhere. The intent was DECAWM: `\x1b[?7l` / `\x1b[?7h`. Auto-wrap was
therefore never actually disabled during rendering.

**Fix:** `term.zig` now has `RESTORE` (no `?1049` — inline mode) and
`RESTORE_ALT` (with `?1049l` — alt-screen mode), selected via a
`global_alt_screen` flag set when `?1049h` is emitted, on all exit paths
(defer, panic). DECAWM sequences corrected to `?7l`/`?7h`.

## Problem

After the TUI closes (via emoji selection, Ctrl-C, or the Ctrl-E zsh keybind),
the rows it drew are **not erased**. The terminal is left with the TUI's visual
remnants in place, and the cursor is not returned to the pre-launch position.
Some terminal state changes also **persist across the rest of the session**,
affecting the shell even after emojig has fully exited.

Four distinct symptoms — all caused by incomplete cleanup/restoration:

### Bug 1 — TUI lines not cleared on exit

All rows written by the TUI (search bar, padding rows, emoji grid rows,
description row, status bar, optional border rows) remain on screen after the
fade animation completes. The selected emoji appears "floating in a void" with
no surrounding UI context.

Visible in reproduction: the 🔥 emoji is left on screen surrounded by blank
terminal rows after `emojig --tui` returns.

### Bug 2 — Selected emoji not cleared during fade

When an emoji is selected and the TUI fades out, the highlighted/selected
glyph persists on screen — it does not disappear as part of the fade animation.
This is a separate symptom from Bug 1: even if row-clearing were fixed, the
selected cell must be explicitly cleared *before* or *during* the fade, not
after.

### Bug 3 — Emoji bleeds into the shell prompt (Ctrl-E keybind path)

When the TUI is opened via the Ctrl-E keybind on an empty shell prompt, the
selected emoji appears **embedded inside the shell prompt** after the TUI exits
(e.g. `emojig git:(main) × 🔥█`). This confirms that the cursor is not
returned to its pre-launch column/row before the shell redraws its prompt.

Reproduces consistently via:

```sh
emojig --tui                   # direct
echo "$(emojig --tui)"         # subshell
# Ctrl-E on an empty prompt    # zsh keybind
```

### Bug 4 — Scroll region leak persists across the terminal session

**Observed in a clean terminal session**: after running `emojig` at least once
(via Ctrl-E or direct invocation), subsequent typing in the shell causes the
cursor line to **scroll to the top of the terminal** as soon as output is
produced — even though emojig has fully exited.

This is a classic **scroll region leak**. The TUI likely sets a restricted
scroll region with `\x1b[N;Mr]` (DECSTBM) to confine in-place rendering, but
never resets it to the full terminal height with `\x1b[r]` on exit. The stale
scroll region then governs all subsequent shell output for the rest of the
session.

**Distinguishing characteristic**: unlike Bugs 1–3 (which are visible
immediately on TUI exit), this symptom only manifests the *next time the user
types* after emojig has run. It persists until the terminal window is closed
or the scroll region is manually reset.

### Bug 5 — Terminal content above the TUI is erased; scrollback is wiped

**Observed sequence** (confirmed with `make termstate` before/after):

1. Run `make termstate` — full output visible, all modes OK, scroll region `1;50r`.
2. Run `emojig --tui` — TUI appears inline below the termstate output.
3. Select an emoji and exit — **only the first 3 lines of the termstate output
   survive**; everything from line 4 onward is blank. The shell prompt jumps
   up to line 4. foot's scrollback buffer is **completely empty** — zero history.
4. Run `make termstate` again — all terminal modes are OK (state IS restored;
   only the visual content was destroyed).

The zero-scrollback is the definitive diagnostic: `foot` only adds lines to
scrollback when they scroll off the *top* of the terminal or scroll region.
If content disappeared with no scrollback entry it was **explicitly erased** —
almost certainly via `\x1b[J]` (ED: erase cursor→end of screen) or
`\x1b[2J]` (ED2: erase entire screen) applied too broadly, hitting content
that existed above the TUI's own rows.

**This is the mirror-image of Bug 1**: Bug 1 = TUI rows NOT cleared.
Bug 5 = NON-TUI rows (above the picker) incorrectly cleared. Both have the
same fix: replace any broad ED/ED2 sequence with precise per-row erasure
(`\x1b[2K` on each row the TUI owns, nothing more).

## Root Cause Area

The fade/close sequence does not:

1. Erase the lines the TUI wrote before returning.
2. Clear the selected emoji cell as part of the fade.
3. Restore the cursor to the exact position it occupied at TUI launch.
4. Reset the terminal scroll region to full-screen (`\x1b[r]`) before exit.
5. **Uses a broad ED / ED2 erase sequence** (`\x1b[J]` or `\x1b[2J]`) that
   reaches beyond the TUI's own rows, destroying terminal content above the
   picker and wiping `foot`'s scrollback buffer.

All exit paths must be audited: normal selection, Ctrl-C / SIGINT, SIGTERM,
panic handler, and the fade animation completion.

## Constraints

> ⚠️ **Do NOT over-clear.** Erasing lines above the TUI's own footprint also
> breaks UX (it deletes the user's shell history above the picker). The
> invariant is strict: clear **exactly** the rows that were written, then place
> the cursor at the pre-launch position — no more, no less.

> ⚠️ **Never use `\x1b[J]` (ED) or `\x1b[2J]` (ED2) for cleanup.** These
> sequences erase beyond the TUI's footprint and do not send content to the
> terminal's scrollback buffer, permanently destroying the user's history.
> Use `\x1b[2K]` (EL2: erase entire line) per row instead, moving the cursor
> to each TUI row before erasing it.

The row count to clear depends on layout mode:

| Mode | Rows written |
|---|---|
| Border off (`EMOJIG_BORDER` unset) | 10 rows (rows 1–10 per `AGENTS.md §3`) |
| Border on (`EMOJIG_BORDER=1`) | 12 rows (adds top + bottom border rows) |

## Expected Behaviour

- All TUI rows erased on **every** exit path.
- Selected emoji glyph cleared during (not after) the fade.
- Cursor lands at exactly the pre-launch column/row.
- Scroll region reset to full-screen on every exit path — shell output after
  emojig exits must scroll normally for the rest of the session.
- Terminal content **above** the TUI (pre-existing shell output) is fully
  preserved after TUI exit — no lines erased above the picker's footprint.
- `foot` scrollback buffer is intact after TUI exit — prior shell history
  remains scrollable.
- `echo "$(emojig --tui)"` leaves the terminal clean after the subshell exits.
- Ctrl-E on an empty prompt leaves the prompt completely undisturbed.
- `zig build screenshot` output shows a blank area where the TUI was — no
  leftover rows.

## Files to Audit

- `src/main.zig` — fade animation path, deferred cleanup, `sigHandler`,
  `panic` override; all must call the same erase-and-restore helper.
- Verify every escape sequence emitted at startup has a matching reset in the
  cleanup helper: mouse tracking, raw mode, scroll region (`\x1b[r]`), cursor
  style, cursor visibility.
- **Grep for `\x1b[J` and `\x1b[2J`** in `src/main.zig` — any occurrence used
  for cleanup must be replaced with per-row `\x1b[2K` erasure.
- Row count constants must match the layout defined in `AGENTS.md §3`.

## Acceptance Criteria

- [ ] All TUI rows erased on normal selection exit
- [ ] All TUI rows erased on Ctrl-C / SIGINT / SIGTERM
- [ ] All TUI rows erased on panic
- [ ] Selected emoji glyph cleared as part of the fade (not left floating)
- [ ] Cursor restored to pre-launch position on every exit path
- [x] ~~Scroll region reset to full-screen (`\x1b[r]`) on every exit path~~ —
      **moot**, emojig never sets DECSTBM (see 2026-08-11 audit above)
- [ ] Shell output scrolls normally after emojig exits — needs re-diagnosis;
      the "scroll region leak" explanation is ruled out
- [ ] Terminal content above the TUI is fully preserved after exit
- [ ] `foot` scrollback buffer retains pre-TUI history (run `make termstate`, then emojig, then scroll up — history must be present)
- [ ] No `\x1b[J` or `\x1b[2J` used in the cleanup path — only per-row `\x1b[2K`
- [ ] `echo "$(emojig --tui)"` leaves the terminal clean
- [ ] Ctrl-E on empty prompt leaves the prompt undisturbed
- [ ] Border-on mode clears 12 rows; border-off mode clears 10 rows
- [ ] No regression: lines above the TUI footprint are never touched
- [ ] `zig build screenshot` confirms clean terminal after exit
