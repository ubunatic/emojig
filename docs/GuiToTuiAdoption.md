# Emojig: Adopting GUI Design Paradigms in a TUI

This document analyzes the design ideas presented in the GUI mockup `emojig-idea-001.png` and proposes a concrete implementation plan for adopting these enhancements into the Emojig terminal user interface (TUI). It addresses the technical constraints of terminal environments—specifically, the unpredictability of double-width emoji rendering and the resulting necessity of borderless layouts.

---

## 1. Visual Comparison: GUI vs. Current TUI

| Feature | GUI Mockup (`emojig-idea-001.png`) | Current TUI Implementation (as of June 2026) | Proposed TUI Adoption |
| :--- | :--- | :--- | :--- |
| **Grid Dimensions** | 8 columns × 4 rows (32 emojis) | 6 columns × 4 rows (24 emojis) | Configurable 8×4 or 6×4 grid based on terminal width |
| **Borders & Separators** | Rounded window frame, solid divider lines | Borderless spacing (or solid background rows) | Background-colored spacer rows; no text-based borders |
| **Status Bar / Footer** | Multi-column informational status bar | None (only a simple description row for active selection) | Dedicated background-colored status row |
| **Theme Cycling** | Keyboard-driven (`Tab: theme`) | Mouse click on search-bar toggle (`🔆`/`🌙` icon) | Dual support: interactive `Tab` key and mouse toggle |
| **Match Counter** | Displays total count on the left (`1870`) | Omitted (only grid displays matching set) | Dynamic counter in footer (`[1870]` or `1870 matches`) |

---

## 2. Core Rendering Constraints in the Terminal

### The Emoji Width Problem
Under the Unicode standard, emojis often occupy two columns (double-width). However, terminal emulators differ widely in their support for character width databases (`wcwidth`). When terminals use outdated Unicode tables or fail to process zero-width markers like Variation Selector-16 (`U+FE0F`), they miscalculate the text cursor positions:
* **The Border Collision**: If box-drawing borders (such as `│`, `┌`, `─`) are used to frame the interface or divide columns, any rendering width mismatch in an emoji shifts all subsequent characters on that row. This results in misaligned borders, broken frames, and terminal screen corruption.
* **The Solution**: Emojig uses a **borderless 2D grid** layout. Drawing emojis directly on grid rows separated by single spaces ensures that even if a terminal misinterprets an emoji's width, the layout remains legible and does not corrupt the surrounding grid.

### Clean Viewport Overwrites
Emojig operates in the standard screen buffer to preserve shell scrollback history. It performs in-place overwrites using ANSI escape sequences (`\x1b[{d}A\r` to move up and `\x1b[2K` to clear lines). Adding new visual elements must not increase vertical jitter or disrupt clean viewport teardown on exit.

---

## 3. Detailed Adoption Specifications

### A. Background-Colored Status/Footer Bar (No Box Characters)
Instead of box-drawing characters, Emojig can create visual compartments using full-width background color bands. This matches the structural segments of the GUI mockup without risking alignment skewing.

* **Layout Structure**:
  * **Search Row**: Styled with `palette.search_bg`.
  * **Grid Area**: Spaced rows styled with `palette.bg`.
  * **Footer Row**: Styled with a distinct `palette.border_bg` or `palette.search_bg` to frame the bottom of the interface.
* **Footer Content Layout**:
  ```
   1870  │  ↑↓←→ Navigate  │  Tab: Theme  │  ^C Cancel
  ```
  To remain safe against width calculations, separators between fields in the footer can be simple spaces or a background color transition, rather than solid characters.

### B. Keyboard-Driven Theme Switching (`Tab`)
The GUI mockup identifies `Tab` as the shortcut for theme switching. Adding this to the TUI greatly improves ergonomics for keyboard-centric workflows.

* **Current State**: Changing the theme in the active TUI requires clicking the sun/moon icon at the right of the search bar.
* **Proposed State**:
  * The interactive main loop in `src/main.zig` captures key presses.
  * Pressing `Tab` (ASCII `9`) cycles the active palette (`dark` $\leftrightarrow$ `light`).
  * On theme change, the application recalculates all colors and triggers a full screen redraw.
  * This is achieved with zero heap allocations by referencing statically defined theme configurations.

### C. Active Match Counter
Knowing the scope of a query is an important usability feature of the GUI mockup.
* **Proposed State**:
  * The fuzzy search engine inside `src/root.zig` scores and filters all database items.
  * The total number of matching items is counted during the query pass.
  * This integer (e.g., `1870`) is formatted into the left section of the footer row during the render pass.
  * When the query is empty, it displays the total database size (e.g., `1870`).

### D. Grid Expansion (8×4 Layout)
The GUI utilizes an 8-column layout, which displays 32 options compared to the TUI's 24.
* **Proposed State**:
  * Increase grid dimensions from 6×4 to 8×4 by updating the layout constants in `src/main.zig`.
  * The row width expands from 24 columns to approximately 32 columns. This is narrow enough to fit comfortably in all standard terminals (typically 80+ columns wide) and remains perfectly stable.

---

## 4. Architectural & Implementation Plan

### Code Modifications

#### 1. Constants and Grid Configuration (`src/main.zig` or `src/root.zig`)
Update grid parameters to accommodate the larger 8×4 grid:
```zig
pub const GRID_COLS = 8;
pub const GRID_ROWS = 4;
pub const GRID_SIZE = GRID_COLS * GRID_ROWS;
```

#### 2. Keyboard Event Processing (`src/main.zig`)
Extend the input parsing switch block to capture `Tab`:
```zig
switch (char) {
    // Escape / Ctrl+C handles exit
    3 => return CleanExit.Cancel,
    // Tab key (ASCII 9) cycles theme
    9 => {
        state.cycleTheme();
        try state.redraw();
    },
    // Arrow keys and characters handle navigation and queries
    ...
}
```

#### 3. Viewport Calculation and Spacing
To ensure clean overwrites and restores, the height offset (`row_off`) must be dynamically computed if the status bar is toggled.
* The application viewport height will increase by exactly 1 row (the footer row).
* The viewport clearing loop in the teardown phase (`\x1b[2K\x1b[B\r`) must be incremented to clean up the additional footer row upon program exit.

---

## 5. Visual Representation of the Adopted TUI

With these changes, the TUI would render inline as follows:

```
user@host:~$ emojig
 🔍 fire█                                         
                                                  
  🚒  🔥  🎆  🧨  🧯  🇮🇪  ⚙️  ⛸️
  😝  🎭  😚  😍  😗  🏎️  😃  😀
  😄  😁  😆  😅  🤣  😂  🙂  🙃
  😜  🤪  😝  🤑  🤗  🤭  🤫  🤔
                                                  
 fire                                             
 [45 Matches]     ↑↓←→ Navigate    Tab: Theme     ^C Cancel 
```
*(Note: The search bar and bottom status bar are colored with continuous background spans to establish structure without using alignment-sensitive borders.)*
