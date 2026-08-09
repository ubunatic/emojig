// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// canary_font_width isolates one mechanism: does the wlroots compositor
// renderer backend (WLR_RENDERER) change which column-width foot assigns to
// the ambiguous BMP symbols in scripts/vte_canary's color-grid test pattern?
// It spins up its own headless sway compositor (WLR_BACKENDS=headless, no
// Xvfb/X11, no GPU or display required), launches foot inside it running
// the vte_canary grid, screenshots via grim, and measures whether all 4
// color rows reach the same right edge. Run once per -renderer value and
// compare; see docs/Canary.md for why this is a script and not a one-off
// shell session.
package main

import (
	"flag"
	"fmt"
	"image"
	_ "image/png"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var canaryColors = []struct {
	Name    string
	R, G, B uint8
}{
	{"red", 255, 0, 0},
	{"green", 0, 255, 0},
	{"blue", 0, 0, 255},
	{"yellow", 255, 255, 0},
}

const maxRowEdgeSkew = 1

func waitForFile(pattern string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		matches, _ := filepath.Glob(pattern)
		for _, m := range matches {
			if !strings.HasSuffix(m, ".lock") {
				return m, nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return "", fmt.Errorf("timed out waiting for %s", pattern)
}

// runProbe spins up a headless sway compositor with the given WLR_RENDERER,
// runs the vte_canary color grid inside foot, screenshots it, and reports
// each row's rightmost matching-color pixel.
func runProbe(renderer, repoRoot, vteCanaryBin, vteCanaryArgs, saveShotPath string) (bool, string, error) {
	runtimeDir, err := os.MkdirTemp("", "canary-font-width-*")
	if err != nil {
		return false, "", err
	}
	defer os.RemoveAll(runtimeDir)
	if err := os.Chmod(runtimeDir, 0o700); err != nil {
		return false, "", err
	}

	cfgPath := filepath.Join(runtimeDir, "sway.cfg")
	cfg := "output * bg #101010 solid_color\nseat * hide_cursor 100\ndefault_border none\n"
	if err := os.WriteFile(cfgPath, []byte(cfg), 0o644); err != nil {
		return false, "", err
	}

	swayEnv := append(os.Environ(),
		"XDG_RUNTIME_DIR="+runtimeDir,
		"WLR_BACKENDS=headless",
		"WLR_LIBINPUT_NO_DEVICES=1",
	)
	if renderer != "" {
		swayEnv = append(swayEnv, "WLR_RENDERER="+renderer)
	}

	sway := exec.Command("sway", "-c", cfgPath)
	sway.Env = swayEnv
	sway.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var swayErr strings.Builder
	sway.Stderr = &swayErr
	if err := sway.Start(); err != nil {
		return false, "", fmt.Errorf("start sway: %w", err)
	}
	defer func() {
		syscall.Kill(-sway.Process.Pid, syscall.SIGTERM)
		sway.Wait()
	}()

	socketPath, err := waitForFile(filepath.Join(runtimeDir, "wayland-*"), 5*time.Second)
	if err != nil {
		return false, "", fmt.Errorf("%w (sway stderr: %s)", err, strings.TrimSpace(swayErr.String()))
	}
	waylandDisplay := filepath.Base(socketPath)

	shotPath := filepath.Join(runtimeDir, "shot.png")
	footEnv := append(os.Environ(),
		"XDG_RUNTIME_DIR="+runtimeDir,
		"WAYLAND_DISPLAY="+waylandDisplay,
	)
	// vte_canary_bin -s prints the grid and exits immediately; foot closes
	// the window the instant its child exits, so wrap it in a shell that
	// keeps the window (and the already-printed grid) open long enough for
	// grim to capture it.
	holdOpen := fmt.Sprintf("%s %s; sleep 5", vteCanaryBin, vteCanaryArgs)
	foot := exec.Command("foot", "--app-id=canary-font-width", "sh", "-c", holdOpen)
	foot.Dir = repoRoot
	foot.Env = footEnv
	foot.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var footErr strings.Builder
	foot.Stderr = &footErr
	if err := foot.Start(); err != nil {
		return false, "", fmt.Errorf("start foot: %w", err)
	}
	defer func() {
		syscall.Kill(-foot.Process.Pid, syscall.SIGTERM)
		foot.Wait()
	}()

	time.Sleep(800 * time.Millisecond)

	grim := exec.Command("grim", "-t", "png", shotPath)
	grim.Env = footEnv
	if out, err := grim.CombinedOutput(); err != nil {
		return false, "", fmt.Errorf("grim: %w (%s)", err, strings.TrimSpace(string(out)))
	}

	if saveShotPath != "" {
		data, err := os.ReadFile(shotPath)
		if err != nil {
			return false, "", fmt.Errorf("read shot for save: %w", err)
		}
		if err := os.WriteFile(saveShotPath, data, 0o644); err != nil {
			return false, "", fmt.Errorf("save shot to %s: %w", saveShotPath, err)
		}
	}

	ok, msg := verifyRowLengths(shotPath)
	return ok, msg, nil
}

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

	var detail []string
	skewed := false
	for i, cc := range canaryColors {
		if rightEdge[i] < 0 {
			detail = append(detail, fmt.Sprintf("%s=not found", cc.Name))
			skewed = true
			continue
		}
		skew := maxEdge - rightEdge[i]
		detail = append(detail, fmt.Sprintf("%s=x%d", cc.Name, rightEdge[i]))
		if skew > maxRowEdgeSkew {
			skewed = true
		}
	}

	status := "PASSED: rows equal"
	if skewed {
		status = "FAILED: row length mismatch"
	}
	return !skewed, fmt.Sprintf("%s (%s)", status, strings.Join(detail, ", "))
}

func main() {
	var renderers string
	var repoRoot string
	var saveDir string
	var vteCanaryArgs string
	flag.StringVar(&renderers, "renderer", "pixman,gles2,", "comma-separated WLR_RENDERER values to probe; empty entry = let wlroots auto-select")
	flag.StringVar(&repoRoot, "repo-root", ".", "emojig repo root (cwd for the foot-launched vte_canary binary)")
	flag.StringVar(&saveDir, "save-dir", "", "if set, save each probe's screenshot to <dir>/shot-<renderer>.png for manual viewing")
	flag.StringVar(&vteCanaryArgs, "vte-canary-args", "-s", "args passed to vte_canary_bin inside foot, e.g. '-b -s' for the unpadded+padded both-blocks variant")
	flag.Parse()

	if saveDir != "" {
		if err := os.MkdirAll(saveDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "mkdir %s: %v\n", saveDir, err)
			os.Exit(2)
		}
	}

	vteCanaryBin := filepath.Join(os.TempDir(), "vte_canary_bin")
	build := exec.Command("go", "build", "-o", vteCanaryBin, "scripts/vte_canary/main.go")
	build.Dir = repoRoot
	if out, err := build.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "build vte_canary: %v\n%s\n", err, out)
		os.Exit(2)
	}

	exitCode := 0
	for _, renderer := range strings.Split(renderers, ",") {
		label := renderer
		if label == "" {
			label = "(auto)"
		}
		var saveShotPath string
		if saveDir != "" {
			saveShotPath = filepath.Join(saveDir, fmt.Sprintf("shot-%s.png", strings.Trim(label, "()")))
		}
		ok, msg, err := runProbe(renderer, repoRoot, vteCanaryBin, vteCanaryArgs, saveShotPath)
		if err != nil {
			fmt.Printf("renderer=%-8s ERROR: %v\n", label, err)
			exitCode = 1
			continue
		}
		if saveShotPath != "" {
			fmt.Printf("renderer=%-8s %s [saved: %s]\n", label, msg, saveShotPath)
		} else {
			fmt.Printf("renderer=%-8s %s\n", label, msg)
		}
		if !ok {
			exitCode = 1
		}
	}
	os.Exit(exitCode)
}
