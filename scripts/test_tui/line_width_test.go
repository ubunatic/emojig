// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"testing"
	"time"
)

func TestTUIRenderedLineWidthsAreEqual(t *testing.T) {
	master, cmd, chunksChan := spawnEmojigTUI(testBinaryPath(t), 8, 10)
	defer master.Close()
	defer func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	initialBytes := collectScreenBytes(chunksChan, 500*time.Millisecond)
	if len(initialBytes) == 0 {
		t.Fatal("initial TUI render produced no bytes")
	}

	if _, err := master.Write([]byte("zzzzzz")); err != nil {
		t.Fatalf("write search query: %v", err)
	}
	rawBytes := append(initialBytes, collectScreenBytes(chunksChan, 500*time.Millisecond)...)
	if len(rawBytes) == len(initialBytes) {
		t.Fatal("query redraw produced no bytes")
	}

	screen := NewTerminalState(80, 24)
	screen.Parse(rawBytes)
	if err := screen.ValidatePaintedRowWidths(34); err != nil {
		screen.PrintScreen()
		t.Fatal(err)
	}
}
