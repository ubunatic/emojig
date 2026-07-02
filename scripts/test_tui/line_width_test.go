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

	// Under load the collection window can cut the stream mid-row, which
	// reads as a bogus width mismatch. Retry with any late bytes before
	// declaring failure so only a *stable* bad frame fails the test.
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		screen := NewTerminalState(80, 24)
		screen.Parse(rawBytes)
		lastErr = screen.ValidatePaintedRowWidths(34)
		if lastErr == nil {
			return
		}
		more := collectScreenBytes(chunksChan, 200*time.Millisecond)
		if len(more) == 0 {
			break
		}
		rawBytes = append(rawBytes, more...)
	}
	screen := NewTerminalState(80, 24)
	screen.Parse(rawBytes)
	screen.PrintScreen()
	t.Fatal(lastErr)
}
