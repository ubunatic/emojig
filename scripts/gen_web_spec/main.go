// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type LayoutSpec struct {
	TUI struct {
		Cols  int `json:"cols"`
		Rows  int `json:"rows"`
		Width int `json:"width"`
	} `json:"tui"`
	GUI struct {
		Cols  int `json:"cols"`
		Rows  int `json:"rows"`
		Width int `json:"width"`
	} `json:"gui"`
	LayoutOverhead int `json:"layout_overhead"`
	MaxQueryLen    int `json:"max_query_len"`
}

type StringsSpec struct {
	HelpLines         []string `json:"help_lines"`
	HelpLinesMore     []string `json:"help_lines_more"`
	CursorLeft        string   `json:"cursor_left"`
	CursorRight       string   `json:"cursor_right"`
	MultiSelectMark   string   `json:"multi_select_mark"`
	SearchPlaceholder string   `json:"search_placeholder"`
	SearchPrompt      string   `json:"search_prompt"`
	Status            struct {
		Default struct {
			OnView       string `json:"on_view"`
			OnViewWide   string `json:"on_view_wide"`
			OnSearch     string `json:"on_search"`
			OnSearchWide string `json:"on_search_wide"`
		} `json:"default"`
	} `json:"status"`
}

type CategoriesSpec struct {
	Categories []CategorySpec `json:"categories"`
}

type CategorySpec struct {
	Name     string   `json:"name"`
	Short    string   `json:"short"`
	Icon     string   `json:"icon"`
	Switcher bool     `json:"switcher"`
	Synonyms []string `json:"synonyms"`
}

type GlyphSpec struct {
	Entries []GlyphEntry `json:"entries"`
}

type GlyphEntry struct {
	Char string `json:"char"`
}

type WebSpec struct {
	GeneratedFrom []string       `json:"generated_from"`
	Layout        WebLayoutSpec  `json:"layout"`
	Strings       WebStringsSpec `json:"strings"`
	Categories    []CategorySpec `json:"categories"`
	Filters       WebFilterSpec  `json:"filters"`
}

type WebLayoutSpec struct {
	Cols           int `json:"cols"`
	Rows           int `json:"rows"`
	Width          int `json:"width"`
	LayoutOverhead int `json:"layout_overhead"`
	MaxQueryLen    int `json:"max_query_len"`
	MaxResults     int `json:"max_results"`
	MinCols        int `json:"min_cols"`
	MinRows        int `json:"min_rows"`
	MaxCols        int `json:"max_cols"`
	MaxRows        int `json:"max_rows"`
}

type WebStringsSpec struct {
	HelpLines         []string             `json:"help_lines"`
	HelpLinesMore     []string             `json:"help_lines_more"`
	CursorLeft        string               `json:"cursor_left"`
	CursorRight       string               `json:"cursor_right"`
	MultiSelectMark   string               `json:"multi_select_mark"`
	SearchPlaceholder string               `json:"search_placeholder"`
	SearchPrompt      string               `json:"search_prompt"`
	StatusDefault     WebStatusDefaultSpec `json:"status_default"`
}

type WebStatusDefaultSpec struct {
	OnView       string `json:"on_view"`
	OnViewWide   string `json:"on_view_wide"`
	OnSearch     string `json:"on_search"`
	OnSearchWide string `json:"on_search_wide"`
}

type WebFilterSpec struct {
	BoxArt  WebRangeFilterSpec `json:"box_art"`
	Braille WebRangeFilterSpec `json:"braille"`
}

type WebRangeFilterSpec struct {
	MinCodepoint int `json:"min_codepoint"`
	MaxCodepoint int `json:"max_codepoint"`
	Penalty      int `json:"penalty"`
	Count        int `json:"count"`
}

func main() {
	layout := mustReadJSON[LayoutSpec]("spec/layout.json")
	stringsSpec := mustReadJSON[StringsSpec]("spec/strings.json")
	categories := mustReadJSON[CategoriesSpec]("spec/categories.json")
	boxart := mustReadJSON[GlyphSpec]("spec/boxart.json")
	braille := mustReadJSON[GlyphSpec]("spec/braille.json")

	web := WebSpec{
		GeneratedFrom: []string{
			"spec/layout.json",
			"spec/strings.json",
			"spec/categories.json",
			"spec/boxart.json",
			"spec/braille.json",
		},
		Layout: WebLayoutSpec{
			Cols:           layout.GUI.Cols,
			Rows:           layout.GUI.Rows,
			Width:          layout.GUI.Width,
			LayoutOverhead: layout.LayoutOverhead,
			MaxQueryLen:    layout.MaxQueryLen,
			MaxResults:     5 * 16 * 16,
			MinCols:        5,
			MinRows:        3,
			MaxCols:        16,
			MaxRows:        16,
		},
		Strings: WebStringsSpec{
			HelpLines:         stringsSpec.HelpLines,
			HelpLinesMore:     stringsSpec.HelpLinesMore,
			CursorLeft:        stringsSpec.CursorLeft,
			CursorRight:       stringsSpec.CursorRight,
			MultiSelectMark:   stringsSpec.MultiSelectMark,
			SearchPlaceholder: stringsSpec.SearchPlaceholder,
			SearchPrompt:      stringsSpec.SearchPrompt,
			StatusDefault: WebStatusDefaultSpec{
				OnView:       stringsSpec.Status.Default.OnView,
				OnViewWide:   stringsSpec.Status.Default.OnViewWide,
				OnSearch:     stringsSpec.Status.Default.OnSearch,
				OnSearchWide: stringsSpec.Status.Default.OnSearchWide,
			},
		},
		Categories: categories.Categories,
		Filters: WebFilterSpec{
			BoxArt:  rangeSpec(boxart, 150),
			Braille: rangeSpec(braille, 150),
		},
	}

	var jsonBuf bytes.Buffer
	enc := json.NewEncoder(&jsonBuf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(web); err != nil {
		fatalf("encode web spec: %v", err)
	}

	var out bytes.Buffer
	out.WriteString("/*\n")
	out.WriteString(" * SPDX-FileCopyrightText: 2026 Uwe Jugel\n")
	out.WriteString(" * SPDX-License-Identifier: AGPL-3.0-or-later\n")
	out.WriteString(" */\n\n")
	out.WriteString("// generated from spec/*.json by scripts/gen_web_spec; do not edit by hand\n")
	out.WriteString("const EMOJIG_WEB_SPEC = ")
	out.Write(bytes.TrimSpace(jsonBuf.Bytes()))
	out.WriteString(";\n")

	outPath := "website/webspec.js"
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fatalf("mkdir %s: %v", filepath.Dir(outPath), err)
	}
	if err := os.WriteFile(outPath, out.Bytes(), 0o644); err != nil {
		fatalf("write %s: %v", outPath, err)
	}
}

func mustReadJSON[T any](path string) T {
	data, err := os.ReadFile(path)
	if err != nil {
		fatalf("read %s: %v", path, err)
	}
	var value T
	if err := json.Unmarshal(data, &value); err != nil {
		fatalf("parse %s: %v", path, err)
	}
	return value
}

func rangeSpec(spec GlyphSpec, penalty int) WebRangeFilterSpec {
	out := WebRangeFilterSpec{
		MinCodepoint: 0,
		MaxCodepoint: 0,
		Penalty:      penalty,
		Count:        len(spec.Entries),
	}
	for _, entry := range spec.Entries {
		for _, r := range entry.Char {
			cp := int(r)
			if out.MinCodepoint == 0 || cp < out.MinCodepoint {
				out.MinCodepoint = cp
			}
			if cp > out.MaxCodepoint {
				out.MaxCodepoint = cp
			}
			break
		}
	}
	return out
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
