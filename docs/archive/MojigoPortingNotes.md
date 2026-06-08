<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [WhyAndNiche.md](file:///home/uwe/projects/emojig/docs/WhyAndNiche.md)
> - **Extra Content Covered Here:** Specific porting challenges when migrating from Go to Zig, standard library differences, zero-allocation database search implementation, and termios management mapping.
> - **Outdated Information:** None.

---


# Mojigo — Porting & Testing Notes

Practical, hard-won notes from porting the Zig `emojig` TUI to Go (`mojigo`).
Read [`Mojigo.md`](Mojigo.md) first for architecture and the spec layout; this
doc captures the **method** and the **gotchas** — the things that aren't obvious
from the code and that the eventual Zig rewrite (which reuses `spec/*.json`)
will hit again.

## Porting methodology that worked

1. **Extract the spec first, render from data.** Layout/theme/keys/strings live
   in `spec/*.json`, not Go literals. "Minimal core" scopes which *features*
   ship, not whether the spec exists — the declarative files are the actual
   deliverable (they are the contract the Zig rewrite consumes). Store
   **semantic** values (256-color indices, `{count}` placeholders), never baked
   escape sequences or pre-formatted strings, so each renderer emits its own.

2. **Port the algorithm byte-for-byte, then port its tests.** The Zig
   `src/root.zig` had `test` blocks (`smile`/`grn` match, `xyz` doesn't,
   plurals/stems score > 0). Porting those to `fuzzy_test.go` gave a free
   correctness oracle — parity is *verified*, not eyeballed. Do the same for any
   logic with existing tests upstream.

3. **Faithful means faithful, including quirks.** The key handler only inspects
   `bytes[0]`, so batched input (`cat\r` in one read) types `cat` and drops the
   `\r`. We replicated that rather than "improving" it, to keep behavior
   identical. Document the quirk; don't silently diverge.

## Testing a raw-mode TUI without a human

Raw-mode/alt-screen apps need a PTY; piping a plain pipe makes `TCGETS` fail.
Drive them with `script`:

```sh
# Type a query, pause so Enter lands in a separate read(), then select:
perl -e '$|=1; print "cat"; select(undef,undef,undef,0.4); print "\r"' \
  | timeout 5 script -qec '/tmp/mojigo' /tmp/ts.txt >/dev/null 2>&1
```

Gotchas learned:

- **Separate keystrokes with delays.** Sending `cat\r` in one burst is one
  `read()`; the app sees it as batched input (see quirk above). Use
  `perl … select(undef,undef,undef,0.3)` for sub-second sleeps between keys.
  (Bare foreground `sleep` is blocked in this harness.)
- **`script` capture is linear** — `\x1b[2J` clears the screen but the bytes
  stay in the typescript, so successive frames concatenate. Don't compare a
  "grid block" against a "description block" across the dump; they may be from
  different frames. Inspect the **last** frame, or the bytes right before
  `script`'s `Script done` footer for the final stdout (e.g. the emitted emoji).
- **Verify navigation flows to output, not just decoding.** Right-arrow before
  Enter must change the *emitted glyph* (index 0 → 1). Comparing hex of the
  printed emoji across `\x1b[C` counts proved selection tracks through.

## Environment traps

- **VTE leaks into children.** `TILIX_ID` / `VTE_VERSION` are inherited, so ZWJ
  filtering auto-activates for every child run from a VTE terminal — match
  counts then differ (e.g. "fire" → 151 vs 180). To test the *toggle*, use
  `env -i PATH=… TERM=… …` for a clean environment; otherwise you measure the
  parent shell, not the flag. Precedence is also worth a unit test
  (`zwj_test.go`): explicit `EMOJIG_DISABLE_ZWJ=0` must beat an inherited
  `TILIX_ID`.
- **REUSE lints only VCS-tracked files.** Untracked new files pass `reuse lint`
  by being invisible, then fail once committed. `git add` before trusting the
  lint. Files that can't carry an SPDX header (`*.json`, `go.mod`) must be
  registered in `REUSE.toml`, not headered.
- **A root `go.mod` pulls `scripts/*.go` into the module.** Those are standalone
  `go run scripts/<name>.go` files (multiple `package main` → collide under
  `go build ./...`). They still run individually and the Makefile/`preflight`
  don't build the whole module, so it's a non-issue — but build mojigo via
  explicit paths (`go build ./cmd/mojigo`), never `./...`.
- **Embedding shared assets.** `//go:embed` can't reach `../`, so the embed
  directive lives in a package at the **module root** (`assets.go`,
  `package emojig`) that can see `data/` and `spec/`. This keeps a single source
  of truth and a self-contained binary.

## Stdlib raw mode (no `golang.org/x/sys`)

Linux raw mode is reachable with just `syscall`: `TCGETS`/`TCSETS` via
`SYS_IOCTL` on `syscall.Termios`, `TIOCGWINSZ` for size. Mandatory safety
(per `AGENTS.md`): `defer Restore()` for the normal/panic path **plus** a
`signal.Notify(SIGINT, SIGTERM)` goroutine that restores and exits, because
signals bypass deferred functions. `Restore` resets termios and emits
mouse-off + alt-screen-off + show-cursor.

## Open follow-ups (carried from the port)

- Split-escape robustness: with `VMIN=1 VTIME=0`, a lone `ESC` split across
  reads is treated as quit. Zig does a 100 ms follow-up read
  (`src/main.zig:1545`). Fine for local terminals; port for slow/remote ttys.
- Parity is *by construction* — it assumes `src/emojis.bin` is regenerated from
  the current `data/emoji.json`. No automated Go-vs-Zig output diff exists
  (the Zig binary copies to clipboard, not stdout).
- Deferred features remain: MRU, clipboard, mouse, system-theme detection,
  border/exit-fade, GUI mode, inline (non-alt-screen) rendering.
