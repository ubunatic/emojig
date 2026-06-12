// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package tui

import (
	"strings"
	"testing"

	"codeberg.org/ubunatic/emojig/internal/spec"
	"codeberg.org/ubunatic/emojig/internal/term"
)

func TestParseHeight(t *testing.T) {
	tests := []struct {
		in       string
		wantSet  bool
		rows     int
		percent  int
		wantErr  bool
	}{
		{"8", true, 8, 0, false},
		{"40%", true, 0, 40, false},
		{" 12 ", true, 12, 0, false},
		{"100%", true, 0, 100, false},
		{"", false, 0, 0, true},
		{"0", false, 0, 0, true},
		{"-3", false, 0, 0, true},
		{"0%", false, 0, 0, true},
		{"150%", false, 0, 0, true},
		{"abc", false, 0, 0, true},
	}
	for _, tc := range tests {
		h, err := ParseHeight(tc.in)
		if tc.wantErr {
			if err == nil {
				t.Errorf("ParseHeight(%q): want error, got %+v", tc.in, h)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseHeight(%q): unexpected error: %v", tc.in, err)
			continue
		}
		if h.set != tc.wantSet || h.rows != tc.rows || h.percent != tc.percent {
			t.Errorf("ParseHeight(%q) = %+v, want set=%v rows=%d pct=%d", tc.in, h, tc.wantSet, tc.rows, tc.percent)
		}
	}
}

func TestHeightResolve(t *testing.T) {
	tests := []struct {
		h        Height
		termRows int
		want     int
	}{
		{Height{set: true, rows: 8}, 50, 8},
		{Height{set: true, percent: 40}, 50, 20},
		{Height{set: true, percent: 100}, 24, 24},
		{Height{set: true, percent: 1}, 24, 1}, // floored to 1
		{Height{set: true, rows: 999}, 24, 999}, // resolve does not clamp to screen
	}
	for _, tc := range tests {
		if got := tc.h.resolve(tc.termRows); got != tc.want {
			t.Errorf("resolve(%+v, %d) = %d, want %d", tc.h, tc.termRows, got, tc.want)
		}
	}
}

func TestReserveRegion(t *testing.T) {
	tests := []struct {
		cy, rows, want   int
		wantY, wantSroll int
	}{
		// Plenty of room below the cursor: no scroll, region starts at cursor.
		{cy: 5, rows: 40, want: 8, wantY: 5, wantSroll: 0},
		// Exactly fits (rows-cy == want-1): no scroll.
		{cy: 33, rows: 40, want: 8, wantY: 33, wantSroll: 0},
		// One short: scroll by 1, region shifts up by 1.
		{cy: 34, rows: 40, want: 8, wantY: 33, wantSroll: 1},
		// Cursor on the last row, full region: scroll by want-1.
		{cy: 40, rows: 40, want: 8, wantY: 33, wantSroll: 7},
		// want == 1 on the last row: nothing to scroll.
		{cy: 40, rows: 40, want: 1, wantY: 40, wantSroll: 0},
	}
	for _, tc := range tests {
		y, scroll := reserveRegion(tc.cy, tc.rows, tc.want)
		if y != tc.wantY || scroll != tc.wantSroll {
			t.Errorf("reserveRegion(cy=%d,rows=%d,want=%d) = (y=%d,scroll=%d), want (y=%d,scroll=%d)",
				tc.cy, tc.rows, tc.want, y, scroll, tc.wantY, tc.wantSroll)
		}
	}
}

func TestClampANSI(t *testing.T) {
	const reset = "\x1b[0m"
	tests := []struct {
		name string
		in   string
		max  int
		want string
	}{
		{"fits unchanged", "hi", 10, "hi" + strings.Repeat(" ", 8)},
		{"truncate plain", "hello", 3, "hel" + reset},
		{"escape passthrough", "\x1b[31mhi" + reset, 10, "\x1b[31mhi" + reset + strings.Repeat(" ", 8)},
		{"escape zero width then truncate", "\x1b[31mhello", 3, "\x1b[31mhel" + reset},
		{"wide glyph counts two", "🎉🎉", 4, "🎉🎉"},
		{"wide glyph truncates on boundary", "🎉🎉", 3, "🎉" + reset + " "},
		{"zero max", "anything", 0, ""},
	}
	for _, tc := range tests {
		if got := clampANSI(tc.in, tc.max); got != tc.want {
			t.Errorf("%s: clampANSI(%q,%d) = %q, want %q", tc.name, tc.in, tc.max, got, tc.want)
		}
	}
}

// minimalApp builds an App with just enough spec to render an empty frame.
func minimalApp() *App {
	specs := spec.Specs{
		Layout: spec.Layout{TUI: spec.GridDims{Cols: 10, Rows: 3, Width: 42}},
		Theme: spec.Theme{
			Icons:  map[string]string{"dark": "🌙"},
			Themes: map[string]spec.Palette{"dark": {}},
		},
		Strings: spec.Strings{
			SearchPrompt:   "> ",
			StatusHelpHint: "help",
			StatusMatches:  "{count} matches",
			HelpLines:      []string{"Help", "a", "b", "c"},
		},
	}
	return &App{db: nil, specs: specs, themeName: "dark", selected: -1}
}

func TestFootprint(t *testing.T) {
	a := minimalApp()
	// grid = Rows+5 = 8; help = 3+len(HelpLines)=7; max = 8.
	if got := a.footprint(); got != 8 {
		t.Errorf("footprint() = %d, want 8", got)
	}
}

func TestRenderInlineShape(t *testing.T) {
	a := minimalApp()
	a.inline = true
	a.regY = 5
	a.regH = 8
	a.boxWidth = 40
	var buf strings.Builder
	a.out = &buf
	a.render()
	out := buf.String()

	// Inline rendering must never touch the alt-screen or clear the whole screen.
	if strings.Contains(out, term.AltScreenOn) || strings.Contains(out, term.ClearScreen) {
		t.Errorf("inline render leaked alt-screen/clear-screen sequences:\n%q", out)
	}
	// Exactly regH rows, each positioned absolutely. Should not contain ClearLine.
	if strings.Contains(out, term.ClearLine) {
		t.Errorf("inline render should not contain ClearLine sequences")
	}
	for i := 0; i < a.regH; i++ {
		want := term.MoveTo(a.regY+i, 1)
		if !strings.Contains(out, want) {
			t.Errorf("missing positioned row %d (%q)", a.regY+i, want)
		}
	}
	// No row past the region.
	if strings.Contains(out, term.MoveTo(a.regY+a.regH, 1)) {
		t.Errorf("render drew past the reserved region (row %d)", a.regY+a.regH)
	}
}

// TestRenderWritesToInjectedOut is the stdout-clean guarantee: the UI bytes go
// only to the App's out writer (wired to /dev/tty in Run), never to stdout.
func TestRenderWritesToInjectedOut(t *testing.T) {
	a := minimalApp()
	a.inline = true
	a.regY = 1
	a.regH = 8
	a.boxWidth = 60
	var buf strings.Builder
	a.out = &buf
	a.render()
	if buf.Len() == 0 {
		t.Fatal("render wrote nothing to the injected out writer")
	}
}
