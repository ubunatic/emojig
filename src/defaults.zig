// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Compile-time **upper bounds** for the emojig TUI/GUI stack buffers.
//!
//! The actual grid dimensions, widths, and query length now live in the
//! declarative spec (`spec/layout.json`) and are loaded at runtime by
//! src/spec.zig. Only the buffer-sizing bounds need to be known at compile
//! time, and those only need to be large *enough*, not exact — so they are
//! deliberately spec-independent. Code that sizes a stack array uses these
//! `MAX_*` constants and asserts the runtime layout fits (see main.zig).
//!
//! To change the default layout, edit `spec/layout.json`. Only raise the
//! bounds below if a spec grid would ever exceed them.

/// Largest grid column count any spec layout may use.
pub const MAX_COLS: usize = 16;

/// Largest grid row count any spec layout may use.
pub const MAX_ROWS: usize = 16;

/// Largest total cell count — bounds the *viewport* (visible grid area).
pub const MAX_CELLS: usize = MAX_COLS * MAX_ROWS;

/// Largest number of search results buffered for scrolling. Much larger than
/// MAX_CELLS (the visible viewport) so the grid can scroll through a deep
/// result set without re-running the search. Sizes the match result buffer.
pub const MAX_RESULTS: usize = 5 * MAX_CELLS;

/// Largest search query length any spec layout may use (sizes query buffers).
pub const MAX_QUERY_LEN: usize = 63;
