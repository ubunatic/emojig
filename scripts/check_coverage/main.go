// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// check_coverage compares emojig's data/emoji.json against the emojibase en
// dataset (the same source GTK's emoji picker uses) and reports coverage gaps.
//
// Usage:
//
//	go run scripts/check_coverage/main.go [--cache data/emojibase_en.json]
//
// By default the script fetches emojibase from the jsDelivr CDN and caches the
// result to data/emojibase_en.json for subsequent offline runs.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"unicode/utf8"
)

const emojibaseURL = "https://cdn.jsdelivr.net/npm/emojibase-data@latest/en/data.json"

// EmojibaseEntry mirrors the fields we care about from emojibase.
type EmojibaseEntry struct {
	Label    string           `json:"label"`
	Hexcode  string           `json:"hexcode"`
	Emoji    string           `json:"emoji"`
	Type     int              `json:"type"` // 1 = emoji, 0 = component (skin tone modifier etc.)
	Group    *int             `json:"group"`
	Subgroup *int             `json:"subgroup"`
	Tags     []string         `json:"tags"`
	Order    int              `json:"order"`
	Skins    []map[string]any `json:"skins"`
}

// EmojigEntry matches the structure of data/emoji.json.
type EmojigEntry struct {
	Emoji       string   `json:"emoji"`
	Description string   `json:"description"`
	Category    string   `json:"category"`
	Aliases     []string `json:"aliases"`
	Tags        []string `json:"tags"`
}

var gtkGroupNames = map[int]string{
	0: "Smileys & Emotion",
	1: "People & Body",
	2: "Component",
	3: "Animals & Nature",
	4: "Food & Drink",
	5: "Travel & Places",
	6: "Activities",
	7: "Objects",
	8: "Symbols",
	9: "Flags",
}

// stripVS strips variation selectors (VS15 U+FE0E and VS16 U+FE0F) from s.
func stripVS(s string) string {
	s = strings.ReplaceAll(s, "︎", "")
	s = strings.ReplaceAll(s, "️", "")
	return s
}

// hasSkinTone returns true if s contains any skin-tone modifier (U+1F3FB–U+1F3FF).
func hasSkinTone(s string) bool {
	for _, r := range s {
		if r >= 0x1f3fb && r <= 0x1f3ff {
			return true
		}
	}
	return false
}

// isRegionalIndicator returns true if every rune is a regional indicator letter
// (U+1F1E6–U+1F1FF used in flag sequences). Individual indicators are not
// stand-alone emojis and are excluded from coverage checks.
func isRegionalIndicator(s string) bool {
	stripped := stripVS(s)
	if utf8.RuneCountInString(stripped) != 1 {
		return false
	}
	r, _ := utf8.DecodeRuneInString(stripped)
	return r >= 0x1f1e6 && r <= 0x1f1ff
}

func loadEmojibase(cachePath string) ([]EmojibaseEntry, error) {
	if data, err := os.ReadFile(cachePath); err == nil {
		var entries []EmojibaseEntry
		if err := json.Unmarshal(data, &entries); err == nil {
			fmt.Printf("Loaded emojibase from cache: %s (%d entries)\n", cachePath, len(entries))
			return entries, nil
		}
	}

	fmt.Printf("Fetching emojibase from %s ...\n", emojibaseURL)
	resp, err := http.Get(emojibaseURL)
	if err != nil {
		return nil, fmt.Errorf("fetch failed: %w", err)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read body: %w", err)
	}

	var entries []EmojibaseEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("parse: %w", err)
	}

	if err := os.WriteFile(cachePath, data, 0644); err != nil {
		fmt.Printf("Warning: could not cache emojibase: %v\n", err)
	} else {
		fmt.Printf("Cached emojibase to %s\n", cachePath)
	}
	return entries, nil
}

func main() {
	cachePath := flag.String("cache", "data/emojibase_en.json", "path to cached emojibase en data")
	verbose := flag.Bool("v", false, "print all missing emojis")
	flag.Parse()

	emojigData, err := os.ReadFile("data/emoji.json")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot read data/emoji.json: %v\n", err)
		os.Exit(1)
	}
	var emojigEntries []EmojigEntry
	if err := json.Unmarshal(emojigData, &emojigEntries); err != nil {
		fmt.Fprintf(os.Stderr, "parse data/emoji.json: %v\n", err)
		os.Exit(1)
	}

	emojigSet := make(map[string]EmojigEntry, len(emojigEntries))
	for _, e := range emojigEntries {
		emojigSet[e.Emoji] = e
		emojigSet[stripVS(e.Emoji)] = e
	}

	gtkEntries, err := loadEmojibase(*cachePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot load emojibase: %v\n", err)
		os.Exit(1)
	}

	// Filter to base emojis only: type=1, no skin-tone variants, no standalone
	// regional indicators, no skin-tone/hair components (group=2).
	var gtkBase []EmojibaseEntry
	for _, e := range gtkEntries {
		if e.Type != 1 {
			continue // components (skin tones, etc.)
		}
		if e.Group != nil && *e.Group == 2 {
			continue // component group (hair, skin-tone swatches)
		}
		if hasSkinTone(e.Emoji) {
			continue // skin-tone variant
		}
		if isRegionalIndicator(e.Emoji) {
			continue // individual flag letter, not a stand-alone emoji
		}
		gtkBase = append(gtkBase, e)
	}

	// Check coverage.
	type gap struct {
		entry  EmojibaseEntry
		vsOnly bool // emojig has base but not this VS16 form
	}
	var missing []gap
	var covered int
	byGroup := make(map[string][]EmojibaseEntry)

	for _, e := range gtkBase {
		_, hasExact := emojigSet[e.Emoji]
		_, hasStripped := emojigSet[stripVS(e.Emoji)]

		groupName := "unknown"
		if e.Group != nil {
			if n, ok := gtkGroupNames[*e.Group]; ok {
				groupName = n
			}
		}

		if hasExact {
			covered++
		} else if hasStripped {
			covered++ // emojig has the base; VS16 variant considered covered
		} else {
			missing = append(missing, gap{entry: e, vsOnly: false})
			byGroup[groupName] = append(byGroup[groupName], e)
		}
	}

	total := len(gtkBase)
	fmt.Printf("\nemojibase base emojis (no skins, no regional letters): %d\n", total)
	fmt.Printf("emojig entries:                                         %d\n", len(emojigEntries))
	fmt.Printf("covered:                                                %d / %d (%.1f%%)\n",
		covered, total, 100*float64(covered)/float64(total))
	fmt.Printf("missing:                                                %d\n\n", len(missing))

	// Summary by group.
	groups := make([]string, 0, len(byGroup))
	for g := range byGroup {
		groups = append(groups, g)
	}
	sort.Strings(groups)

	for _, g := range groups {
		fmt.Printf("  %3d missing in %-24s", len(byGroup[g]), g)
		if !*verbose {
			for i, e := range byGroup[g] {
				if i >= 5 {
					fmt.Printf(" (+%d)", len(byGroup[g])-5)
					break
				}
				fmt.Printf(" %s", e.Emoji)
			}
		}
		fmt.Println()
	}

	if *verbose && len(missing) > 0 {
		fmt.Println("\nAll missing emojis:")
		for _, g := range missing {
			groupName := "unknown"
			if g.entry.Group != nil {
				if n, ok := gtkGroupNames[*g.entry.Group]; ok {
					groupName = n
				}
			}
			fmt.Printf("  %s  %-40s  %s\n", g.entry.Emoji, g.entry.Label, groupName)
		}
	}

	// Tag coverage: for each GTK emoji that emojig has, report GTK tags
	// that emojig lacks (potential search improvements).
	type tagGap struct {
		emoji    string
		label    string
		gtkTags  []string
		emojigTags []string
		missing  []string
	}
	var tagGaps []tagGap

	for _, e := range gtkBase {
		emE, ok := emojigSet[e.Emoji]
		if !ok {
			emE, ok = emojigSet[stripVS(e.Emoji)]
		}
		if !ok || len(e.Tags) == 0 {
			continue
		}

		emigTagSet := make(map[string]bool)
		for _, t := range emE.Tags {
			emigTagSet[strings.ToLower(t)] = true
		}
		for _, a := range emE.Aliases {
			// Treat alias words as implicit tags for coverage check.
			for _, w := range strings.Fields(strings.ReplaceAll(strings.ToLower(a), "_", " ")) {
				emigTagSet[w] = true
			}
		}
		for _, w := range strings.Fields(strings.ToLower(emE.Description)) {
			emigTagSet[w] = true
		}

		var missingTags []string
		for _, t := range e.Tags {
			tl := strings.ToLower(t)
			if !emigTagSet[tl] {
				missingTags = append(missingTags, t)
			}
		}
		if len(missingTags) > 0 {
			tagGaps = append(tagGaps, tagGap{
				emoji:    e.Emoji,
				label:    e.Label,
				gtkTags:  e.Tags,
				emojigTags: emE.Tags,
				missing:  missingTags,
			})
		}
	}

	fmt.Printf("\nTag coverage gaps (%d emojis have GTK tags not in emojig):\n", len(tagGaps))
	limit := 20
	if *verbose {
		limit = len(tagGaps)
	}
	for i, tg := range tagGaps {
		if i >= limit {
			fmt.Printf("  ... and %d more (use -v to see all)\n", len(tagGaps)-limit)
			break
		}
		fmt.Printf("  %s %-28s  missing: %s\n", tg.emoji, tg.label, strings.Join(tg.missing, ", "))
	}
}
