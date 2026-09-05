<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "No automated regression proof for terminal restore on the three exit paths"
status: open
priority: p1
---

# 067 — No automated regression proof for terminal restore on the three exit paths

**Status**: Open
**Priority**: P1 (High)
**Severity**: Major
**Category**: Bug
**Related**: 012, archive/013, 044, 045, AGENTS.md §2, AGENTS.md §7

---

## 1. Problem & Motivation

`AGENTS.md` treats terminal-state restoration as the project's hardest safety
invariant — §2 ("Safe Terminal State Restoration") plus three separate
Quickstart imperatives ("Make sure --tui scrollback logic is always super
safe!", "--gui/--tui mouse hover logic is always safe!", "--tui close
behaviour is safe!"). The invariant spans **three independent exit paths**:
the normal `defer` block, the signal path (SIGINT/SIGTERM via the self-pipe),
and the `panic` override.

**Nothing in the test suite asserts that invariant.** Today:

- `src/term.zig` carries exactly **two** tests, both of which assert the byte
  spelling of individual ANSI constants — not that the constants are actually
  emitted at exit.
- `src/main.zig`, `src/tui.zig`, `src/mru.zig`, `src/pid_lock.zig`,
  `src/clipboard.zig` and `src/integration.zig` carry **zero** tests.
- The PTY harness (`scripts/test_tui`) drives the app through search, focus,
  quit, category and multi-select flows and asserts on rendered frames, but
  it never sends a signal, never provokes a panic, and never asserts on the
  restore byte stream.
- `scripts/termstate.sh` (issue archive/013) *can* detect a leaked mode, but
  it is a **human-run diagnostic**, not a gate. Nothing runs it in `make
  test` / `make preflight`.

Issue [012](012-tui-line-cleanup-and-terminal-restoration.md) tracks the
*behaviour* and carries the right acceptance criteria, but its own 2026-08-11
audit note concedes it stays open because "most remaining acceptance criteria
are inherently visual" — every checkbox there is a manual terminal check. So
the invariant is documented in three places, audited by source reading, and
verified by hand. It is not defended by anything that runs.

This matters right now because two planned refactors touch exactly this code
with zero coverage under them:

- Issue [044](044-main-zig-decomposition.md) explicitly proposes *"moving the
  terminal-restore trio to `src/term.zig`"* as one of its eight extractions.
- Issue [045](archive/045-ansi-escape-consolidation.md) already consolidated
  145 hand-rolled escape sequences.

A restore sequence silently dropped during either refactor is a terminal the
user has to `reset`, and no gate would notice.

## 2. Technical Specification / Findings

The restore contract is fully observable from outside the process — it is a
byte stream on the PTY plus a termios state — so it is mechanically testable
with the harness that already exists. The observable obligations, per
`AGENTS.md` §2/§3/§9:

| Obligation | Observable |
|---|---|
| Mouse tracking off | `\x1b[?1003l\x1b[?1006l` present after exit |
| Cursor shown | cursor-show sequence present |
| Cursor style reset | `\x1b[0q` present |
| Termios restored | `tcgetattr` on the master side shows cooked mode |
| Rows erased, scrollback intact | per-row `\x1b[2K`, and **no** `\x1b[J` / `\x1b[2J` in the cleanup tail |
| Alt-screen left (altscreen mode) | matched `?1049l` |
| GUI pidfile removed | `/tmp/emojig-picker-<uid>.pid` gone |

Each of these must hold on **all three** paths. The signal path is the one
with the least prior coverage and the most subtlety (`sigHandler` is
documented in-source as a V1 legacy handler that deliberately does *not*
clear rows; the real work happens in the `defer` block reached via the
self-pipe — a wiring detail that a refactor could break without any visible
symptom in the normal path).

`scripts/test_tui/vt.go` already parses terminal output, and `main.go`
already owns a PTY master, so both the byte assertions and `tcgetattr` are
reachable with no new dependency.

## 3. Implementation & Verification Plan

Sketch — deliberately scoped as a **test-only** ticket; behavioural fixes it
uncovers belong in issue 012.

1. **Extract the restore emitters into named, callable functions** in
   `src/term.zig` (`restoreSeq()` already exists) so a Zig unit test can
   assert the exact composed byte string for both `RESTORE` and
   `RESTORE_ALT`, including the pidfile-removal and mouse-disable members.
   This overlaps deliberately with issue 044's proposed extraction — do it
   here first so 044 lands on top of a gate rather than under one.
2. **Add a PTY exit-path suite to `scripts/test_tui`**, one case per path:
   - *normal*: drive a pick, let the process exit, assert the tail of the
     master-side stream against the table above.
   - *signal*: send `SIGINT`, then `SIGTERM`, to the child; assert the same
     tail, plus a clean zero/expected exit status and no hang.
   - *panic*: provoke the panic override via a dedicated hidden
     `--panic-test` build flag or an injected fault; assert restore bytes
     precede the panic message.
3. **Assert the negative too**: grep the cleanup tail for `\x1b[J` /
   `\x1b[2J` and fail if present (012's standing invariant, currently
   unenforced). Note the two known in-flight `CLEAR_BELOW` sites in the
   *redraw* path must not trip this — scope the assertion to bytes emitted
   after the last frame.
4. **Assert termios** with `tcgetattr` on the master after child exit
   (cooked mode, `ECHO` restored).
5. **Wire it into `make test`** so it is a gate, not a tool. Optionally have
   the case shell out to `scripts/termstate.sh` for the mode-leak view.
6. **Verify**: `make test` green; then deliberately delete one restore
   sequence and confirm the suite goes red (a test that cannot fail is not a
   gate — see `docs/AgenticLoop.md` Phase 3, "Test Assertion Rigor").

Once green, 012's mechanical acceptance criteria can be checked off by the
suite rather than by hand, leaving 012 to carry only the genuinely visual
ones (scrollback history, prompt undisturbed).
