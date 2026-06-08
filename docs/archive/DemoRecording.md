<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->
> [!CAUTION]
> **This document has been archived.**
> - **Replaced by:** None (Development reference)
> - **Extra Content Covered Here:** Precise setup instructions for `asciinema` recording, editing and converting `.cast` files into `.gif` using `agg` (asciinema gif generator) and window sizing tricks.
> - **Outdated Information:** Mention of specific v0.1.4 version tags.

---


# Demo Recording: Headless Webm Generation

> [!NOTE]
> **Currency Status:** Current as of June 7, 2026. Documents the headless
> recording pipeline introduced during the **v0.1.5+** development cycle, covering
> all lessons learned about font rendering, emoji sizing, window geometry, and
> TrueColor fade animations.

The automated recording pipeline (`go run scripts/record_demo.go` / `make record`)
produces two `.webm` files committed to `website/`:

| Output file | Theme | Terminal |
|---|---|---|
| `website/emojig-tui-dark.webm` | Dark | xterm (50×13, inline TUI) |
| `website/emojig-gui-light.webm` | Light | foot (GUI popup) |

---

## 1. Infrastructure Stack

| Component | Role |
|---|---|
| **Xvfb** | Virtual framebuffer X server — headless display `:99` at `1920×1080×24` |
| **Openbox** | Minimal window manager; maps windows to `0,0` (top-left) reliably |
| **xterm** | TUI recording host — lightweight, supports `-geometry`, `-fa`, `-bg`/`-fg` |
| **foot** | GUI recording host — Wayland terminal; launched inside Xvfb via XWayland |
| **ffmpeg** | Screen capture via `x11grab` → VP9 `.webm` |
| **xdotool** | Window ID discovery, focus, and synthetic key injection via XTest |

`runInDisplay()` in `scripts/record_demo.go` injects `DISPLAY=:99` into every
subprocess's environment so all tools share the same virtual screen.

---

## 2. Font & Emoji Rendering Lessons

### 2.1 The "tiny emoji / extra space" problem

**Symptom:** Emojis appeared too small inside xterm cells, with visible extra
padding spaces around them, producing a misaligned grid in the recorded video.

**Root cause:** xterm uses the system `monospace` FontConfig alias. When
`fonts-noto-color-emoji` is installed but `NotoColorEmoji.ttf` is *not* available
as an un-stripped system font, FontConfig falls back to DejaVu Sans Mono's
built-in U+FFFD glyph for emoji, which is monochrome, narrow, and incorrectly
sized. The Noto Color Emoji fallback also needs proper `scalable` priority so
xterm's Xft renderer matches the correct cell width.

**Fix applied:**

1. Install the official unstripped Noto Color Emoji font:
   ```
   ~/.local/share/fonts/NotoColorEmoji.ttf
   fc-cache -fv
   ```

2. Create a FontConfig rule that gives `monospace` the correct priority order —
   DejaVu Sans Mono as the primary metric font, NotoColorEmoji as emoji fallback:
   ```xml
   <!-- /etc/fonts/conf.d/99-emojig-noto.conf -->
   <alias>
     <family>monospace</family>
     <prefer>
       <family>DejaVu Sans Mono</family>
       <family>Noto Color Emoji</family>
     </prefer>
   </alias>
   ```

3. Verify with `fc-match monospace` — it must resolve to `DejaVuSansMono.ttf`
   (not `NotoColorEmoji`). Noto should appear only as a fallback.

### 2.2 Country flags and ZWJ sequences

**Symptom:** Typing `fire` as the demo query caused flag emojis (regional
indicators used in some name matches) to appear — these render as two-letter text
codes (`GB`, `DE`, etc.) in xterm, skewing column alignment.

**Fix:** Changed the demo query from `fire` to `cat`. Cat emojis are
straightforward single-codepoint glyphs with no rendering edge cases.

### 2.3 xterm vs. foot for TUI recording

xterm is used (not foot) for the TUI demo because:
- Its window class is trivially set via `-class` for `xdotool search --class`
- It accepts precise geometry in columns×rows at startup (`-geometry 50x13+0+0`)
- It is pixel-for-pixel consistent under Xvfb/Openbox
- foot requires Wayland, which adds XWayland overhead and complicates window management

---

## 3. Window Geometry & ffmpeg Capture

ffmpeg's `x11grab` captures a fixed pixel rectangle from the virtual display.
The recording area must exactly match the xterm/foot window geometry to avoid
black borders or clipping.

The pipeline uses `xdotool getwindowgeometry <winID>` to discover the rendered
pixel size of the window after it opens, then feeds those dimensions to ffmpeg:

```go
w, h, _ := getWindowGeometry(winID)
if w%2 != 0 { w++ }   // ffmpeg VP9 requires even dimensions
if h%2 != 0 { h++ }
// ffmpeg -video_size WxH -i :99.0+0,0 ...
```

**Important:** Openbox must be configured to place windows at `(0,0)` with no
window decorations and no title bar. This is done via a minimal `openbox-rc.xml`
written to `/tmp/openbox-rc.xml` before Openbox is launched. Without this,
windows appear at a random desktop offset and the capture misses them.

xterm is launched at `+0+0` in its `-geometry` flag to force top-left positioning.

---

## 4. TUI Scripted Interaction

After the xterm window is found and focused, `xdotool` injects keystrokes via
XTest (bypassing xterm's own focus model, which requires `allowSendEvents`):

```
xterm -xrm "xterm*allowSendEvents: true" ...
```

The recorded interaction sequence:
1. **Type `cat`** with 150 ms inter-key delay (gives emojig time to filter)
2. **Sleep 1 s** — lets the full grid render settle on screen
3. **Press `Right`** — moves selection to second emoji in row 1
4. **Sleep 1 s** — holds the selected state visible in the recording
5. **Press `Return`** — triggers copy + exit preview animation
6. **Wait for xterm to exit** — then send `SIGTERM` to ffmpeg

---

## 5. Exit Preview & TrueColor Fade Animation

### 5.1 Block-shading approach (legacy)

The original exit preview animation used Unicode block characters as a retro
dissolve effect:

| Step | Character | Density |
|---|---|---|
| 3 | `▓` | ~75% |
| 4 | `▒` | ~50% |
| 5 | `░` | ~25% |
| 6+ | ` ` | blank |

These are drawn into the border, search-bar, and status-bar rows using the
palette's `search_shade_fg` / `border_shade_fg` foreground sequences on top of
the plain `bg` background.

**Limitation:** The block characters produce a coarse, pixelated dithering look
in recorded video. They also depend on the terminal rendering Unicode block
elements at exactly the right cell width, which is not guaranteed across all fonts.

### 5.2 TrueColor fade approach (target)

The Go prototype in `scripts/fade_demo.go` demonstrates a smooth 24-bit RGB fade.
The key concept:

```go
t = float64(step) / float64(maxSteps)   // 0.0 → 1.0
currentColor = fromColor.Lerp(toColor, t)
// writes: "\x1b[48;2;R;G;Bm" (TrueColor background)
//         "\x1b[38;2;R;G;Bm" (TrueColor foreground)
```

Each palette colour is lerped towards the base background (`BG`) independently:
- `SearchBG → BG` (search bar / status bar background fades out)
- `SearchFG → BG` (search bar text fades to invisible)
- `SelBG → BG` (selection highlight fades)
- `BorderBG → BG` (border rows fade)
- Grid rows: non-selected cells blanked immediately; selected emoji stays until
  the final step

This produces a smooth, modern dissolve with no block artefacts.

**Terminal detection:** TrueColor support is detected via `COLORTERM`:
```zig
const is_truecolor = blk: {
    if (init.environ_map.get("COLORTERM")) |v| {
        if (std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit"))
            break :blk true;
    }
    break :blk false;
};
```

When `COLORTERM` is not set (e.g. over SSH or in a 256-colour-only terminal),
the code falls back to the block-shade animation for maximum compatibility.

**Palette RGB values** corresponding to the 256-colour indices used in normal rendering:

| Palette field | xterm-256 index (dark/light) | Approximate RGB (dark) | Approximate RGB (light) |
|---|---|---|---|
| `bg` | 234 / 255 | `#1c1c1c` | `#eeeeee` |
| `search_bg` | 238 / 251 | `#444444` | `#c6c6c6` |
| `border_bg` | 236 / 252 | `#303030` | `#d0d0d0` |
| `selection_bg` | 24 / 111 | `#005f87` | `#87afdf` |

These exact values are encoded as `RGB{}` literals in `scripts/fade_demo.go`,
serving as the single source of truth for the Go prototype.

### 5.3 Recording environment for TrueColor

For the fade animation to activate during recording, `COLORTERM=truecolor` must
be visible to the emojig process. The host environment already exports it
(verified: `echo $COLORTERM` → `truecolor`), so `os.Environ()` in the Go
recorder already propagates it. Making it explicit in `runInDisplay()` is
recommended for reproducibility:

```go
cmd.Env = append(os.Environ(), "DISPLAY="+display, "COLORTERM=truecolor")
```

---

## 6. Open Work

| Item | Status |
|---|---|
| Port RGB `lerp` + TrueColor BG/FG escape sequences to Zig (`src/main.zig`) | **Planned** |
| Detect `COLORTERM` in main init block; fall back to block-shade when absent | **Planned** |
| Re-record demo videos after TrueColor fade is live | **Planned** |
| Promote `ptyxis` in GUI host terminal auto-detection order | ✅ Done |
| Fix emoji sizing / extra spaces in xterm recording | ✅ Done |
| Change demo query from `fire` to `cat` | ✅ Done |
| Xvfb resolution increased to `1920×1080` | ✅ Done |
| Website simulator: import Noto Color Emoji web font, fix `width: 4ch` | ✅ Done |

---

## 7. Reproducing the Recording Locally

```bash
# Prerequisites
sudo apt install xvfb openbox xterm xdotool ffmpeg fonts-noto-color-emoji
# Plus NotoColorEmoji.ttf in ~/.local/share/fonts/ (see §2.1)

# Build + record
make record

# Outputs
ls -lh website/emojig-tui-dark.webm website/emojig-gui-light.webm
```

The recording runs non-interactively; no display connection on the host is
required. All activity occurs on the virtual display `:99`.
