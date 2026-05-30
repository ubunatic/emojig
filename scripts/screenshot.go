// screenshot.go — capture an initial rendered frame of emojig in a PTY.
// Outputs a plain-text (ANSI-stripped) frame to stdout and saves the raw
// ANSI frame to /tmp/emojig_frame.ansi for agent inspection.
// Usage: go run scripts/screenshot.go [binary-path]
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

	// Set PTY window size to match the picker window (40 cols × 8 rows).
	// Use 8 rows (not 10) so the test catches scroll bugs that only occur
	// when window-height == content-height.
	type winsize struct{ Row, Col, Xpixel, Ypixel uint16 }
	ws := winsize{Row: 8, Col: 40}
	syscall.Syscall(syscall.SYS_IOCTL, slave.Fd(), syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))

	cmd := exec.Command(binaryPath, "--tui")
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	cmd.Env = append(os.Environ(), "EMOJIG_WIDTH=40", "TERM=xterm-256color")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}

	// Wait for initial render.
	time.Sleep(300 * time.Millisecond)

	syscall.SetNonblock(int(master.Fd()), true)
	buf := make([]byte, 16384)
	n, _ := master.Read(buf)
	syscall.SetNonblock(int(master.Fd()), false)

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
