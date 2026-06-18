// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Reads spec/art.json and compiles pixel-art entries into $[fg=N,bg=M]{char}
// DSL strings, then upserts the resulting *_lines or *_frames arrays into
// spec/strings.json.  Single-frame entries use inline "shape"; multi-frame
// entries use "frames_dir" (directory of numbered .txt files) + "delays_ms".
// Run: go run ./scripts/gen_about_art/

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strconv"
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

// rawArtSpec is the unmarshalled shape before palette resolution.
type rawArtSpec struct {
	Colors   map[string]int               `json:"colors"`
	Palette  map[string]json.RawMessage   `json:"palette"`
	Priority []string                     `json:"priority"`
	Art      []ArtEntry                   `json:"art"`
}

type ArtSpec struct {
	Palette  map[string]*int
	Priority []string
	Art      []ArtEntry
}

// resolvePalette turns raw palette entries (null | number | "name") into *int.
func resolvePalette(raw map[string]json.RawMessage, colors map[string]int) (map[string]*int, error) {
	out := make(map[string]*int, len(raw))
	for k, v := range raw {
		if string(v) == "null" {
			out[k] = nil
			continue
		}
		// try number first
		var num int
		if err := json.Unmarshal(v, &num); err == nil {
			n := num
			out[k] = &n
			continue
		}
		// try string name
		var name string
		if err := json.Unmarshal(v, &name); err != nil {
			return nil, fmt.Errorf("palette key %q: expected null, number, or color name, got %s", k, v)
		}
		n, ok := colors[name]
		if !ok {
			return nil, fmt.Errorf("palette key %q references unknown color %q", k, name)
		}
		out[k] = &n
	}
	return out, nil
}

type ArtEntry struct {
	Name         string   `json:"name"`
	Target       string   `json:"target"`
	Mode         string   `json:"mode"`
	Spaced       bool     `json:"spaced"`
	Indent       string   `json:"indent"`
	Header       []string `json:"header"`
	Footer       []string `json:"footer"`
	Shape        []string `json:"shape"`
	FramesDir    string   `json:"frames_dir"`
	DelaysMs     []int    `json:"delays_ms"`
	Fps          int      `json:"fps"`
	StartDelayMs *int     `json:"start_delay_ms"`
	EndDelayMs   *int     `json:"end_delay_ms"`
}

// buildDelays returns one delay (ms) per frame.
// If fps > 0, all frames get 1000/fps ms; otherwise delays_ms is used verbatim.
// start_delay_ms / end_delay_ms override the first / last entry.
func buildDelays(entry ArtEntry, n int) []int {
	delays := make([]int, n)
	switch {
	case entry.Fps > 0:
		ms := 1000 / entry.Fps
		for i := range delays {
			delays[i] = ms
		}
	case len(entry.DelaysMs) == n:
		copy(delays, entry.DelaysMs)
	default:
		fatalf("%q: need 'fps' or 'delays_ms' with %d entries for %d frames (got %d)",
			entry.Name, n, n, len(entry.DelaysMs))
	}
	if entry.StartDelayMs != nil {
		delays[0] = *entry.StartDelayMs
	}
	if entry.EndDelayMs != nil {
		delays[n-1] = *entry.EndDelayMs
	}
	return delays
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
	grid, err := parseShape(entry.Shape, entry.Spaced)
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

	// colorCanon maps each color value to the first palette key in priority
	// order that carries that color, so chars with the same color are treated
	// as identical by chooseFgBg and the mask computation.
	colorCanon := map[int]string{}
	for _, p := range priority {
		if palette[p] != nil {
			v := *palette[p]
			if _, exists := colorCanon[v]; !exists {
				colorCanon[v] = p
			}
		}
	}
	normPx := func(ch string) string {
		if palette[ch] == nil {
			return "."
		}
		if canon, ok := colorCanon[*palette[ch]]; ok {
			return canon
		}
		return ch
	}

	for tr := 0; tr < tcRows; tr++ {
		row0 := grid[tr*2]
		row1 := grid[tr*2+1]

		cells := make([]tcCell, tcCols)
		for tc := 0; tc < tcCols; tc++ {
			ul := normPx(row0[tc*2])
			ur := normPx(row0[tc*2+1])
			ll := normPx(row1[tc*2])
			lr := normPx(row1[tc*2+1])

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

// ── DSL expander ─────────────────────────────────────────────────────────────

// expandDSL converts $[fg=N,bg=M]{content} spans to ANSI escape codes.
// $version is replaced with "dev" (preview only).
func expandDSL(s string) string {
	s = strings.ReplaceAll(s, "$version", "dev")
	var out strings.Builder
	for {
		i := strings.Index(s, "$[")
		if i < 0 {
			out.WriteString(s)
			break
		}
		out.WriteString(s[:i])
		s = s[i+2:]
		j := strings.Index(s, "]{")
		if j < 0 {
			out.WriteString("$[")
			out.WriteString(s)
			break
		}
		attrs := s[:j]
		s = s[j+2:]
		k := strings.Index(s, "}")
		if k < 0 {
			out.WriteString("$[")
			out.WriteString(attrs)
			out.WriteString("]{")
			out.WriteString(s)
			break
		}
		content := s[:k]
		s = s[k+1:]
		for _, part := range strings.Split(attrs, ",") {
			part = strings.TrimSpace(part)
			switch {
			case strings.HasPrefix(part, "fg="):
				fmt.Fprintf(&out, "\x1b[38;5;%sm", part[3:])
			case strings.HasPrefix(part, "bg="):
				fmt.Fprintf(&out, "\x1b[48;5;%sm", part[3:])
			}
		}
		out.WriteString(content)
		out.WriteString("\x1b[0m")
	}
	return out.String()
}

// ── frame loading ────────────────────────────────────────────────────────────

// loadFrames reads all *.txt files from dir in sorted order and returns
// each file's lines as one element of the outer slice.
// parseFrameName splits a frame base name (like "sheet_0001" or "02") into
// its prefix (everything before the trailing digits), numeric value, and digit width.
func parseFrameName(name string) (prefix string, num int, width int, ok bool) {
	base := strings.TrimSuffix(name, filepath.Ext(name))
	i := len(base) - 1
	for i >= 0 && base[i] >= '0' && base[i] <= '9' {
		i--
	}
	digitStart := i + 1
	if digitStart == len(base) {
		return "", 0, 0, false
	}
	prefix = base[:digitStart]
	digits := base[digitStart:]
	var err error
	num, err = strconv.Atoi(digits)
	if err != nil {
		return "", 0, 0, false
	}
	return prefix, num, len(digits), true
}

// standardANSI is the classic 16-color palette (indices 0–15).
var standardANSI = [16]color.NRGBA{
	{0x00, 0x00, 0x00, 0xFF}, // 0  black
	{0x80, 0x00, 0x00, 0xFF}, // 1  red
	{0x00, 0x80, 0x00, 0xFF}, // 2  green
	{0x80, 0x80, 0x00, 0xFF}, // 3  yellow
	{0x00, 0x00, 0x80, 0xFF}, // 4  blue
	{0x80, 0x00, 0x80, 0xFF}, // 5  magenta
	{0x00, 0x80, 0x80, 0xFF}, // 6  cyan
	{0xC0, 0xC0, 0xC0, 0xFF}, // 7  white
	{0x80, 0x80, 0x80, 0xFF}, // 8  bright black
	{0xFF, 0x00, 0x00, 0xFF}, // 9  bright red
	{0x00, 0xFF, 0x00, 0xFF}, // 10 bright green
	{0xFF, 0xFF, 0x00, 0xFF}, // 11 bright yellow
	{0x00, 0x00, 0xFF, 0xFF}, // 12 bright blue
	{0xFF, 0x00, 0xFF, 0xFF}, // 13 bright magenta
	{0x00, 0xFF, 0xFF, 0xFF}, // 14 bright cyan
	{0xFF, 0xFF, 0xFF, 0xFF}, // 15 bright white
}

// Well-known overrides for specific 256-color indices used in the project.
var knownColors = map[int]color.NRGBA{
	214: {0xFF, 0xD7, 0x00, 0xFF}, // amber
	255: {0xEE, 0xEE, 0xEE, 0xFF}, // white
	238: {0x44, 0x44, 0x44, 0xFF}, // gray
	232: {0x08, 0x08, 0x08, 0xFF}, // dark/black
	209: {0xFF, 0x87, 0x5F, 0xFF}, // pink
	54:  {0x5F, 0x00, 0x87, 0xFF}, // purple
}

// idx256ToRGB converts a 256-color terminal index to NRGBA.
func idx256ToRGB(idx int) color.NRGBA {
	if c, ok := knownColors[idx]; ok {
		return c
	}
	if idx < 16 {
		return standardANSI[idx]
	}
	if idx >= 232 {
		// grayscale ramp: 232–255 → 8, 18, 28, …, 238
		g := uint8(8 + (idx-232)*10)
		return color.NRGBA{g, g, g, 0xFF}
	}
	// 6×6×6 color cube: indices 16–231
	idx -= 16
	b := idx % 6
	idx /= 6
	g := idx % 6
	r := idx / 6
	conv := func(v int) uint8 {
		if v == 0 {
			return 0
		}
		return uint8(55 + v*40)
	}
	return color.NRGBA{conv(r), conv(g), conv(b), 0xFF}
}

// buildImagePalette creates an indexed color.Palette following priority order.
func buildImagePalette(priority []string, pal map[string]*int) color.Palette {
	imgPal := make(color.Palette, len(priority))
	for i, ch := range priority {
		colPtr := pal[ch]
		if colPtr == nil {
			imgPal[i] = color.NRGBA{0, 0, 0, 0} // transparent
		} else {
			imgPal[i] = idx256ToRGB(*colPtr)
		}
	}
	return imgPal
}

// closestPaletteIndex finds the palette entry closest to c by Euclidean distance.
func closestPaletteIndex(c color.Color, pal color.Palette) int {
	cr, cg, cb, ca := c.RGBA()
	best := 0
	bestDist := uint64(1<<63 - 1)
	for i, pc := range pal {
		pr, pg, pb, pa := pc.RGBA()
		dr := int64(cr) - int64(pr)
		dg := int64(cg) - int64(pg)
		db := int64(cb) - int64(pb)
		da := int64(ca) - int64(pa)
		dist := uint64(dr*dr + dg*dg + db*db + da*da)
		if dist < bestDist {
			bestDist = dist
			best = i
		}
	}
	return best
}

// loadFrames reads all *.png files from dir in sorted order and returns
// each file's pixel characters as lines of strings.
func loadFrames(dir string, priority []string, imgPal color.Palette) ([][]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read frames dir %s: %w", dir, err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if filepath.Ext(e.Name()) != ".png" {
			continue
		}
		if _, _, _, ok := parseFrameName(e.Name()); ok {
			names = append(names, e.Name())
		}
	}
	sort.Slice(names, func(i, j int) bool {
		pi, numI, _, okI := parseFrameName(names[i])
		pj, numJ, _, okJ := parseFrameName(names[j])
		if okI && okJ {
			if pi != pj {
				return pi < pj
			}
			return numI < numJ
		}
		return names[i] < names[j]
	})

	if len(names) == 0 {
		return nil, fmt.Errorf("no .png files found in %s", dir)
	}
	var frames [][]string
	for _, name := range names {
		f, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		img, err := png.Decode(f)
		f.Close()
		if err != nil {
			return nil, fmt.Errorf("decode %s: %w", name, err)
		}

		bounds := img.Bounds()
		w, h := bounds.Dx(), bounds.Dy()

		var lines []string
		for y := 0; y < h; y++ {
			var sb strings.Builder
			for x := 0; x < w; x++ {
				c := img.At(bounds.Min.X+x, bounds.Min.Y+y)
				_, _, _, ca := c.RGBA()
				if ca == 0 {
					sb.WriteString(priority[0])
				} else {
					idx := closestPaletteIndex(c, imgPal)
					if idx < len(priority) {
						sb.WriteString(priority[idx])
					} else {
						sb.WriteString(priority[0])
					}
				}
			}
			lines = append(lines, sb.String())
		}
		frames = append(frames, lines)
	}
	return frames, nil
}

// ── main ─────────────────────────────────────────────────────────────────────

func main() {
	doPrint := len(os.Args) > 1 && os.Args[1] == "print"

	artData, err := os.ReadFile("spec/art.json")
	if err != nil {
		fatalf("read spec/art.json: %v", err)
	}
	var raw rawArtSpec
	if err := json.Unmarshal(artData, &raw); err != nil {
		fatalf("parse spec/art.json: %v", err)
	}
	palette, err := resolvePalette(raw.Palette, raw.Colors)
	if err != nil {
		fatalf("resolve palette: %v", err)
	}
	spec := ArtSpec{Palette: palette, Priority: raw.Priority, Art: raw.Art}

	for _, entry := range spec.Art {
		// Determine frame shapes: either from frames_dir or inline shape.
		var shapeFrames [][]string // each element is one frame's shape rows
		if entry.FramesDir != "" {
			imgPal := buildImagePalette(spec.Priority, spec.Palette)
			shapeFrames, err = loadFrames(entry.FramesDir, spec.Priority, imgPal)
			if err != nil {
				fatalf("load frames for %q: %v", entry.Name, err)
			}
			// Validate consistent dimensions across frames.
			refRows := len(shapeFrames[0])
			refCols := 0
			if refRows > 0 {
				refCols = len([]rune(shapeFrames[0][0]))
			}
			for i, frame := range shapeFrames {
				if len(frame) != refRows {
					fatalf("%q: frame %d has %d rows, expected %d",
						entry.Name, i, len(frame), refRows)
				}
				for r, row := range frame {
					if len([]rune(row)) != refCols {
						fatalf("%q: frame %d row %d has %d cols, expected %d",
							entry.Name, i, r, len([]rune(row)), refCols)
					}
				}
			}
			// Validate even dimensions for quad mode.
			if entry.Mode == "quad" {
				if refRows%2 != 0 {
					fatalf("%q: quad mode needs even row count, got %d", entry.Name, refRows)
				}
				if refCols%2 != 0 {
					fatalf("%q: quad mode needs even column count, got %d", entry.Name, refCols)
				}
			}
		} else if entry.Shape != nil {
			shapeFrames = [][]string{entry.Shape}
		} else {
			fatalf("%q: art entry has neither 'shape' nor 'frames_dir'", entry.Name)
		}

		// Compile each frame.
		allFrames := make([][]string, 0, len(shapeFrames))
		for _, shape := range shapeFrames {
			frameEntry := entry
			frameEntry.Shape = shape
			var lines []string
			switch entry.Mode {
			case "quad":
				lines, err = compileQuad(frameEntry, spec.Palette, spec.Priority)
			default:
				fatalf("unsupported mode %q in art entry %q", entry.Mode, entry.Name)
			}
			if err != nil {
				fatalf("compile %q: %v", entry.Name, err)
			}
			allFrames = append(allFrames, lines)
		}

		// Build delays for multi-frame entries.
		var delays []int
		if strings.HasSuffix(entry.Target, "_frames") {
			delays = buildDelays(entry, len(allFrames))
		}

		// Print mode.
		if doPrint {
			for i, frame := range allFrames {
				if len(allFrames) > 1 {
					delay := 0
					if delays != nil && i < len(delays) {
						delay = delays[i]
					}
					if i > 0 {
						fmt.Println()
					}
					fmt.Printf("--- Frame %d (%dms) ---\n", i, delay)
				}
				for _, l := range frame {
					fmt.Println(expandDSL(l))
				}
			}
			continue
		}

		// Write to strings.json.
		if strings.HasSuffix(entry.Target, "_frames") {
			if err := upsertFrames("spec/strings.json", entry.Target, allFrames); err != nil {
				fatalf("upsert %s: %v", entry.Target, err)
			}
			delaysKey := strings.TrimSuffix(entry.Target, "_frames") + "_delays"
			if err := upsertInts("spec/strings.json", delaysKey, delays); err != nil {
				fatalf("upsert %s: %v", delaysKey, err)
			}
			fmt.Printf("spec/strings.json: updated %s (%d frames) + %s\n",
				entry.Target, len(allFrames), delaysKey)
		} else {
			if err := upsertLines("spec/strings.json", entry.Target, allFrames[0]); err != nil {
				fatalf("upsert %s: %v", entry.Target, err)
			}
			fmt.Printf("spec/strings.json: updated %s (%d lines)\n", entry.Target, len(allFrames[0]))
		}
	}
}

func fatalf(f string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+f+"\n", args...)
	os.Exit(1)
}

// ── strings.json upsert (token-aware: rewrites only the target value) ────────

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

// upsertFrames writes a [][]string (array of frame line arrays) into the JSON file.
func upsertFrames(file, key string, frames [][]string) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(frames)
	if err != nil {
		return err
	}
	// Pretty-print the 2D array: outer array on its own lines, inner arrays
	// formatted like upsertLines (one string per line, 6-space indent).
	var pretty bytes.Buffer
	var outer []json.RawMessage
	if err := json.Unmarshal(encoded, &outer); err != nil {
		return err
	}
	pretty.WriteString("[\n")
	for fi, frameRaw := range outer {
		var inner []json.RawMessage
		if err := json.Unmarshal(frameRaw, &inner); err != nil {
			return err
		}
		pretty.WriteString("    [\n")
		for i, elem := range inner {
			pretty.WriteString("      ")
			pretty.Write(elem)
			if i < len(inner)-1 {
				pretty.WriteByte(',')
			}
			pretty.WriteByte('\n')
		}
		pretty.WriteString("    ]")
		if fi < len(outer)-1 {
			pretty.WriteByte(',')
		}
		pretty.WriteByte('\n')
	}
	pretty.WriteString("  ]")

	return upsertRaw(file, key, pretty.Bytes(), data)
}

// upsertInts writes a []int value into the JSON file.
func upsertInts(file, key string, vals []int) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(vals)
	if err != nil {
		return err
	}
	// Pretty-print: single-line array is fine for ints.
	return upsertRaw(file, key, encoded, data)
}

// upsertRaw replaces or inserts a key with already-formatted value bytes.
func upsertRaw(file, key string, value, data []byte) error {
	arrStart, arrEnd, found, err := findValueBounds(data, key)
	if err != nil {
		return fmt.Errorf("scan %s: %w", key, err)
	}
	if found {
		out := make([]byte, 0, len(data)+len(value))
		out = append(out, data[:arrStart]...)
		out = append(out, value...)
		out = append(out, data[arrEnd:]...)
		return os.WriteFile(file, out, 0o644)
	}
	closingBrace := bytes.LastIndexByte(data, '}')
	if closingBrace < 0 {
		return fmt.Errorf("no closing brace in %s", file)
	}
	newField := []byte(",\n  \"" + key + "\": " + string(value))
	out := make([]byte, 0, len(data)+len(newField)+2)
	out = append(out, data[:closingBrace]...)
	out = append(out, newField...)
	out = append(out, '\n', '}')
	return os.WriteFile(file, out, 0o644)
}

// findValueBounds locates the start and end byte offsets of a top-level
// key's value in a JSON object.  Works for any value type (array, object,
// number, string, etc.).
func findValueBounds(data []byte, key string) (start, end int, found bool, err error) {
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
		valStart := int(dec.InputOffset())
		if k != key {
			if e := skipValue(dec); e != nil {
				return 0, 0, false, e
			}
			continue
		}
		// Skip whitespace before colon
		for valStart < len(data) && (data[valStart] == ' ' || data[valStart] == '\t' || data[valStart] == '\n' || data[valStart] == '\r') {
			valStart++
		}
		// Skip colon
		if valStart < len(data) && data[valStart] == ':' {
			valStart++
		}
		// Skip whitespace after colon
		for valStart < len(data) && (data[valStart] == ' ' || data[valStart] == '\t' || data[valStart] == '\n' || data[valStart] == '\r') {
			valStart++
		}
		if e := skipValue(dec); e != nil {
			return 0, 0, false, e
		}
		return valStart, int(dec.InputOffset()), true, nil
	}
	return 0, 0, false, nil
}
