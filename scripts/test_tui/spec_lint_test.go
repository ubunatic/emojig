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

func TestSpecSettingsOptionsHaveHelp(t *testing.T) {
	var settings struct {
		Title        string `json:"title"`
		HelpFallback string `json:"help_fallback"`
		Options      []struct {
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

// hostArgPlaceholders must mirror src/host.zig ArgValues — a template entry
// naming an unknown placeholder is silently dropped at runtime, so catch
// typos here.
var hostArgPlaceholders = map[string]bool{
	"title": true, "size": true, "font": true, "bg": true, "fg": true,
	"border_color": true, "csd_size": true, "csd_color": true, "csd_title_font": true,
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
	placeholderRe := regexp.MustCompile(`\{([a-z_]+)\}`)
	for _, term := range host.Terminals {
		if term.Name == "" {
			t.Error("host.yaml: terminal entry without name")
		}
		byName[term.Name] = true
		for _, list := range [][]string{term.Args, term.BorderlessArgs, term.DecoratedArgs, term.PostArgs} {
			for _, arg := range list {
				for _, m := range placeholderRe.FindAllStringSubmatch(arg, -1) {
					if !hostArgPlaceholders[m[1]] {
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
	if layout.MruSize > 64 {
		t.Errorf("layout.yaml mru_size: %d exceeds the compile-time bound 64 (src/mru.zig MAX_MRU)", layout.MruSize)
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
