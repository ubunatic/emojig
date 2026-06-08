// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Command mojigo is a TUI-only Go port of emojig. It loads the emoji database
// and declarative UI specs (spec/*.json), shows a fuzzy-search emoji picker,
// and prints the chosen emoji to stdout.
package main

import (
	"fmt"
	"os"

	"codeberg.org/ubunatic/emojig/internal/emoji"
	"codeberg.org/ubunatic/emojig/internal/spec"
	"codeberg.org/ubunatic/emojig/internal/tui"
)

func main() {
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
	chosen, err := app.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mojigo:", err)
		os.Exit(1)
	}
	if chosen != "" {
		fmt.Println(chosen)
	}
}
