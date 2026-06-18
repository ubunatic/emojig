// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package tui

import (
	"errors"
	"strings"
	"testing"
)

type errorReader struct{}

func (r errorReader) Read(p []byte) (n int, err error) {
	return 0, errors.New("simulated error")
}

func TestReadKey(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantKey  string
		wantText string
		wantEof  bool
	}{
		{"EOF", "", "", "", true},
		{"ESC single", "\x1b", "esc", "", false},
		{"Arrow Up [", "\x1b[A", "up", "", false},
		{"Arrow Up O", "\x1bOA", "up", "", false},
		{"Arrow Down [", "\x1b[B", "down", "", false},
		{"Arrow Down O", "\x1bOB", "down", "", false},
		{"Arrow Right [", "\x1b[C", "right", "", false},
		{"Arrow Right O", "\x1bOC", "right", "", false},
		{"Arrow Left [", "\x1b[D", "left", "", false},
		{"Arrow Left O", "\x1bOD", "left", "", false},
		{"Unhandled Escape", "\x1b[Z", "", "", false},
		{"Backspace 127", "\x7f", "backspace", "", false},
		{"Backspace 8", "\x08", "backspace", "", false},
		{"Enter 10", "\n", "enter", "", false},
		{"Enter 13", "\r", "enter", "", false},
		{"Tab", "\t", "tab", "", false},
		{"Ctrl-C", "\x03", "ctrl-c", "", false},
		{"Ctrl-D", "\x04", "ctrl-d", "", false},
		{"Ctrl-Q", "\x11", "ctrl-q", "", false},
		{"Ctrl-W", "\x17", "ctrl-w", "", false},
		{"Typed Text Printable", "hello", "", "hello", false},
		{"Typed Text Mixed", "h\x01e\x7fl\xfflo", "", "hello", false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := strings.NewReader(tc.input)
			key, text, eof := readKey(r)

			if key != tc.wantKey {
				t.Errorf("got key %q, want %q", key, tc.wantKey)
			}
			if text != tc.wantText {
				t.Errorf("got text %q, want %q", text, tc.wantText)
			}
			if eof != tc.wantEof {
				t.Errorf("got eof %v, want %v", eof, tc.wantEof)
			}
		})
	}

	t.Run("Reader Error", func(t *testing.T) {
		key, text, eof := readKey(errorReader{})
		if key != "" || text != "" || !eof {
			t.Errorf("expected empty strings and eof=true on error, got key=%q, text=%q, eof=%v", key, text, eof)
		}
	})
}
