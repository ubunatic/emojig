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

> ⚠️ **The "reallocate/free its backing array" mechanism stated in this
> paragraph is WRONG** — see "Independent review" below for the corrected
> root cause (stale cached *length*, not a freed/dangling array).
> Do not paste the sentence above into an upstream report.

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

> ⚠️ **Wrong mechanism again** (same as the Summary). Nothing is freed or
> moved: `entry` is exactly `null`, which is why the crash reports
> `address 0x0` rather than a garbage address. Corrected explanation in
> "Independent review" below.

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

- [ ] Report upstream to Zig's active issue tracker,
      [codeberg.org/ziglang/zig/issues](https://codeberg.org/ziglang/zig/issues)
      (GitHub issue creation is restricted — see "Independent review" §
      Correction 3), referencing this file and
      `scripts/zig_unsetenv_bug_repro.zig` (self-contained, no project
      dependencies, ready to attach/paste) — but only after completing the
      "Manual verification plan" below yourself.
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

---

## Independent review (second reviewer, skeptical pass)

All four repro modes were independently rebuilt and re-run from scratch on
Zig 0.16.0 / Fedora 44 / glibc. **The observable behaviour reproduces
exactly as claimed.** The *explanation* of why, however, was wrong in two
places, and one procedural detail (where to file) is out of date. Details
below, so nothing incorrect gets carried upstream.

### What reproduced (verified, own eyes)

| Mode | Observed | Exit |
|---|---|---|
| `panic-deadlock` | panics `attempt to use null value`, then hangs forever | `124` (killed by `timeout`) |
| `spawn-segfault` | `aborting due to recursive panic`, core dumped | `134` |
| `print-workaround` | reaches its `SUCCESS:` line | `0` |
| `spawn-still-broken-after-print-warmup` | `Segmentation fault at address 0x0` + full stdlib trace, core dumped | `134` |

### Correction 1 — the root cause is a stale cached *length*, not a dangling/freed pointer

The issue text above says glibc's `unsetenv()` "reallocate[s]/free[s] its
backing array" and that Zig then reads "a dangling pointer into memory
glibc already freed". That is not what happens. Measured directly:

```
environ array addr BEFORE = 0x7fffe2871e18, count = 87
environ array addr AFTER  = 0x7fffe2871e18, count = 86
array pointer changed? false
old_ptr[old_len-1] is null? true
```

The array address is **identical** before and after, and it lives at
`0x7fff…` — i.e. it is the original kernel-supplied `envp` block on the
stack. Nothing is allocated, freed, or moved. glibc's `unsetenv()` simply
shifts the remaining entries down one slot in place and writes the `NULL`
terminator one slot earlier.

The actual defect is on Zig's side, in `std/start.zig`:

```zig
// std/start.zig, fn main(...)
var env_count: usize = 0;
while (c_envp[env_count] != null) : (env_count += 1) {}
const envp = c_envp[0..env_count :null];
```

Zig measures `environ`'s length **once at startup** and stores it as a
fixed-length slice (`Environ.PosixBlock.slice: [:null]const ?[*:0]const u8`).
It never re-reads `std.c.environ` afterwards, so it can never observe a
mutation. After `unsetenv()` the cached length is one too large, so
iterating that slice walks one slot past the live terminator and reads the
`NULL` glibc just wrote. From there the two symptoms diverge:

- **Panic path** — `std/Io/Threaded.zig:313` (`Environ.scan`) does
  `const entry = opt_entry.?;` on that `NULL` ⇒ `attempt to use null value`.
- **Spawn path** — `Environ.PosixBlock.view()` does
  `return .{ .slice = @ptrCast(block.slice) };`, casting
  `?[*:0]const u8` → `[*:0]const u8` and thereby **silently discarding the
  optionality**. `createPosixBlock` (`Environ.zig:712`) then calls
  `mem.sliceTo(entry, '=')` on a null pointer ⇒ null deref. This is why the
  crash says `address 0x0` — decisive evidence *against* the
  "freed/dangling memory" story, which would produce a garbage address.

This corrected framing is *stronger* upstream, not weaker: it is a
one-line, obviously-wrong cached invariant plus a `@ptrCast` that defeats
Zig's own null-safety check, rather than a vague "libc moved memory" claim
a maintainer can wave away.

### Correction 2 — the deadlock is a separate, more clearly-defensible defect

The hang is not merely a consequence of the environ desync; it is an
independent hole in Zig's recursive-panic protection, and it is worth
reporting as its own point:

- `Threaded.scanEnviron()` takes `t.mutex`, and only sets
  `t.environ_initialized = true` **after** `environ.scan()` returns.
- `environ.scan()` panics while that mutex is held and the flag is still
  `false`.
- `defaultPanic` prints a stack trace → `debug/ElfFile.zig:73-79` calls
  `t.environString("DEBUGINFOD_CACHE_PATH" / "XDG_CACHE_HOME" / "HOME")`
  → `scanEnviron()` → `mutexLock(&t.mutex)` on a non-reentrant mutex ⇒
  permanent futex wait.
- Zig's `panic_stage` guard in `std/debug.zig:545-585` exists precisely to
  guarantee "abort rather than hang", and its comment even says *"We're
  still holding the mutex but that's fine as we're going to call abort()"*.
  That guard only advances on a *second panic*; a **deadlock** never
  reaches it. `lockStderr` has a same-thread re-entrancy escape hatch;
  `t.mutex` has none.

Consequence worth stating upstream: **any** panic inside `Environ.scan`
hangs the process unkillably, `unsetenv` or not. Note this sub-claim is
established by reading the source plus the observed hang, not by an
independent trigger, and should be worded that way.

### Correction 3 — Zig's issue tracker moved off GitHub

"Next steps" says to report to `github.com/ziglang/zig` issues. As of this
review, **new-issue creation is restricted on GitHub** and the active
tracker is **<https://codeberg.org/ziglang/zig/issues>** (newest issues
observed in the #36xxx range, dated within a day of this review). File
there.

### Honest counter-argument the filer should be ready for

This is not a slam dunk, and the issue text currently overstates its
certainty ("Proof this is a Zig stdlib bug, not user misuse"). A
maintainer could legitimately respond:

- POSIX itself warns that `setenv()`/`unsetenv()`/`putenv()` may invalidate
  pointers obtained earlier, and advises against using `main`'s third
  argument for exactly this reason. Zig caches `main`'s third argument.
- The C `environ` API is inherently unsound under mutation (not
  thread-safe, no locking); other languages have retreated from supporting
  it — Rust made `std::env::set_var` **`unsafe`** in Rust 2024 over the
  same hazard.
- Zig 0.16 deliberately removed `std.os.environ` and moved process APIs
  under `std.Io` (upstream PR *"std: delete `os.environ`, `os.argv`, add
  new parameter to `main`, move process API to `std.Io`"*). "Environment
  mutation after startup is unsupported" is a defensible design stance.

Weighing against that:

- Zig's stdlib contains **no documented prohibition** on POSIX environment
  mutation. A grep of `std/process/Environ.zig`, `std/process.zig` and
  `std/Io/Threaded.zig` finds the invalidation hazard acknowledged **only**
  in the Windows branch — `Environ.zig:22-24` ("the memory pointed at by
  the PEB changes when the environment is modified, so a long-lived
  pointer cannot be used") and `Threaded.zig:226` ("This value expires with
  any call that modifies the environment"). Zig therefore *knows* about the
  hazard and handles it on Windows while leaving POSIX exposed.
- Zig offers no sanctioned API to mutate the current process's environment
  at all, so "use the supported path instead" has no answer.
- Returning *stale data* would be defensible. Crashing with a null deref
  and hanging unkillably is a memory-safety failure in safety-checked
  builds, and the `@ptrCast` in `view()` actively removes the check that
  would have caught it.

**Reviewer's verdict: CONFIRMED reproducible stdlib defect**, but frame it
as *"stdlib caches `environ`'s length at startup and crashes unsafely
instead of degrading"* — a memory-safety and robustness report — rather
than *"`unsetenv()` must be supported"*, which invites a
working-as-intended close. Lead with the deadlock (Correction 2) and the
`view()` `@ptrCast` (Correction 1), which are hard to defend on any
design stance.

---

## Manual verification plan (no AI assistance)

Everything below is something **you** run and read yourself. No step asks
you to trust any AI's summary. If your own output disagrees with what is
written here, trust your output and stop.

### Step 0 — environment

```sh
zig version
zig env | grep std_dir
echo "LANG=$LANG"
```

Expect `0.16.0`, a `std_dir` path (`/usr/lib/zig/std` on this machine —
use *your* value everywhere below), and a **non-empty** `LANG`. If `LANG`
is empty, prefix every run below with `LANG=en_US.UTF-8 `.

### Step 1 — build the repro

```sh
zig build-exe scripts/zig_unsetenv_bug_repro.zig -femit-bin=/tmp/repro_verify -lc
```

Expect: **no output at all**, and `/tmp/repro_verify` to exist.

### Step 2 — run mode 1 (`panic-deadlock`)

```sh
timeout 15 /tmp/repro_verify panic-deadlock; echo "EXIT=$?"
```

Expected raw output (thread id will differ):

```
before unsetenv: LANG=en_US.UTF-8
after unsetenv: about to call std.debug.print for the FIRST time in this process...
thread 293832 panic: attempt to use null value
EXIT=124
```

Read it yourself: `EXIT=124` is `timeout`'s "I had to kill it" code. The
process printed the panic line and then produced **nothing further for a
full 15 seconds**. It must never print `SUCCESS:` and never exit on its
own. (Run it without `timeout` once if you want to watch it hang and kill
it with Ctrl-C yourself.)

### Step 3 — run mode 2 (`spawn-segfault`)

```sh
timeout 15 /tmp/repro_verify spawn-segfault; echo "EXIT=$?"
```

Expected raw output:

```
spawning `true` BEFORE unsetenv (to prove spawn itself works, and that merely
spawning once beforehand does NOT pre-warm whatever cache avoids the crash)...
first spawn OK. Unsetting LANG...
spawning `true` AFTER unsetenv — this is where it segfaults...
aborting due to recursive panic
timeout: the monitored command dumped core
EXIT=134
```

⚠️ Note for your own eyes: this mode prints **`aborting due to recursive
panic`**, *not* the long stdlib stack trace that the "`spawn-segfault` —
observed output" section earlier in this file shows. That earlier trace is
really mode 4's output (mode 2 never did a warm-up `debug.print`, so the
crash reporter itself cannot print). Do not be alarmed by the mismatch —
it is a labelling error in this file, corrected here. What matters: `true`
spawns fine *before* `unsetenv` and the process dies *after*.

### Step 4 — run mode 3 (`print-workaround`)

```sh
timeout 15 /tmp/repro_verify print-workaround; echo "EXIT=$?"
```

Expected raw output:

```
warm-up debug.print, before any unsetenv
SUCCESS: second debug.print call, after unsetenv, did not panic
EXIT=0
```

This is the control: it proves the toolchain and your shell are fine, and
that the failures above are ordering-dependent rather than "this binary is
just broken".

### Step 5 — run mode 4 (`spawn-still-broken-after-print-warmup`)

```sh
timeout 15 /tmp/repro_verify spawn-still-broken-after-print-warmup; echo "EXIT=$?"
```

Expected raw output (addresses will differ; **paths and line numbers
should match**):

```
warm-up debug.print, before any unsetenv
Segmentation fault at address 0x0
/usr/lib/zig/std/mem.zig:1037:27: ... in lenSliceTo__anon_NNNNN (std.zig)
                while (ptr[i] != end and ptr[i] != s) i += 1;
/usr/lib/zig/std/mem.zig:958:30: ... in sliceTo__anon_NNNNN (std.zig)
/usr/lib/zig/std/process/Environ.zig:712:36: ... in createPosixBlock (std.zig)
        if (mem.eql(u8, mem.sliceTo(entry, '='), "ZIG_PROGRESS")) break true;
/usr/lib/zig/std/Io/Threaded.zig:14937:72: ... in spawnPosix (std.zig)
/usr/lib/zig/std/Io/Threaded.zig:15098:35: ... in processSpawnPosix (std.zig)
/usr/lib/zig/std/process.zig:443:34: ... in spawn (std.zig)
...zig_unsetenv_bug_repro.zig:121:42: ... in main (zig_unsetenv_bug_repro.zig)
timeout: the monitored command dumped core
EXIT=134
```

Two things to confirm with your own eyes: **`address 0x0`** exactly (not
some other address), and that every frame between `main` and the crash is
in **your `std_dir`**, i.e. Zig's stdlib — no third-party library appears.

### Step 6 — verify the root cause yourself (the part the issue text got wrong)

Save this as `/tmp/mech.zig`:

```zig
const std = @import("std");
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub fn main() void {
    std.debug.print("warmup\n", .{});
    const before_ptr = std.c.environ;
    var n_before: usize = 0;
    while (before_ptr[n_before] != null) : (n_before += 1) {}
    std.debug.print("BEFORE addr={*} count={d}\n", .{ before_ptr, n_before });

    _ = unsetenv("LANG");

    const after_ptr = std.c.environ;
    var n_after: usize = 0;
    while (after_ptr[n_after] != null) : (n_after += 1) {}
    std.debug.print("AFTER  addr={*} count={d}\n", .{ after_ptr, n_after });
    std.debug.print("pointer changed? {}\n", .{before_ptr != after_ptr});
    std.debug.print("old_ptr[old_len-1] is null? {}\n", .{before_ptr[n_before - 1] == null});
}
```

```sh
zig build-exe /tmp/mech.zig -femit-bin=/tmp/mech -lc && /tmp/mech
```

Expected (your addresses and counts will differ):

```
warmup
BEFORE addr=?[*:0]u8@7fffe2871e18 count=87
AFTER  addr=?[*:0]u8@7fffe2871e18 count=86
pointer changed? false
old_ptr[old_len-1] is null? true
```

Judge for yourself: the address is **the same** before and after, so
nothing was freed or reallocated; the count dropped by exactly one; and
the slot at the *old* last index is now `null`. That is the whole bug —
Zig kept the old count.

### Step 7 — read the stdlib source yourself

Use your own `std_dir` from Step 0. Open each file and decide for yourself
whether it does what is claimed:

```sh
S=$(zig env | sed -n 's/.*\.std_dir = "\(.*\)".*/\1/p')

# (a) the length is measured once, at startup, and never re-read:
grep -n "env_count" "$S/start.zig"

# (b) the cached type is a fixed-length slice of OPTIONAL pointers,
#     and view() @ptrCasts the optionality away:
sed -n '20,70p' "$S/process/Environ.zig"

# (c) the null-unwrap that panics (look for `opt_entry.?`):
sed -n '305,320p' "$S/Io/Threaded.zig"

# (d) the null deref that segfaults (line 712):
sed -n '705,715p' "$S/process/Environ.zig"

# (e) the mutex held across the panicking scan:
grep -n -A6 "fn scanEnviron" "$S/Io/Threaded.zig"

# (f) the re-entry that deadlocks: environString from the panic printer:
grep -n "environString" "$S/debug/ElfFile.zig"

# (g) Zig's recursive-panic guard, which a deadlock never reaches:
sed -n '543,586p' "$S/debug.zig"

# (h) the ONLY places the stdlib acknowledges this hazard — both Windows:
sed -n '20,26p' "$S/process/Environ.zig"
sed -n '224,228p' "$S/Io/Threaded.zig"
```

Questions to answer for yourself from (a)–(h), without anyone's help:

1. Does anything ever re-read `std.c.environ` after startup? (Expected: no.)
2. Does `view()` throw away the `?` before the pointer is dereferenced?
3. Is `t.mutex` still held, and `t.environ_initialized` still `false`, at
   the moment `scan` panics?
4. Does the panic printer really call back into `scanEnviron`?
5. Does the stdlib document anywhere that mutating the environment via
   libc is forbidden on POSIX, or is that acknowledgement Windows-only?

If your answer to (5) is "it does document it somewhere I found" — that
changes the report substantially. Quote where, and reconsider filing.

### Step 8 — check whether it is already reported

Zig's active tracker is **Codeberg**, not GitHub (GitHub restricts new
issue creation). Search yourself at
<https://codeberg.org/ziglang/zig/issues> — search **open and closed**:

- `unsetenv`
- `setenv environ`
- `createPosixBlock`
- `scanEnviron`
- `Environ.scan`
- `environ stale`
- `recursive panic deadlock`

Also worth a look: <https://codeberg.org/ziglang/zig/pulls> for
`os.environ` / `process API to std.Io`, which is the change that
introduced this design and may already carry a discussion of the hazard.

- **If you find a match** — comment on it with your Step 2–6 output and
  link this file. Do **not** open a duplicate.
- **If you find only a related design discussion** (e.g. "environ mutation
  is unsupported") — read it before filing; it may already answer this,
  in which case close this issue as working-as-intended instead.
- **If you find nothing** — file new on Codeberg. Attach
  `scripts/zig_unsetenv_bug_repro.zig` and `/tmp/mech.zig`, paste your
  own Step 2–6 raw output, and describe the mechanism as
  *"`start.zig` caches `environ`'s length at startup; `PosixBlock.view()`
  `@ptrCast`s away the optional, so a shifted `NULL` terminator becomes a
  null deref; and a panic inside `Environ.scan` deadlocks on `t.mutex`
  instead of reaching `panic_stage`'s abort."* Present it as **your own
  verification** per this checklist. Do not claim AI analysis as evidence.

### Tripwires — if ANY of these fail, STOP and do not file

- [ ] `zig version` is **not** `0.16.0` → your findings may not apply; re-run everything on 0.16.0 or report the version you actually tested.
- [ ] Step 1 emits build errors or warnings → fix the build first; a miscompile is not this bug.
- [ ] Mode 1 exits on its own (any `EXIT` other than `124`), or prints `SUCCESS:` → the deadlock claim is wrong on your system. Stop.
- [ ] Mode 3 does **not** print `SUCCESS:` / does not exit `0` → your toolchain or shell is broken; nothing else here is trustworthy. Stop.
- [ ] Mode 4's crash address is **not** `0x0` → the mechanism in Correction 1 is wrong. Stop and re-investigate.
- [ ] Mode 4's backtrace shows any frame **outside** your `std_dir` (other than `main` in the repro) → not a pure-stdlib bug. Stop.
- [ ] Step 6 shows `pointer changed? true` → glibc *did* reallocate on your system; the mechanism differs and the writeup must be redone before filing.
- [ ] Step 7 question (1) turns out "yes, it re-reads `environ`" → the cached-length theory is wrong. Stop.
- [ ] Step 7 question (5) turns out "yes, POSIX mutation is documented as unsupported" → likely working-as-intended. Do not file; close this issue instead.
- [ ] Step 8 finds an existing issue → comment there, do not file.
- [ ] You have not personally run every command above and read its output → do not file.
