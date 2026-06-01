package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: go run scripts/bump_version.go <major|minor|patch>")
		os.Exit(1)
	}

	bumpType := os.Args[1]
	if bumpType != "major" && bumpType != "minor" && bumpType != "patch" {
		fmt.Printf("Error: invalid bump type '%s'. Supported types: major, minor, patch\n", bumpType)
		os.Exit(1)
	}

	filePath := "build.zig.zon"
	content, err := os.ReadFile(filePath)
	if err != nil {
		fmt.Printf("Error: could not read %s: %v\n", filePath, err)
		os.Exit(1)
	}

	// Regex to match the version declaration: .version = "X.Y.Z",
	re := regexp.MustCompile(`\.version\s*=\s*"([0-9]+)\.([0-9]+)\.([0-9]+)"`)
	matches := re.FindSubmatch(content)
	if len(matches) < 4 {
		fmt.Printf("Error: could not find valid .version = \"X.Y.Z\" in %s\n", filePath)
		os.Exit(1)
	}

	major, _ := strconv.Atoi(string(matches[1]))
	minor, _ := strconv.Atoi(string(matches[2]))
	patch, _ := strconv.Atoi(string(matches[3]))

	oldVersion := fmt.Sprintf("%d.%d.%d", major, minor, patch)

	switch bumpType {
	case "major":
		major++
		minor = 0
		patch = 0
	case "minor":
		minor++
		patch = 0
	case "patch":
		patch++
	}

	newVersion := fmt.Sprintf("%d.%d.%d", major, minor, patch)
	oldMatch := string(matches[0])
	newMatch := fmt.Sprintf(`.version = "%s"`, newVersion)

	// Replace only the first occurrence of the version match
	reVersion := regexp.MustCompile(regexp.QuoteMeta(oldMatch))
	newContent := reVersion.ReplaceAllLiteral(content, []byte(newMatch))

	err = os.WriteFile(filePath, newContent, 0644)
	if err != nil {
		fmt.Printf("Error: could not write updated version to %s: %v\n", filePath, err)
		os.Exit(1)
	}

	fmt.Printf("Bumped version: %s -> %s\n", oldVersion, newVersion)
}
