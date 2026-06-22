// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// screenshot.go — capture an initial rendered frame of emojig in a PTY.
// Outputs a plain-text (ANSI-stripped) frame to stdout and saves the raw
// ANSI frame to /tmp/emojig_frame.ansi for agent inspection.
// An optional second argument is typed into the picker before capturing,
// e.g. "??" to capture the second help page.
// Usage: go run ./scripts/screenshot [binary-path [keys]]
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

func main() {
	binaryPath := "./zig-out/bin/emojig"
	if len(os.Args) > 1 {
		binaryPath = os.Args[1]
	}
	keys := ""
	if len(os.Args) > 2 {
		keys = os.Args[2]
	}
	if _, err := os.Stat(binaryPath); os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "binary not found: %s — building first\n", binaryPath)
		build := exec.Command("zig", "build")
		build.Stdout = os.Stderr
		build.Stderr = os.Stderr
		if err := build.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "build failed: %v\n", err)
			os.Exit(1)
		}
	}

	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open /dev/ptmx: %v\n", err)
		os.Exit(1)
	}
	defer master.Close()

	var ptsNum uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&ptsNum))); errno != 0 {
		fmt.Fprintf(os.Stderr, "TIOCGPTN: %v\n", errno)
		os.Exit(1)
	}
	var unlock int
	syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock)))

	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", ptsNum), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open slave PTY: %v\n", err)
		os.Exit(1)
	}
	defer slave.Close()

	type winsize struct{ Row, Col, Xpixel, Ypixel uint16 }
	rowSize := uint16(12)
	ws := winsize{Row: rowSize, Col: 50}
	syscall.Syscall(syscall.SYS_IOCTL, slave.Fd(), syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))

	cmd := exec.Command(binaryPath, "--tui", "--show-switcher")
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	cmd.Env = append(os.Environ(), "EMOJIG_WIDTH=45", "EMOJIG_ROWS=4", "TERM=xterm-256color")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
		Ctty:    0,
	}

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}

	// Wait for initial render.
	time.Sleep(800 * time.Millisecond)

	// Type the optional keys and wait for the re-render.
	if keys != "" {
		for _, ks := range parseKeystrokes(keys) {
			master.Write(ks)
			time.Sleep(50 * time.Millisecond)
		}
		time.Sleep(300 * time.Millisecond)
	}

	// Drain with raw syscall.Read: os.File.Read would park in the Go poller
	// on EAGAIN instead of returning once the buffered frames are consumed.
	// Fd() must be called once only — every call flips the fd back to blocking.
	masterFd := int(master.Fd())
	syscall.SetNonblock(masterFd, true)
	buf := make([]byte, 32768)
	n := 0
	for n < len(buf) {
		r, _ := syscall.Read(masterFd, buf[n:])
		if r <= 0 {
			break
		}
		n += r
	}
	syscall.SetNonblock(masterFd, false)

	// Kill the app.
	cmd.Process.Signal(syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		cmd.Process.Kill()
		<-done
	}

	raw := string(buf[:n])

	// Save raw ANSI to /tmp/emojig_frame.ansi.
	_ = os.WriteFile("/tmp/emojig_frame.ansi", []byte(raw), 0644)

	// Strip ANSI escape sequences for readable text output.
	plain := stripANSI(raw)
	_ = os.WriteFile("/tmp/emojig_frame.txt", []byte(plain), 0644)

	fmt.Printf("=== emojig initial frame (ANSI stripped) ===\n%s\n", plain)
	fmt.Printf("Raw ANSI saved to: /tmp/emojig_frame.ansi\n")
	fmt.Printf("Plain text saved to: /tmp/emojig_frame.txt\n")
}

// stripANSI removes ANSI CSI/OSC/etc escape sequences and control bytes,
// leaving only printable content and newlines.
func stripANSI(s string) string {
	var out strings.Builder
	i := 0
	for i < len(s) {
		b := s[i]
		if b == 0x1b && i+1 < len(s) {
			next := s[i+1]
			if next == '[' { // CSI
				i += 2
				for i < len(s) && (s[i] < 0x40 || s[i] > 0x7e) {
					i++
				}
				i++ // consume final byte
				continue
			} else if next == ']' { // OSC
				i += 2
				for i < len(s) {
					if s[i] == 0x07 {
						i++
						break
					}
					if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '\\' {
						i += 2
						break
					}
					i++
				}
				continue
			} else if next == '\\' || next == 'c' {
				i += 2
				continue
			} else {
				i += 2
				continue
			}
		}
		if b == '\r' {
			i++
			continue
		}
		if b == '\n' {
			out.WriteByte('\n')
			i++
			continue
		}
		if b >= 0x20 || b > 0x7e {
			out.WriteByte(b)
		}
		i++
	}
	return out.String()
}

// parseKeystrokes splits a key string into individual writes:
// ANSI CSI/SS3 escape sequences (e.g. \x1b[A, \x1bOB) are kept as one
// slice so they arrive at the PTY in a single write; all other bytes are
// sent one at a time with a 50 ms delay between them.
// Note: ESC sequence atomicity depends on the TUI's read buffer size —
// if it reads 1 byte at a time, CSI sequences may still be split.
func parseKeystrokes(keys string) [][]byte {
	var list [][]byte
	i := 0
	for i < len(keys) {
		if keys[i] == 0x1b && i+2 < len(keys) {
			// ESC + introducer byte ([ or O) + at least one more byte.
			start := i
			i += 2 // skip ESC and the introducer ([ or O)
			for i < len(keys) {
				b := keys[i]
				i++
				if (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '~' {
					break
				}
			}
			list = append(list, []byte(keys[start:i]))
		} else {
			list = append(list, []byte{keys[i]})
			i++
		}
	}
	return list
}
