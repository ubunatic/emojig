// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Converts a spec file between YAML and JSON while preserving key order.
// Usage:
//   go run ./scripts/convert_spec/ input.yaml output.json
//   go run ./scripts/convert_spec/ input.json output.yaml

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: convert_spec <input> <output>")
		os.Exit(2)
	}

	inPath := os.Args[1]
	outPath := os.Args[2]

	data, err := os.ReadFile(inPath)
	if err != nil {
		fatalf("read %s: %v", inPath, err)
	}

	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		fatalf("parse %s: %v", inPath, err)
	}
	if len(root.Content) == 0 {
		fatalf("%s: empty document", inPath)
	}
	clearFlowStyle(root.Content[0])

	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fatalf("mkdir %s: %v", filepath.Dir(outPath), err)
	}

	switch strings.ToLower(filepath.Ext(outPath)) {
	case ".json":
		var buf bytes.Buffer
		if err := writeJSON(&buf, root.Content[0], 0); err != nil {
			fatalf("encode %s: %v", outPath, err)
		}
		buf.WriteByte('\n')
		if err := os.WriteFile(outPath, buf.Bytes(), 0o644); err != nil {
			fatalf("write %s: %v", outPath, err)
		}
	case ".yaml", ".yml":
		out, err := yaml.Marshal(root.Content[0])
		if err != nil {
			fatalf("encode %s: %v", outPath, err)
		}
		var buf bytes.Buffer
		const spdx = "# " + "SPDX"
		buf.WriteString(spdx + "-FileCopyrightText: 2026 Uwe Jugel\n")
		buf.WriteString(spdx + "-License-Identifier: AGPL-3.0-or-later\n\n")
		buf.Write(out)
		if buf.Len() == 0 || buf.Bytes()[buf.Len()-1] != '\n' {
			buf.WriteByte('\n')
		}
		if err := os.WriteFile(outPath, buf.Bytes(), 0o644); err != nil {
			fatalf("write %s: %v", outPath, err)
		}
	default:
		fatalf("%s: unsupported output extension %q", outPath, filepath.Ext(outPath))
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func writeJSON(buf *bytes.Buffer, node *yaml.Node, indent int) error {
	switch node.Kind {
	case yaml.DocumentNode:
		if len(node.Content) == 0 {
			buf.WriteString("null")
			return nil
		}
		return writeJSON(buf, node.Content[0], indent)
	case yaml.MappingNode:
		if len(node.Content) == 0 {
			buf.WriteString("{}")
			return nil
		}
		buf.WriteByte('{')
		buf.WriteByte('\n')
		for i := 0; i < len(node.Content); i += 2 {
			key := node.Content[i]
			val := node.Content[i+1]
			writeIndent(buf, indent+2)
			if err := writeJSONScalarKey(buf, key); err != nil {
				return err
			}
			buf.WriteString(": ")
			if isContainer(val) {
				if err := writeJSON(buf, val, indent+2); err != nil {
					return err
				}
			} else {
				if err := writeJSON(buf, val, indent+2); err != nil {
					return err
				}
			}
			if i+2 < len(node.Content) {
				buf.WriteByte(',')
			}
			buf.WriteByte('\n')
		}
		writeIndent(buf, indent)
		buf.WriteByte('}')
		return nil
	case yaml.SequenceNode:
		if len(node.Content) == 0 {
			buf.WriteString("[]")
			return nil
		}
		buf.WriteByte('[')
		buf.WriteByte('\n')
		for i, child := range node.Content {
			writeIndent(buf, indent+2)
			if err := writeJSON(buf, child, indent+2); err != nil {
				return err
			}
			if i+1 < len(node.Content) {
				buf.WriteByte(',')
			}
			buf.WriteByte('\n')
		}
		writeIndent(buf, indent)
		buf.WriteByte(']')
		return nil
	case yaml.ScalarNode:
		return writeJSONScalar(buf, node)
	case yaml.AliasNode:
		if node.Alias == nil {
			buf.WriteString("null")
			return nil
		}
		return writeJSON(buf, node.Alias, indent)
	default:
		return fmt.Errorf("unsupported yaml node kind %d", node.Kind)
	}
}

func clearFlowStyle(node *yaml.Node) {
	if node == nil {
		return
	}
	node.Style = 0
	for i := range node.Content {
		clearFlowStyle(node.Content[i])
	}
	if node.Alias != nil {
		clearFlowStyle(node.Alias)
	}
}

func isContainer(node *yaml.Node) bool {
	return node.Kind == yaml.MappingNode || node.Kind == yaml.SequenceNode || node.Kind == yaml.DocumentNode
}

func writeJSONScalarKey(buf *bytes.Buffer, node *yaml.Node) error {
	if node.Kind != yaml.ScalarNode {
		return fmt.Errorf("mapping key must be scalar, got kind %d", node.Kind)
	}
	return writeJSONString(buf, node.Value)
}

func writeJSONScalar(buf *bytes.Buffer, node *yaml.Node) error {
	switch node.Tag {
	case "!!null":
		buf.WriteString("null")
	case "!!bool":
		switch strings.ToLower(node.Value) {
		case "true", "y", "yes", "on":
			buf.WriteString("true")
		case "false", "n", "no", "off":
			buf.WriteString("false")
		default:
			return fmt.Errorf("invalid bool scalar %q", node.Value)
		}
	case "!!int":
		buf.WriteString(node.Value)
	case "!!float":
		buf.WriteString(node.Value)
	case "!!binary":
		if err := writeJSONString(buf, node.Value); err != nil {
			return err
		}
	default:
		if node.Style == yaml.DoubleQuotedStyle || node.Style == yaml.SingleQuotedStyle {
			return writeJSONString(buf, node.Value)
		}
		if node.Tag == "!!str" || node.Tag == "" {
			return writeJSONString(buf, node.Value)
		}
		// Fall back to string encoding for any exotic tag.
		return writeJSONString(buf, node.Value)
	}
	return nil
}

func writeJSONString(buf *bytes.Buffer, s string) error {
	raw, err := json.Marshal(s)
	if err != nil {
		return err
	}
	buf.Write(raw)
	return nil
}

func writeIndent(buf *bytes.Buffer, indent int) {
	for i := 0; i < indent; i++ {
		buf.WriteByte(' ')
	}
}
