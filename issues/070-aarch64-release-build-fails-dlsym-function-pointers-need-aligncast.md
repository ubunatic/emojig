<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: done
---

# 070 — aarch64 release build fails: dlsym function pointers need @alignCast

**Status**: Closed — resolved in 0dad63d, released v0.2.1
**Priority**: P1 (High)
**Severity**: Major
**Category**: Bug
**Related**: [Zig.md](../docs/Zig.md)

---

## 1. Problem & Motivation

`harnez release` (goreleaser, Zig cross-build) failed on the
`aarch64-linux-musl` target with:

```
src/gui/wl_dyn.zig:66:35: error: @ptrCast increases pointer alignment
    .wl_display_connect = @ptrCast(std.c.dlsym(h, "wl_display_connect") orelse return error.SymbolNotFound),
```

The native `x86_64-linux-musl` build, and every local `zig build test` /
`make preflight` run all session, were green — this was a P1/Major bug
that was completely invisible until the release build compiled the second
target. **No routine gate in this repo cross-compiles**; the release
pipeline is the only place aarch64 gets built.

## 2. Technical Specification / Findings

`WaylandLib.load()` in `src/gui/wl_dyn.zig` binds ~8 Wayland client
functions via `dlsym`, which returns `?*anyopaque` (alignment 1). The
struct's `WlInterface` pointer fields already went through
`@ptrCast(@alignCast(...))`, but the function-pointer fields used a bare
`@ptrCast`. That happened to compile on `x86_64`, where function pointers
have alignment 1, but not on `aarch64`, where function pointers require
alignment 4 (ARM instructions are 4-byte aligned) — Zig's `@ptrCast` refuses
to silently increase required alignment.

## 3. Implementation & Verification Plan

Added the missing `@alignCast` to all 8 function-pointer fields (commit
`0dad63d`), matching the pattern already used for the interface pointers
two lines below each one.

Verified: `zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall`
(previously failing, now clean), `zig build test` (135/135, native target
unaffected), `zig fmt --check`. Full `harnez release --continue` then
completed both cross targets and published v0.2.1.

Documented in [docs/Zig.md](../docs/Zig.md) §9 ("dlopen'd C Libraries with
Struct Fields") as a new numbered pitfall — the existing entry only covered
struct *field* layout, not function-pointer alignment across targets.

## 4. Process follow-up (not implemented here)

Consider adding a periodic or pre-release `zig build -Dtarget=aarch64-linux-musl`
smoke check (even just a compile, no run) to `make preflight` or a CI job,
so a target-specific compile error surfaces before `harnez release` rather
than during it. Not filed as a separate ticket — small enough to fold into
whichever ticket next touches `Makefile`/CI, or left to a future
`/evergreen` pass to size properly.
