// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// tty_bench.go — measure RSS of terminal emulators + their emojig children.
// Anchors on running emojig processes and walks up the ppid chain to find the
// owning terminal, so only windows launched by ttylaunch are counted.
// Usage: go run scripts/tty_bench.go
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

var terminals = map[string]bool{
	"kitty":                 true,
	"ghostty":               true,
	"alacritty":             true,
	"gnome-terminal-server": true,
	"ptyxis":                true,
	"foot":                  true,
	"xfce4-terminal":        true,
	"tilix":                 true,
}

func readProcField(pid int, file, field string) string {
	f, err := os.Open(fmt.Sprintf("/proc/%d/%s", pid, file))
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, field+":") {
			return strings.TrimSpace(strings.TrimPrefix(line, field+":"))
		}
	}
	return ""
}

func comm(pid int) string {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func ppid(pid int) int {
	v, _ := strconv.Atoi(readProcField(pid, "status", "PPid"))
	return v
}

func rssKB(pid int) int {
	fields := strings.Fields(readProcField(pid, "status", "VmRSS"))
	if len(fields) == 0 {
		return 0
	}
	v, _ := strconv.Atoi(fields[0])
	return v
}

// findTerminalAncestor walks up the ppid chain and returns the PID and name of
// the first ancestor whose comm matches a known terminal emulator.
func findTerminalAncestor(pid int) (int, string, bool) {
	for range 20 {
		pid = ppid(pid)
		if pid <= 1 {
			break
		}
		name := comm(pid)
		if terminals[name] {
			return pid, name, true
		}
	}
	return 0, "", false
}

// emojigPIDs returns all PIDs whose comm is "emojig".
func emojigPIDs() []int {
	entries, err := filepath.Glob("/proc/[0-9]*/comm")
	if err != nil {
		return nil
	}
	var pids []int
	for _, entry := range entries {
		data, err := os.ReadFile(entry)
		if err != nil || strings.TrimSpace(string(data)) != "emojig" {
			continue
		}
		pidStr := strings.Split(entry, "/")[2]
		pid, err := strconv.Atoi(pidStr)
		if err == nil {
			pids = append(pids, pid)
		}
	}
	return pids
}

func main() {
	epids := emojigPIDs()
	if len(epids) == 0 {
		fmt.Println("No emojig processes found. Launch with: make ttylaunch")
		return
	}

	fmt.Printf("%-26s %12s %12s %12s\n", "TERMINAL", "TERM kB", "EMOJIG kB", "TOTAL kB")
	fmt.Printf("%-26s %12s %12s %12s\n",
		"--------------------------", "------------", "------------", "------------")

	found := false
	for _, epid := range epids {
		tpid, tname, ok := findTerminalAncestor(epid)
		if !ok {
			continue
		}
		termRSS := rssKB(tpid)
		emoRSS := rssKB(epid)
		fmt.Printf("%-26s %12d %12d %12d\n", tname, termRSS, emoRSS, termRSS+emoRSS)
		found = true
	}

	if !found {
		fmt.Println("No known terminal found as ancestor of any emojig process.")
	}
}
