// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// inline_tui.go — minimal inline TUI testbed demonstrating the "eat lines above" resize strategy.
//
// When the terminal shrinks vertically the emulator scrolls content upward; the TUI
// stays on screen because it sits at the bottom of the viewport. Lines above it
// (shell history) are sacrificed to scrollback — the TUI frame itself never enters
// scrollback. On SIGWINCH the app just re-reads TIOCGWINSZ and redraws in place.
// No CPR round-trip, no hide/freeze state machine.
//
// See docs/InlineTui.md §4.5 for tradeoffs vs. the hide/freeze approach used in emojig.
// Run: go run scripts/inline_tui.go
// Press q or Ctrl-C to quit.

package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
	"unsafe"
)

// ANSI sequences
const (
	cursorHide  = "\x1b[?25l"
	cursorShow  = "\x1b[?25h"
	cursorBlink = "\x1b[?12h"
	wrapOff     = "\x1b[?7l"
	wrapOn      = "\x1b[?7h"
	clearLine   = "\x1b[2K"
	cursorDown  = "\x1b[B\r"
)

func cursorUp(n int) string { return fmt.Sprintf("\x1b[%dA\r", n) }

// winsize mirrors struct winsize from <sys/ioctl.h>.
type winsize struct {
	Row, Col       uint16
	Xpixel, Ypixel uint16
}

func termSize(fd uintptr) (rows, cols int) {
	var ws winsize
	syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&ws)))
	return int(ws.Row), int(ws.Col)
}

// tuiHeight is the number of lines the inline TUI occupies.
const tuiHeight = 6

func drawFrame(tty *os.File, tick int, hidden bool) {
	cursor := "█"
	if tick%2 == 0 {
		cursor = " "
	}

	if hidden {
		// frozen: blank line, no cursor
		fmt.Fprint(tty, clearLine)
		return
	}

	rows, _ := termSize(tty.Fd())
	lines := []string{
		"",
		fmt.Sprintf(" inline TUI  [%s]", cursor),
		" ─────────────────",
		fmt.Sprintf(" Term Rows: %-3d | TUI Height: %-3d", rows, tuiHeight),
		fmt.Sprintf(" Status: Visible | Threshold: %-3d", tuiHeight+1),
		" q to quit",
	}
	for i, l := range lines {
		fmt.Fprint(tty, clearLine+l)
		if i < len(lines)-1 {
			fmt.Fprint(tty, cursorDown)
		}
	}
	// move back to top of TUI region
	fmt.Fprint(tty, cursorUp(len(lines)-1))
}

func clearTUI(tty *os.File, rows int) {
	for i := 0; i < rows; i++ {
		fmt.Fprint(tty, clearLine)
		if i < rows-1 {
			fmt.Fprint(tty, cursorDown)
		}
	}
	if rows > 1 {
		fmt.Fprint(tty, cursorUp(rows-1))
	}
}

func rawMode(fd int) (syscall.Termios, error) {
	var orig syscall.Termios
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCGETS, uintptr(unsafe.Pointer(&orig))); e != 0 {
		return orig, e
	}
	raw := orig
	raw.Iflag &^= syscall.IXON | syscall.ICRNL | syscall.BRKINT | syscall.INPCK | syscall.ISTRIP
	raw.Oflag &^= syscall.OPOST
	raw.Cflag |= syscall.CS8
	raw.Lflag &^= syscall.ECHO | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	raw.Cc[syscall.VMIN] = 0
	raw.Cc[syscall.VTIME] = 1
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&raw))); e != 0 {
		return orig, e
	}
	return orig, nil
}

func restoreMode(fd int, orig syscall.Termios) {
	syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&orig)))
}

func main() {
	delay := flag.Duration("delay", 100*time.Millisecond, "redraw interval (e.g. 100ms, 500ms, 1s)")
	flag.Parse()

	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot open /dev/tty:", err)
		os.Exit(1)
	}
	defer tty.Close()

	orig, err := rawMode(int(tty.Fd()))
	if err != nil {
		fmt.Fprintln(os.Stderr, "raw mode failed:", err)
		os.Exit(1)
	}

	restore := func() {
		restoreMode(int(tty.Fd()), orig)
		fmt.Fprint(tty, cursorShow+wrapOn)
	}
	defer restore()

	// reserve vertical space for the TUI
	for i := 0; i < tuiHeight-1; i++ {
		fmt.Fprint(tty, "\n")
	}
	fmt.Fprint(tty, cursorUp(tuiHeight-1))

	fmt.Fprint(tty, wrapOff+cursorHide+cursorBlink)

	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)

	quit := make(chan struct{})
	go func() {
		buf := make([]byte, 1)
		for {
			n, _ := tty.Read(buf)
			if n > 0 && (buf[0] == 'q' || buf[0] == 3) {
				close(quit)
				return
			}
		}
	}()

	ticker := time.NewTicker(*delay)
	defer ticker.Stop()

	tick := 0
	hidden := false

	checkSize := func() {
		rows, _ := termSize(tty.Fd())
		if rows > 0 {
			hidden = rows < tuiHeight+1
		}
	}
	checkSize()

	for {
		select {
		case <-quit:
			clearTUI(tty, tuiHeight)
			fmt.Fprintln(tty, "\r(bye)")
			return
		case <-winch:
			checkSize()
		case <-ticker.C:
			tick++
			drawFrame(tty, tick, hidden)
		}
	}
}
