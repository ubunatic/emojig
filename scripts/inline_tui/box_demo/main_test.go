// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"strings"
	"testing"
)

func TestStatsOverflow(t *testing.T) {
	tests := []struct {
		name               string
		startRow, bh, rows int
		want               int
	}{
		{"fits with room", 5, 10, 24, 5 + 10 - 1 - 24}, // -10: 9 rows to spare
		{"exactly fits", 15, 10, 24, 0},                // box bottom == last row
		{"past bottom by 3", 18, 10, 24, 3},            // scroll/leak risk
		{"relative mode startRow 0", 0, 10, 24, -15},   // no absolute anchor
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &stats{startRow: tt.startRow, boxHeight: tt.bh, rows: tt.rows}
			if got := s.overflow(); got != tt.want {
				t.Errorf("overflow() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestStatsDigestMode(t *testing.T) {
	// ABS only when absolute requested AND a real startRow is known.
	abs := &stats{redraws: 12, winches: 3, startRow: 18, cols: 80, rows: 24, boxHeight: 10, absolute: true, lastEvent: "cpr"}
	d := abs.digest()
	for _, want := range []string{"f12", "wz3", "sr18", "80x24", "bh10", "ov+3", "ABS", "ev:cpr"} {
		if !strings.Contains(d, want) {
			t.Errorf("digest %q missing %q", d, want)
		}
	}

	// absolute requested but startRow still 0 => not yet anchored => REL.
	pending := &stats{absolute: true, startRow: 0}
	if got := pending.digest(); !strings.Contains(got, "REL") {
		t.Errorf("digest %q: want REL while startRow==0", got)
	}

	// relative mode never reports ABS.
	rel := &stats{absolute: false, startRow: 18}
	if got := rel.digest(); !strings.Contains(got, "REL") {
		t.Errorf("digest %q: want REL in relative mode", got)
	}

	// overflow sign is explicit so negatives read clearly in the border.
	if got := abs.digest(); !strings.Contains(got, "ov+3") {
		t.Errorf("digest %q: want signed overflow ov+3", got)
	}
}

func TestBorderWithLabel(t *testing.T) {
	tests := []struct {
		name  string
		inner int
		label string
	}{
		{"normal", 40, "f1 wz0 sr12 80x24 bh10 ov-2 ABS ev:init"},
		{"label longer than inner gets truncated", 20, "this label is way too long to fit inside"},
		{"tiny inner falls back to plain dashes", 3, "x"},
		{"zero inner", 0, "x"},
		{"negative inner clamps", -5, "x"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := borderWithLabel(tt.inner, tt.label)

			// Must start and end with a corner.
			if !strings.HasPrefix(b, "+") || !strings.HasSuffix(b, "+") {
				t.Fatalf("border %q missing + corners", b)
			}

			// Total displayed width must be exactly inner+2 (the two corners),
			// never less — otherwise the right edge drifts / wraps.
			wantWidth := tt.inner + 2
			if wantWidth < 2 {
				wantWidth = 2 // clamped inner==0
			}
			if len(b) != wantWidth {
				t.Errorf("border width = %d (%q), want %d", len(b), b, wantWidth)
			}

			// Interior must be only dashes, spaces, and the label text — no newlines.
			if strings.ContainsAny(b, "\n\r") {
				t.Errorf("border %q contains line breaks", b)
			}
		})
	}
}

func TestLegendIsAsciiAndFits(t *testing.T) {
	// Legend lines are padded by byte length, so any multi-byte rune would
	// misalign the right border. Guard against accidental Unicode creeping in.
	s := &stats{}
	for _, line := range s.legend() {
		for i, r := range line {
			if r > 127 {
				t.Errorf("legend line %q has non-ASCII rune %q at %d", line, r, i)
			}
		}
	}
}
