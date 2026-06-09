// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package tui implements the minimal-core inline emoji picker: a search bar, a
// fuzzy-matched grid, a description row, and a status row, rendered on the
// alt-screen with raw keyboard input. Mouse, MRU, clipboard, border, and exit
// preview are intentionally out of scope for the first cut.
package tui

import (
	"fmt"
	"io"
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

	// I/O handles. Set during Run from the /dev/tty handle so os.Stdout stays
	// free for the selection. out also receives the inline control codes.
	out io.StringWriter
	in  io.Reader

	// Inline rendering. When height.set, the picker draws a fixed region below
	// the prompt (skim-style) instead of taking the alt-screen.
	height   Height
	inline   bool
	regY     int // 1-based top row of the reserved region
	regH     int // region height in rows (constant footprint)
	boxWidth int // max drawn width (cols-1) so an h-shrink can't wrap rows
}

// New builds an App from the loaded data and specs.
func New(db *emoji.DB, specs spec.Specs) *App {
	return &App{
		db:        db,
		specs:     specs,
		themeName: "dark",
	}
}

// SetHeight enables inline rendering with the given height spec (see
// ParseHeight). The zero Height leaves the App in its default alt-screen mode.
func (a *App) SetHeight(h Height) { a.height = h }

func fg(n int) string { return fmt.Sprintf("\x1b[38;5;%dm", n) }
func bg(n int) string { return fmt.Sprintf("\x1b[48;5;%dm", n) }
func bgOpt(n *int) string {
	if n == nil {
		return ""
	}
	return fmt.Sprintf("\x1b[48;5;%dm", *n)
}

// Run drives the picker and returns the chosen emoji, or "" if cancelled.
func (a *App) Run() (string, error) {
	t, err := term.MakeRaw()
	if err != nil {
		return "", err
	}
	defer t.Restore()

	a.out = t.TTY()
	a.in = t.TTY()

	if a.height.set {
		a.enterInline(t)
	} else {
		a.out.WriteString(term.AltScreenOn + term.HideCursor)
	}

	a.refresh()
	for {
		a.render()
		key, text, quit := readKey(a.in)
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

// render draws one frame. It builds the logical rows once, then emits them
// either as a full alt-screen repaint or into the fixed inline region (each row
// positioned absolutely and clamped so a horizontal shrink cannot wrap it).
func (a *App) render() {
	rows := a.frame()
	var b strings.Builder
	if a.inline {
		for i := 0; i < a.regH; i++ {
			b.WriteString(term.MoveTo(a.regY+i, 1))
			if i < len(rows) {
				b.WriteString(clampANSI(rows[i], a.boxWidth))
			} else {
				b.WriteString(strings.Repeat(" ", a.boxWidth))
			}
		}
	} else {
		b.WriteString(term.CursorHome + term.ClearScreen)
		b.WriteString(strings.Join(rows, "\r\n"))
	}
	a.out.WriteString(b.String())
}

// frame returns the picker's logical rows with no positioning or newlines:
// search bar, a spacer, the grid (or help) body, and the status row. Both the
// alt-screen and inline render paths consume this.
func (a *App) frame() []string {
	pal := a.specs.Theme.Themes[a.themeName]
	str := a.specs.Strings
	width := a.specs.Layout.TUI.Width
	var rows []string

	// Search bar row.
	icon := a.specs.Theme.Icons[a.themeName]
	left := str.SearchPrompt + string(a.query)
	bar := padTo(left, width-3) + icon + " "
	rows = append(rows, bgOpt(pal.SearchBg)+fg(pal.SearchFg)+bar+term.Reset)
	rows = append(rows, "") // spacer

	if a.helpMode() {
		rows = a.helpRows(rows, pal, width)
	} else {
		rows = a.gridRows(rows, pal, width)
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
	rows = append(rows, bgOpt(pal.StatusBg)+fg(pal.StatusFg)+padTo(truncate(status, width), width)+term.Reset)
	return rows
}

// gridRows appends the emoji grid, a spacer, and the description row.
func (a *App) gridRows(rows []string, pal spec.Palette, width int) []string {
	cols := a.specs.Layout.TUI.Cols
	gr := a.specs.Layout.TUI.Rows
	// Each cell occupies 4 columns. Padding adapts to the emoji display width
	// so single- and double-width glyphs stay aligned (see emoji.Width).
	for r := 0; r < gr; r++ {
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
				row.WriteString(bgOpt(pal.SelectionBg) + fg(pal.SelectionFg) + "[" + e + pad[1:] + "]" + term.Reset)
			} else {
				row.WriteString(bgOpt(pal.GridBg) + fg(pal.GridFg) + " " + e + pad + term.Reset)
			}
		}
		rows = append(rows, row.String())
	}
	rows = append(rows, "") // spacer

	// Description row.
	name := ""
	if a.selected >= 0 && a.selected < len(a.top) {
		name = a.db.Entries[a.top[a.selected].Index].Name
	}
	return append(rows, bgOpt(pal.InfoBg)+fg(pal.InfoFg)+" "+truncate(name, width-1)+term.Reset)
}

// helpRows appends the help overlay in place of the grid: the title and each
// help line on its own row.
func (a *App) helpRows(rows []string, pal spec.Palette, width int) []string {
	str := a.specs.Strings
	lines := append([]string{str.HelpTitle}, str.HelpLines...)
	for _, line := range lines {
		rows = append(rows, bgOpt(pal.GridBg)+fg(pal.GridFg)+" "+truncate(line, width-1)+term.Reset)
	}
	return rows
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

// enterInline reserves a fixed region below the prompt, skim-style: resolve the
// region height, query the cursor first, scroll up only by the deficit so the
// region fits on screen, then record the region (and register it on t for clean
// teardown). See docs/SkimInlineTui.md and src/main.rs for the reference.
func (a *App) enterInline(t *term.Terminal) {
	cols, rows := t.Size()

	want := a.height.resolve(rows)
	if h := a.footprint(); want > h {
		want = h // never reserve more than the picker can fill
	}
	if want > rows-1 {
		want = rows - 1 // keep the initiating line visible
	}
	if want < 1 {
		want = 1
	}

	// Query the cursor before reserving space — the root cause of inline drift
	// is reserving before you know where you are. On failure assume the bottom
	// row, which forces a full scroll (safe: never overdraws above the prompt).
	cy, _, err := t.QueryCursor()
	if err != nil || cy < 1 || cy > rows {
		cy = rows
	}
	y, toScroll := reserveRegion(cy, rows, want)
	if toScroll > 0 {
		a.out.WriteString(term.ScrollUp(toScroll))
	}

	a.inline = true
	a.regY = y
	a.regH = want
	a.boxWidth = a.specs.Layout.TUI.Width
	if a.boxWidth > cols-1 {
		a.boxWidth = cols - 1
	}
	if a.boxWidth < 1 {
		a.boxWidth = 1
	}
	t.SetInline(y, want, a.boxWidth)
	a.out.WriteString(term.HideCursor)
}

// reserveRegion computes where a want-row region starting at the 1-based cursor
// row cy lands, and how far to scroll up to make it fit on a rows-tall screen.
// It scrolls only by the deficit, keeping the initiating line visible (skim's
// rule). Returns the region's 1-based top row and the lines to scroll (0 = none).
func reserveRegion(cy, rows, want int) (y, toScroll int) {
	y = cy
	if rows-cy < want {
		if d := want - (rows - cy) - 1; d > 0 {
			toScroll = d
			y -= d
		}
	}
	if y < 1 {
		y = 1
	}
	return y, toScroll
}

// footprint returns the picker's natural height in rows: the larger of the grid
// view and the help view, so the reserved region never overflows either.
func (a *App) footprint() int {
	// grid view: search bar + spacer + grid rows + spacer + desc + status
	grid := a.specs.Layout.TUI.Rows + 5
	// help view: search bar + spacer + (title + help lines) + status
	help := 4 + len(a.specs.Strings.HelpLines)
	if help > grid {
		return help
	}
	return grid
}

// Height is a parsed --height value: either a fixed row count or a percentage of
// the terminal height. The zero value (set=false) means alt-screen mode.
type Height struct {
	set     bool
	rows    int
	percent int
}

// Set reports whether a --height value was given (i.e. inline mode is enabled).
func (h Height) Set() bool { return h.set }

// ParseHeight parses a --height value: "N" for a fixed row count or "N%" for a
// percentage of the terminal height.
func ParseHeight(s string) (Height, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return Height{}, fmt.Errorf("empty height")
	}
	if strings.HasSuffix(s, "%") {
		n, err := strconv.Atoi(strings.TrimSuffix(s, "%"))
		if err != nil || n <= 0 || n > 100 {
			return Height{}, fmt.Errorf("invalid height percent: %q", s)
		}
		return Height{set: true, percent: n}, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return Height{}, fmt.Errorf("invalid height: %q", s)
	}
	return Height{set: true, rows: n}, nil
}

// resolve turns the spec into an absolute row count for the given terminal
// height (at least 1).
func (h Height) resolve(termRows int) int {
	n := h.rows
	if h.percent > 0 {
		n = termRows * h.percent / 100
	}
	if n < 1 {
		n = 1
	}
	return n
}

// clampANSI truncates s to at most max display columns. ANSI escape sequences
// are copied through with zero width; wide glyphs (emoji) count as two. A reset
// is appended on truncation so colors cannot bleed past the cut. Shorter rows
// are padded with spaces up to max display columns.
func clampANSI(s string, max int) string {
	if max <= 0 {
		return ""
	}
	var b strings.Builder
	col := 0
	runes := []rune(s)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if r == 0x1b { // ESC: copy the whole escape sequence verbatim
			b.WriteRune(r)
			i++
			if i < len(runes) && runes[i] == '[' { // CSI
				b.WriteRune(runes[i])
				i++
				for i < len(runes) {
					c := runes[i]
					b.WriteRune(c)
					if c >= 0x40 && c <= 0x7e { // final byte ends the CSI
						break
					}
					i++
				}
			} else if i < len(runes) {
				b.WriteRune(runes[i]) // simple two-byte escape
			}
			continue
		}
		w := emoji.Width(string(r))
		if col+w > max {
			b.WriteString(term.Reset)
			break
		}
		b.WriteRune(r)
		col += w
	}
	if col < max {
		b.WriteString(strings.Repeat(" ", max-col))
	}
	return b.String()
}
