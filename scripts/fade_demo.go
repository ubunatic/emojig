// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// fade_demo.go — Interactive visual demonstration of TUI exit fade-out animations.
// It mocks the Emojig TUI layout and allows the user to preview four different
// exit animation techniques: 24-bit RGB Truecolor Melt, Dither Dissolve, Scanline Wipe,
// and Theme-Aware Shade BG Fade + Text Removal (Legibility-Preserving & Safe).
// Supports toggling between Dark/Light themes and Transparency.
// Usage: go run scripts/fade_demo.go
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Color representation & linear interpolation
// ---------------------------------------------------------------------------

type RGB struct {
	R, G, B int
}

func (c RGB) ToFG() string {
	return fmt.Sprintf("\x1b[38;2;%d;%d;%dm", c.R, c.G, c.B)
}

func (c RGB) ToBG() string {
	return fmt.Sprintf("\x1b[48;2;%d;%d;%dm", c.R, c.G, c.B)
}

func (c RGB) Lerp(other RGB, t float64) RGB {
	return RGB{
		R: int(float64(c.R) + t*float64(other.R-c.R)),
		G: int(float64(c.G) + t*float64(other.G-c.G)),
		B: int(float64(c.B) + t*float64(other.B-c.B)),
	}
}

type Palette struct {
	BG       RGB
	FG       RGB
	SearchBG RGB
	SearchFG RGB
	SelBG    RGB
	SelFG    RGB
	BorderBG RGB
}

var darkPalette = Palette{
	BG:       RGB{28, 28, 28},
	FG:       RGB{168, 168, 168},
	SearchBG: RGB{68, 68, 68},
	SearchFG: RGB{255, 255, 255},
	SelBG:    RGB{0, 95, 135},
	SelFG:    RGB{255, 255, 255},
	BorderBG: RGB{48, 48, 48},
}

var lightPalette = Palette{
	BG:       RGB{238, 238, 238},
	FG:       RGB{68, 68, 68},
	SearchBG: RGB{198, 198, 198},
	SearchFG: RGB{8, 8, 8},
	SelBG:    RGB{135, 175, 215},
	SelFG:    RGB{8, 8, 8},
	BorderBG: RGB{208, 208, 208},
}

// ---------------------------------------------------------------------------
// Terminal state & raw mode handling
// ---------------------------------------------------------------------------

var originalTermState string

func enterRawMode() {
	cmd := exec.Command("stty", "-g")
	state, err := cmd.Output()
	if err == nil {
		originalTermState = strings.TrimSpace(string(state))
	}
	cmdRaw := exec.Command("stty", "raw", "-echo")
	cmdRaw.Stdin = os.Stdin
	_ = cmdRaw.Run()
	fmt.Print("\x1b[?25l") // Hide cursor
}

func restoreTerminal() {
	fmt.Print("\x1b[30;1H\x1b[?25h\x1b[0m") // Move cursor down, show cursor, reset styling
	if originalTermState != "" {
		cmd := exec.Command("stty", originalTermState)
		cmd.Stdin = os.Stdin
		_ = cmd.Run()
	}
}

// ---------------------------------------------------------------------------
// Mock TUI layouts
// ---------------------------------------------------------------------------

type Cell struct {
	Text       string // Emoji glyph or label string
	IsEmoji    bool
	IsSelected bool
}

var mockGrid = [4][6]Cell{
	{
		{Text: "🧑‍🚒", IsEmoji: true, IsSelected: true},
		{Text: "🚒", IsEmoji: true},
		{Text: "🔥", IsEmoji: true},
		{Text: "💧", IsEmoji: true},
		{Text: "🌲", IsEmoji: true},
		{Text: "🏫", IsEmoji: true},
	},
	{
		{Text: "🪵", IsEmoji: true},
		{Text: "🧯", IsEmoji: true},
		{Text: "🚨", IsEmoji: true},
		{Text: "🚒", IsEmoji: true},
		{Text: "🪓", IsEmoji: true},
		{Text: "🪜", IsEmoji: true},
	},
	{
		{Text: "🥯", IsEmoji: true},
		{Text: "⛺", IsEmoji: true},
		{Text: "🍂", IsEmoji: true},
		{Text: "🍃", IsEmoji: true},
		{Text: "🍁", IsEmoji: true},
		{Text: "🌾", IsEmoji: true},
	},
	{
		{Text: "🌪", IsEmoji: true},
		{Text: "⛈", IsEmoji: true},
		{Text: "🌤", IsEmoji: true},
		{Text: "🌦", IsEmoji: true},
		{Text: "🌧", IsEmoji: true},
		{Text: "🌨", IsEmoji: true},
	},
}

// Deterministic LCG hash for dither masks (returns value in [0, 1])
func ditherHash(row, col int) float64 {
	val := (row*127 + col*313) % 1000
	return float64(val) / 1000.0
}

func getShadeChar(t float64) string {
	switch {
	case t < 0.2:
		return "█"
	case t < 0.45:
		return "▓"
	case t < 0.7:
		return "▒"
	case t < 0.9:
		return "░"
	default:
		return " "
	}
}

// Formats a line by substituting spacing with dissolving Unicode shade blocks while keeping text intact
func formatShadedLine(text string, shade string, shadeColor RGB, textColor RGB) string {
	var sb strings.Builder
	runes := []rune(text)
	for i := 0; i < len(runes); {
		r := runes[i]
		if r == ' ' {
			sb.WriteString(shadeColor.ToFG() + shade)
			i++
		} else {
			sb.WriteString(textColor.ToFG() + string(r))
			i++
		}
	}
	return sb.String()
}

// ---------------------------------------------------------------------------
// Render function representing Emojig's layout
// ---------------------------------------------------------------------------

func renderTUI(pal Palette, transp bool, animMode string, step int, maxSteps int) {
	t := float64(step) / float64(maxSteps)

	// Determine active colors for this animation step
	var currentBG, currentFG, currentSearchBG, currentSearchFG, currentSelBG, currentSelFG, currentBorderBG RGB

	if animMode == "rgb" || animMode == "shade" {
		// Fade towards the base background color
		currentBG = pal.BG
		currentFG = pal.FG.Lerp(pal.BG, t)
		currentSearchBG = pal.SearchBG.Lerp(pal.BG, t)
		currentSearchFG = pal.SearchFG.Lerp(pal.BG, t)
		currentSelBG = pal.SelBG.Lerp(pal.BG, t)
		currentSelFG = pal.SelFG.Lerp(pal.BG, t)
		currentBorderBG = pal.BorderBG.Lerp(pal.BG, t)
	} else {
		// Normal static rendering (used by dither/wipe modes internally or when idle)
		currentBG = pal.BG
		currentFG = pal.FG
		currentSearchBG = pal.SearchBG
		currentSearchFG = pal.SearchFG
		currentSelBG = pal.SelBG
		currentSelFG = pal.SelFG
		currentBorderBG = pal.BorderBG
	}

	// 12 total rows rendered at absolute screen coordinates 2 to 13
	for r := 0; r < 12; r++ {
		// Position cursor explicitly at row 2+r, column 1
		fmt.Printf("\x1b[%d;1H", 2+r)

		// Wipe checking
		if animMode == "wipe" && step > 0 {
			// Wipe outer rows inwards symmetrically
			if r < step || r >= 12-step {
				fmt.Print("\x1b[0m\x1b[K") // Reset styling and clear entire line
				continue
			}
		}

		// Apply background
		bgSeq := ""
		if !transp {
			if animMode == "rgb" || animMode == "shade" {
				bgSeq = currentBG.ToBG()
			} else {
				bgSeq = pal.BG.ToBG()
			}
		}

		// Reset terminal attributes, clear line to the right, and apply background color
		fmt.Print("\x1b[0m\x1b[K" + bgSeq)

		switch r {
		case 0: // Top Border
			if animMode == "shade" && step > 0 {
				shade := getShadeChar(t)
				fmt.Print(currentBorderBG.ToFG() + strings.Repeat(shade, 38))
			} else if animMode == "dither" && step > 0 {
				shade := getShadeChar(t)
				fmt.Print(pal.BorderBG.ToFG() + strings.Repeat(shade, 38))
			} else {
				fmt.Print(currentBorderBG.ToBG() + strings.Repeat(" ", 38))
			}

		case 1: // Top Padding
			fmt.Print(strings.Repeat(" ", 38))

		case 2: // Search Bar Row
			if animMode == "shade" && step > 0 {
				shade := getShadeChar(t)
				text := " 🔍 fire                             🌙 "
				if step >= 3 {
					// Safe text removal after a few frames to prevent fragile color interpolation bugs
					text = "                                        "
				}
				formatted := formatShadedLine(text, shade, currentSearchBG, pal.SearchFG)
				fmt.Print(formatted)
			} else if animMode == "dither" && step > 0 {
				shade := getShadeChar(t)
				fmt.Print(pal.SearchBG.ToFG() + strings.Repeat(shade, 38))
			} else if animMode == "rgb" && step == maxSteps {
				fmt.Print(strings.Repeat(" ", 38))
			} else {
				fmt.Print(currentSearchBG.ToBG() + currentSearchFG.ToFG() + " 🔍 fire                             🌙 ")
			}

		case 3: // Spacer
			fmt.Print(strings.Repeat(" ", 38))

		case 4, 5, 6, 7: // Emoji Grid Rows
			gridRow := r - 4
			fmt.Print(currentFG.ToFG() + " ")
			for col := 0; col < 6; col++ {
				cell := mockGrid[gridRow][col]
				
				// Dither check
				dithered := false
				if animMode == "dither" && step > 0 {
					if ditherHash(gridRow, col) < t {
						dithered = true
					}
				}

				if dithered {
					fmt.Print("    ")
				} else if cell.IsSelected {
					if (animMode == "dither" || animMode == "shade") && step > 0 {
						// Selected emoji remains standing intact during dissolve
						fmt.Printf(" %s ", cell.Text)
					} else if animMode == "rgb" && step > 0 {
						// For RGB fade, Emojig's actual preview leaves only the plain selected emoji, without selection highlights
						if step == maxSteps {
							fmt.Print("    ")
						} else {
							fmt.Printf(" %s ", cell.Text)
						}
					} else {
						// Normal selection highlight
						fmt.Print(currentSelBG.ToBG() + currentSelFG.ToFG() + "[" + cell.Text + "]" + bgSeq + currentFG.ToFG())
					}
				} else {
					if (animMode == "rgb" || animMode == "shade") && step > 0 {
						// Non-selected cells blanked out instantly in exit preview/shade modes
						fmt.Print("    ")
					} else {
						fmt.Printf(" %s ", cell.Text)
					}
				}
			}
			fmt.Print("             ")

		case 8: // Spacer
			fmt.Print(strings.Repeat(" ", 38))

		case 9: // Description Row
			if animMode == "rgb" && step > 0 {
				fmt.Print(strings.Repeat(" ", 38))
			} else if animMode == "shade" && step > 0 {
				if step >= 3 {
					// Safe text removal
					fmt.Print(strings.Repeat(" ", 38))
				} else {
					fmt.Print(pal.FG.ToFG() + " firefighter                            ")
				}
			} else if animMode == "dither" && step > 0 {
				// Dither character-by-character
				text := " firefighter                                "
				for col, char := range text {
					if ditherHash(r, col) < t {
						fmt.Print(" ")
					} else {
						fmt.Printf("%c", char)
					}
				}
			} else {
				fmt.Print(currentFG.ToFG() + " firefighter                            ")
			}

		case 10: // Status Bar
			if animMode == "shade" && step > 0 {
				shade := getShadeChar(t)
				text := " 24  ↑↓←→  Tab  ^C                     "
				if step >= 3 {
					// Safe text removal
					text = "                                        "
				}
				formatted := formatShadedLine(text, shade, currentSearchBG, pal.SearchFG)
				fmt.Print(formatted)
			} else if animMode == "dither" && step > 0 {
				shade := getShadeChar(t)
				fmt.Print(pal.SearchBG.ToFG() + strings.Repeat(shade, 38))
			} else if animMode == "rgb" && step == maxSteps {
				fmt.Print(strings.Repeat(" ", 38))
			} else {
				fmt.Print(currentSearchBG.ToBG() + currentSearchFG.ToFG() + " 24  ↑↓←→  Tab  ^C                     ")
			}

		case 11: // Bottom Border
			if animMode == "shade" && step > 0 {
				shade := getShadeChar(t)
				fmt.Print(currentBorderBG.ToFG() + strings.Repeat(shade, 38))
			} else if animMode == "dither" && step > 0 {
				shade := getShadeChar(t)
				fmt.Print(pal.BorderBG.ToFG() + strings.Repeat(shade, 38))
			} else {
				fmt.Print(currentBorderBG.ToBG() + strings.Repeat(" ", 38))
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Run specific animation sequence
// ---------------------------------------------------------------------------

func animateFade(pal Palette, transp bool, mode string) {
	maxSteps := 8
	delay := 40 * time.Millisecond

	if mode == "wipe" {
		maxSteps = 6
		delay = 60 * time.Millisecond
	}

	for s := 0; s <= maxSteps; s++ {
		// Only redraw the TUI portion absolutely during the fade animation
		renderTUI(pal, transp, mode, s, maxSteps)
		time.Sleep(delay)
	}

	// Brief pause on the fully cleared frame
	time.Sleep(150 * time.Millisecond)
}

// ---------------------------------------------------------------------------
// Main drawing router for absolute coordinates
// ---------------------------------------------------------------------------

func drawFullInterface(palette Palette, transp bool, isDark bool) {
	// 1. Header (Row 1)
	fmt.Print("\x1b[1;1H\x1b[36m=== Emojig Exit Fade Demonstration ===\x1b[0m\x1b[K")

	// 2. Mock TUI (Rows 2 to 13)
	renderTUI(palette, transp, "idle", 0, 8)

	// 3. Controls (Rows 15 to 22)
	fmt.Print("\x1b[15;1H\x1b[33mControls:\x1b[0m\x1b[K\r\n")
	fmt.Print("  [1] Preview Option 1: 24-bit Truecolor RGB Melt\x1b[K\r\n")
	fmt.Print("  [2] Preview Option 2: Retro Dither/Shade Dissolve (Full)\x1b[K\r\n")
	fmt.Print("  [3] Preview Option 3: Scanline Symmetric Row Wipe\x1b[K\r\n")
	fmt.Print("  [4] Preview Option 4: Shade BG Fade + Text Evacuate (Theme-Aware, Safe)\x1b[K\r\n")
	fmt.Printf("  [t] Toggle Theme   (Active: %s\x1b[0m)\x1b[K\r\n", func() string {
		if isDark {
			return "\x1b[35mDark"
		}
		return "\x1b[35mLight"
	}())
	fmt.Printf("  [h] Toggle Transp  (Active: %s\x1b[0m)\x1b[K\r\n", func() string {
		if transp {
			return "\x1b[32mON (Reveals terminal BG)"
		}
		return "\x1b[31mOFF (Draws theme solid BG)"
	}())
	fmt.Print("  [q] Quit Demo\x1b[K")

	// 4. Technical Insights (Rows 24 to 28)
	fmt.Print("\x1b[24;1H\x1b[90mTechnical Insight:\x1b[0m\x1b[K\r\n")
	if transp {
		fmt.Print("  * Option 2 dissolves text cells entirely, exposing terminal transparency.\x1b[K\r\n")
		fmt.Print("  * Option 4 fades backgrounds and borders, while text cleanly evaporates on step 3.\x1b[K\r\n")
		fmt.Print("    This avoids fragile text color calculations and guarantees 100% stable terminal fades.\x1b[K")
	} else {
		fmt.Print("  * Emojis are pre-rendered bitmap glyphs and do NOT respond to RGB foreground color fades!\x1b[K\r\n")
		fmt.Print("    Notice how the fire engine, firefighter, etc., stay full opacity during Option 1 and 4,\x1b[K\r\n")
		fmt.Print("    while Option 2 completely dissolves them via spatial masks.\x1b[K\r\n")
		fmt.Print("                                                                                \x1b[K")
	}
}

// ---------------------------------------------------------------------------
// Main Interactive Shell
// ---------------------------------------------------------------------------

func main() {
	enterRawMode()
	defer restoreTerminal()

	// Clear full viewport on launch to prevent initial overlap
	fmt.Print("\x1b[2J\x1b[1;1H")

	palette := darkPalette
	isDark := true
	transp := false

	// Capture user key presses
	buf := make([]byte, 3)

	for {
		drawFullInterface(palette, transp, isDark)

		// Park cursor at bottom control line to read cleanly
		fmt.Print("\x1b[22;16H")

		n, err := os.Stdin.Read(buf)
		if err != nil || n == 0 {
			break
		}

		char := buf[0]

		// Handle key actions
		if char == 'q' || char == 27 || char == 3 { // 'q', Esc, Ctrl-C
			break
		} else if char == 't' {
			if isDark {
				palette = lightPalette
				isDark = false
			} else {
				palette = darkPalette
				isDark = true
			}
			fmt.Print("\x1b[2J") // Clear screen on theme change
		} else if char == 'h' {
			transp = !transp
			fmt.Print("\x1b[2J") // Clear screen on transparency toggle
		} else if char == '1' {
			animateFade(palette, transp, "rgb")
			fmt.Print("\x1b[2J")
		} else if char == '2' {
			animateFade(palette, transp, "dither")
			fmt.Print("\x1b[2J")
		} else if char == '3' {
			animateFade(palette, transp, "wipe")
			fmt.Print("\x1b[2J")
		} else if char == '4' {
			animateFade(palette, transp, "shade")
			fmt.Print("\x1b[2J")
		}
	}

	// Final screen clear on exit
	fmt.Print("\x1b[2J\x1b[1;1H")
}
