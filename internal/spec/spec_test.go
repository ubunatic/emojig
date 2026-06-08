// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package spec

import "testing"

func TestLoad(t *testing.T) {
	s, err := Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if s.Layout.TUI.Cols == 0 {
		t.Error("layout: TUI cols is 0")
	}
	if s.Layout.TUI.Rows == 0 {
		t.Error("layout: TUI rows is 0")
	}
	if len(s.Theme.Themes) == 0 {
		t.Error("theme: no themes loaded")
	}
	if len(s.Keys.Bindings) == 0 {
		t.Error("keys: no bindings loaded")
	}
	if s.Strings.SearchPrompt == "" {
		t.Error("strings: search_prompt is empty")
	}
}

func TestGridDimsCells(t *testing.T) {
	g := GridDims{Cols: 8, Rows: 5}
	if got := g.Cells(); got != 40 {
		t.Errorf("Cells() = %d, want 40", got)
	}
}
