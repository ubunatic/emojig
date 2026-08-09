// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
)

// hostBg is the contrasting host-terminal background (magenta) that the
// canary reels force via `--override=colors.background=ff00ff` on the
// captured foot window. Any pixel of this color inside the captured
// `mode=app` client-surface screenshot proves a cell the app was supposed
// to paint (either for cosmetic bg-fill reasons, issue 50, or because it
// under-drew the grid it was given, issue 41) was left showing the host
// terminal default instead.
var hostBg = [3]uint8{255, 0, 255}

// verifyBgLeak inspects a captured, uncropped `mode=app` screenshot PNG for
// any host-background pixel anywhere in the client surface. Because the
// reel fixes the foot window to the exact character geometry emojig
// requested (see spec/reels/canary-gui-*.reel), a stray host-bg pixel can
// only mean the app failed to paint a cell it was told to draw — whether a
// cosmetic row/column-edge bug (issue 50) or a geometry-budget miscalculation
// that left real rows/columns unpainted (issue 41). One scan proves both.
func verifyBgLeak(pngPath string) (bool, string) {
	f, err := os.Open(pngPath)
	if err != nil {
		return false, fmt.Sprintf("cannot open PNG %s: %v", pngPath, err)
	}
	defer f.Close()

	img, _, err := image.Decode(f)
	if err != nil {
		return false, fmt.Sprintf("cannot decode PNG %s: %v", pngPath, err)
	}

	bounds := img.Bounds()
	leakCount := 0
	totalPixels := 0

	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			totalPixels++
			r, g, b, _ := img.At(x, y).RGBA()
			r8, g8, b8 := uint8(r>>8), uint8(g>>8), uint8(b>>8)
			if r8 == hostBg[0] && g8 == hostBg[1] && b8 == hostBg[2] {
				leakCount++
			}
		}
	}

	if leakCount > 0 {
		return false, fmt.Sprintf("FAILED: detected %d host-background pixels (#FF00FF) in %s — unpainted cell or short row/column", leakCount, pngPath)
	}
	return true, fmt.Sprintf("PASSED: 0 host-background leaks across %d pixels in %s", totalPixels, pngPath)
}

// verifyGeometry compares a captured screenshot's pixel dimensions against
// the dimensions recorded from a known-good capture at the same grid/font
// settings (see spec/reels/canary-gui-*.reel and docs/Canary.md: "document
// what you found, then keep the canary as the regression oracle"). This is
// a pixel measurement of the real rendered window, not an assumed
// font-metric formula — if font size, grid size, or window-sizing behavior
// regresses, the captured pixel size changes and this fails.
func verifyGeometry(pngPath string, expectWidth, expectHeight int) (bool, string) {
	f, err := os.Open(pngPath)
	if err != nil {
		return false, fmt.Sprintf("cannot open PNG %s: %v", pngPath, err)
	}
	defer f.Close()

	img, _, err := image.Decode(f)
	if err != nil {
		return false, fmt.Sprintf("cannot decode PNG %s: %v", pngPath, err)
	}

	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w != expectWidth || h != expectHeight {
		return false, fmt.Sprintf("FAILED: geometry mismatch in %s — expected %dx%d px, captured %dx%d px", pngPath, expectWidth, expectHeight, w, h)
	}
	return true, fmt.Sprintf("PASSED: %s matches recorded-good geometry %dx%d px", pngPath, w, h)
}

// writeFixture renders a tiny synthetic PNG, optionally with a magenta
// host-bg pixel, so the self-test can drive verifyBgLeak against known-good
// and known-bad input without depending on a real capture.
func writeFixture(path string, withLeak bool) error {
	const w, h = 8, 8
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	appBg := color.RGBA{0x26, 0x26, 0x26, 255}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, appBg)
		}
	}
	if withLeak {
		img.Set(0, h-1, color.RGBA{hostBg[0], hostBg[1], hostBg[2], 255})
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return png.Encode(f, img)
}

// runSelfTest proves the leak detector actually detects a leak (and does not
// false-positive on a clean frame) instead of trusting the pass/fail wiring
// blindly. Run whenever verifyBgLeak changes.
func runSelfTest() (bool, string) {
	dir, err := os.MkdirTemp("", "canary-gui-selftest-*")
	if err != nil {
		return false, fmt.Sprintf("cannot create temp dir: %v", err)
	}
	defer os.RemoveAll(dir)

	var problems []string

	leakyPath := filepath.Join(dir, "leaky.png")
	if err := writeFixture(leakyPath, true); err != nil {
		return false, fmt.Sprintf("cannot write leaky fixture: %v", err)
	}
	if ok, msg := verifyBgLeak(leakyPath); ok {
		problems = append(problems, fmt.Sprintf("detector missed a synthetic leak (%s)", msg))
	}

	cleanPath := filepath.Join(dir, "clean.png")
	if err := writeFixture(cleanPath, false); err != nil {
		return false, fmt.Sprintf("cannot write clean fixture: %v", err)
	}
	if ok, msg := verifyBgLeak(cleanPath); !ok {
		problems = append(problems, fmt.Sprintf("detector false-positived on a clean frame (%s)", msg))
	}

	// verifyGeometry regression check: a fixture must fail against a
	// deliberately wrong expected size and pass against its own true size.
	dims, err := decodeDims(cleanPath)
	if err != nil {
		return false, fmt.Sprintf("cannot measure fixture dims: %v", err)
	}
	if ok, msg := verifyGeometry(cleanPath, dims[0]+1, dims[1]); ok {
		problems = append(problems, fmt.Sprintf("geometry check missed a deliberate width mismatch (%s)", msg))
	}
	if ok, _ := verifyGeometry(cleanPath, dims[0], dims[1]); !ok {
		problems = append(problems, "geometry check rejected a fixture's own true dimensions")
	}

	if len(problems) > 0 {
		return false, "FAILED self-test: " + strings.Join(problems, "; ")
	}
	return true, "PASSED self-test: leak and geometry detectors both catch synthetic faults and accept clean input"
}

func decodeDims(path string) ([2]int, error) {
	f, err := os.Open(path)
	if err != nil {
		return [2]int{}, err
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		return [2]int{}, err
	}
	b := img.Bounds()
	return [2]int{b.Dx(), b.Dy()}, nil
}

func main() {
	var (
		leakPng      string
		selfTest     bool
		geomPng      string
		expectWidth  int
		expectHeight int
		reportJson   string
	)

	flag.StringVar(&leakPng, "verify-leak", "", "Uncropped mode=app screenshot PNG path to scan for host-bg leaks")
	flag.BoolVar(&selfTest, "self-test", false, "Run the detector self-test against synthetic fixtures (proves the detectors themselves work)")

	flag.StringVar(&geomPng, "verify-geom", "", "Screenshot PNG path to check against a recorded-good pixel size")
	flag.IntVar(&expectWidth, "expect-width", 0, "Recorded-good capture width in pixels")
	flag.IntVar(&expectHeight, "expect-height", 0, "Recorded-good capture height in pixels")
	flag.StringVar(&reportJson, "report", "", "Optional JSON summary report file output path")

	flag.Parse()

	passed := true
	var messages []string

	if selfTest {
		ok, msg := runSelfTest()
		messages = append(messages, msg)
		if !ok {
			passed = false
		}
	}

	if leakPng != "" {
		ok, msg := verifyBgLeak(leakPng)
		messages = append(messages, msg)
		if !ok {
			passed = false
		}
	}

	if geomPng != "" {
		if expectWidth == 0 || expectHeight == 0 {
			messages = append(messages, "FAILED: -verify-geom requires -expect-width and -expect-height")
			passed = false
		} else {
			ok, msg := verifyGeometry(geomPng, expectWidth, expectHeight)
			messages = append(messages, msg)
			if !ok {
				passed = false
			}
		}
	}

	if len(messages) == 0 {
		fmt.Fprintln(os.Stderr, "Usage: canary_gui -self-test | -verify-leak <png> | -verify-geom <png> -expect-width W -expect-height H")
		os.Exit(2)
	}

	for _, msg := range messages {
		fmt.Fprintln(os.Stderr, msg)
	}

	if reportJson != "" {
		reportData := map[string]any{
			"passed":   passed,
			"messages": messages,
		}
		data, _ := json.MarshalIndent(reportData, "", "  ")
		_ = os.MkdirAll(filepath.Dir(reportJson), 0o755)
		_ = os.WriteFile(reportJson, data, 0o644)
	}

	if !passed {
		os.Exit(1)
	}
}
