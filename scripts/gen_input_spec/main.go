// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Parses spec/input.yaml with yaml.v3 and writes a normalized JSON copy to
// spec/input.generated.json. The generated JSON is embedded by Zig so the
// runtime stays allocation-free.
//
// Run: go run ./scripts/gen_input_spec/
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

type inputFile struct {
	Schema string `json:"$schema"`
	Input  Input  `json:"input"`
}

type Input struct {
	KeyAliases       map[string]string `yaml:"key_aliases" json:"key_aliases"`
	CtrlPattern      CtrlPattern       `yaml:"ctrl_pattern" json:"ctrl_pattern"`
	Signals          []Signal          `yaml:"signals" json:"signals"`
	TerminalSequence []TerminalSeq     `yaml:"terminal_sequences" json:"terminal_sequences"`
	Mouse            Mouse             `yaml:"mouse" json:"mouse"`
	Tokenizer        Tokenizer         `yaml:"tokenizer" json:"tokenizer"`
}

type CtrlPattern struct {
	Prefix   string `yaml:"prefix" json:"prefix"`
	BaseChar string `yaml:"base_char" json:"base_char"`
	BaseCode int    `yaml:"base_code" json:"base_code"`
}

type Signal struct {
	Name   string `yaml:"name" json:"name"`
	Number int    `yaml:"number" json:"number"`
	Event  string `yaml:"event" json:"event"`
}

type TerminalSeq struct {
	Seq   string `yaml:"seq" json:"seq"`
	Event string `yaml:"event" json:"event"`
}

type Mouse struct {
	Prefix        string `yaml:"prefix" json:"prefix"`
	PressSuffix   string `yaml:"press_suffix" json:"press_suffix"`
	ReleaseSuffix string `yaml:"release_suffix" json:"release_suffix"`
	EnableButton  string `yaml:"enable_button" json:"enable_button"`
	EnableMotion  string `yaml:"enable_motion" json:"enable_motion"`
	DisableButton string `yaml:"disable_button" json:"disable_button"`
	DisableMotion string `yaml:"disable_motion" json:"disable_motion"`
	BtnButtonMask int    `yaml:"btn_button_mask" json:"btn_button_mask"`
	BtnShiftMask  int    `yaml:"btn_shift_mask" json:"btn_shift_mask"`
	BtnMetaMask   int    `yaml:"btn_meta_mask" json:"btn_meta_mask"`
	BtnCtrlMask   int    `yaml:"btn_ctrl_mask" json:"btn_ctrl_mask"`
	BtnMotionFlag int    `yaml:"btn_motion_flag" json:"btn_motion_flag"`
	BtnScrollFlag int    `yaml:"btn_scroll_flag" json:"btn_scroll_flag"`
	BtnNoButton   int    `yaml:"btn_no_button" json:"btn_no_button"`
}

type Tokenizer struct {
	Rules []TokenizerRule `yaml:"rules" json:"rules"`
}

type TokenizerRule struct {
	Name      string `yaml:"name" json:"name"`
	Match     string `yaml:"match" json:"match"`
	Prefix    string `yaml:"prefix,omitempty" json:"prefix,omitempty"`
	ScanUntil string `yaml:"scan_until,omitempty" json:"scan_until,omitempty"`
	ScanClass string `yaml:"scan_class,omitempty" json:"scan_class,omitempty"`
	Emit      string `yaml:"emit" json:"emit"`
}

func main() {
	inPath := filepath.Clean("spec/input.yaml")
	outPath := filepath.Clean("spec/input.generated.json")

	data, err := os.ReadFile(inPath)
	if err != nil {
		fatalf("read %s: %v", inPath, err)
	}

	var yamlRoot struct {
		Schema string `yaml:"$schema"`
		Input  Input  `yaml:"input"`
	}
	if err := yaml.Unmarshal(data, &yamlRoot); err != nil {
		fatalf("parse %s: %v", inPath, err)
	}
	if yamlRoot.Input.KeyAliases == nil {
		fatalf("%s: missing input.key_aliases", inPath)
	}
	if len(yamlRoot.Input.Tokenizer.Rules) == 0 {
		fatalf("%s: missing input.tokenizer.rules", inPath)
	}

	out := inputFile{
		Schema: yamlRoot.Schema,
		Input:  yamlRoot.Input,
	}
	jsonData, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		fatalf("marshal %s: %v", outPath, err)
	}
	jsonData = append(jsonData, '\n')
	if err := os.WriteFile(outPath, jsonData, 0o644); err != nil {
		fatalf("write %s: %v", outPath, err)
	}
	fmt.Printf("wrote %s\n", outPath)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}
