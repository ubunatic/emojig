// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type recordSpec struct {
	Bitrate         string       `json:"bitrate"`
	FPS             int          `json:"fps"`
	Speed           float64      `json:"speed"`
	TUITheme        string       `json:"tui_theme"`
	TUIBg           string       `json:"tui_bg"`
	TUIFg           string       `json:"tui_fg"`
	TUITitle        string       `json:"tui_title"`
	TUIOutput       string       `json:"tui_output"`
	TUIFontSize     int          `json:"tui_font_size"`
	GUIFontSize     int          `json:"gui_font_size"`
	SceneWidth      int          `json:"scene_width"`
	SceneHeight     int          `json:"scene_height"`
	GeditWidth      int          `json:"gedit_width"`
	GeditHeight     int          `json:"gedit_height"`
	TUIPrompt       []PromptPart `json:"tui_prompt"`
	TUIScript       []ScriptStep `json:"tui_script"`
	GUIGeditScript  []ScriptStep `json:"gui_gedit_script"`
	GUIPickerScript []ScriptStep `json:"gui_picker_script"`
}

// stepDelay scales a base duration by spec.Speed (speed=0.5 → 2× slower).
func (s recordSpec) stepDelay(base time.Duration) time.Duration {
	if s.Speed <= 0 {
		return base
	}
	return time.Duration(float64(base) / s.Speed)
}

// tuiColors returns the effective foot/sway bg and fg hex colors (no #).
// Explicit tui_bg/tui_fg fields win; otherwise tui_theme picks the defaults.
func (s recordSpec) tuiColors() (bg, fg string) {
	bg, fg = s.TUIBg, s.TUIFg
	if bg == "" {
		if s.TUITheme == "light" {
			bg = "fafafa"
		} else {
			bg = "1c1c1c"
		}
	}
	if fg == "" {
		if s.TUITheme == "light" {
			fg = "383a42"
		} else {
			fg = "a8a8a8"
		}
	}
	return
}

// tuiOutputPath returns the output webm path for the TUI recording.
func (s recordSpec) tuiOutputPath() string {
	if s.TUIOutput != "" {
		return s.TUIOutput
	}
	if s.TUITheme == "light" {
		return "website/emojig-tui-light.webm"
	}
	return "website/emojig-tui-dark.webm"
}

func loadRecordSpec() recordSpec {
	s := recordSpec{
		Bitrate: "1M", FPS: 25, Speed: 1.0, TUIFontSize: 14, GUIFontSize: 14,
		SceneWidth: 1100, SceneHeight: 680,
		GeditWidth: 1000, GeditHeight: 540,
		TUIPrompt: []PromptPart{{Text: "$ "}},
		TUIScript: []ScriptStep{
			{Type: "cat", Desc: "search for cat"},
			{Type: "<right>", Desc: "select first result"},
			{Type: "<cr>", Desc: "confirm"},
		},
		GUIGeditScript: []ScriptStep{
			{Type: "Let's go ", Desc: "pre-emoji text"},
		},
		GUIPickerScript: []ScriptStep{
			{Type: "fire", Desc: "search query"},
			{Type: "<cr>", Desc: "select first result"},
		},
	}
	// Load base spec, then optional overlay (EMOJIG_RECORD_SPEC).
	// json.Unmarshal only sets fields present in the JSON, so the overlay
	// selectively overrides without repeating unchanged values.
	for _, path := range []string{"spec/record.json", os.Getenv("EMOJIG_RECORD_SPEC")} {
		if path == "" {
			continue
		}
		if data, err := os.ReadFile(path); err == nil {
			json.Unmarshal(data, &s)
		}
	}
	return s
}

const display = ":99"

func main() {
	fmt.Println("Building emojig...")
	buildCmd := exec.Command("zig", "build", "-Doptimize=ReleaseSmall")
	buildCmd.Stdout = os.Stdout
	buildCmd.Stderr = os.Stderr
	if err := buildCmd.Run(); err != nil {
		fmt.Printf("Build failed: %v\n", err)
		os.Exit(1)
	}

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
	time.Sleep(1 * time.Second)

	cwd, err := os.Getwd()
	if err != nil {
		fmt.Printf("Failed to get working directory: %v\n", err)
		os.Exit(1)
	}
	binaryPath := cwd + "/zig-out/bin/emojig"

	spec := loadRecordSpec()
	mode := os.Getenv("EMOJIG_RECORD_MODE") // "tui", "gui", or "" for both

	if mode == "" || mode == "tui" {
		if err := recordTUIDemo(binaryPath, spec); err != nil {
			fmt.Printf("TUI recording failed: %v\n", err)
			os.Exit(1)
		}
	}

	if mode == "" || mode == "gui" {
		if err := recordScenarioDemo(binaryPath, spec); err != nil {
			fmt.Printf("GUI scenario recording failed: %v\n", err)
			os.Exit(1)
		}
	}

	fmt.Println("🎉 Automated demo recording complete!")
}

func recordTUIDemo(binaryPath string, spec recordSpec) error {
	theme := spec.TUITheme
	if theme == "" {
		theme = "dark"
	}
	fmt.Printf("🎥 Recording TUI Demo (%s theme)...\n", theme)

	outputPath := spec.tuiOutputPath()
	_ = os.Remove(outputPath)

	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("failed to get working directory: %v", err)
	}
	zdotdir, err := os.MkdirTemp("", "emojig-zsh-*")
	if err != nil {
		return fmt.Errorf("failed to create zsh temp dir: %v", err)
	}
	defer os.RemoveAll(zdotdir)

	zshrc := fmt.Sprintf("export PATH=%s:$PATH\nsource %s/src/shell/emojig.zsh\nexport PS1='%s'\n",
		filepath.Dir(binaryPath), cwd, renderPS1(spec.TUIPrompt))
	if err := os.WriteFile(filepath.Join(zdotdir, ".zshrc"), []byte(zshrc), 0644); err != nil {
		return fmt.Errorf("failed to write zshrc: %v", err)
	}

	bg, fg := spec.tuiColors()
	footIni := fmt.Sprintf("[colors]\nbackground=%s\nforeground=%s\n", bg, fg)
	footIniPath := filepath.Join(os.TempDir(), "emojig-foot.ini")
	if err := os.WriteFile(footIniPath, []byte(footIni), 0644); err != nil {
		return fmt.Errorf("failed to write foot.ini: %v", err)
	}
	defer os.Remove(footIniPath)

	// 1. Nested sway (same backend as GUI recording).
	runtimeDir := filepath.Join(os.TempDir(), "emojig-tui-xdg")
	if err := os.MkdirAll(runtimeDir, 0700); err != nil {
		return fmt.Errorf("mkdir runtime dir: %v", err)
	}
	cfgPath := filepath.Join(os.TempDir(), "emojig-tui-sway.cfg")
	swayCfg := fmt.Sprintf(`output X11-1 resolution %dx%d position 0 0
output X11-1 bg #%s solid_color
for_window [app_id="emojig-picker"] floating enable, border none, resize set 450 340, move position center
`, spec.SceneWidth, spec.SceneHeight, bg)
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
	sway.Stderr = nil
	if err := sway.Start(); err != nil {
		return fmt.Errorf("failed to start sway: %v", err)
	}
	defer func() {
		fmt.Println("Shutting down sway (TUI)...")
		syscall.Kill(-sway.Process.Pid, syscall.SIGTERM)
		sway.Wait()
	}()

	// 2. Wait for Wayland socket.
	waylandDisplay, err := waitForWaylandSocket(runtimeDir)
	if err != nil {
		return err
	}
	swaySock, err := findSwaySocket(runtimeDir)
	if err != nil {
		return err
	}
	fmt.Printf("sway (TUI) up: WAYLAND_DISPLAY=%s\n", waylandDisplay)

	scene := waylandEnv(runtimeDir, waylandDisplay, swaySock)
	killGroup := func(c *exec.Cmd) {
		if c != nil && c.Process != nil {
			syscall.Kill(-c.Process.Pid, syscall.SIGTERM)
		}
	}

	// 3. Launch foot terminal running zsh with the emojig widget loaded.
	footArgs := []string{
		"--config=" + footIniPath,
		"--app-id=emojig-tui",
		fmt.Sprintf("--font=Monospace:size=%d", spec.TUIFontSize),
	}
	if spec.TUITitle != "" {
		footArgs = append(footArgs, "--title="+spec.TUITitle)
	}
	footArgs = append(footArgs, "--", "zsh", "-d")
	foot := exec.Command("foot", footArgs...)
	footEnv := append(scene,
		"ZDOTDIR="+zdotdir,
		"PATH="+filepath.Dir(binaryPath)+":"+os.Getenv("PATH"),
		"EMOJIG_TERMINAL=foot",
		"EMOJIG_GUI_FONT_SIZE="+strconv.Itoa(spec.GUIFontSize),
	)
	if spec.TUITheme != "" {
		footEnv = append(footEnv, "EMOJIG_THEME="+spec.TUITheme)
	}
	foot.Env = footEnv
	foot.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := foot.Start(); err != nil {
		return fmt.Errorf("failed to start foot: %v", err)
	}
	defer killGroup(foot)
	if err := waitForSwayApp(scene, "emojig-tui", true); err != nil {
		return err
	}
	time.Sleep(1 * time.Second)

	// 4. Start recording.
	subs := NewSubtitleCollector()
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

	// 5. Run the TUI script via wtype (Wayland input — no focus gymnastics needed).
	swaymsg(scene, `[app_id="emojig-tui"] focus`)
	time.Sleep(300 * time.Millisecond)
	if err := runWtypeScript(scene, spec.TUIScript, spec.stepDelay(800*time.Millisecond), nil, subs); err != nil {
		return err
	}
	time.Sleep(1 * time.Second)

	// 6. Stop recording.
	wf.Process.Signal(syscall.SIGINT)
	wf.Wait()

	if info, err := os.Stat(outputPath); err == nil && info.Size() > 0 {
		fmt.Printf("  TUI raw video: %d bytes\n", info.Size())
	} else {
		return fmt.Errorf("failed to produce TUI video file %s (wf-recorder: %s)", outputPath, strings.TrimSpace(wfErr.String()))
	}
	addSubtitles(outputPath, spec.Bitrate, subs.Entries)
	fmt.Printf("✅ Saved TUI demo to %s\n", outputPath)
	return nil
}
