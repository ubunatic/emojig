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

func TestBoxArtFilterAndRank(t *testing.T) {
	db, err := Load()
	if err != nil {
		t.Fatalf("failed to load db: %v", err)
	}

	// b: with empty query lists only box art.
	top, total := db.Search("b:", 24)
	if len(top) == 0 || total == 0 {
		t.Fatalf("expected box art entries for 'b:'")
	}
	for _, m := range top {
		if !IsBoxArt(db.Entries[m.Index].Emoji) {
			t.Errorf("expected only box art for 'b:', got %q", db.Entries[m.Index].Emoji)
		}
	}

	// Systematic names hit the exact glyph.
	top, _ = db.Search("b:top left double border", 24)
	if len(top) == 0 || db.Entries[top[0].Index].Emoji != "╔" {
		t.Errorf("expected 'b:top left double border' to rank ╔ first")
	}
	top, _ = db.Search("bottom right border round", 24)
	if len(top) == 0 || db.Entries[top[0].Index].Emoji != "╯" {
		t.Errorf("expected 'bottom right border round' to rank ╯ first")
	}

	// General searches rank box art below genuine emoji matches.
	top, _ = db.Search("left", 24)
	if len(top) == 0 || IsBoxArt(db.Entries[top[0].Index].Emoji) {
		t.Errorf("expected non-box-art first result for 'left'")
	}
}

func TestBrailleFilterDotCountAndOrder(t *testing.T) {
	db, err := Load()
	if err != nil {
		t.Fatalf("failed to load db: %v", err)
	}

	// br: with empty query lists all 256 Braille patterns, sorted by
	// ascending dot count.
	top, total := db.Search("br:", 300)
	if total != 256 || len(top) != 256 {
		t.Fatalf("expected 256 braille entries for 'br:', got total=%d len=%d", total, len(top))
	}
	prevDots := -1
	for _, m := range top {
		emoji := db.Entries[m.Index].Emoji
		if !IsBraille(emoji) {
			t.Errorf("expected only braille for 'br:', got %q", emoji)
		}
		dots := BrailleDotCount(emoji)
		if dots < prevDots {
			t.Errorf("expected ascending dot order, got %d after %d", dots, prevDots)
		}
		prevDots = dots
	}
	if db.Entries[top[0].Index].Emoji != "⠀" {
		t.Errorf("expected blank cell first, got %q", db.Entries[top[0].Index].Emoji)
	}
	if db.Entries[top[len(top)-1].Index].Emoji != "⣿" {
		t.Errorf("expected full 8-dot cell last, got %q", db.Entries[top[len(top)-1].Index].Emoji)
	}

	// "br:<n>" and "br:<n>:" both filter to exactly n raised dots.
	top, total = db.Search("br:1", 300)
	if total != 8 {
		t.Fatalf("expected 8 single-dot braille entries, got %d", total)
	}
	for _, m := range top {
		if d := BrailleDotCount(db.Entries[m.Index].Emoji); d != 1 {
			t.Errorf("expected dot count 1, got %d", d)
		}
	}
	top, _ = db.Search("br:1:", 300)
	if len(top) != 8 {
		t.Errorf("expected 'br:1:' to also list 8 entries, got %d", len(top))
	}

	// br: name search still filters to Braille glyphs only.
	top, _ = db.Search("br:dots 1 2", 300)
	if len(top) == 0 {
		t.Fatalf("expected matches for 'br:dots 1 2'")
	}
	for _, m := range top {
		if !IsBraille(db.Entries[m.Index].Emoji) {
			t.Errorf("expected only braille for 'br:dots 1 2', got %q", db.Entries[m.Index].Emoji)
		}
	}

	// General searches rank Braille patterns below genuine emoji matches.
	top, _ = db.Search("dots", 24)
	if len(top) == 0 || IsBraille(db.Entries[top[0].Index].Emoji) {
		t.Errorf("expected non-braille first result for 'dots'")
	}
}
