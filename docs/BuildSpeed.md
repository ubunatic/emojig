<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Zig Build Speed: LLVM vs Self-Hosted Backend

Reference for anyone touching `build.zig` or wondering why `make install` is
slow (or, after this change, why it's fast). Measured June 2026 on zig 0.16.0.

## The question that started this

"Can we use a faster linker like mold for `make install`?"

## The answer: no, linking was never the bottleneck

Zig's native ELF target does **not** shell out to an external linker (`ld`,
`lld`, `mold`, ...) — it uses its own fast self-hosted linker by default. The
slow part of `-Doptimize=ReleaseSmall` is **LLVM's codegen/optimizer**, which
runs regardless of which linker is involved. Swapping linkers would have done
nothing; the lever that actually matters is whether LLVM runs at all.

## The lever: `exe.use_llvm` / `-Dllvm`

`std.Build.Step.Compile` exposes `use_llvm: ?bool` (CLI: `-Dllvm=true|false`
once wired up as a `b.option` in `build.zig`, see below). Setting it to
`false` skips LLVM entirely and uses zig's self-hosted backend instead.

Measured on this codebase (clean cache, then a one-line source touch for the
incremental number):

| Build                                   | Clean | Incremental | Binary size      |
|------------------------------------------|------:|------------:|-------------------|
| LLVM `ReleaseSmall` (old `make install`)  | 9.3s  | 7.1s         | 725 KB (stripped)  |
| Self-hosted `ReleaseFast`, unstripped     | 1.5s  | 0.6s         | 20.8 MB            |
| Self-hosted `ReleaseFast`, module-stripped| 1.4s  | 0.5s         | 5.7 MB             |

That's a **~12x** speedup on incremental rebuilds.

## The surprise: runtime speed doesn't suffer

The self-hosted backend has no optimizer (no inlining, no real dead-code
elimination), so the intuition is "fast to compile, slow to run." For this
codebase that intuition is wrong. Benchmarking the fuzzy-search hot path
(`zig build test -Doptimize=ReleaseFast`, `EMOJIG_BENCH=5000`):

- LLVM `ReleaseFast`: 29,587 searches/s
- Self-hosted `ReleaseFast`: 29,886 searches/s

Within noise of each other. `ReleaseFast` already disables the
bounds/overflow safety checks that make `Debug` slow at runtime — that's
where the speed comes from, not LLVM's instruction-level optimization. The
only thing you actually give up by skipping LLVM is binary size (no
dead-code elimination, no inlining), not execution speed.

## What this means for the size budget

CLAUDE.md commits to a binary-size/RSS budget (~650 KB / 2.5 MB RSS) for
**release** artifacts. The self-hosted backend cannot meet that — even
module-stripped (`.strip = true`, no external `strip` binary needed) it's
5.7 MB, ~8x over budget. So:

- **Dev installs** (`make install`, run often): self-hosted, `ReleaseFast`,
  module-stripped. Fast to build, full runtime speed, size doesn't matter
  because it's not what ships.
- **Release / pre-upload installs** (`make install-small`): LLVM,
  `ReleaseSmall`. Slow to build, but hits the size budget. `goreleaser`
  (`make release-build` / `release-publish`) builds release artifacts
  directly via `zig build -Doptimize=ReleaseSmall` and was never on the fast
  path to begin with, so it's unaffected by any of this.

## Implementation

In `build.zig`:

```zig
const use_llvm = b.option(bool, "llvm", "...") orelse true;
...
const exe = b.addExecutable(.{
    .name = "emojig",
    .use_llvm = use_llvm,
    .root_module = b.createModule(.{
        .strip = if (use_llvm) null else true,
        ...
    }),
});
```

`strip` is tied to `use_llvm` rather than being its own flag: LLVM
`ReleaseSmall` already auto-strips (zig's default), and LLVM
`ReleaseFast`/`Debug` keep their prior unstripped behavior — only the
self-hosted path needed an explicit nudge to avoid shipping a 20 MB dev
binary with full debug info.

In `Makefile`:

```makefile
OPTIMIZE ?= ReleaseFast
LLVM ?= false
...
install: ⚙️  # fast build, default
	zig build shell-install -Doptimize=$(OPTIMIZE) -Dllvm=$(LLVM)

install-small: ⚙️  # smallest binary (LLVM ReleaseSmall, slow build) — use before releases
	@$(MAKE) install OPTIMIZE=ReleaseSmall LLVM=true

install-debug: ⚙️  # debug build, safety checks on
	@$(MAKE) install OPTIMIZE=Debug
```
