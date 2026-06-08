// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func runCmd(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(stdout.String()), nil
}

func main() {
	ref := os.Getenv("VERSION_PUBLISHED")

	// If we got a VERSION_PUBLISHED, verify it actually exists locally
	if ref != "" {
		_, err := runCmd("git", "rev-parse", "--verify", "--quiet", ref)
		if err != nil {
			ref = ""
		}
	}

	// Fallback to git describe
	if ref == "" {
		var err error
		ref, err = runCmd("git", "describe", "--tags", "--abbrev=0")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: Could not determine the last published release or git tag: %v\n", err)
			os.Exit(1)
		}
	}

	fmt.Printf("Showing git summary of changes since %s:\n", ref)

	cmd := exec.Command("git", "--no-pager", "diff", "--stat", ref)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error running git diff: %v\n", err)
		os.Exit(1)
	}
}
