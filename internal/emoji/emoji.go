// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package emoji loads the emoji database and provides the fuzzy search engine.
// The matching logic is a faithful port of src/root.zig so that mojigo returns
// the same ordered results as the Zig emojig binary.
package emoji

import (
	"encoding/json"
	"os"
	"strings"
	"unicode/utf8"

	emojig "codeberg.org/ubunatic/emojig"
)

// zwj is the Zero Width Joiner (U+200D) used in compound emoji sequences (e.g.
// the firefighter 🧑‍🚒). Such sequences render as multiple glyphs ("double
// icons") on terminals without ZWJ support, so they are filtered when
// DisableZWJ is set. Mirrors src/root.zig.
const zwj = "‍"

// Variation selectors: VS16 forces emoji (double-width) presentation, VS15 text.
const (
	vs16 = "️"
	vs15 = "︎"
)

// Entry is a single emoji record.
type Entry struct {
	Emoji  string // the emoji glyph
	Name   string // human description, shown in the UI
	Search string // space-joined unique cleaned search words
}

// Match is a search result: an index into the database plus its score.
type Match struct {
	Index int
	Score int
}

// rawEmoji mirrors the JSON shape of data/emoji.json.
type rawEmoji struct {
	Emoji       string   `json:"emoji"`
	Description string   `json:"description"`
	Aliases     []string `json:"aliases"`
	Tags        []string `json:"tags"`
}

// DB is the loaded emoji database.
type DB struct {
	Entries []Entry
	// DisableZWJ drops ZWJ-sequence emoji from results to avoid the
	// double-glyph rendering seen on VTE-based terminals (Tilix, GNOME).
	DisableZWJ bool
	Synonyms   map[string][]string
}

// detectDisableZWJ mirrors the env logic in src/root.zig:search. Explicit
// EMOJIG_DISABLE_ZWJ wins; otherwise ZWJ is disabled under VTE terminals.
func detectDisableZWJ() bool {
	if v, ok := os.LookupEnv("EMOJIG_DISABLE_ZWJ"); ok {
		switch v {
		case "1", "true":
			return true
		case "0", "false":
			return false
		}
	}
	return os.Getenv("TILIX_ID") != "" || os.Getenv("VTE_VERSION") != ""
}

// Load parses the embedded emoji.json and builds search strings the same way
// scripts/pack_emojis.go builds the embedded binary (unique cleaned words from
// description + tags + aliases).
func Load() (*DB, error) {
	var raw []rawEmoji
	if err := json.Unmarshal(emojig.EmojiJSON, &raw); err != nil {
		return nil, err
	}
	type synonymsFile struct {
		Synonyms map[string][]string `json:"synonyms"`
	}
	var rawSyn synonymsFile
	if err := json.Unmarshal(emojig.SynonymsJSON, &rawSyn); err != nil {
		return nil, err
	}

	db := &DB{
		Entries:    make([]Entry, 0, len(raw)),
		DisableZWJ: detectDisableZWJ(),
		Synonyms:   rawSyn.Synonyms,
	}
	for _, r := range raw {
		if r.Emoji == "" {
			continue
		}
		db.Entries = append(db.Entries, Entry{
			Emoji:  r.Emoji,
			Name:   r.Description,
			Search: buildSearch(r),
		})
	}
	return db, nil
}

// Count returns the number of entries.
func (db *DB) Count() int { return len(db.Entries) }

// skip reports whether entry i should be excluded from results.
func (db *DB) skip(i int) bool {
	return db.DisableZWJ && strings.Contains(db.Entries[i].Emoji, zwj)
}

// cleanWord keeps only ASCII alphanumerics, matching pack_emojis.go.
func cleanWord(word string) string {
	var sb strings.Builder
	for _, r := range word {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// buildSearch assembles the unique, cleaned, lowercased search words.
func buildSearch(r rawEmoji) string {
	var words []string
	seen := map[string]bool{}
	add := func(text string) {
		cleaned := strings.ReplaceAll(text, "-", " ")
		cleaned = strings.ReplaceAll(cleaned, "_", " ")
		for _, w := range strings.Fields(strings.ToLower(cleaned)) {
			cw := cleanWord(w)
			if cw == "" || seen[cw] {
				continue
			}
			seen[cw] = true
			words = append(words, cw)
		}
	}
	add(r.Description)
	for _, t := range r.Tags {
		add(t)
	}
	for _, a := range r.Aliases {
		add(a)
	}
	return strings.Join(words, " ")
}

// Search returns the top matches for query (capped at limit) and the total
// number of matches. Empty query yields the database order (MRU is not part of
// the minimal core). Non-empty query uses fuzzy scoring with insertion sort,
// mirroring src/root.zig:search. ZWJ entries are skipped when DisableZWJ is set.
func (db *DB) Search(query string, limit int) (top []Match, total int) {
	actualQuery := query
	filterWidth := 0
	if len(query) >= 2 {
		if (query[0] == 'e' || query[0] == 'E') && query[1] == ':' {
			actualQuery = query[2:]
			filterWidth = 2
		} else if (query[0] == 't' || query[0] == 'T') && query[1] == ':' {
			actualQuery = query[2:]
			filterWidth = 1
		}
	}

	if strings.TrimSpace(actualQuery) == "" {
		top = make([]Match, 0, limit)
		for i := range db.Entries {
			if db.skip(i) {
				continue
			}
			if filterWidth > 0 && Width(db.Entries[i].Emoji) != filterWidth {
				continue
			}
			total++
			if len(top) < limit {
				top = append(top, Match{Index: i, Score: 0})
			}
		}
		return top, total
	}

	top = make([]Match, 0, limit)
	for i := range db.Entries {
		if db.skip(i) {
			continue
		}
		if filterWidth > 0 && Width(db.Entries[i].Emoji) != filterWidth {
			continue
		}
		score, ok := fuzzyMatch(actualQuery, db.Entries[i].Search, db.Synonyms)
		if !ok {
			continue
		}
		total++
		m := Match{Index: i, Score: score}
		// Find insertion position (descending score, stable on ties).
		pos := 0
		for pos < len(top) {
			if m.Score > top[pos].Score {
				break
			}
			pos++
		}
		if pos >= limit {
			continue
		}
		if len(top) < limit {
			top = append(top, Match{})
		}
		copy(top[pos+1:], top[pos:len(top)-1])
		top[pos] = m
	}
	return top, total
}

// Width returns the terminal display width (1 or 2 columns) of an emoji glyph.
// Faithful port of src/root.zig:getEmojiWidth.
func Width(emoji string) int {
	if len(emoji) == 0 {
		return 0
	}
	// VS16 forces double-width presentation.
	if strings.Contains(emoji, vs16) {
		return 2
	}
	cp, _ := utf8.DecodeRuneInString(emoji)
	if cp == utf8.RuneError {
		return 2
	}
	// Emoji plane.
	if cp >= 0x1F000 {
		return 2
	}
	// BMP double-width emoji code points (no VS16 in the JSON).
	switch {
	case cp == 0x231A || cp == 0x231B || cp == 0x23F3,
		cp >= 0x23E9 && cp <= 0x23EC,
		cp == 0x23F0,
		cp == 0x2B50 || cp == 0x2B55 || cp == 0x2B1B || cp == 0x2B1C,
		cp >= 0x3000 && cp <= 0x32FF:
		return 2
	case cp == 0x25FD || cp == 0x25FE,
		cp == 0x2614 || cp == 0x2615,
		cp >= 0x2648 && cp <= 0x2653,
		cp == 0x267F,
		cp == 0x2693,
		cp == 0x26A1,
		cp == 0x26BD || cp == 0x26BE,
		cp == 0x26C4 || cp == 0x26C5,
		cp == 0x26D4,
		cp == 0x26EA,
		cp == 0x26F2 || cp == 0x26F3,
		cp == 0x26F5,
		cp == 0x26FA,
		cp == 0x26FD,
		cp == 0x2705,
		cp == 0x270A || cp == 0x270B,
		cp == 0x2728,
		cp == 0x274C,
		cp == 0x274E,
		cp >= 0x2753 && cp <= 0x2755, cp == 0x2757,
		cp >= 0x2795 && cp <= 0x2797,
		cp == 0x27B0 || cp == 0x27BF,
		cp == 0x26AA || cp == 0x26AB,
		cp == 0x26CE:
		return 2
	}
	return 1
}

// StripVariationSelectors removes VS15/VS16 from an emoji (safe-mode rendering).
// Faithful port of src/root.zig:stripVariationSelectors.
func StripVariationSelectors(emoji string) string {
	r := strings.NewReplacer(vs16, "", vs15, "")
	return r.Replace(emoji)
}
