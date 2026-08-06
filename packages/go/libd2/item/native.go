package item

import (
	"sync"
	"unsafe"

	"github.com/libd2/go/internal/lib"
)

// abiVersion is the d2item C ABI these bindings were written against.
const abiVersion = 2

type api struct {
	abiVersion func() uint32
	create     func() uintptr
	destroy    func(ctx uintptr)
	// tc crosses as a Go string: purego passes it as a NUL-terminated char*, which is what the
	// entry point documents.
	roll func(ctx uintptr, seed uint32, tc string, mlvl, mf int32, out unsafe.Pointer, capacity int32) int32
}

var (
	loadOnce sync.Once
	loaded   *api
	loadErr  error
)

func load() (*api, error) {
	loadOnce.Do(func() {
		l, err := lib.Open("d2item")
		if err != nil {
			loadErr = err
			return
		}
		a := &api{}
		binds := []struct {
			fn  any
			sym string
		}{
			{&a.abiVersion, "d2item_abi_version"},
			{&a.create, "d2item_create"},
			{&a.destroy, "d2item_destroy"},
			{&a.roll, "d2item_roll"},
		}
		for _, b := range binds {
			if err := lib.Bind(l, b.fn, b.sym); err != nil {
				loadErr = err
				return
			}
		}
		if err := lib.Verify(l, a.abiVersion(), abiVersion); err != nil {
			loadErr = err
			return
		}
		loaded = a
	})
	return loaded, loadErr
}
