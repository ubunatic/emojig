<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The Box Demo: A Stable Inline TUI Harness

`scripts/inline_tui/box_demo/` is a self-contained diagnostic harness that
renders a fixed-height box directly beneath the shell prompt and keeps it
stable across redraws, terminal resizes, and scrolling — **without leaking
stray lines into the scrollback**.

This document covers only what the box demo *adds* over the general inline-TUI
playbook. The universal techniques — `/dev/tty` vs `stdout` separation, constant
height, cursor-down (`\x1b[B`) instead of newline, the `\r\x1b[2K` clear,
startup space reservation, raw-mode recovery — are already documented in
[PerfectInlineTui.md](./PerfectInlineTui.md) and
[InlineTuiGuide.md](./InlineTuiGuide.md). Read those first; this is the delta.

```
go run ./scripts/inline_tui/box_demo/      # q or Ctrl-C to quit
```

---

## 1. The overflow invariant (the spine of the whole thing)

Every inline-TUI scrollback leak has the same root cause. The box occupies
`boxHeight` rows starting at terminal row `startRow`. If its bottom edge falls
below the last visible row, *any* draw forces the emulator to scroll the
viewport up to make room — and that scroll pushes a line into scrollback that
never comes back.

```
overflow = startRow + boxHeight - 1 - rows

overflow <= 0   box fits below startRow      → safe, nothing scrolls
overflow >  0   box bottom past last row     → every draw scrolls → leaked line
```

The harness computes this on every frame (`stats.overflow()`) and prints it in
the top border as `ov`, so a recording or screenshot tells you the exact state
in effect when a stray line appeared. **This is observability, not the fix** —
the digest makes leaks *visible*; the techniques in §2–§4 are what prevent them.

The top border carries a compact digest of that state:

```
+- f12 wz3 sr18 80x24 bh10 ov+3 ABS ev:cpr ---------------+
   │   │   │    │     │    │    │   └ last event (init/cpr/rsz)
   │   │   │    │     │    │    └ ABS = absolute mode, REL = relative
   │   │   │    │     │    └ ov = startRow + bh-1 - rows (signed)
   │   │   │    │     └ bh = reserved box height
   │   │   │    └ cols x rows
   │   │   └ sr = startRow from CPR (0 = relative / not anchored)
   │   └ wz = SIGWINCH events seen
   └ f = redraw count
```

The legend rendered inside the box repeats this, so the harness is
self-documenting on screen.

---

## 1b. Two clamps that keep the box rigid

The `ov` metric above is about the *viewport*: where the box sits relative to
the bottom of the screen. Independently, the box must guarantee its **content
never grows the box**, on either axis — otherwise the footprint changes between
frames and the whole overflow calculation is built on a moving target. Two
clamps enforce this:

- **Horizontal — autowrap off (row overflow, not line wrap).** The harness sets
  `\x1b[?7l` (`wrapOff`) at startup. With autowrap disabled, a line longer than
  the terminal is *truncated at the right margin* instead of wrapping onto a new
  row. A wrapped line would silently add a row to the box's footprint and push
  its bottom past `rows`. On top of the terminal-level guard, every line the
  harness emits is explicitly sliced to the box's inner width (`line[:inner]`,
  and `borderWithLabel` truncates the digest), so the right border stays put
  even on terminals that handle `?7l` loosely.
- **Vertical — fixed body height (content never leaves the box).** The draw loop
  always emits exactly `boxHeight` rows: top border, `boxHeight-2` body rows,
  bottom border. The legend is drawn top-aligned and *clamped* to that body — if
  it has more lines than fit they are simply not drawn, and short legends are
  blank-filled. Content can never spill below the bottom border, so the box's
  vertical size is a constant, not a function of how much there is to show.

Together these turn the box into a rigid rectangle: fixed width, fixed height,
regardless of content. Only *then* does the single `ov` viewport invariant in
§1 fully describe leak risk.

---

## 2. Two positioning strategies, both kept

The predecessor harness (`scripts/inline_tui/main.go`) used purely **relative**
positioning: it never learns its absolute row, it just clamps the cursor with
`\x1b[B` and relies on the box sitting at the bottom of the viewport ("eat the
lines above" — see PerfectInlineTui.md §3 and §5). That is robust but cannot
re-anchor itself; it assumes the box owns the bottom of the screen.

The box demo keeps that relative path as a fallback and adds an **absolute**
path driven by CPR (Cursor Position Report):

| | Relative (`-r`, or CPR failed) | Absolute (default) |
|---|---|---|
| Anchor | none — `startRow == 0` | `startRow` learned via `\x1b[6n` |
| Move to top of box | `\x1b[{boxHeight-1}A\r` | `\x1b[{startRow};1H` |
| Clear canvas | `\x1b[J` from current row | `\x1b[{startRow};1H\x1b[J` |
| Survives scroll? | only if box stays at bottom | yes — re-anchors after scroll |

`startRow == 0` is the sentinel for "not anchored": every draw helper checks
`absolute && startRow > 0` and silently takes the relative branch otherwise, so
a CPR timeout degrades gracefully instead of positioning at row 0.

---

## 3. Learning `startRow` with `queryCursorRow` (drain, then query)

Absolute positioning needs to know which terminal row the box starts on. The
harness asks the terminal directly with the CPR sequence `\x1b[6n` and parses
the `\x1b[{row};{col}R` reply. Two details make this reliable:

1. **Drain first.** Before issuing the query, `queryCursorRow` switches the tty
   to `VMIN=0, VTIME=0` (fully non-blocking) and reads until empty. This
   discards any pending keystrokes so they cannot be mistaken for — or prepended
   to — the CPR reply.
2. **Bounded wait.** It then sets `VTIME=2` (200 ms) and does a single blocking
   read for the reply. If no terminal answers (pipe, dumb terminal, CI), the
   read times out, `queryCursorRow` returns `0`, and the harness falls back to
   relative mode. The original termios is always restored via `defer`.

This runs **synchronously at startup, before the input-reader goroutine is
started**, so there is exactly one reader of the tty during the handshake and no
race over who consumes the `\x1b[6n` reply.

---

## 4. Resize: clear relatively, debounce, then re-anchor

Resizing is where naïve absolute positioning breaks. When the terminal reflows,
the cached `startRow` is immediately stale — the content (and the box) may have
moved — so clearing at the *old* absolute row would erase the wrong region. The
harness handles `SIGWINCH` in three moves:

1. **Clear relatively, even in absolute mode.** On the SIGWINCH the box is
   cleared with `\x1b[J` from the current (reflowed) cursor position, never with
   the stale `\x1b[{startRow};1H`. See the comment at `main.go` in the
   `case <-sigChan` branch — this is the single most important line for resize
   correctness.
2. **Debounce.** Resizes arrive as a storm of signals while the user drags the
   window edge. Each SIGWINCH (re)starts a 350 ms timer (`-b`) instead of
   redrawing immediately, so the box is redrawn once after the drag settles.
3. **Re-anchor, then redraw.** When the debounce fires: in absolute mode it
   writes a fresh `\x1b[6n`; the reader goroutine parses the reply, sends the
   new row on `cprChan`, and *that* triggers the redraw with a correct
   `startRow`. In relative mode there is no CPR round-trip, so it redraws
   directly (otherwise the box would stay cleared and vanish).

**skim-style repaint (`-resize=false`).** The §4 debounce+re-anchor machinery is
gated behind `-resize`, so `-resize=false` selects the simpler skim path: on
every SIGWINCH it just calls `redraw` immediately — no relative clear, no
debounce, no CPR. Because `drawBox` already self-clears from its anchor
(`\x1b[J`), the box is repainted in place and is **never eaten**.

An earlier version made `-resize=false` a pure *no-op* (count the SIGWINCH, do
nothing else) to test whether ignoring resize was viable. It is not: with no
repaint, a terminal scroll moves the box and nothing ever puts it back, so it
eats its own rows. The screencast (§8) showed the fix — skim does **not** ignore
resize, it *always repaints* and simply does not reflow. `-resize=false` now
matches that. The trade-off vs `-resize=true`: it does not chase a vertical
scroll via CPR, so on a vertical shrink the prior copy may scroll into the host
scrollbar (again, exactly like skim). Pair it with `-r` for a fully relative
repaint.

The event loop is a single `select` over: quit (`q`/Ctrl-C), an optional
auto-exit deadline (`-d`), SIGWINCH, the debounce timer, and `cprChan`. CPR
replies and quit keys are demultiplexed by the one reader goroutine.

---

## 5. Verifying inline behaviour: setup/teardown demo content

With `-D` (on by default) the harness prints a few marker lines to **stdout**
(not `/dev/tty`) immediately before entering raw mode, and again immediately
after the terminal is restored:

- **Setup** lines are printed before any space reservation or raw mode, so they
  must end up in the scrollback *above* the box — proving the box does not
  clobber prior output.
- **Teardown** lines are printed after restore (registered as a `defer` *before*
  the restore `defer`, so LIFO runs it last), so they must resume exactly where
  the box was, with nothing left behind.

Because these go to stdout, running under a pipe (`go run … | cat`) sends them
to the pipe while the box still renders on `/dev/tty` — a live check that the
stream separation actually holds.

---

## 6. Small / degenerate terminals

If the terminal is narrower than `-c` columns (default 40) or shorter than `-m`
rows (default `boxHeight + 2`), the harness draws a centered "Terminal size too
small" hint instead of the box. Borders clamp to a minimum width, and
`borderWithLabel` truncates the digest label so the right edge never drifts or
wraps. The legend is asserted ASCII-only in the tests, because lines are padded
by byte length — a stray multi-byte rune would misalign the right border.

---

## 7. Flags

The flags map directly onto the techniques above, so the table doubles as a
feature summary.

| Flag | Default | Purpose |
|---|---|---|
| `-H` | `10` | Reserved box height in rows (clamped to ≥ 3). |
| `-r` | `false` | Force relative positioning — skip the CPR/absolute path (§2). |
| `-resize` | `true` | SIGWINCH strategy. `true` = clear + debounce + CPR re-anchor (reflows to new width, §4). `false` = skim-style: repaint the box immediately, no debounce/re-anchor (§4, §8). |
| `-b` | `350ms` | Resize debounce before redraw (§4). |
| `-c` | `40` | Minimum columns before the "too small" hint (§6). |
| `-m` | `0` | Minimum rows before "too small"; `0` means `boxHeight + 2`. |
| `-overflow` | `hint` | Small-terminal strategy: `hint` (centered message, §6) or `full` (skim-style: always draw the full box, let the host scrollbar absorb the overflow, §8). |
| `-d` | `0` | Auto-exit after this duration (e.g. `2s`) for headless/recorded runs; `0` runs until `q`/Ctrl-C. |
| `-D` | `true` | Print setup/teardown demo content to stdout (§5). |

---

## 8. Prior art, tested on this machine

The fixed-height-region pattern is well established; comparing implementations
is the fastest way to see which guarantees are hard.

| Tool | No-leak | Scrollbar / mouse | Resize | Notes |
|---|---|---|---|---|
| **skim** (`sk --height`) | **yes, never leaks** | **yes** | redraws, no reflow | The cleanest inline behaviour observed — never leaks a row, adds a scrollbar with mouse support, and **does not eat its own rows on vertical resize**: it always repaints all rows and lets the host scrollbar absorb overflow rather than reflowing (see screencast analysis below). |
| fzf (`fzf --height`) | leaks rows | partial | yes | Leaves stray rows under some conditions (e.g. `--height 10` near the bottom). Writes UI to stderr. |
| gum / peco / fzy | varies | varies | varies | Minimal inline widgets; return selection on stdout. |
| Ratatui `Viewport::Inline` | — | — | fragile | Reserves height by appending lines (same move as §3); does not re-anchor on scroll. |
| Bubble Tea inline | — | — | fragile | Maintainers note inline is for short-lived programs, not resize-heavy ones. |

The takeaway that shaped this harness: **no-leak and resize-survival are
separable guarantees, but neither comes from doing nothing.** An early no-op
version of `-resize=false` (count the SIGWINCH, never repaint) ate its own rows
on a vertical shrink — so skim's stability is not "it ignores resize." `-resize`
now selects between two *working* strategies (skim-style repaint vs. clear +
re-anchor); see §4.

### What a screencast of `sk --height 5` actually shows

(Recorded on Tilix, 2026-06-09, running `sk --height 5`.) Shrinking the window
vertically below skim's row count produces three observable facts:

1. **skim always repaints its full, fixed row set on resize** — it never drops
   into a reduced or "too small" mode. Every frame has all of: prompt, results,
   query, count, input.
2. **It does not reflow.** The layout/row count stays put; it does not try to
   fit a smaller window. This is the sense in which skim "does not support
   resize" — and why, when the rows no longer fit, they overflow the viewport.
3. **The terminal's own scrollbar absorbs the overflow.** Tilix paints a
   scrollbar; the top rows scroll *out of view* but are not destroyed —
   dragging the scrollbar reveals them, and growing the window back restores
   the full TUI intact. The rows are scrolled out, **not committed to permanent
   scroll history**.

So skim's robustness recipe is: *always redraw the full row set from a stable
anchor, never reflow, and let the terminal scrollbar handle the case where the
window is simply too small.* It is closer to box_demo's §4 (redraw on resize)
than to the no-op — the key difference is that skim has **no "too small" hidden
mode** (cf. box_demo's §6 `drawTooSmall`); it just keeps drawing and trusts the
scrollbar.

### Mechanism: observed vs. inferred

The screencast proves the *behaviour* above but **not** the escape sequences
behind it. Two candidates:

- **Always-redraw from a fixed anchor** (no special region) — consistent with
  the rows appearing in the scrollbar/viewport-above area, since that is where
  normal overflow goes.
- **Scroll region (DECSTBM, `\x1b[{top};{bottom}r`)**, the classic `--height`
  technique used by fzf — but a *strict* bottom region would keep the rows out
  of the scrollbar entirely, which is in tension with the "drag the scrollbar
  to see them" observation. So if skim uses DECSTBM at all, it is not the simple
  bottom-reserved form.

Confirming which means reading the skim / `tuikit` source; the maintainers do
not document it. *(Earlier drafts of this doc asserted DECSTBM as fact — the
screencast walked that back to "behaviour confirmed, mechanism inferred.")*

### Strategies, in rising order of work

1. **Always-repaint, no reflow, lean on the scrollbar (skim)** — robust and
   simple *if* you accept a fixed layout and let an over-small window overflow.
   This is `-resize=false` (best paired with `-r`).
2. **Clear + re-anchor (box_demo §4)** — react to SIGWINCH, re-query position,
   redraw; more code, but the box reflows to the new width and has an explicit
   "too small" mode instead of relying on the scrollbar. This is the default
   (`-resize=true`).
3. **No-op (ignore resize entirely)** — does **not** work; with no repaint a
   scroll eats the rows. This was an earlier `-resize=false` and is rejected;
   it is recorded only as the cautionary baseline.

### Reproducing skim's behaviour: `-overflow=full`

This experiment is wired up. `-overflow=full` makes `redraw` skip the
`drawTooSmall` fallback (§6) entirely and *always* paint the whole box, exactly
like skim — when the box no longer fits, the rows simply overflow and the host
terminal's scrollbar is left to absorb them.

```sh
go run ./scripts/inline_tui/box_demo/ -overflow=full        # skim-style overflow
go run ./scripts/inline_tui/box_demo/                        # default: "too small" hint
```

The open question this is meant to answer: does the host scrollbar absorb the
overflow as cleanly as it does for skim, or does box_demo's cursor-down (`\x1b[B`)
clamping — which pins the cursor at the bottom margin instead of scrolling —
pile the spilled rows onto the last visible line? skim's rows can scroll *above*
the viewport (revealable via the scrollbar); box_demo's no-scroll discipline
(PerfectInlineTui.md §3) may instead clamp them. If so, faithfully matching skim
means letting the bottom rows scroll (line-feed, not CUD) in this mode — which
is the next thing to try. Watch the `ov` digest while shrinking: `ov > 0` is the
exact regime where the two behaviours diverge.

For the closest head-to-head with skim, combine `-overflow=full` with `-r`
(relative anchor) and toggle `-resize` to compare repaint-on-resize against the
static case.

---

## 9. What the tests cover

`main_test.go` pins the parts that are pure and alignment-critical:

- `TestStatsOverflow` — the overflow arithmetic of §1 across fits / exact-fit /
  past-bottom / relative cases.
- `TestStatsDigestMode` — `ABS` only when absolute *and* anchored
  (`startRow > 0`); signed overflow renders as `ov+3`.
- `TestBorderWithLabel` — border width is always `inner + 2`, corners present,
  no line breaks, label truncated to fit.
- `TestLegendIsAsciiAndFits` — guards against non-ASCII creeping into the
  byte-padded legend.

The terminal I/O itself (raw mode, CPR, `ioctl`) is not unit-tested — it needs a
real tty (see [GoScripts.md](./GoScripts.md) coverage notes) and is exercised by
eye via recordings, which is exactly what the on-screen digest is for.
