// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package spec loads the declarative layout, theme, and key-binding specs from
// the embedded JSON files. These specs are the language-neutral contract that a
// future Zig rewrite can consume verbatim.
package spec

import (
	"encoding/json"
	"fmt"

	emojig "codeberg.org/ubunatic/emojig"
)

// GridDims describes a grid configuration (columns, rows, content width).
type GridDims struct {
	Cols  int `json:"cols"`
	Rows  int `json:"rows"`
	Width int `json:"width"`
}

// Cells returns the total number of grid cells.
func (g GridDims) Cells() int { return g.Cols * g.Rows }

// Layout mirrors spec/layout.json.
type Layout struct {
	Description    string   `json:"description"`
	TUI            GridDims `json:"tui"`
	GUI            GridDims `json:"gui"`
	LayoutOverhead int      `json:"layout_overhead"`
	MaxQueryLen    int      `json:"max_query_len"`
	RowsOrder      []string `json:"rows_order"`
}

// Palette holds the semantic colors for one theme. Color indices are xterm
// 256-color values; terminal_bg/fg are hex for OSC sequences.
type Palette struct {
	GridFg        int    `json:"grid_fg"`
	GridBg        *int   `json:"grid_bg"`
	SelectionBg   *int   `json:"selection_bg"`
	SelectionFg   int    `json:"selection_fg"`
	SearchBg      *int   `json:"search_bg"`
	SearchFg      int    `json:"search_fg"`
	SearchShadeFg int    `json:"search_shade_fg"`
	StatusBg      *int   `json:"status_bg"`
	StatusFg      int    `json:"status_fg"`
	StatusShadeFg int    `json:"status_shade_fg"`
	InfoFg        int    `json:"info_fg"`
	InfoBg        *int   `json:"info_bg"`
	BorderBg      *int   `json:"border_bg"`
	BorderShadeFg int    `json:"border_shade_fg"`
	TerminalBg2   string `json:"terminal_bg2"`
	TerminalBg    string `json:"terminal_bg"`
	TerminalFg    string `json:"terminal_fg"`
}

// Theme mirrors spec/theme.json.
type Theme struct {
	Description string             `json:"description"`
	Icons       map[string]string  `json:"icons"`
	Themes      map[string]Palette `json:"themes"`
}

// Keys mirrors spec/keys.json: logical key name -> action name.
type Keys struct {
	Description string            `json:"description"`
	Bindings    map[string]string `json:"bindings"`
}

// Strings mirrors spec/strings.json: editable UI text. {count} in StatusMatches
// is substituted with the live match count by the renderer.
type Strings struct {
	Description    string   `json:"description"`
	SearchPrompt   string   `json:"search_prompt"`
	StatusHelpHint string   `json:"status_help_hint"`
	StatusMatches  string   `json:"status_matches"`
	HelpTitle      string   `json:"help_title"`
	HelpLines      []string `json:"help_lines"`
}

// Specs bundles all loaded declarative specs.
type Specs struct {
	Layout  Layout
	Theme   Theme
	Keys    Keys
	Strings Strings
}

// Load parses all embedded spec files.
func Load() (Specs, error) {
	var s Specs
	for _, p := range []struct {
		name string
		data []byte
		dst  any
	}{
		{"layout", emojig.LayoutJSON, &s.Layout},
		{"theme", emojig.ThemeJSON, &s.Theme},
		{"keys", emojig.KeysJSON, &s.Keys},
		{"strings", emojig.StringsJSON, &s.Strings},
	} {
		if err := json.Unmarshal(p.data, p.dst); err != nil {
			return s, fmt.Errorf("%s spec: %w", p.name, err)
		}
	}
	return s, nil
}
