// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Updates about2_lines, about3_lines, about4_lines in spec/strings.json.
// Run: go run scripts/write_about_art.go

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
)

// DSL helpers — fg/bg are xterm-256 color numbers.
func span(fg, bg, s string) string {
	attrs := "fg=" + fg
	if bg != "" {
		attrs += ",bg=" + bg
	}
	return "$[" + attrs + "]{" + s + "}"
}
func fg(c, s string) string      { return span(c, "", s) }
func fgbg(f, b, s string) string { return span(f, b, s) }
func bgOnly(c, s string) string  { return "$[bg=" + c + "]{" + s + "}" }

// Palette constants.
const (
	Y = "220" // yellow face
	W = "255" // white (sclera, teeth)
	K = "232" // near-black (pupil, mouth, outer bg)
	P = "209" // pink (cheeks)
)

func yy(s string) string    { return fg(Y, s) }
func ww(s string) string    { return fg(W, s) }
func kk(s string) string    { return fg(K, s) }
func yOnK(s string) string  { return fgbg(Y, K, s) }
func wOnK(s string) string  { return fgbg(W, K, s) }
func pOnY(s string) string  { return fgbg(P, Y, s) }
func dark(n int) string     { return bgOnly(K, rep(" ", n)) }
func rep(s string, n int) string {
	r := ""
	for i := 0; i < n; i++ {
		r += s
	}
	return r
}

func main() {
	const ESC = "\x1b"
	const ST = ESC + "\\"
	link := ESC + "]8;;https://ubunatic.com/emojig" + ST + "ubunatic.com/emojig" + ESC + "]8;;" + ST

	// ── about2 (revised) ────────────────────────────────────────────────────
	// Transparent bg, curved smile (▀/▄ at corners), smaller eyes (1W+1K each).
	//
	// Smile design: TC1=▀Y/K, TC2=▄W/K, TC3-8=W, TC9=▄W/K, TC10=▀Y/K
	// This creates a staircase that looks like the smile curves upward at corners.
	indent := "      "
	about2 := []string{
		link,
		"",
		" Emojig $version — quad-block art",
		" using U+2596–U+259F quadrant chars.",
		"",
		// TR0: top arc (same structure as about_lines)
		indent + yy(" ▄████████▄ "),
		// TR1: cut corners — ▟/▙ have dark at UL/UR quad
		indent + yOnK("▟") + yy("██████████") + yOnK("▙"),
		// TR2: eyes — 1W+1K per eye with 4-cell bridge (was 2W+1K, too wide)
		indent + yy("██") + ww("█") + kk("█") + yy("████") + kk("█") + ww("█") + yy("██"),
		// TR3: solid yellow spacer
		indent + yy("████████████"),
		// TR4: curved smile — ▀Y/K at outer corners lifts the smile
		indent + yy("█") + yOnK("▀") + wOnK("▄") + ww("██████") + wOnK("▄") + yOnK("▀") + yy("█"),
		// TR5: dark mouth
		indent + yy("█") + kk("██████████") + yy("█"),
		// TR6: bottom arc — ▝/▘ single-quad corners
		indent + yOnK("▝") + yy("▀████████▀") + yOnK("▘"),
		"",
		" Made with 💙+🤖 in Dresden, DE",
	}

	// ── about3 ──────────────────────────────────────────────────────────────
	// Dark background frame so the circular face pops out visually.
	// Face tapers: 8-wide top → 10 → 12 → 12 → 12 → 10 → 8 bottom.
	// All art rows are 24 visible chars: 6 dark + 12 face + 6 dark
	// (top/bottom rows: 8+8+8).
	about3 := []string{
		link,
		"",
		" Emojig $version — circular face",
		" on explicit dark background.",
		"",
		// TR0: 8 dark + 8 half-bottom cells + 8 dark = 24
		dark(8) + yOnK(rep("▄", 8)) + dark(8),
		// TR1: 6 dark + ▄Y + 10 full + ▄Y + 6 dark = 24
		dark(6) + yOnK("▄") + yy(rep("█", 10)) + yOnK("▄") + dark(6),
		// TR2: 6 dark + ▟Y + 10-char eyes + ▙Y + 6 dark = 24
		dark(6) + yOnK("▟") + yy("██") + ww("█") + kk("█") + yy("████") + kk("█") + ww("█") + yy("██") + yOnK("▙") + dark(6),
		// TR3: 6 dark + 12 yellow spacer + 6 dark = 24
		dark(6) + yy(rep("█", 12)) + dark(6),
		// TR4: curved smile
		dark(6) + yy("█") + yOnK("▀") + wOnK("▄") + ww("██████") + wOnK("▄") + yOnK("▀") + yy("█") + dark(6),
		// TR5: dark mouth
		dark(6) + yy("█") + kk(rep("█", 10)) + yy("█") + dark(6),
		// TR6: 6 dark + ▀Y + 10 full + ▀Y + 6 dark = 24
		dark(6) + yOnK("▀") + yy(rep("█", 10)) + yOnK("▀") + dark(6),
		// TR7: 8 dark + 8 half-top cells + 8 dark = 24
		dark(8) + yOnK(rep("▀", 8)) + dark(8),
		"",
		" Made with 💙+🤖 in Dresden, DE",
	}

	// ── about4 ──────────────────────────────────────────────────────────────
	// Maximum circle + pink cheeks. Steeper top/bottom arcs (4-wide at peak),
	// pink blush marks at cheek row.
	about4 := []string{
		link,
		"",
		" Emojig $version — max circle",
		" with pink cheeks ☺",
		"",
		// TR0: 10 dark + 4 half-bottom + 10 dark = 24
		dark(10) + yOnK(rep("▄", 4)) + dark(10),
		// TR1: 6 dark + ▄▄Y + 8 full + ▄▄Y + 6 dark = 24
		dark(6) + yOnK("▄▄") + yy(rep("█", 8)) + yOnK("▄▄") + dark(6),
		// TR2: 6 dark + ▟ + eyes (10 chars) + ▙ + 6 dark = 24
		dark(6) + yOnK("▟") + yy("██") + ww("█") + kk("█") + yy("████") + kk("█") + ww("█") + yy("██") + yOnK("▙") + dark(6),
		// TR3: cheeks — pink ▄ (fg=pink bg=yellow) = lower half of cell is pink
		// Layout: 6D + Y + PP + YYYYYY + PP + Y + 6D = 6+1+2+6+2+1+6 = 24
		dark(6) + yy("█") + pOnY("▄▄") + yy("██████") + pOnY("▄▄") + yy("█") + dark(6),
		// TR4: curved smile
		dark(6) + yy("█") + yOnK("▀") + wOnK("▄") + ww("██████") + wOnK("▄") + yOnK("▀") + yy("█") + dark(6),
		// TR5: dark mouth
		dark(6) + yy("█") + kk(rep("█", 10)) + yy("█") + dark(6),
		// TR6: 6 dark + ▀▀Y + 8 full + ▀▀Y + 6 dark = 24
		dark(6) + yOnK("▀▀") + yy(rep("█", 8)) + yOnK("▀▀") + dark(6),
		// TR7: 10 dark + 4 half-top + 10 dark = 24
		dark(10) + yOnK(rep("▀", 4)) + dark(10),
		"",
		" Made with 💙+🤖 in Dresden, DE",
	}

	// Write all three to spec/strings.json in a deterministic order.
	type field struct {
		key   string
		lines []string
	}
	updates := []field{
		{"about2_lines", about2},
		{"about3_lines", about3},
		{"about4_lines", about4},
	}
	for _, f := range updates {
		if err := upsertLines("spec/strings.json", f.key, f.lines); err != nil {
			fmt.Fprintf(os.Stderr, "error updating %s: %v\n", f.key, err)
			os.Exit(1)
		}
		fmt.Printf("spec/strings.json: updated %s (%d lines)\n", f.key, len(f.lines))
	}
}

// upsertLines inserts or replaces a JSON string-array field using the
// json.Decoder so that ']' characters inside string values don't fool the
// parser (the old byte-scan approach failed on OSC-8 hyperlink strings).
func upsertLines(file, key string, lines []string) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}

	// Marshal lines so ESC bytes become  in the JSON output.
	encoded, err := json.Marshal(lines)
	if err != nil {
		return err
	}

	// Pretty-print the array: one element per line, 4-space indent.
	var pretty bytes.Buffer
	var raw []json.RawMessage
	if err := json.Unmarshal(encoded, &raw); err != nil {
		return err
	}
	pretty.WriteString("[\n")
	for i, elem := range raw {
		pretty.WriteString("    ")
		pretty.Write(elem)
		if i < len(raw)-1 {
			pretty.WriteByte(',')
		}
		pretty.WriteByte('\n')
	}
	pretty.WriteString("  ]")

	// Find the existing array using a token-aware decoder.
	arrStart, arrEnd, found, err := findArrayBounds(data, key)
	if err != nil {
		return fmt.Errorf("scan %s: %w", key, err)
	}

	if found {
		// Replace the existing array in-place.
		out := make([]byte, 0, len(data)+len(pretty.Bytes()))
		out = append(out, data[:arrStart]...)
		out = append(out, pretty.Bytes()...)
		out = append(out, data[arrEnd:]...)
		return os.WriteFile(file, out, 0o644)
	}

	// Key not found: append as a new field before the closing '}'.
	closingBrace := bytes.LastIndexByte(data, '}')
	if closingBrace < 0 {
		return fmt.Errorf("no closing brace in %s", file)
	}
	newField := []byte(",\n  \"" + key + "\": " + pretty.String())
	out := make([]byte, 0, len(data)+len(newField)+2)
	out = append(out, data[:closingBrace]...)
	out = append(out, newField...)
	out = append(out, '\n', '}')
	return os.WriteFile(file, out, 0o644)
}

// findArrayBounds uses json.Decoder to locate [start, end) byte offsets for
// the array value of the given key in a flat JSON object.
// 'start' is the offset of '[', 'end' is the offset just after ']'.
func findArrayBounds(data []byte, key string) (start, end int, found bool, err error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()

	if _, e := dec.Token(); e != nil { // opening '{'
		return 0, 0, false, e
	}

	for dec.More() {
		keyTok, e := dec.Token()
		if e != nil {
			return 0, 0, false, e
		}
		k, ok := keyTok.(string)
		if !ok {
			return 0, 0, false, fmt.Errorf("expected string key, got %T", keyTok)
		}

		// Record where the value starts (just after the key token).
		valOffset := dec.InputOffset()

		if k != key {
			if e := skipValue(dec); e != nil {
				return 0, 0, false, e
			}
			continue
		}

		// Locate '[' just after whitespace past valOffset.
		arrOff := bytes.IndexByte(data[valOffset:], '[')
		if arrOff < 0 {
			return 0, 0, false, fmt.Errorf("key %q value is not an array", key)
		}
		absStart := int(valOffset) + arrOff

		// Consume the array via decoder (handles strings correctly).
		if _, e := dec.Token(); e != nil { // '['
			return 0, 0, false, e
		}
		for dec.More() {
			if e := skipValue(dec); e != nil {
				return 0, 0, false, e
			}
		}
		if _, e := dec.Token(); e != nil { // ']'
			return 0, 0, false, e
		}
		absEnd := int(dec.InputOffset())

		return absStart, absEnd, true, nil
	}
	return 0, 0, false, nil
}

// skipValue reads one complete JSON value (primitive or nested) from dec.
func skipValue(dec *json.Decoder) error {
	t, err := dec.Token()
	if err != nil {
		return err
	}
	delim, isDelim := t.(json.Delim)
	if !isDelim {
		return nil
	}
	switch delim {
	case '[', '{':
		isObj := delim == '{'
		for dec.More() {
			if e := skipValue(dec); e != nil {
				return e
			}
			if isObj {
				// Objects alternate key / value; skip the value too.
				if e := skipValue(dec); e != nil {
					return e
				}
			}
		}
		if _, e := dec.Token(); e != nil { // closing ] or }
			return e
		}
	}
	return nil
}
