<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 63 — two orphaned scratch scripts in `scripts/`: `test_posix.zig` and `gen_wayland_spec.go`

**Priority: P3** (housekeeping, no user-facing behavior; but both files are
zero-reference dead code that misleads anyone auditing `scripts/`, and one of
them has a name that falsely implies it feeds the `spec/.gen/` pipeline)

**Status: Closed (Deleted) — 2026-08-11.** Both files removed per the
recommendation below. Found during the `scripts/` audit that followed issue
62's font-width migration. Unlike issue 62 these were *not* research tools
worth relocating: one was superseded by shipped code, the other never
worked.

## Summary

Neither file is referenced by any Makefile target, `build.zig` step, doc,
issue, or other source file (grep over the whole tree excluding `.git`
returns zero hits for `test_posix`, `gen_wayland`, `wayland_spec`). Both
were committed as by-products of a working session rather than as tools
anyone was meant to run again.

## `scripts/test_posix.zig` — DELETE (superseded by shipped code)

- **Introduced:** `65213a9` (2026-05-29) *"Add POSIX and interactive TUI PTY
  testing scripts to scripts/ directory"* — the same commit that added
  `scripts/test_tui.go`. `test_tui` went on to become a real, Makefile-wired
  harness (`go run ./scripts/test_tui`, AGENTS.md §7); `test_posix.zig` never
  got a target and was never referenced again.
- **Never wired in:** no Makefile/`build.zig` reference at any point in
  history.
- **Superseded:** its entire body is the two-line `clock_gettime` shape

  ```zig
  var ts = std.mem.zeroes(std.posix.system.timespec);
  _ = std.posix.system.clock_gettime(.REALTIME, &ts);
  ```

  which now appears verbatim in `src/term.zig:153-154` and again at
  `src/term.zig:201-202`, `src/main.zig:189/195`, and
  `src/ranking_test.zig:412-413`. Textbook scratch file used to work out a
  Zig 0.16 API shape, then hand-copied into real code.
- **Cannot regress-guard anything:** it exposes `pub fn main`, not a `test`
  block, so `zig build test` can never reach it. If the API shape ever needs
  pinning, the right home is a `test` block in `src/term.zig` (or a
  `docs/Zig.md` snippet, where this API family is already documented), not a
  standalone executable.

## `scripts/gen_wayland_spec.go` — DELETE (never functional, misleading name)

- **Introduced:** `bfe5546` (2026-08-04) *"feat(gui): implement protocol
  marshal bindings for native Wayland windowing"* — a 2-file commit whose
  other half added marshal bindings to `src/gui/wl_dyn.zig`. So it was an
  exploration aid written *alongside* the hand-written bindings, not a
  generator they came from.
- **It generates nothing.** It declares `Protocol`/`Interface`/`Message`
  structs, unmarshals the XML, then discards every parsed field — `main()`'s
  only output is a comment line, `// Generated from <path> (<name>)`. No
  request/event/signature emission exists.
- **Never fed the live bindings:** no `Generated from` marker appears
  anywhere in `src/` or `spec/.gen/`. `src/gui/wl_dyn.zig` is hand-written
  (`//! Wayland C API and symbol bindings for native window creation.`).
- **Fragile input paths:** hardcodes `/usr/share/qt6/wayland/protocols/...`,
  i.e. Qt6's vendored copies rather than the canonical
  `wayland`/`wayland-protocols` locations — it would silently no-op (`continue`
  on read error) on a machine without Qt6.
- **Name is actively misleading:** `gen_*` + "spec" reads like part of the
  `make gen-spec` → `spec/.gen/` pipeline (AGENTS.md Quickstart). It is not:
  `spec/.gen/` is compiled from hand-edited YAML, and no Wayland
  protocol-derived data exists in `spec/host.yaml` or `spec/.gen/`. Anyone
  tracing the spec pipeline will waste time on this file.
- **Not worth MOVE-ing** (contrast issue 62): 45 lines, over half of them
  struct tags, producing no output. There is no research result here to
  preserve — it would be rewritten from scratch anyway.

## Caveat / relation to issue 49

Issue 49 (native GUI engine, **open**, high priority) is live work and
`src/gui/` — including `wl_dyn.zig` — is real, `build.zig`-wired code
(`-Dgui`, dispatched via `src/gui.zig`). Deleting `gen_wayland_spec.go` does
**not** touch that. If issue 49 later wants genuine XML-driven binding
generation, it needs a real generator (signature strings, opcode ordering,
interface type tables) written fresh against canonical protocol paths; this
stub is not a starting point worth keeping warm.

## Recommendation

1. `git rm scripts/test_posix.zig scripts/gen_wayland_spec.go`.
2. Optionally note in `docs/Zig.md` that the `clock_gettime`/`timespec`
   shape now lives in `src/term.zig` (it is already covered there in spirit).
3. Re-run `make preflight` (REUSE lint) and `zig build test`; neither file is
   referenced, so both should be no-ops beyond the deletion.
