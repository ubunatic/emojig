// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package tui implements the minimal-core inline emoji picker: a search bar, a
// fuzzy-matched grid, a description row, and a status row, rendered on the
// alt-screen with raw keyboard input. Mouse, MRU, clipboard, border, and exit
// preview are intentionally out of scope for the first cut.
package tui

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"codeberg.org/ubunatic/emojig/internal/emoji"
	"codeberg.org/ubunatic/emojig/internal/spec"
	"codeberg.org/ubunatic/emojig/internal/term"
)

// App holds the picker state.
type App struct {
	db    *emoji.DB
	specs spec.Specs

	themeName string // "dark" or "light"
	query     []byte
	selected  int
	top       []emoji.Match
	total     int
}

// New builds an App from the loaded data and specs.
func New(db *emoji.DB, specs spec.Specs) *App {
	return &App{
		db:        db,
		specs:     specs,
		themeName: "dark",
	}
}

func fg(n int) string { return fmt.Sprintf("\x1b[38;5;%dm", n) }
func bg(n int) string { return fmt.Sprintf("\x1b[48;5;%dm", n) }

// Run drives the picker and returns the chosen emoji, or "" if cancelled.
func (a *App) Run() (string, error) {
	t, err := term.MakeRaw()
	if err != nil {
		return "", err
	}
	defer t.Restore()

	os.Stdout.WriteString(term.AltScreenOn + term.HideCursor)

	a.refresh()
	for {
		a.render()
		key, text, quit := readKey()
		if quit {
			return "", nil
		}
		action := a.specs.Keys.Bindings[key]
		switch action {
		case "quit":
			return "", nil
		case "select":
			if a.selected >= 0 && a.selected < len(a.top) {
				return a.db.Entries[a.top[a.selected].Index].Emoji, nil
			}
			return "", nil
		case "delete":
			if len(a.query) > 0 {
				a.query = a.query[:len(a.query)-1]
				a.refresh()
			}
		case "cycle_theme":
			if a.themeName == "dark" {
				a.themeName = "light"
			} else {
				a.themeName = "dark"
			}
		case "nav_up", "nav_down", "nav_left", "nav_right":
			a.navigate(action)
		default:
			if text != "" {
				if len(a.query) < a.specs.Layout.MaxQueryLen {
					a.query = append(a.query, text...)
					a.refresh()
				}
			}
		}
	}
}

// refresh re-runs the search and resets the selection.
func (a *App) refresh() {
	cells := a.specs.Layout.TUI.Cells()
	a.top, a.total = a.db.Search(string(a.query), cells)
	if len(a.top) > 0 {
		a.selected = 0
	} else {
		a.selected = -1
	}
}

// navigate moves the selection within the grid, wrapping like src/main.zig.
func (a *App) navigate(action string) {
	count := len(a.top)
	if count == 0 {
		a.selected = -1
		return
	}
	if a.selected < 0 {
		a.selected = 0
		return
	}
	cols := a.specs.Layout.TUI.Cols
	rows := a.specs.Layout.TUI.Rows
	sel := a.selected
	switch action {
	case "nav_up":
		if sel >= cols {
			sel -= cols
		} else {
			target := sel + (rows-1)*cols
			if target < count {
				sel = target
			} else {
				sel = count - 1
			}
		}
	case "nav_down":
		target := sel + cols
		if target < count {
			sel = target
		} else {
			sel = sel % cols
		}
	case "nav_left":
		if sel > 0 {
			sel--
		} else {
			sel = count - 1
		}
	case "nav_right":
		if sel < count-1 {
			sel++
		} else {
			sel = 0
		}
	}
	a.selected = sel
}

// helpMode reports whether the help overlay should replace the grid (query
// starts with '?', mirroring src/main.zig:1011).
func (a *App) helpMode() bool {
	return len(a.query) > 0 && a.query[0] == '?'
}

// render draws a full frame on the alt-screen.
func (a *App) render() {
	pal := a.specs.Theme.Themes[a.themeName]
	str := a.specs.Strings
	width := a.specs.Layout.TUI.Width
	var b strings.Builder
	b.WriteString(term.CursorHome + term.ClearScreen)

	// Search bar row.
	icon := a.specs.Theme.Icons[a.themeName]
	left := str.SearchPrompt + string(a.query)
	bar := padTo(left, width-3) + icon + " "
	b.WriteString(bg(pal.SearchBg) + fg(pal.SearchFg) + bar + term.Reset + "\r\n")
	b.WriteString("\r\n") // spacer

	if a.helpMode() {
		a.renderHelp(&b, pal, width)
	} else {
		a.renderGrid(&b, pal, width)
	}

	// Status row.
	status := str.StatusHelpHint
	if len(a.query) > 0 {
		status = strings.ReplaceAll(str.StatusMatches, "{count}", strconv.Itoa(a.total))
	}
	if width >= 35 {
		if len(a.query) == 0 {
			status = " ?:help e:img t:txt  ↕↔|↵|Esc"
		} else {
			status = " " + strconv.Itoa(a.total) + " e:img t:txt  ↕↔|↵|Esc"
		}
	}
	b.WriteString(fg(pal.SearchShadeFg) + truncate(status, width) + term.Reset)

	os.Stdout.WriteString(b.String())
}

// renderGrid draws the emoji grid, a spacer, and the description row.
func (a *App) renderGrid(b *strings.Builder, pal spec.Palette, width int) {
	cols := a.specs.Layout.TUI.Cols
	rows := a.specs.Layout.TUI.Rows
	// Each cell occupies 4 columns. Padding adapts to the emoji display width
	// so single- and double-width glyphs stay aligned (see emoji.Width).
	for r := 0; r < rows; r++ {
		var row strings.Builder
		for c := 0; c < cols; c++ {
			idx := r*cols + c
			if idx >= len(a.top) {
				row.WriteString("    ")
				continue
			}
			e := a.db.Entries[a.top[idx].Index].Emoji
			pad := " " // double-width: one trailing space
			if emoji.Width(e) == 1 {
				pad = "  " // single-width: two trailing spaces
			}
			if idx == a.selected {
				row.WriteString(bg(pal.SelectionBg) + fg(pal.SelectionFg) + "[" + e + pad[1:] + "]" + term.Reset)
			} else {
				row.WriteString(fg(pal.GridFg) + " " + e + pad + term.Reset)
			}
		}
		b.WriteString(row.String() + "\r\n")
	}
	b.WriteString("\r\n") // spacer

	// Description row.
	name := ""
	if a.selected >= 0 && a.selected < len(a.top) {
		name = a.db.Entries[a.top[a.selected].Index].Name
	}
	b.WriteString(fg(pal.GridFg) + " " + truncate(name, width-1) + term.Reset + "\r\n")
}

// renderHelp draws the help overlay in place of the grid. The title plus each
// help line is rendered on its own row; the status row follows below.
func (a *App) renderHelp(b *strings.Builder, pal spec.Palette, width int) {
	str := a.specs.Strings
	lines := append([]string{str.HelpTitle}, str.HelpLines...)
	for _, line := range lines {
		b.WriteString(fg(pal.GridFg) + " " + truncate(line, width-1) + term.Reset + "\r\n")
	}
}

// padTo pads s with spaces to at least n runes (no truncation).
func padTo(s string, n int) string {
	l := len([]rune(s))
	if l >= n {
		return s
	}
	return s + strings.Repeat(" ", n-l)
}

// truncate shortens s to at most n runes.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}
