// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Synchronizes .txt ↔ .png frame files for the emojig pixel art animation
// system. Reads spec/art.json for palette definitions, scans each art entry's
// frames_dir, and converts whichever side is newer.
// Run: go run ./scripts/sync_art_frames/

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
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

// parseFrameName splits a frame base name (like "sheet_0001" or "02") into
// its prefix (everything before the trailing digits), numeric value, and digit width.
func parseFrameName(base string) (prefix string, num int, width int, ok bool) {
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

type frameInfo struct {
	num     string // e.g. "sheet_0001" or "00"
	prefix  string // e.g. "sheet_" or ""
	numVal  int    // e.g. 1
	width   int    // e.g. 4
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
		prefix, numVal, width, ok := parseFrameName(base)
		if !ok {
			continue
		}
		switch ext {
		case ".txt":
			fi := getOrCreate(m, base, prefix, numVal, width)
			fi.txtPath = filepath.Join(dir, name)
		case ".png":
			fi := getOrCreate(m, base, prefix, numVal, width)
			fi.pngPath = filepath.Join(dir, name)
		}
	}

	var frames []frameInfo
	for _, fi := range m {
		frames = append(frames, *fi)
	}
	sort.Slice(frames, func(i, j int) bool {
		if frames[i].prefix != frames[j].prefix {
			return frames[i].prefix < frames[j].prefix
		}
		return frames[i].numVal < frames[j].numVal
	})
	return frames, nil
}

func getOrCreate(m map[string]*frameInfo, num string, prefix string, numVal int, width int) *frameInfo {
	if fi, ok := m[num]; ok {
		return fi
	}
	fi := &frameInfo{
		num:    num,
		prefix: prefix,
		numVal: numVal,
		width:  width,
	}
	m[num] = fi
	return fi
}

// ── main ─────────────────────────────────────────────────────────────────────

func main() {
	var rootCmd = &cobra.Command{
		Use:   "sync_art_frames",
		Short: "Synchronizes .txt ↔ .png frame files for emojig pixel art animations",
		Long:  `A utility to keep frame files in sync and perform frame insertions/deletions.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSync()
		},
	}

	var syncCmd = &cobra.Command{
		Use:   "sync",
		Short: "Sync .txt ↔ .png frames (default)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSync()
		},
	}

	var insertCmd = &cobra.Command{
		Use:   "insert [pos]",
		Short: "Insert a new frame at pos by duplicating the frame",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			pos, err := strconv.Atoi(args[0])
			if err != nil || pos < 0 {
				return fmt.Errorf("invalid position: %s", args[0])
			}
			return runInsert(pos)
		},
	}

	var deleteCmd = &cobra.Command{
		Use:   "delete [pos]",
		Short: "Delete a frame at pos",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			pos, err := strconv.Atoi(args[0])
			if err != nil || pos < 0 {
				return fmt.Errorf("invalid position: %s", args[0])
			}
			return runDelete(pos)
		},
	}

	rootCmd.AddCommand(syncCmd, insertCmd, deleteCmd)

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

// ── helper: file copy ────────────────────────────────────────────────────────

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

// ── helper: delays parser ────────────────────────────────────────────────────

func findDelaysBoundsForDir(data []byte, dir string) (start, end int, err error) {
	dirBytes := []byte(dir)
	dirIdx := bytes.Index(data, dirBytes)
	if dirIdx < 0 {
		return 0, 0, fmt.Errorf("could not find directory %q in art.json", dir)
	}

	objStart := -1
	braceCount := 0
	for i := dirIdx; i >= 0; i-- {
		if data[i] == '}' {
			braceCount++
		} else if data[i] == '{' {
			if braceCount == 0 {
				objStart = i
				break
			}
			braceCount--
		}
	}
	if objStart < 0 {
		return 0, 0, fmt.Errorf("could not find containing '{' for directory %q", dir)
	}

	objEnd := -1
	braceCount = 0
	for i := dirIdx; i < len(data); i++ {
		if data[i] == '{' {
			braceCount++
		} else if data[i] == '}' {
			if braceCount == 0 {
				objEnd = i + 1
				break
			}
			braceCount--
		}
	}
	if objEnd < 0 {
		return 0, 0, fmt.Errorf("could not find containing '}' for directory %q", dir)
	}

	objData := data[objStart:objEnd]
	keyBytes := []byte(`"delays_ms"`)
	keyIdx := bytes.Index(objData, keyBytes)
	if keyIdx < 0 {
		return 0, 0, fmt.Errorf("could not find \"delays_ms\" in the art entry for %q", dir)
	}

	searchStart := keyIdx + len(keyBytes)
	colonIdx := bytes.IndexByte(objData[searchStart:], ':')
	if colonIdx < 0 {
		return 0, 0, fmt.Errorf("could not find colon after \"delays_ms\" for %q", dir)
	}
	valStart := objStart + searchStart + colonIdx + 1
	for valStart < len(data) && (data[valStart] == ' ' || data[valStart] == '\t' || data[valStart] == '\n' || data[valStart] == '\r') {
		valStart++
	}
	if valStart >= len(data) || data[valStart] != '[' {
		return 0, 0, fmt.Errorf("expected '[' after \"delays_ms\" for %q", dir)
	}

	bracketCount := 0
	for i := valStart; i < len(data); i++ {
		if data[i] == '[' {
			bracketCount++
		} else if data[i] == ']' {
			bracketCount--
			if bracketCount == 0 {
				return valStart, i + 1, nil
			}
		}
	}

	return 0, 0, fmt.Errorf("could not find matching ']' for delays_ms array of %q", dir)
}

func updateDelays(dir string, op string, pos int, minNumVal int) error {
	artJsonPath := "spec/art.json"
	data, err := os.ReadFile(artJsonPath)
	if err != nil {
		return fmt.Errorf("read art.json: %w", err)
	}

	start, end, err := findDelaysBoundsForDir(data, dir)
	if err != nil {
		return err
	}

	var delays []int
	if err := json.Unmarshal(data[start:end], &delays); err != nil {
		return fmt.Errorf("parse delays: %w", err)
	}

	idx := pos - minNumVal

	if op == "insert" {
		if idx < 0 || idx >= len(delays) {
			return fmt.Errorf("index %d (pos %d, min %d) out of bounds for delays of length %d", idx, pos, minNumVal, len(delays))
		}
		val := delays[idx]
		newDelays := make([]int, len(delays)+1)
		copy(newDelays[:idx+1], delays[:idx+1])
		newDelays[idx+1] = val
		copy(newDelays[idx+2:], delays[idx+1:])
		delays = newDelays
	} else if op == "delete" {
		if idx < 0 || idx >= len(delays) {
			return fmt.Errorf("index %d (pos %d, min %d) out of bounds for delays of length %d", idx, pos, minNumVal, len(delays))
		}
		delays = append(delays[:idx], delays[idx+1:]...)
	}

	newVal, err := json.Marshal(delays)
	if err != nil {
		return fmt.Errorf("marshal delays: %w", err)
	}

	newData := make([]byte, 0, len(data)-(end-start)+len(newVal))
	newData = append(newData, data[:start]...)
	newData = append(newData, newVal...)
	newData = append(newData, data[end:]...)

	return os.WriteFile(artJsonPath, newData, 0644)
}

// ── helper: run gen_about_art ──────────────────────────────────────────────

func runGenAboutArt() {
	cmd := exec.Command("go", "run", "./scripts/gen_about_art/")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Run()
}

// ── command runners ──────────────────────────────────────────────────────────

func runSync() error {
	artData, err := os.ReadFile("spec/art.json")
	if err != nil {
		return fmt.Errorf("read spec/art.json: %w", err)
	}
	artInfo, err := os.Stat("spec/art.json")
	if err != nil {
		return fmt.Errorf("stat spec/art.json: %w", err)
	}

	var raw rawArtSpec
	if err := json.Unmarshal(artData, &raw); err != nil {
		return fmt.Errorf("parse spec/art.json: %w", err)
	}
	pal, err := resolvePalette(raw.Palette, raw.Colors)
	if err != nil {
		return fmt.Errorf("resolve palette: %w", err)
	}

	imgPal, charToIdx := buildImagePalette(raw.Priority, pal)

	hadWork := false
	for _, entry := range raw.Art {
		dir := entry.FramesDir
		if dir == "" {
			continue
		}

		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", dir, err)
		}

		frames, err := scanFrames(dir)
		if err != nil {
			return fmt.Errorf("scan %s: %w", dir, err)
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
				return fmt.Errorf("sync %s frame %s: %w", dir, fr.num, err)
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
	_ = hadWork
	return nil
}

func runInsert(pos int) error {
	// 1. runs sync to ensure we do not mess up file dates
	if err := runSync(); err != nil {
		return fmt.Errorf("sync failed before insert: %w", err)
	}

	artData, err := os.ReadFile("spec/art.json")
	if err != nil {
		return fmt.Errorf("read spec/art.json: %w", err)
	}
	var raw rawArtSpec
	if err := json.Unmarshal(artData, &raw); err != nil {
		return fmt.Errorf("parse spec/art.json: %w", err)
	}

	for _, entry := range raw.Art {
		dir := entry.FramesDir
		if dir == "" {
			continue
		}

		frames, err := scanFrames(dir)
		if err != nil {
			return fmt.Errorf("scan %s: %w", dir, err)
		}

		if len(frames) == 0 {
			continue
		}

		minNumVal := frames[0].numVal
		maxNumVal := frames[len(frames)-1].numVal
		if pos < minNumVal || pos > maxNumVal {
			return fmt.Errorf("position %d out of bounds [%d, %d] in %s", pos, minNumVal, maxNumVal, dir)
		}

		// 2. moves pos+1 and consecutive files to pos+2
		for i := len(frames) - 1; i >= 0; i-- {
			if frames[i].numVal >= pos+1 {
				newNum := fmt.Sprintf("%s%0*d", frames[i].prefix, frames[i].width, frames[i].numVal+1)

				if frames[i].txtPath != "" {
					oldPath := frames[i].txtPath
					newPath := filepath.Join(dir, newNum+".txt")
					if err := os.Rename(oldPath, newPath); err != nil {
						return fmt.Errorf("rename %s -> %s: %w", oldPath, newPath, err)
					}
				}
				if frames[i].pngPath != "" {
					oldPath := frames[i].pngPath
					newPath := filepath.Join(dir, newNum+".png")
					if err := os.Rename(oldPath, newPath); err != nil {
						return fmt.Errorf("rename %s -> %s: %w", oldPath, newPath, err)
					}
				}
			}
		}

		// 3. copies pos as pos+1
		var posFrame *frameInfo
		for i := range frames {
			if frames[i].numVal == pos {
				posFrame = &frames[i]
				break
			}
		}
		if posFrame == nil {
			return fmt.Errorf("frame at position %d not found in %s", pos, dir)
		}

		nextStr := fmt.Sprintf("%s%0*d", posFrame.prefix, posFrame.width, pos+1)

		if posFrame.txtPath != "" {
			src := posFrame.txtPath
			dst := filepath.Join(dir, nextStr+".txt")
			if err := copyFile(src, dst); err != nil {
				return fmt.Errorf("copy %s -> %s: %w", src, dst, err)
			}
		}
		if posFrame.pngPath != "" {
			src := posFrame.pngPath
			dst := filepath.Join(dir, nextStr+".png")
			if err := copyFile(src, dst); err != nil {
				return fmt.Errorf("copy %s -> %s: %w", src, dst, err)
			}
		}

		// Update delays in art.json
		if err := updateDelays(dir, "insert", pos, minNumVal); err != nil {
			return fmt.Errorf("update delays: %w", err)
		}

		fmt.Printf("inserted frame at position %d (duplicated to %d) in %s\n", pos, pos+1, dir)
	}

	// 4. runs -> runs sync again at the end to finalize dates
	if err := runSync(); err != nil {
		return fmt.Errorf("final sync failed: %w", err)
	}

	// and runs the generation to keep strings.json in sync
	runGenAboutArt()
	return nil
}

func runDelete(pos int) error {
	artData, err := os.ReadFile("spec/art.json")
	if err != nil {
		return fmt.Errorf("read spec/art.json: %w", err)
	}
	var raw rawArtSpec
	if err := json.Unmarshal(artData, &raw); err != nil {
		return fmt.Errorf("parse spec/art.json: %w", err)
	}

	for _, entry := range raw.Art {
		dir := entry.FramesDir
		if dir == "" {
			continue
		}

		frames, err := scanFrames(dir)
		if err != nil {
			return fmt.Errorf("scan %s: %w", dir, err)
		}

		if len(frames) == 0 {
			continue
		}

		minNumVal := frames[0].numVal
		maxNumVal := frames[len(frames)-1].numVal
		if pos < minNumVal || pos > maxNumVal {
			return fmt.Errorf("position %d out of bounds [%d, %d] in %s", pos, minNumVal, maxNumVal, dir)
		}

		// 1. deletes pos
		for _, fr := range frames {
			if fr.numVal == pos {
				if fr.txtPath != "" {
					if err := os.Remove(fr.txtPath); err != nil {
						return fmt.Errorf("remove %s: %w", fr.txtPath, err)
					}
				}
				if fr.pngPath != "" {
					if err := os.Remove(fr.pngPath); err != nil {
						return fmt.Errorf("remove %s: %w", fr.pngPath, err)
					}
				}
				break
			}
		}

		// 2. moves pos+1 to pos
		for i := 0; i < len(frames); i++ {
			if frames[i].numVal >= pos+1 {
				newNum := fmt.Sprintf("%s%0*d", frames[i].prefix, frames[i].width, frames[i].numVal-1)

				if frames[i].txtPath != "" {
					oldPath := frames[i].txtPath
					newPath := filepath.Join(dir, newNum+".txt")
					if err := os.Rename(oldPath, newPath); err != nil {
						return fmt.Errorf("rename %s -> %s: %w", oldPath, newPath, err)
					}
				}
				if frames[i].pngPath != "" {
					oldPath := frames[i].pngPath
					newPath := filepath.Join(dir, newNum+".png")
					if err := os.Rename(oldPath, newPath); err != nil {
						return fmt.Errorf("rename %s -> %s: %w", oldPath, newPath, err)
					}
				}
			}
		}

		// Update delays in art.json
		if err := updateDelays(dir, "delete", pos, minNumVal); err != nil {
			return fmt.Errorf("update delays: %w", err)
		}

		fmt.Printf("deleted frame at position %d in %s\n", pos, dir)
	}

	// runs sync at the end to settle dates
	if err := runSync(); err != nil {
		return fmt.Errorf("final sync failed: %w", err)
	}

	// and runs the generation to keep strings.json in sync
	runGenAboutArt()
	return nil
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
