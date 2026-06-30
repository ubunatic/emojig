// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// check_synonyms validates spec/synonyms.yaml against src/emojis.bin.
//
// Two checks are run:
//
//  1. Duplicate YAML keys — the yaml-to-json converter silently takes the last
//     definition, leaving dead stale entries.  Each synonym key must appear only
//     once in spec/synonyms.yaml.
//
//  2. Multi-word `to` reachability — for every synonym pair (from → to) whose `to`
//     value contains a space, at least one emoji in the packed binary must have ALL
//     words of `to` as actual words in its search string.  A multi-word phrase where
//     no single emoji contains every word is a silent no-op: the subsequence matcher
//     cannot assemble the phrase across different entries.
//
//     Single-word `to` values are not checked here — a reversed synonym like
//     "airplane → aircraft" is dead code (no emoji has "aircraft") but harmless.
//     The multi-word case is dangerous: "motorcycle racing" fails for 🏍️ because
//     its search string is "motorcycle travel" (no "racing"), so the synonym fires
//     but can never return the intended emoji.
//
// Run: go run ./scripts/check_synonyms/
// Also called by: make preflight
package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"os"
	"strings"
)

const (
	binPath  = "src/emojis.bin"
	yamlPath = "spec/synonyms.yaml"
	magic    = "EMJG"
)

func main() {
	errors := 0
	errors += checkDuplicateKeys(yamlPath)
	errors += checkSynonymReachability(binPath)
	if errors > 0 {
		fmt.Fprintf(os.Stderr, "\n❌ check_synonyms: %d error(s) found\n", errors)
		os.Exit(1)
	}
	fmt.Println("✅ check_synonyms: all synonym entries are valid")
}

// checkDuplicateKeys scans the YAML file for duplicate top-level synonym keys.
// A synonym key is a line matching exactly "    <word>:" (4-space indent, no space
// before the colon) — the indentation level used for synonym keys in synonyms.yaml.
func checkDuplicateKeys(path string) int {
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error opening %s: %v\n", path, err)
		return 1
	}
	defer f.Close()

	seen := map[string]int{}
	lineNum := 0
	errors := 0
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lineNum++
		line := scanner.Text()
		// Match lines like "    word:" (4 spaces, word, colon, end or space)
		if !strings.HasPrefix(line, "    ") || strings.HasPrefix(line, "     ") {
			continue
		}
		trimmed := strings.TrimPrefix(line, "    ")
		if !strings.HasSuffix(trimmed, ":") {
			continue
		}
		key := strings.TrimSuffix(trimmed, ":")
		if strings.ContainsAny(key, " \t") {
			continue // skip multi-word lines (shouldn't exist but be safe)
		}
		if prev, ok := seen[key]; ok {
			fmt.Fprintf(os.Stderr, "%s:%d: duplicate synonym key %q (first seen at line %d)\n", path, lineNum, key, prev)
			errors++
		} else {
			seen[key] = lineNum
		}
	}
	return errors
}

// checkSynonymReachability reads the packed binary, collects all emoji search
// words, then for each synonym (from → to) verifies that every word in `to`
// appears as an actual word in at least one emoji's search string.
func checkSynonymReachability(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error reading %s: %v\n", path, err)
		return 1
	}
	if len(data) < 32 || string(data[:4]) != magic {
		fmt.Fprintf(os.Stderr, "%s: invalid magic bytes\n", path)
		return 1
	}

	count := binary.LittleEndian.Uint16(data[6:8])
	strOff := binary.LittleEndian.Uint32(data[8:12])
	strLen := binary.LittleEndian.Uint32(data[12:16])
	synOff := binary.LittleEndian.Uint32(data[16:20])
	synCnt := binary.LittleEndian.Uint32(data[20:24])

	strTable := data[strOff : strOff+strLen]

	readStr := func(off uint32) string {
		s := strTable[off:]
		end := strings.IndexByte(string(s), 0)
		if end < 0 {
			return string(s)
		}
		return string(s[:end])
	}

	// Build per-emoji word sets for multi-word co-occurrence check.
	type wordBag map[string]bool
	emojiBags := make([]wordBag, count)
	for i := range int(count) {
		entryOff := 32 + uint32(i)*12
		searchOff := binary.LittleEndian.Uint32(data[entryOff+8 : entryOff+12])
		search := readStr(searchOff)
		if idx := strings.IndexByte(search, '\t'); idx >= 0 {
			search = search[:idx]
		}
		bag := wordBag{}
		for _, w := range strings.Fields(search) {
			bag[w] = true
		}
		emojiBags[i] = bag
	}

	// Check each synonym pair — only multi-word `to` values.
	errors := 0
	for i := range int(synCnt) {
		pairOff := synOff + uint32(i)*8
		fromOff := binary.LittleEndian.Uint32(data[pairOff : pairOff+4])
		toOff := binary.LittleEndian.Uint32(data[pairOff+4 : pairOff+8])
		from := readStr(fromOff)
		to := readStr(toOff)

		words := strings.Fields(to)
		if len(words) < 2 {
			continue // single-word `to` values are not checked (harmless if dead)
		}

		// At least one emoji must contain ALL words of `to`.
		found := false
		for _, bag := range emojiBags {
			all := true
			for _, w := range words {
				if !bag[w] {
					all = false
					break
				}
			}
			if all {
				found = true
				break
			}
		}
		if !found {
			fmt.Fprintf(os.Stderr, "synonym %q → %q: no emoji has all words %v in its search string\n", from, to, words)
			errors++
		}
	}
	return errors
}
