//go:build linux && amd64

package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"syscall"
	"unsafe"
)

func main() {
	if len(os.Args) < 2 {
		panic("storage-filter requires a command")
	}
	path, err := exec.LookPath(os.Args[1])
	if err != nil {
		panic(err)
	}
	runtime.LockOSThread()
	const (
		sysSetns        = 308
		sysOpenTree     = 428
		sysMoveMount    = 429
		sysFsopen       = 430
		sysFsconfig     = 431
		sysFsmount      = 432
		sysFspick       = 433
		sysClone3       = 435
		sysMountSetattr = 442
		deny            = uint32(0x00050000 | syscall.EPERM)
	)
	filter := []syscall.SockFilter{
		{Code: syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, K: 4},
		{Code: syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, K: 0xc000003e, Jt: 1},
		{Code: syscall.BPF_RET | syscall.BPF_K, K: 0x80000000},
		{Code: syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, K: 0},
		{Code: syscall.BPF_JMP | syscall.BPF_JSET | syscall.BPF_K, K: 0x40000000, Jf: 1},
		{Code: syscall.BPF_RET | syscall.BPF_K, K: deny},
	}
	for _, number := range []uint32{
		syscall.SYS_MOUNT, syscall.SYS_UMOUNT2, syscall.SYS_UNSHARE, sysSetns,
		sysOpenTree, sysMoveMount, sysFsopen, sysFsconfig, sysFsmount, sysFspick, sysMountSetattr,
	} {
		filter = append(filter,
			syscall.SockFilter{Code: syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, K: number, Jf: 1},
			syscall.SockFilter{Code: syscall.BPF_RET | syscall.BPF_K, K: deny},
		)
	}
	filter = append(filter,
		syscall.SockFilter{Code: syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, K: sysClone3, Jf: 1},
		syscall.SockFilter{Code: syscall.BPF_RET | syscall.BPF_K, K: 0x00050000 | uint32(syscall.ENOSYS)},
		syscall.SockFilter{Code: syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, K: syscall.SYS_CLONE, Jf: 3},
		syscall.SockFilter{Code: syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, K: 16},
		syscall.SockFilter{Code: syscall.BPF_JMP | syscall.BPF_JSET | syscall.BPF_K, K: 0x7e020000, Jf: 1},
		syscall.SockFilter{Code: syscall.BPF_RET | syscall.BPF_K, K: deny},
		syscall.SockFilter{Code: syscall.BPF_RET | syscall.BPF_K, K: 0x7fff0000},
	)
	program := syscall.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}
	if _, _, errno := syscall.RawSyscall6(syscall.SYS_PRCTL, 38, 1, 0, 0, 0, 0); errno != 0 {
		panic(fmt.Errorf("no_new_privs: %w", errno))
	}
	if _, _, errno := syscall.RawSyscall6(syscall.SYS_PRCTL, 22, 2, uintptr(unsafe.Pointer(&program)), 0, 0, 0); errno != 0 {
		panic(fmt.Errorf("seccomp filter: %w", errno))
	}
	runtime.KeepAlive(filter)
	if err := syscall.Exec(path, os.Args[1:], os.Environ()); err != nil {
		panic(err)
	}
}
