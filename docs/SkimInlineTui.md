<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Inline TUI, the skim way

How [skim](file:///home/uwe/git/skim) draws a rock-solid, non-drifting, flicker-free
inline TUI under `--height`, and how we reproduce it. The runnable reference is the
Rust demo in [`src/main.rs`](../src/main.rs) (`cargo run --bin inline-demo`), which
renders through the same stack skim uses (`ratatui` + `crossterm`) rather than
re-implementing the escape sequences by hand.

> Earlier hand-rolled experiments (the Go `box_demo`, the relative-positioning
> harness, the Zig sketches and their writeups) are in [`archive/`](./archive/).
>
> These mechanics were ported into the Go `mojigo` picker as an opt-in
> `--height` mode — see [`MojigoInlineHeight.md`](./MojigoInlineHeight.md).

---

## The four things skim gets right

Implemented in skim's [backend.rs](file:///home/uwe/git/skim/src/tui/backend.rs)
(`new_with_height_and_backend`) and mirrored in our `enter`/`exit`:

1. **Query the cursor first.** Before drawing anything, read the cursor position
   via DSR (`\x1b[6n`). Reserving space *before* knowing where you are is the root
   of most inline-TUI drift.
2. **Scroll up only by the deficit.** If the viewport runs past the bottom of the
   screen, scroll by exactly `height - (term_height - cy) - 1` lines — no more.
   The initiating command stays visible; scrollback is not polluted.
3. **Pin a `Viewport::Fixed(Rect)`.** Every cell maps to an absolute screen
   coordinate. ratatui writes via `\x1b[row;colH`, never relative cursor-down — so
   a stray write or resize cannot make rows leak or drift.
4. **Clean teardown.** On exit, clear the fixed rect and park the cursor at its
   top-left (`area.x, area.y`). The shell prompt then overwrites the drawing area;
   the TUI disappears with no orphaned lines.

```rust
// skim's setup, condensed:
let cy = cursor_pos.1;                 // 1-based row from DSR
let mut y = cy - 1;
if term_height - cy < height {
    let to_scroll = height - (term_height - cy) - 1;
    execute!(stderr, ScrollUp(to_scroll))?;
    y = y.saturating_sub(to_scroll);
}
Viewport::Fixed(Rect::new(0, y, width, height))
```

UI goes to **stderr** so stdout stays free for the selection — the picker stays
pipe-composable (`inline-demo < items.txt > picked.txt`).

---

## Where we improve on skim: horizontal resize

skim pins the viewport to `cols - 1`, so its rows nearly fill the width. A
`Viewport::Fixed` width is **frozen at creation** — ratatui's autoresize only
re-sizes `Fullscreen`/`Inline` viewports, never `Fixed` (confirmed in
`ratatui-core`'s `terminal.rs`). So when the terminal is shrunk horizontally, the
frozen buffer is now wider than the screen and the emulator **soft-wraps** every
over-long line onto the next row — the layout breaks. (This is wrapping, not
"reflow": nothing re-lays-out to the new width.)

The demo sizes the box to its **content** instead — the widest item (measured with
`unicode-width` for correct emoji widths) plus the pointer and a small right pad,
floored at a usable minimum. The box then sits well inside the available width with
slack on the right, so an ordinary horizontal shrink leaves the terminal wider than
the box: nothing wraps, with **no resize handling at all**. It only wraps once the
terminal is squeezed below `box_width` itself — the deliberate floor.

See `content_width` and `enter` in [`src/main.rs`](../src/main.rs).
