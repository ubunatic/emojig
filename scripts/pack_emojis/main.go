// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

type EmojiItem struct {
	Emoji       string   `json:"emoji"`
	Description string   `json:"description"`
	Category    string   `json:"category"`
	Tags        []string `json:"tags"`
	Aliases     []string `json:"aliases"`
}

// categoryKeywords injects a canonical keyword for each emoji category so that
// "c:animal" / "c:food" / "c:travel" filters work without adding tags to every
// individual emoji in the data file.
var categoryKeywords = map[string]string{
	"Animals & Nature": "animal",
	"Food & Drink":     "food",
	"Travel & Places":  "travel",
	"Activities":       "activity",
}

func cleanWord(word string) string {
	var sb strings.Builder
	for _, r := range word {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

func main() {
	jsonPath := "data/emoji.json"
	binPath := "src/emojis.bin"

	fmt.Printf("Reading %s...\n", jsonPath)
	data, err := os.ReadFile(jsonPath)
	if err != nil {
		fmt.Printf("Error reading JSON file: %v\n", err)
		os.Exit(1)
	}

	var emojis []EmojiItem
	if err := json.Unmarshal(data, &emojis); err != nil {
		fmt.Printf("Error unmarshaling JSON: %v\n", err)
		os.Exit(1)
	}

	stringTable := &bytes.Buffer{}
	stringOffsets := make(map[string]uint32)

	getOrAddString := func(s string) uint32 {
		sBytes := append([]byte(s), 0) // Null terminator
		sKey := string(sBytes)
		if off, exists := stringOffsets[sKey]; exists {
			return off
		}
		off := uint32(stringTable.Len())
		stringTable.Write(sBytes)
		stringOffsets[sKey] = off
		return off
	}

	type Entry struct {
		EmojiOff  uint32
		NameOff   uint32
		SearchOff uint32
	}

	var entries []Entry

	type WebEmoji struct {
		Emoji       string
		Description string
		SearchStr   string
	}
	var webEmojis []WebEmoji

	// Set of all emoji strings in the source data, to avoid emitting a
	// derived plain twin that already exists as its own entry.
	existing := make(map[string]bool, len(emojis))
	for _, item := range emojis {
		existing[item.Emoji] = true
	}

	addEntry := func(emoji, name, searchStr string) {
		emojiOff := getOrAddString(emoji)
		nameOff := getOrAddString(name)
		searchOff := getOrAddString(searchStr)
		entries = append(entries, Entry{
			EmojiOff:  emojiOff,
			NameOff:   nameOff,
			SearchOff: searchOff,
		})
		webEmojis = append(webEmojis, WebEmoji{
			Emoji:       emoji,
			Description: name,
			SearchStr:   searchStr,
		})
	}

	plainTwins := 0
	for _, item := range emojis {
		if item.Emoji == "" {
			continue
		}

		// Collect unique search words
		var searchWords []string
		addWords := func(text string) {
			cleaned := strings.ReplaceAll(text, "-", " ")
			cleaned = strings.ReplaceAll(cleaned, "_", " ")
			for _, w := range strings.Fields(strings.ToLower(cleaned)) {
				cw := cleanWord(w)
				if cw == "" {
					continue
				}
				// check uniqueness
				found := false
				for _, sw := range searchWords {
					if sw == cw {
						found = true
						break
					}
				}
				if !found {
					searchWords = append(searchWords, cw)
				}
			}
		}

		// Aliases first so the canonical popular name (e.g. "coffee", "heart",
		// "bee") lands at position 0 and scores highest for direct queries.
		for _, a := range item.Aliases {
			addWords(a)
		}
		addWords(item.Description)
		for _, t := range item.Tags {
			addWords(t)
		}
		// Inject category keyword so c:animal / c:food / c:travel filters work.
		if kw, ok := categoryKeywords[item.Category]; ok {
			addWords(kw)
		}

		searchStr := strings.Join(searchWords, " ")

		addEntry(item.Emoji, item.Description, searchStr)

		// Derive a plain (text-presentation) twin for simple VS16 emojis:
		// a single base codepoint + U+FE0F. The twin keeps the base rune and
		// appends U+FE0E (VS15), which explicitly requests the monochrome
		// text glyph and survives pasting into emoji-happy apps. It renders
		// single-width (see getEmojiWidth/Width), so the t: filter finds it.
		// ZWJ sequences and keycaps (multi-rune after stripping) are skipped.
		const (
			vs15 = "\ufe0e" // text presentation selector
			vs16 = "\ufe0f" // emoji presentation selector
			zwj  = "\u200d" // zero-width joiner
		)
		if strings.Contains(item.Emoji, vs16) && !strings.Contains(item.Emoji, zwj) {
			bare := strings.ReplaceAll(item.Emoji, vs16, "")
			if utf8.RuneCountInString(bare) == 1 && !existing[bare] && !existing[bare+vs15] {
				addEntry(bare+vs15, item.Description+" plain", searchStr+" plain text")
				plainTwins++
			}
		}
	}
	fmt.Printf("Derived %d plain text-presentation twins.\n", plainTwins)

	// Append box-drawing / block-element entries from spec/boxart.json.
	// They share the emoji entry format; search engines rank them below
	// emojis and the b: query prefix filters to them (see internal/emoji
	// and src/root.zig).
	boxartPath := "spec/boxart.json"
	fmt.Printf("Reading %s...\n", boxartPath)
	boxartData, err := os.ReadFile(boxartPath)
	if err != nil {
		fmt.Printf("Error reading boxart file: %v\n", err)
		os.Exit(1)
	}
	type BoxartEntry struct {
		Char string   `json:"char"`
		Name string   `json:"name"`
		Tags []string `json:"tags"`
	}
	type BoxartJSON struct {
		Entries []BoxartEntry `json:"entries"`
	}
	var boxart BoxartJSON
	if err := json.Unmarshal(boxartData, &boxart); err != nil {
		fmt.Printf("Error unmarshaling boxart JSON: %v\n", err)
		os.Exit(1)
	}
	for _, b := range boxart.Entries {
		if b.Char == "" || existing[b.Char] {
			continue
		}
		searchStr := b.Name + " " + strings.Join(b.Tags, " ") + " box ascii art"
		addEntry(b.Char, b.Name, searchStr)
	}
	fmt.Printf("Added %d box art entries.\n", len(boxart.Entries))

	// Append Braille pattern entries from spec/braille.json. They share the
	// emoji entry format; search engines rank them below emojis and the br:
	// query prefix filters to them (see internal/emoji and src/root.zig).
	braillePath := "spec/braille.json"
	fmt.Printf("Reading %s...\n", braillePath)
	brailleData, err := os.ReadFile(braillePath)
	if err != nil {
		fmt.Printf("Error reading braille file: %v\n", err)
		os.Exit(1)
	}
	type BrailleEntry struct {
		Char string   `json:"char"`
		Name string   `json:"name"`
		Tags []string `json:"tags"`
	}
	type BrailleJSON struct {
		Entries []BrailleEntry `json:"entries"`
	}
	var braille BrailleJSON
	if err := json.Unmarshal(brailleData, &braille); err != nil {
		fmt.Printf("Error unmarshaling braille JSON: %v\n", err)
		os.Exit(1)
	}
	for _, b := range braille.Entries {
		if b.Char == "" || existing[b.Char] {
			continue
		}
		searchStr := b.Name + " " + strings.Join(b.Tags, " ") + " braille"
		addEntry(b.Char, b.Name, searchStr)
	}
	fmt.Printf("Added %d braille entries.\n", len(braille.Entries))

	// Read synonyms from spec/synonyms.json
	synonymsPath := "spec/synonyms.json"
	fmt.Printf("Reading %s...\n", synonymsPath)
	synonymsData, err := os.ReadFile(synonymsPath)
	if err != nil {
		fmt.Printf("Error reading synonyms file: %v\n", err)
		os.Exit(1)
	}
	type SynonymsJSON struct {
		Synonyms       map[string][]string `json:"synonyms"`
		StemExclusions []string            `json:"stem_exclusions"`
	}
	var synJSON SynonymsJSON
	if err := json.Unmarshal(synonymsData, &synJSON); err != nil {
		fmt.Printf("Error unmarshaling synonyms JSON: %v\n", err)
		os.Exit(1)
	}

	// Add synonym strings to the string table and collect synonym pairs
	type SynonymPair struct {
		FromOff uint32
		ToOff   uint32
	}
	var synonymPairs []SynonymPair
	var synKeys []string
	for k := range synJSON.Synonyms {
		synKeys = append(synKeys, k)
	}
	sort.Strings(synKeys)
	for _, from := range synKeys {
		tos := synJSON.Synonyms[from]
		sort.Strings(tos)
		for _, to := range tos {
			fromOff := getOrAddString(from)
			toOff := getOrAddString(to)
			synonymPairs = append(synonymPairs, SynonymPair{
				FromOff: fromOff,
				ToOff:   toOff,
			})
		}
	}

	// Collect stem-exclusion offsets (terms for which the trailing-'e' fallback is suppressed)
	stemExclusions := synJSON.StemExclusions
	sort.Strings(stemExclusions)
	var stemExclOffsets []uint32
	for _, term := range stemExclusions {
		stemExclOffsets = append(stemExclOffsets, getOrAddString(term))
	}

	emojiCount := uint16(len(entries))
	fmt.Printf("Packed %d emojis.\n", emojiCount)

	// Index size: count * 12 bytes
	indexSize := uint32(emojiCount) * 12
	// Header is 32 bytes: magic(4) version(2) count(2) str_off(4) str_len(4) syn_off(4) syn_cnt(4) excl_off(4) excl_cnt(4)
	headerSize := uint32(32)
	stringTableOffset := headerSize + indexSize
	synonymTableOffset := stringTableOffset + uint32(stringTable.Len())
	synonymCount := uint32(len(synonymPairs))
	stemExclTableOffset := synonymTableOffset + synonymCount*8
	stemExclCount := uint32(len(stemExclOffsets))

	// Write binary file
	outBuf := &bytes.Buffer{}

	// Header: magic(4) version(u16) count(u16) str_off(u32) str_len(u32) syn_off(u32) syn_cnt(u32) excl_off(u32) excl_cnt(u32)
	outBuf.Write([]byte("EMJG"))
	binary.Write(outBuf, binary.LittleEndian, uint16(3))
	binary.Write(outBuf, binary.LittleEndian, emojiCount)
	binary.Write(outBuf, binary.LittleEndian, stringTableOffset)
	binary.Write(outBuf, binary.LittleEndian, uint32(stringTable.Len()))
	binary.Write(outBuf, binary.LittleEndian, synonymTableOffset)
	binary.Write(outBuf, binary.LittleEndian, synonymCount)
	binary.Write(outBuf, binary.LittleEndian, stemExclTableOffset)
	binary.Write(outBuf, binary.LittleEndian, stemExclCount)

	// Index Entries
	for _, entry := range entries {
		binary.Write(outBuf, binary.LittleEndian, entry.EmojiOff)
		binary.Write(outBuf, binary.LittleEndian, entry.NameOff)
		binary.Write(outBuf, binary.LittleEndian, entry.SearchOff)
	}

	// String Table
	outBuf.Write(stringTable.Bytes())

	// Synonym Pairs
	for _, pair := range synonymPairs {
		binary.Write(outBuf, binary.LittleEndian, pair.FromOff)
		binary.Write(outBuf, binary.LittleEndian, pair.ToOff)
	}

	// Stem Exclusion Table (one u32 offset per excluded term)
	for _, off := range stemExclOffsets {
		binary.Write(outBuf, binary.LittleEndian, off)
	}

	if err := os.MkdirAll(filepath.Dir(binPath), 0755); err != nil {
		fmt.Printf("Error creating directory: %v\n", err)
		os.Exit(1)
	}

	if err := os.WriteFile(binPath, outBuf.Bytes(), 0644); err != nil {
		fmt.Printf("Error writing binary file: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Binary generated at %s (%.2f KB).\n", binPath, float64(outBuf.Len())/1024.0)

	// Generate website/emojis.js
	webJSPath := "website/emojis.js"
	var webJSBuilder strings.Builder
	webJSBuilder.WriteString("/*\n * SPDX-FileCopyrightText: 2026 Uwe Jugel\n * SPDX-License-Identifier: AGPL-3.0-or-later\n */\n\nconst EMOJI_DB = [\n")
	for _, we := range webEmojis {
		escapedDesc := strings.ReplaceAll(strings.ReplaceAll(we.Description, "\\", "\\\\"), "\"", "\\\"")
		escapedSearch := strings.ReplaceAll(strings.ReplaceAll(we.SearchStr, "\\", "\\\\"), "\"", "\\\"")
		escapedEmoji := strings.ReplaceAll(strings.ReplaceAll(we.Emoji, "\\", "\\\\"), "\"", "\\\"")
		webJSBuilder.WriteString(fmt.Sprintf("  [\"%s\", \"%s\", \"%s\"],\n", escapedEmoji, escapedDesc, escapedSearch))
	}
	webJSBuilder.WriteString("];\n")

	// Synonym map for the JS simulator's match-time synonym expansion,
	// mirroring the embedded synonym table used by the Zig and Go engines.
	webJSBuilder.WriteString("\nconst EMOJI_SYNONYMS = {\n")
	for _, from := range synKeys {
		tos := synJSON.Synonyms[from]
		quoted := make([]string, len(tos))
		for i, to := range tos {
			quoted[i] = fmt.Sprintf("%q", to)
		}
		webJSBuilder.WriteString(fmt.Sprintf("  %q: [%s],\n", from, strings.Join(quoted, ", ")))
	}
	webJSBuilder.WriteString("};\n")

	if err := os.WriteFile(webJSPath, []byte(webJSBuilder.String()), 0644); err != nil {
		fmt.Printf("Error writing website/emojis.js: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Website DB generated at %s.\n", webJSPath)
}
