// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Synchronizes .txt ↔ .png frame files for the emojig pixel art animation
// system. Reads spec/art.json for palette definitions, scans each art entry's
// frames_dir, and converts whichever side is newer.
// Run: go run ./scripts/sync_art_frames/

package main

import (
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ── JSON shapes ──────────────────────────────────────────────────────────────

type rawArtSpec struct {
	Colors   map[string]int             `json:"colors"`
	Palette  map[string]json.RawMessage `json:"palette"`
	Priority []string                   `json:"priority"`
	Art      []ArtEntry                 `json:"art"`
}

type ArtEntry struct {
	Name      string   `json:"name"`
	Target    string   `json:"target"`
	Mode      string   `json:"mode"`
	Spaced    bool     `json:"spaced"`
	Indent    string   `json:"indent"`
	Header    []string `json:"header"`
	Footer    []string `json:"footer"`
	Shape     []string `json:"shape"`
	FramesDir string   `json:"frames_dir"`
	Scratch   []string `json:"scratch"`
}

// resolvedPalette maps palette chars → *int (256-color index), nil = transparent.
type resolvedPalette map[string]*int

func resolvePalette(raw map[string]json.RawMessage, colors map[string]int) (resolvedPalette, error) {
	out := make(resolvedPalette, len(raw))
	for k, v := range raw {
		if string(v) == "null" {
			out[k] = nil
			continue
		}
		var num int
		if err := json.Unmarshal(v, &num); err == nil {
			n := num
			out[k] = &n
			continue
		}
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

// ── 256-color → RGB mapping ──────────────────────────────────────────────────

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

// ── palette → image.Palette construction ─────────────────────────────────────

// buildImagePalette creates an indexed color.Palette following priority order.
// Returns the palette and a map from priority-char → palette-index.
func buildImagePalette(priority []string, pal resolvedPalette) (color.Palette, map[string]int) {
	imgPal := make(color.Palette, len(priority))
	charToIdx := make(map[string]int, len(priority))
	for i, ch := range priority {
		charToIdx[ch] = i
		colPtr := pal[ch]
		if colPtr == nil {
			imgPal[i] = color.NRGBA{0, 0, 0, 0} // transparent
		} else {
			imgPal[i] = idx256ToRGB(*colPtr)
		}
	}
	return imgPal, charToIdx
}

// ── txt → png ────────────────────────────────────────────────────────────────

func txtToPNG(txtPath, pngPath string, priority []string, charToIdx map[string]int, imgPal color.Palette) error {
	data, err := os.ReadFile(txtPath)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) == 0 {
		return fmt.Errorf("empty txt file: %s", txtPath)
	}

	// determine grid width from the longest line (by rune count)
	maxW := 0
	for _, line := range lines {
		runes := []rune(line)
		if len(runes) > maxW {
			maxW = len(runes)
		}
	}

	img := image.NewPaletted(image.Rect(0, 0, maxW, len(lines)), imgPal)
	for y, line := range lines {
		runes := []rune(line)
		for x := 0; x < maxW; x++ {
			idx := 0 // default: first priority entry (transparent)
			if x < len(runes) {
				ch := string(runes[x])
				if i, ok := charToIdx[ch]; ok {
					idx = i
				}
			}
			img.SetColorIndex(x, y, uint8(idx))
		}
	}

	f, err := os.Create(pngPath)
	if err != nil {
		return err
	}
	defer f.Close()
	return png.Encode(f, img)
}

// ── png → txt ────────────────────────────────────────────────────────────────

func pngToTxt(pngPath, txtPath string, priority []string, imgPal color.Palette, pal resolvedPalette) error {
	// Read existing txt if it exists, to preserve transparent guide characters like '-' and '_'
	var origLines [][]rune
	if txtData, err := os.ReadFile(txtPath); err == nil {
		for _, line := range strings.Split(strings.TrimRight(string(txtData), "\n"), "\n") {
			origLines = append(origLines, []rune(line))
		}
	}

	f, err := os.Open(pngPath)
	if err != nil {
		return err
	}
	defer f.Close()

	img, err := png.Decode(f)
	if err != nil {
		return err
	}

	bounds := img.Bounds()
	w, h := bounds.Dx(), bounds.Dy()

	var sb strings.Builder
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := img.At(bounds.Min.X+x, bounds.Min.Y+y)
			_, _, _, ca := c.RGBA()
			if ca == 0 && y < len(origLines) && x < len(origLines[y]) {
				origChar := string(origLines[y][x])
				if val, exists := pal[origChar]; exists && val == nil {
					sb.WriteString(origChar)
					continue
				}
			}

			idx := closestPaletteIndex(c, imgPal)
			if idx < len(priority) {
				sb.WriteString(priority[idx])
			} else {
				sb.WriteString(priority[0])
			}
		}
		sb.WriteByte('\n')
	}

	return os.WriteFile(txtPath, []byte(sb.String()), 0o644)
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

// ── frame scanning & syncing ─────────────────────────────────────────────────

type frameInfo struct {
	num     string // e.g. "00", "01"
	txtPath string
	pngPath string
}

// scanFrames discovers .txt and .png files in dir and groups them by frame number.
func scanFrames(dir string) ([]frameInfo, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	m := map[string]*frameInfo{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		ext := filepath.Ext(name)
		base := strings.TrimSuffix(name, ext)
		switch ext {
		case ".txt":
			fi := getOrCreate(m, base)
			fi.txtPath = filepath.Join(dir, name)
		case ".png":
			fi := getOrCreate(m, base)
			fi.pngPath = filepath.Join(dir, name)
		}
	}

	var frames []frameInfo
	for _, fi := range m {
		frames = append(frames, *fi)
	}
	sort.Slice(frames, func(i, j int) bool { return frames[i].num < frames[j].num })
	return frames, nil
}

func getOrCreate(m map[string]*frameInfo, num string) *frameInfo {
	if fi, ok := m[num]; ok {
		return fi
	}
	fi := &frameInfo{num: num}
	m[num] = fi
	return fi
}

// ── main ─────────────────────────────────────────────────────────────────────

func main() {
	artData, err := os.ReadFile("spec/art.json")
	if err != nil {
		fatalf("read spec/art.json: %v", err)
	}
	artInfo, err := os.Stat("spec/art.json")
	if err != nil {
		fatalf("stat spec/art.json: %v", err)
	}

	var raw rawArtSpec
	if err := json.Unmarshal(artData, &raw); err != nil {
		fatalf("parse spec/art.json: %v", err)
	}
	pal, err := resolvePalette(raw.Palette, raw.Colors)
	if err != nil {
		fatalf("resolve palette: %v", err)
	}

	imgPal, charToIdx := buildImagePalette(raw.Priority, pal)

	hadWork := false
	for _, entry := range raw.Art {
		dir := entry.FramesDir
		if dir == "" {
			continue
		}

		// ensure the directory exists
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fatalf("mkdir %s: %v", dir, err)
		}

		frames, err := scanFrames(dir)
		if err != nil {
			fatalf("scan %s: %v", dir, err)
		}

		if len(frames) == 0 {
			fmt.Printf("%s: no frames found\n", dir)
			continue
		}

		artModTime := artInfo.ModTime()
		synced := false

		for _, fr := range frames {
			action, err := syncFrame(fr, dir, raw.Priority, charToIdx, imgPal, artModTime, pal)
			if err != nil {
				fatalf("sync %s frame %s: %v", dir, fr.num, err)
			}
			if action != "" {
				fmt.Println(action)
				synced = true
				hadWork = true
			}
		}
		if !synced {
			fmt.Printf("%s: up to date\n", dir)
		}
	}
	if !hadWork {
		// all entries were either skipped (no frames_dir) or up to date
		// individual messages already printed above
	}
}

// syncFrame decides what to do for a single frame and executes it.
// Returns a human-readable action string, or "" if nothing was done.
func syncFrame(fr frameInfo, dir string, priority []string, charToIdx map[string]int, imgPal color.Palette, artModTime time.Time, pal resolvedPalette) (string, error) {
	hasTxt := fr.txtPath != ""
	hasPng := fr.pngPath != ""

	switch {
	case hasTxt && !hasPng:
		// txt only → generate png
		pngPath := filepath.Join(dir, fr.num+".png")
		if err := txtToPNG(fr.txtPath, pngPath, priority, charToIdx, imgPal); err != nil {
			return "", err
		}
		return fmt.Sprintf("synced %s%s.txt → %s.png", dir, fr.num, fr.num), nil

	case hasPng && !hasTxt:
		// png only → generate txt
		txtPath := filepath.Join(dir, fr.num+".txt")
		if err := pngToTxt(fr.pngPath, txtPath, priority, imgPal, pal); err != nil {
			return "", err
		}
		return fmt.Sprintf("synced %s%s.png → %s.txt", dir, fr.num, fr.num), nil

	case hasTxt && hasPng:
		txtInfo, err := os.Stat(fr.txtPath)
		if err != nil {
			return "", err
		}
		pngInfo, err := os.Stat(fr.pngPath)
		if err != nil {
			return "", err
		}

		// If art.json is newer than the PNG, regenerate PNG (palette may have changed).
		if artModTime.After(pngInfo.ModTime()) {
			if err := txtToPNG(fr.txtPath, fr.pngPath, priority, charToIdx, imgPal); err != nil {
				return "", err
			}
			return fmt.Sprintf("synced %s%s.txt → %s.png (palette changed)", dir, fr.num, fr.num), nil
		}

		// Otherwise, newer file wins.
		if txtInfo.ModTime().After(pngInfo.ModTime()) {
			if err := txtToPNG(fr.txtPath, fr.pngPath, priority, charToIdx, imgPal); err != nil {
				return "", err
			}
			return fmt.Sprintf("synced %s%s.txt → %s.png", dir, fr.num, fr.num), nil
		}
		if pngInfo.ModTime().After(txtInfo.ModTime()) {
			if err := pngToTxt(fr.pngPath, fr.txtPath, priority, imgPal, pal); err != nil {
				return "", err
			}
			return fmt.Sprintf("synced %s%s.png → %s.txt", dir, fr.num, fr.num), nil
		}
		// Same mod time → nothing to do.
		return "", nil
	}
	return "", nil
}

func fatalf(f string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+f+"\n", args...)
	os.Exit(1)
}
