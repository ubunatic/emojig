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
