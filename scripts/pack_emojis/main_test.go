// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import "testing"

func TestCleanWord(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"hello", "hello"},
		{"face-with-tears", "facewithtears"},
		{"face_smiling", "facesmiling"},
		{"café", "caf"},
		{"100%", "100"},
		{"", ""},
		{"🎉party", "party"},
		{"ABC123", "ABC123"},
	}
	for _, c := range cases {
		if got := cleanWord(c.in); got != c.want {
			t.Errorf("cleanWord(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
