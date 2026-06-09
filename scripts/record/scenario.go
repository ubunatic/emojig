// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

// Desktop GUI scenario recording.
//
// Replaces the old isolated GUI-popup capture with a full "desktop" demo:
// a single-color desktop (nested sway compositor) hosts a real GUI app (gedit),
// the user opens the emojig picker (foot popup), searches a query, selects an
// emoji, and pastes it back into gedit — all captured to a webm.
//
// Why sway (not plain xterm/foot on X11): foot is Wayland-only, and emojig's
// first-choice clipboard path (`wl-copy`) needs a wlroots compositor. sway gives
// us deterministic window control via `swaymsg` plus a working Wayland clipboard.
//
// Headless gotchas baked in below (verified empirically):
//   - No GPU: sway needs WLR_RENDERER=pixman + software-render env.
//   - ffmpeg x11grab captures BLACK for the nested-sway window (DRI3/Present is
//     invisible to XGetImage), so we record with wf-recorder (wlr-screencopy).
//   - wtype modifier combos (Ctrl+V) are no-ops under sway, so paste is done via
//     the PRIMARY selection + a synthetic middle-click.

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const sceneWidth = 1100
const sceneHeight = 680

// recordScenarioDemo records the full desktop GUI scenario to a webm.
// query is the search term typed into the picker (default "fire").
func recordScenarioDemo(binaryPath, query string, spec recordSpec) error {
	fmt.Printf("🎬 Recording GUI desktop scenario (query %q)...\n", query)

	outputPath := "website/emojig-gui-light.webm"
	_ = os.Remove(outputPath)

	// Per-run Wayland runtime dir for the nested sway compositor.
	runtimeDir := filepath.Join(os.TempDir(), "emojig-record-xdg")
	if err := os.MkdirAll(runtimeDir, 0700); err != nil {
		return fmt.Errorf("mkdir runtime dir: %v", err)
	}

	// 1. Launch nested sway (x11 backend, software rendering).
	cfgPath := filepath.Join(os.TempDir(), "emojig-sway.cfg")
	swayCfg := fmt.Sprintf(`output X11-1 resolution %dx%d position 0 0
output X11-1 bg #1f2d3d solid_color
default_border none
default_floating_border none
for_window [app_id="gedit"] floating enable, resize set %d %d, move position 50 40
for_window [app_id="emojig-picker"] floating enable, resize set 450 340, move position center
`, sceneWidth, sceneHeight, spec.GeditWidth, spec.GeditHeight)
	if err := os.WriteFile(cfgPath, []byte(swayCfg), 0644); err != nil {
		return fmt.Errorf("write sway config: %v", err)
	}

	swayEnv := append(os.Environ(),
		"DISPLAY="+display,
		"XDG_RUNTIME_DIR="+runtimeDir,
		"WLR_BACKENDS=x11",
		"WLR_X11_OUTPUTS=1",
		"WLR_RENDERER=pixman",
		"WLR_RENDERER_ALLOW_SOFTWARE=1",
		"LIBGL_ALWAYS_SOFTWARE=1",
	)
	sway := exec.Command("sway", "-c", cfgPath)
	sway.Env = swayEnv
	sway.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	sway.Stderr = os.Stderr
	if err := sway.Start(); err != nil {
		return fmt.Errorf("failed to start sway: %v", err)
	}
	defer func() {
		fmt.Println("Shutting down sway...")
		syscall.Kill(-sway.Process.Pid, syscall.SIGTERM)
		sway.Wait()
		// Tearing down sway drops the Wayland display, so any daemonized
		// wl-copy (and foot) that escaped their process group exit on
		// disconnect — no session-wide pkill needed (which would also kill
		// the user's real gedit/foot).
	}()

	// 2. Wait for the Wayland socket and resolve the sway IPC socket.
	waylandDisplay, err := waitForWaylandSocket(runtimeDir)
	if err != nil {
		return err
	}
	swaySock, err := findSwaySocket(runtimeDir)
	if err != nil {
		return err
	}
	fmt.Printf("sway up: WAYLAND_DISPLAY=%s\n", waylandDisplay)

	// killGroup terminates a started command's whole process group (each
	// scenario child runs with Setpgid). Registered as a defer per child so
	// even error paths clean up — scoped strictly to processes we spawned.
	killGroup := func(c *exec.Cmd) {
		if c != nil && c.Process != nil {
			syscall.Kill(-c.Process.Pid, syscall.SIGTERM)
		}
	}

	// scene is the env every Wayland-side command shares.
	scene := waylandEnv(runtimeDir, waylandDisplay, swaySock)

	// 3. Launch gedit (light theme) and wait for its window.
	demoFile := filepath.Join(os.TempDir(), "demo.txt")
	_ = os.WriteFile(demoFile, []byte(""), 0644)
	defer os.Remove(demoFile)

	gedit := exec.Command("gedit", demoFile)
	gedit.Env = append(scene, "GTK_THEME=Adwaita:light")
	gedit.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := gedit.Start(); err != nil {
		return fmt.Errorf("failed to start gedit: %v", err)
	}
	defer killGroup(gedit)
	if err := waitForSwayApp(scene, "gedit", true); err != nil {
		return err
	}
	time.Sleep(1 * time.Second)

	// 4. Focus gedit and pre-type the sentence the emoji will complete.
	swaymsg(scene, `[app_id="gedit"] focus`)
	time.Sleep(300 * time.Millisecond)
	if err := wtype(scene, "-d", "60", "Let's go "); err != nil {
		return err
	}
	time.Sleep(400 * time.Millisecond)

	// 5. Start recording (wf-recorder, wlr-screencopy — captures sway's output).
	wf := exec.Command("wf-recorder", "-o", "X11-1", "-c", "libvpx-vp9",
		"-r", strconv.Itoa(spec.FPS), "-b", spec.Bitrate, "-f", outputPath)
	wf.Env = scene
	wf.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var wfErr strings.Builder
	wf.Stderr = &wfErr
	if err := wf.Start(); err != nil {
		return fmt.Errorf("failed to start wf-recorder: %v", err)
	}
	defer killGroup(wf)
	time.Sleep(1500 * time.Millisecond)

	// 6. Open the emojig picker (foot popup, light theme) and wait for it.
	picker := exec.Command(binaryPath, "--gui", "--theme", "light")
	picker.Env = append(scene, "EMOJIG_TERMINAL=foot",
		"EMOJIG_GUI_FONT_SIZE="+strconv.Itoa(spec.GUIFontSize))
	picker.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := picker.Start(); err != nil {
		return fmt.Errorf("failed to start emojig picker: %v", err)
	}
	defer killGroup(picker)
	if err := waitForSwayApp(scene, "emojig-picker", true); err != nil {
		return err
	}
	time.Sleep(1200 * time.Millisecond)

	// 7. Focus the picker, type the query, select the first result.
	swaymsg(scene, `[app_id="emojig-picker"] focus`)
	time.Sleep(300 * time.Millisecond)
	fmt.Printf("Typing query %q...\n", query)
	if err := wtype(scene, "-d", "130", query); err != nil {
		return err
	}
	time.Sleep(1200 * time.Millisecond)
	wtype(scene, "-k", "Return")

	// Wait for the picker window to disappear (selection + exit animation done).
	if err := waitForSwayApp(scene, "emojig-picker", false); err != nil {
		fmt.Printf("Warning: picker did not close cleanly: %v\n", err)
	}
	clip := strings.TrimSpace(captureOutput(scene, "wl-paste"))
	fmt.Printf("Clipboard now holds: %q\n", clip)

	// 8. Paste into gedit: mirror clipboard -> PRIMARY, then middle-click.
	// (wtype Ctrl+V is a no-op under sway; PRIMARY + middle-click is reliable.)
	mirrorClipboardToPrimary(scene)
	swaymsg(scene, `[app_id="gedit"] focus`)
	time.Sleep(400 * time.Millisecond)
	swaymsg(scene, "seat - cursor set 300 97")
	swaymsg(scene, "seat - cursor press button2")
	swaymsg(scene, "seat - cursor release button2")
	time.Sleep(1300 * time.Millisecond)

	// 9. Stop recording (SIGINT so wf-recorder finalizes the webm cleanly).
	wf.Process.Signal(syscall.SIGINT)
	wf.Wait()

	if info, err := os.Stat(outputPath); err == nil && info.Size() > 0 {
		fmt.Printf("✅ Saved GUI scenario to %s (%d bytes)\n", outputPath, info.Size())
	} else {
		return fmt.Errorf("failed to produce scenario video %s (wf-recorder: %s)", outputPath, strings.TrimSpace(wfErr.String()))
	}
	return nil
}

// waylandEnv returns the base environment for Wayland-side commands.
func waylandEnv(runtimeDir, waylandDisplay, swaySock string) []string {
	return append(os.Environ(),
		"XDG_RUNTIME_DIR="+runtimeDir,
		"WAYLAND_DISPLAY="+waylandDisplay,
		"SWAYSOCK="+swaySock,
	)
}

// waitForWaylandSocket polls runtimeDir for the wayland-N socket sway creates.
func waitForWaylandSocket(runtimeDir string) (string, error) {
	for i := 0; i < 60; i++ {
		entries, _ := os.ReadDir(runtimeDir)
		for _, e := range entries {
			n := e.Name()
			if strings.HasPrefix(n, "wayland-") && !strings.HasSuffix(n, ".lock") {
				// names are wayland-0, wayland-1, ... (skip .lock siblings)
				if _, err := fmt.Sscanf(strings.TrimPrefix(n, "wayland-"), "%d", new(int)); err == nil {
					return n, nil
				}
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return "", fmt.Errorf("sway wayland socket never appeared in %s", runtimeDir)
}

// findSwaySocket resolves the sway IPC socket path (sway-ipc.*.sock).
func findSwaySocket(runtimeDir string) (string, error) {
	matches, _ := filepath.Glob(filepath.Join(runtimeDir, "sway-ipc.*.sock"))
	if len(matches) == 0 {
		return "", fmt.Errorf("sway IPC socket not found in %s", runtimeDir)
	}
	return matches[0], nil
}

// waitForSwayApp waits until a window with the given app_id is present (want=true)
// or gone (want=false) in the sway tree.
func waitForSwayApp(env []string, appID string, want bool) error {
	needle := fmt.Sprintf(`"app_id": "%s"`, appID)
	for i := 0; i < 60; i++ {
		tree := captureOutput(env, "swaymsg", "-t", "get_tree")
		present := strings.Contains(tree, needle)
		if present == want {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	state := "appear"
	if !want {
		state = "disappear"
	}
	return fmt.Errorf("timed out waiting for app_id %q to %s", appID, state)
}

// swaymsg runs a swaymsg command, logging (not failing) on error.
func swaymsg(env []string, args ...string) {
	cmd := exec.Command("swaymsg", args...)
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Printf("Warning: swaymsg %v: %v (%s)\n", args, err, strings.TrimSpace(string(out)))
	}
}

// wtype types text / keys into the focused Wayland surface.
func wtype(env []string, args ...string) error {
	cmd := exec.Command("wtype", args...)
	cmd.Env = env
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("wtype %v failed: %v (%s)", args, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// mirrorClipboardToPrimary copies the CLIPBOARD selection into PRIMARY so a
// middle-click paste delivers the emoji emojig placed on the clipboard.
func mirrorClipboardToPrimary(env []string) {
	content := captureOutput(env, "wl-paste", "-n")
	cmd := exec.Command("wl-copy", "--primary")
	cmd.Env = env
	cmd.Stdin = strings.NewReader(content)
	if err := cmd.Run(); err != nil {
		fmt.Printf("Warning: wl-copy --primary: %v\n", err)
	}
}

// captureOutput runs a command in the given env and returns its stdout.
func captureOutput(env []string, name string, args ...string) string {
	cmd := exec.Command(name, args...)
	cmd.Env = env
	out, _ := cmd.Output()
	return string(out)
}
