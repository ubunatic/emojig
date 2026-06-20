// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Generates spec/colors.json — the full xterm-256 palette documented with a
// long name, a 3-letter short name, a hex value, and a human description for
// every index 0-255. The 16 system colors and a curated set of popular colors
// (orange, teal, navy, …) get real names + shorts; the rest get systematic
// rgbRGB / grayNN names. Both the long name and the short are accepted wherever
// the picker resolves a color (e.g. spec/strings.json multi_select_bg).
// Run: go run ./scripts/gen_colors/
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"sort"
)

// colorEntry is one documented palette slot.
type colorEntry struct {
	I     int      `json:"i"`
	Name  string   `json:"name"`
	Short string   `json:"short,omitempty"`
	Hex   string   `json:"hex"`
	Desc  string   `json:"desc"`
	Alt   []string `json:"alt,omitempty"`
}

// named overrides the systematic name/short for a given index. Alt entries keep
// the systematic rgbRGB/grayNN name reachable as an alias.
type named struct {
	name  string
	short string
	alt   []string
}

// system holds the 16 ANSI base colors (long name + 3-letter short).
var system = [16]named{
	{"black", "blk", nil}, {"maroon", "mar", nil}, {"green", "grn", nil}, {"olive", "oli", nil},
	{"navy", "nvy", nil}, {"purple", "pur", nil}, {"teal", "tea", nil}, {"silver", "sil", nil},
	{"brightblack", "bbk", []string{"brightgray", "bgry"}}, {"red", "red", nil}, {"lime", "lim", nil}, {"yellow", "ylw", nil},
	{"blue", "blu", nil}, {"magenta", "mag", nil}, {"cyan", "cyn", nil}, {"white", "wht", nil},
}

// popular maps well-known xterm indices to friendly names so people can type a
// colour by feel ("orange", "pink") instead of memorising the cube formula.
var popular = map[int]named{
	196: {"brightred", "brd", nil},
	46:  {"brightgreen", "bgn", nil},
	21:  {"Deep Blue", "dpb", []string{"brightblue", "bbl"}},
	51:  {"Cyan / Aqua", "cyn", []string{"brightcyan", "bcy"}},
	201: {"brightmagenta", "bmg", nil},
	226: {"brightyellow", "byl", nil},
	208: {"orange", "org", nil},
	202: {"darkorange", "dor", nil},
	214: {"Bright Amber", "bab", []string{"amber", "amb"}},
	220: {"gold", "gld", []string{"yellow", "ylw"}},
	200: {"pink", "pnk", nil},
	198: {"hotpink", "hpk", nil},
	205: {"rose", "ros", nil},
	93:  {"violet", "vio", nil},
	99:  {"indigo", "ind", nil},
	54:  {"darkviolet", "dvi", []string{"purple"}},
	30:  {"darkteal", "dtl", nil},
	22:  {"forest", "fst", nil},
	28:  {"darkgreen", "dgn", nil},
	17:  {"darknavy", "dnv", nil},
	33:  {"Electric Blue", "ebl", []string{"azure", "azr"}},
	39:  {"Sky Blue", "sky", []string{"skyblue"}},
	111: {"Light Blue", "lbl", []string{"lightblue"}},
	153: {"Pale Ice Blue", "pib", []string{"paleblue", "pbl"}},
	94:  {"brown", "brn", nil},
	130: {"sienna", "sie", nil},
	137: {"tan", "tan", nil},
	180: {"wheat", "wht2", nil},
	143: {"khaki", "khk", nil},
	100: {"darkolive", "dol", nil},
	160: {"crimson", "crm", nil},
	124: {"darkred", "drd", nil},
	88:  {"darkmaroon", "dmr", nil},
	29:  {"seagreen", "sea", nil},
	35:  {"mint", "mnt", nil},
	121: {"palegreen", "pgn", nil},
	159: {"paleturquoise", "ptq", nil},
	183: {"plum", "plm", nil},
	60:  {"slate", "slt", nil},
	67:  {"Steel Blue", "stl", []string{"steelblue"}},
	245: {"midgray", "mgy", nil},
	240: {"darkgray", "dgy", []string{"gray"}},
	250: {"lightgray", "lgy", nil},
	244: {"dimgray", "dmg", nil},
	178: {"Dark Gold", "dgd", []string{"gold2"}},
	172: {"Orange-Brown", "obr", nil},
	136: {"Dark Goldenrod", "dgo", nil},
	18:  {"Dark Blue", "dbl", nil},
	19:  {"Navy Blue", "nbl", nil},
	24:  {"Midnight Blue", "mnb", []string{"midnight"}},
	69:  {"Cornflower Blue", "cbl", nil},
	75:  {"Royal Blue", "rbl", nil},
	45:  {"Dodger Blue", "dbl", nil},
	195: {"Powder Blue", "pwb", nil},
	232: {"dark", "drk", []string{"gray0"}},
	238: {"gray", "gry", []string{"gray6"}},
	209: {"Rose Pink", "rpk", []string{"rosepink", "coral"}},
}

// cubeLevels are the six channel intensities of the 6×6×6 colour cube.
var cubeLevels = [6]int{0, 95, 135, 175, 215, 255}

func main() {
	colors := make([]colorEntry, 0, 256)

	// 0-15: system colours.
	for i := range 16 {
		r, g, b := systemRGB(i)
		colors = append(colors, colorEntry{
			I: i, Name: system[i].name, Short: system[i].short,
			Hex: hex(r, g, b), Desc: describe(r, g, b),
			Alt: system[i].alt,
		})
	}

	// 16-231: the 6×6×6 cube.
	for i := 16; i <= 231; i++ {
		n := i - 16
		r := cubeLevels[n/36]
		g := cubeLevels[(n/6)%6]
		b := cubeLevels[n%6]
		canon := fmt.Sprintf("rgb%d%d%d", n/36, (n/6)%6, n%6)
		colors = append(colors, withName(i, canon, r, g, b))
	}

	// 232-255: the 24-step grayscale ramp.
	for i := 232; i <= 255; i++ {
		v := 8 + (i-232)*10
		canon := fmt.Sprintf("gray%d", i-232)
		colors = append(colors, withName(i, canon, v, v, v))
	}

	// Generate JSON schemas
	var colorEnums []string
	for _, c := range colors {
		colorEnums = append(colorEnums, c.Name)
		if c.Short != "" {
			colorEnums = append(colorEnums, c.Short)
		}
		for _, a := range c.Alt {
			colorEnums = append(colorEnums, a)
		}
	}
	seen := make(map[string]bool)
	var uniqueEnums []string
	for _, name := range colorEnums {
		if !seen[name] {
			seen[name] = true
			uniqueEnums = append(uniqueEnums, name)
		}
	}
	sort.Strings(uniqueEnums)

	themeSchema := map[string]any{
		"$schema": "http://json-schema.org/draft-07/schema#",
		"type":    "object",
		"properties": map[string]any{
			"description": map[string]any{"type": "string"},
			"notes":       map[string]any{"type": "object"},
			"icons": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"dark":   map[string]any{"type": "string"},
					"light":  map[string]any{"type": "string"},
					"system": map[string]any{"type": "string"},
				},
				"additionalProperties": false,
				"required":             []string{"dark", "light", "system"},
			},
			"themes": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"dark":  map[string]any{"$ref": "#/definitions/palette"},
					"light": map[string]any{"$ref": "#/definitions/palette"},
				},
				"additionalProperties": false,
				"required":             []string{"dark", "light"},
			},
		},
		"additionalProperties": false,
		"required":             []string{"icons", "themes"},
		"definitions": map[string]any{
			"color": map[string]any{
				"anyOf": []any{
					map[string]any{"type": "integer", "minimum": 0, "maximum": 255},
					map[string]any{"type": "null"},
					map[string]any{
						"type": "string",
						"enum": uniqueEnums,
					},
					map[string]any{
						"type":    "string",
						"pattern": "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$",
					},
				},
			},
			"palette": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"grid_bg":         map[string]any{"$ref": "#/definitions/color"},
					"grid_fg":         map[string]any{"$ref": "#/definitions/color"},
					"selection_bg":    map[string]any{"$ref": "#/definitions/color"},
					"selection_fg":    map[string]any{"$ref": "#/definitions/color"},
					"search_bg":       map[string]any{"$ref": "#/definitions/color"},
					"search_fg":       map[string]any{"$ref": "#/definitions/color"},
					"search_shade_fg": map[string]any{"$ref": "#/definitions/color"},
					"info_bg":         map[string]any{"$ref": "#/definitions/color"},
					"info_fg":         map[string]any{"$ref": "#/definitions/color"},
					"status_bg":       map[string]any{"$ref": "#/definitions/color"},
					"status_fg":       map[string]any{"$ref": "#/definitions/color"},
					"status_shade_fg": map[string]any{"$ref": "#/definitions/color"},
					"border_bg":       map[string]any{"$ref": "#/definitions/color"},
					"border_shade_fg": map[string]any{"$ref": "#/definitions/color"},
					"terminal_bg2":    map[string]any{"type": "string"},
					"terminal_bg":     map[string]any{"type": "string"},
					"terminal_fg":     map[string]any{"type": "string"},
					"terminal_border": map[string]any{"type": "string"},
					"warning_fg":      map[string]any{"$ref": "#/definitions/color"},
					"success_fg":      map[string]any{"$ref": "#/definitions/color"},
				},
				"additionalProperties": false,
			},
		},
	}

	artSchema := map[string]any{
		"$schema": "http://json-schema.org/draft-07/schema#",
		"type":    "object",
		"properties": map[string]any{
			"description": map[string]any{"type": "string"},
			"colors": map[string]any{
				"type": "object",
				"additionalProperties": map[string]any{
					"anyOf": []any{
						map[string]any{"type": "integer", "minimum": 0, "maximum": 255},
						map[string]any{
							"type": "string",
							"enum": uniqueEnums,
						},
						map[string]any{
							"type":    "string",
							"pattern": "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$",
						},
					},
				},
			},
			"palette": map[string]any{
				"type": "object",
				"additionalProperties": map[string]any{
					"anyOf": []any{
						map[string]any{"type": "null"},
						map[string]any{"type": "integer", "minimum": 0, "maximum": 255},
						map[string]any{
							"type": "string",
							"enum": uniqueEnums,
						},
						map[string]any{
							"type":    "string",
							"pattern": "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$",
						},
					},
				},
			},
			"priority": map[string]any{
				"type": "array",
				"items": map[string]any{"type": "string"},
			},
			"art": map[string]any{
				"type": "array",
				"items": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"name":           map[string]any{"type": "string"},
						"target":         map[string]any{"type": "string"},
						"mode":           map[string]any{"type": "string", "enum": []string{"quad"}},
						"spaced":         map[string]any{"type": "boolean"},
						"indent":         map[string]any{"type": "string"},
						"stack": map[string]any{
							"type": "array",
							"items": map[string]any{
								"anyOf": []any{
									map[string]any{"type": "string"},
									map[string]any{
										"type": "object",
										"properties": map[string]any{
											"path": map[string]any{"type": "string"},
											"fps":  map[string]any{"type": "integer"},
										},
										"required": []string{"path"},
									},
								},
							},
						},
						"fps":            map[string]any{"type": "integer"},
						"start_delay_ms": map[string]any{"type": "integer"},
						"end_delay_ms":   map[string]any{"type": "integer"},
						"header": map[string]any{
							"type":  "array",
							"items": map[string]any{"type": "string"},
						},
						"footer": map[string]any{
							"type":  "array",
							"items": map[string]any{"type": "string"},
						},
					},
					"required": []string{"name", "target", "mode", "spaced"},
				},
			},
		},
		"required": []string{"colors", "palette", "priority", "art"},
	}

	writeSchema := func(path string, val any) {
		data, err := json.MarshalIndent(val, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal schema %s: %v\n", path, err)
			os.Exit(1)
		}
		if err := os.WriteFile(path, data, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "write schema %s: %v\n", path, err)
			os.Exit(1)
		}
	}

	writeSchema("spec/theme.schema.json", themeSchema)
	writeSchema("spec/art.schema.json", artSchema)

	out := map[string]any{
		"description": "Full xterm-256 palette. Each entry: i (index 0-255), " +
			"name (long), short (3-letter), hex, desc (human colour family). " +
			"Both name and short resolve anywhere the picker takes a colour " +
			"(e.g. multi_select_bg in spec/strings.json) — else use the numeric " +
			"index. System colours (0-15) and popular colours get friendly names; " +
			"the rest use systematic rgbRGB / grayN names (cube level digits 0-5). " +
			"Generated by scripts/gen_colors — run `make gen-colors` to regenerate.",
		"colors": colors,
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, "encode:", err)
		os.Exit(1)
	}
}

// withName builds a cube/gray entry, applying a popular-name override (keeping
// the systematic name reachable as an alias) when one exists.
func withName(i int, canon string, r, g, b int) colorEntry {
	e := colorEntry{I: i, Name: canon, Hex: hex(r, g, b), Desc: describe(r, g, b)}
	if p, ok := popular[i]; ok {
		e.Name = p.name
		e.Short = p.short
		e.Alt = append([]string{canon}, p.alt...)
	}
	return e
}

func hex(r, g, b int) string { return fmt.Sprintf("#%02x%02x%02x", r, g, b) }

// systemRGB returns the conventional RGB for an ANSI system colour (0-15).
func systemRGB(i int) (int, int, int) {
	base := [16][3]int{
		{0, 0, 0}, {128, 0, 0}, {0, 128, 0}, {128, 128, 0},
		{0, 0, 128}, {128, 0, 128}, {0, 128, 128}, {192, 192, 192},
		{128, 128, 128}, {255, 0, 0}, {0, 255, 0}, {255, 255, 0},
		{0, 0, 255}, {255, 0, 255}, {0, 255, 255}, {255, 255, 255},
	}
	return base[i][0], base[i][1], base[i][2]
}

// describe returns a short human colour family like "dark green" or "pale cyan"
// for documentation. Grays are detected by equal channels.
func describe(r, g, b int) string {
	maxc := math.Max(float64(r), math.Max(float64(g), float64(b)))
	minc := math.Min(float64(r), math.Min(float64(g), float64(b)))
	v := maxc / 255.0
	if maxc == minc {
		switch {
		case maxc == 0:
			return "black"
		case v < 0.30:
			return "dark gray"
		case v < 0.65:
			return "gray"
		case v < 0.95:
			return "light gray"
		default:
			return "white"
		}
	}
	sat := (maxc - minc) / maxc
	hue := hueOf(float64(r), float64(g), float64(b), maxc, minc)
	names := []string{
		"red", "orange", "yellow", "chartreuse", "green", "spring green",
		"cyan", "azure", "blue", "violet", "magenta", "rose",
	}
	family := names[int(math.Mod(hue/30.0+0.5, 12))]

	var light string
	switch {
	case v < 0.45:
		light = "dark "
	case sat < 0.35:
		light = "pale "
	case v > 0.85 && sat < 0.7:
		light = "light "
	}
	return light + family
}

// hueOf returns the colour hue in degrees [0,360).
func hueOf(r, g, b, maxc, minc float64) float64 {
	d := maxc - minc
	var h float64
	switch maxc {
	case r:
		h = math.Mod((g-b)/d, 6)
	case g:
		h = (b-r)/d + 2
	default:
		h = (r-g)/d + 4
	}
	h *= 60
	if h < 0 {
		h += 360
	}
	return h
}
