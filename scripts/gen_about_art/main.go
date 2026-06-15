// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Reads spec/art.json and compiles pixel-art entries into $[fg=N,bg=M]{char}
// DSL strings, then upserts the resulting *_lines arrays into spec/strings.json.
// Run: go run ./scripts/gen_about_art/

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// quadChars maps a 4-bit quadrant mask to a Unicode block character.
// Bit layout: bit3=UL bit2=UR bit1=LL bit0=LR; 1=fg 0=bg.
var quadChars = [16]string{
	" ", "▗", "▖", "▄",
	"▝", "▐", "▞", "▟",
	"▘", "▚", "▌", "▙",
	"▀", "▜", "▛", "█",
}

const link = "\x1b]8;;https://ubunatic.com/emojig\x1b\\ubunatic.com/emojig\x1b]8;;\x1b\\"

// ── JSON shapes ──────────────────────────────────────────────────────────────

type ArtSpec struct {
	Palette  map[string]*int `json:"palette"`
	Priority []string        `json:"priority"`
	Art      []ArtEntry      `json:"art"`
}

type ArtEntry struct {
	Name    string   `json:"name"`
	Target  string   `json:"target"`
	Mode    string   `json:"mode"`
	OddCols bool     `json:"odd_cols"`
	Indent  string   `json:"indent"`
	Header  []string `json:"header"`
	Footer  []string `json:"footer"`
	Shape   []string `json:"shape"`
}

// ── Compiler ─────────────────────────────────────────────────────────────────

// parseShape extracts the pixel grid from shape rows.
// If oddCols is true, chars at odd indices (1,3,5,…) are visual separators and skipped.
func parseShape(rows []string, oddCols bool) ([][]string, error) {
	var grid [][]string
	for r, row := range rows {
		chars := strings.Split(row, "")
		var pixels []string
		for i, ch := range chars {
			if oddCols && i%2 == 1 {
				continue
			}
			pixels = append(pixels, ch)
		}
		if len(grid) > 0 && len(pixels) != len(grid[0]) {
			return nil, fmt.Errorf("shape row %d has %d pixels, expected %d", r, len(pixels), len(grid[0]))
		}
		grid = append(grid, pixels)
	}
	return grid, nil
}

// chooseFgBg picks fg/bg colors for a 2×2 quad given the four pixel keys.
// fg = highest-priority non-null color; bg = second-highest (or null).
func chooseFgBg(ul, ur, ll, lr string, palette map[string]*int, priority []string) (fg, bg string) {
	seen := map[string]bool{}
	for _, p := range []string{ul, ur, ll, lr} {
		if palette[p] != nil {
			seen[p] = true
		}
	}
	if len(seen) == 0 {
		return ".", "."
	}
	// collect by priority order
	var colors []string
	for _, p := range priority {
		if seen[p] {
			colors = append(colors, p)
		}
	}
	// any remaining colors not in priority list
	for k := range seen {
		found := false
		for _, c := range colors {
			if c == k {
				found = true
				break
			}
		}
		if !found {
			colors = append(colors, k)
		}
	}
	if len(colors) == 1 {
		return colors[0], "."
	}
	return colors[0], colors[1]
}

type tcCell struct {
	ch string
	fg *int // nil = transparent
	bg *int // nil = transparent
}

func compileQuad(entry ArtEntry, palette map[string]*int, priority []string) ([]string, error) {
	grid, err := parseShape(entry.Shape, entry.OddCols)
	if err != nil {
		return nil, err
	}
	nRows := len(grid)
	if nRows == 0 || nRows%2 != 0 {
		return nil, fmt.Errorf("quad mode needs an even number of shape rows, got %d", nRows)
	}
	nCols := len(grid[0])
	if nCols%2 != 0 {
		return nil, fmt.Errorf("quad mode needs an even number of pixel columns, got %d", nCols)
	}
	tcRows := nRows / 2
	tcCols := nCols / 2

	var lines []string
	for _, h := range entry.Header {
		lines = append(lines, strings.ReplaceAll(h, "$link", link))
	}

	for tr := 0; tr < tcRows; tr++ {
		row0 := grid[tr*2]
		row1 := grid[tr*2+1]

		cells := make([]tcCell, tcCols)
		for tc := 0; tc < tcCols; tc++ {
			ul := row0[tc*2]
			ur := row0[tc*2+1]
			ll := row1[tc*2]
			lr := row1[tc*2+1]

			fg, bg := chooseFgBg(ul, ur, ll, lr, palette, priority)

			// all same single color → full block with fg color (or bare space if null)
			if ul == ur && ur == ll && ll == lr {
				if palette[ul] == nil {
					cells[tc] = tcCell{ch: " ", fg: nil, bg: nil}
				} else {
					cells[tc] = tcCell{ch: "█", fg: palette[ul], bg: nil}
				}
				continue
			}

			mask := 0
			if ul == fg {
				mask |= 8
			}
			if ur == fg {
				mask |= 4
			}
			if ll == fg {
				mask |= 2
			}
			if lr == fg {
				mask |= 1
			}

			var fgIdx, bgIdx *int
			if palette[fg] != nil {
				fgIdx = palette[fg]
			}
			if palette[bg] != nil {
				bgIdx = palette[bg]
			}
			cells[tc] = tcCell{ch: quadChars[mask], fg: fgIdx, bg: bgIdx}
		}

		lines = append(lines, entry.Indent+buildRow(cells))
	}

	for _, f := range entry.Footer {
		lines = append(lines, f)
	}
	return lines, nil
}

// buildRow coalesces adjacent cells with equal fg+bg into DSL spans.
func buildRow(cells []tcCell) string {
	if len(cells) == 0 {
		return ""
	}
	var sb strings.Builder
	start := 0
	for i := 1; i <= len(cells); i++ {
		if i < len(cells) && sameFgBg(cells[i], cells[start]) {
			continue
		}
		// flush run [start, i)
		c := cells[start]
		var content strings.Builder
		for j := start; j < i; j++ {
			content.WriteString(cells[j].ch)
		}
		sb.WriteString(span(c.fg, c.bg, content.String()))
		start = i
	}
	return sb.String()
}

func sameFgBg(a, b tcCell) bool {
	return ptrEq(a.fg, b.fg) && ptrEq(a.bg, b.bg)
}

func ptrEq(a, b *int) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}

func span(fg, bg *int, content string) string {
	if fg == nil && bg == nil {
		return content
	}
	var attrs strings.Builder
	if fg != nil {
		fmt.Fprintf(&attrs, "fg=%d", *fg)
	}
	if bg != nil {
		if attrs.Len() > 0 {
			attrs.WriteByte(',')
		}
		fmt.Fprintf(&attrs, "bg=%d", *bg)
	}
	return "$[" + attrs.String() + "]{" + content + "}"
}

// ── main ─────────────────────────────────────────────────────────────────────

func main() {
	artData, err := os.ReadFile("spec/art.json")
	if err != nil {
		fatalf("read spec/art.json: %v", err)
	}
	var spec ArtSpec
	if err := json.Unmarshal(artData, &spec); err != nil {
		fatalf("parse spec/art.json: %v", err)
	}

	for _, entry := range spec.Art {
		var lines []string
		switch entry.Mode {
		case "quad":
			lines, err = compileQuad(entry, spec.Palette, spec.Priority)
		default:
			fatalf("unsupported mode %q in art entry %q", entry.Mode, entry.Name)
		}
		if err != nil {
			fatalf("compile %q: %v", entry.Name, err)
		}
		if err := upsertLines("spec/strings.json", entry.Target, lines); err != nil {
			fatalf("upsert %s: %v", entry.Target, err)
		}
		fmt.Printf("spec/strings.json: updated %s (%d lines)\n", entry.Target, len(lines))
	}
}

func fatalf(f string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+f+"\n", args...)
	os.Exit(1)
}

// ── strings.json upsert (same token-aware approach as write_about_art.go) ────

func upsertLines(file, key string, lines []string) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(lines)
	if err != nil {
		return err
	}
	var pretty bytes.Buffer
	var raw []json.RawMessage
	if err := json.Unmarshal(encoded, &raw); err != nil {
		return err
	}
	pretty.WriteString("[\n")
	for i, elem := range raw {
		pretty.WriteString("    ")
		pretty.Write(elem)
		if i < len(raw)-1 {
			pretty.WriteByte(',')
		}
		pretty.WriteByte('\n')
	}
	pretty.WriteString("  ]")

	arrStart, arrEnd, found, err := findArrayBounds(data, key)
	if err != nil {
		return fmt.Errorf("scan %s: %w", key, err)
	}
	if found {
		out := make([]byte, 0, len(data)+pretty.Len())
		out = append(out, data[:arrStart]...)
		out = append(out, pretty.Bytes()...)
		out = append(out, data[arrEnd:]...)
		return os.WriteFile(file, out, 0o644)
	}
	closingBrace := bytes.LastIndexByte(data, '}')
	if closingBrace < 0 {
		return fmt.Errorf("no closing brace in %s", file)
	}
	newField := []byte(",\n  \"" + key + "\": " + pretty.String())
	out := make([]byte, 0, len(data)+len(newField)+2)
	out = append(out, data[:closingBrace]...)
	out = append(out, newField...)
	out = append(out, '\n', '}')
	return os.WriteFile(file, out, 0o644)
}

func findArrayBounds(data []byte, key string) (start, end int, found bool, err error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if _, e := dec.Token(); e != nil {
		return 0, 0, false, e
	}
	for dec.More() {
		keyTok, e := dec.Token()
		if e != nil {
			return 0, 0, false, e
		}
		k, ok := keyTok.(string)
		if !ok {
			return 0, 0, false, fmt.Errorf("expected string key, got %T", keyTok)
		}
		valOffset := dec.InputOffset()
		if k != key {
			if e := skipValue(dec); e != nil {
				return 0, 0, false, e
			}
			continue
		}
		arrOff := bytes.IndexByte(data[valOffset:], '[')
		if arrOff < 0 {
			return 0, 0, false, fmt.Errorf("key %q value is not an array", key)
		}
		absStart := int(valOffset) + arrOff
		if _, e := dec.Token(); e != nil {
			return 0, 0, false, e
		}
		for dec.More() {
			if e := skipValue(dec); e != nil {
				return 0, 0, false, e
			}
		}
		if _, e := dec.Token(); e != nil {
			return 0, 0, false, e
		}
		return absStart, int(dec.InputOffset()), true, nil
	}
	return 0, 0, false, nil
}

func skipValue(dec *json.Decoder) error {
	t, err := dec.Token()
	if err != nil {
		return err
	}
	delim, isDelim := t.(json.Delim)
	if !isDelim {
		return nil
	}
	isObj := delim == '{'
	for dec.More() {
		if e := skipValue(dec); e != nil {
			return e
		}
		if isObj {
			if e := skipValue(dec); e != nil {
				return e
			}
		}
	}
	_, err = dec.Token()
	return err
}
