<!--
SPDX-FileCopyrightText: 2026 Uwe Jugel
SPDX-License-Identifier: AGPL-3.0-or-later
-->

---
status: open
priority: high
created: 2026-08-04
---

# Issue #49: Native GUI Engine — Adopt foot/Ghostty Code & Architecture to Roll Our Own Windowing Layer

## Executive Summary

`emojig --gui` currently relies on spawning external host terminal emulators (`ptyxis`, `foot`, `ghostty`, `kitty`, etc.) via `spawnGuiWindow` in [`src/host.zig`](file:///home/uwe/projects/emojig/src/host.zig). While this dynamic launcher model provided rapid zero-dependency GUI support, it introduces host-dependent quirks:
- Font format mismatches (`foot` requiring CBDT bitmap fonts while modern distros package COLRv1 vector fonts like `Noto-COLRv1.ttf`).
- Lack of programmatic window positioning/geometry flags in GTK4/libadwaita terminals (`ptyxis`, `gnome-terminal`).
- Process spawning overhead and dependency on host terminals installed on `$PATH`.

This issue details the architectural blueprint for rolling **our own native Wayland/X11 GUI engine** embedded directly into `emojig`, combining:
1. **`foot`'s raw Linux/Wayland robustness and minimalism** (pure C/POSIX zero-dependency architecture, cell-precise character geometry sizing, lightweight CSD border framing, sub-millisecond startup).
2. **`Ghostty`'s modern Zig idioms and rendering patterns** (idiomatic Zig memory pools, C API bindings, hardware/software glyph rasterization, structured event loop).

---

## Architectural Comparison & Selected Highlights

### 1. Robustness & Layout Approach (Inspired by `foot`)
- **Direct Wayland Protocol Integration**: Communicate directly over `wayland-client` protocols (`xdg_wm_base`, `zwp_text_input_v3`).
- **Cell-Precise Character Window Sizing**: Implement `foot`'s `window-size-chars` algorithm: compute precise window surface dimensions as `width = cols * cell_width`, `height = rows * cell_height + csd_height`.
- **Zero-Dependency Lightweight CSD**: Adopt `foot`'s client-side decoration model (`csd.border-width`, `csd.border-color`). Frame the surface with 1px border lines and zero-height titlebar when floating without relying on heavy GTK runtime libraries.

```c
// Reference approach from foot (Codeberg: dnkl/foot / main.c & wayland.c)
// Exact character grid to surface size calculation:
uint32_t width = config->margin.x * 2 + cols * font->width;
uint32_t height = config->margin.y * 2 + rows * font->height + csd_header_height;
wl_surface_attach(wayland->surface, buffer, 0, 0);
xdg_surface_set_window_geometry(wayland->xdg_surface, 0, 0, width, height);
```

### 2. Modern Zig Patterns & Structural Idioms (Inspired by `Ghostty`)
- **Idiomatic Zig Memory Management**: Use arena allocators for frame allocation and thread-safe pool allocators for event dispatching.
- **Clean C Library Bindings**: Consume Wayland client headers via Zig's `@cImport` without boilerplate wrapper overhead.
- **Embedded Font & Glyph Rasterization**: Support both CBDT bitmap and COLRv1 vector color emoji fonts using standard FreeType / HarfBuzz bindings in Zig.

```zig
// Reference pattern from Ghostty (github.com/ghostty-org/ghostty / src/font/main.zig)
const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("ft2build.h");
    @cInclude(FT_FREETYPE_H);
});

pub const NativeGuiWindow = struct {
    display: *c.wl_display,
    surface: *c.wl_surface,
    xdg_surface: *c.xdg_surface,
    xdg_toplevel: *c.xdg_toplevel,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cols: u32, rows: u32) !NativeGuiWindow {
        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);
        // Initialize wayland surface & character grid sizing...
        return .{
            .display = display,
            .surface = undefined,
            .xdg_surface = undefined,
            .xdg_toplevel = undefined,
            .allocator = allocator,
        };
    }
};
```

---

## Sub-Task Research Backlog

To execute this architectural transition efficiently without blocking immediate work, the research and implementation must be broken down into discrete sub-tasks for subagents to research in parallel:

### Sub-Task 1: Wayland Native Protocol & Surface Sizing Research (`research/wayland-surface`)
- **Goal**: Survey `foot`'s `wayland.c` implementation for `xdg_toplevel` window sizing, buffer creation, and event loop handling in C/Zig.
- **Deliverable**: Draft minimal Wayland window creation prototype in Zig (`src/gui/wayland.zig`).

### Sub-Task 2: Vector (COLRv1) & Bitmap (CBDT) Font Rendering in Zig (`research/font-engine`)
- **Goal**: Analyze how Ghostty integrates FreeType/harfbuzz with Zig for rendering both COLRv1 vector emoji fonts (`Noto-COLRv1.ttf`) and CBDT bitmap fonts without fcft/foot limitations.
- **Deliverable**: Benchmark report and font loader interface (`src/gui/font.zig`).

### Sub-Task 3: Client-Side Window Decoration & Border Framing (`research/csd-framing`)
- **Goal**: Extract `foot`'s borderless 1px drop-shadow framing and CSD header rendering logic.
- **Deliverable**: CSD rendering pipeline specifications (`spec/gui_csd.yaml`).

### Sub-Task 4: Fallback Native X11 / xcb Engine (`research/x11-backend`)
- **Goal**: Research lightweight X11 fallback windowing for non-Wayland environments using `xcb`.
- **Deliverable**: X11 window backend specification (`src/gui/x11.zig`).

### Sub-Task 5: Conditional Build Options (`-Dgui=false` / `-Dgui=true`) (`research/build-options`)
- **Goal**: Research Zig build options (`b.option(bool, "gui", ...)`) to allow building headless / TUI-only binaries for server/headless environments without compiling native GUI dependencies or dynamic library links (`libwayland-client`, `libX11`, `libfreetype`).
- **Deliverable**: `build.zig` option contract and compile-time conditional imports (`@import("gui.zig")` vs dummy stub module) ensuring minimal binary size (< 600 KB for `-Dgui=false`).

---

## Action Items & Next Steps

1. [ ] Assign **Sub-Task 1** (`research/wayland-surface`) to a research subagent to produce a standalone `src/gui/wayland.zig` POC.
2. [ ] Assign **Sub-Task 2** (`research/font-engine`) to evaluate FreeType COLRv1 support in Zig.
3. [ ] Assign **Sub-Task 5** (`research/build-options`) to design Zig compile-time `-Dgui=false` feature flags.
4. [ ] Integrate native GUI window backend behind `--gui-native` flag once POC targets compile.
