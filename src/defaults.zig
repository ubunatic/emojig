// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Compile-time defaults for the emojig TUI and GUI layouts.
//!
//! Edit this file to change the default grid dimensions and window widths
//! that are baked into the binary at build time. Runtime overrides via
//! environment variables (EMOJIG_COLS, EMOJIG_ROWS, EMOJIG_WIDTH) and
//! CLI flags (--width, --height) still take precedence.

// ---------------------------------------------------------------------------
// TUI defaults  (inline terminal mode, `emojig --tui`)
// ---------------------------------------------------------------------------

/// Number of emoji columns in TUI mode.
pub const tui_cols: usize = 6;

/// Number of emoji rows in TUI mode.
pub const tui_rows: usize = 4;

/// Terminal content width in columns for TUI mode.
pub const tui_width: usize = 25;

// ---------------------------------------------------------------------------
// GUI defaults  (floating window mode, `emojig --gui`)
// ---------------------------------------------------------------------------

/// Number of emoji columns in GUI mode.
pub const gui_cols: usize = 10;

/// Number of emoji rows in GUI mode.
pub const gui_rows: usize = 6;

/// Terminal content width in columns for GUI mode.
pub const gui_width: usize = 41;

// ---------------------------------------------------------------------------
// Derived (do not edit)
// ---------------------------------------------------------------------------

/// Non-grid content rows: padding + search + spacer + spacer + description + status = 6.
pub const layout_overhead: usize = 6;

/// Largest grid column count across TUI and GUI — sizes the per-row stack buffers.
pub const max_cols: usize = @max(tui_cols, gui_cols);

/// Largest grid row count across TUI and GUI.
pub const max_rows: usize = @max(tui_rows, gui_rows);

/// Largest total cell count — sizes the match result buffer.
pub const max_cells: usize = max_cols * max_rows;
