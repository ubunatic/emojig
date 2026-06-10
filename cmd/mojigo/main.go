// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Command mojigo is a TUI-only Go port of emojig. It loads the emoji database
// and declarative UI specs (spec/*.json), shows a fuzzy-search emoji picker,
// and prints the chosen emoji to stdout.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	emojig "codeberg.org/ubunatic/emojig"
	"codeberg.org/ubunatic/emojig/internal/emoji"
	"codeberg.org/ubunatic/emojig/internal/spec"
	"codeberg.org/ubunatic/emojig/internal/tui"
)

func main() {
	opts, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "mojigo:", err)
		os.Exit(2)
	}

	if opts.completion {
		shell := opts.completionShell
		if shell == "" {
			shell = detectShell()
		}
		printCompletion(shell, opts.key)
		os.Exit(0)
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
	if opts.height.Set() {
		app.SetHeight(opts.height)
	}
	if opts.simple {
		app.SetSimple(true)
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

type options struct {
	height          tui.Height
	simple          bool
	completion      bool
	completionShell string
	key             string
}

// parseArgs handles mojigo's flags.
func parseArgs(args []string) (options, error) {
	var opts options
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--height" || a == "-H":
			i++
			if i >= len(args) {
				return opts, fmt.Errorf("%s requires a value (e.g. 8 or 40%%)", a)
			}
			h, err := tui.ParseHeight(args[i])
			if err != nil {
				return opts, err
			}
			opts.height = h
		case strings.HasPrefix(a, "--height="):
			h, err := tui.ParseHeight(strings.TrimPrefix(a, "--height="))
			if err != nil {
				return opts, err
			}
			opts.height = h
		case a == "--simple":
			opts.simple = true
		case a == "--completion":
			opts.completion = true
		case strings.HasPrefix(a, "--completion="):
			v := strings.TrimPrefix(a, "--completion=")
			if v != "sh" && v != "zsh" && v != "bash" && v != "fish" {
				return opts, fmt.Errorf("--completion= accepts sh, zsh, bash, or fish")
			}
			opts.completion = true
			opts.completionShell = v
		case a == "--key":
			i++
			if i >= len(args) {
				return opts, fmt.Errorf("--key requires a value (e.g. '^E')")
			}
			opts.key = args[i]
		case strings.HasPrefix(a, "--key="):
			opts.key = strings.TrimPrefix(a, "--key=")
		case a == "-h" || a == "--help":
			fmt.Println("usage: mojigo [--height N|N%] [--simple] [--completion[=sh|zsh|bash|fish]] [--key KEY]")
			os.Exit(0)
		default:
			return opts, fmt.Errorf("unknown argument: %q", a)
		}
	}
	return opts, nil
}

func detectShell() string {
	s := os.Getenv("SHELL")
	base := filepath.Base(s)
	switch base {
	case "bash":
		return "bash"
	case "fish":
		return "fish"
	default:
		return "zsh"
	}
}

func printCompletion(shell, key string) {
	if key != "" {
		fmt.Printf("EMOJIG_KEY='%s'\n", key)
	}
	var script []byte
	switch shell {
	case "bash":
		script = emojig.ShellBash
	case "fish":
		script = emojig.ShellFish
	case "sh":
		script = emojig.ShellSh
	default:
		script = emojig.ShellZsh
	}
	os.Stdout.Write(script)
}
