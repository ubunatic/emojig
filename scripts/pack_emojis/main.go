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
	Tags        []string `json:"tags"`
	Aliases     []string `json:"aliases"`
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

		addWords(item.Description)
		for _, t := range item.Tags {
			addWords(t)
		}
		for _, a := range item.Aliases {
			addWords(a)
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

	// Read synonyms from spec/synonyms.json
	synonymsPath := "spec/synonyms.json"
	fmt.Printf("Reading %s...\n", synonymsPath)
	synonymsData, err := os.ReadFile(synonymsPath)
	if err != nil {
		fmt.Printf("Error reading synonyms file: %v\n", err)
		os.Exit(1)
	}
	type SynonymsJSON struct {
		Synonyms map[string][]string `json:"synonyms"`
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

	emojiCount := uint16(len(entries))
	fmt.Printf("Packed %d emojis.\n", emojiCount)

	// Index size: count * 12 bytes
	indexSize := uint32(emojiCount) * 12
	headerSize := uint32(24)
	stringTableOffset := headerSize + indexSize
	synonymTableOffset := stringTableOffset + uint32(stringTable.Len())
	synonymCount := uint32(len(synonymPairs))

	// Write binary file
	outBuf := &bytes.Buffer{}

	// Header: magic (4s), version (u16), count (u16), string_table_offset (u32), string_table_len (u32), synonym_table_offset (u32), synonym_count (u32)
	outBuf.Write([]byte("EMJG"))
	binary.Write(outBuf, binary.LittleEndian, uint16(2))
	binary.Write(outBuf, binary.LittleEndian, emojiCount)
	binary.Write(outBuf, binary.LittleEndian, stringTableOffset)
	binary.Write(outBuf, binary.LittleEndian, uint32(stringTable.Len()))
	binary.Write(outBuf, binary.LittleEndian, synonymTableOffset)
	binary.Write(outBuf, binary.LittleEndian, synonymCount)

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

	if err := os.WriteFile(webJSPath, []byte(webJSBuilder.String()), 0644); err != nil {
		fmt.Printf("Error writing website/emojis.js: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Website DB generated at %s.\n", webJSPath)
}
