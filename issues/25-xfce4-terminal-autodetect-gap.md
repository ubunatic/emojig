<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "GUI auto-mode misses xfce4-terminal despite built-in host support"
status: open
priority: p2
---

# 25 — GUI auto-mode misses `xfce4-terminal` despite built-in host support

**Status:** Open  
**Priority:** P2

## Problem

The GUI launcher already knows how to treat `xfce4-terminal` as a supported host,
but the auto-detection list never tries it.

That creates a UX gap:

- `hostKindFromName()` recognizes `xfce4-terminal`
- `buildGuiArgv()` has an `.xfce4_terminal` branch
- but `selectTerminalHost()` cannot auto-pick it

On systems where `xfce4-terminal` is the only supported terminal available,
`emojig`'s non-TTY GUI fallback can fail even though the codebase already has
the host-specific launch path.

## Evidence

- `src/host.zig:99` — `if (std.mem.eql(u8, name, "xfce4-terminal")) return .xfce4_terminal;`
- `src/host.zig:286` — `.xfce4_terminal => {`
- `src/host.zig:70-80` — auto-detection list omits `"xfce4-terminal"`
- `issues/02-distribution-and-release.md:52` — backlog text explicitly names `xfce4-terminal` among supported hosts

## Reproduction

```sh
go run ./scripts/review_audit xfce-host-detect
```

Current result: **fails**, because the host kind + argv path exist, but the
candidate list still omits `xfce4-terminal`.

## Why this matters

This is a narrow but real **auto-mode reliability** bug:

- hotkey / launcher users depend on `emojig` finding a GUI host automatically
- the workaround (`EMOJIG_TERMINAL=xfce4-terminal`) exists, but users should not
  need a manual override for a host the code already treats as supported

## Suggested fix

Add `"xfce4-terminal"` to the `selectTerminalHost()` detection candidates and
keep the docs in sync with the actual list.

## Chosen direction

**Decision (2026-06-21):** Add `xfce4-terminal` to the GUI auto-detection list.
