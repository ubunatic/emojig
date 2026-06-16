// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package emojig embeds the canonical data and declarative spec files so the
// mojigo binary is self-contained while keeping data/ and spec/ as the single
// source of truth shared with the Zig implementation.
package emojig

import _ "embed"

// EmojiJSON is the canonical Unicode emoji database (data/emoji.json).
//
//go:embed data/emoji.json
var EmojiJSON []byte

// LayoutJSON is the declarative layout spec (spec/layout.json).
//
//go:embed spec/layout.json
var LayoutJSON []byte

// ThemeJSON is the declarative theme/palette spec (spec/theme.json).
//
//go:embed spec/theme.json
var ThemeJSON []byte

// KeysJSON is the declarative key-binding spec (spec/keys.json).
//
//go:embed spec/keys.json
var KeysJSON []byte

// StringsJSON is the declarative UI text spec (spec/strings.json).
//
//go:embed spec/strings.json
var StringsJSON []byte

// SynonymsJSON is the declarative synonym map (spec/synonyms.json).
//
//go:embed spec/synonyms.json
var SynonymsJSON []byte

// BoxartJSON is the box-drawing / block-element character set (spec/boxart.json).
//
//go:embed spec/boxart.json
var BoxartJSON []byte

// BrailleJSON is the Unicode Braille Patterns block (spec/braille.json).
//
//go:embed spec/braille.json
var BrailleJSON []byte

// ShellSh is the generic shell integration dispatcher (zsh + bash).
//
//go:embed src/shell/emojig.sh
var ShellSh []byte

// ShellZsh is the zsh shell integration script.
//
//go:embed src/shell/emojig.zsh
var ShellZsh []byte

// ShellBash is the bash shell integration script.
//
//go:embed src/shell/emojig.bash
var ShellBash []byte

// ShellFish is the fish shell integration script.
//
//go:embed src/shell/emojig.fish
var ShellFish []byte
