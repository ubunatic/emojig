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
	"strings"
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

		cleanEmoji := strings.ReplaceAll(item.Emoji, "\uFE0F", "")
		emojiOff := getOrAddString(cleanEmoji)
		nameOff := getOrAddString(item.Description)
		searchOff := getOrAddString(searchStr)

		entries = append(entries, Entry{
			EmojiOff:  emojiOff,
			NameOff:   nameOff,
			SearchOff: searchOff,
		})
	}

	emojiCount := uint16(len(entries))
	fmt.Printf("Packed %d emojis.\n", emojiCount)

	// Index size: count * 12 bytes
	indexSize := uint32(emojiCount) * 12
	headerSize := uint32(16)
	stringTableOffset := headerSize + indexSize

	// Write binary file
	outBuf := &bytes.Buffer{}

	// Header: magic (4s), version (u16), count (u16), string_table_offset (u32), string_table_len (u32)
	outBuf.Write([]byte("EMJG"))
	binary.Write(outBuf, binary.LittleEndian, uint16(1))
	binary.Write(outBuf, binary.LittleEndian, emojiCount)
	binary.Write(outBuf, binary.LittleEndian, stringTableOffset)
	binary.Write(outBuf, binary.LittleEndian, uint32(stringTable.Len()))

	// Index Entries
	for _, entry := range entries {
		binary.Write(outBuf, binary.LittleEndian, entry.EmojiOff)
		binary.Write(outBuf, binary.LittleEndian, entry.NameOff)
		binary.Write(outBuf, binary.LittleEndian, entry.SearchOff)
	}

	// String Table
	outBuf.Write(stringTable.Bytes())

	if err := os.MkdirAll(filepath.Dir(binPath), 0755); err != nil {
		fmt.Printf("Error creating directory: %v\n", err)
		os.Exit(1)
	}

	if err := os.WriteFile(binPath, outBuf.Bytes(), 0644); err != nil {
		fmt.Printf("Error writing binary file: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Binary generated at %s (%.2f KB).\n", binPath, float64(outBuf.Len())/1024.0)
}
