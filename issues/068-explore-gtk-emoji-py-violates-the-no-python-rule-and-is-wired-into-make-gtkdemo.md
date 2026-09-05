<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "explore_gtk_emoji.py violates the no-Python rule and is wired into make gtkdemo"
status: open
priority: p3
---

# 068 — `explore_gtk_emoji.py` violates the no-Python rule and is wired into `make gtkdemo`

**Status**: Open
**Priority**: P3 (Low)
**Severity**: Minor
**Category**: Refactor
**Related**: archive/063, AGENTS.md §1

---

## 1. Problem & Motivation

`AGENTS.md` §1 is unambiguous:

> **No Python, No Perl, No Heredocs**: All helpers must be written in Go or
> Zig (or POSIX-compliant Shell for installers). **Do not introduce Python
> scripts or packages.**

The repository root nonetheless contains a tracked, Makefile-wired Python
script:

- `explore_gtk_emoji.py` — a PyGObject/GTK4 window that opens a text field so
  a developer can poke at GTK's *built-in* emoji picker (Ctrl+.), for
  comparison against emojig.
- `Makefile:142-143` — `gtkdemo:` target, recipe `python3 explore_gtk_emoji.py`.
- `git ls-files` confirms it is tracked, not a gitignored scratch file.

Three separate problems, in descending order of importance:

1. **Convention violation.** It is the single Python file in a repo whose
   conventions doc forbids Python by name, and it is not a stray leftover —
   it has a `make` target advertising it, so it reads as sanctioned.
2. **Hidden dependency.** It needs `python3` plus PyGObject (`gi`,
   `gi.require_version("Gtk", "4.0")`) — a runtime dependency stack that
   appears nowhere in the project's documented tooling assumptions, and that
   `make help` gives no warning about.
3. **License inconsistency.** Its header declares
   `SPDX-License-Identifier: MIT`, while the project is
   `AGPL-3.0-or-later` (`LICENSES/`, README). `reuse lint` passes because the
   header is *present and valid*, so `make preflight` will never flag the
   mismatch — but MIT is not one of the licenses this repo otherwise ships.

Issue [archive/063](archive/063-orphaned-scratch-scripts.md) swept
`scripts/` for exactly this class of file and deleted two of them. This one
survived that sweep because it lives at the repo root rather than under
`scripts/`, and because a Makefile reference made it look wired-in rather
than orphaned.

## 2. Technical Specification / Findings

- The script is pure exploration: it constructs a `Gtk.ApplicationWindow`
  with a text entry and nothing else. It has no output artifact, feeds no
  spec, generates no code, and is referenced by nothing except its own
  `make` target (`grep -rl explore_gtk_emoji` over the tree returns
  `Makefile` only — no doc, no issue, no source file).
- Its value is a one-time research question ("what does GTK's own picker do
  that we don't?"), the same category as the two files 063 deleted, and the
  same category as the font-width canaries issue archive/062 relocated to the
  sibling `fontwidth` project.
- The repo already owns a GTK/GUI research surface —
  `scripts/canary_gui/` + `scripts/canary_gui.zig` — so if the comparison is
  still wanted, there is an in-conventions home for it.

## 3. Implementation & Verification Plan

Pick one, cheapest first:

1. **Delete** `explore_gtk_emoji.py` and the `gtkdemo:` target (preferred, and
   the precedent set by 063). The research it enabled is done; GTK's built-in
   picker is not a moving target emojig tracks.
2. **Relocate** it out of this repo — into a scratch/notes area or a sibling
   research project — if the maintainer still wants to re-run it
   occasionally, mirroring what archive/062 did for the font-width canaries.
3. **Reimplement** as `scripts/canary_gtk_emoji.zig` (or fold into the
   existing `scripts/canary_gui`) only if the comparison is genuinely
   recurring. This is the most work for the least new information — do not
   default to it.

Whichever path: also fix the MIT header if the file survives in-tree.

**Verification**: `make preflight` green (`reuse lint` + `zig fmt`);
`grep -rn "explore_gtk_emoji\|gtkdemo" .` returns nothing outside this
ticket; `make help` no longer advertises a Python-dependent target; no
remaining `*.py` in `git ls-files`.
