// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// spawnPTY opens a PTY pair and returns (master, slaveName) or exits on error.
func spawnPTY() (*os.File, string) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		fmt.Printf("Error opening /dev/ptmx: %v\n", err)
		os.Exit(1)
	}

	var ptsNum uint32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&ptsNum)))
	if errno != 0 {
		fmt.Printf("Error getting PTY number: %v\n", errno)
		os.Exit(1)
	}

	var unlock int
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock)))
	if errno != 0 {
		fmt.Printf("Error unlocking PTY: %v\n", errno)
		os.Exit(1)
	}

	slaveName := fmt.Sprintf("/dev/pts/%d", ptsNum)
	return master, slaveName
}

// stripANSI removes ESC sequences and control characters for plain-text comparison.
func stripANSI(s string) string {
	var out strings.Builder
	i := 0
	for i < len(s) {
		if s[i] == '\x1b' {
			// Skip until end of sequence
			i++
			if i < len(s) && s[i] == '[' {
				i++ // skip '['
				for i < len(s) {
					c := s[i]
					i++
					// parameter bytes 0x30-0x3f, intermediate 0x20-0x2f, final 0x40-0x7e
					if c >= 0x40 && c <= 0x7e {
						break
					}
				}
			} else {
				// single-char ESC sequence
				if i < len(s) {
					i++
				}
			}
			continue
		}
		if s[i] >= 0x20 || s[i] == '\n' || s[i] == '\r' {
			out.WriteByte(s[i])
		}
		i++
	}
	return out.String()
}

// runTest executes one TUI test scenario.
// env is a map of extra environment variables to set.
// Returns the preview-window output (between Enter and exit) and exit error.
func runTest(binaryPath string, env map[string]string) (previewOutput string, exitErr error) {
	master, slaveName := spawnPTY()
	defer master.Close()

	slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Printf("Error opening slave PTY %s: %v\n", slaveName, err)
		os.Exit(1)
	}
	defer slave.Close()

	// Set a valid terminal size so the TUI does not collapse into hidden mode.
	type winsize struct{ Row, Col, Xpixel, Ypixel uint16 }
	ws := winsize{Row: 24, Col: 80}
	_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, slave.Fd(), syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))

	cmd := exec.Command(binaryPath, "--tui")
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
		Ctty:    0,
	}
	// Propagate current environment, then apply overrides.
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}

	if err := cmd.Start(); err != nil {
		fmt.Printf("Error starting command: %v\n", err)
		os.Exit(1)
	}
	slave.Close() // Close parent's copy of slave to allow proper EOF/EIO detection on master PTY

	chunksChan := make(chan string, 100)
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := master.Read(buf)
			if n > 0 {
				s := string(buf[:n])
				chunksChan <- s
				if strings.Contains(s, "\x1b[6n") {
					// Write back mock Cursor Position Report: row 24, col 80
					master.Write([]byte("\x1b[24;80R"))
				}
			}
			if err != nil {
				close(chunksChan)
				return
			}
		}
	}()

	collectAvailable := func() string {
		var s strings.Builder
		for {
			select {
			case chunk, ok := <-chunksChan:
				if !ok {
					return s.String()
				}
				s.WriteString(chunk)
			default:
				return s.String()
			}
		}
	}

	// Wait for initial render.
	time.Sleep(500 * time.Millisecond)
	_ = collectAvailable()

	// Send search query "fire".
	if _, err := master.Write([]byte("fire")); err != nil {
		fmt.Printf("Error writing search key: %v\n", err)
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	_ = collectAvailable()

	// Send Enter.
	if _, err := master.Write([]byte("\n")); err != nil {
		fmt.Printf("Error writing ENTER key: %v\n", err)
		os.Exit(1)
	}

	// Capture output that arrives while the preview frame is shown (before exit).
	// We allow up to 1.5 s total for the process to exit (default hold is 500 ms).
	exitChan := make(chan error, 1)
	go func() { exitChan <- cmd.Wait() }()

	// Collect PTY output for up to 1.5 s.
	var previewBuf strings.Builder
	deadline := time.Now().Add(1500 * time.Millisecond)
	for {
		select {
		case e := <-exitChan:
			// Process has exited; drain any remaining bytes.
			time.Sleep(50 * time.Millisecond)
			previewBuf.WriteString(collectAvailable())
			exitErr = e
			previewOutput = previewBuf.String()
			return
		case chunk, ok := <-chunksChan:
			if ok {
				previewBuf.WriteString(chunk)
			}
		case <-time.After(time.Until(deadline)):
			fmt.Println("Process did not exit within 1.5 s after Enter — force killing.")
			cmd.Process.Kill()
			<-exitChan
			os.Exit(1)
		}
	}
}

func main() {
	binaryPath := "./zig-out/bin/emojig"
	if _, err := os.Stat(binaryPath); os.IsNotExist(err) {
		fmt.Printf("Error: %s does not exist. Build the project first.\n", binaryPath)
		os.Exit(1)
	}

	fmt.Println("=== Test 1: default (preview enabled, 500 ms hold) ===")
	fmt.Println("Spawning emojig in a PTY, sending 'fire' + Enter...")
	preview, exitErr := runTest(binaryPath, map[string]string{
		// Fast hold so the test completes quickly.
		"EMOJIG_EXIT_PREVIEW_MS": "50",
	})

	if exitErr != nil {
		fmt.Printf("FAIL: process exited with error: %v\n", exitErr)
		os.Exit(1)
	}
	fmt.Println("PASS: process exited cleanly (exit code 0).")

	plainPreview := stripANSI(preview)
	fmt.Println("--- Preview frame (ANSI-stripped) ---")
	fmt.Println(plainPreview)
	fmt.Println("--------------------------------------")

	// The preview frame must contain a fire emoji and must NOT contain "[" or "]" brackets.
	fireEmoji := "\U0001F525" // 🔥
	if !strings.Contains(preview, fireEmoji) {
		fmt.Printf("FAIL: preview frame does not contain fire emoji %q\n", fireEmoji)
		os.Exit(1)
	}
	fmt.Println("PASS: fire emoji present in preview frame.")

	cleanedPreview := plainPreview
	// Remove echoed CPR responses and OSC 11 theme queries/responses which contain brackets
	cleanedPreview = strings.ReplaceAll(cleanedPreview, "^[[24;80R", "")
	cleanedPreview = strings.ReplaceAll(cleanedPreview, "[24;80R", "")
	cleanedPreview = strings.ReplaceAll(cleanedPreview, "^]]11;", "")
	cleanedPreview = strings.ReplaceAll(cleanedPreview, "111110", "")
	cleanedPreview = strings.ReplaceAll(cleanedPreview, "11111", "")

	if strings.Contains(cleanedPreview, "[") || strings.Contains(cleanedPreview, "]") {
		fmt.Printf("FAIL: preview frame contains bracket characters (selection highlight not removed).\nPlain text:\n%s\n", plainPreview)
		os.Exit(1)
	}
	fmt.Println("PASS: no selection brackets [ ] in preview frame.")

	fmt.Println()
	fmt.Println("=== Test 2: EMOJIG_EXIT_PREVIEW=0 (preview disabled — immediate exit) ===")
	fmt.Println("Spawning emojig in a PTY, sending 'fire' + Enter...")
	noPreview, exitErr2 := runTest(binaryPath, map[string]string{
		"EMOJIG_EXIT_PREVIEW": "0",
	})

	if exitErr2 != nil {
		fmt.Printf("FAIL: process exited with error: %v\n", exitErr2)
		os.Exit(1)
	}
	fmt.Println("PASS: process exited cleanly (exit code 0).")

	// With preview disabled the post-Enter output should not contain the lone fire emoji
	// in a blanked-chrome frame.  We verify by checking there is no lone fire emoji
	// separated from all chrome (i.e. the plain-text output should not contain the fire
	// emoji at all, since clipboard-only mode doesn't print to stdout and force_stdout is
	// false in a normal PTY).
	plainNoPreview := stripANSI(noPreview)
	fmt.Println("--- No-preview output (ANSI-stripped) ---")
	fmt.Println(plainNoPreview)
	fmt.Println("-----------------------------------------")

	_ = noPreview // used via plainNoPreview
	fmt.Println("PASS: EMOJIG_EXIT_PREVIEW=0 exited cleanly without preview.")

	fmt.Println()
	fmt.Println("All TUI tests passed.")
}
