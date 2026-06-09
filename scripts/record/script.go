// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// ScriptStep is a single input action. Fields:
//   - type:      text or vim-style keys (<cr> <bs> <C-e> <C-A-space> …)
//   - pause:     sleep, e.g. "1s", "500ms"
//   - next:      call a named script in another context, then return
//   - show_keys: hint for future key-overlay rendering (not yet implemented)
//   - desc:      human-readable label printed during recording
type ScriptStep struct {
	Type     string `json:"type"`
	Desc     string `json:"desc"`
	Pause    string `json:"pause"`
	Next     string `json:"next"`
	ShowKeys bool   `json:"show_keys"`
}

type keyToken struct {
	isKey bool
	value string
}

// parseScript splits a step string into alternating text/key tokens.
// "<cr>foo<bs>" → [{key,"cr"}, {text,"foo"}, {key,"bs"}]
func parseScript(s string) []keyToken {
	var tokens []keyToken
	for len(s) > 0 {
		lt := strings.Index(s, "<")
		if lt < 0 {
			tokens = append(tokens, keyToken{false, s})
			break
		}
		if lt > 0 {
			tokens = append(tokens, keyToken{false, s[:lt]})
			s = s[lt:]
		}
		gt := strings.Index(s, ">")
		if gt < 0 {
			tokens = append(tokens, keyToken{false, s})
			break
		}
		tokens = append(tokens, keyToken{true, s[1:gt]})
		s = s[gt+1:]
	}
	return tokens
}

// xkbKeys maps vim-style names to XKB key names (used by both xdotool and wtype).
var xkbKeys = map[string]string{
	"cr": "Return", "enter": "Return",
	"bs": "BackSpace", "backspace": "BackSpace",
	"esc": "Escape", "escape": "Escape",
	"tab": "Tab", "space": "space",
	"del": "Delete", "delete": "Delete",
	"ins": "Insert", "insert": "Insert",
	"up": "Up", "down": "Down", "left": "Left", "right": "Right",
}

// parseVimKey splits a vim-style key like "C-A-space" into modifier names
// (["ctrl","alt"]) and the final XKB key name ("space").
func parseVimKey(key string) (mods []string, xkbKey string) {
	lo := strings.ToLower(key)
	for len(lo) >= 3 && lo[1] == '-' {
		var mod string
		switch lo[0] {
		case 'c':
			mod = "ctrl"
		case 'm', 'a':
			mod = "alt"
		case 's':
			mod = "shift"
		}
		if mod == "" {
			break
		}
		mods = append(mods, mod)
		lo = lo[2:]
	}
	if k, ok := xkbKeys[lo]; ok {
		xkbKey = k
	} else {
		xkbKey = lo
	}
	return
}


// vimToWtypeArgs returns wtype flag(s) for a vim-style key name.
func vimToWtypeArgs(key string) []string {
	mods, xkbKey := parseVimKey(key)
	if len(mods) == 0 {
		return []string{"-k", xkbKey}
	}
	var args []string
	for _, m := range mods {
		args = append(args, "-M", m)
	}
	args = append(args, "-k", xkbKey)
	for i := len(mods) - 1; i >= 0; i-- {
		args = append(args, "-m", mods[i])
	}
	return args
}

func parsePause(s string) (time.Duration, error) {
	return time.ParseDuration(s)
}

// SubtitleEntry records a timed text overlay for burn-in into the final video.
type SubtitleEntry struct {
	Start time.Duration
	Text  string
}

// SubtitleCollector accumulates subtitle entries relative to a recording start.
type SubtitleCollector struct {
	start   time.Time
	Entries []SubtitleEntry
}

func NewSubtitleCollector() *SubtitleCollector {
	return &SubtitleCollector{start: time.Now()}
}

func (c *SubtitleCollector) Mark(text string) {
	c.Entries = append(c.Entries, SubtitleEntry{Start: time.Since(c.start), Text: text})
}

var modDisplayName = map[string]string{"ctrl": "Ctrl", "alt": "Alt", "shift": "Shift"}
var keyDisplayName = map[string]string{
	"Return": "Enter", "BackSpace": "Backspace", "Escape": "Esc",
	"Tab": "Tab", "space": "Space", "Delete": "Delete", "Insert": "Insert",
	"Up": "Up", "Down": "Down", "Left": "Left", "Right": "Right",
}

// formatVimKey converts a vim-style key like "C-A-space" to "Ctrl+Alt+Space".
func formatVimKey(key string) string {
	mods, xkbKey := parseVimKey(key)
	var parts []string
	for _, m := range mods {
		if d, ok := modDisplayName[m]; ok {
			parts = append(parts, d)
		}
	}
	if d, ok := keyDisplayName[xkbKey]; ok {
		parts = append(parts, d)
	} else {
		parts = append(parts, strings.ToUpper(xkbKey))
	}
	return strings.Join(parts, "+")
}

// stepLabel returns a human-readable key label for a show_keys subtitle.
func stepLabel(step ScriptStep) string {
	tokens := parseScript(step.Type)
	var parts []string
	for _, tok := range tokens {
		if tok.isKey {
			parts = append(parts, formatVimKey(tok.value))
		}
	}
	if len(parts) == 0 {
		return step.Type
	}
	return strings.Join(parts, " ")
}


func srtTime(d time.Duration) string {
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60
	ms := int(d.Milliseconds()) % 1000
	return fmt.Sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
}

func writeSRT(path string, entries []SubtitleEntry, dur time.Duration) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	for i, e := range entries {
		end := e.Start + dur
		if i+1 < len(entries) && entries[i+1].Start < end {
			end = entries[i+1].Start - 50*time.Millisecond
		}
		fmt.Fprintf(f, "%d\n%s --> %s\n%s\n\n", i+1, srtTime(e.Start), srtTime(end), e.Text)
	}
	return nil
}

func probeVideoDuration(path string) time.Duration {
	out, _ := exec.Command("ffprobe", "-v", "error",
		"-show_entries", "format=duration",
		"-of", "csv=p=0", path).Output()
	secs, _ := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	return time.Duration(secs * float64(time.Second))
}

func printProgress(label string, pct int) {
	const width = 25
	filled := pct * width / 100
	fmt.Printf("\r  %s [%s%s] %3d%%",
		label,
		strings.Repeat("█", filled),
		strings.Repeat("░", width-filled),
		pct)
}

// addSubtitles burns subtitles into videoPath using libass with SRT + force_style.
// Shows a progress bar; on failure warns and leaves the original video intact.
func addSubtitles(videoPath, bitrate string, entries []SubtitleEntry) {
	if len(entries) == 0 {
		return
	}
	srtPath := videoPath + ".srt"
	if err := writeSRT(srtPath, entries, 1200*time.Millisecond); err != nil {
		fmt.Printf("Warning: failed to write SRT: %v (skipping subtitles)\n", err)
		return
	}
	defer os.Remove(srtPath)

	totalDur := probeVideoDuration(videoPath)
	tmpPath := videoPath + ".tmp.webm"
	vf := fmt.Sprintf("subtitles=%s:force_style='FontSize=22,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=3,Outline=1,Shadow=1,Alignment=2'", srtPath)
	cmd := exec.Command("ffmpeg",
		"-i", videoPath,
		"-vf", vf,
		"-c:v", "libvpx-vp9",
		"-b:v", bitrate,
		"-progress", "pipe:1",
		"-loglevel", "error",
		"-y", tmpPath)
	var errBuf strings.Builder
	cmd.Stderr = &errBuf
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Printf("Warning: subtitle setup failed: %v\n", err)
		return
	}
	if err := cmd.Start(); err != nil {
		fmt.Printf("Warning: subtitle burn-in failed to start: %v\n", err)
		return
	}
	printProgress("Adding subtitles", 0)
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "out_time_us=") {
			us, _ := strconv.ParseInt(strings.TrimPrefix(scanner.Text(), "out_time_us="), 10, 64)
			if totalDur > 0 {
				pct := int(us * 100 / int64(totalDur/time.Microsecond))
				if pct > 100 {
					pct = 100
				}
				printProgress("Adding subtitles", pct)
			}
		}
	}
	if err := cmd.Wait(); err != nil {
		fmt.Printf("\n  Warning: subtitle burn-in failed: %v %s\n", err, strings.TrimSpace(errBuf.String()))
		os.Remove(tmpPath)
		return
	}
	fmt.Printf("\r  Adding subtitles [%s] done\n", strings.Repeat("█", 25))
	if err := os.Rename(tmpPath, videoPath); err != nil {
		fmt.Printf("  Warning: failed to replace video: %v\n", err)
	}
}


// runWtypeScript executes steps via wtype (Wayland / GUI recording).
// onNext is called when a { "next": "name" } step is encountered; pass nil if unused.
// subs collects subtitle entries for show_keys steps; pass nil to skip.
func runWtypeScript(env []string, steps []ScriptStep, stepDelay time.Duration, onNext func(string) error, subs *SubtitleCollector) error {
	for _, step := range steps {
		if step.Pause != "" {
			d, err := parsePause(step.Pause)
			if err != nil {
				return fmt.Errorf("invalid pause %q: %v", step.Pause, err)
			}
			time.Sleep(d)
			continue
		}
		if step.Next != "" {
			if onNext != nil {
				if err := onNext(step.Next); err != nil {
					return err
				}
			}
			continue
		}
		if step.Desc != "" {
			fmt.Printf("  > %s\n", step.Desc)
		}
		if step.ShowKeys && subs != nil {
			subs.Mark(stepLabel(step))
		}
		for _, tok := range parseScript(step.Type) {
			var err error
			if tok.isKey {
				err = wtype(env, vimToWtypeArgs(tok.value)...)
			} else if tok.value != "" {
				err = wtype(env, "-d", "60", tok.value)
			}
			if err != nil {
				return err
			}
		}
		time.Sleep(stepDelay)
	}
	return nil
}

// PromptPart is one colored segment of the TUI shell prompt.
// Color names: black red green yellow blue magenta cyan white,
// and bright_ variants (e.g. "bright_green").
type PromptPart struct {
	Text  string `json:"text"`
	Color string `json:"color"`
}

// ansiColors maps color names to ANSI SGR codes.
var ansiColors = map[string]string{
	"black": "30", "red": "31", "green": "32", "yellow": "33",
	"blue": "34", "magenta": "35", "cyan": "36", "white": "37",
	"bright_black": "90", "bright_red": "91", "bright_green": "92", "bright_yellow": "93",
	"bright_blue": "94", "bright_magenta": "95", "bright_cyan": "96", "bright_white": "97",
}

// renderPS1 converts prompt parts to a zsh PS1 string. Non-printing ANSI
// sequences are wrapped in %{...%} so zsh computes line length correctly.
func renderPS1(parts []PromptPart) string {
	var sb strings.Builder
	for _, p := range parts {
		if code, ok := ansiColors[p.Color]; ok {
			sb.WriteString("%{")
			sb.WriteByte('\x1b')
			sb.WriteString("[" + code + "m%}")
		}
		sb.WriteString(p.Text)
		if p.Color != "" {
			sb.WriteString("%{")
			sb.WriteByte('\x1b')
			sb.WriteString("[0m%}")
		}
	}
	return sb.String()
}
