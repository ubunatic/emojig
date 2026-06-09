// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package tui

import "io"

// readKey reads one keypress from in and decodes it into a logical key name
// (matching spec/keys.json) plus, for typed characters, the literal text. The
// third return is true if the input closed (treat as quit). Reading from the
// tty handle (not os.Stdin) keeps piped stdin from being consumed as
// keystrokes. Mirrors the key switch in src/main.zig but stays minimal: no
// mouse, no Alt+F4.
func readKey(in io.Reader) (key, text string, eof bool) {
	var buf [32]byte
	n, err := in.Read(buf[:])
	if err != nil || n == 0 {
		return "", "", true
	}
	b := buf[:n]

	switch {
	case b[0] == 27: // ESC
		if n == 1 {
			return "esc", "", false
		}
		if n >= 3 && (b[1] == '[' || b[1] == 'O') {
			switch b[2] {
			case 'A':
				return "up", "", false
			case 'B':
				return "down", "", false
			case 'C':
				return "right", "", false
			case 'D':
				return "left", "", false
			}
		}
		// Unhandled escape sequence: ignore.
		return "", "", false
	case b[0] == 127 || b[0] == 8:
		return "backspace", "", false
	case b[0] == 10 || b[0] == 13:
		return "enter", "", false
	case b[0] == 9:
		return "tab", "", false
	case b[0] == 3:
		return "ctrl-c", "", false
	case b[0] == 4:
		return "ctrl-d", "", false
	case b[0] == 17:
		return "ctrl-q", "", false
	case b[0] == 23:
		return "ctrl-w", "", false
	default:
		// Typed text: keep printable ASCII bytes (matches src/main.zig).
		out := make([]byte, 0, n)
		for _, c := range b {
			if c >= 32 && c <= 126 {
				out = append(out, c)
			}
		}
		return "", string(out), false
	}
}
