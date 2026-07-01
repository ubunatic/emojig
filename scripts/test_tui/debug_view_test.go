// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testBinaryPath(t *testing.T) string {
	t.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("get working directory: %v", err)
	}
	rootDir, err := filepath.Abs(filepath.Join(cwd, "../.."))
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}
	binaryPath := filepath.Join(rootDir, "zig-out/bin/emojig")
	build := exec.Command("zig", "build", "-Doptimize=ReleaseFast", "-Dllvm=false")
	build.Dir = rootDir
	build.Stdout = os.Stderr
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		t.Fatalf("build %s: %v", binaryPath, err)
	}
	return binaryPath
}

func TestTUIDebugViewOpens(t *testing.T) {
	master, cmd, chunksChan := spawnEmojigTUI(testBinaryPath(t), 6, 4)
	defer master.Close()
	defer func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	collectScreenBytes(chunksChan, 500*time.Millisecond)
	if _, err := master.Write([]byte("/d")); err != nil {
		t.Fatalf("write debug command: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	if _, err := master.Write([]byte("\r")); err != nil {
		t.Fatalf("press enter for debug command: %v", err)
	}
	time.Sleep(300 * time.Millisecond)
	rawBytes := collectScreenBytes(chunksChan, 700*time.Millisecond)
	if len(rawBytes) == 0 {
		t.Fatal("debug view produced no bytes")
	}

	plain := stripANSI(string(rawBytes))
	for _, want := range []string{
		"emojig debug",
		"theme status",
		"settings theme:",
		"effective theme:",
		"detected terminal theme",
	} {
		if !strings.Contains(plain, want) {
			t.Fatalf("debug view missing %q\n%s", want, plain)
		}
	}
}
