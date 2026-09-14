// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"os"
	"os/exec"
	"testing"
)

func TestWebsiteSearch(t *testing.T) {
	// Register Node's inputs with Go's test cache so JS-only edits rerun it.
	for _, path := range []string{"simulator_test.js", "../../website/webspec.js", "../../website/emojis.js", "../../website/simulator.js"} {
		if _, err := os.ReadFile(path); err != nil {
			t.Fatal(err)
		}
	}
	cmd := exec.Command("node", "--test", "scripts/gen_web_spec/simulator_test.js")
	cmd.Dir = "../.."
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("website search regression: %v\n%s", err, output)
	}
}
