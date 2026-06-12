// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package emoji

import (
	"testing"
)

func TestSearchPrefixFilters(t *testing.T) {
	db, err := Load()
	if err != nil {
		t.Fatalf("failed to load db: %v", err)
	}

	// 1. Test "e:arrow"
	top, _ := db.Search("e:arrow", 24)
	if len(top) == 0 {
		t.Errorf("expected some matches for e:arrow")
	}
	for _, m := range top {
		e := db.Entries[m.Index]
		if Width(e.Emoji) != 2 {
			t.Errorf("expected emoji width 2 for %s, got %d", e.Emoji, Width(e.Emoji))
		}
	}

	// 2. Test "t:arrow"
	top, _ = db.Search("t:arrow", 24)
	if len(top) == 0 {
		t.Errorf("expected some matches for t:arrow")
	}
	for _, m := range top {
		e := db.Entries[m.Index]
		if Width(e.Emoji) != 1 {
			t.Errorf("expected emoji width 1 for %s, got %d", e.Emoji, Width(e.Emoji))
		}
	}

	// 3. Test empty prefix: "e:"
	top, _ = db.Search("e:", 24)
	if len(top) == 0 {
		t.Errorf("expected some matches for e:")
	}
	for _, m := range top {
		e := db.Entries[m.Index]
		if Width(e.Emoji) != 2 {
			t.Errorf("expected emoji width 2 for %s, got %d", e.Emoji, Width(e.Emoji))
		}
	}

	// 4. Test empty prefix: "t:"
	top, _ = db.Search("t:", 24)
	if len(top) == 0 {
		t.Errorf("expected some matches for t:")
	}
	for _, m := range top {
		e := db.Entries[m.Index]
		if Width(e.Emoji) != 1 {
			t.Errorf("expected emoji width 1 for %s, got %d", e.Emoji, Width(e.Emoji))
		}
	}
}

func TestSearchSynonymRanking(t *testing.T) {
	db, err := Load()
	if err != nil {
		t.Fatalf("failed to load db: %v", err)
	}

	top, _ := db.Search("car", 24)
	if len(top) < 2 {
		t.Fatalf("expected at least 2 matches for query 'car', got %d", len(top))
	}

	carPos := -1
	tramPos := -1
	for pos, m := range top {
		e := db.Entries[m.Index]
		if e.Emoji == "🚗" {
			carPos = pos
		} else if e.Emoji == "🚋" {
			tramPos = pos
		}
	}

	if carPos == -1 {
		t.Errorf("expected to find automobile '🚗' in search results for 'car'")
	}
	if tramPos == -1 {
		t.Errorf("expected to find tram car '🚋' in search results for 'car'")
	}
	if carPos != -1 && tramPos != -1 && carPos >= tramPos {
		t.Errorf("expected automobile '🚗' (rank %d) to outrank tram car '🚋' (rank %d)", carPos, tramPos)
	}
}

func TestPlainTwinsDiscoverable(t *testing.T) {
	db, err := Load()
	if err != nil {
		t.Fatalf("failed to load db: %v", err)
	}

	gearPlain := "⚙︎" // ⚙ + VS15
	gearEmoji := "⚙️" // ⚙ + VS16

	// VS15 forces text presentation: single-width, so t: lists it.
	if w := Width(gearPlain); w != 1 {
		t.Errorf("expected width 1 for plain gear, got %d", w)
	}
	if w := Width(gearEmoji); w != 2 {
		t.Errorf("expected width 2 for emoji gear, got %d", w)
	}

	// "t:gear" must surface the plain twin.
	top, _ := db.Search("t:gear", 24)
	foundPlain := false
	for _, m := range top {
		if db.Entries[m.Index].Emoji == gearPlain {
			foundPlain = true
		}
	}
	if !foundPlain {
		t.Errorf("expected 't:gear' to surface the plain twin ⚙︎")
	}

	// The "plain" keyword narrows a general search to the twin.
	top, _ = db.Search("gear plain", 24)
	if len(top) == 0 || db.Entries[top[0].Index].Emoji != gearPlain {
		t.Errorf("expected 'gear plain' to rank the plain twin first")
	}

	// The color twin is still there for the general query.
	top, _ = db.Search("gear", 24)
	foundColor := false
	for _, m := range top {
		if db.Entries[m.Index].Emoji == gearEmoji {
			foundColor = true
		}
	}
	if !foundColor {
		t.Errorf("expected 'gear' to still surface the color emoji ⚙️")
	}
}
