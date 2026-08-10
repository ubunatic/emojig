// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// canary_font is the Go counterpart of scripts/canary_font.zig — same
// minimal behavior (render -text with -font via Cairo+Pango into an
// offscreen image, save a PNG with a baked terminal/session label, write a
// companion env dump), built with a different tech stack (cgo linked
// straight against the real cairo/pango/pangocairo headers via pkg-config,
// vs. Zig's manually dlopen'd extern-fn-pointer struct) so the two can be
// compared directly. See docs/EmojiWidthResearch.md.
//
// Requires cairo/pango/pangocairo -dev packages: `make canary-font-go-deps`
// (or `scripts/install_cairo_pango_dev.sh`) installs them.
//
// Font-fallback is disabled by default (-allow-fallback to re-enable):
// Pango's default fallback silently substitutes a different family for
// emoji-presentation codepoints regardless of -font, even when the
// requested font covers the glyph — verified with hb-shape that
// Twemoji.ttf has a real glyph for U+1F680 that unmodified Pango ignored
// in favor of Noto Color Emoji. Without this, -font was a no-op for
// emoji. See docs/EmojiWidthResearch.md and
// issues/59-canary-font-research-gaps.md.
//
// Scope: only the Pango/Cairo/FreeType/fontconfig stack. foot links no
// Pango at all (libfcft+FreeType+HarfBuzz directly) and no terminal lays
// out its grid via pango_layout, so this canary cannot speak to foot's
// behavior or terminal grid alignment specifically.
//
// Run: go run ./scripts/canary_font -- -help
// Manual/on-demand only — not part of `make canary`.
package main

/*
#cgo pkg-config: cairo pango pangocairo
#include <cairo/cairo.h>
#include <pango/pango.h>
#include <pango/pangocairo.h>
*/
import "C"

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unsafe"
)

func hexToUnit(hex string) float64 {
	v, err := strconv.ParseUint(hex, 16, 16)
	if err != nil {
		return 0
	}
	return float64(v) / 255.0
}

func parseColor(hex6 string) [3]float64 {
	if len(hex6) != 6 {
		return [3]float64{0, 0, 0}
	}
	return [3]float64{hexToUnit(hex6[0:2]), hexToUnit(hex6[2:4]), hexToUnit(hex6[4:6])}
}

func sanitizeForFilename(s string) string {
	var b strings.Builder
	for _, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			b.WriteRune(toLower(c))
		} else {
			b.WriteByte('-')
		}
	}
	return b.String()
}

func toLower(c rune) rune {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// envOr returns an env var's value, or "(unset)" — used for both the
// companion dump and terminal-name detection, so a missing var is always
// visible rather than silently absent from the record.
func envOr(name string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	return "(unset)"
}

// detectTerminalName is a best-effort terminal-emulator label from the env
// vars each emulator is known to set (most-specific first, so e.g. TILIX_ID
// wins over the generic VTE_VERSION every VTE-based terminal sets). Falls
// back to $TERM, then "unknown" — a research label for comparing renders
// across hosts/terminals, not a detection mechanism anything else depends on.
func detectTerminalName() string {
	switch {
	case os.Getenv("TILIX_ID") != "":
		return "tilix"
	case os.Getenv("KONSOLE_VERSION") != "":
		return "konsole"
	case os.Getenv("GNOME_TERMINAL_SCREEN") != "" || os.Getenv("GNOME_TERMINAL_SERVICE") != "":
		return "gnome-terminal"
	case os.Getenv("WEZTERM_EXECUTABLE") != "" || os.Getenv("WEZTERM_PANE") != "":
		return "wezterm"
	case os.Getenv("KITTY_WINDOW_ID") != "":
		return "kitty"
	case os.Getenv("ALACRITTY_SOCKET") != "" || os.Getenv("ALACRITTY_LOG") != "":
		return "alacritty"
	case os.Getenv("GHOSTTY_RESOURCES_DIR") != "":
		return "ghostty"
	case os.Getenv("VTE_VERSION") != "":
		return "vte-based"
	case os.Getenv("TERM_PROGRAM") != "":
		return os.Getenv("TERM_PROGRAM")
	case os.Getenv("TERM") != "":
		return os.Getenv("TERM")
	default:
		return "unknown"
	}
}

// envDumpVars mirrors scripts/canary_font.zig's writeEnvDump list — the
// font-stack vars (FREETYPE_PROPERTIES/FONTCONFIG_*/FC_LANG/
// PANGOCAIRO_BACKEND) were added after a websearch of fontconfig/FreeType/
// Pango docs for vars that can change glyph metrics or font selection; see
// docs/EmojiWidthResearch.md for sources.
var envDumpVars = []string{
	"TERM", "TERM_PROGRAM", "WAYLAND_DISPLAY", "DISPLAY", "XDG_SESSION_TYPE",
	"XDG_CURRENT_DESKTOP", "DESKTOP_SESSION", "SWAYSOCK", "GDK_BACKEND",
	"QT_QPA_PLATFORM", "LANG", "LC_ALL", "FREETYPE_PROPERTIES",
	"FONTCONFIG_PATH", "FONTCONFIG_FILE", "FONTCONFIG_SYSROOT", "FC_LANG",
	"PANGOCAIRO_BACKEND", "VTE_VERSION", "TILIX_ID", "KONSOLE_VERSION",
	"WEZTERM_EXECUTABLE", "KITTY_WINDOW_ID", "ALACRITTY_SOCKET",
	"GHOSTTY_RESOURCES_DIR", "GNOME_TERMINAL_SCREEN",
}

// disableFallback forces every glyph in layout to actually come from its
// PangoFontDescription's requested family — Pango's default per-run
// fallback silently substitutes a *different* family for codepoints
// tagged Emoji_Presentation (e.g. rocket 🚀), regardless of what -font
// asked for and regardless of whether the requested font also covers
// that glyph (verified: HarfBuzz reports a real, non-.notdef glyph for
// U+1F680 in Twemoji.ttf, yet Pango picked Noto Color Emoji anyway).
// Confirmed empirically that -font was otherwise a no-op for emoji glyphs
// specifically — see docs/EmojiWidthResearch.md and issue 59. With
// fallback disabled, a font that genuinely lacks a glyph shows a tofu/
// notdef box instead of silently substituting — the honest result this
// research tool needs.
func disableFallback(layout *C.PangoLayout) {
	attrs := C.pango_attr_list_new()
	attr := C.pango_attr_fallback_new(C.FALSE)
	C.pango_attr_list_insert(attrs, attr)        // list takes ownership of attr
	C.pango_layout_set_attributes(layout, attrs) // layout takes its own ref
}

// absPath returns path as an absolute path (unchanged if already absolute)
// — printed paths must be absolute for a terminal's own ctrl+click-to-open
// file-link detection to reliably find them; a relative path only resolves
// if the terminal you're reading it in happens to share this process's CWD.
// Falls back to the original path on error (best-effort for a log line).
func absPath(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		return abs
	}
	return path
}

// writeEnvDump writes a companion text file next to the PNG recording the
// env vars most likely to matter when comparing renders across hosts/
// terminals later — a bare PNG filename doesn't carry that context on its
// own.
func writeEnvDump(outPath, font, text string, sizePx float64, terminalName string) error {
	dumpPath := strings.TrimSuffix(outPath, ".png") + ".env.txt"
	var b strings.Builder
	fmt.Fprintf(&b, "# canary_font companion env dump\n")
	fmt.Fprintf(&b, "terminal=%s\n", terminalName)
	fmt.Fprintf(&b, "font=%s\n", font)
	fmt.Fprintf(&b, "text=%s\n", text)
	fmt.Fprintf(&b, "size_px=%g\n", sizePx)
	for _, name := range envDumpVars {
		fmt.Fprintf(&b, "%s=%s\n", name, envOr(name))
	}
	if err := os.WriteFile(dumpPath, []byte(b.String()), 0o644); err != nil {
		return err
	}
	fmt.Printf("canary_font: saved %s\n", absPath(dumpPath))
	return nil
}

func main() {
	font := flag.String("font", "monospace", "Pango font family")
	text := flag.String("text", "abc ABC 123 ☺️ ☺︎ \U0001f600 \U0001f680", "text/emoji to render")
	sizePx := flag.Float64("size", 48, "pixel font size")
	pad := flag.Float64("pad", 16, "padding around the text")
	bgHex := flag.String("bg", "1e1e24", "background hex color")
	fgHex := flag.String("fg", "eaeae6", "text hex color")
	out := flag.String("out", "", "output PNG path (default: scripts/canary_font/shots/<font>.png)")
	unset := flag.String("unset", "", "comma-separated env vars to unset before rendering")
	allowFallback := flag.Bool("allow-fallback", false, "let Pango substitute a different font when the requested one is missing/incomplete for a glyph (default: off)")
	flag.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage: go run ./scripts/canary_font -- [flags]

Renders -text with -font (a Pango family name — fontconfig resolves it to a
real installed font; vector families like "DejaVu Sans Mono" or "Noto Color
Emoji" and bitmap/CBDT families like "Twemoji" both go through the same
Cairo/Pango path) into an offscreen image and saves it as a PNG — no
window, no compositor, no screenshot tool, since alignment is decided
entirely by Pango/Cairo/FreeType before presentation. Font-fallback is
disabled by default (see -allow-fallback below) so -font is a real,
honest switch: Pango's default fallback silently substitutes a different
family for emoji-presentation codepoints regardless of what you asked
for, even when the requested font covers the glyph. Every render bakes a
terminal/session label into the image and writes a companion
<out>.env.txt env-var dump.

This is the Go counterpart of scripts/canary_font.zig — same behavior, a
different tech stack (cgo+pkg-config instead of Zig's dlopen), for
comparison. Requires cairo/pango/pangocairo -dev packages — run
'make canary-font-go-deps' first if the build fails to find them.

Only covers the Pango/Cairo/FreeType/fontconfig stack (GTK, VTE-based
terminals, etc.) — foot links no Pango at all (libfcft+FreeType+HarfBuzz
directly) and no terminal lays out a grid via pango_layout, so this
canary cannot speak to foot's or a terminal grid's behavior specifically.

`)
		flag.PrintDefaults()
		fmt.Fprint(os.Stderr, "\nManual/on-demand only — not part of `make canary`. See docs/EmojiWidthResearch.md.\n")
	}
	flag.Parse()

	for _, name := range strings.Split(*unset, ",") {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		os.Unsetenv(name)
		fmt.Printf("canary_font: unset %s\n", name)
	}

	bg := parseColor(*bgHex)
	fg := parseColor(*fgHex)

	outPath := *out
	if outPath == "" {
		outPath = filepath.Join("scripts", "canary_font", "shots", sanitizeForFilename(*font)+".png")
	}
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "canary_font: mkdir failed: %v\n", err)
		os.Exit(1)
	}

	terminalName := detectTerminalName()
	labelText := fmt.Sprintf("term=%s  TERM=%s  session=%s/%s", terminalName, envOr("TERM"), envOr("XDG_SESSION_TYPE"), envOr("XDG_CURRENT_DESKTOP"))
	if err := writeEnvDump(outPath, *font, *text, *sizePx, terminalName); err != nil {
		fmt.Fprintf(os.Stderr, "canary_font: env dump failed: %v\n", err)
		os.Exit(1)
	}

	fontFamilyC := C.CString(*font)
	defer C.free(unsafe.Pointer(fontFamilyC))
	textC := C.CString(*text)
	defer C.free(unsafe.Pointer(textC))
	labelTextC := C.CString(labelText)
	defer C.free(unsafe.Pointer(labelTextC))

	// Measure the text and the label (against a tiny scratch surface) so
	// the real image is sized exactly to its content plus padding — a
	// pre-cropped PNG rather than a fixed canvas with stray blank margins.
	scratchPixels := make([]byte, 4)
	scratchSurface := C.cairo_image_surface_create_for_data((*C.uchar)(unsafe.Pointer(&scratchPixels[0])), C.CAIRO_FORMAT_ARGB32, 1, 1, 4)
	scratchCr := C.cairo_create(scratchSurface)
	fontDesc := C.pango_font_description_new()
	C.pango_font_description_set_family(fontDesc, fontFamilyC)
	C.pango_font_description_set_absolute_size(fontDesc, C.double(*sizePx*1024.0))
	scratchLayout := C.pango_cairo_create_layout(scratchCr)
	C.pango_layout_set_font_description(scratchLayout, fontDesc)
	if !*allowFallback {
		disableFallback(scratchLayout)
	}
	C.pango_layout_set_text(scratchLayout, textC, C.int(len(*text)))
	var textW, textH C.int
	C.pango_layout_get_pixel_size(scratchLayout, &textW, &textH)

	// Label uses a plain system font (not -font) at a small fixed size —
	// it's metadata chrome, not part of the thing being measured.
	const labelSizePx = 13.0
	labelFamilyC := C.CString("sans-serif")
	defer C.free(unsafe.Pointer(labelFamilyC))
	labelDesc := C.pango_font_description_new()
	C.pango_font_description_set_family(labelDesc, labelFamilyC)
	C.pango_font_description_set_absolute_size(labelDesc, C.double(labelSizePx*1024.0))
	scratchLabelLayout := C.pango_cairo_create_layout(scratchCr)
	C.pango_layout_set_font_description(scratchLabelLayout, labelDesc)
	C.pango_layout_set_text(scratchLabelLayout, labelTextC, C.int(len(labelText)))
	var labelW, labelH C.int
	C.pango_layout_get_pixel_size(scratchLabelLayout, &labelW, &labelH)

	C.cairo_destroy(scratchCr)
	C.cairo_surface_destroy(scratchSurface)

	const labelGap = 16
	padI := int(*pad)
	width := max(int(textW), int(labelW)) + padI*2
	height := int(textH) + labelGap + int(labelH) + padI*2
	fmt.Printf("canary_font: measured text %dx%dpx, label %dx%dpx, image %dx%dpx, font=%s, terminal=%s\n",
		textW, textH, labelW, labelH, width, height, *font, terminalName)

	stride := width * 4
	pixels := make([]byte, stride*height)

	realSurface := C.cairo_image_surface_create_for_data((*C.uchar)(unsafe.Pointer(&pixels[0])), C.CAIRO_FORMAT_ARGB32, C.int(width), C.int(height), C.int(stride))
	realCr := C.cairo_create(realSurface)
	C.cairo_set_source_rgb(realCr, C.double(bg[0]), C.double(bg[1]), C.double(bg[2]))
	C.cairo_paint(realCr)
	C.cairo_set_source_rgb(realCr, C.double(fg[0]), C.double(fg[1]), C.double(fg[2]))
	C.cairo_move_to(realCr, C.double(*pad), C.double(*pad))
	realLayout := C.pango_cairo_create_layout(realCr)
	C.pango_layout_set_font_description(realLayout, fontDesc)
	if !*allowFallback {
		disableFallback(realLayout)
	}
	C.pango_layout_set_text(realLayout, textC, C.int(len(*text)))
	C.pango_cairo_show_layout(realCr, realLayout)

	// Dimmer than the main text so it reads as metadata, not content.
	C.cairo_set_source_rgb(realCr, C.double(fg[0]*0.55), C.double(fg[1]*0.55), C.double(fg[2]*0.55))
	C.cairo_move_to(realCr, C.double(*pad), C.double(*pad+float64(textH)+labelGap))
	realLabelLayout := C.pango_cairo_create_layout(realCr)
	C.pango_layout_set_font_description(realLabelLayout, labelDesc)
	C.pango_layout_set_text(realLabelLayout, labelTextC, C.int(len(labelText)))
	C.pango_cairo_show_layout(realCr, realLabelLayout)

	C.cairo_surface_flush(realSurface)
	C.cairo_destroy(realCr)

	outPathC := C.CString(outPath)
	defer C.free(unsafe.Pointer(outPathC))
	C.cairo_surface_write_to_png(realSurface, outPathC)
	C.cairo_surface_destroy(realSurface)
	C.pango_font_description_free(fontDesc)
	C.pango_font_description_free(labelDesc)

	fmt.Printf("canary_font: saved %s\n", absPath(outPath))
}
