// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"os/exec"
	"testing"
)

func TestWebsiteSearch(t *testing.T) {
	cmd := exec.Command("node", "--test", "scripts/gen_web_spec/simulator_test.js")
	cmd.Dir = "../.."
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("website search regression: %v\n%s", err, output)
	}
}
