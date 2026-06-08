// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package emoji

import "strings"

// toLower lowercases a single ASCII byte.
func toLower(b byte) byte {
	if b >= 'A' && b <= 'Z' {
		return b + ('a' - 'A')
	}
	return b
}

// matchTermDirect scores term as a subsequence of target, or returns false.
// Faithful port of src/root.zig:matchTermDirect.
func matchTermDirect(term, target string) (int, bool) {
	if len(term) == 0 {
		return 0, true
	}
	score := 0
	targetIdx := 0
	termIdx := 0
	consecutive := 0
	for termIdx < len(term) {
		if targetIdx >= len(target) {
			return 0, false // not a subsequence
		}
		tc := toLower(term[termIdx])
		gc := toLower(target[targetIdx])
		if tc == gc {
			charScore := 10
			if targetIdx == 0 || target[targetIdx-1] == ' ' {
				charScore += 40 // start-of-word bonus
			}
			if consecutive > 0 {
				charScore += 20 * consecutive // consecutive-match bonus
			}
			score += charScore
			consecutive++
			termIdx++
		} else {
			score-- // small gap penalty
			consecutive = 0
		}
		targetIdx++
	}
	// Penalty for starting late in the target.
	startIdx := targetIdx - len(term)
	score -= startIdx
	return score, true
}

// matchTermSelf scores a term itself (with stem/plural fallbacks) against target.
func matchTermSelf(term, target string) (int, bool) {
	if len(term) == 0 {
		return 0, true
	}
	if s, ok := matchTermDirect(term, target); ok {
		return s, true
	}

	// Plurals: term ends in 's', length > 3.
	if len(term) > 3 && toLower(term[len(term)-1]) == 's' {
		last2 := toLower(term[len(term)-2])
		if last2 != 's' { // avoid "glass", "grass"
			// "...ies" -> "...y" (e.g. "cherries" -> "cherry")
			if len(term) > 5 && len(term) < 60 && last2 == 'e' && toLower(term[len(term)-3]) == 'i' {
				alt := term[:len(term)-3] + "y"
				if s, ok := matchTermDirect(alt, target); ok {
					return s - 5, true
				}
			}
			// "...es" -> "..." or strip trailing "s"
			if len(term) > 4 && last2 == 'e' {
				if s, ok := matchTermDirect(term[:len(term)-2], target); ok {
					return s - 5, true
				}
				if s, ok := matchTermDirect(term[:len(term)-1], target); ok {
					return s - 5, true
				}
			}
			// Default plural strip 's'.
			if s, ok := matchTermDirect(term[:len(term)-1], target); ok {
				return s - 5, true
			}
		}
	}

	// Word stems: term ends in "ing", length > 4.
	if len(term) > 4 && strings.HasSuffix(term, "ing") {
		stem := term[:len(term)-3]
		if s, ok := matchTermDirect(stem, target); ok { // "racing" -> "rac"
			return s - 5, true
		}
		if len(stem) < 60 { // "racing" -> "race"
			if s, ok := matchTermDirect(stem+"e", target); ok {
				return s - 5, true
			}
		}
		if len(stem) > 2 && stem[len(stem)-1] == stem[len(stem)-2] { // "running" -> "run"
			if s, ok := matchTermDirect(stem[:len(stem)-1], target); ok {
				return s - 5, true
			}
		}
	}

	// Query stem: term ends in 'e', length > 3 (e.g. "race" -> "rac").
	if len(term) > 3 && toLower(term[len(term)-1]) == 'e' {
		if s, ok := matchTermDirect(term[:len(term)-1], target); ok {
			return s - 5, true
		}
	}

	return 0, false
}

// matchTerm scores a single term against target with plural/stem fallbacks and synonym matching.
func matchTerm(term, target string, synonyms map[string][]string) (int, bool) {
	if len(term) == 0 {
		return 0, true
	}
	bestScore := 0
	matched := false

	if s, ok := matchTermSelf(term, target); ok {
		bestScore = s
		matched = true
	}

	if synonyms != nil {
		if synList, exists := synonyms[term]; exists {
			for _, syn := range synList {
				if s, ok := matchTermDirect(syn, target); ok {
					if !matched || s > bestScore {
						bestScore = s
						matched = true
					}
				}
			}
		}
	}

	return bestScore, matched
}

// fuzzyMatch scores all space-separated terms; every term must match.
// Faithful port of src/root.zig:fuzzyMatch.
func fuzzyMatch(query, target string, synonyms map[string][]string) (int, bool) {
	total := 0
	hasTerms := false
	for _, term := range strings.FieldsFunc(query, func(r rune) bool {
		return r == ' ' || r == '\t' || r == '\r' || r == '\n'
	}) {
		hasTerms = true
		s, ok := matchTerm(term, target, synonyms)
		if !ok {
			return 0, false
		}
		total += s
	}
	if !hasTerms {
		return 0, true
	}
	return total, true
}

