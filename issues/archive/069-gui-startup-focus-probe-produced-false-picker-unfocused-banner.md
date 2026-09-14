<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: done
---

# 069 — GUI startup focus probe produced false 'Picker unfocused' banner

**Status**: Closed — resolved in b2da470, released v0.2.1
**Priority**: P2 (Medium)
**Severity**: Moderate
**Category**: Bug
**Related**: [EnvironmentDetection.md](../docs/EnvironmentDetection.md), 040

---

## 1. Problem & Motivation

Reported live on Fedora 44/GNOME: the user's desktop shortcut visibly gave
the `emojig --gui` window keyboard focus instantly (confirmed: typing
worked immediately, and Alt+Tab "fixed" the display), but emojig still
rendered the "🕵️ Picker unfocused. Click or switch window to focus!"
banner on launch.

## 2. Technical Specification / Findings

`src/main.zig`'s `--tui` child (when `gui_spawned`) enabled focus reporting
(`\x1b[?1004h`) and then read stdin for up to 200ms, trying to infer the
*startup* focus state from whatever `\x1b[I`/`\x1b[O` bytes showed up. Three
independent failure modes were found, all producing the same symptom:

1. Terminals emit `CSI I`/`CSI O` only on a focus *transition* — a window
   already focused when `FOCUS_ON` is enabled can legitimately send nothing.
2. A stray `CSI O` can arrive for the split-second before the compositor
   hands over input focus, with no `CSI I` following inside the read window.
3. Even a genuine `CSI I` grant can simply land after whatever timeout is
   chosen — measured directly on this machine (foot 1.27.0, real Wayland
   session) the first `O`/`I` pair took over 100ms to arrive in one trace.

A first attempted fix only changed the `n == 0` (timeout/silence) branch to
default to focused instead of unfocused. This did not fix the user's report
— the real trace hitting their machine was case 2 above (a `CSI O` with no
timely follow-up), which the first fix left untouched.

## 3. Implementation & Verification Plan

Removed the startup probe entirely (commit `b2da470`): a `--gui` launch now
just keeps `has_focus`'s declared-default of `true`. `FOCUS_ON` is still
enabled so the *live* focus-report handling already in the run loop
(`src/main.zig` around line 2917) keeps working — that live path has no
startup race, since by then the read loop is already polling continuously
rather than racing a single 200ms window.

Verified: `zig build test` (135/135), `make preflight`, `make install`,
and — most importantly — direct user confirmation after reinstalling that
the shortcut no longer shows the false banner. Released in v0.2.1.

Documented in [docs/EnvironmentDetection.md](../docs/EnvironmentDetection.md)
under "No startup focus probe — trust `--gui` starts focused."
