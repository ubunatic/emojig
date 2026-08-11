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

**Updated 2026-08-11** — still open, but the evidence moved. Host handling was
migrated from hardcoded Zig branches to spec-driven argv templates (issue 46 /
`AGENTS.md §9`), so the original `src/host.zig` line references below are
**stale and no longer exist**:

- ~~`src/host.zig:99` — `if (std.mem.eql(u8, name, "xfce4-terminal")) return .xfce4_terminal;`~~
- ~~`src/host.zig:286` — `.xfce4_terminal => {`~~
- ~~`src/host.zig:70-80` — auto-detection list omits `"xfce4-terminal"`~~

Current evidence (same gap, new location):

- `spec/host.yaml` — the `terminals:` list **does** carry a full
  `xfce4-terminal` entry (`name: xfce4-terminal` with
  `tail_separator: "-x"`), so the launch path is fully specified.
- `spec/host.yaml` `detection:` (the auto-detect candidate list) contains
  exactly `foot, ptyxis, kitty, alacritty, wezterm, ghostty, konsole,
  gnome-terminal, xterm` — **`xfce4-terminal` is absent.**
- `src/host.zig:107` — `for (getGlobalHostSpec().detection) |name|` is the
  only auto-detection loop, so a terminal with a template but no detection
  entry can never be auto-picked.
- `src/host.zig:903` — the existing spec test ("detection list and all
  referenced terminals exist") only asserts the *converse* direction (every
  detection entry has a template), so it structurally cannot catch a
  template that is missing from detection. Whatever fixes this issue should
  consider asserting both directions, or explicitly listing the
  intentionally-not-auto-detected terminals (`generic`, and today `tilix`
  — see issue [57](57-tilix-monochrome-mixed-row-length.md), which notes
  tilix is absent from `detection` by design).
- `issues/02-distribution-and-release.md` — backlog text still names
  `xfce4-terminal` among supported hosts.

The gap itself was re-confirmed by hand on 2026-08-11 by reading
`spec/host.yaml` directly, per `AGENTS.md`'s guidance to read the spec
rather than probe.

## Reproduction

```sh
go run ./scripts/review_audit xfce-host-detect
```

⚠️ **This check currently reports a false PASS — it is NOT evidence the bug is
fixed.** `scripts/review_audit/main.go` still greps `src/host.zig` for the two
literal Zig strings struck out above; both are gone, so `hasKind` and
`hasArgvCase` are `false`, the `hit` conjunction collapses, and the check
prints `PASS` while the underlying gap is untouched. Tracked separately as
issue [60](60-review-audit-xfce-check-false-pass.md) — that check must be
ported to read `spec/host.yaml` before it can speak to this issue at all.

Historic result (when the check still matched the code): **fails**, because
the host kind + argv path exist, but the
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
