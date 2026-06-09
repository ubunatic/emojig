// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// ANSI sequences
const (
	cursorHide  = "\x1b[?25l"
	cursorShow  = "\x1b[?25h"
	wrapOff     = "\x1b[?7l"
	wrapOn      = "\x1b[?7h"
	clearLine   = "\x1b[2K"
	cursorDown  = "\x1b[B\r"
)

func cursorUp(n int) string {
	if n <= 0 {
		return ""
	}
	return fmt.Sprintf("\x1b[%dA\r", n)
}

type winsize struct {
	Row, Col       uint16
	Xpixel, Ypixel uint16
}

func termSize(fd uintptr) (rows, cols int) {
	var ws winsize
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&ws)))
	if errno != 0 {
		return 24, 80
	}
	return int(ws.Row), int(ws.Col)
}

// boxHeight is the reserved vertical footprint of the TUI; it is a variable so
// it can be overridden with the -height flag for testing.
var boxHeight = 10

var startRow int

// printDemo writes a few lines of marker content to w. It is used to print to
// stdout immediately before raw mode is entered (setup) and immediately after
// the terminal is restored (teardown), so the inline behaviour of the TUI can
// be eyeballed: setup lines should scroll cleanly into scrollback above the
// box, and teardown lines should resume exactly where the box was, with nothing
// clobbered. Writing to stdout (not /dev/tty) also exercises the stream
// separation — under a pipe these go to the pipe, not the terminal.
func printDemo(w io.Writer, header string) {
	fmt.Fprintf(w, "── %s ──\n", header)
	for i := 1; i <= 3; i++ {
		fmt.Fprintf(w, "   stdout line %d\n", i)
	}
}

// stats captures the per-draw state we want to correlate with a leaked
// scrollback line: the rendered digest lives in the top border so a glance at a
// recording/screenshot tells you the numbers in effect when a stray line
// appeared. ASCII-only so byte length == display width and the box stays aligned.
type stats struct {
	redraws   int    // frame/redraw count
	winches   int    // SIGWINCH events seen
	startRow  int    // CPR-reported top row of the TUI (0 = relative mode)
	cols      int    // current terminal columns
	rows      int    // current terminal rows
	boxHeight int    // reserved box height
	absolute  bool   // absolute-positioning mode requested
	lastEvent string // last event handled (init/cpr/rsz)
}

// overflow is how far the box bottom extends past the last terminal row.
// ov > 0 means the box cannot fit below startRow, so any draw scrolls the
// viewport — the classic cause of a leaked scrollback line.
func (s *stats) overflow() int { return s.startRow + s.boxHeight - 1 - s.rows }

func (s *stats) digest() string {
	mode := "REL"
	if s.absolute && s.startRow > 0 {
		mode = "ABS"
	}
	return fmt.Sprintf("f%d wz%d sr%d %dx%d bh%d ov%+d %s ev:%s",
		s.redraws, s.winches, s.startRow, s.cols, s.rows, s.boxHeight, s.overflow(), mode, s.lastEvent)
}

// legend explains the digest tokens; rendered top-aligned inside the box.
func (s *stats) legend() []string {
	return []string{
		"Top-border digest = state at draw time:",
		"  f# redraws   wz SIGWINCH events",
		"  sr startRow via CPR (0 = relative)",
		"  WxH term cols x rows   bh box height",
		"  ov = sr + bh-1 - rows",
		"     ov > 0  => box past bottom row",
		"     (terminal scrolls => leaked line)",
		"  ABS/REL mode   ev = last event",
	}
}

// borderWithLabel renders a top/bottom border of `inner` dashes (between the two
// `+` corners) with `label` embedded after the first dash, truncated to fit.
func borderWithLabel(inner int, label string) string {
	if inner < 4 {
		if inner < 0 {
			inner = 0
		}
		return "+" + strings.Repeat("-", inner) + "+"
	}
	label = " " + label + " "
	if len(label) > inner-1 {
		label = label[:inner-1]
	}
	rest := inner - 1 - len(label)
	return "+-" + label + strings.Repeat("-", rest) + "+"
}

func drawBox(tty *os.File, cols, rows int, absolute bool, st *stats) {
	width := cols - 1
	if width < 10 {
		width = 10
	}
	inner := width - 2

	var b strings.Builder

	// Move to startRow absolutely and clear the canvas below, or clear relatively
	if absolute && startRow > 0 {
		b.WriteString(fmt.Sprintf("\x1b[%d;1H\x1b[J", startRow))
	} else {
		b.WriteString("\x1b[J")
	}

	// Top border carries the brief state digest
	b.WriteString(borderWithLabel(inner, st.digest()) + cursorDown)

	// Inner rows: digest legend, top-aligned (blank-filled below it)
	legend := st.legend()
	for r := 1; r < boxHeight-1; r++ {
		b.WriteString(clearLine)
		line := ""
		if idx := r - 1; idx < len(legend) {
			line = legend[idx]
		}
		if len(line) > inner {
			line = line[:inner]
		}
		b.WriteString("|" + line + strings.Repeat(" ", inner-len(line)) + "|")
		b.WriteString(cursorDown)
	}

	// Bottom border
	b.WriteString(clearLine + "+" + strings.Repeat("-", inner) + "+")

	// Move cursor back to startRow absolutely or relatively
	if absolute && startRow > 0 {
		b.WriteString(fmt.Sprintf("\x1b[%d;1H", startRow))
	} else {
		b.WriteString(cursorUp(boxHeight - 1))
	}

	tty.WriteString(b.String())
}

func drawTooSmall(tty *os.File, cols, rows int, absolute bool) {
	var b strings.Builder
	if absolute && startRow > 0 {
		b.WriteString(fmt.Sprintf("\x1b[%d;1H\x1b[J", startRow))
	} else {
		b.WriteString("\x1b[J")
	}

	hint := " Terminal size too small "
	if len(hint) > cols-2 {
		hint = " Too small "
	}
	if cols > len(hint) {
		padLeft := (cols - len(hint)) / 2
		hint = strings.Repeat(" ", padLeft) + hint
	}
	b.WriteString(hint)

	if absolute && startRow > 0 {
		b.WriteString(fmt.Sprintf("\x1b[%d;1H", startRow))
	} else {
		b.WriteString("\r")
	}
	tty.WriteString(b.String())
}

func clearBox(tty *os.File, absolute bool) {
	var b strings.Builder
	if absolute && startRow > 0 {
		b.WriteString(fmt.Sprintf("\x1b[%d;1H\x1b[J", startRow))
	} else {
		b.WriteString("\x1b[J")
	}
	tty.WriteString(b.String())
}

func queryCursorRow(tty *os.File) int {
	fd := int(tty.Fd())
	var orig syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCGETS, uintptr(unsafe.Pointer(&orig)))
	if errno != 0 {
		return 0
	}

	drain := orig
	drain.Cc[syscall.VMIN] = 0
	drain.Cc[syscall.VTIME] = 0
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&drain)))
	if errno != 0 {
		return 0
	}
	var drainBuf [256]byte
	for {
		n, _ := syscall.Read(fd, drainBuf[:])
		if n <= 0 {
			break
		}
	}

	if _, err := tty.Write([]byte("\x1b[6n")); err != nil {
		_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&orig)))
		return 0
	}

	timed := orig
	timed.Cc[syscall.VMIN] = 0
	timed.Cc[syscall.VTIME] = 2 // 200ms timeout
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&timed)))
	if errno != 0 {
		return 0
	}
	defer func() {
		_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&orig)))
	}()

	var buf [32]byte
	n, _ := syscall.Read(fd, buf[:])
	if n == 0 {
		return 0
	}

	resp := buf[:n]
	for i := 0; i+2 < len(resp); i++ {
		if resp[i] == 27 && resp[i+1] == '[' {
			i += 2
			row := 0
			for i < len(resp) && resp[i] >= '0' && resp[i] <= '9' {
				row = row*10 + int(resp[i]-'0')
				i++
			}
			if i < len(resp) && resp[i] == ';' {
				return row
			}
		}
	}
	return 0
}

func rawMode(fd int) (syscall.Termios, error) {
	var orig syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCGETS, uintptr(unsafe.Pointer(&orig)))
	if errno != 0 {
		return orig, errno
	}
	raw := orig
	raw.Iflag &^= syscall.IXON | syscall.ICRNL | syscall.BRKINT | syscall.INPCK | syscall.ISTRIP
	raw.Oflag &^= syscall.OPOST
	raw.Cflag |= syscall.CS8
	raw.Lflag &^= syscall.ECHO | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	raw.Cc[syscall.VMIN] = 0
	raw.Cc[syscall.VTIME] = 1
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&raw)))
	if errno != 0 {
		return orig, errno
	}
	return orig, nil
}

func restoreMode(fd int, orig syscall.Termios) {
	syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&orig)))
}

func main() {
	heightFlag := flag.Int("H", 10, "reserved box height in rows")
	durationFlag := flag.Duration("d", 0, "auto-exit after this duration, e.g. 2s (0 = run until 'q'/Ctrl-C)")
	debounceFlag := flag.Duration("b", 350*time.Millisecond, "resize debounce before redraw")
	minColsFlag := flag.Int("c", 40, "minimum columns before showing the \"too small\" hint")
	minRowsFlag := flag.Int("m", 0, "minimum rows before \"too small\" (0 = height+2)")
	relativeFlag := flag.Bool("r", false, "force relative cursor positioning (skip the CPR/absolute path)")
	demoFlag := flag.Bool("D", true, "print demo content to stdout on setup/teardown to test inline behaviour")
	flag.Parse()

	boxHeight = *heightFlag
	if boxHeight < 3 {
		boxHeight = 3
	}
	minCols := *minColsFlag
	minRows := *minRowsFlag
	if minRows <= 0 {
		minRows = boxHeight + 2
	}
	useAbsolute := !*relativeFlag

	// Setup demo content — printed to stdout BEFORE any terminal-state change
	// (raw mode, space reservation). It should end up in scrollback above the box.
	if *demoFlag {
		printDemo(os.Stdout, fmt.Sprintf("SETUP · stdout · before raw mode (height=%d, absolute=%v)", boxHeight, useAbsolute))
	}

	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot open /dev/tty:", err)
		os.Exit(1)
	}
	defer tty.Close()

	// Teardown demo content — printed to stdout AFTER the terminal state is
	// restored. Registered before the restore defer so (LIFO) it runs after it.
	if *demoFlag {
		defer func() { printDemo(os.Stdout, "TEARDOWN · stdout · after restore") }()
	}

	orig, err := rawMode(int(tty.Fd()))
	if err != nil {
		fmt.Fprintln(os.Stderr, "raw mode failed:", err)
		os.Exit(1)
	}
	defer func() {
		restoreMode(int(tty.Fd()), orig)
		fmt.Fprint(tty, cursorShow+wrapOn)
	}()

	// Reserve vertical space for the TUI
	for i := 0; i < boxHeight-1; i++ {
		tty.WriteString("\n")
	}
	tty.WriteString(cursorUp(boxHeight - 1))
	tty.WriteString(wrapOff + cursorHide)

	if useAbsolute {
		startRow = queryCursorRow(tty)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGWINCH)
	defer signal.Stop(sigChan)

	quit := make(chan struct{})
	cprChan := make(chan int, 1)

	go func() {
		buf := make([]byte, 32)
		for {
			n, _ := tty.Read(buf)
			if n > 0 {
				b := buf[:n]
				// Check for quit
				for _, c := range b {
					if c == 'q' || c == 3 {
						close(quit)
						return
					}
				}
				// Check for CPR: \x1b[Row;ColR
				if b[0] == 27 && n >= 3 && b[1] == '[' {
					s := string(b[2:])
					if idx := strings.Index(s, "R"); idx >= 0 {
						parts := strings.Split(s[:idx], ";")
						if len(parts) > 0 && parts[0] != "" {
							isDigit := true
							for _, c := range parts[0] {
								if c < '0' || c > '9' {
									isDigit = false
									break
								}
							}
							if isDigit {
								if r, err := strconv.Atoi(parts[0]); err == nil {
									select {
									case cprChan <- r:
									default:
									}
								}
							}
						}
					}
				}
			}
		}
	}()

	tuiVisible := false
	st := &stats{boxHeight: boxHeight, absolute: useAbsolute}

	// redraw paints the current frame and marks the TUI visible. It uses
	// absolute positioning only when we have a known start row (the CPR path);
	// in -relative mode startRow stays 0 so every draw takes the relative path.
	// ev labels what triggered this draw, so it shows up in the digest.
	redraw := func(ev string) {
		rows, cols := termSize(tty.Fd())
		st.redraws++
		st.startRow = startRow
		st.cols, st.rows = cols, rows
		st.lastEvent = ev
		if cols < minCols || rows < minRows {
			drawTooSmall(tty, cols, rows, startRow > 0)
		} else {
			drawBox(tty, cols, rows, startRow > 0, st)
		}
		tuiVisible = true
	}

	// Draw initial frame
	redraw("init")

	// Optional auto-exit deadline for non-interactive/headless testing.
	var deadlineChan <-chan time.Time
	if *durationFlag > 0 {
		deadlineChan = time.After(*durationFlag)
	}

	var resizeTimer *time.Timer
	var resizeTimerChan <-chan time.Time

	for {
		select {
		case <-quit:
			if tuiVisible {
				clearBox(tty, startRow > 0)
			}
			return
		case <-deadlineChan:
			if tuiVisible {
				clearBox(tty, startRow > 0)
			}
			return
		case <-sigChan:
			st.winches++
			if tuiVisible {
				clearBox(tty, false) // Always clear relatively on resize to align with reflowed cursor!
				tuiVisible = false
			}

			if resizeTimer != nil {
				resizeTimer.Stop()
			}
			resizeTimer = time.NewTimer(*debounceFlag)
			resizeTimerChan = resizeTimer.C

		case <-resizeTimerChan:
			resizeTimerChan = nil
			if useAbsolute {
				// Query the new cursor row; the CPR response triggers the redraw.
				tty.Write([]byte("\x1b[6n"))
			} else {
				// No CPR in relative mode — redraw directly or the box vanishes.
				redraw("rsz")
			}

		case r := <-cprChan:
			startRow = r
			redraw("cpr")
		}
	}
}
