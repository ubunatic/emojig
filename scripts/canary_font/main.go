// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// canary_font is the Go counterpart of scripts/canary_font.zig — same
// minimal behavior (render -text with -font via Cairo+Pango into an
// offscreen image, save a PNG with a baked terminal/session label, write a
// companion env dump), built with a different tech stack (cgo + dlopen
// instead of Zig's dlopen'd extern-fn-pointer struct) so the two can be
// compared directly. See docs/EmojiWidthResearch.md.
//
// Run: go run ./scripts/canary_font -- -help
// Manual/on-demand only — not part of `make canary`.
package main

/*
#cgo LDFLAGS: -ldl
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef void* (*create_for_data_fn)(unsigned char*, int, int, int, int);
typedef void* (*create_fn)(void*);
typedef void  (*destroy_fn)(void*);
typedef void  (*surface_flush_fn)(void*);
typedef int   (*write_png_fn)(void*, const char*);
typedef void  (*set_source_rgb_fn)(void*, double, double, double);
typedef void  (*paint_fn)(void*);
typedef void  (*move_to_fn)(void*, double, double);
typedef void* (*font_desc_new_fn)(void);
typedef void  (*font_desc_set_family_fn)(void*, const char*);
typedef void  (*font_desc_set_size_fn)(void*, double);
typedef void  (*font_desc_free_fn)(void*);
typedef void* (*create_layout_fn)(void*);
typedef void  (*layout_set_font_desc_fn)(void*, void*);
typedef void  (*layout_set_text_fn)(void*, const char*, int);
typedef void  (*layout_get_pixel_size_fn)(void*, int*, int*);
typedef void  (*show_layout_fn)(void*, void*);

static create_for_data_fn      p_image_surface_create_for_data;
static create_fn               p_create;
static destroy_fn               p_destroy;
static destroy_fn               p_surface_destroy;
static surface_flush_fn         p_surface_flush;
static write_png_fn             p_surface_write_to_png;
static set_source_rgb_fn        p_set_source_rgb;
static paint_fn                 p_paint;
static move_to_fn               p_move_to;
static font_desc_new_fn         p_font_description_new;
static font_desc_set_family_fn  p_font_description_set_family;
static font_desc_set_size_fn    p_font_description_set_absolute_size;
static font_desc_free_fn        p_font_description_free;
static create_layout_fn         p_cairo_create_layout;
static layout_set_font_desc_fn  p_layout_set_font_description;
static layout_set_text_fn       p_layout_set_text;
static layout_get_pixel_size_fn p_layout_get_pixel_size;
static show_layout_fn           p_cairo_show_layout;

// loadCairoPango dlopens libcairo/libpango/libpangocairo by their runtime
// SONAMEs (not the unversioned -dev symlinks pkg-config/-lcairo would need)
// and resolves every symbol used below. Returns NULL on success, or a
// static message naming what failed.
static const char* loadCairoPango(void) {
	void *cairo_h = dlopen("libcairo.so.2", RTLD_LAZY);
	if (!cairo_h) return "dlopen libcairo.so.2 failed";
	void *pango_h = dlopen("libpango-1.0.so.0", RTLD_LAZY);
	if (!pango_h) return "dlopen libpango-1.0.so.0 failed";
	void *pangocairo_h = dlopen("libpangocairo-1.0.so.0", RTLD_LAZY);
	if (!pangocairo_h) return "dlopen libpangocairo-1.0.so.0 failed";

	p_image_surface_create_for_data      = (create_for_data_fn)dlsym(cairo_h, "cairo_image_surface_create_for_data");
	p_create                             = (create_fn)dlsym(cairo_h, "cairo_create");
	p_destroy                            = (destroy_fn)dlsym(cairo_h, "cairo_destroy");
	p_surface_destroy                    = (destroy_fn)dlsym(cairo_h, "cairo_surface_destroy");
	p_surface_flush                      = (surface_flush_fn)dlsym(cairo_h, "cairo_surface_flush");
	p_surface_write_to_png               = (write_png_fn)dlsym(cairo_h, "cairo_surface_write_to_png");
	p_set_source_rgb                     = (set_source_rgb_fn)dlsym(cairo_h, "cairo_set_source_rgb");
	p_paint                              = (paint_fn)dlsym(cairo_h, "cairo_paint");
	p_move_to                            = (move_to_fn)dlsym(cairo_h, "cairo_move_to");
	p_font_description_new               = (font_desc_new_fn)dlsym(pango_h, "pango_font_description_new");
	p_font_description_set_family        = (font_desc_set_family_fn)dlsym(pango_h, "pango_font_description_set_family");
	p_font_description_set_absolute_size = (font_desc_set_size_fn)dlsym(pango_h, "pango_font_description_set_absolute_size");
	p_font_description_free              = (font_desc_free_fn)dlsym(pango_h, "pango_font_description_free");
	p_cairo_create_layout                = (create_layout_fn)dlsym(pangocairo_h, "pango_cairo_create_layout");
	p_layout_set_font_description        = (layout_set_font_desc_fn)dlsym(pango_h, "pango_layout_set_font_description");
	p_layout_set_text                    = (layout_set_text_fn)dlsym(pango_h, "pango_layout_set_text");
	p_layout_get_pixel_size              = (layout_get_pixel_size_fn)dlsym(pango_h, "pango_layout_get_pixel_size");
	p_cairo_show_layout                  = (show_layout_fn)dlsym(pangocairo_h, "pango_cairo_show_layout");

	if (!p_image_surface_create_for_data || !p_create || !p_destroy || !p_surface_destroy ||
	    !p_surface_flush || !p_surface_write_to_png || !p_set_source_rgb || !p_paint || !p_move_to ||
	    !p_font_description_new || !p_font_description_set_family || !p_font_description_set_absolute_size ||
	    !p_font_description_free || !p_cairo_create_layout || !p_layout_set_font_description ||
	    !p_layout_set_text || !p_layout_get_pixel_size || !p_cairo_show_layout) {
		return "dlsym failed for one or more cairo/pango symbols";
	}
	return NULL;
}

static void* cf_image_surface_create_for_data(unsigned char *data, int format, int width, int height, int stride) {
	return p_image_surface_create_for_data(data, format, width, height, stride);
}
static void* cf_create(void *surface) { return p_create(surface); }
static void  cf_destroy(void *cr) { p_destroy(cr); }
static void  cf_surface_destroy(void *surface) { p_surface_destroy(surface); }
static void  cf_surface_flush(void *surface) { p_surface_flush(surface); }
static int   cf_surface_write_to_png(void *surface, const char *filename) { return p_surface_write_to_png(surface, filename); }
static void  cf_set_source_rgb(void *cr, double r, double g, double b) { p_set_source_rgb(cr, r, g, b); }
static void  cf_paint(void *cr) { p_paint(cr); }
static void  cf_move_to(void *cr, double x, double y) { p_move_to(cr, x, y); }
static void* cf_font_description_new(void) { return p_font_description_new(); }
static void  cf_font_description_set_family(void *desc, const char *family) { p_font_description_set_family(desc, family); }
static void  cf_font_description_set_absolute_size(void *desc, double size) { p_font_description_set_absolute_size(desc, size); }
static void  cf_font_description_free(void *desc) { p_font_description_free(desc); }
static void* cf_cairo_create_layout(void *cr) { return p_cairo_create_layout(cr); }
static void  cf_layout_set_font_description(void *layout, void *desc) { p_layout_set_font_description(layout, desc); }
static void  cf_layout_set_text(void *layout, const char *text, int length) { p_layout_set_text(layout, text, length); }
static void  cf_layout_get_pixel_size(void *layout, int *w, int *h) { p_layout_get_pixel_size(layout, w, h); }
static void  cf_cairo_show_layout(void *cr, void *layout) { p_cairo_show_layout(cr, layout); }
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

const cairoFormatARGB32 = 0

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
	fmt.Printf("canary_font: saved %s\n", dumpPath)
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
	flag.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage: go run ./scripts/canary_font -- [flags]

Renders -text with -font (a Pango family name — fontconfig resolves it to a
real installed font; vector families like "DejaVu Sans Mono" or "Noto Color
Emoji" and bitmap/CBDT families like "Twemoji" both go through the same
Cairo/Pango path, so the flag *is* the vector-vs-bitmap switch) into an
offscreen image and saves it as a PNG — no window, no compositor, no
screenshot tool, since alignment is decided entirely by Pango/Cairo/
FreeType before presentation. Every render bakes a terminal/session label
into the image and writes a companion <out>.env.txt env-var dump.

This is the Go counterpart of scripts/canary_font.zig — same behavior, a
different tech stack (cgo+dlopen instead of Zig's dlopen), for comparison.

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

	if errMsg := C.loadCairoPango(); errMsg != nil {
		fmt.Fprintf(os.Stderr, "canary_font: %s\n", C.GoString(errMsg))
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
	scratchSurface := C.cf_image_surface_create_for_data((*C.uchar)(unsafe.Pointer(&scratchPixels[0])), cairoFormatARGB32, 1, 1, 4)
	scratchCr := C.cf_create(scratchSurface)
	fontDesc := C.cf_font_description_new()
	C.cf_font_description_set_family(fontDesc, fontFamilyC)
	C.cf_font_description_set_absolute_size(fontDesc, C.double(*sizePx*1024.0))
	scratchLayout := C.cf_cairo_create_layout(scratchCr)
	C.cf_layout_set_font_description(scratchLayout, fontDesc)
	C.cf_layout_set_text(scratchLayout, textC, C.int(len(*text)))
	var textW, textH C.int
	C.cf_layout_get_pixel_size(scratchLayout, &textW, &textH)

	// Label uses a plain system font (not -font) at a small fixed size —
	// it's metadata chrome, not part of the thing being measured.
	const labelSizePx = 13.0
	labelFamilyC := C.CString("sans-serif")
	defer C.free(unsafe.Pointer(labelFamilyC))
	labelDesc := C.cf_font_description_new()
	C.cf_font_description_set_family(labelDesc, labelFamilyC)
	C.cf_font_description_set_absolute_size(labelDesc, C.double(labelSizePx*1024.0))
	scratchLabelLayout := C.cf_cairo_create_layout(scratchCr)
	C.cf_layout_set_font_description(scratchLabelLayout, labelDesc)
	C.cf_layout_set_text(scratchLabelLayout, labelTextC, C.int(len(labelText)))
	var labelW, labelH C.int
	C.cf_layout_get_pixel_size(scratchLabelLayout, &labelW, &labelH)

	C.cf_destroy(scratchCr)
	C.cf_surface_destroy(scratchSurface)

	const labelGap = 16
	padI := int(*pad)
	width := max(int(textW), int(labelW)) + padI*2
	height := int(textH) + labelGap + int(labelH) + padI*2
	fmt.Printf("canary_font: measured text %dx%dpx, label %dx%dpx, image %dx%dpx, font=%s, terminal=%s\n",
		textW, textH, labelW, labelH, width, height, *font, terminalName)

	stride := width * 4
	pixels := make([]byte, stride*height)

	realSurface := C.cf_image_surface_create_for_data((*C.uchar)(unsafe.Pointer(&pixels[0])), cairoFormatARGB32, C.int(width), C.int(height), C.int(stride))
	realCr := C.cf_create(realSurface)
	C.cf_set_source_rgb(realCr, C.double(bg[0]), C.double(bg[1]), C.double(bg[2]))
	C.cf_paint(realCr)
	C.cf_set_source_rgb(realCr, C.double(fg[0]), C.double(fg[1]), C.double(fg[2]))
	C.cf_move_to(realCr, C.double(*pad), C.double(*pad))
	realLayout := C.cf_cairo_create_layout(realCr)
	C.cf_layout_set_font_description(realLayout, fontDesc)
	C.cf_layout_set_text(realLayout, textC, C.int(len(*text)))
	C.cf_cairo_show_layout(realCr, realLayout)

	// Dimmer than the main text so it reads as metadata, not content.
	C.cf_set_source_rgb(realCr, C.double(fg[0]*0.55), C.double(fg[1]*0.55), C.double(fg[2]*0.55))
	C.cf_move_to(realCr, C.double(*pad), C.double(*pad+float64(textH)+labelGap))
	realLabelLayout := C.cf_cairo_create_layout(realCr)
	C.cf_layout_set_font_description(realLabelLayout, labelDesc)
	C.cf_layout_set_text(realLabelLayout, labelTextC, C.int(len(labelText)))
	C.cf_cairo_show_layout(realCr, realLabelLayout)

	C.cf_surface_flush(realSurface)
	C.cf_destroy(realCr)

	outPathC := C.CString(outPath)
	defer C.free(unsafe.Pointer(outPathC))
	C.cf_surface_write_to_png(realSurface, outPathC)
	C.cf_surface_destroy(realSurface)
	C.cf_font_description_free(fontDesc)
	C.cf_font_description_free(labelDesc)

	fmt.Printf("canary_font: saved %s\n", outPath)
}
