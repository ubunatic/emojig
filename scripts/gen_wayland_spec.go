// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"encoding/xml"
	"fmt"
	"os"
)

type Protocol struct {
	Name       string      `xml:"name,attr"`
	Interfaces []Interface `xml:"interface"`
}

type Interface struct {
	Name     string    `xml:"name,attr"`
	Version  int       `xml:"version,attr"`
	Requests []Message `xml:"request"`
	Events   []Message `xml:"event"`
}

type Message struct {
	Name string `xml:"name,attr"`
	Type string `xml:"type,attr"`
}

func main() {
	files := []string{
		"/usr/share/qt6/wayland/protocols/wayland/wayland.xml",
		"/usr/share/qt6/wayland/protocols/xdg-shell/xdg-shell.xml",
	}

	for _, path := range files {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var p Protocol
		if err := xml.Unmarshal(data, &p); err == nil {
			fmt.Printf("// Generated from %s (%s)\n", path, p.Name)
		}
	}
}
