// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Prints a project status summary: open issues, recent commits, working-tree state.
// Parses YAML front matter from issues/*.md with body-scan fallback for files that
// predate the front matter convention.
//
// Run: go run ./scripts/status/
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Issue holds parsed metadata for a single issue file.
type Issue struct {
	File     string
	Num      string
	Title    string
	Status   string // open | in-progress | blocked | implemented | closed | report
	Priority string // P1 | P2 | P3
}

func main() {
	version := gitZonVersion("build.zig.zon")
	branch := git("rev-parse", "--abbrev-ref", "HEAD")
	fmt.Printf("Emojig %s  branch: %s\n\n", version, branch)

	fmt.Println("Recent commits:")
	for _, line := range splitLines(git("log", "--oneline", "-5")) {
		fmt.Printf("  %s\n", line)
	}

	issues := loadIssues("issues")
	active := filterActive(issues)
	sort.Slice(active, func(i, j int) bool {
		if active[i].Priority != active[j].Priority {
			return active[i].Priority < active[j].Priority
		}
		return active[i].Num < active[j].Num
	})

	fmt.Printf("\nIssues (%d):\n", len(active))
	for _, iss := range active {
		tag := ""
		if iss.Status != "open" && iss.Status != "" {
			tag = "  [" + iss.Status + "]"
		}
		prio := iss.Priority
		if prio == "" {
			prio = "   "
		}
		fmt.Printf("  %-3s  %-4s %s%s\n", prio, iss.Num, iss.Title, tag)
	}

	status := git("status", "--short")
	lines := splitLines(status)
	fmt.Printf("\nWorking tree (%d):\n", len(lines))
	for _, l := range lines {
		fmt.Printf("  %s\n", l)
	}
}

// filterActive returns issues that are not closed or report-type documents.
func filterActive(issues []Issue) []Issue {
	var out []Issue
	for _, iss := range issues {
		if iss.Status == "closed" || iss.Status == "report" {
			continue
		}
		out = append(out, iss)
	}
	return out
}

// loadIssues reads all *.md files in dir (excluding README.md).
func loadIssues(dir string) []Issue {
	entries, _ := filepath.Glob(filepath.Join(dir, "*.md"))
	var issues []Issue
	for _, path := range entries {
		if filepath.Base(path) == "README.md" {
			continue
		}
		iss, err := parseIssue(path)
		if err != nil {
			continue
		}
		// Extract issue number from filename: "27-foo.md" → "27"
		name := strings.TrimSuffix(filepath.Base(path), ".md")
		iss.Num = strings.SplitN(name, "-", 2)[0]
		issues = append(issues, iss)
	}
	return issues
}

// parseIssue reads YAML front matter when present, then falls back to body scanning
// for the title, status, and priority fields.
func parseIssue(path string) (Issue, error) {
	f, err := os.Open(path)
	if err != nil {
		return Issue{}, err
	}
	defer f.Close()

	iss := Issue{File: path}
	sc := bufio.NewScanner(f)
	inComment, inFront, bodyStarted := false, false, false

	for sc.Scan() {
		line := sc.Text()
		trimmed := strings.TrimSpace(line)

		// Skip HTML comment blocks (SPDX license headers)
		if strings.HasPrefix(trimmed, "<!--") {
			inComment = true
		}
		if inComment {
			if strings.Contains(line, "-->") {
				inComment = false
			}
			continue
		}

		// Skip blank lines before front matter
		if !bodyStarted && !inFront && trimmed == "" {
			continue
		}

		// Front matter delimiter
		if !bodyStarted && !inFront && trimmed == "---" {
			inFront = true
			continue
		}

		// Inside front matter block
		if inFront {
			if trimmed == "---" {
				inFront = false
				bodyStarted = true
				continue
			}
			key, val, ok := strings.Cut(trimmed, ":")
			if ok {
				applyFront(&iss, strings.TrimSpace(key), strings.TrimSpace(val))
			}
			continue
		}

		// Document body — title and status/priority fallbacks
		bodyStarted = true
		if iss.Title == "" && strings.HasPrefix(line, "# ") {
			iss.Title = strings.TrimPrefix(line, "# ")
		}
		if iss.Status == "" && strings.HasPrefix(line, "**Status:**") {
			iss.Status = bodyStatus(strings.TrimPrefix(line, "**Status:**"))
		}
		if iss.Priority == "" && strings.HasPrefix(line, "**Priority:**") {
			iss.Priority = bodyPriority(strings.TrimPrefix(line, "**Priority:**"))
		}
	}

	if iss.Status == "" {
		iss.Status = "open"
	}
	return iss, sc.Err()
}

func applyFront(iss *Issue, key, val string) {
	// Strip inline YAML comments and surrounding quotes
	if idx := strings.Index(val, " #"); idx != -1 {
		val = strings.TrimSpace(val[:idx])
	}
	val = strings.Trim(val, `"'`)
	switch key {
	case "status":
		iss.Status = strings.ToLower(val)
	case "priority":
		iss.Priority = strings.ToUpper(val)
	case "title":
		iss.Title = val
	}
}

func bodyStatus(val string) string {
	v := strings.ToLower(strings.TrimSpace(val))
	switch {
	case strings.Contains(v, "closed"):
		return "closed"
	case strings.Contains(v, "in progress"), strings.Contains(v, "in-progress"):
		return "in-progress"
	case strings.Contains(v, "blocked"):
		return "blocked"
	case strings.Contains(v, "implemented"):
		return "implemented"
	default:
		return "open"
	}
}

func bodyPriority(val string) string {
	val = strings.TrimSpace(val)
	for _, p := range []string{"P1", "P2", "P3"} {
		if strings.HasPrefix(val, p) {
			return p
		}
	}
	return ""
}

func git(args ...string) string {
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// gitZonVersion reads the .version field from a build.zig.zon file.
func gitZonVersion(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return "unknown"
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.Contains(line, ".version") {
			continue
		}
		// .version = "0.2.0",  →  split on '"' gives ["...", "0.2.0", "..."]
		parts := strings.Split(line, `"`)
		if len(parts) >= 2 {
			return "v" + parts[1]
		}
	}
	return "unknown"
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}
