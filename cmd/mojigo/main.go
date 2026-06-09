// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Command mojigo is a TUI-only Go port of emojig. It loads the emoji database
// and declarative UI specs (spec/*.json), shows a fuzzy-search emoji picker,
// and prints the chosen emoji to stdout.
package main

import (
	"fmt"
	"os"
	"strings"

	"codeberg.org/ubunatic/emojig/internal/emoji"
	"codeberg.org/ubunatic/emojig/internal/spec"
	"codeberg.org/ubunatic/emojig/internal/tui"
)

func main() {
	height, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "mojigo:", err)
		os.Exit(2)
	}

	specs, err := spec.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mojigo: loading spec:", err)
		os.Exit(1)
	}
	db, err := emoji.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mojigo: loading emoji db:", err)
		os.Exit(1)
	}

	app := tui.New(db, specs)
	if height.Set() {
		app.SetHeight(height)
	}
	chosen, err := app.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mojigo:", err)
		os.Exit(1)
	}
	if chosen != "" {
		fmt.Println(chosen)
	}
}

// parseArgs handles the only flag mojigo accepts: --height. Forms supported,
// mirroring the Rust demo (src/main.rs): --height N, --height N%, --height=N,
// -H N. With no flag the picker runs in its default alt-screen mode.
func parseArgs(args []string) (tui.Height, error) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--height" || a == "-H":
			i++
			if i >= len(args) {
				return tui.Height{}, fmt.Errorf("%s requires a value (e.g. 8 or 40%%)", a)
			}
			return tui.ParseHeight(args[i])
		case strings.HasPrefix(a, "--height="):
			return tui.ParseHeight(strings.TrimPrefix(a, "--height="))
		case a == "-h" || a == "--help":
			fmt.Println("usage: mojigo [--height N|N%]")
			os.Exit(0)
		default:
			return tui.Height{}, fmt.Errorf("unknown argument: %q", a)
		}
	}
	return tui.Height{}, nil
}
