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

## Sub-Task Research Status (Completed)

All 5 research sub-tasks have completed initial analysis:
- ✅ **Sub-Task 1 (Wayland Protocol & Surface)**: Prototype architecture in `src/gui/wayland.zig` using `xdg_toplevel` & `memfd_create` SHM double-buffering based on `foot`'s `window-size-chars` algorithm.
- ✅ **Sub-Task 2 (Font Engine)**: Font stack in `src/gui/font.zig` using FreeType + HarfBuzz + Fontconfig supporting both `COLRv1` vector emojis (`Noto-COLRv1.ttf`) and `CBDT` color bitmaps.
- ✅ **Sub-Task 3 (CSD & Border Framing)**: Spec structure defined in `spec/gui_csd.yaml` for 1px border framing, titlebar buttons, and drop shadows.
- ⏳ **Sub-Task 4 (X11 xcb Backend)**: Fallback `src/gui/x11.zig` for non-Wayland sessions.
- ✅ **Sub-Task 5 (Conditional Build Options)**: `-Dgui=false` / `-Dgui=true` option contract in `build.zig` & comptime lazy `@import("gui.zig")` dispatcher to guarantee headless binaries stay < 600 KB without GUI dynamic library dependencies (`libwayland-client`, `libfreetype`, `libxcb`).

---

## Consolidated Implementation Roadmap

### Phase 1: Build System & Comptime Modularization
1. Update [`build.zig`](file:///home/uwe/projects/emojig/build.zig) with `enable_gui` option (`-Dgui=true`/`-Dgui=false`) and conditional `linkSystemLibrary` calls for `wayland-client`, `freetype`, `harfbuzz`, `fontconfig`, `xcb`.
2. Add [`src/gui.zig`](file:///home/uwe/projects/emojig/src/gui.zig) dispatcher and [`src/gui/stub.zig`](file:///home/uwe/projects/emojig/src/gui/stub.zig) for zero-dependency headless builds (< 600 KB target).

### Phase 2: CSD Spec & Schema Integration
1. Create [`spec/gui_csd.yaml`](file:///home/uwe/projects/emojig/spec/gui_csd.yaml) and corresponding schema in `spec/.schema/gui_csd.schema.json`.
2. Update `scripts/gen_colors/main.go` and `make gen-spec` to embed `gui_csd.json` into `src/spec.zig`.

### Phase 3: Native Windowing & Font Engine Subsystem
1. Implement `src/gui/wayland.zig` (Wayland display, registry, `xdg_toplevel` surface, SHM double buffer).
2. Implement `src/gui/font.zig` (FreeType + HarfBuzz + Fontconfig loader for COLRv1 & CBDT).
3. Implement `src/gui/csd.zig` (1px frame & titlebar rendering).

### Phase 4: Main Loop & CLI Integration
1. Add `--gui-native` opt-in flag to [`src/cli.zig`](file:///home/uwe/projects/emojig/src/cli.zig) and [`src/main.zig`](file:///home/uwe/projects/emojig/src/main.zig).
2. Wire event loop (pointer clicks, key inputs, resize events) directly to `emojig`'s search & rendering loop.
3. Validate `make preflight`, `zig build test -Dgui=false`, and `zig build test -Dgui=true`.
