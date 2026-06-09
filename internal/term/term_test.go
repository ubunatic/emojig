// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package term

import "testing"

func TestParseCursorReport(t *testing.T) {
	tests := []struct {
		in            string
		row, col      int
		wantErr       bool
	}{
		{"\x1b[12;34R", 12, 34, false},
		{"\x1b[1;1R", 1, 1, false},
		{"\x1b[24;80R", 24, 80, false},
		{"", 0, 0, true},
		{"garbage", 0, 0, true},
		{"\x1b[0;5R", 0, 0, true},  // row < 1
		{"\x1b[5;0R", 0, 0, true},  // col < 1
		{"\x1b[12R", 0, 0, true},   // missing col
	}
	for _, tc := range tests {
		row, col, err := parseCursorReport(tc.in)
		if tc.wantErr {
			if err == nil {
				t.Errorf("parseCursorReport(%q): want error, got (%d,%d)", tc.in, row, col)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseCursorReport(%q): unexpected error: %v", tc.in, err)
			continue
		}
		if row != tc.row || col != tc.col {
			t.Errorf("parseCursorReport(%q) = (%d,%d), want (%d,%d)", tc.in, row, col, tc.row, tc.col)
		}
	}
}

func TestMoveToAndScrollUp(t *testing.T) {
	if got := MoveTo(3, 1); got != "\x1b[3;1H" {
		t.Errorf("MoveTo(3,1) = %q", got)
	}
	if got := ScrollUp(2); got != "\x1b[2S" {
		t.Errorf("ScrollUp(2) = %q", got)
	}
	if ClearLine != "\r\x1b[2K" {
		t.Errorf("ClearLine = %q, want carriage-return-guarded clear", ClearLine)
	}
}
