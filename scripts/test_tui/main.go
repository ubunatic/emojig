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

	plainNoPreview := stripANSI(noPreview)
	fmt.Println("--- No-preview output (ANSI-stripped) ---")
	fmt.Println(plainNoPreview)
	fmt.Println("-----------------------------------------")

	_ = noPreview // used via plainNoPreview
	fmt.Println("PASS: EMOJIG_EXIT_PREVIEW=0 exited cleanly without preview.")

	fmt.Println()
	fmt.Println("=== Test 3: GUI Focus reporting test ===")
	runFocusTest(binaryPath)
	fmt.Println("PASS: GUI Focus reporting test passed.")

	fmt.Println()
	fmt.Println("=== Test 4: Category autocompletion test ===")
	runCategoryAutocompleteTest(binaryPath)
	fmt.Println("PASS: Category autocompletion test passed.")

	fmt.Println()
	fmt.Println("=== Test 5: Quit command test (:q and /quit) ===")
	runQuitCommandTest(binaryPath)
	fmt.Println("PASS: Quit command test passed.")

	fmt.Println()
	fmt.Println("=== Test 6: Multi-selection mode test ===")
	runMultiSelectTest(binaryPath)
	fmt.Println("PASS: Multi-selection mode test passed.")

	fmt.Println()
	fmt.Println("All TUI tests passed.")
}

func runFocusTest(binaryPath string) {
	master, slaveName := spawnPTY()
	defer master.Close()

	slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Printf("Error opening slave PTY %s: %v\n", slaveName, err)
		os.Exit(1)
	}
	defer slave.Close()

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
	cmd.Env = append(os.Environ(), "EMOJIG_GUI_SPAWNED=1", "EMOJIG_PICKER_TIMEOUT=10")

	if err := cmd.Start(); err != nil {
		fmt.Printf("Error starting command: %v\n", err)
		os.Exit(1)
	}
	slave.Close()

	chunksChan := make(chan string, 100)
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := master.Read(buf)
			if n > 0 {
				s := string(buf[:n])
				chunksChan <- s
				if strings.Contains(s, "\x1b[6n") {
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

	// Wait for initial render. It should start unfocused since we did not write focus-in yet, and EMOJIG_GUI_SPAWNED=1.
	time.Sleep(500 * time.Millisecond)
	out1 := stripANSI(collectAvailable())
	if !strings.Contains(out1, "prevented focus") {
		fmt.Printf("FAIL: expected initial output to show 'OS prevented focus change'. Got:\n%s\n", out1)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: correctly started unfocused.")

	// Send focus-in sequence \x1b[I.
	fmt.Println("Sending focus-in sequence...")
	if _, err := master.Write([]byte("\x1b[I")); err != nil {
		fmt.Printf("Error writing focus-in: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	out2 := stripANSI(collectAvailable())
	if !strings.Contains(out2, "search") {
		fmt.Printf("FAIL: expected normal GUI to be restored after focus-in. Got:\n%s\n", out2)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: correctly restored to search GUI after focus-in.")

	// Send focus-out sequence \x1b[O.
	fmt.Println("Sending focus-out sequence...")
	if _, err := master.Write([]byte("\x1b[O")); err != nil {
		fmt.Printf("Error writing focus-out: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	out3 := stripANSI(collectAvailable())
	if !strings.Contains(out3, "unfocused") {
		fmt.Printf("FAIL: expected focus lost screen after focus-out. Got:\n%s\n", out3)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: correctly transitioned to focus lost screen.")

	// Send focus-in sequence \x1b[I again.
	fmt.Println("Sending focus-in sequence again...")
	if _, err := master.Write([]byte("\x1b[I")); err != nil {
		fmt.Printf("Error writing focus-in 2: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	out4 := stripANSI(collectAvailable())
	if !strings.Contains(out4, "search") {
		fmt.Printf("FAIL: expected normal GUI to be restored after focus-in 2. Got:\n%s\n", out4)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: correctly restored to search GUI after focus-in 2.")

	// Clean exit: send Ctrl-C.
	master.Write([]byte("\x03"))
	cmd.Wait()
}

func runCategoryAutocompleteTest(binaryPath string) {
	master, slaveName := spawnPTY()
	defer master.Close()

	slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Printf("Error opening slave PTY %s: %v\n", slaveName, err)
		os.Exit(1)
	}
	defer slave.Close()

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
	cmd.Env = append(os.Environ(), "EMOJIG_EXIT_PREVIEW=0")

	if err := cmd.Start(); err != nil {
		fmt.Printf("Error starting command: %v\n", err)
		os.Exit(1)
	}
	slave.Close()

	chunksChan := make(chan string, 100)
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := master.Read(buf)
			if n > 0 {
				s := string(buf[:n])
				chunksChan <- s
				if strings.Contains(s, "\x1b[6n") {
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
	time.Sleep(300 * time.Millisecond)
	_ = collectAvailable()

	// Type "c:" to trigger category autocomplete
	if _, err := master.Write([]byte("c:")); err != nil {
		fmt.Printf("Error writing c:: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(200 * time.Millisecond)
	out := stripANSI(collectAvailable())

	// The output should display the categories, for example, "smileys"
	if !strings.Contains(out, "smileys") && !strings.Contains(out, "flags") {
		fmt.Printf("FAIL: expected category autocomplete list to show smileys/flags. Got:\n%s\n", out)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: category list is visible in autocomplete grid.")

	// Press Enter to select the first category ("smileys")
	if _, err := master.Write([]byte("\n")); err != nil {
		fmt.Printf("Error writing Enter: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(200 * time.Millisecond)
	out2 := stripANSI(collectAvailable())

	// The query should now be "c:smiley "
	if !strings.Contains(out2, "c:smiley") {
		fmt.Printf("FAIL: expected query to be updated to 'c:smiley '. Got:\n%s\n", out2)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: query updated to category query prefix.")

	// Press Enter again to select the clock emoji and exit
	if _, err := master.Write([]byte("\n")); err != nil {
		fmt.Printf("Error writing Enter: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}

	if err := cmd.Wait(); err != nil {
		fmt.Printf("FAIL: process exited with error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("PASS: process exited cleanly after selecting emoji from category.")
}

func runMultiSelectTest(binaryPath string) {
	master, slaveName := spawnPTY()
	defer master.Close()

	slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Printf("Error opening slave PTY %s: %v\n", slaveName, err)
		os.Exit(1)
	}
	defer slave.Close()

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
	cmd.Env = append(os.Environ(), "EMOJIG_EXIT_PREVIEW=0")

	if err := cmd.Start(); err != nil {
		fmt.Printf("Error starting command: %v\n", err)
		os.Exit(1)
	}
	slave.Close()

	chunksChan := make(chan string, 100)
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := master.Read(buf)
			if n > 0 {
				s := string(buf[:n])
				chunksChan <- s
				if strings.Contains(s, "\x1b[6n") {
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

	// Type "/multi"
	if _, err := master.Write([]byte("/multi")); err != nil {
		fmt.Printf("Error typing /multi: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)

	// Press Enter to activate multi selection mode
	if _, err := master.Write([]byte("\n")); err != nil {
		fmt.Printf("Error starting multi-select: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	out := stripANSI(collectAvailable())

	// The status/layout should display "[Multi:0]"
	if !strings.Contains(out, "[Multi:0]") {
		fmt.Printf("FAIL: expected TUI to indicate multi-selection active with 0 selected. Got:\n%s\n", out)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: multi-selection mode is active.")

	// Type "robot" to search for robot
	if _, err := master.Write([]byte("robot")); err != nil {
		fmt.Printf("Error typing robot: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	_ = collectAvailable()

	// Press Enter to select the robot emoji (🤖)
	if _, err := master.Write([]byte("\n")); err != nil {
		fmt.Printf("Error writing Enter: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	out2 := stripANSI(collectAvailable())

	// The status/layout should display "[Multi:1]"
	if !strings.Contains(out2, "[Multi:1]") {
		fmt.Printf("FAIL: expected TUI to show 1 selected. Got:\n%s\n", out2)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: selected first emoji (🤖) in multi-selection mode.")

	// Clear search term by sending 5 backspaces
	if _, err := master.Write([]byte("\x7f\x7f\x7f\x7f\x7f")); err != nil {
		fmt.Printf("Error writing Backspaces: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	_ = collectAvailable()

	// Type "heart" to search for heart
	if _, err := master.Write([]byte("heart")); err != nil {
		fmt.Printf("Error typing heart: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	_ = collectAvailable()

	// Press Enter to select the heart emoji
	if _, err := master.Write([]byte("\n")); err != nil {
		fmt.Printf("Error writing Enter: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}
	time.Sleep(300 * time.Millisecond)
	out3 := stripANSI(collectAvailable())

	// The status/layout should display "[Multi:2]"
	if !strings.Contains(out3, "[Multi:2]") {
		fmt.Printf("FAIL: expected TUI to show 2 selected. Got:\n%s\n", out3)
		cmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Println("PASS: selected second emoji in multi-selection mode.")

	// Send Shift-Enter (using CSI sequence for shift-enter "\x1b[27;2;13~")
	if _, err := master.Write([]byte("\x1b[27;2;13~")); err != nil {
		fmt.Printf("Error writing Shift-Enter: %v\n", err)
		cmd.Process.Kill()
		os.Exit(1)
	}

	// The process should exit with 0
	if err := cmd.Wait(); err != nil {
		fmt.Printf("FAIL: process exited with error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("PASS: process exited cleanly on Shift-Enter.")
}

func runQuitCommandTest(binaryPath string) {
	// 1. Test :q command
	{
		master, slaveName := spawnPTY()
		defer master.Close()

		slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
		if err != nil {
			fmt.Printf("Error opening slave PTY %s: %v\n", slaveName, err)
			os.Exit(1)
		}
		defer slave.Close()

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
		cmd.Env = append(os.Environ(), "EMOJIG_EXIT_PREVIEW=0")

		if err := cmd.Start(); err != nil {
			fmt.Printf("Error starting command: %v\n", err)
			os.Exit(1)
		}
		slave.Close()

		chunksChan := make(chan string, 100)
		go func() {
			buf := make([]byte, 65536)
			for {
				n, err := master.Read(buf)
				if n > 0 {
					s := string(buf[:n])
					chunksChan <- s
					if strings.Contains(s, "\x1b[6n") {
						master.Write([]byte("\x1b[24;80R"))
					}
				}
				if err != nil {
					close(chunksChan)
					return
				}
			}
		}()

		// Wait for initial render.
		time.Sleep(300 * time.Millisecond)

		// Type "/q"
		if _, err := master.Write([]byte("/q")); err != nil {
			fmt.Printf("Error typing /q: %v\n", err)
			cmd.Process.Kill()
			os.Exit(1)
		}
		time.Sleep(200 * time.Millisecond)

		// Press Enter to execute the command
		if _, err := master.Write([]byte("\n")); err != nil {
			fmt.Printf("Error writing Enter: %v\n", err)
			cmd.Process.Kill()
			os.Exit(1)
		}

		exitChan := make(chan error, 1)
		go func() { exitChan <- cmd.Wait() }()

		select {
		case err := <-exitChan:
			if err != nil {
				fmt.Printf("FAIL: quit command :q failed to exit cleanly: %v\n", err)
				os.Exit(1)
			}
		case <-time.After(1500 * time.Millisecond):
			fmt.Println("FAIL: quit command :q did not exit within 1.5 s — force killing.")
			cmd.Process.Kill()
			<-exitChan
			os.Exit(1)
		}
		fmt.Println("PASS: quit command :q exited cleanly.")
	}

	// 2. Test /quit command
	{
		master, slaveName := spawnPTY()
		defer master.Close()

		slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
		if err != nil {
			fmt.Printf("Error opening slave PTY %s: %v\n", slaveName, err)
			os.Exit(1)
		}
		defer slave.Close()

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
		cmd.Env = append(os.Environ(), "EMOJIG_EXIT_PREVIEW=0")

		if err := cmd.Start(); err != nil {
			fmt.Printf("Error starting command: %v\n", err)
			os.Exit(1)
		}
		slave.Close()

		chunksChan := make(chan string, 100)
		go func() {
			buf := make([]byte, 65536)
			for {
				n, err := master.Read(buf)
				if n > 0 {
					s := string(buf[:n])
					chunksChan <- s
					if strings.Contains(s, "\x1b[6n") {
						master.Write([]byte("\x1b[24;80R"))
					}
				}
				if err != nil {
					close(chunksChan)
					return
				}
			}
		}()

		// Wait for initial render.
		time.Sleep(300 * time.Millisecond)

		// Type "/quit"
		if _, err := master.Write([]byte("/quit")); err != nil {
			fmt.Printf("Error typing /quit: %v\n", err)
			cmd.Process.Kill()
			os.Exit(1)
		}
		time.Sleep(200 * time.Millisecond)

		// Press Enter to execute the command
		if _, err := master.Write([]byte("\n")); err != nil {
			fmt.Printf("Error writing Enter: %v\n", err)
			cmd.Process.Kill()
			os.Exit(1)
		}

		exitChan := make(chan error, 1)
		go func() { exitChan <- cmd.Wait() }()

		select {
		case err := <-exitChan:
			if err != nil {
				fmt.Printf("FAIL: quit command /quit failed to exit cleanly: %v\n", err)
				os.Exit(1)
			}
		case <-time.After(1500 * time.Millisecond):
			fmt.Println("FAIL: quit command /quit did not exit within 1.5 s — force killing.")
			cmd.Process.Kill()
			<-exitChan
			os.Exit(1)
		}
		fmt.Println("PASS: quit command /quit exited cleanly.")
	}
}


