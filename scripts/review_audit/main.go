// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type finding struct {
	name    string
	hit     bool
	details []string
}

func main() {
	check := "all"
	if len(os.Args) > 1 {
		check = os.Args[1]
	}

	root, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to get cwd: %v\n", err)
		os.Exit(2)
	}

	var findings []finding
	switch check {
	case "all":
		findings = []finding{
			reproduceXfceHostDetect(root),
			reproduceInstallIntegrityGap(root),
			reproducePersistenceBufferEdges(root),
		}
	case "xfce-host-detect":
		findings = []finding{reproduceXfceHostDetect(root)}
	case "install-update-integrity":
		findings = []finding{reproduceInstallIntegrityGap(root)}
	case "persistence-buffer-edges":
		findings = []finding{reproducePersistenceBufferEdges(root)}
	default:
		fmt.Fprintf(os.Stderr, "unknown check %q\n", check)
		fmt.Fprintf(os.Stderr, "valid checks: all, xfce-host-detect, install-update-integrity, persistence-buffer-edges\n")
		os.Exit(2)
	}

	hits := 0
	for _, f := range findings {
		if f.hit {
			hits++
			fmt.Printf("FAIL %s\n", f.name)
			for _, d := range f.details {
				fmt.Printf("  %s\n", d)
			}
		} else {
			fmt.Printf("PASS %s\n", f.name)
		}
	}

	if hits > 0 {
		os.Exit(1)
	}
}

func reproduceXfceHostDetect(root string) finding {
	hostPath := filepath.Join(root, "src", "host.zig")
	issue02Path := filepath.Join(root, "issues", "02-distribution-and-release.md")

	hostText := mustRead(hostPath)
	issue02Text := mustRead(issue02Path)

	hasKind := strings.Contains(hostText, `if (std.mem.eql(u8, name, "xfce4-terminal")) return .xfce4_terminal;`)
	hasArgvCase := strings.Contains(hostText, `.xfce4_terminal => {`)
	autoDetectMissing := !strings.Contains(hostText, `"xfce4-terminal",`)
	backlogClaimsSupport := strings.Contains(issue02Text, "xfce4-terminal")

	return finding{
		name: "xfce-host-detect",
		hit:  hasKind && hasArgvCase && autoDetectMissing && backlogClaimsSupport,
		details: []string{
			excerpt(hostPath, `if (std.mem.eql(u8, name, "xfce4-terminal")) return .xfce4_terminal;`),
			excerpt(hostPath, `.xfce4_terminal => {`),
			"src/host.zig candidate list omits \"xfce4-terminal\" even though the host kind and argv builder support it.",
			excerpt(issue02Path, "xfce4-terminal"),
		},
	}
}

func reproduceInstallIntegrityGap(root string) finding {
	installPath := filepath.Join(root, "scripts", "install.sh")
	integrationPath := filepath.Join(root, "src", "integration.zig")
	issue02Path := filepath.Join(root, "issues", "02-distribution-and-release.md")

	installText := strings.ToLower(mustRead(installPath))
	integrationText := mustRead(integrationPath)
	issue02Text := mustRead(issue02Path)

	promisesVerify := strings.Contains(issue02Text, "verify hash")
	lacksHashes := !strings.Contains(installText, "sha256sums") && !strings.Contains(installText, "sha256sum")
	lacksMinisign := !strings.Contains(installText, "minisign")
	updateFallsBackToCurlPipe := strings.Contains(integrationText, `cmd = "curl -sSf https://ubunatic.com/emojig/install.sh | sh";`)

	return finding{
		name: "install-update-integrity",
		hit:  promisesVerify && lacksHashes && lacksMinisign && updateFallsBackToCurlPipe,
		details: []string{
			excerpt(issue02Path, "verify hash"),
			excerpt(installPath, "Download & Verify Release Archive"),
			"scripts/install.sh contains no SHA256SUMS, sha256sum, or minisign verification logic before extraction.",
			excerpt(integrationPath, `cmd = "curl -sSf https://ubunatic.com/emojig/install.sh | sh";`),
		},
	}
}

func reproducePersistenceBufferEdges(root string) finding {
	configPath := filepath.Join(root, "src", "config.zig")
	mruPath := filepath.Join(root, "src", "mru.zig")
	closed01Path := filepath.Join(root, "issues", "closed", "01-config-file-silent-truncation.md")

	configText := mustRead(configPath)
	mruText := mustRead(mruPath)
	closed01Text := mustRead(closed01Path)

	configBailsOnFullPage := strings.Contains(configText, `if (len == file_buf.len) return cfg;`)
	mruUsesSameBuffer := strings.Contains(mruText, `var file_buf: [4096]u8 = undefined;`)
	mruHasNoGuard := !strings.Contains(mruText, "len == file_buf.len")
	closedIssueClaimsFixed := strings.Contains(closed01Text, "fixed-size buffer limitation")

	return finding{
		name: "persistence-buffer-edges",
		hit:  configBailsOnFullPage && mruUsesSameBuffer && mruHasNoGuard && closedIssueClaimsFixed,
		details: []string{
			excerpt(configPath, `if (len == file_buf.len) return cfg;`),
			excerpt(mruPath, `var file_buf: [4096]u8 = undefined;`),
			excerpt(mruPath, `const len = std.posix.read(fd, &file_buf) catch return;`),
			excerpt(closed01Path, "fixed-size buffer limitation"),
		},
	}
}

func mustRead(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read %s: %v\n", path, err)
		os.Exit(2)
	}
	return string(data)
}

func excerpt(path string, needle string) string {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Sprintf("%s: %v", path, err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		if strings.Contains(line, needle) {
			return fmt.Sprintf("%s:%d: %s", rel(path), lineNo, strings.TrimSpace(line))
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Sprintf("%s: scan error: %v", rel(path), err)
	}
	return fmt.Sprintf("%s: needle not found: %s", rel(path), needle)
}

func rel(path string) string {
	wd, err := os.Getwd()
	if err != nil {
		return path
	}
	if relPath, err := filepath.Rel(wd, path); err == nil {
		return relPath
	}
	return path
}
