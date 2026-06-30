<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "Wayland focused-window placement for GUI picker"
status: open
priority: p2
---

# 40 - Wayland focused-window placement for GUI picker

**Status:** Open  
**Priority:** P2

## Problem

`emojig --gui` currently lets the terminal host and compositor choose the popup
position. This is reliable, but the picker may appear far from the application
where the user is typing.

The ideal UX would be to open the picker near the user's current text caret.
On Wayland, that exact caret position is not generally available to unrelated
clients, and ordinary top-level windows cannot rely on setting arbitrary global
screen coordinates.

## Scope

Assume modern Wayland first. X11 support can remain a lower-priority fallback
or be skipped for the initial implementation.

The practical target is **focused-window-adjacent placement**, not exact
caret-relative placement.

## Current evidence

- `src/host.zig` launches terminal windows and sets terminal-specific flags, but
  does not pass any screen coordinates.
- `foot` exposes initial size flags, including `--window-size-chars` and
  `--window-size-pixels`, but no generic initial position flag.
- `kitty --position` exists, but its own help states it never works on Wayland.
- The demo recorder can place the picker only because it owns a nested `sway`
  compositor and installs a rule:
  `for_window [app_id="emojig-picker"] ... move position center`.

## Feasible Wayland approaches

### wlroots / sway

Use `swaymsg -t get_tree` to find the focused container, launch the picker with
`app_id="emojig-picker"`, then move it near the focused window using `swaymsg`.

This should be robust for sway users and testable in the existing nested-sway
recording harness.

### Hyprland

Use `hyprctl activewindow -j` for the focused window geometry, then dispatch a
move for the emojig picker window.

This is feasible but needs a separate adapter and test strategy.

### GNOME / KDE

No stable generic command-line control path is expected. Shell/KWin extensions,
user window rules, or portal-level future work may help, but should not block a
wlroots-first implementation.

## Suggested design

Add an opt-in placement setting, for example:

```sh
emojig --gui --placement=focus
```

Resolution order:

1. Detect supported compositor control API from environment.
2. Query focused window geometry.
3. Launch picker normally with the existing host abstraction.
4. Move the `emojig-picker` window near the focused window.
5. Fall back silently to current compositor placement when any step fails.

The default should remain current behavior until the compositor adapters have
enough real-world mileage.

## Risks

- Race between launching the terminal and moving its new surface.
- App ID/class differences across terminal hosts.
- Multi-monitor coordinate spaces differ by compositor.
- Focus-stealing prevention may interact with post-launch move/focus commands.
- Exact text caret placement is not a reliable product promise on Wayland.

## Acceptance criteria

- `--gui` remains unchanged by default.
- Opt-in placement works under sway in the nested recording environment.
- Failure to query or move never prevents the picker from opening.
- Docs describe the feature as focused-window placement, not caret placement.
