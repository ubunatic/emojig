// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package emoji

import "testing"

// Ported from src/root.zig "fuzzy subsequence matching".
func TestFuzzySubsequence(t *testing.T) {
	target := "grinning face smile happy"
	cases := []struct {
		query string
		want  bool
	}{
		{"smile", true},
		{"grn", true},
		{"xyz", false},
		{"face smile", true},
		{"face xyz", false},
	}
	for _, c := range cases {
		if _, ok := fuzzyMatch(c.query, target); ok != c.want {
			t.Errorf("fuzzyMatch(%q) ok = %v, want %v", c.query, ok, c.want)
		}
	}
}

// Ported from src/root.zig "fuzzy matching with plurals and word stems".
func TestFuzzyPluralsAndStems(t *testing.T) {
	target := "racing car"
	for _, q := range []string{"car", "cars", "racing", "race"} {
		s, ok := fuzzyMatch(q, target)
		if !ok {
			t.Errorf("fuzzyMatch(%q) did not match", q)
			continue
		}
		if s <= 0 {
			t.Errorf("fuzzyMatch(%q) score = %d, want > 0", q, s)
		}
	}
}

// Sanity: start-of-word matches should outrank mid-word matches.
func TestStartOfWordBonus(t *testing.T) {
	start, _ := fuzzyMatch("face", "face smile")
	mid, _ := fuzzyMatch("ace", "face smile")
	if start <= mid {
		t.Errorf("start-of-word %d should outscore mid-word %d", start, mid)
	}
}
