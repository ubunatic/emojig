# GUI Desktop Scenario Recording

## Problem

The old GUI demo (`recordGUIDemo` in `scripts/record/main.go`) captured the
emojig picker as an isolated `xterm` window with no surrounding context. It did
not show the actual user story: a desktop, a real application receiving focus,
and the emoji being **pasted** into that application after selection.

We wanted a richer recording: a single-color desktop hosting a GUI text editor
(gedit), the user opening `emojig --gui`, searching a query, selecting an emoji,
and pasting it back into the editor — all in one captured `.webm`.

## Solution

`scripts/record/scenario.go` (`recordScenarioDemo`) replaces the old GUI demo.
It runs a **nested sway compositor** as an X11 client on the existing Xvfb
display, hosts gedit + the emojig foot popup inside it, drives them, and records
the sway output to `website/emojig-gui-light.webm`.

Flow:

1. Start nested `sway` (x11 backend) on `:99` — solid `#1f2d3d` desktop, no bar.
2. Launch `gedit` (light theme) floating, pre-type `"Let's go "`.
3. Start `wf-recorder` capturing the sway output.
4. Launch `emojig --gui` with `EMOJIG_TERMINAL=foot`; the picker opens centered.
5. Type the query (default `fire`, override via `EMOJIG_DEMO_QUERY` or argv[1]),
   press Return — emojig copies the emoji to the Wayland clipboard via `wl-copy`.
6. Mirror clipboard → PRIMARY, middle-click in gedit → emoji pastes
   (`"Let's go 🔥"`).
7. SIGINT `wf-recorder` to finalize the webm.

The whole 1100×680 sway output **is** the cropped desktop frame.

## Why these specific tools (hard-won, headless gotchas)

| Decision | Reason |
|---|---|
| **sway** (not weston) | wlroots ⇒ emojig's first-choice `wl-copy` clipboard path works, and `swaymsg` gives deterministic window focus/placement. weston lacks the data-control protocol. |
| **foot** popup | Wayland-native, polished; emojig already supports `EMOJIG_TERMINAL=foot` (`--app-id=emojig-picker`). |
| **wf-recorder** (not `ffmpeg x11grab`) | sway's x11 backend presents via DRI3/Present, which is **invisible to `XGetImage`** — `x11grab` records an all-black frame (only the mouse cursor shows). `wf-recorder` uses `wlr-screencopy` (same path as `grim`) and captures the real output. `x11grab` is still fine for the plain-xterm TUI demo. |
| **wtype** for typing | virtual-keyboard protocol; no root needed (`/dev/uinput` is root-only, so `ydotool` is out). |
| **middle-click PRIMARY** for paste | `wtype` **modifier combos do not work** under nested sway (Ctrl+V, Ctrl+A, Shift+Insert are all no-ops; plain text typing works). Mirroring clipboard→PRIMARY and synthesizing a middle-click (`swaymsg 'seat - cursor …'`) is reliable and root-free. |

Other notes:

- No GPU in CI/headless ⇒ sway needs
  `WLR_RENDERER=pixman WLR_RENDERER_ALLOW_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1`.
- `bar { mode invisible }` makes sway print `Error(s) loading config!` — omit the
  `bar` block entirely for no bar.
- emojig's foot popup is flagged **"Too small"** at its native 43-col request in
  this environment; force `for_window [app_id="emojig-picker"] resize set 560 320`.
- Verify a recorded webm by decoding a frame:
  `ffmpeg -sseof -1 -i out.webm -frames:v 1 frame.png`.

## Dependencies

`sway`, `wtype`, `grim` (apt), plus the existing `Xvfb openbox xterm xdotool
ffmpeg gedit wf-recorder fonts-noto-color-emoji`.

## Status

Implemented and verified end-to-end via `make record`: the produced
`website/emojig-gui-light.webm` (VP9, 1100×680) shows `"Let's go 🔥"` pasted into
gedit on the teal desktop.
