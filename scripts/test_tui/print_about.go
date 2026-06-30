// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//go:build ignore
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

func spawnPTY() (*os.File, string) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		panic(err)
	}

	var ptsNum uint32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&ptsNum)))
	if errno != 0 {
		panic(errno)
	}

	var unlock int
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock)))
	if errno != 0 {
		panic(errno)
	}

	slaveName := fmt.Sprintf("/dev/pts/%d", ptsNum)
	return master, slaveName
}

func main() {
	binaryPath := "./zig-out/bin/emojig"
	master, slaveName := spawnPTY()
	defer master.Close()

	slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		panic(err)
	}
	defer slave.Close()

	type winsize struct{ Row, Col, Xpixel, Ypixel uint16 }
	ws := winsize{Row: 24, Col: 80}
	syscall.Syscall(syscall.SYS_IOCTL, slave.Fd(), syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))

	cmd := exec.Command(binaryPath, "--tui")
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	cmd.Env = append(os.Environ(), "EMOJIG_THEME=dark", "EMOJIG_EXIT_PREVIEW=0", "EMOJIG_COLS=8", "EMOJIG_ROWS=10", "EMOJIG_COMPACT=0")

	if err := cmd.Start(); err != nil {
		panic(err)
	}
	slave.Close()

	time.Sleep(300 * time.Millisecond)

	// Send /a + Enter to open About
	master.Write([]byte("/a"))
	time.Sleep(200 * time.Millisecond)
	master.Write([]byte("\n"))
	time.Sleep(300 * time.Millisecond)

	// Read all output
	buf := make([]byte, 65536)
	n, _ := master.Read(buf)

	ts := NewTerminalState(80, 24)
	ts.Parse(buf[:n])
	ts.PrintScreen()

	// Print backgrounds of rows 3 to 10
	fmt.Println("\n--- Backgrounds ---")
	for y := 3; y <= 10; y++ {
		var bgs []string
		for x := 0; x < 40; x++ {
			bg := ts.Grid[y][x].BgColor
			if bg == "" {
				bg = "   "
			}
			bgs = append(bgs, bg)
		}
		fmt.Printf("Row %02d BG: %v\n", y, bgs)
	}

	cmd.Process.Kill()
}
