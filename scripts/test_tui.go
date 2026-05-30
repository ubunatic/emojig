package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

func main() {
	binaryPath := "./zig-out/bin/emojig"
	if _, err := os.Stat(binaryPath); os.IsNotExist(err) {
		fmt.Printf("Error: %s does not exist. Build the project first.\n", binaryPath)
		os.Exit(1)
	}

	fmt.Println("Spawning emojig in a pseudo-terminal (PTY) to test selection...")

	// 1. Open /dev/ptmx
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		fmt.Printf("Error opening /dev/ptmx: %v\n", err)
		os.Exit(1)
	}
	defer master.Close()

	// 2. Get slave PTY number (ptsname equivalent)
	var ptsNum uint32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&ptsNum)))
	if errno != 0 {
		fmt.Printf("Error getting PTY number: %v\n", errno)
		os.Exit(1)
	}

	// 3. Unlock the slave PTY (unlockpt equivalent)
	var unlock int
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock)))
	if errno != 0 {
		fmt.Printf("Error unlocking PTY: %v\n", errno)
		os.Exit(1)
	}

	slaveName := fmt.Sprintf("/dev/pts/%d", ptsNum)
	slave, err := os.OpenFile(slaveName, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Printf("Error opening slave PTY %s: %v\n", slaveName, err)
		os.Exit(1)
	}
	defer slave.Close()

	// 4. Start the command with PTY as stdin, stdout, stderr
	cmd := exec.Command(binaryPath, "--tui")
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
	}

	if err := cmd.Start(); err != nil {
		fmt.Printf("Error starting command: %v\n", err)
		os.Exit(1)
	}

	// Helper to read current buffer with timeout
	readBuf := make([]byte, 8192)
	readOutput := func() string {
		// Set non-blocking read
		syscall.SetNonblock(int(master.Fd()), true)
		defer syscall.SetNonblock(int(master.Fd()), false)

		time.Sleep(100 * time.Millisecond)
		n, err := master.Read(readBuf)
		if n > 0 {
			return string(readBuf[:n])
		}
		if err != nil && !os.IsPermission(err) {
			// Ignore read errors from closing PTY
		}
		return ""
	}

	// Wait for application to draw initial screen
	time.Sleep(200 * time.Millisecond)
	_ = readOutput()

	// 1. Send "fire"
	fmt.Println("Sending search keys: 'fire'...")
	_, err = master.Write([]byte("fire"))
	if err != nil {
		fmt.Printf("Error writing search key: %v\n", err)
		os.Exit(1)
	}

	time.Sleep(200 * time.Millisecond)
	_ = readOutput()

	// 2. Send ENTER key to copy and exit
	fmt.Println("Sending ENTER key to copy and exit...")
	_, err = master.Write([]byte("\n"))
	if err != nil {
		fmt.Printf("Error writing ENTER key: %v\n", err)
		os.Exit(1)
	}

	// Wait for program to exit
	exitChan := make(chan error, 1)
	go func() {
		exitChan <- cmd.Wait()
	}()

	select {
	case err := <-exitChan:
		if err != nil {
			fmt.Printf("Process exited with error: %v\n", err)
		} else {
			fmt.Println("Process exited cleanly.")
		}
	case <-time.After(2 * time.Second):
		fmt.Println("Process timed out and did not exit! Force killing...")
		cmd.Process.Kill()
		<-exitChan
		os.Exit(1)
	}

	// Read remaining output
	postOutput := readOutput()
	fmt.Println("--- POST-ENTER PTY BUFFER ---")
	fmt.Print(postOutput)
	fmt.Println("-----------------------------")
}
