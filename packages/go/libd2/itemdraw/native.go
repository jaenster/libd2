package itemdraw

import (
	"sync"
	"unsafe"

	"github.com/libd2/go/internal/lib"
)

// abiVersion is the d2itemdraw C ABI these bindings were written against.
const abiVersion = 1

type api struct {
	abiVersion  func() uint32
	alloc       func(n uintptr) uintptr
	free        func(p uintptr, n uintptr)
	create      func() uintptr
	destroy     func(ctx uintptr)
	addArchive  func(ctx uintptr, bytes uintptr, n uintptr) int32
	addFile     func(ctx uintptr, name string, bytes unsafe.Pointer, n uintptr) int32
	text        func(ctx uintptr, records unsafe.Pointer, n uintptr, opts unsafe.Pointer, mode int32, out unsafe.Pointer, cap uintptr) int32
	icon        func(ctx uintptr, records unsafe.Pointer, n uintptr, opts unsafe.Pointer, background, sockets int32) uintptr
	tooltip     func(ctx uintptr, records unsafe.Pointer, n uintptr, opts unsafe.Pointer) uintptr
	card        func(ctx uintptr, records unsafe.Pointer, n uintptr, opts unsafe.Pointer) uintptr
	imageWidth  func(img uintptr) uint32
	imageHeight func(img uintptr) uint32
	imageRGBA   func(img uintptr) uintptr
	imagePNG    func(img uintptr, outLen unsafe.Pointer) uintptr
	imageFree   func(img uintptr)
}

var (
	loadOnce sync.Once
	loaded   *api
	loadErr  error
)

func load() (*api, error) {
	loadOnce.Do(func() {
		l, err := lib.Open("d2itemdraw")
		if err != nil {
			loadErr = err
			return
		}
		a := &api{}
		binds := []struct {
			fn  any
			sym string
		}{
			{&a.abiVersion, "d2itemdraw_abi_version"},
			{&a.alloc, "d2itemdraw_alloc"},
			{&a.free, "d2itemdraw_free"},
			{&a.create, "d2itemdraw_create"},
			{&a.destroy, "d2itemdraw_destroy"},
			{&a.addArchive, "d2itemdraw_add_archive"},
			{&a.addFile, "d2itemdraw_add_file"},
			{&a.text, "d2itemdraw_text"},
			{&a.icon, "d2itemdraw_icon"},
			{&a.tooltip, "d2itemdraw_tooltip"},
			{&a.card, "d2itemdraw_card"},
			{&a.imageWidth, "d2itemdraw_image_width"},
			{&a.imageHeight, "d2itemdraw_image_height"},
			{&a.imageRGBA, "d2itemdraw_image_rgba"},
			{&a.imagePNG, "d2itemdraw_image_png"},
			{&a.imageFree, "d2itemdraw_image_free"},
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
