<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Issue 17 — Screenshot harness: typed keys + Go `Fd()` blocking gotcha

**Status:** Closed

## Description

The agent screenshot harness (`scripts/screenshot`) could only capture the
initial frame, so UI states reachable only via input (e.g. the new `??` help
page) could not be verified in the agentic loop.

## Change

`go run ./scripts/screenshot [binary-path [keys]]` now accepts an optional
second argument that is typed into the picker before the frame is captured,
e.g. `go run ./scripts/screenshot ./zig-out/bin/emojig '??'`.

## Learning: `os.File.Fd()` resets the fd to blocking mode

The first implementation of the post-keys drain loop hung forever. Two
distinct traps were involved:

1. `os.File.Read` on an fd that was made non-blocking via
   `syscall.SetNonblock` does **not** return `EAGAIN` — the Go runtime
   poller parks the goroutine until more data arrives. A "read until
   drained" loop therefore blocks once the buffered frames are consumed.
   Use raw `syscall.Read` for non-blocking drains.
2. **Every call to `os.File.Fd()` switches the fd back to blocking mode.**
   `syscall.Read(int(master.Fd()), …)` inside the loop silently undid the
   earlier `SetNonblock(…, true)` and blocked in the kernel. Capture the fd
   once (`fd := int(master.Fd())`) and reuse it.

Diagnosis trick: run the harness under `timeout -s QUIT 15 …` — Go dumps all
goroutine stacks on SIGQUIT, which pinpointed the blocked `syscall.Read`.

## Related

- `?` shows help page 1 (`help_lines`), `??` shows page 2
  (`help_lines_more`, documenting the `e:`/`t:` width filters);
  `help_lines_wide` and the width-based (≥35 cols) help selection were
  removed from both the Zig app and mojigo.
