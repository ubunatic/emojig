// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// check_docs_index flags any docs/*.md file not linked from docs/README.md —
// the one index meant to make evergreen docs discoverable. Six such docs
// (Canary.md, EmojiWidthResearch.md, EnvironmentDetection.md, Git.md,
// Markdown.md, Spec.md) went undiscoverable this way until a 2026-08-11
// evergreen pass caught it by hand; this script exists so that doesn't
// happen silently again.
//
// Usage:
//
//	go run ./scripts/check_docs_index
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var mdLinkTarget = regexp.MustCompile(`\]\(([^)]+\.md)\)`)

func main() {
	const docsDir = "docs"
	const indexFile = "docs/README.md"

	index, err := os.ReadFile(indexFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "check_docs_index: cannot read %s: %v\n", indexFile, err)
		os.Exit(1)
	}

	linked := map[string]bool{}
	for _, m := range mdLinkTarget.FindAllStringSubmatch(string(index), -1) {
		linked[filepath.Base(m[1])] = true
	}

	entries, err := os.ReadDir(docsDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "check_docs_index: cannot read %s: %v\n", docsDir, err)
		os.Exit(1)
	}

	var missing []string
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".md") || name == "README.md" {
			continue
		}
		if !linked[name] {
			missing = append(missing, name)
		}
	}

	if len(missing) == 0 {
		fmt.Println("check_docs_index: OK — every docs/*.md is linked from docs/README.md")
		return
	}

	sort.Strings(missing)
	fmt.Fprintln(os.Stderr, "check_docs_index: FAIL — these evergreen docs exist but aren't linked from docs/README.md:")
	for _, name := range missing {
		fmt.Fprintf(os.Stderr, "  - docs/%s\n", name)
	}
	os.Exit(1)
}
