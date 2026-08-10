<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 58 — Zig 0.16 stdlib bug: `unsetenv()` desyncs `std.Io.Threaded`'s own `environ` cache

**Priority: P3** (found while building a manual research canary, not on
any emojig code path used at runtime — `-unset=` in `scripts/canary_font.zig`
is a developer-only diagnostic flag; no shipped emojig behavior is affected.
Tracked here mainly so the fix/workaround isn't re-derived later, and as a
candidate to report upstream to ziglang/zig.)

**Status: workaround shipped for one of the two symptoms** (see
`scripts/canary_font.zig`'s `-unset=` flag and `docs/Zig.md` §8). Filing
this as an issue rather than closing outright because (a) the second
symptom (`std.process.spawn` after `unsetenv()`) has **no known
workaround**, only avoidance, and (b) this looks like a genuine upstream
Zig 0.16 stdlib defect worth reporting to
[ziglang/zig](https://github.com/ziglang/zig), not something to silently
route around forever.

## Summary

Zig 0.16's `std.Io.Threaded` (the default `Io` implementation) keeps its
own cached view of the process's `environ`, built lazily on first use.
Calling libc's `unsetenv()` directly — a completely standard, POSIX-legal
operation — desyncs that cache from libc's own copy, because glibc's
`unsetenv()` can reallocate/free its backing array. Two different pieces
of Zig's stdlib break as a result, in two different ways:

1. **`std.debug.print`'s first call in a process** lazily scans `environ`
   to locate self debug-info search paths (for pretty stack traces). If a
   var like `LANG` was removed via `unsetenv()` before this first call,
   the scan **panics** (`attempt to use null value`) — and then the panic
   handler's own attempt to print that panic message recurses into the
   same lazy-init code path and **deadlocks** re-locking a mutex it's
   already holding. The process never exits; it must be killed externally.
2. **`std.process.spawn`**, when building a spawned child's env block,
   reads through `Io.Threaded`'s cached `environ` view. If `unsetenv()`
   was called anywhere earlier in the process's lifetime, that call
   **segfaults** inside `std.process.Environ.createPosixBlock`, reading a
   dangling pointer into memory glibc already freed when it reallocated
   its own `environ` array.

## Proof this is a Zig stdlib bug, not user misuse

- `unsetenv()` is standard POSIX libc API, called here via a plain
  `extern "c" fn unsetenv(name: [*:0]const u8) c_int;` declaration —
  the exact same low-level FFI pattern already used and documented
  elsewhere in this codebase (`docs/Zig.md` §§1-3) for pipes, spawn
  redirection, and raw reads. There is no unsafe cast, no wrong calling
  convention, no undefined behavior on our side: the declaration matches
  libc's real signature (`int unsetenv(const char *name)`) exactly, and
  the call is made with a valid, `alloc.dupeZ`-produced null-terminated
  string.
- The minimal reproduction below (`scripts/zig_unsetenv_bug_repro.zig`)
  contains **zero application logic** — no Cairo, no Pango, no dlopen, no
  Wayland, nothing from this project's own domain. It is exactly:
  `std.debug.print`, `std.process.spawn`, and one `extern "c"` call to
  `unsetenv`. The bug reproduces with that alone.
- Both failure modes are gated on the unset variable actually being
  *present* beforehand — unsetting an already-absent variable is a
  documented no-op for libc and reproduces neither bug (verified: see
  "Experiments" below). This behavior is exactly what you'd expect from a
  stale-cache-after-a-real-mutation bug, not a coincidence or a
  misconfigured test.
- Both crash locations are inside Zig's own stdlib source
  (`/usr/lib/zig/std/process/Environ.zig:712`, `/usr/lib/zig/std/debug.zig`,
  `/usr/lib/zig/std/Io/Threaded.zig`), confirmed via `gdb -p <pid>`
  backtraces reproduced below — not inside any code this project wrote or
  any C library this project calls.
- Zig version: `0.16.0` (`zig version`), reproduced on Fedora Linux 44,
  glibc-backed native build (`x86_64-linux-gnu`).

## Reproduction

`scripts/zig_unsetenv_bug_repro.zig` — standalone, `zig run`-able, no
project dependencies:

```sh
zig run scripts/zig_unsetenv_bug_repro.zig -- panic-deadlock
zig run scripts/zig_unsetenv_bug_repro.zig -- spawn-segfault
zig run scripts/zig_unsetenv_bug_repro.zig -- print-workaround
zig run scripts/zig_unsetenv_bug_repro.zig -- spawn-still-broken-after-print-warmup
```

(Needs `$LANG` set in the calling shell — if it's already unset, the
script says so and exits instead of silently not reproducing anything.)

### `panic-deadlock` — observed output

```
before unsetenv: LANG=en_DK.UTF-8
after unsetenv: about to call std.debug.print for the FIRST time in this process...
thread 279912 panic: attempt to use null value
```
(then hangs; verified via `timeout 20` that it never exits on its own)

`gdb -p <pid>` backtrace while hung:

```
#0  futex wait
...
#5  Io.Threaded.scanEnviron (t=...)
#6  Io.Threaded.environString__anon_13335 (t=..., name=...)
#7  debug.ElfFile.DebugInfoSearchPaths.native (exe_path=...)
#8  debug.SelfInfo.Elf.Module.loadElf (...)
#9  debug.SelfInfo.Elf.Module.getLoadedElf (...)
#10 debug.SelfInfo.Elf.getSymbols (...)
#11 debug.printSourceAtAddress (...)
#12 debug.writeCurrentStackTrace (...)
#13 debug.defaultPanic (msg=..., first_trace_addr=...)
#14 debug.FullPanic((function 'defaultPanic')).unwrapNull ()
#15 Io.Threaded.Environ.scan (environ=..., allocator=...)   <- the panic
#16 Io.Threaded.scanEnviron (t=...)
#17 Io.Threaded.initLockedStderr (t=..., terminal_mode=...)
#18 Io.Threaded.lockStderr (...)
#19 Io.lockStderr (...)
#20 debug.lockStderr (...)
#21 debug.print__anon_41369 (...)
#22 <caller's std.debug.print call>
```

Reading bottom-up: our `std.debug.print` call (#22) locks stderr (#17-20),
which lazily calls `scanEnviron` (#16) to build the debug-info search-path
cache, which panics inside `Environ.scan` (#15) because `LANG` is gone.
The panic handler (`defaultPanic`, #13) then tries to *print the panic
message itself* — which walks straight back into `printSourceAtAddress`
→ `getSymbols` → `loadElf` → `DebugInfoSearchPaths.native` → **the same
`scanEnviron`/`environString` path** (#5-11), which tries to re-lock the
mutex `initLockedStderr` (#17) is still holding → permanent deadlock on a
`futex` wait (#0).

### `spawn-segfault` — observed output

```
spawning `true` BEFORE unsetenv (to prove spawn itself works, and that merely
spawning once beforehand does NOT pre-warm whatever cache avoids the crash)...
first spawn OK. Unsetting LANG...
spawning `true` AFTER unsetenv — this is where it segfaults...
Segmentation fault at address 0x0
/usr/lib/zig/std/mem.zig:1037:27: 0x117a534 in lenSliceTo__anon_24761 (std.zig)
                while (ptr[i] != end and ptr[i] != s) i += 1;
                          ^
/usr/lib/zig/std/mem.zig:958:30: 0x117a2af in sliceTo__anon_24310 (std.zig)
    const length = lenSliceTo(ptr, end);
/usr/lib/zig/std/process/Environ.zig:712:36: 0x116f6ce in createPosixBlock (std.zig)
        if (mem.eql(u8, mem.sliceTo(entry, '='), "ZIG_PROGRESS")) break true;
/usr/lib/zig/std/Io/Threaded.zig:14937:72: 0x116864a in spawnPosix (std.zig)
        break :env_block try t.environ.process_environ.createPosixBlock(arena, .{
/usr/lib/zig/std/Io/Threaded.zig:15098:35: 0x11662fe in processSpawnPosix (std.zig)
    const spawned = try spawnPosix(t, options);
/usr/lib/zig/std/process.zig:443:34: 0x1201eb4 in spawn (std.zig)
    return io.vtable.processSpawn(io.userdata, options);
```

`std.process.Environ.createPosixBlock` (`Environ.zig:712`) walks a raw
`entry` pointer expecting a NUL-terminated C string; it dereferences
memory that's no longer valid because `unsetenv()` already freed/moved
libc's `environ` backing array by the time this runs.

## Experiments (proving there's no simple ordering fix)

| # | Sequence | Result |
|---|---|---|
| 1 | `unsetenv` → first `debug.print` | panic → deadlock |
| 2 | spawn (OK) → `unsetenv` → spawn | segfault |
| 3 | `debug.print` warm-up → `unsetenv` → `debug.print` again | **succeeds** |
| 4 | `debug.print` warm-up → `unsetenv` → spawn | **still segfaults** |
| 5 | `unsetenv("NONEXISTENT_VAR")` (any of the above) | no crash — confirms this is specific to unsetting a var that was actually present |

Row 3 vs. row 4 is the important, slightly counter-intuitive result: the
`debug.print` warm-up genuinely fixes *later `debug.print` calls*, but it
does **not** also fix a later `std.process.spawn` call — the two lazy
caches are apparently unrelated despite superficially similar stack
traces. There is no ordering trick found that makes a spawn *after*
`unsetenv()` safe; the only mitigation is structural: never call
`std.process.spawn` after any `unsetenv()` call, anywhere, for the rest
of the process's life.

## Workaround shipped in this codebase

`scripts/canary_font.zig`'s `-unset=` flag (a manual, on-demand canary —
see `docs/EmojiWidthResearch.md`) is the only place in this codebase that
calls `unsetenv()`. It:

1. Runs its one and only `std.process.spawn` call (`mkdir -p`) **before**
   `applyUnset`.
2. Does one warm-up `std.debug.print("", .{})` call **before**
   `applyUnset`.
3. Never calls `std.process.spawn` again for the rest of the program.

This isn't a general-purpose fix — it works specifically because that
program's structure allows "no more spawns after this point." A program
that needs to spawn a child *after* dynamically unsetting an env var has
no known workaround available; it would need to avoid `unsetenv()`
entirely (e.g. build a fully custom `envp` array for the specific spawn
call instead of mutating the process's real environment).

## Next steps

- [ ] Report upstream to [ziglang/zig](https://github.com/ziglang/zig)
      issues, referencing this file and `scripts/zig_unsetenv_bug_repro.zig`
      (self-contained, no project dependencies, ready to attach/paste).
- [ ] Re-run `scripts/zig_unsetenv_bug_repro.zig`'s four modes against
      each new Zig release; close this issue once upstream fixes land and
      all four modes behave as their doc comments say a fixed version
      should (i.e. all reach their `SUCCESS:` line).
- [ ] If a future project ever needs to spawn a child *after* dynamically
      unsetting an env var (not true today — `canary_font.zig` never
      does), revisit: the only safe option found is avoiding `unsetenv()`
      and instead building an explicit `envp` for that one spawn call.

## Related

- `scripts/canary_font.zig` — where this was found (`-unset=` flag).
- `scripts/zig_unsetenv_bug_repro.zig` — the minimal, standalone
  reproduction referenced throughout this issue.
- `docs/Zig.md` §8 — the developer-facing "read before you write
  subprocess/environ code in Zig" version of this finding.
- `docs/EmojiWidthResearch.md` — the broader font-rendering research
  thread `-unset=` was built to support.
