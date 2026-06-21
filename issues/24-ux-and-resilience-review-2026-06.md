<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# UX & Resilience Review — 2026-06-21

## Scope

This review focused on the repo surfaces that most directly affect **end-user UX,
runtime resilience, install/update trust, and backlog quality**:

- core Zig TUI/runtime paths
- GUI host selection
- config + MRU persistence
- install/update tooling
- existing issue docs and tracker hygiene

I validated the current baseline with:

- `make test`
- `go run ./scripts/test_tui`
- `go run ./scripts/review_audit all`

`make test` and the PTY harness both pass, so the main risks are no longer
"the app is broadly unstable" but rather a smaller set of **sharp edges, drift,
and trust gaps**.

## Executive summary

| Area | Status | Why it matters | Next place to invest |
|---|---|---|---|
| Install/update integrity | **New confirmed gap** | The release plan promises verification, but `scripts/install.sh` still downloads and extracts without `SHA256SUMS`/`minisign`, and self-update still falls back to `curl \| sh`. | [Issue 26](26-install-and-update-integrity-gap.md) |
| GUI host auto-detection | **New confirmed gap** | `xfce4-terminal` is implemented as a host kind but omitted from auto-detection, so GUI fallback can fail on systems where it is the only supported terminal. | [Issue 25](25-xfce4-terminal-autodetect-gap.md) |
| Config + MRU persistence edges | **New confirmed gap** | Config loading still treats a full 4 KB read as "return defaults", and MRU uses the same 4 KB pattern without a full-buffer guard. | [Issue 27](27-persistence-buffer-edges.md) |
| Wayland clipboard UX | **Old issue still live** | `copyToClipboard` still spawns raw `wl-copy` with inherited env and no debounce/cancellation, so issue 20 remains relevant. | [Issue 20](20-wl-clipboard-opens-as-desk-app.md) |
| TUI redraw flicker | **Old issue still live** | The render path still uses repeated `\x1b[2K\r` pre-clears in `src/main.zig`, so issue 16 is not stale yet. | [Issue 16](16-tui-flicker.md) |
| Tracker hygiene | **Needs cleanup** | `issues/README.md` had open issues missing from the table, and several "open" docs now read more like completed work or mixed historical notes. | backlog cleanup after prioritization |

## What looks healthy now

These areas looked materially better than older issues suggest:

1. **Core terminal restore safety improved.** The VTE-specific `?1049l` restore bug is fixed in `src/term.zig:196-197`, and the critical mouse-enable ordering bug tracked by old issue 03 is not present anymore.
2. **The TUI harness is in decent shape.** `go run ./scripts/test_tui` passes the focus, quit, category, and multi-select flows.
3. **General search behavior looks solid.** Search/filter coverage in `src/root_test.zig` is broad, and I did not find a high-priority search ranking regression that beats the three new issues above.

## New validated issues

### 1. Install/update integrity drift

This is the highest-priority new finding.

- `issues/02-distribution-and-release.md:356` says the installer path should download tarball + `SHA256SUMS`, verify the hash, then extract.
- `scripts/install.sh:50-61` says "Download & Verify Release Archive" but does not reference `SHA256SUMS`, `sha256sum`, or `minisign` at all.
- `src/integration.zig:286` still uses `curl -sSf https://ubunatic.com/emojig/install.sh | sh` as the curl-install update path.

That means the repo's current **trust model is documented, but not enforced**.

See [Issue 26](26-install-and-update-integrity-gap.md).

### 2. GUI auto-detection gap for xfce4-terminal

- `src/host.zig:99` supports `xfce4-terminal` in `hostKindFromName`.
- `src/host.zig:286` has a dedicated `.xfce4_terminal` argv path.
- but the auto-detection candidates in `src/host.zig:70-80` omit `xfce4-terminal`.

So the codebase says "this host is supported", but auto-mode cannot discover it.
That is a pure UX footgun for environments that rely on GUI fallback.

See [Issue 25](25-xfce4-terminal-autodetect-gap.md).

### 3. Persistence buffer edge cases still exist

- `src/config.zig:62` still does `if (len == file_buf.len) return cfg;`, so a
  config file that exactly fills the 4 KB buffer is treated as "load nothing".
- `src/mru.zig:31-32` uses the same 4 KB single-read pattern but has **no**
  equivalent full-buffer guard, so a large MRU file is truncated silently.
- Closed issue 01 documents the old 1 KB version of the same class of problem.

This is not a day-one UX issue, but it **is** a real resilience problem for the
settings/state layer and is worth fixing before more config/state features land.

See [Issue 27](27-persistence-buffer-edges.md).

## Old issues that still deserve attention

### Issue 16 is still current

The current render path still uses repeated `\x1b[2K\r` clears in
`src/main.zig` (`1337`, `1783`, `1791`, `1813`, `1819`, and many more).
So [Issue 16](16-tui-flicker.md) is not just historical context yet.

### Issue 20 is still current

`copyToClipboard` still launches plain `wl-copy` directly in
`src/main.zig:3913-3923`, with no debounce, no previous-process management, and
no token stripping in the child environment. The code does not yet reflect the
mitigations proposed in [Issue 20](20-wl-clipboard-opens-as-desk-app.md).

## Old issues that look stale or mixed

### Issue 12 needs a trim/split pass

The core VTE alt-screen restore bug described at the top of
[Issue 12](12-tui-line-cleanup-and-terminal-restoration.md) is fixed in
`src/term.zig:196-197`, but the doc still mixes that resolved history with a
much larger bundle of cleanup asks. It would be easier to prioritize if the
fixed history were separated from any still-open cleanup work.

### Issues 14 and 15 read like implemented work

- [Issue 14](14-gui-desktop-scenario-recording.md)
- [Issue 15](15-mojigo-inline-height-mode.md)

Both describe implemented work rather than active backlog. They look like good
candidates to move into `issues/closed/` once you are happy with the archive.

### Issues 20 and 22 were not indexed in `issues/README.md`

The tracker table had drifted away from the actual files. That makes the backlog
harder to trust during prioritization, especially when some "open" items are
already effectively done.

## Secondary findings worth tracking, but not promoting yet

These are real, but I would not spend the next effort cycle on them before the
three new confirmed issues and the still-live old issues above:

1. **Whitespace intolerance in `disabled_categories`.** `src/main.zig:1420-1430`
   splits by comma but does not trim per-item whitespace, so manual edits like
   `disabled_categories=clocks, flags` break the second entry.
2. **Unknown config keys are silently ignored.** `src/config.zig:67-99` has no
   validation or diagnostic path for typos.
3. **Tooling command drift:** `make screenshot` works, but `zig build screenshot`
   does not exist, even though older docs and issue acceptance text still refer
   to it.

## Recommended investment order

1. **Issue 26 + issue 02** — lock down install/update trust first.
2. **Issue 25** — fix GUI fallback detection drift before more terminal-host work accumulates.
3. **Issue 27** — harden settings/state persistence before growing config/MRU usage.
4. **Issue 20** — improve Wayland clipboard behavior, especially for GNOME-style desktop UX.
5. **Issue 16** — revisit redraw strategy and clear-path behavior once clipboard/install risks are reduced.
6. **Backlog cleanup** — close or archive stale docs, then refresh `issues/README.md` again.
