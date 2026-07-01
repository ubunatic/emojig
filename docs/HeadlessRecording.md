<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# Headless Demo Recording

How emojig's demo videos are produced fully headlessly via `make record`
(`go run ./scripts/record/`). No physical display, GPU, or login session is
required — everything runs on a virtual X server.

The recorder produces two `.webm` files committed under `website/`:

| Output | Theme | What it shows | Capture host |
|---|---|---|---|
| `website/emojig-tui-dark.webm` | dark | inline TUI: type a query, arrow-select, Enter | `xterm` on Xvfb |
| `website/emojig-gui-light.webm` | light | **desktop scenario**: gedit + emojig picker popup + paste | nested `sway` on Xvfb |

Source: `scripts/record/main.go` (orchestration + TUI demo) and
`scripts/record/scenario.go` (the GUI desktop scenario).

---

## 1. Two different capture stacks, and why

The TUI demo and the GUI scenario use **deliberately different** stacks. This is
the single most important thing to understand before changing the recorder.

### TUI demo — plain X11

`xterm` is an ordinary X11 client that draws into the X framebuffer. So:

- input is injected with **`xdotool`** (XTest),
- the screen is grabbed with **`ffmpeg -f x11grab`**,
- the window is found by `--class` and sized via `xdotool getwindowgeometry`.

This is simple and reliable for a single terminal window.

### GUI scenario — nested Wayland (sway)

The GUI story needs a *desktop* with a real app (gedit), a floating popup
(foot), focus management, and a working clipboard. That pushes us to a Wayland
compositor running **nested as an X11 client** on the same Xvfb display:

```
Xvfb :99 ──(openbox forces window to 0,0)── sway (WLR_BACKENDS=x11)
                                              ├─ gedit        (Wayland client)
                                              ├─ foot popup   (Wayland client, emojig --gui)
                                              └─ desktop bg #1f2d3d
```

Why sway specifically:

- **wlroots** ⇒ emojig's first-choice clipboard path (`wl-copy`) works. weston
  was rejected because it lacks the data-control protocol, breaking `wl-copy`.
- **`swaymsg`** gives deterministic window focus, floating, sizing, and even
  synthetic pointer events — none of which a bare X11 setup offers.
- **foot** is Wayland-only and already supported by emojig
  (`EMOJIG_TERMINAL=foot`, window `--app-id=emojig-picker`).

The whole `1100×680` sway output **is** the cropped desktop frame — there is no
separate crop step.

---

## 2. The scenario, step by step

`recordScenarioDemo(binaryPath, query)` in `scenario.go`:

1. Start nested `sway` (x11 backend) — solid `#1f2d3d` desktop, no bar.
2. Launch `gedit` (light theme) floating; pre-type `"Let's go "`.
3. Start `wf-recorder` capturing the sway output.
4. Launch `emojig --gui` with `EMOJIG_TERMINAL=foot`; the picker opens centered.
5. Type the query, press Return → emojig copies the emoji to the Wayland
   clipboard via `wl-copy`.
6. Mirror clipboard → PRIMARY, then synthesize a **middle-click** in gedit → the
   emoji pastes (`"Let's go 🔥"`).
7. SIGINT `wf-recorder` to finalize the webm.

The query defaults to `fire` and is overridable via `EMOJIG_DEMO_QUERY` or the
first CLI arg (`go run ./scripts/record/ heart`).

---

## 3. Headless gotchas (hard-won — do not relearn these)

These are the traps that cost the most time. Every one is load-bearing.

### `ffmpeg x11grab` records a BLACK frame for the sway window

sway's x11 backend presents frames via **DRI3/Present**, which is invisible to
`XGetImage` — `x11grab` captures only the X root framebuffer plus the mouse
cursor, so the sway window reads as solid black.

**Fix:** record the sway scene with **`wf-recorder`** (uses `wlr-screencopy`,
the same path as `grim`):

```sh
wf-recorder -o X11-1 -c libvpx-vp9 -f out.webm   # stop with SIGINT
```

`x11grab` is still correct for the plain-`xterm` TUI demo.

### `wtype` modifier combos do NOT work under sway

`wtype` types plain text fine, but **Ctrl+V, Ctrl+A, Shift+Insert are all
no-ops** under nested sway. The intended "select emoji → Ctrl+V into gedit"
cannot use a keyboard paste.

**Fix:** paste via the PRIMARY selection + a synthetic middle-click:

```sh
wl-paste -n | wl-copy --primary          # mirror clipboard -> primary
swaymsg 'seat - cursor set 300 97'       # point at gedit line 1, past the text
swaymsg 'seat - cursor press button2'    # middle-click pastes PRIMARY
swaymsg 'seat - cursor release button2'  # GTK clamps the caret to the line end
```

`ydotool` would give a real Ctrl+V but needs root access to `/dev/uinput`
(root-only here), which also breaks the "reproducible, no privileges" property —
so middle-click is the chosen path.

### No GPU ⇒ force software rendering

```sh
WLR_BACKENDS=x11 WLR_X11_OUTPUTS=1 \
WLR_RENDERER=pixman WLR_RENDERER_ALLOW_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1 sway ...
```

### sway config: omit the `bar` block

`bar { mode invisible }` makes sway print `Error(s) loading config!`. Leaving out
the `bar` block entirely yields no bar with no error.

### emojig popup is flagged "Too small"

At its native 43-column request the foot popup renders emojig's "Too small"
state in this environment (font metrics + padding). Force a larger floating size:

```
for_window [app_id="emojig-picker"] floating enable, resize set 560 320, move position center
```

### A too-small `emojig-picker` window can misplace the cursor without ever showing "Too small"

A related but sneakier failure: the wayreel-based `spec/reels/gui.json` scenario
(the `apps.emojig` sub-app inside a two-window `gedit` + `emojig-picker` reel)
showed a **persistently misplaced hardware cursor** — sitting one row above the
search bar the whole time, not just a blink glitch — even though the picker
never showed its own "Too small" banner.

Root cause: until 2026-07-01, wayreel's `AppConfig` for secondary `apps{}`
entries had **no `app_width`/`app_height` override at all** — every sub-app
window was forced to a hardcoded `450x340` regardless of what character grid
(`--window-size-chars`) the launched terminal actually requested. If that fixed
pixel size doesn't fit the grid the app assumes it has (cols/rows/font_size),
the terminal ends up with fewer real rows than emojig's cursor-reposition math
expects, and the cursor lands on the wrong row for the entire session — with no
visible "Too small" warning, since that check only looks at *width*.

Fixed upstream in wayreel (`reelang/types.go`, `scenario.go`, `play.go`): `apps{}`
entries now accept their own `"app_width"`/`"app_height"`, same as the
top-level app. `spec/reels/gui.json`'s `apps.emojig` block sets
`"app_width": 420, "app_height": 400` to comfortably fit its 9×8 grid at
`EMOJIG_GUI_FONT_SIZE=14` — verified cursor-correct across multiple
recordings. See `../wayreel/issues/01-gui-window-scaling.md` for the full
diagnosis (this is the same underlying limitation that issue already flagged
for the top-level app; secondary `apps{}` windows just had no override
mechanism yet).

**Follow-up (2026-07-01):** giving wayreel an explicit per-app size only works
around the symptom — under this sandbox's nested-sway/x11-backend, even
*omitting* a forced size (so the compositor should honor the client's own
`--window-size-chars` request) still produced an undersized window in
practice. That pushed the real fix to emojig itself: see
[`docs/Advanced.md` §Height guard](Advanced.md#height-guard-terminal-shorter-than-expected)
for `--height-guard=off|strict|fit` (default `fit`), which shrinks the grid to
whatever the terminal actually has instead of assuming the requested size was
honored, plus absolute-addressed cursor positioning in alt-screen mode. This
is the more durable fix — it protects against *any* GUI host/compositor that
under-sizes the window, not just this recording sandbox. The wayreel
`app_width`/`app_height` override above is still useful to avoid the *cosmetic*
extra-column padding (see `issues/41-width-fit-and-cosmetic-recorder-gap.md`
for that separate, lower-priority follow-up).

### Wayland runtime plumbing

sway needs `XDG_RUNTIME_DIR` (a `0700` dir). It creates the socket at
`$XDG_RUNTIME_DIR/wayland-N` and the IPC socket at `sway-ipc.*.sock`. Every
Wayland-side command must share `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, and
`SWAYSOCK` — `scenario.go` threads these through one `waylandEnv` helper.

### Process cleanup must be PID-scoped, never `pkill -f`

`pkill -f gedit`/`foot` matches across the **entire user session** and would kill
the developer's real editor on every `make record`. Each scenario child is
started with `Setpgid: true` and torn down by **process-group PID** via a
`defer`. Killing sway drops the Wayland display, so any daemonized `wl-copy` and
`foot` that escaped their group exit on disconnect — no name matching needed.

---

## 4. Verifying a recording

Decode a single frame to confirm the capture is real (not black) and contains
what you expect:

```sh
ffmpeg -sseof -1 -i out.webm -frames:v 1 frame.png   # last frame
ffmpeg -ss 4.5 -i out.webm -frames:v 1 mid.png        # mid-recording (popup open)
```

For the GUI scenario the mid frame should show the picker grid; the final frame
should show `"Let's go 🔥"` pasted into gedit.

---

## 5. Reproducing locally

```sh
sudo apt install xvfb openbox xterm xdotool ffmpeg gedit \
                 sway wtype grim wf-recorder \
                 fonts-noto-color-emoji
# plus NotoColorEmoji.ttf in ~/.local/share/fonts/ for correct emoji metrics

make record
ls -lh website/emojig-tui-dark.webm website/emojig-gui-light.webm
```

The run is non-interactive; all activity occurs on the virtual display `:99`.

---

## 6. Extending the scenario

- **Change the query:** `EMOJIG_DEMO_QUERY=heart make record`. Note that broad
  queries (e.g. `fire`) surface many country-flag results via synonym matching;
  the intended emoji is still selected first, but the grid behind it is busy.
- **Change the desktop color / window layout:** edit the sway config string and
  the `for_window` rules in `recordScenarioDemo`.
- **Add a second paste / longer story:** repeat steps 4–6; keep the
  PID-scoped cleanup defers for any new child process.
- **Different editor:** swap `gedit` for another GTK app; update the
  `app_id` used in `swaymsg` focus criteria and the middle-click coordinates.

See also `issues/14-gui-desktop-scenario-recording.md` for the original
problem/decision record, and `docs/archive/DemoRecording.md` for the historical
x11grab-only pipeline.
