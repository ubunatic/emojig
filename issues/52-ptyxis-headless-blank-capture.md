<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 52 — ptyxis renders blank in headless wayreel capture

**Priority: P3** (dev-tooling gap; ptyxis is not the primary GUI terminal, foot is)

## Summary

`scripts/vte_canary/canary-ptyxis.reel` produces a screenshot containing only
the sway compositor background — no ptyxis window content at all — when run
headless via `wayreel record` (nested sway + Xvfb, `DISPLAY=:99`,
`DBUS_SESSION_BUS_ADDRESS=` cleared per `docs/HeadlessRecording.md §7`).

Confirmed not a startup-delay race: tested `terminal_startup_delay` at 2s,
5s, and 8s — all three produce the identical blank frame.

By contrast, `tilix` (also GTK, also covered by the same `env` isolation
line) renders correctly and immediately in the same headless setup.

## Discovered via

Issue 51's wayreel `crop_colors` hardening work: `crop_colors` errors loudly
when zero matching pixels are found, which is what first surfaced this — the
pre-existing `canary-ptyxis.reel` had no automated verification, so a blank
capture was silently accepted as "success" before.

## Suspected cause (unconfirmed)

`docs/HeadlessRecording.md §7`'s GTK/VTE isolation fix (`DISPLAY=:99` +
clearing `DBUS_SESSION_BUS_ADDRESS`) is documented and tested against GTK3
apps (tilix, gnome-terminal). ptyxis is a GTK4/libadwaita app and may need a
different or additional isolation mechanism (e.g. a portal backend, a
different `XDG_*` variable, or a Wayland-native path that doesn't fall back
to X11 the same way GTK3 does).

## Next steps

- Reproduce with `wayreel open ptyxis` (interactive canvas) to see if it's
  headless-only or general.
- Check ptyxis process actually launches (`ps`) vs. launches-but-doesn't-draw.
- Compare against a known-working headless GTK4 app, if one exists in the
  wayreel test suite, to isolate GTK3-vs-GTK4 vs. ptyxis-specific.
- Once fixed, re-add `canary-ptyxis.reel` record + `-verify` calls to
  `Makefile`'s `canary-shots` target (currently only foot + tilix).
