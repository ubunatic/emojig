<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** [WhyAndNiche.md](file:///home/uwe/projects/emojig/docs/WhyAndNiche.md)
> - **Extra Content Covered Here:** The original Go-based terminal emoji picker architecture, design decisions, and database packing layout details.
> - **Outdated Information:** Describes the deprecated pure-Go version of the CLI.

---


# Mojigo — Go (TUI-only) port of Emojig

`mojigo` is a TUI-only reimplementation of the Emojig emoji picker in Go. Its
purpose is twofold:

1. Provide a maintainable, standard-library-only Go picker.
2. **Extract the UI spec and defaults into language-neutral declarative files**
   (`spec/*.json`) that both the Go port and a future Zig rewrite can consume,
   so layout/theme/keybindings live in data, not code.

See [`MojigoPortingNotes.md`](MojigoPortingNotes.md) for the porting methodology,
how to test a raw-mode TUI without a human, and the environment traps we hit.

## Run

```sh
go run ./cmd/mojigo      # interactive picker; prints the chosen emoji to stdout
go test ./internal/...   # search-parity unit tests (ported from src/root.zig)
```

Linux-only (raw mode via `syscall` ioctls `TCGETS`/`TCSETS`; no `golang.org/x/sys`).

## Layout

| Path                   | Responsibility                                              |
| ---------------------- | ---------------------------------------------------------- |
| `cmd/mojigo/`          | entrypoint: load specs + db, run the picker                |
| `assets.go` (root pkg) | `//go:embed` of `data/emoji.json` and `spec/*.json`        |
| `internal/spec/`       | typed loaders for the declarative spec JSON                |
| `internal/emoji/`      | emoji db load + fuzzy search (faithful port of `root.zig`) |
| `internal/term/`       | Linux raw mode, ANSI helpers, safe restore (signal/defer)  |
| `internal/tui/`        | alt-screen render loop + key decoding                      |

## Declarative spec (the Zig-reusable payload)

| File               | Extracted from   | Holds                                            |
| ------------------ | ---------------- | ------------------------------------------------ |
| `spec/layout.json`  | `src/defaults.zig` | grid dims (tui/gui), width, overhead, row order |
| `spec/theme.json`   | `src/term.zig`     | dark/light palettes as 256-color indices + hex  |
| `spec/keys.json`    | `src/main.zig`     | logical key name → action mapping               |
| `spec/strings.json` | `src/main.zig`     | search prompt, status bar, help screen text     |

Colors are stored as **semantic values** (xterm 256-color indices, hex for OSC)
rather than baked escape sequences, so any renderer emits its own escapes.

### What to edit where

| To change…                       | Edit                                              |
| -------------------------------- | ------------------------------------------------- |
| Default TUI / GUI grid size      | `spec/layout.json` → `tui.*` / `gui.*`            |
| Status bar text & nav hint       | `spec/strings.json` → `status_help_hint`, `status_matches` (`{count}` = live count) |
| Help screen lines                | `spec/strings.json` → `help_lines`                |
| Search prompt icon               | `spec/strings.json` → `search_prompt`             |
| Colors / theme icons             | `spec/theme.json`                                 |
| Key → action bindings            | `spec/keys.json`                                  |

The help screen opens when the query starts with `?` (mirrors `src/main.zig`).
Note: mojigo is TUI-only, so `gui.*` is carried for the future Zig port but not
yet read. Keep `strings.json` lines within `tui.width` or they are truncated.

## Parity

`internal/emoji` ports `matchTermDirect` / `matchTerm` (plural + stem fallbacks)
/ `fuzzyMatch` from `src/root.zig` byte-for-byte, and the `fuzzy_test.go` cases
are ported from the Zig `test` blocks. Search words are built from
`description + tags + aliases` exactly as `scripts/pack_emojis.go` does.

Result ordering mirrors the Zig algorithm and is identical *by construction*
— **provided `src/emojis.bin` was regenerated from the current `data/emoji.json`**
(`make pack` / `go run scripts/pack_emojis.go`). Tie-breaking among equal-score
matches depends on identical DB iteration order, so a stale `emojis.bin` would
diverge. The ported tests assert match/no-match and score > 0, not exact scores
against the Zig binary (which copies to clipboard, not stdout, so a direct
output diff is impractical).

## Scope of the first cut (minimal core)

Included: search, 6×4 grid, arrow navigation (with wrap), description + status
rows, help screen (`?`), theme toggle (dark/light), safe terminal restore, and
the Zig app's terminal-rendering safeguards (see below). All UI text is
data-driven via `spec/strings.json`.

Deferred (present in the Zig app, not yet ported): MRU ordering, clipboard copy,
mouse tracking, system-theme detection, exit-fade preview, border mode, GUI
(floating-window) mode, inline (non-alt-screen) rendering.

## Terminal rendering (emoji width & ZWJ)

Ported from `src/root.zig` to avoid misaligned/double glyphs:

- **ZWJ filtering** (`emoji.DisableZWJ`): compound emoji joined with U+200D (e.g.
  the firefighter 🧑‍🚒) render as two glyphs on terminals without ZWJ support, so
  they are dropped from results when `EMOJIG_DISABLE_ZWJ=1`, or automatically
  when `TILIX_ID`/`VTE_VERSION` is set (Tilix, GNOME Terminal, foot-with-VTE…).
  Explicit `EMOJIG_DISABLE_ZWJ=0` always wins. This is why match counts differ
  by terminal (e.g. "fire" → 180 unfiltered vs 151 under VTE), matching Zig.
- **Width-aware cells** (`emoji.Width`, port of `getEmojiWidth`): each grid cell
  is 4 columns; single-width glyphs get two trailing spaces, double-width get
  one, so rows stay aligned regardless of glyph width.

## Notes

- The root `go.mod` makes `scripts/*.go` look like one package to `go build ./...`;
  they remain standalone `go run scripts/<name>.go` files (as the Makefile uses)
  and are unaffected. Build/test mojigo via explicit paths: `go build ./cmd/mojigo`.
- Batched input (e.g. pasted `cat\r`) types the text and drops the trailing
  control byte — matching the Zig key handler, which only inspects `bytes[0]`.
- **Known limitation:** with `VMIN=1 VTIME=0`, a single `Read` returns a whole
  escape sequence on local terminals (verified: arrows decode correctly), but if
  an escape sequence is ever split across reads, a lone `ESC` is treated as quit.
  The Zig version does a 100 ms timed follow-up read (`main.zig:1545`) to stitch
  split sequences; porting that is a follow-up for non-local/slow ttys.
