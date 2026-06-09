// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package term provides Linux raw-mode terminal control and ANSI helpers using
// only the Go standard library (no golang.org/x/sys). Safe restoration of the
// terminal on exit, panic, or signal is mandatory (see AGENTS.md).
package term

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// ANSI control sequences.
const (
	AltScreenOn  = "\x1b[?1049h"
	AltScreenOff = "\x1b[?1049l"
	HideCursor   = "\x1b[?25l"
	ShowCursor   = "\x1b[?25h"
	ClearScreen  = "\x1b[2J"
	CursorHome   = "\x1b[H"
	Reset        = "\x1b[0m"
	MouseOff     = "\x1b[?1003l\x1b[?1006l"
	// ClearLine clears the current line. The leading carriage return resets the
	// cursor to column 1 first, so a growing query can never drift rightwards.
	ClearLine = "\r\x1b[2K"
)

// ScrollUp returns the sequence to scroll the screen up by n lines, keeping the
// initiating command visible (used to reserve an inline region without
// polluting scrollback).
func ScrollUp(n int) string { return fmt.Sprintf("\x1b[%dS", n) }

// MoveTo returns the sequence to move the cursor to an absolute 1-based
// (row, col). Inline rendering draws every frame from a known origin instead of
// relying on relative cursor motion, which cannot drift.
func MoveTo(row, col int) string { return fmt.Sprintf("\x1b[%d;%dH", row, col) }

// Terminal wraps a tty fd with saved state for restoration.
type Terminal struct {
	fd       int
	tty      *os.File
	orig     syscall.Termios
	restored bool

	// Inline region teardown state. When inline is true, Restore clears the
	// reserved region (rows regY..regY+regH-1) and parks the cursor at its
	// top-left instead of leaving the alt-screen. Set via SetInline.
	inline bool
	regY   int
	regH   int
	regW   int
}

func ioctl(fd int, req uintptr, t *syscall.Termios) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, uintptr(unsafe.Pointer(t)))
	if errno != 0 {
		return errno
	}
	return nil
}

// MakeRaw puts the controlling terminal into raw mode and returns a Terminal
// that can restore the previous state. It also installs a signal-safe restore
// path: callers must still `defer t.Restore()` for the normal/panic path.
func MakeRaw() (*Terminal, error) {
	// Use /dev/tty rather than os.Stdin so the picker keeps working when stdin
	// is a pipe (items fed in) and stdout is captured (`e=$(mojigo)`): control
	// codes and key input flow over the tty, leaving stdout for the selection.
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	fd := int(tty.Fd())
	var orig syscall.Termios
	if err := ioctl(fd, syscall.TCGETS, &orig); err != nil {
		tty.Close()
		return nil, err
	}

	raw := orig
	raw.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK |
		syscall.ISTRIP | syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IXON
	raw.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	raw.Oflag &^= syscall.OPOST
	raw.Cflag &^= syscall.CSIZE | syscall.PARENB
	raw.Cflag |= syscall.CS8
	raw.Cc[syscall.VMIN] = 1
	raw.Cc[syscall.VTIME] = 0

	if err := ioctl(fd, syscall.TCSETS, &raw); err != nil {
		tty.Close()
		return nil, err
	}

	t := &Terminal{fd: fd, tty: tty, orig: orig}
	t.installSignalHandler()
	return t, nil
}

// TTY returns the /dev/tty handle. Inline rendering writes control codes here
// and readKey reads input from it, keeping os.Stdout/os.Stdin free.
func (t *Terminal) TTY() *os.File { return t.tty }

// SetInline marks the terminal as holding an inline region at 1-based row y with
// the given height and width, so Restore tears the region down cleanly instead
// of leaving the alt-screen.
func (t *Terminal) SetInline(y, height, width int) {
	t.inline = true
	t.regY = y
	t.regH = height
	t.regW = width
}

// parseCursorReport parses a DSR cursor-position report of the form
// \x1b[<row>;<col>R into 1-based row and col.
func parseCursorReport(s string) (row, col int, err error) {
	if _, err = fmt.Sscanf(s, "\x1b[%d;%dR", &row, &col); err != nil {
		return 0, 0, err
	}
	if row < 1 || col < 1 {
		return 0, 0, fmt.Errorf("invalid cursor report %q", s)
	}
	return row, col, nil
}

// QueryCursor asks the terminal for the cursor position via DSR (\x1b[6n) and
// parses the \x1b[<row>;<col>R reply. Raw mode must already be on. It runs the
// read under a short deadline; on timeout or a malformed reply it returns an
// error so the caller can fall back to a safe default (treat as the bottom row).
func (t *Terminal) QueryCursor() (row, col int, err error) {
	if _, err = t.tty.WriteString("\x1b[6n"); err != nil {
		return 0, 0, err
	}
	type res struct {
		row, col int
		err      error
	}
	ch := make(chan res, 1)
	go func() {
		var buf [32]byte
		n := 0
		for n < len(buf) {
			m, rerr := t.tty.Read(buf[n : n+1])
			if rerr != nil {
				ch <- res{err: rerr}
				return
			}
			n += m
			if m > 0 && buf[n-1] == 'R' {
				break
			}
		}
		r, c, serr := parseCursorReport(string(buf[:n]))
		if serr != nil {
			ch <- res{err: serr}
			return
		}
		ch <- res{row: r, col: c}
	}()
	select {
	case out := <-ch:
		return out.row, out.col, out.err
	case <-time.After(250 * time.Millisecond):
		return 0, 0, fmt.Errorf("cursor query timed out")
	}
}

// installSignalHandler restores the terminal and exits on SIGINT/SIGTERM,
// since signals bypass deferred functions.
func (t *Terminal) installSignalHandler() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-ch
		t.Restore()
		os.Exit(130)
	}()
}

// Restore returns the terminal to its original (cooked) state and disables the
// alt-screen, mouse tracking, and cursor hiding. Safe to call multiple times.
func (t *Terminal) Restore() {
	if t.restored {
		return
	}
	t.restored = true

	w := t.writer()
	if t.inline {
		// Clear the reserved region row by row, then park the cursor at its
		// top-left so the shell prompt overwrites the drawing area — no orphaned
		// lines, no scrollback pollution.
		var b strings.Builder
		for i := 0; i < t.regH; i++ {
			b.WriteString(MoveTo(t.regY+i, 1) + strings.Repeat(" ", t.regW))
		}
		b.WriteString(MoveTo(t.regY, 1) + MouseOff + ShowCursor + Reset)
		w.WriteString(b.String())
	} else {
		w.WriteString(MouseOff + AltScreenOff + ShowCursor + Reset)
	}
	_ = ioctl(t.fd, syscall.TCSETS, &t.orig)
	if t.tty != nil {
		t.tty.Close()
	}
}

// writer returns the destination for control codes: the /dev/tty handle when
// present, falling back to os.Stdout.
func (t *Terminal) writer() interface{ WriteString(string) (int, error) } {
	if t.tty != nil {
		return t.tty
	}
	return os.Stdout
}

// Size returns the terminal's columns and rows.
func (t *Terminal) Size() (cols, rows int) {
	var ws struct {
		Row, Col, X, Y uint16
	}
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(t.fd),
		uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws)))
	if errno != 0 {
		return 80, 24
	}
	return int(ws.Col), int(ws.Row)
}
