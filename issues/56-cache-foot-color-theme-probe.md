<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# 56 — cache the foot color-theme dialect probe result in config; move it off the launch-blocking path

**Priority: P3** (the probe it's caching is already cheap — ~5-7ms,
measured 2026-08-09 — this is a further optimization + design cleanup, not
a correctness fix)

## Summary

`footSupportsColorThemeSections` (`src/host.zig`, added while fixing issue
53's close-time warning-flash bug) shells out to `foot --check-config`
against a throwaway `[colors-dark]` probe file on **every** `--gui` launch,
synchronously, before `spawnGuiWindow` execs the actual foot window. It's
cheap (~5-7ms) but it's still dead weight on every single launch when the
installed foot binary essentially never changes between launches.

Resolved via discussion (2026-08-09) — decisions below are final for this
issue, not open questions:

1. **Storage**: the same config file user settings already live in
   (`~/.config/emojig/config`), via the existing `saveKeyToConfig`/
   `loadConfig` machinery in `src/config.zig` — not a separate cache file.
2. **Cached value**: both the foot version string *and* the resulting
   boolean (e.g. two keys, `foot_colors_dialect_version=1.27.0` +
   `foot_colors_dialect_supported=1`, or one combined
   `foot_colors_dialect=1.27.0:colors-dark` — pick whichever fits
   `config.zig`'s existing key=value line format more naturally when
   implementing). Storing the version alongside the bool means the cache is
   self-documenting and, if it's ever visibly wrong, a human reading the
   config file can immediately see what foot version produced it.
3. **Probe timing — the key architectural change**: do **not** probe
   synchronously before spawning the window at all, on any launch that has
   a cached value to fall back on. Instead:
   - **Launch-time (blocking path, must stay fast)**: read whatever is
     currently cached in the config and use it immediately to decide the
     `colors`/`colors-dark`+`colors-light` dialect for this launch's foot
     argv. No subprocess spawn, no blocking — this is a plain config read,
     same cost as every other `EMOJIG_*`/config value `spawnGuiWindow`
     already resolves.
   - **Post-spawn (still inside the short-lived `--gui` launcher process,
     after `std.process.spawn` has returned)**: since `spawnGuiWindow`'s
     `std.process.spawn` call is already non-blocking fork+exec — the foot
     window pops up and becomes responsive independently of what the
     parent launcher process does next — run the live
     `foot --check-config` probe *here*, after the window is already up,
     and write the fresh `(version, bool)` pair back to config
     unconditionally. This seeds the *next* launch. The window the user
     sees is never delayed by this; only the launcher process's own exit is
     delayed by ~5-7ms, and the launcher process has no visible UI of its
     own to delay.
   - Net effect: every launch refreshes the cache (so there's no staleness
     window, no version-comparison logic, and no hardcoded "how old is too
     old" cutoff needed — explicitly rejected during discussion as
     reintroducing the version-boundary-guessing problem issue 53's fix was
     designed to avoid), but the probe cost is *never* on the path that
     determines when the user-visible window appears.
4. **Cold start (no cache entry yet, e.g. first-ever launch, or a corrupt/
   unparseable cached value)**: fall back to today's behavior exactly —
   probe live and synchronously, before spawning, same as the current
   (issue 53) implementation. Only later launches (once a cache entry
   exists) get the moved-off-critical-path treatment above. This keeps
   first-run behavior unchanged and safe (no risk of guessing the dialect
   wrong on a fresh install) at the cost of the existing ~5-7ms on launch
   #1 only.

## Why no time-based staleness or safety-net re-probe

Because the post-spawn probe runs on **every** launch once a cache exists
(not conditionally on version match, not conditionally on cache age), the
cache is refreshed continuously as a side effect of normal use. There is no
window where a stale cached value could persist across more than one
launch — the very next launch reads whatever the previous launch's
post-spawn probe just wrote. A foot upgrade is picked up starting the
*second* launch after the upgrade, not immediately, but that's an
acceptable one-launch lag for a purely cosmetic (deprecation-warning-flash)
concern, and matches how other resolved-at-launch values in this codebase
already behave (e.g. `EMOJIG_COLS`/`EMOJIG_ROWS` resolution order in
`docs/EnvironmentDetection.md §2`).

## Implementation sketch

- `src/config.zig`: add `foot_colors_dialect_version: ?[]const u8` and
  `foot_colors_dialect_supported: ?bool` (or equivalent combined field) to
  `Config`, parsed in `loadConfig`.
- `src/host.zig`: `spawnGuiWindow` gains a `cached_dialect: ?struct { version: []const u8, supported: bool }` parameter (or reads `init`-provided config directly, matching how it already reads `init.environ_map` for `EMOJIG_TERMINAL`).
  - If `cached_dialect` is present: use `cached_dialect.supported` directly
    for `colors_section`/`color_theme_arg`, skip the pre-spawn probe
    entirely.
  - If absent: keep today's synchronous `footSupportsColorThemeSections`
    call before spawn (cold-start path).
  - After `std.process.spawn(...)` returns (regardless of which path was
    taken above): call `footSupportsColorThemeSections` again, get the
    current `foot --version` string, and write both to config via
    `config.saveKeyToConfig` — unconditionally, every launch.
- Needs a way to read `foot --version`'s output separately from
  `footSupportsColorThemeSections`'s pass/fail check (currently that
  function only returns a bool) — either have it also return the parsed
  version string, or add a small sibling helper.

## Next steps

- [ ] Implement per the sketch above; verify with the same headless canary
      pattern used for issue 53 (no PASS/FAIL check currently asserts
      *which* dialect was chosen — may need a new canary check reading the
      config file post-launch, or a `-verify-config` style flag on a small
      Go test harness, following the PNG-first proof-pattern precedent
      where a pixel check *can't* observe this internal decision).
- [ ] Confirm `saveKeyToConfig`'s existing 4KB-buffer/partial-write handling
      (issue 27, `27-persistence-buffer-edges.md`) comfortably covers two
      more short key=value lines — should be trivially true, but check
      before assuming.
- [ ] Decide exact key name(s) and format (two keys vs. one combined
      `version:dialect` value) during implementation, matching whichever
      reads more naturally against existing `config.zig` key conventions.
- [ ] Update `src/host.zig`'s `footSupportsColorThemeSections` doc comment
      to describe the new caller contract (cold-start-only vs. post-spawn
      refresh) once split.

## Related

- Issue [53](53-foot-grapheme-width-tweak.md) — where
  `footSupportsColorThemeSections` was introduced (as a synchronous
  pre-spawn probe) to fix the close-time deprecation-warning flash.
- `docs/EmojiWidthResearch.md` — the broader research thread this and
  issue 53 both grew out of.
- `src/config.zig` `saveKeyToConfig`/`loadConfig` — the existing machinery
  this issue reuses rather than inventing a new cache-file mechanism.
