//go:build windows

package lib

import "syscall"

// purego's Dlopen is a POSIX interface; on Windows the loader is reached through the stdlib and
// the module handle it returns is what purego.RegisterFunc wants anyway.
func openLibrary(path string) (uintptr, error) {
	h, err := syscall.LoadLibrary(path)
	if err != nil {
		return 0, err
	}
	return uintptr(h), nil
}

func symbol(handle uintptr, name string) (uintptr, error) {
	addr, err := syscall.GetProcAddress(syscall.Handle(handle), name)
	if err != nil {
		return 0, err
	}
	if addr == 0 {
		return 0, errNoSymbol
	}
	return addr, nil
}
