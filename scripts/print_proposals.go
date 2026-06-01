// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// print_proposals.go — A small utility to print and demonstrate the Emojig TUI proposals.
// This allows visual review of the layout stability and appeal in different terminal environments.
//
// Run: go run scripts/print_proposals.go
package main

import (
	"fmt"
)

// ANSI Color Sequences
const (
	reset = "\x1b[0m"
	bold  = "\x1b[1m"
	dim   = "\x1b[2m"

	// Dark Theme (bg=234, fg=248, selection=24, search=238, border=236)
	darkGridBg      = "\x1b[48;5;234m"
	darkGridFg      = "\x1b[38;5;248m"
	darkSearchBg    = "\x1b[48;5;238m"
	darkSearchFg    = "\x1b[38;5;255m"
	darkSelectionBg = "\x1b[48;5;24m"
	darkSelectionFg = "\x1b[38;5;255m"
	darkBorderBg    = "\x1b[48;5;236m"

	// Light Theme (bg=255, fg=238, selection=111, search=251, border=252)
	lightGridBg      = "\x1b[48;5;255m"
	lightGridFg      = "\x1b[38;5;238m"
	lightSearchBg    = "\x1b[48;5;251m"
	lightSearchFg    = "\x1b[38;5;232m"
	lightSelectionBg = "\x1b[48;5;111m"
	lightSelectionFg = "\x1b[38;5;232m"
	lightBorderBg    = "\x1b[48;5;252m"

	// ANSI Line Clear and Erase to end of line
	eraseToLineEnd = "\x1b[K"
)

func main() {
	fmt.Println(bold + "Emojig TUI Render Proposals" + reset)
	fmt.Println("This script demonstrates the visual designs directly in your terminal.")
	fmt.Println("Review how each style handles alignment, colors, and layout margins without box-drawing characters.\n")

	fmt.Println(bold + "=== 1. THE ASYMMETRIC SANDWICH ===" + reset)
	fmt.Println("Uses full-width color bands at top and bottom to frame the view. Grid sides are completely open.")
	fmt.Println(dim + "Stability: 100% stable. No right-side borders or elements can be pushed by emoji width anomalies." + reset)
	fmt.Println("\n" + bold + "--- Dark Theme Variant ---" + reset)
	renderSandwich(darkSearchBg, darkSearchFg, darkSelectionBg, darkSelectionFg)
	fmt.Println("\n" + bold + "--- Light Theme Variant ---" + reset)
	renderSandwich(lightSearchBg, lightSearchFg, lightSelectionBg, lightSelectionFg)
	fmt.Println("\n")

	fmt.Println(bold + "=== 2. THE TERMINAL-EDGE BLOCK ===" + reset)
	fmt.Println("Every row of the TUI is painted with a solid background color up to the physical right edge of the terminal.")
	fmt.Println(dim + "Stability: 100% stable. The right edge is aligned perfectly to the terminal window via \\x1b[K." + reset)
	fmt.Println("\n" + bold + "--- Dark Theme Variant ---" + reset)
	renderBlock(darkGridBg, darkGridFg, darkSearchBg, darkSearchFg, darkSelectionBg, darkSelectionFg)
	fmt.Println("\n" + bold + "--- Light Theme Variant ---" + reset)
	renderBlock(lightGridBg, lightGridFg, lightSearchBg, lightSearchFg, lightSelectionBg, lightSelectionFg)
	fmt.Println("\n")

	fmt.Println(bold + "=== 3. THE ISOLATED CLI ===" + reset)
	fmt.Println("Minimalist developer design. No horizontal background blocks. Complete decoupling of columns and rows.")
	fmt.Println(dim + "Stability: 100% stable. Integrates cleanly into standard shell scrollback." + reset)
	fmt.Println("\n" + bold + "--- Dark Theme Variant ---" + reset)
	renderIsolated(darkSelectionBg, darkSelectionFg)
	fmt.Println("\n" + bold + "--- Light Theme Variant ---" + reset)
	renderIsolated(lightSelectionBg, lightSelectionFg)
	fmt.Println("\n")

	fmt.Println(bold + "Summary & Technical Analysis:" + reset)
	fmt.Println("1. " + bold + "\\x1b[K (Erase to Line End)" + reset + " is the key: it paints the active background color all the way to the right margin.")
	fmt.Println("2. By eliminating all box-drawing border characters (e.g., │, ┌, ─), we remove spatial coupling.")
	fmt.Println("3. Even if an emoji renders as 1.5ch, the layout remains unbroken. Only the internal grid cell spacing shifts slightly, which is visually imperceptible.")
}

func renderSandwich(searchBg, searchFg, selectionBg, selectionFg string) {
	// Search row (full width bg)
	fmt.Printf("%s%s 🔍 fire █%s%s\n", searchBg, searchFg, eraseToLineEnd, reset)
	// Spacer
	fmt.Println()
	// Grid rows
	fmt.Printf("  🚒   %s%s 🔥 %s  🎆   🧨   🧯   🇮🇪\n", selectionBg, selectionFg, reset)
	fmt.Println("  ⚙️   ⛸️   😝   🎭   😚   😍")
	fmt.Println("  😗   🏎️   😃   😀   😄   😁")
	fmt.Println("  😆   😅   🤣   😂   🙂   🙃")
	// Spacer
	fmt.Println()
	// Description
	fmt.Println(" fire")
	// Status row (full width bg)
	fmt.Printf("%s%s 45 Matches        ↑↓←→ Navigate        Tab: Theme        ^C Cancel%s%s\n", searchBg, searchFg, eraseToLineEnd, reset)
}

func renderBlock(gridBg, gridFg, searchBg, searchFg, selectionBg, selectionFg string) {
	// Search row (full width bg)
	fmt.Printf("%s%s 🔍 fire █%s%s\n", searchBg, searchFg, eraseToLineEnd, reset)
	// Spacer row
	fmt.Printf("%s%s\n", gridBg, eraseToLineEnd+reset)
	// Grid rows (full width bg)
	fmt.Printf("%s%s  🚒   %s%s 🔥 %s%s%s  🎆   🧨   🧯   🇮🇪%s%s\n", gridBg, gridFg, selectionBg, selectionFg, reset, gridBg, gridFg, eraseToLineEnd, reset)
	fmt.Printf("%s%s  ⚙️   ⛸️   😝   🎭   😚   😍%s%s\n", gridBg, gridFg, eraseToLineEnd, reset)
	fmt.Printf("%s%s  😗   🏎️   😃   😀   😄   😁%s%s\n", gridBg, gridFg, eraseToLineEnd, reset)
	fmt.Printf("%s%s  😆   😅   🤣   😂   🙂   🙃%s%s\n", gridBg, gridFg, eraseToLineEnd, reset)
	// Spacer row
	fmt.Printf("%s%s\n", gridBg, eraseToLineEnd+reset)
	// Description row (full width bg)
	fmt.Printf("%s%s fire%s%s\n", gridBg, gridFg, eraseToLineEnd, reset)
	// Status row (full width bg)
	fmt.Printf("%s%s 45 Matches        ↑↓←→ Navigate        Tab: Theme        ^C Cancel%s%s\n", searchBg, searchFg, eraseToLineEnd, reset)
}

func renderIsolated(selectionBg, selectionFg string) {
	// Search row
	fmt.Println(" 🔍 fire")
	// Spacer
	fmt.Println()
	// Grid rows
	fmt.Printf("  🚒   %s%s[🔥]%s  🎆   🧨   🧯   🇮🇪\n", selectionBg, selectionFg, reset)
	fmt.Println("  ⚙️   ⛸️   😝   🎭   😚   😍")
	fmt.Println("  😗   🏎️   😃   😀   😄   😁")
	fmt.Println("  😆   😅   🤣   😂   🙂   🙃")
	// Spacer
	fmt.Println()
	// Description
	fmt.Println(" fire")
	// Status/footer row (dim text)
	fmt.Println(dim + " 45 matches  •  ↑↓←→ navigate  •  Tab: theme  •  ^C cancel" + reset)
}
