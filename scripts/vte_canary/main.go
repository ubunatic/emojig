// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"flag"
	"fmt"
	"image"
	_ "image/png"
	"os"
	"strings"
	"unicode/utf8"
)

// List of 4x4 test emojis containing standard emojis and BMP symbols. Kept
// as an all-passing baseline (see knownIssueEmojis below for the currently
// broken case) so `make canary-shots`/`make canary` stay green as a build
// gate — a canary that's permanently red for a known, not-yet-fixed issue
// blocks unrelated work, same reasoning as issue 52 excluding ptyxis from
// this target while keeping its reel file runnable standalone.
var sampleEmojis = []string{
	"🌧️", "🌦️", "🌈", "☔", // Row 1 (contains ☔ U+2614)
	"☕", "⚡", "⚓", "⚽", // Row 2 (contains ☕ U+2615, ⚡ U+26A1, ⚓ U+2693, ⚽ U+26BD)
	"⛄", "⛵", "⛺", "⛽", // Row 3 (contains ⛄ U+26C4, ⛵ U+26F5, ⛺ U+26FA, ⛽ U+26FD)
	"✨", "❌", "❓", "🚀", // Row 4 (contains ✨ U+2728, ❌ U+274C, ❓ U+2753, 🚀 U+1F680)
}

// knownIssueEmojis reproduces issue 57's confirmed root cause: ☺️
// (U+263A + VS16, "smiling face") next to its ☺︎ VS15 "plain twin".
// src/search.zig's getEmojiWidth() assumes any VS16 glyph is width 2
// regardless of whether the base codepoint is East-Asian-Wide; U+263A
// isn't, so per-codepoint-summation terminals (and, confirmed via this
// exact grid, foot 1.27.0 even with issue 53's tweaks set) render it as
// width 1 — one column short. Not wired into `-s`/`make canary-shots` (see
// sampleEmojis above); run manually with `-known-issue-57` to reproduce,
// or swap it into sampleEmojis and re-add it to the make target once
// issue 53/57's underlying fix lands, to turn this into a real regression
// guard.
var knownIssueEmojis = []string{
	"🌧️", "🌦️", "🌈", "☔",
	"☕", "⚡", "⚓", "⚽",
	"⛄", "⛵", "⛺", "⛽",
	"✨", "☺️", "☺︎", "🚀", // issue 57: ☺️ U+263A+VS16 vs. its ☺︎ VS15 twin
}

// canaryColors is the single source of truth for the row pattern colors:
// renderGrid emits them as ANSI truecolor backgrounds, and -verify checks
// a (wayreel crop_colors-cropped) screenshot for the same pure RGB values.
// Pure RGB values let a wayreel reel target them directly via the "rgb"/"y"
// combo tokens in crop_colors, instead of needing per-shot hex overrides.
var canaryColors = []struct {
	Name    string
	R, G, B uint8
	Fg      string
}{
	{"red", 255, 0, 0, "\x1b[38;2;255;255;255m"},
	{"green", 0, 255, 0, "\x1b[38;2;0;0;0m"},
	{"blue", 0, 0, 255, "\x1b[38;2;255;255;255m"},
	{"yellow", 255, 255, 0, "\x1b[38;2;0;0;0m"},
}

// isVteTerminal checks environment variables to detect VTE-based terminals (Tilix, GNOME Terminal, Ptyxis).
func isVteTerminal() (bool, string) {
	if id := os.Getenv("TILIX_ID"); id != "" {
		return true, fmt.Sprintf("Tilix (TILIX_ID=%s)", id)
	}
	if ver := os.Getenv("VTE_VERSION"); ver != "" {
		return true, fmt.Sprintf("VTE Terminal (VTE_VERSION=%s)", ver)
	}
	term := strings.ToLower(os.Getenv("TERM"))
	terminal := strings.ToLower(os.Getenv("TERMINAL"))
	if strings.Contains(term, "vte") || strings.Contains(terminal, "tilix") || strings.Contains(terminal, "gnome") {
		return true, fmt.Sprintf("VTE (TERM=%s, TERMINAL=%s)", term, terminal)
	}
	if term != "" {
		return false, fmt.Sprintf("Modern/Non-VTE (TERM=%s)", term)
	}
	return false, "Modern/Non-VTE (Default)"
}

// isAmbiguousBmpSymbol returns true for emojis that glibc/VTE wcwidth()
// reports as single-width (width=1) in standard Linux UTF-8 locales
// (e.g. U+1F324..U+1F329 weather emojis: 🌤, 🌥, 🌦, 🌧, 🌨, 🌩).
func isAmbiguousBmpSymbol(emoji string) bool {
	r, _ := utf8.DecodeRuneInString(emoji)
	if r >= 0x1F324 && r <= 0x1F329 {
		return true
	}
	return false
}

func ensureVS16(emoji string) string {
	if strings.Contains(emoji, "\ufe0f") || strings.Contains(emoji, "\ufe0e") {
		return emoji
	}
	r, _ := utf8.DecodeRuneInString(emoji)
	if (r >= 0x2600 && r <= 0x26FF) || (r >= 0x2700 && r <= 0x27BF) {
		return emoji + "\ufe0f"
	}
	return emoji
}

func renderGrid(cols, rows int, compensate, vs16Mode, isAuto, silent bool) {
	reset := "\x1b[0m"
	scrollbar := "\x1b[48;5;236m\x1b[38;5;248m▐\x1b[0m"

	targetContentWidth := cols * 4

	if !silent {
		isVte, termDesc := isVteTerminal()
		modeStr := "OFF (Unpadded)"
		if vs16Mode {
			modeStr = "VS16 Mode (Appends \\uFE0F to BMP symbols)"
		} else if isAuto {
			if isVte {
				modeStr = fmt.Sprintf("AUTO -> VTE Mode (Padded weather symbols for %s)", termDesc)
			} else {
				modeStr = fmt.Sprintf("AUTO -> Modern Engine Mode (Unpadded for %s)", termDesc)
			}
		} else if compensate {
			modeStr = "ON (Padded +1 space)"
		}
		fmt.Fprintf(os.Stderr, "=== VTE Grid Canary (Color Test Pattern) ===\n")
		fmt.Fprintf(os.Stderr, "Terminal: %s\n", termDesc)
		fmt.Fprintf(os.Stderr, "Mode:     %s\n", modeStr)
		fmt.Fprintf(os.Stderr, "Grid:     %dx%d (%d columns wide)\n\n", cols, rows, targetContentWidth)
	}

	for r := 0; r < rows; r++ {
		var rowBuf strings.Builder
		cc := canaryColors[r%len(canaryColors)]
		rowBuf.WriteString(fmt.Sprintf("\x1b[48;2;%d;%d;%dm%s", cc.R, cc.G, cc.B, cc.Fg))
		rowBuf.WriteString(" ") // 1-space left margin

		for c := 0; c < cols; c++ {
			idx := r*cols + c
			emoji := "  "
			if idx < len(sampleEmojis) {
				emoji = sampleEmojis[idx]
			}
			if vs16Mode {
				emoji = ensureVS16(emoji)
			}

			// Render standard 4-char cell: " <emoji> " or " <emoji>  " if compensated
			if compensate && isAmbiguousBmpSymbol(emoji) {
				rowBuf.WriteString(fmt.Sprintf(" %s  ", emoji))
			} else {
				rowBuf.WriteString(fmt.Sprintf(" %s ", emoji))
			}
		}

		rowBuf.WriteString(reset)
		rowBuf.WriteString(scrollbar)
		fmt.Fprintln(os.Stdout, rowBuf.String())
	}

	if !silent {
		fmt.Fprintf(os.Stderr, "\nCheck right border (▐):\n")
		if compensate {
			fmt.Fprintf(os.Stderr, "  ✅ Weather symbol compensation active (+1 space for U+1F324..1F329).\n\n")
		} else {
			fmt.Fprintf(os.Stderr, "  ✅ Unpadded grid active (standard 4-char cells).\n\n")
		}
	}
}

// minColorCoverage is the minimum fraction of pixels a canary color must
// cover in a crop_colors-cropped screenshot to count as "rendered". The crop
// already bounds the image tightly to the 4-row grid, so each color should
// cover roughly a quarter of the pixels; 5% leaves headroom for emoji
// glyphs/text eating into a row's background while still catching a row
// that failed to render (e.g. a terminal falling back from truecolor).
const minColorCoverage = 0.05

// verifyCrop decodes the PNG at path (expected to already be cropped to the
// canary color region via wayreel's crop_colors) and checks that every
// canaryColors entry covers at least minColorCoverage of the pixels.
func verifyCrop(path string) (bool, string) {
	f, err := os.Open(path)
	if err != nil {
		return false, fmt.Sprintf("cannot open %s: %v", path, err)
	}
	defer f.Close()

	img, _, err := image.Decode(f)
	if err != nil {
		return false, fmt.Sprintf("cannot decode %s: %v", path, err)
	}

	bounds := img.Bounds()
	counts := make([]int, len(canaryColors))
	total := 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			total++
			r, g, b, _ := img.At(x, y).RGBA()
			r8, g8, b8 := uint8(r>>8), uint8(g>>8), uint8(b>>8)
			for i, cc := range canaryColors {
				if r8 == cc.R && g8 == cc.G && b8 == cc.B {
					counts[i]++
					break
				}
			}
		}
	}

	minCount := int(float64(total) * minColorCoverage)
	var missing []string
	for i, cc := range canaryColors {
		if counts[i] < minCount {
			missing = append(missing, fmt.Sprintf("%s (%d/%d px)", cc.Name, counts[i], minCount))
		}
	}
	if len(missing) > 0 {
		return false, fmt.Sprintf("FAILED: colors below %.0f%% coverage: %s", minColorCoverage*100, strings.Join(missing, ", "))
	}
	return true, fmt.Sprintf("PASSED: all %d colors present (%d px sampled)", len(canaryColors), total)
}

// maxRowEdgeSkew is the max allowed difference, in pixels, between the
// rightmost extent of any two canary color rows before it counts as a real
// row-length mismatch rather than antialiasing/glyph-edge noise.
const maxRowEdgeSkew = 1

// verifyRowLengths decodes the PNG at path (cropped via wayreel crop_colors
// to the bounding box of the 4 canary colors only, not the grey scrollbar)
// and checks that every color row's own rightmost matching pixel reaches the
// same x as the others. A terminal that renders an ambiguous-width glyph
// (e.g. a ☔-class weather symbol) as single-width when the app assumed
// double-width leaves that row's color band short of the image's right edge
// — a real, visible row-length mismatch like the one in issue vte_canary
// weather-symbol compensation.
func verifyRowLengths(path string) (bool, string) {
	f, err := os.Open(path)
	if err != nil {
		return false, fmt.Sprintf("cannot open %s: %v", path, err)
	}
	defer f.Close()

	img, _, err := image.Decode(f)
	if err != nil {
		return false, fmt.Sprintf("cannot decode %s: %v", path, err)
	}

	bounds := img.Bounds()
	rightEdge := make([]int, len(canaryColors))
	for i := range rightEdge {
		rightEdge[i] = -1
	}

	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			r, g, b, _ := img.At(x, y).RGBA()
			r8, g8, b8 := uint8(r>>8), uint8(g>>8), uint8(b>>8)
			for i, cc := range canaryColors {
				if r8 == cc.R && g8 == cc.G && b8 == cc.B && x > rightEdge[i] {
					rightEdge[i] = x
				}
			}
		}
	}

	maxEdge := 0
	for _, e := range rightEdge {
		if e > maxEdge {
			maxEdge = e
		}
	}

	var short []string
	for i, cc := range canaryColors {
		if rightEdge[i] < 0 {
			short = append(short, fmt.Sprintf("%s (not found)", cc.Name))
			continue
		}
		if maxEdge-rightEdge[i] > maxRowEdgeSkew {
			short = append(short, fmt.Sprintf("%s (right edge x=%d, %dpx short of x=%d)", cc.Name, rightEdge[i], maxEdge-rightEdge[i], maxEdge))
		}
	}
	if len(short) > 0 {
		return false, fmt.Sprintf("FAILED: row length mismatch — %s", strings.Join(short, ", "))
	}
	return true, fmt.Sprintf("PASSED: all %d rows reach the same right edge (x=%d)", len(canaryColors), maxEdge)
}

func main() {
	var (
		autoMode     bool
		compensate   bool
		vs16Mode     bool
		both         bool
		silent       bool
		verifyPath   string
		verifyRows   string
		cols         int
		rows         int
		knownIssue57 bool
	)

	flag.StringVar(&verifyPath, "verify", "", "Verify a wayreel crop_colors-cropped canary screenshot PNG contains all 4 test pattern colors")
	flag.StringVar(&verifyRows, "verify-rows", "", "Verify a wayreel crop_colors-cropped canary screenshot PNG has all 4 rows reaching the same right edge (no ambiguous-width row-length mismatch)")

	flag.BoolVar(&autoMode, "auto", false, "Auto-detect terminal environment (VTE vs Modern foot/ghostty)")
	flag.BoolVar(&autoMode, "a", false, "Alias for -auto")

	flag.BoolVar(&compensate, "compensate", false, "Force compensation for single-width VTE weather symbols (+1 space)")
	flag.BoolVar(&compensate, "c", false, "Alias for -compensate")

	flag.BoolVar(&vs16Mode, "vs16", false, "Append VS16 (\\uFE0F) to force emoji presentation on BMP symbols")
	flag.BoolVar(&vs16Mode, "v", false, "Alias for -vs16")

	flag.BoolVar(&both, "both", false, "Print both unpadded and padded grid variants sequentially")
	flag.BoolVar(&both, "b", false, "Alias for -both")

	flag.BoolVar(&silent, "silent", false, "Suppress all stderr info messages (outputs grid rows only)")
	flag.BoolVar(&silent, "s", false, "Alias for -silent")

	flag.IntVar(&cols, "cols", 4, "Number of grid columns")
	flag.IntVar(&cols, "w", 4, "Alias for -cols")

	flag.IntVar(&rows, "rows", 4, "Number of grid rows")
	flag.IntVar(&rows, "r", 4, "Alias for -rows")

	flag.BoolVar(&knownIssue57, "known-issue-57", false, "Reproduce issue 57's confirmed row-length regression (swaps in knownIssueEmojis) instead of the passing default grid")

	flag.Parse()

	if knownIssue57 {
		sampleEmojis = knownIssueEmojis
	}

	if verifyPath != "" || verifyRows != "" {
		passed := true
		if verifyPath != "" {
			ok, msg := verifyCrop(verifyPath)
			fmt.Fprintln(os.Stderr, msg)
			if !ok {
				passed = false
			}
		}
		if verifyRows != "" {
			ok, msg := verifyRowLengths(verifyRows)
			fmt.Fprintln(os.Stderr, msg)
			if !ok {
				passed = false
			}
		}
		if !passed {
			os.Exit(1)
		}
		return
	}

	// Default to -auto mode if no explicit mode flags are passed
	if !autoMode && !compensate && !vs16Mode && !both {
		autoMode = true
	}

	if autoMode && !both {
		isVte, _ := isVteTerminal()
		renderGrid(cols, rows, isVte, false, true, silent)
		return
	}

	if both {
		if !silent {
			fmt.Fprintln(os.Stderr, "--- Variant 1: Unpadded (Standard) ---")
		}
		renderGrid(cols, rows, false, false, false, silent)

		if !silent {
			fmt.Fprintln(os.Stderr, "--- Variant 2: Padded (Compensated) ---")
		} else {
			fmt.Fprintln(os.Stdout, "") // separator between stdout grid outputs
		}
		renderGrid(cols, rows, true, false, false, silent)
	} else {
		renderGrid(cols, rows, compensate, vs16Mode, false, silent)
	}
}
