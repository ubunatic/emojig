<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Terminal Restore: Safe Inline-TUI Teardown Across Terminals

Reference for anyone touching the TUI startup/teardown escape sequences in
`src/main.zig` / `src/term.zig` (Zig picker) or `internal/term/term.go`
(Go `mojigo`). It documents the teardown contract, the cross-terminal pitfalls
we actually hit, and how to test a change — so the next "closes with extra
lines" bug doesn't take another archaeology session.

History: [`issues/12-tui-line-cleanup-and-terminal-restoration.md`](../issues/12-tui-line-cleanup-and-terminal-restoration.md)
(per-row cleanup + the VTE `?1049l` root cause),
[`SkimInlineTui.md`](./SkimInlineTui.md) (inline region mechanics),
[`MojigoInlineHeight.md`](./MojigoInlineHeight.md) (the Go port — the
known-good reference implementation).

---

## 1. The teardown contract

An inline (non-alt-screen) TUI owns exactly the rows it drew, nothing else.
On **every** exit path (normal selection, Esc, Ctrl-C/SIGINT, SIGTERM, panic)
it must, in this order:

1. Disable mouse tracking (`\x1b[?1003l\x1b[?1006l`) and **drain in-flight
   input** before restoring cooked mode. The Zig picker does this with a CPR
   handshake: write `\x1b[6n`, read until the terminating `R` — the terminal
   answers queries in FIFO order, so receiving the report guarantees the
   mouse-off was processed and no stray SGR release/motion bytes leak into the
   shell prompt.
2. Restore termios (cooked mode).
3. Erase the TUI's own rows — **per row** with `\x1b[2K`, never with `\x1b[J`
   or `\x1b[2J` (ED erases beyond the footprint and destroys scrollback).
4. Park the cursor at the TUI's top row (absolute `\x1b[row;1H` from the
   start row recorded at launch). The shell prompt then overwrites the
   region; no orphaned lines.
5. Emit the mode-appropriate restore sequence — **and nothing more that can
   move the cursor** (see §2).

Steps 3–5 must be the *last* cursor-affecting output. Anything that moves the
cursor after parking re-introduces the "blank lines before the next prompt"
class of bug.

## 2. Pitfall: `\x1b[?1049l` outside the alt screen (VTE)

`?1049h/l` is "switch to/from alt screen **and save/restore the cursor**".
Terminals disagree about the *reset* when the alt screen was never entered:

| Terminal family | `?1049l` while on the normal screen |
|---|---|
| foot, tmux | ignored — no visible effect |
| VTE (Tilix, GNOME Terminal, Ptyxis, xfce4-terminal) | still executes the **cursor-restore half**, jumping to a stale saved position |

So a shared restore sequence that always ends with `?1049l` works perfectly in
foot/tmux and silently breaks in every VTE terminal: cleanup parks the cursor,
`?1049l` yanks it elsewhere, and the selection/prompt print rows too low.

**Rule:** only emit `?1049l` if *you* emitted `?1049h`. In Zig this is
`RESTORE` (inline, no `?1049`) vs `RESTORE_ALT` (alt-screen) selected by the
`global_alt_screen` flag — including in the panic handler. In Go, the inline
`Restore` path never touches `?1049` at all.

**Corollary for debugging:** foot and tmux are *forgiving* terminals. A
teardown that looks clean there can still be broken on VTE. Test the VTE
family explicitly (§5).

## 3. Pitfall: ANSI mode vs DEC private mode (`7` vs `?7`)

Auto-wrap (DECAWM) is a DEC *private* mode: disable with `\x1b[?7l`, restore
with `\x1b[?7h`. The picker shipped for a while with `\x1b[7l` / `\x1b[7h` —
ANSI mode 7, which no modern terminal implements — so wrap-disable was a
silent no-op everywhere.

Two lessons:

* **The `?` is load-bearing.** Every mode this project uses (`?25` cursor,
  `?1003`/`?1006` mouse, `?1049` alt screen, `?7` wrap, `?12` blink) is a DEC
  private mode. A missing `?` doesn't error; the terminal just ignores it (or
  worse, hits an unrelated ANSI mode).
* **foot's stderr is a free linter.** foot logs unknown sequences, e.g.
  `csi.c: SM with unimplemented mode: 7` — that warning is what exposed this
  bug. When hand-writing escape codes, run once in foot and read stderr.

Wrap matters for teardown because an over-wide row (emoji width quirks) on the
terminal's bottom row wraps and **scrolls the screen**, invalidating the
absolute start row recorded at launch — the cleanup then clears and parks at
stale coordinates.

## 4. Pitfall: anything position-dependent after a scroll

The start row captured at launch (DSR/CPR query) is only valid while the
screen does not scroll. Things that scroll it: a trailing `\n` on the bottom
row, a wrapped over-wide row (§3), terminal resize. Rules the renderers
follow:

* Never emit `\n` inside the region — move with `\x1b[B\r` (CUD clamps at the
  bottom row instead of scrolling).
* Re-query the cursor row on resize and update the recorded start row.
* Pad/clamp every row to the region width; emoji count as width 2.

## 5. How to test a teardown change

`zig build test` + `go run ./scripts/test_tui` catch protocol regressions
(clean exit, no leaked brackets), but a PTY harness is **not** a terminal —
it cannot catch positional drift. Verify visually in *at least*:

1. **A VTE terminal** (Tilix/GNOME Terminal/Ptyxis) — strictest about
   `?1049l`; this is where the extra-lines bug lived.
2. **foot** — strict sequence parser, logs unknown sequences to stderr.
3. **tmux** — most forgiving; if even tmux misbehaves the bug is basic.

For each, run `emojig --tui | cat` with the prompt both near the top and on
the bottom row (forces the scroll-up reservation), and exit via Enter
(selection + fade), Esc, Ctrl-C, and a mouse click. After exit the next
prompt must sit directly under the launching command — zero blank lines, no
leftover TUI rows, scrollback intact.

## 6. Pitfall: SGR mouse events split across reads → typed into search query

**Symptom.** After fast scrollbar drag or rapid wheel scroll, characters like
`7M`, `2;32;12M`, or `[<32;32;11M` appear in the search bar of the next
session. They are the *tail bytes of SGR mouse events* whose leading bytes
were consumed in a prior read.

**Root cause.** `?1003h` (any-motion tracking) generates one `\x1b[<Cb;Cx;CyM`
event per mouse-position sample — at 125 Hz that is thousands of events per
scrollbar drag. With a 64-byte read buffer, each `readStdin` call holds roughly
five 12-byte events. The original parser processed **only the first event** per
read and then returned to `poll()`. The remaining bytes came back in the next
`readStdin` call. When the read-buffer boundary fell *inside* an event (e.g.
the buffer ended after `\x1b[<32;32;` with no `M` yet), the continuation bytes
(`7M`, `12M`, ...) arrived in the next read starting with a digit — no leading
`\x1b` — so the printable-text branch typed them into the query.

**Why panic made it worse.** Zig `defer` blocks do not run on `panic()`. When
the app panicked (e.g. the now-fixed `name[0..max_len-3]` out-of-bounds in the
description row), the CPR drain block was skipped entirely. Mouse events that
foot had already queued in the PTY buffer were then read by the next process
(the shell), appearing verbatim in the prompt.

**Fix — three layers in `src/main.zig`:**

1. **Larger read buffer** — `read_buf` grew from 64 → 512 bytes. With 12-byte
   events that is ~40 events per read, cutting split probability 8×.

2. **Multi-event loop (`sgr_loop`)** — the `bytes[2] == '<'` branch now loops
   with an `sgr_off` cursor: after processing one complete event it advances
   past the terminator, checks whether the next three bytes are `\x1b[<`, and
   if so continues into the next event. All complete events in the buffer are
   consumed in a single read iteration before returning to `poll()`.

3. **Carry buffer for incomplete tails** — when the loop finds no `M`/`m`
   terminator in the remaining bytes (`term_char == 0`), it saves the partial
   `\x1b[<...` bytes into `mouse_carry[0..mouse_carry_len]`. At the start of
   the next `readStdin`, carry bytes are prepended to the front of `read_buf`
   so the continuation arrives as a contiguous, parseable sequence.

4. **Panic drain** — the `pub fn panic` handler was extended to drain the TTY
   input non-blockingly after writing `RESTORE`. This flushes any SGR events
   that foot queued before processing `MOUSE_OFF`, matching what the `defer`
   block already did for normal exits.

**Detection pattern.** If control-code leak symptoms reappear, search the log
for search queries that match `^\d.*[Mm]$` or contain `;` — those are raw SGR
parameter tails. The escape byte (`\x1b`) is non-printable so it is silently
dropped, leaving only the parameter+terminator suffix visible as text.

**Testing.** Drag the scrollbar hard and fast for 5–10 seconds, release, then
scroll the mouse wheel rapidly. Close the picker and verify the shell prompt is
clean. In `--tui` mode, run `emojig --tui | cat` and repeat — `cat` will print
any bytes that leak after the TUI exits, making them visible.
