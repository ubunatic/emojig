<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
title: "`:report` command — file a bug/problem via prefilled Codeberg issue URL"
status: open
priority: p3
---

# 42 - `:report` command — file a bug/problem via prefilled Codeberg issue URL

**Status:** Open
**Priority:** P3

## Problem

There is no in-app way to report a bug or problem. Users who hit an issue while
using `emojig` have to remember the repo URL, open a browser themselves, and
write an issue from scratch with no context about their environment. This is
enough friction that most problems never get reported.

## Goal

Add a `:report` custom command (`spec/commands.yaml`, alongside `:help`,
`:status`, `:update`) that lets the user type a short title and body for a
problem report, then opens the user's browser at:

```
https://codeberg.org/ubunatic/emojig/issues/new?title=<url-encoded title>&body=<url-encoded body>
```

Codeberg (like GitHub/Gitea) pre-fills the new-issue form from `title=`/`body=`
query params, so the browser tab lands on a ready-to-submit issue — the app
itself never talks to the network or holds a token.

## Command spec

`spec/commands.yaml` entry:

```yaml
- name: report
  short: r
  action: open_report
```

`cmd_start_chars` is already `'/:'`, so both `:report` and `/report` (and the
`:r` short form) work via the existing autocomplete path in `main.zig`
(`is_cmd_autocomplete` block, `src/main.zig:4520` `cmd.action` dispatch chain).

## New screen: `.report`

Modeled on the existing `.settings`/`.categories` screens (own `current_screen`
enum value, own scroll/selection state), not on the one-shot popup used by
`:update`/setting-help, because it needs two editable text fields:

- **Title** — single line, reuses the existing prompt text-editing primitives
  (`query_cursor`, `deleteAtCursor`/`forwardDeleteAtCursor`, `Home`/`End`)
  already used for the search box.
- **Body** — multi-line free text. Pre-filled with a diagnostic preamble the
  user can edit or delete, sourced the same way `:status` renders its report
  (version, OS/arch, terminal `$TERM`/`TERM_PROGRAM`, GUI vs TUI mode, theme).
  Keep it short — long prefilled bodies risk exceeding URL length limits (see
  Risks).

Navigation: `Tab`/`Shift-Tab` (or `Up`/`Down`) switches focus between Title and
Body, matching the existing `Tab` semantics used for category cycling
elsewhere. `Enter` on the Title field moves to Body; `Ctrl-Enter` or a
dedicated "submit" row/hint opens the URL (plain `Enter` inside a multi-line
body field must insert a newline, not submit — don't overload it). `Esc`
cancels back to search without opening anything.

## Opening the browser

There is currently no "open URL in default browser" capability in the
codebase — `src/host.zig` only knows how to *launch a terminal emulator*
running `emojig --tui` for `--gui` mode. This needs a small sibling helper,
not a reuse of `spawnGuiWindow`:

- Try, in order: `$BROWSER` (if set and on `PATH`), `xdg-open` (Linux desktop
  standard), `wslview` (WSL), `open` (macOS, for future `--tui`-only macOS
  builds per issue 02).
- Spawn-and-detach (`std.process.spawn`, matching the pattern already used in
  `src/integration.zig` for `runUpdate`'s subprocess) — do not block the TUI
  waiting for the browser to exit, and do not treat a slow/backgrounded
  browser process as a picker timeout reset.
- If no opener is found or the Wayland/X11 session check (already implemented
  in `host.zig` for `--gui`) fails, fall back to printing the URL as a popup
  message (`popup_msg`) the user can select/copy manually — never hard-fail.

Consider whether this opener command list belongs in `spec/host.yaml`
(extending `detection`) or a new small `spec/report.yaml` — per the
spec-driven-config convention (`AGENTS.md` §Quickstart), the candidate list
and query-param field names should not be hardcoded in Zig.

## URL encoding

Title/body must be percent-encoded (space → `%20` or `+`, reserved chars
escaped) before insertion into the query string. No existing URL-encoder
exists in the codebase — needs a small zero-allocation encoder into a stack
buffer, consistent with the project's no-heap-allocation conventions
(§1/§5 of `AGENTS.md`), sized generously enough for a full title + prefilled
body but hard-capped (see Risks).

## Risks

- **URL length limits**: browsers and Codeberg/Gitea both cap query string
  length (commonly ~8KB browser-side, less is safer). The prefilled body must
  stay short and the body field should be truncated defensively before
  encoding, not just hope the user keeps it short.
- **No browser / no display**: SSH sessions, plain TTYs (`--tui` outside a
  graphical session) have no browser to open. Must degrade to the popup-URL
  fallback, not error out or hang.
- **Double text-input UX**: this is the first *multi-line* text field in the
  app (existing text input, e.g. the settings key-binding row, is single-line
  only). Scope the Body field's editing to what's actually needed (append,
  backspace, newline, maybe Home/End per line) rather than building a full
  text editor.
- **Percent-encoding correctness**: getting this wrong silently corrupts the
  prefilled issue (e.g. an unescaped `&` in the body truncates it at the query
  parser). Needs a unit test in `zig build test` with a title/body containing
  `&`, `=`, `#`, newlines, and non-ASCII (emoji in a bug report title is a
  realistic case).

## Acceptance criteria

- `:report` / `:r` opens a dedicated report screen; `Esc` cancels with no
  side effects.
- Submitting opens the default browser at the correct
  `codeberg.org/ubunatic/emojig/issues/new` URL with title/body correctly
  percent-encoded, verified by a unit test (encoding only — opening a real
  browser is out of scope for `zig build test`).
- No browser available → the fully-formed URL is shown in a popup instead of
  a silent failure or crash.
- New behavior values (opener candidate list, field labels/help text, any
  size caps) live in `spec/*.yaml`, not hardcoded in `src/main.zig`.
