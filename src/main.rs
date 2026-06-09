// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Skim-style inline TUI demo.
//!
//! This is the *genuine article* counterpart to the hand-rolled raw-ANSI
//! `scripts/inline_tui/box_demo/` harness: instead of re-implementing skim's
//! escape-sequence choreography, it renders through the exact same stack skim
//! uses (`ratatui` + `crossterm`) so the inline `--height` viewport behaves
//! identically. See `docs/SkimInlineTui.md` for the architectural analysis.
//!
//! What it mirrors from skim (`src/tui/backend.rs`):
//!   1. Query the cursor *first*, before drawing anything.
//!   2. Scroll the terminal up only by the exact line deficit, if the viewport
//!      does not fit below the cursor.
//!   3. Pin a `Viewport::Fixed(Rect)` so every cell is drawn at an absolute
//!      screen coordinate (no relative cursor-down drift).
//!   4. On exit, clear the viewport and park the cursor at its top-left so the
//!      shell prompt overwrites the drawing area cleanly — no leaked rows.
//!
//! UI is written to stderr (like skim) so stdout stays free for the selection,
//! making the demo pipe-composable: `inline-demo < items.txt > picked.txt`.

use std::io::{self, BufWriter, IsTerminal, Stderr, Write};

use crossterm::terminal::ScrollUp;
use crossterm::{cursor, execute, terminal};
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph};
use ratatui::{Terminal, TerminalOptions, Viewport};
use unicode_width::UnicodeWidthStr;

type Backend = CrosstermBackend<BufWriter<Stderr>>;

/// Columns the highlight pointer (`"> "`) reserves on the left of each row.
const POINTER_W: u16 = 2;
/// Slack kept on the right of the widest item, so the box never hugs the margin.
const RIGHT_PAD: u16 = 1;
/// Floor so there is always room to type a query and show the count.
const MIN_BOX_WIDTH: u16 = 30;

/// How many rows the inline viewport should occupy, parsed from `--height`.
enum Height {
    /// Absolute row count, e.g. `--height 10`.
    Rows(u16),
    /// Percentage of the terminal height, e.g. `--height 40%`.
    Percent(u16),
}

impl Height {
    /// Resolve against the live terminal height, then clamp to `[1, term]`.
    fn rows(&self, term_height: u16) -> u16 {
        let raw = match *self {
            Height::Rows(n) => n,
            Height::Percent(p) => term_height.saturating_mul(p) / 100,
        };
        raw.clamp(1, term_height.max(1))
    }
}

fn main() {
    let height = match parse_args() {
        Ok(h) => h,
        Err(msg) => {
            eprintln!("{msg}");
            eprintln!("usage: inline-demo [--height N | --height N%]   (items on stdin, else a sample list)");
            std::process::exit(2);
        }
    };

    let items = load_items();
    match run(height, items) {
        Ok(Some(selection)) => {
            // The picked item is the program's *result* -> stdout, for piping.
            println!("{selection}");
        }
        Ok(None) => {} // aborted (Esc / Ctrl-C) — print nothing, like skim
        Err(e) => {
            eprintln!("inline-demo: {e}");
            std::process::exit(1);
        }
    }
}

fn parse_args() -> Result<Height, String> {
    let mut args = std::env::args().skip(1);
    let mut height = Height::Rows(10);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--height" | "-H" => {
                let val = args.next().ok_or("--height requires a value")?;
                height = parse_height(&val)?;
            }
            other if other.starts_with("--height=") => {
                height = parse_height(&other["--height=".len()..])?;
            }
            "-h" | "--help" => return Err("inline-demo: skim-style inline TUI demo".into()),
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(height)
}

fn parse_height(val: &str) -> Result<Height, String> {
    if let Some(pct) = val.strip_suffix('%') {
        let p: u16 = pct.parse().map_err(|_| format!("invalid height: {val}"))?;
        Ok(Height::Percent(p))
    } else {
        let n: u16 = val.parse().map_err(|_| format!("invalid height: {val}"))?;
        Ok(Height::Rows(n))
    }
}

/// Read newline-separated items from stdin when it is piped; otherwise fall
/// back to a built-in sample so the demo is runnable with no input — exactly
/// the shape real skim uses (`use-dev-tty` keeps key events on /dev/tty even
/// while stdin is a pipe).
fn load_items() -> Vec<String> {
    if io::stdin().is_terminal() {
        return sample_items();
    }
    let mut buf = String::new();
    if io::Read::read_to_string(&mut io::stdin(), &mut buf).is_err() {
        return sample_items();
    }
    let items: Vec<String> = buf.lines().map(str::to_owned).filter(|l| !l.is_empty()).collect();
    if items.is_empty() {
        sample_items()
    } else {
        items
    }
}

fn sample_items() -> Vec<String> {
    [
        "😀 grinning face",
        "😂 face with tears of joy",
        "🥹 face holding back tears",
        "😍 smiling face with heart-eyes",
        "🤔 thinking face",
        "🙃 upside-down face",
        "😴 sleeping face",
        "🤯 exploding head",
        "🥳 partying face",
        "😎 smiling face with sunglasses",
        "🚀 rocket",
        "🔥 fire",
        "✨ sparkles",
        "🎉 party popper",
        "💡 light bulb",
        "🐙 octopus",
        "🦀 crab",
        "🐧 penguin",
        "🌮 taco",
        "☕ hot beverage",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect()
}

/// State of the interactive picker.
struct App {
    items: Vec<String>,
    query: String,
    /// Indices into `items` matching the current query, in input order.
    matches: Vec<usize>,
    state: ListState,
}

impl App {
    fn new(items: Vec<String>) -> Self {
        let mut app = App {
            matches: (0..items.len()).collect(),
            items,
            query: String::new(),
            state: ListState::default(),
        };
        app.state.select(if app.matches.is_empty() { None } else { Some(0) });
        app
    }

    /// Case-insensitive substring filter, preserving input order. The fidelity
    /// of this demo lives in the viewport, not the matcher (see module docs).
    fn refilter(&mut self) {
        let q = self.query.to_lowercase();
        self.matches = self
            .items
            .iter()
            .enumerate()
            .filter(|(_, it)| q.is_empty() || it.to_lowercase().contains(&q))
            .map(|(i, _)| i)
            .collect();
        self.state.select(if self.matches.is_empty() { None } else { Some(0) });
    }

    fn move_selection(&mut self, delta: isize) {
        if self.matches.is_empty() {
            return;
        }
        let len = self.matches.len() as isize;
        let cur = self.state.selected().unwrap_or(0) as isize;
        let next = (cur + delta).rem_euclid(len);
        self.state.select(Some(next as usize));
    }

    fn selected_item(&self) -> Option<&str> {
        self.state
            .selected()
            .and_then(|i| self.matches.get(i))
            .map(|&idx| self.items[idx].as_str())
    }
}

fn run(height: Height, items: Vec<String>) -> io::Result<Option<String>> {
    let box_width = content_width(&items);
    let mut term = enter(&height, box_width)?;
    let mut app = App::new(items);

    let result = loop {
        term.draw(|f| draw(f, &mut app))?;

        match event::read()? {
            Event::Key(key) if key.kind == KeyEventKind::Press => {
                let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
                match key.code {
                    KeyCode::Esc => break None,
                    KeyCode::Char('c') if ctrl => break None,
                    KeyCode::Char('g') if ctrl => break None,
                    KeyCode::Enter => break app.selected_item().map(str::to_owned),
                    KeyCode::Up => app.move_selection(-1),
                    KeyCode::Down => app.move_selection(1),
                    KeyCode::Char('p') if ctrl => app.move_selection(-1),
                    KeyCode::Char('n') if ctrl => app.move_selection(1),
                    KeyCode::Char('k') if ctrl => app.move_selection(-1),
                    KeyCode::Char('j') if ctrl => app.move_selection(1),
                    KeyCode::Backspace => {
                        app.query.pop();
                        app.refilter();
                    }
                    KeyCode::Char(c) if !ctrl => {
                        app.query.push(c);
                        app.refilter();
                    }
                    _ => {}
                }
            }
            Event::Resize(..) => {} // ratatui repaints into the fixed viewport
            _ => {}
        }
    };

    exit(&mut term)?;
    Ok(result)
}

/// The box is sized to its content, not the terminal.
///
/// A `Viewport::Fixed` width is frozen at creation: ratatui's autoresize only
/// re-sizes `Fullscreen`/`Inline` viewports, never `Fixed`. skim (and our first
/// cut) pinned it to `cols - 1`, so the rows nearly fill the width. Shrink the
/// terminal and that frozen buffer is now wider than the screen, so the emulator
/// soft-wraps every over-long line onto the next row — the broken layout you see.
///
/// Pinning the box to the widest item instead leaves slack on the right, so an
/// ordinary horizontal shrink keeps the terminal wider than the box: lines still
/// fit, nothing wraps, and we are h-resize-safe with no resize handling at all.
/// (It only wraps once the terminal is squeezed below `box_width` itself.)
fn content_width(items: &[String]) -> u16 {
    let longest = items
        .iter()
        .map(|s| UnicodeWidthStr::width(s.as_str()).min(u16::MAX as usize) as u16)
        .max()
        .unwrap_or(0);
    longest.saturating_add(POINTER_W + RIGHT_PAD).max(MIN_BOX_WIDTH)
}

/// Set up the inline viewport exactly as skim does (`Tui::new_with_height_and_backend`),
/// except the viewport width is the content-sized `box_width` rather than `cols - 1`.
fn enter(height: &Height, box_width: u16) -> io::Result<Terminal<Backend>> {
    terminal::enable_raw_mode()?;

    let (cols, term_height) = terminal::size()?;
    let want = height.rows(term_height);
    // Clamp to what actually fits; on a wide terminal this stays well short of
    // the right edge, which is exactly what keeps us resize-safe.
    let box_width = box_width.min(cols.saturating_sub(1)).max(1);

    // 1. Query the cursor *before* drawing. `cursor::position` is 0-based;
    //    skim works in 1-based coordinates, so `cy = row + 1`.
    let cy = cursor::position()?.1 + 1;
    let mut y = cy - 1;

    // 2. Scroll up only by the exact deficit if the viewport runs past the
    //    bottom — keeps the initiating command visible, never over-scrolls.
    if term_height - cy < want {
        let to_scroll = want - (term_height - cy) - 1;
        execute!(io::stderr(), ScrollUp(to_scroll))?;
        y = y.saturating_sub(to_scroll);
    }

    // 3. Pin the viewport: every cell now maps to an absolute screen cell.
    let viewport = Viewport::Fixed(Rect::new(0, y, box_width, want));
    let backend = CrosstermBackend::new(BufWriter::new(io::stderr()));
    execute!(io::stderr(), cursor::Hide)?;
    Terminal::with_options(backend, TerminalOptions { viewport })
}

/// Tear down the inline viewport the way skim does: clear the fixed rect and
/// park the cursor at its top-left, so the shell prompt overwrites it cleanly.
fn exit(term: &mut Terminal<Backend>) -> io::Result<()> {
    term.clear()?;
    let area = term.get_frame().area();
    term.set_cursor_position(Position { x: area.x, y: area.y })?;
    execute!(io::stderr(), cursor::Show)?;
    terminal::disable_raw_mode()?;
    io::stderr().flush()?;
    Ok(())
}

/// skim's default layout: results on top, an info/count line, then the prompt
/// at the bottom — all inside the fixed `height`-row viewport.
fn draw(f: &mut ratatui::Frame, app: &mut App) {
    let area = f.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(1),    // results
            Constraint::Length(1), // count
            Constraint::Length(1), // prompt
        ])
        .split(area);

    let rows: Vec<ListItem> = app
        .matches
        .iter()
        .map(|&idx| ListItem::new(Line::from(app.items[idx].as_str())))
        .collect();

    let list = List::new(rows)
        .highlight_symbol("> ")
        .highlight_style(Style::default().fg(Color::Green).add_modifier(Modifier::BOLD));
    f.render_stateful_widget(list, chunks[0], &mut app.state);

    let count = Line::from(vec![Span::styled(
        format!("  {}/{}", app.matches.len(), app.items.len()),
        Style::default().fg(Color::Yellow),
    )]);
    f.render_widget(Paragraph::new(count), chunks[1]);

    let prompt = Line::from(vec![
        Span::styled("> ", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
        Span::raw(app.query.as_str()),
    ]);
    f.render_widget(Paragraph::new(prompt), chunks[2]);

    // Park the real terminal cursor after the query text, like a prompt.
    let cursor_col = area.x + 2 + app.query.chars().count() as u16;
    f.set_cursor_position(Position { x: cursor_col.min(area.x + area.width.saturating_sub(1)), y: chunks[2].y });
}
