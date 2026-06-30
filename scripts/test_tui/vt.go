// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

type Cell struct {
	Char      rune
	FgColor   string // SGR color parameter, e.g. "38;5;248"
	BgColor   string // SGR color parameter, e.g. "48;5;234"
	Bold      bool
	Underline bool
	Reverse   bool
}

type TerminalState struct {
	Width           int
	Height          int
	Grid            [][]Cell
	CursorX         int // 0-indexed
	CursorY         int // 0-indexed
	ActiveFG        string
	ActiveBG        string
	ActiveBold      bool
	ActiveUnderline bool
	ActiveReverse   bool
}

func NewTerminalState(width, height int) *TerminalState {
	grid := make([][]Cell, height)
	for y := range grid {
		grid[y] = make([]Cell, width)
		for x := range grid[y] {
			grid[y][x] = Cell{Char: ' '}
		}
	}
	return &TerminalState{
		Width:  width,
		Height: height,
		Grid:   grid,
	}
}

func (ts *TerminalState) scrollUp() {
	for y := 0; y < ts.Height-1; y++ {
		copy(ts.Grid[y], ts.Grid[y+1])
	}
	ts.Grid[ts.Height-1] = make([]Cell, ts.Width)
	for x := range ts.Grid[ts.Height-1] {
		ts.Grid[ts.Height-1][x] = Cell{Char: ' '}
	}
}

func runeWidth(r rune) int {
	if r == 0xFE0F || r == 0xFE0E {
		return 0
	}
	if r >= 0x2e80 {
		return 2
	}
	if r >= 0x20 {
		return 1
	}
	return 0
}

func (ts *TerminalState) writeChar(r rune) {
	w := runeWidth(r)
	if w == 0 {
		return
	}

	if ts.CursorX+w > ts.Width {
		// Auto-wrap
		ts.CursorX = 0
		ts.CursorY++
		if ts.CursorY >= ts.Height {
			ts.CursorY = ts.Height - 1
			ts.scrollUp()
		}
	}

	if ts.CursorY >= 0 && ts.CursorY < ts.Height && ts.CursorX >= 0 && ts.CursorX < ts.Width {
		ts.Grid[ts.CursorY][ts.CursorX] = Cell{
			Char:      r,
			FgColor:   ts.ActiveFG,
			BgColor:   ts.ActiveBG,
			Bold:      ts.ActiveBold,
			Underline: ts.ActiveUnderline,
			Reverse:   ts.ActiveReverse,
		}
		ts.CursorX++
		if w == 2 && ts.CursorX < ts.Width {
			ts.Grid[ts.CursorY][ts.CursorX] = Cell{
				Char:      0, // Null/filler for second half of wide char
				FgColor:   ts.ActiveFG,
				BgColor:   ts.ActiveBG,
				Bold:      ts.ActiveBold,
				Underline: ts.ActiveUnderline,
				Reverse:   ts.ActiveReverse,
			}
			ts.CursorX++
		}
	}
}

func (ts *TerminalState) handleCSI(params []byte, cmd byte) {
	paramStr := string(params)
	switch cmd {
	case 'H', 'f': // Cursor position (CUP)
		row, col := 1, 1
		if len(paramStr) > 0 {
			parts := strings.Split(paramStr, ";")
			if len(parts) >= 1 && parts[0] != "" {
				if r, err := strconv.Atoi(parts[0]); err == nil {
					row = r
				}
			}
			if len(parts) >= 2 && parts[1] != "" {
				if c, err := strconv.Atoi(parts[1]); err == nil {
					col = c
				}
			}
		}
		ts.CursorY = row - 1
		ts.CursorX = col - 1
		if ts.CursorY < 0 {
			ts.CursorY = 0
		}
		if ts.CursorY >= ts.Height {
			ts.CursorY = ts.Height - 1
		}
		if ts.CursorX < 0 {
			ts.CursorX = 0
		}
		if ts.CursorX >= ts.Width {
			ts.CursorX = ts.Width - 1
		}

	case 'A': // Cursor Up (CUU)
		n := 1
		if paramStr != "" {
			if val, err := strconv.Atoi(paramStr); err == nil {
				n = val
			}
		}
		ts.CursorY -= n
		if ts.CursorY < 0 {
			ts.CursorY = 0
		}

	case 'B': // Cursor Down (CUD)
		n := 1
		if paramStr != "" {
			if val, err := strconv.Atoi(paramStr); err == nil {
				n = val
			}
		}
		ts.CursorY += n
		if ts.CursorY >= ts.Height {
			ts.CursorY = ts.Height - 1
		}

	case 'C': // Cursor Forward (CUF)
		n := 1
		if paramStr != "" {
			if val, err := strconv.Atoi(paramStr); err == nil {
				n = val
			}
		}
		ts.CursorX += n
		if ts.CursorX >= ts.Width {
			ts.CursorX = ts.Width - 1
		}

	case 'D': // Cursor Backward (CUB)
		n := 1
		if paramStr != "" {
			if val, err := strconv.Atoi(paramStr); err == nil {
				n = val
			}
		}
		ts.CursorX -= n
		if ts.CursorX < 0 {
			ts.CursorX = 0
		}

	case 'G': // Cursor Horizontal Absolute (CHA)
		n := 1
		if paramStr != "" {
			if val, err := strconv.Atoi(paramStr); err == nil {
				n = val
			}
		}
		ts.CursorX = n - 1
		if ts.CursorX < 0 {
			ts.CursorX = 0
		}
		if ts.CursorX >= ts.Width {
			ts.CursorX = ts.Width - 1
		}

	case 'K': // Erase in Line (EL)
		mode := 0
		if paramStr != "" {
			if val, err := strconv.Atoi(paramStr); err == nil {
				mode = val
			}
		}
		if ts.CursorY >= 0 && ts.CursorY < ts.Height {
			switch mode {
			case 0: // Clear from cursor to end of line
				for x := ts.CursorX; x < ts.Width; x++ {
					ts.Grid[ts.CursorY][x] = Cell{Char: ' '}
				}
			case 1: // Clear from start of line to cursor
				limit := ts.CursorX
				if limit >= ts.Width {
					limit = ts.Width - 1
				}
				for x := 0; x <= limit; x++ {
					ts.Grid[ts.CursorY][x] = Cell{Char: ' '}
				}
			case 2: // Clear entire line
				for x := 0; x < ts.Width; x++ {
					ts.Grid[ts.CursorY][x] = Cell{Char: ' '}
				}
			}
		}

	case 'm': // Select Graphic Rendition (SGR)
		if paramStr == "" || paramStr == "0" {
			ts.ActiveFG = ""
			ts.ActiveBG = ""
			ts.ActiveBold = false
			ts.ActiveUnderline = false
			ts.ActiveReverse = false
			return
		}

		parts := strings.Split(paramStr, ";")
		idx := 0
		for idx < len(parts) {
			part := parts[idx]
			if part == "" || part == "0" {
				ts.ActiveFG = ""
				ts.ActiveBG = ""
				ts.ActiveBold = false
				ts.ActiveUnderline = false
				ts.ActiveReverse = false
				idx++
				continue
			}

			val, err := strconv.Atoi(part)
			if err != nil {
				idx++
				continue
			}

			switch val {
			case 1:
				ts.ActiveBold = true
				idx++
			case 4:
				ts.ActiveUnderline = true
				idx++
			case 7:
				ts.ActiveReverse = true
				idx++
			case 22:
				ts.ActiveBold = false
				idx++
			case 24:
				ts.ActiveUnderline = false
				idx++
			case 27:
				ts.ActiveReverse = false
				idx++
			case 30, 31, 32, 33, 34, 35, 36, 37:
				ts.ActiveFG = part
				idx++
			case 38: // FG extended color
				if idx+2 < len(parts) && parts[idx+1] == "5" { // 256 color
					ts.ActiveFG = fmt.Sprintf("38;5;%s", parts[idx+2])
					idx += 3
				} else if idx+4 < len(parts) && parts[idx+1] == "2" { // true color
					ts.ActiveFG = fmt.Sprintf("38;2;%s;%s;%s", parts[idx+2], parts[idx+3], parts[idx+4])
					idx += 5
				} else {
					idx++
				}
			case 39:
				ts.ActiveFG = ""
				idx++
			case 40, 41, 42, 43, 44, 45, 46, 47:
				ts.ActiveBG = part
				idx++
			case 48: // BG extended color
				if idx+2 < len(parts) && parts[idx+1] == "5" { // 256 color
					ts.ActiveBG = fmt.Sprintf("48;5;%s", parts[idx+2])
					idx += 3
				} else if idx+4 < len(parts) && parts[idx+1] == "2" { // true color
					ts.ActiveBG = fmt.Sprintf("48;2;%s;%s;%s", parts[idx+2], parts[idx+3], parts[idx+4])
					idx += 5
				} else {
					idx++
				}
			case 49:
				ts.ActiveBG = ""
				idx++
			default:
				idx++
			}
		}
	}
}

func (ts *TerminalState) Parse(data []byte) {
	i := 0
	for i < len(data) {
		b := data[i]
		if b == 0x1b { // ESC
			if i+1 < len(data) {
				next := data[i+1]
				if next == '[' { // CSI sequence
					i += 2
					start := i
					for i < len(data) {
						c := data[i]
						i++
						if c >= 0x40 && c <= 0x7e {
							ts.handleCSI(data[start:i-1], c)
							break
						}
					}
					continue
				} else if next == ']' { // OSC sequence
					i += 2
					for i < len(data) {
						if data[i] == 0x07 {
							i++
							break
						}
						if data[i] == 0x1b && i+1 < len(data) && data[i+1] == '\\' {
							i += 2
							break
						}
						i++
					}
					continue
				} else {
					i += 2
					continue
				}
			} else {
				i++
				continue
			}
		}

		if b == '\r' {
			ts.CursorX = 0
			i++
			continue
		}
		if b == '\n' {
			ts.CursorY++
			if ts.CursorY >= ts.Height {
				ts.CursorY = ts.Height - 1
				ts.scrollUp()
			}
			i++
			continue
		}

		r, size := utf8.DecodeRune(data[i:])
		if r != utf8.RuneError {
			ts.writeChar(r)
			i += size
		} else {
			ts.writeChar(rune(b))
			i++
		}
	}
}

func (ts *TerminalState) GetRowText(y int) string {
	if y < 0 || y >= ts.Height {
		return ""
	}
	var sb strings.Builder
	for x := 0; x < ts.Width; x++ {
		sb.WriteRune(ts.Grid[y][x].Char)
	}
	return sb.String()
}

func (ts *TerminalState) ValidateLayout(contentWidth int) error {
	// The TUI has width contentWidth + 1 (columns 0 to contentWidth).
	// Therefore, column contentWidth + 1 onwards must be empty.
	for y := 0; y < ts.Height; y++ {
		for x := contentWidth + 1; x < ts.Width; x++ {
			c := ts.Grid[y][x].Char
			if c != ' ' && c != 0 {
				return fmt.Errorf("layout overflow: cell at row %d col %d contains non-space character %q (out of bounds for contentWidth %d)", y, x, c, contentWidth)
			}
		}
	}
	return nil
}

func (ts *TerminalState) PrintScreen() {
	for y := 0; y < ts.Height; y++ {
		var line strings.Builder
		for x := 0; x < ts.Width; x++ {
			r := ts.Grid[y][x].Char
			if r == 0 {
				r = ' '
			}
			line.WriteRune(r)
		}
		fmt.Printf("Row %02d: |%s|\n", y, line.String())
	}
}

