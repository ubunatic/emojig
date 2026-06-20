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

// Global Colors Schema loaded from spec/colors.json
type GlobalColor struct {
	I     int      `json:"i"`
	Name  string   `json:"name"`
	Short string   `json:"short"`
	Hex   string   `json:"hex"`
	Desc  string   `json:"desc"`
	Alt   []string `json:"alt"`
}

type GlobalColorsSpec struct {
	Colors []GlobalColor `json:"colors"`
}

var globalColors []GlobalColor
var globalRGBs [256]color.NRGBA

// rawArtSpec is the unmarshalled shape before palette resolution.
type rawArtSpec struct {
	Colors   map[string]json.RawMessage   `json:"colors"`
	Palette  map[string]json.RawMessage   `json:"palette"`
	Priority []string                     `json:"priority"`
	Art      []ArtEntry                   `json:"art"`
}

type ArtSpec struct {
	Palette  map[string]*int
	Priority []string
	Art      []ArtEntry
}

func normalizeColorName(s string) string {
	s = strings.ToLower(s)
	var sb strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

func parseHexGo(h string) (color.NRGBA, error) {
	h = strings.TrimPrefix(h, "#")
	if len(h) == 3 {
		r, err := strconv.ParseUint(h[0:1], 16, 8)
		if err != nil {
			return color.NRGBA{}, err
		}
		g, err := strconv.ParseUint(h[1:2], 16, 8)
		if err != nil {
			return color.NRGBA{}, err
		}
		b, err := strconv.ParseUint(h[2:3], 16, 8)
		if err != nil {
			return color.NRGBA{}, err
		}
		return color.NRGBA{uint8(r * 17), uint8(g * 17), uint8(b * 17), 255}, nil
	} else if len(h) == 6 {
		r, err := strconv.ParseUint(h[0:2], 16, 8)
		if err != nil {
			return color.NRGBA{}, err
		}
		g, err := strconv.ParseUint(h[2:4], 16, 8)
		if err != nil {
			return color.NRGBA{}, err
		}
		b, err := strconv.ParseUint(h[4:6], 16, 8)
		if err != nil {
			return color.NRGBA{}, err
		}
		return color.NRGBA{uint8(r), uint8(g), uint8(b), 255}, nil
	}
	return color.NRGBA{}, fmt.Errorf("invalid hex color: %s", h)
}

func closestSchemaColor(c color.NRGBA, schema []GlobalColor) GlobalColor {
	best := schema[0]
	bestDist := uint64(1<<63 - 1)
	cr, cg, cb := c.R, c.G, c.B
	for _, gc := range schema {
		pc, err := parseHexGo(gc.Hex)
		if err != nil {
			continue
		}
		dr := int64(cr) - int64(pc.R)
		dg := int64(cg) - int64(pc.G)
		db := int64(cb) - int64(pc.B)
		dist := uint64(dr*dr + dg*dg + db*db)
		if dist < bestDist {
			bestDist = dist
			best = gc
		}
	}
	return best
}

func resolveRawColor(v json.RawMessage) (int, error) {
	var num int
	if err := json.Unmarshal(v, &num); err == nil {
		if num >= 0 && num <= 255 {
			return num, nil
		}
		return 0, fmt.Errorf("invalid color index: %d", num)
	}
	var str string
	if err := json.Unmarshal(v, &str); err != nil {
		return 0, fmt.Errorf("expected number or string, got %s", string(v))
	}
	// Try parsing as integer string
	if idx, err := strconv.Atoi(str); err == nil {
		if idx >= 0 && idx <= 255 {
			return idx, nil
		}
		return 0, fmt.Errorf("invalid color index: %d", idx)
	}
	// Try parsing as hex
	if strings.HasPrefix(str, "#") {
		rgb, err := parseHexGo(str)
		if err != nil {
			return 0, err
		}
		// Check exact match in schema
		for _, gc := range globalColors {
			if gc.Hex == str {
				return gc.I, nil
			}
		}
		// Check normalized exact hex match
		for _, gc := range globalColors {
			gcRGB := globalRGBs[gc.I]
			if gcRGB.R == rgb.R && gcRGB.G == rgb.G && gcRGB.B == rgb.B {
				return gc.I, nil
			}
		}
		// Warning and match to closest
		closest := closestSchemaColor(rgb, globalColors)
		fmt.Fprintf(os.Stderr, "Warning: hex color %q is not compatible with the schema, matching to closest color %q (index %d, hex %s)\n", str, closest.Name, closest.I, closest.Hex)
		return closest.I, nil
	}

	// Normalize and look up in globalColors
	norm := normalizeColorName(str)
	for _, gc := range globalColors {
		if normalizeColorName(gc.Name) == norm || (gc.Short != "" && normalizeColorName(gc.Short) == norm) {
			return gc.I, nil
		}
		for _, a := range gc.Alt {
			if normalizeColorName(a) == norm {
				return gc.I, nil
			}
		}
	}
	return 0, fmt.Errorf("unknown color name: %q", str)
}

// resolvePalette turns raw palette entries (null | number | "name") into *int.
func resolvePalette(rawPalette map[string]json.RawMessage, rawColors map[string]json.RawMessage) (map[string]*int, error) {
	// First resolve the local colors overrides
	localColors := make(map[string]int)
	for name, rawVal := range rawColors {
		idx, err := resolveRawColor(rawVal)
		if err != nil {
			return nil, fmt.Errorf("resolve local color %q: %w", name, err)
		}
		localColors[name] = idx
	}

	out := make(map[string]*int, len(rawPalette))
	for k, v := range rawPalette {
		if string(v) == "null" {
			out[k] = nil
			continue
		}
		
		// If it matches a local override name or global color name
		var str string
		if err := json.Unmarshal(v, &str); err == nil {
			// Check local overrides first
			if idx, ok := localColors[str]; ok {
				n := idx
				out[k] = &n
				continue
			}
			// Check global colors
			if idx, err := resolveRawColor(v); err == nil {
				n := idx
				out[k] = &n
				continue
			}
		}

		// Fallback to direct resolution of raw palette entry
		idx, err := resolveRawColor(v)
		if err != nil {
			return nil, fmt.Errorf("palette key %q: %w", k, err)
		}
		n := idx
		out[k] = &n
	}
	return out, nil
}

type StackItem struct {
	Path string
	Fps  int
}

func (s *StackItem) UnmarshalJSON(data []byte) error {
	var str string
	if err := json.Unmarshal(data, &str); err == nil {
		s.Path = str
		s.Fps = 0
		return nil
	}
	var obj struct {
		Path string `json:"path"`
		Fps  int    `json:"fps"`
	}
	if err := json.Unmarshal(data, &obj); err == nil {
		s.Path = obj.Path
		s.Fps = obj.Fps
		return nil
	}
	return fmt.Errorf("invalid stack item: %s", string(data))
}

type ArtEntry struct {
	Name         string      `json:"name"`
	Target       string      `json:"target"`
	Mode         string      `json:"mode"`
	Spaced       bool        `json:"spaced"`
	Indent       string      `json:"indent"`
	Header       []string    `json:"header"`
	Footer       []string    `json:"footer"`
	Shape        []string    `json:"shape"`
	FramesDir    string      `json:"frames_dir"`
	Stack        []StackItem `json:"stack"`
	DelaysMs     []int       `json:"delays_ms"`
	Fps          int         `json:"fps"`
	StartDelayMs *int        `json:"start_delay_ms"`
	EndDelayMs   *int        `json:"end_delay_ms"`
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

// idx256ToRGB converts a 256-color terminal index to NRGBA using the global schema.
func idx256ToRGB(idx int) color.NRGBA {
	if idx < 0 || idx > 255 {
		return color.NRGBA{0, 0, 0, 0}
	}
	return globalRGBs[idx]
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

// loadFramesFromPath reads *.png files from dir in sorted order, optionally
// filtering by filename prefix, and returns each file's pixel characters.
func loadFramesFromPath(path string, priority []string, imgPal color.Palette) ([][]string, error) {
	fi, err := os.Stat(path)
	var dir, prefix string
	if err == nil && fi.IsDir() {
		dir = path
		prefix = ""
	} else {
		dir = filepath.Dir(path)
		prefix = filepath.Base(path)
	}

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
		name := e.Name()
		filePrefix, _, _, ok := parseFrameName(name)
		if !ok {
			continue
		}
		if prefix != "" {
			if filePrefix != prefix && filePrefix != prefix+"_" && filePrefix != prefix+"-" {
				continue
			}
		}
		names = append(names, name)
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
		return nil, fmt.Errorf("no .png files found in %s with prefix %q", dir, prefix)
	}
	var frames [][]string
	warned := make(map[color.NRGBA]bool)
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

		// Scan all pixel colors for schema compatibility
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				c := img.At(bounds.Min.X+x, bounds.Min.Y+y)
				_, _, _, ca := c.RGBA()
				if ca > 0 {
					nrgba := color.NRGBAModel.Convert(c).(color.NRGBA)
					if !warned[nrgba] {
						// Check if there is an exact match in globalColors
						exact := false
						for _, gc := range globalColors {
							gcRGB := globalRGBs[gc.I]
							if gcRGB.R == nrgba.R && gcRGB.G == nrgba.G && gcRGB.B == nrgba.B {
								exact = true
								break
							}
						}
						if !exact {
							warned[nrgba] = true
							closest := closestSchemaColor(nrgba, globalColors)
							fmt.Fprintf(os.Stderr, "Warning: PNG pixel color #%02x%02x%02x in frame %s is not compatible with the schema, matching to closest color %q (index %d, hex %s)\n", nrgba.R, nrgba.G, nrgba.B, name, closest.Name, closest.I, closest.Hex)
						}
					}
				}
			}
		}

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

// loadFrames reads all *.png files from dir in sorted order and returns
// each file's pixel characters as lines of strings.
func loadFrames(dir string, priority []string, imgPal color.Palette) ([][]string, error) {
	return loadFramesFromPath(dir, priority, imgPal)
}

// ── main ─────────────────────────────────────────────────────────────────────

func main() {
	doPrint := len(os.Args) > 1 && os.Args[1] == "print"

	colorsData, err := os.ReadFile("spec/colors.json")
	if err != nil {
		fatalf("read spec/colors.json: %v", err)
	}
	var gColorsSpec GlobalColorsSpec
	if err := json.Unmarshal(colorsData, &gColorsSpec); err != nil {
		fatalf("parse spec/colors.json: %v", err)
	}
	globalColors = gColorsSpec.Colors
	for _, c := range globalColors {
		rgb, err := parseHexGo(c.Hex)
		if err != nil {
			fatalf("parse global hex color %q: %v", c.Hex, err)
		}
		globalRGBs[c.I] = rgb
	}

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
		// Determine frame shapes: from stack, frames_dir or inline shape.
		var shapeFrames [][]string // each element is one frame's shape rows
		if len(entry.Stack) > 0 {
			imgPal := buildImagePalette(spec.Priority, spec.Palette)
			var stackFrames [][][]string
			for _, item := range entry.Stack {
				frames, err := loadFramesFromPath(item.Path, spec.Priority, imgPal)
				if err != nil {
					fatalf("load stack frame %q for %q: %v", item.Path, entry.Name, err)
				}
				stackFrames = append(stackFrames, frames)
			}

			// Resolve target FPS
			targetFps := entry.Fps
			if targetFps == 0 {
				targetFps = 30
			}

			// Validate and calculate maxFrames using exact integer divisions/multiples.
			maxFrames := 0
			for k, frames := range stackFrames {
				itemFps := entry.Stack[k].Fps
				if itemFps == 0 {
					itemFps = targetFps
				}
				if targetFps%itemFps != 0 {
					fatalf("%q: target fps (%d) must be a multiple of stack item %q fps (%d)",
						entry.Name, targetFps, entry.Stack[k].Path, itemFps)
				}
				factor := targetFps / itemFps
				needed := len(frames) * factor
				if needed > maxFrames {
					maxFrames = needed
				}
			}

			maxWidth := 0
			for _, frames := range stackFrames {
				if len(frames) > 0 && len(frames[0]) > 0 {
					w := len([]rune(frames[0][0]))
					if w > maxWidth {
						maxWidth = w
					}
				}
			}

			shapeFrames = make([][]string, maxFrames)
			for i := 0; i < maxFrames; i++ {
				var combinedFrame []string
				for k, frames := range stackFrames {
					itemFps := entry.Stack[k].Fps
					if itemFps == 0 {
						itemFps = targetFps
					}
					// Map time/frame index concretely (target_fps % itemFps == 0)
					fIdx := (i * itemFps) / targetFps
					if fIdx >= len(frames) {
						fIdx = len(frames) - 1
					}
					frameRows := frames[fIdx]
					for _, row := range frameRows {
						rowRunes := []rune(row)
						if len(rowRunes) < maxWidth {
							paddingChar := spec.Priority[0]
							padded := string(rowRunes) + strings.Repeat(paddingChar, maxWidth-len(rowRunes))
							combinedFrame = append(combinedFrame, padded)
						} else {
							combinedFrame = append(combinedFrame, row)
						}
					}
				}
				shapeFrames[i] = combinedFrame
			}

			// Validate consistent dimensions across frames.
			if len(shapeFrames) > 0 {
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
			}
		} else if entry.FramesDir != "" {
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
			fatalf("%q: art entry has neither 'shape', 'frames_dir', nor 'stack'", entry.Name)
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
