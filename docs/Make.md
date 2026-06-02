# Using Make as a Thin Wrapper

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026. Matches the thin Makefile wrapper patterns utilized in **Emojig v0.1.5**.

## Why

`make <TAB>` completes target names in virtually every shell out of the box.
Custom build systems (Zig, Cargo, Bazel, …) rarely get the same treatment.
A thin Makefile that delegates to the real build system gives you universal
completion without duplicating logic.

## Pattern

Keep all logic in the real build system. The Makefile just names targets and
forwards calls:

```makefile
.PHONY: ⚙️  # one phony prerequisite shared by all targets

help: ⚙️
    @real-build-tool --list-steps

foo bar baz: ⚙️
    real-build-tool $@

# special case: different name in the underlying system
install: ⚙️
    real-build-tool app-install
```

## Rules

**Name every target explicitly.** Shell completion reads the Makefile and lists
named targets. A `%` catch-all pattern is invisible to completion — don't use
it as the primary dispatch mechanism.

**Use a shared phony prerequisite instead of listing everything in `.PHONY`.**
`.PHONY: ⚙️` followed by `target: ⚙️` on every rule achieves the same effect
with less repetition. The `⚙️` name is arbitrary; any name not matching a real
file works.

**Group targets that share the same command on one line.**
```makefile
foo bar baz: ⚙️
    real-build-tool $@
```
`$@` expands to whichever target was invoked, so `make bar` runs
`real-build-tool bar`.

**Guard against make remaking itself.** If you ever use a `%` catch-all
(e.g. as a fallback), GNU Make will try to apply it to `Makefile` itself on
startup. Prevent this with an explicit no-op rule:
```makefile
Makefile: ;
```

**Handle reserved names explicitly.** Some build systems reserve step names
(`install` in Zig, `build` in Cargo). Map the Make name to the underlying
system's actual name in an explicit rule rather than relying on `$@`.

## What belongs in the Makefile vs the build system

| Makefile | Build system |
|----------|-------------|
| Target names (for completion) | Actual commands and dependencies |
| Special-case name remapping | Step descriptions (`--list-steps`) |
| Flags that differ from defaults (e.g. `zig build -Doptimize=ReleaseSmall`) | Everything else |
