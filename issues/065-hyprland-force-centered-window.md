<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "Way to force a centered GUI window on Hyprland"
status: open
priority: p3
---

# 065 — Way to force a centered GUI window on Hyprland

**Status**: Open
**Priority**: P3 (Low)
**Severity**: Minor
**Category**: Feature
**Related**: 040

---

## Problem

On Hyprland desktops, `emojig` is launched as a floating GUI shell app (e.g.
from a desktop hotkey, non-TTY context — see AGENTS.md §9). Unlike the nested
`sway` recording harness, which installs a compositor rule
(`for_window [app_id="emojig-picker"] ... move position center`), a plain
Hyprland session has no such rule by default, so the picker window opens
wherever Hyprland's default floating placement puts it rather than centered
on screen.

We need a way to force the picker to open centered specifically on Hyprland.

## Evidence

- `issues/040-wayland-focused-window-placement.md` — already scopes the
  broader "focus-adjacent placement" problem and names `hyprctl activewindow
  -j` + a move dispatch as the feasible Hyprland approach, but that issue is
  about tracking the *focused* window, not simply centering. No Hyprland
  adapter exists yet.
- `src/host.zig` sets terminal launch flags (size, borderless) per
  `spec/host.yaml`, but does not query or move the resulting window via any
  compositor IPC.

## Suggested direction

Narrower than issue 40's focus-tracking goal — just get a reliable "centered"
option on Hyprland:

1. Detect Hyprland via `$HYPRLAND_INSTANCE_SIGNATURE` (already the standard
   detection env var for Hyprland tooling).
2. After launching the picker's terminal host with a stable
   `app_id="emojig-picker"` (foot: `--app-id`), use `hyprctl` to center it,
   e.g. `hyprctl dispatch centerwindow` targeted at the new window, or a
   one-shot `hyprctl keyword windowrulev2 "center,1,initialClass:emojig-picker"`
   applied before spawn.
3. Gate this behind an opt-in flag/setting (e.g. `--center` or
   `EMOJIG_CENTER=1`), consistent with issue 40's opt-in placement design, so
   default behavior on other compositors is unaffected.
4. Fail silently and fall back to default placement if `hyprctl` is missing
   or the dispatch fails — never block the picker from opening.

## Risks

- Race between spawning the terminal and the window existing for `hyprctl` to
  target — may need a short poll/retry on `hyprctl clients -j` for the new
  `app_id` before dispatching.
- Behavior may vary by Hyprland version / user's own `windowrulev2` config
  already targeting `emojig-picker`.

## Acceptance criteria

- `--gui` default behavior on non-Hyprland compositors is unchanged.
- On Hyprland, the opt-in centering flag reliably centers the picker window.
- Missing `hyprctl` or a failed dispatch never prevents the picker from
  opening.

## Related

- [Issue 40](40-wayland-focused-window-placement.md) — broader Wayland
  focus-adjacent placement design; this issue can share its opt-in
  `--placement`-style flag scheme, or ship as a simpler standalone `--center`
  first.
