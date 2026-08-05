//go:build !windows

package lib

import "github.com/ebitengine/purego"

// RTLD_LOCAL, not GLOBAL: d2drlg and d2pf each statically link their own copy of the shared
// engine code, and making one of them global would let the dynamic linker interpose that copy's
// internals on the other. Keeping each library's non-exported symbols to itself avoids the
// question entirely — the two only ever meet through the context pointer we pass by hand.
func openLibrary(path string) (uintptr, error) {
	return purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_LOCAL)
}

func symbol(handle uintptr, name string) (uintptr, error) {
	addr, err := purego.Dlsym(handle, name)
	if err != nil {
		return 0, err
	}
	if addr == 0 {
		return 0, errNoSymbol
	}
	return addr, nil
}
