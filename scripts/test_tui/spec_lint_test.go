// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Spec lint: fast integration checks over the generated spec artifacts in
// spec/.gen/. The YAML sources in spec/ are the primary developer surface,
// so these tests catch spec mistakes (missing fields, typo'd placeholders,
// broken invariants) at test time instead of silently at runtime.

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func readSpecJSON(t *testing.T, rel string, v any) {
	t.Helper()
	path := filepath.Join("..", "..", "spec", ".gen", rel)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v (run `make gen-spec`)", path, err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
}

// readZigSource returns the contents of a file under src/, for lints that
// cross-check spec values against the Zig source of truth instead of
// hand-mirroring magic numbers here (issue 46).
func readZigSource(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join("..", "..", "src", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

// zigIntConst extracts `pub const NAME: usize = N;` from Zig source text.
func zigIntConst(t *testing.T, src, file, name string) int {
	t.Helper()
	re := regexp.MustCompile(`pub const ` + name + `[^=\n]*=\s*(\d+)\s*;`)
	m := re.FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("%s: could not find `pub const %s = <int>;` (lint needs updating?)", file, name)
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		t.Fatalf("%s: bad integer for %s: %v", file, name, err)
	}
	return n
}

// zigStructFields extracts the field names of `pub const NAME = struct {...}`.
func zigStructFields(t *testing.T, src, file, name string) []string {
	t.Helper()
	re := regexp.MustCompile(`pub const ` + name + ` = struct \{([^}]*)\}`)
	m := re.FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("%s: could not find `pub const %s = struct {...}` (lint needs updating?)", file, name)
	}
	fieldRe := regexp.MustCompile(`(?m)^\s*([a-z_][a-z0-9_]*)\s*:`)
	var fields []string
	for _, f := range fieldRe.FindAllStringSubmatch(m[1], -1) {
		fields = append(fields, f[1])
	}
	if len(fields) == 0 {
		t.Fatalf("%s: no fields parsed from struct %s", file, name)
	}
	return fields
}

func TestSpecSettingsOptionsHaveHelp(t *testing.T) {
	var settings struct {
		Title          string `json:"title"`
		MaxHelpLineLen int    `json:"max_help_line_len"`
		HelpFallback   string `json:"help_fallback"`
		Options        []struct {
			ID      string `json:"id"`
			Type    string `json:"type"`
			Label   string `json:"label"`
			Default string `json:"default"`
			Help    string `json:"help"`
		} `json:"options"`
	}
	readSpecJSON(t, "settings.json", &settings)

	if settings.HelpFallback == "" {
		t.Error("settings.yaml: help_fallback must be set (shown when a row has no help)")
	}
	if settings.MaxHelpLineLen <= 0 {
		t.Fatal("settings.yaml: max_help_line_len must be set (per-line help modal budget)")
	}
	// Help lines longer than the budget are silently truncated in the modal
	// (issue 46 §5.5): enforce the spec's own bound on every line.
	checkHelpLines := func(id, help string) {
		for _, line := range strings.Split(help, "\n") {
			if n := len([]rune(line)); n > settings.MaxHelpLineLen {
				t.Errorf("settings.yaml %s: help line %q is %d chars, exceeds max_help_line_len=%d (truncated in the modal)",
					id, line, n, settings.MaxHelpLineLen)
			}
		}
	}
	checkHelpLines("help_fallback", settings.HelpFallback)
	if len(settings.Options) == 0 {
		t.Fatal("settings.yaml: no options defined")
	}
	seen := map[string]bool{}
	for i, opt := range settings.Options {
		if opt.ID == "" || opt.Label == "" || opt.Type == "" {
			t.Errorf("settings.yaml option %d: id/label/type must be set", i)
		}
		if seen[opt.ID] {
			t.Errorf("settings.yaml option %q: duplicate id", opt.ID)
		}
		seen[opt.ID] = true
		if opt.Help == "" {
			t.Errorf("settings.yaml option %q: missing help text (shown by ?/h/F1)", opt.ID)
		}
		checkHelpLines(opt.ID, opt.Help)
	}
}

func TestSpecSearchWeights(t *testing.T) {
	var search struct {
		Scoring struct {
			CharMatch        int `json:"char_match"`
			WordStartBonus   int `json:"word_start_bonus"`
			ConsecutiveBonus int `json:"consecutive_bonus"`
			GapPenalty       int `json:"gap_penalty"`
			LateStartPenalty int `json:"late_start_penalty"`
			LengthPenalty    int `json:"length_penalty"`
			ExactWordBonus   int `json:"exact_word_bonus"`
			FallbackPenalty  int `json:"fallback_penalty"`
		} `json:"scoring"`
		Penalties struct {
			BoxArt  int `json:"box_art"`
			Braille int `json:"braille"`
		} `json:"penalties"`
	}
	readSpecJSON(t, "search.json", &search)

	positive := map[string]int{
		"scoring.char_match":       search.Scoring.CharMatch,
		"scoring.word_start_bonus": search.Scoring.WordStartBonus,
		"scoring.exact_word_bonus": search.Scoring.ExactWordBonus,
		"scoring.fallback_penalty": search.Scoring.FallbackPenalty,
		"penalties.box_art":        search.Penalties.BoxArt,
		"penalties.braille":        search.Penalties.Braille,
	}
	for name, v := range positive {
		if v <= 0 {
			t.Errorf("search.yaml %s: must be positive, got %d", name, v)
		}
	}
	if search.Scoring.WordStartBonus <= search.Scoring.CharMatch {
		t.Error("search.yaml: word_start_bonus should exceed char_match (word starts must rank above mid-word hits)")
	}
}

// hostArgPlaceholders returns the valid template placeholders parsed
// straight from src/host.zig's ArgValues struct — a template entry naming
// an unknown placeholder is silently dropped at runtime, so catch typos
// here without hand-mirroring the field list (issue 46 §4).
func hostArgPlaceholders(t *testing.T) map[string]bool {
	t.Helper()
	src := readZigSource(t, "host.zig")
	valid := map[string]bool{}
	for _, f := range zigStructFields(t, src, "src/host.zig", "ArgValues") {
		valid[f] = true
	}
	return valid
}

func TestSpecHostTerminals(t *testing.T) {
	var host struct {
		Detection []string `json:"detection"`
		Terminals []struct {
			Name           string   `json:"name"`
			Args           []string `json:"args"`
			BorderlessArgs []string `json:"borderless_args"`
			DecoratedArgs  []string `json:"decorated_args"`
			PostArgs       []string `json:"post_args"`
			TailSeparator  string   `json:"tail_separator"`
		} `json:"terminals"`
	}
	readSpecJSON(t, "host.json", &host)

	if len(host.Detection) == 0 {
		t.Fatal("host.yaml: detection list is empty")
	}
	if host.Detection[0] != "foot" {
		t.Errorf("host.yaml: foot must stay first in detection (cell-precise sizing), got %q", host.Detection[0])
	}
	byName := map[string]bool{}
	placeholders := hostArgPlaceholders(t)
	placeholderRe := regexp.MustCompile(`\{([a-z_]+)\}`)
	for _, term := range host.Terminals {
		if term.Name == "" {
			t.Error("host.yaml: terminal entry without name")
		}
		byName[term.Name] = true
		for _, list := range [][]string{term.Args, term.BorderlessArgs, term.DecoratedArgs, term.PostArgs} {
			for _, arg := range list {
				for _, m := range placeholderRe.FindAllStringSubmatch(arg, -1) {
					if !placeholders[m[1]] {
						t.Errorf("host.yaml terminal %q: unknown placeholder {%s} in %q (entry would be dropped at runtime)", term.Name, m[1], arg)
					}
				}
			}
		}
	}
	if !byName["generic"] {
		t.Error("host.yaml: missing `generic` fallback terminal entry")
	}
	for _, name := range host.Detection {
		if !byName[name] {
			t.Errorf("host.yaml: detection candidate %q has no terminals entry", name)
		}
	}
}

func TestSpecLayoutInteraction(t *testing.T) {
	var layout struct {
		GUI struct {
			Cols     int `json:"cols"`
			Rows     int `json:"rows"`
			FontSize int `json:"font_size"`
		} `json:"gui"`
		MruSize   int `json:"mru_size"`
		Animation struct {
			Steps int `json:"exit_preview_steps"`
			Ms    int `json:"exit_preview_ms"`
		} `json:"animation"`
		Interaction struct {
			WheelScrollStep int `json:"wheel_scroll_step"`
			GridDimStep     int `json:"grid_dim_step"`
		} `json:"interaction"`
	}
	readSpecJSON(t, "layout.json", &layout)

	checks := map[string]int{
		"gui.font_size":                 layout.GUI.FontSize,
		"mru_size":                      layout.MruSize,
		"animation.exit_preview_steps":  layout.Animation.Steps,
		"interaction.wheel_scroll_step": layout.Interaction.WheelScrollStep,
		"interaction.grid_dim_step":     layout.Interaction.GridDimStep,
	}
	for name, v := range checks {
		if v <= 0 {
			t.Errorf("layout.yaml %s: must be positive, got %d", name, v)
		}
	}
	// Cross-check against the real compile-time bound instead of a
	// hand-mirrored 64 (issue 46 §4a).
	maxMru := zigIntConst(t, readZigSource(t, "mru.zig"), "src/mru.zig", "MAX_MRU")
	if layout.MruSize > maxMru {
		t.Errorf("layout.yaml mru_size: %d exceeds the compile-time bound %d (src/mru.zig MAX_MRU)", layout.MruSize, maxMru)
	}
}

// TestSpecLayoutGridBoundsMatchDefaults asserts that the spec's default grid
// dimensions fit inside the compile-time clamp bounds in src/defaults.zig
// (issue 46 §5.4) — the bounds size stack buffers, so a spec default outside
// them would be silently clamped (min) or overflow assertions (max).
func TestSpecLayoutGridBoundsMatchDefaults(t *testing.T) {
	var layout struct {
		TUI struct {
			Cols int `json:"cols"`
			Rows int `json:"rows"`
		} `json:"tui"`
		GUI struct {
			Cols int `json:"cols"`
			Rows int `json:"rows"`
		} `json:"gui"`
	}
	readSpecJSON(t, "layout.json", &layout)

	src := readZigSource(t, "defaults.zig")
	minCols := zigIntConst(t, src, "src/defaults.zig", "MIN_COLS")
	maxCols := zigIntConst(t, src, "src/defaults.zig", "MAX_COLS")
	minRows := zigIntConst(t, src, "src/defaults.zig", "MIN_ROWS")
	maxRows := zigIntConst(t, src, "src/defaults.zig", "MAX_ROWS")

	if minCols >= maxCols || minRows >= maxRows {
		t.Fatalf("src/defaults.zig: inconsistent clamp bounds cols [%d,%d] rows [%d,%d]", minCols, maxCols, minRows, maxRows)
	}
	grids := map[string][2]int{
		"tui": {layout.TUI.Cols, layout.TUI.Rows},
		"gui": {layout.GUI.Cols, layout.GUI.Rows},
	}
	for name, g := range grids {
		if g[0] < minCols || g[0] > maxCols {
			t.Errorf("layout.yaml %s.cols=%d outside src/defaults.zig clamp [%d,%d]", name, g[0], minCols, maxCols)
		}
		if g[1] < minRows || g[1] > maxRows {
			t.Errorf("layout.yaml %s.rows=%d outside src/defaults.zig clamp [%d,%d]", name, g[1], minRows, maxRows)
		}
	}
}

func TestSpecStringsLocalesParse(t *testing.T) {
	langs := []string{"", "_de", "_es", "_fr", "_it", "_nl", "_pl", "_pt", "_ru", "_tr", "_uk"}
	for _, lang := range langs {
		var strings struct {
			SearchPlaceholder string `json:"search_placeholder"`
			MruCleared        string `json:"mru_cleared"`
		}
		file := fmt.Sprintf("strings%s.json", lang)
		readSpecJSON(t, file, &strings)
		if strings.SearchPlaceholder == "" {
			t.Errorf("%s: search_placeholder must be set", file)
		}
		if strings.MruCleared == "" {
			t.Errorf("%s: mru_cleared must be set", file)
		}
	}
}

// zigEnumTags extracts the tag names of `pub const NAME = enum {...}`. The
// capture stops at the first `}` (inside a method body if the enum has any),
// which is fine because Zig convention puts all tags before the methods.
func zigEnumTags(t *testing.T, src, file, name string) []string {
	t.Helper()
	re := regexp.MustCompile(`pub const ` + name + ` = enum \{([^}]*)`)
	m := re.FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("%s: could not find `pub const %s = enum {...}` (lint needs updating?)", file, name)
	}
	tagRe := regexp.MustCompile(`(?m)^\s*([a-z_][a-z0-9_]*),`)
	var tags []string
	for _, f := range tagRe.FindAllStringSubmatch(m[1], -1) {
		tags = append(tags, f[1])
	}
	if len(tags) == 0 {
		t.Fatalf("%s: no tags parsed from enum %s", file, name)
	}
	return tags
}

// zigStringArray extracts the elements of `const NAME = [_][]const u8{...}`.
func zigStringArray(t *testing.T, src, file, name string) []string {
	t.Helper()
	re := regexp.MustCompile(`const ` + name + ` = \[_\]\[\]const u8\{([^}]*)\}`)
	m := re.FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("%s: could not find `const %s = [_][]const u8{...}` (lint needs updating?)", file, name)
	}
	elemRe := regexp.MustCompile(`"([^"]+)"`)
	var elems []string
	for _, f := range elemRe.FindAllStringSubmatch(m[1], -1) {
		elems = append(elems, f[1])
	}
	if len(elems) == 0 {
		t.Fatalf("%s: no strings parsed from array %s", file, name)
	}
	return elems
}

// TestSpecInputBindingsResolve asserts the spec/input.yaml `bindings:` table
// against the Zig source of truth (issue 46 §4 input lint gap): every bound
// action must be a tag of src/input.zig's Action enum, and every bound key
// name must be producible by the decoder — either a key_sequences name or one
// of main.zig's hardcoded single-byte decodes (mirrored as spec.zig's
// hardcoded_key_names, which the Zig-side spec test also checks against).
func TestSpecInputBindingsResolve(t *testing.T) {
	var input struct {
		Input struct {
			Bindings     map[string]string `json:"bindings"`
			KeySequences []struct {
				Seq  string `json:"seq"`
				Name string `json:"name"`
			} `json:"key_sequences"`
		} `json:"input"`
	}
	readSpecJSON(t, "input.generated.json", &input)
	if len(input.Input.Bindings) == 0 {
		t.Fatal("input.yaml: bindings must not be empty")
	}

	actions := map[string]bool{}
	for _, tag := range zigEnumTags(t, readZigSource(t, "input.zig"), "src/input.zig", "Action") {
		if tag != "none" { // .none marks "unbound"; binding to it is a spec error
			actions[tag] = true
		}
	}
	decodable := map[string]bool{}
	for _, ks := range input.Input.KeySequences {
		decodable[ks.Name] = true
	}
	for _, n := range zigStringArray(t, readZigSource(t, "spec.zig"), "src/spec.zig", "hardcoded_key_names") {
		decodable[n] = true
	}

	for key, action := range input.Input.Bindings {
		if !actions[action] {
			t.Errorf("input.yaml binding %q: action %q is not a src/input.zig Action tag", key, action)
		}
		if !decodable[key] {
			t.Errorf("input.yaml binding %q: no key sequence or hardcoded decode produces this name", key)
		}
	}
}
