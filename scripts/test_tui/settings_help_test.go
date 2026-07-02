// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"strings"
	"testing"
	"time"
)

// TestTUISettingsHelpModalFromSpec opens the settings screen (/s), presses
// `?` on the first row, and verifies the modal shows the spec-driven help
// text from spec/settings.yaml (option `shell_integration`).
func TestTUISettingsHelpModalFromSpec(t *testing.T) {
	master, cmd, chunksChan := spawnEmojigTUI(testBinaryPath(t), 8, 10)
	defer master.Close()
	defer func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	collectScreenBytes(chunksChan, 500*time.Millisecond)
	if _, err := master.Write([]byte("/s")); err != nil {
		t.Fatalf("write settings command: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	if _, err := master.Write([]byte("\r")); err != nil {
		t.Fatalf("press enter for settings command: %v", err)
	}
	time.Sleep(300 * time.Millisecond)
	settingsBytes := collectScreenBytes(chunksChan, 500*time.Millisecond)
	settingsPlain := stripANSI(string(settingsBytes))
	if !strings.Contains(settingsPlain, "emojig settings") {
		t.Fatalf("settings screen did not open\n%s", settingsPlain)
	}

	// `?` opens the help modal for the selected (first) row.
	if _, err := master.Write([]byte("?")); err != nil {
		t.Fatalf("write help key: %v", err)
	}
	time.Sleep(300 * time.Millisecond)
	helpBytes := collectScreenBytes(chunksChan, 500*time.Millisecond)
	plain := stripANSI(string(helpBytes))
	// The modal text comes from spec/settings.yaml `help` of shell_integration.
	for _, want := range []string{"Shell integration", "shell"} {
		if !strings.Contains(plain, want) {
			t.Fatalf("settings help modal missing %q\n%s", want, plain)
		}
	}
}
