// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	display = ":99"
)

func main() {
	// 1. Build the binary first to ensure we record the latest version
	fmt.Println("Building emojig...")
	buildCmd := exec.Command("zig", "build", "-Doptimize=ReleaseSmall")
	buildCmd.Stdout = os.Stdout
	buildCmd.Stderr = os.Stderr
	if err := buildCmd.Run(); err != nil {
		fmt.Printf("Build failed: %v\n", err)
		os.Exit(1)
	}

	// 2. Start Xvfb virtual display
	fmt.Printf("Starting Xvfb on display %s...\n", display)
	xvfbCtx, xvfbCancel := context.WithCancel(context.Background())
	defer xvfbCancel()

	xvfb := exec.CommandContext(xvfbCtx, "Xvfb", display, "-screen", "0", "1920x1080x24")
	xvfb.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := xvfb.Start(); err != nil {
		fmt.Printf("Failed to start Xvfb: %v\n", err)
		os.Exit(1)
	}
	defer func() {
		fmt.Println("Shutting down Xvfb...")
		syscall.Kill(-xvfb.Process.Pid, syscall.SIGTERM)
		xvfb.Wait()
	}()

	// Wait for Xvfb to be ready
	time.Sleep(1 * time.Second)

	// Start Openbox window manager inside Xvfb to handle window focus and mapping correctly
	fmt.Println("Starting Openbox window manager...")
	openboxConfig := `<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <keepBorder>no</keepBorder>
  </theme>
  <applications>
    <application class="*">
      <decor>no</decor>
      <shade>no</shade>
      <position force="yes">
        <x>0</x>
        <y>0</y>
      </position>
    </application>
  </applications>
</openbox_config>
`
	if err := os.WriteFile("/tmp/openbox-rc.xml", []byte(openboxConfig), 0644); err != nil {
		fmt.Printf("Warning: failed to write openbox config: %v\n", err)
	}

	openbox := exec.CommandContext(xvfbCtx, "openbox", "--sm-disable", "--config-file", "/tmp/openbox-rc.xml")
	openbox.Env = append(os.Environ(), "DISPLAY="+display)
	openbox.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := openbox.Start(); err != nil {
		fmt.Printf("Warning: failed to start Openbox: %v\n", err)
	} else {
		defer func() {
			fmt.Println("Shutting down Openbox...")
			syscall.Kill(-openbox.Process.Pid, syscall.SIGTERM)
			openbox.Wait()
		}()
		time.Sleep(500 * time.Millisecond)
	}

	// Resolve absolute path to the emojig binary
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Printf("Failed to get working directory: %v\n", err)
		os.Exit(1)
	}
	binaryPath := cwd + "/zig-out/bin/emojig"

	// 3. Record TUI (Dark Theme)
	if err := recordTUIDemo(xvfbCtx, binaryPath); err != nil {
		fmt.Printf("TUI recording failed: %v\n", err)
		os.Exit(1)
	}

	// 4. Record GUI (Light Theme)
	if err := recordGUIDemo(xvfbCtx, binaryPath); err != nil {
		fmt.Printf("GUI recording failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("🎉 Automated demo recording complete!")
}

func runInDisplay(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "DISPLAY="+display)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

func getWindowGeometry(winID string) (int, int, error) {
	cmd := exec.Command("xdotool", "getwindowgeometry", winID)
	cmd.Env = append(os.Environ(), "DISPLAY="+display)
	out, err := cmd.Output()
	if err != nil {
		return 0, 0, err
	}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		if strings.Contains(line, "Geometry:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				geom := parts[1] // e.g. "450x250"
				sizeParts := strings.Split(geom, "x")
				if len(sizeParts) == 2 {
					w, _ := strconv.Atoi(sizeParts[0])
					h, _ := strconv.Atoi(sizeParts[1])
					return w, h, nil
				}
			}
		}
	}
	return 0, 0, fmt.Errorf("could not parse geometry")
}

func waitForWindow(class string) (string, error) {
	for i := 0; i < 40; i++ {
		cmd := exec.Command("xdotool", "search", "--class", class)
		cmd.Env = append(os.Environ(), "DISPLAY="+display)
		out, err := cmd.Output()
		if err == nil && len(out) > 0 {
			lines := strings.Split(strings.TrimSpace(string(out)), "\n")
			for _, line := range lines {
				line = strings.TrimSpace(line)
				if line != "" {
					return line, nil
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return "", fmt.Errorf("window with class '%s' not found", class)
}

func recordTUIDemo(ctx context.Context, binaryPath string) error {
	fmt.Println("🎥 Recording TUI Demo (Dark Theme)...")

	// Set up output path
	outputPath := "website/emojig-tui-dark.webm"
	_ = os.Remove(outputPath)

	// Launch xterm with specific layout and dark palette styling, running emojig directly
	xtermArgs := []string{
		"-xrm", "xterm*allowSendEvents: true",
		"-fa", "Monospace",
		"-fs", "14",
		"-geometry", "50x13+0+0",
		"-bg", "#1c1c1c",
		"-fg", "#a8a8a8",
		"-cr", "#ffffff",
		"+sb",
		"-bd", "#1c1c1c",
		"-class", "emojig-tui",
		"-e", binaryPath, "--tui",
	}
	xterm := runInDisplay(ctx, "xterm", xtermArgs...)
	xterm.Stderr = os.Stderr
	if err := xterm.Start(); err != nil {
		return fmt.Errorf("failed to start xterm: %v", err)
	}

	winID, err := waitForWindow("emojig-tui")
	if err != nil {
		return fmt.Errorf("failed waiting for window emojig-tui: %v", err)
	}
	fmt.Printf("TUI Window found: %s\n", winID)

	w, h, err := getWindowGeometry(winID)
	if err != nil {
		return fmt.Errorf("failed getting window geometry: %v", err)
	}
	fmt.Printf("Window geometry: %dx%d\n", w, h)
	// ffmpeg needs even dimensions
	if w%2 != 0 {
		w++
	}
	if h%2 != 0 {
		h++
	}

	// Start ffmpeg grab
	ffmpegArgs := []string{
		"-f", "x11grab",
		"-video_size", fmt.Sprintf("%dx%d", w, h),
		"-i", display + ".0+0,0",
		"-codec:v", "libvpx-vp9",
		"-b:v", "1M",
		"-r", "25",
		"-y",
		outputPath,
	}
	ffmpeg := runInDisplay(ctx, "ffmpeg", ffmpegArgs...)
	ffmpeg.Stderr = os.Stderr
	if err := ffmpeg.Start(); err != nil {
		return fmt.Errorf("failed to start ffmpeg: %v", err)
	}
	fmt.Println("ffmpeg recording started...")

	// Let record settle
	time.Sleep(1 * time.Second)

	// Explicitly focus/activate the window first
	if err := runXdotool("windowfocus", "--sync", winID); err != nil {
		fmt.Printf("Warning focusing window: %v\n", err)
	}
	time.Sleep(500 * time.Millisecond)

	// Simulate TUI keyboard inputs (using XTest focus-based typing)
	fmt.Println("Typing query 'cat'...")
	if err := runXdotool("type", "--delay", "150", "cat"); err != nil {
		return err
	}

	time.Sleep(1 * time.Second)

	fmt.Println("Pressing Right arrow...")
	if err := runXdotool("key", "Right"); err != nil {
		return err
	}

	time.Sleep(1 * time.Second)

	fmt.Println("Pressing Return...")
	if err := runXdotool("key", "Return"); err != nil {
		return err
	}

	// Wait for xterm process to clean exit
	fmt.Println("Waiting for xterm to close...")
	xtermErr := xterm.Wait()
	if xtermErr != nil {
		fmt.Printf("Warning: xterm exited with error: %v\n", xtermErr)
	} else {
		fmt.Println("xterm closed cleanly.")
	}

	// Stop recording
	fmt.Println("Stopping ffmpeg...")
	syscall.Kill(-ffmpeg.Process.Pid, syscall.SIGTERM)
	ffmpeg.Wait()

	// Verify the output file exists
	if info, err := os.Stat(outputPath); err == nil && info.Size() > 0 {
		fmt.Printf("✅ Saved TUI demo to %s (%d bytes)\n", outputPath, info.Size())
	} else {
		return fmt.Errorf("failed to produce TUI video file %s", outputPath)
	}
	return nil
}

func recordGUIDemo(ctx context.Context, binaryPath string) error {
	fmt.Println("🎥 Recording GUI Demo (Light Theme)...")

	// Set up output path
	outputPath := "website/emojig-gui-light.webm"
	_ = os.Remove(outputPath)

	// Configure xterm resources for class 'emojig' to match light theme
	xrdbResources := `emojig*background: #eeeeee
emojig*foreground: #444444
emojig*cursorColor: #444444
emojig*borderColor: #eeeeee
emojig*borderWidth: 0
emojig*scrollBar: false
emojig*faceName: Monospace
emojig*faceSize: 14
emojig*geometry: 53x12+0+0
emojig*allowSendEvents: true
xterm*allowSendEvents: true
`
	xrdb := runInDisplay(ctx, "xrdb", "-merge")
	xrdb.Stdin = bytes.NewBufferString(xrdbResources)
	var xrdbStderr bytes.Buffer
	xrdb.Stderr = &xrdbStderr
	if err := xrdb.Run(); err != nil {
		return fmt.Errorf("failed to load x resources via xrdb: %v (stderr: %s)", err, strings.TrimSpace(xrdbStderr.String()))
	}

	// Launch emojig in gui mode, forcing xterm host under Xvfb
	gui := runInDisplay(ctx, binaryPath, "--gui", "--theme", "light")
	gui.Env = append(gui.Env, "EMOJIG_TERMINAL=xterm")
	gui.Stderr = os.Stderr
	if err := gui.Start(); err != nil {
		return fmt.Errorf("failed to start gui: %v", err)
	}

	winID, err := waitForWindow("emojig")
	if err != nil {
		return err
	}

	w, h, err := getWindowGeometry(winID)
	if err != nil {
		return err
	}
	// ffmpeg needs even dimensions
	if w%2 != 0 {
		w++
	}
	if h%2 != 0 {
		h++
	}

	// Start ffmpeg grab
	ffmpegArgs := []string{
		"-f", "x11grab",
		"-video_size", fmt.Sprintf("%dx%d", w, h),
		"-i", display + ".0+0,0",
		"-codec:v", "libvpx-vp9",
		"-b:v", "1M",
		"-r", "25",
		"-y",
		outputPath,
	}
	ffmpeg := runInDisplay(ctx, "ffmpeg", ffmpegArgs...)
	ffmpeg.Stderr = os.Stderr
	if err := ffmpeg.Start(); err != nil {
		return fmt.Errorf("failed to start ffmpeg: %v", err)
	}

	// Let record settle
	time.Sleep(1 * time.Second)

	// Explicitly focus/activate the window first
	if err := runXdotool("windowfocus", "--sync", winID); err != nil {
		fmt.Printf("Warning focusing window: %v\n", err)
	}
	time.Sleep(500 * time.Millisecond)

	if err := runXdotool("type", "--delay", "150", "cat"); err != nil {
		return err
	}

	time.Sleep(1 * time.Second)

	if err := runXdotool("key", "Right"); err != nil {
		return err
	}

	time.Sleep(1 * time.Second)

	if err := runXdotool("key", "Down"); err != nil {
		return err
	}

	time.Sleep(1 * time.Second)

	if err := runXdotool("key", "Return"); err != nil {
		return err
	}

	// Wait for window to close (checking if class 'emojig' is gone)
	xdotoolEnv := append(os.Environ(), "DISPLAY="+display)
	for i := 0; i < 40; i++ {
		cmd := exec.Command("xdotool", "search", "--class", "emojig")
		cmd.Env = xdotoolEnv
		out, _ := cmd.Output()
		if len(out) == 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	// Stop recording
	syscall.Kill(-ffmpeg.Process.Pid, syscall.SIGTERM)
	ffmpeg.Wait()

	fmt.Printf("✅ Saved GUI demo to %s\n", outputPath)
	return nil
}

func runXdotool(args ...string) error {
	cmd := exec.Command("xdotool", args...)
	cmd.Env = append(os.Environ(), "DISPLAY="+display)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("xdotool %s failed: %v (stderr: %s)", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return nil
}
