// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Rewrites spec/strings.json with the correct content including ESC sequences.
// Run once with: go run scripts/write_strings_json.go
package main

import (
	"fmt"
	"os"
	"strings"
)

func main() {
	esc := "\x1b"
	link := func(url, text string) string {
		return esc + "]8;;" + url + esc + "\\" + text + esc + "]8;;" + esc + "\\"
	}
	logo := "😀 " + link("https://ubunatic.com/emojig", "ubunatic.com/emojig")

	lines := map[string][]string{
		"help_lines": {
			logo,
			"",
			" ⌨️|abc|↕↔ Search, Navigate",
			" 🖱️|↵|Esc  Select, Exit",
			" ⭾ (Tab)   Theme 🗘 (🌞|🌙|🔆)",
			" ??        More…",
		},
		"about_lines": {
			logo,
			"",
			" Emojig $version — lightning-fast,",
			" zero-allocation emoji picker in Zig.",
			"",
			" Made with 💙+🤖 in Dresden, DE",
		},
		"status_lines": {
			"ℹ️  emojig $version",
			"",
			" theme:       $theme",
			" shell:       $shell",
			" key binding: $shell_key_binding",
			" integration: $shell_integration",
			" categories:  $show_all_categories",
			" ambiguous:   $ambiguous_chars",
			" update cmd:  $update_cmd",
			"",
			" $emojis emojis indexed",
		},
		"help_lines_more": {
			logo,
			"",
			" e:abc 🔍 Emojis only",
			" t:abc 🔍 Symbols only",
			" b:abc 🔍 Box art only",
			" a b 🔍   Match all words",
			" ⌫        Back…",
		},
		"focus_lost_startup_lines": {
			"🛡️ OS prevented focus change.",
			"   Click or switch window",
			"   to change focus!",
			"",
			"💡 GTK apps have native picker.",
			"   Try Ctrl + '.' to open.",
		},
		"focus_lost_runtime_lines": {
			"🕵️ Picker unfocused.",
			"   Click or switch window",
			"   to focus!",
		},
	}

	jsonLines := func(key string) string {
		var sb strings.Builder
		sb.WriteString(fmt.Sprintf("  %q: [\n", key))
		for i, l := range lines[key] {
			comma := ","
			if i == len(lines[key])-1 {
				comma = ""
			}
			sb.WriteString(fmt.Sprintf("    %s%s\n", jsonStr(l), comma))
		}
		sb.WriteString("  ]")
		return sb.String()
	}

	desc := "Language-neutral UI text strings for the picker. Edit these to change the search prompt, status bar, and help screen without touching code. {count} is substituted with the live match count. Keep lines within the rendered content width (spec/layout.json) or they are truncated. Consumed by both the Zig app and the Go mojigo port. help_lines is the default help page (query starts with '?'); help_lines_more is the second page shown when the query starts with '??' and documents the e:/t: width filters."

	content := fmt.Sprintf(`{
  "description": %s,
  "search_prompt": " 🔍 ",
  "search_placeholder": "search…",
  "status_help_hint": " ?:help  ↕↔|↵|Esc",
  "status_matches": " {count}  ↕↔|↵|Esc",
  "status_help_hint_wide": " ?:help e:img t:txt  ↕↔|↵|Esc",
  "status_matches_wide": " {count} e:img t:txt  ↕↔|↵|Esc",
%s,
%s,
%s,
%s,
%s,
%s
}
`,
		jsonStr(desc),
		jsonLines("help_lines"),
		jsonLines("about_lines"),
		jsonLines("status_lines"),
		jsonLines("help_lines_more"),
		jsonLines("focus_lost_startup_lines"),
		jsonLines("focus_lost_runtime_lines"),
	)

	if err := os.WriteFile("spec/strings.json", []byte(content), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("wrote spec/strings.json")
}

func jsonStr(s string) string {
	var sb strings.Builder
	sb.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString(`\"`)
		case '\\':
			sb.WriteString(`\\`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		default:
			if r < 0x20 {
				sb.WriteString(fmt.Sprintf(`\u%04x`, r))
			} else {
				sb.WriteRune(r)
			}
		}
	}
	sb.WriteByte('"')
	return sb.String()
}
