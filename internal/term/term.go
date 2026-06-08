// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package term provides Linux raw-mode terminal control and ANSI helpers using
// only the Go standard library (no golang.org/x/sys). Safe restoration of the
// terminal on exit, panic, or signal is mandatory (see AGENTS.md).
package term

import (
	"os"
	"os/signal"
	"syscall"
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
)

// Terminal wraps a tty fd with saved state for restoration.
type Terminal struct {
	fd       int
	orig     syscall.Termios
	restored bool
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
	fd := int(os.Stdin.Fd())
	var orig syscall.Termios
	if err := ioctl(fd, syscall.TCGETS, &orig); err != nil {
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
		return nil, err
	}

	t := &Terminal{fd: fd, orig: orig}
	t.installSignalHandler()
	return t, nil
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
	os.Stdout.WriteString(MouseOff + AltScreenOff + ShowCursor + Reset)
	_ = ioctl(t.fd, syscall.TCSETS, &t.orig)
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
