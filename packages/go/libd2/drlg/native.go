package drlg

import (
	"sync"
	"unsafe"

	"github.com/libd2/go/internal/lib"
)

// abiVersion is the d2drlg C ABI these bindings were written against. A library reporting
// anything else is refused by New rather than called into.
const abiVersion = 3

// api is the bound C entry points. Buffers cross as unsafe.Pointer and out-parameters as *int32,
// which is the whole vocabulary this ABI uses: no floats, no by-value structs, no callbacks.
type api struct {
	abiVersion func() uint32

	ctxCreate  func() uintptr
	ctxCore    func(ctx uintptr) uintptr
	ctxDestroy func(ctx uintptr)

	genAct  func(ctx uintptr, seed uint32, difficulty, actNo int32) uintptr
	actFree func(act uintptr)

	actLevelCount     func(act uintptr) int32
	actLevelID        func(act uintptr, index int32) int32
	actLevelType      func(act uintptr, index int32) int32
	actLevelPlaced    func(act uintptr, index int32) int32
	actLevelRoomCount func(act uintptr, index int32) int32

	actRooms          func(act uintptr, index int32, out unsafe.Pointer, capacity int32) int32
	actLevelOrigin    func(act uintptr, index int32, ox, oy *int32) int32
	actLevelSize      func(act uintptr, index int32, w, h *int32) int32
	actLevelPresets   func(act uintptr, index int32, out unsafe.Pointer, capacity int32) int32
	actLevelAdjacents func(act uintptr, index int32, out unsafe.Pointer, capacity int32) int32
	actLevelCollision func(act uintptr, index int32, out unsafe.Pointer, capacity int32, w, h *int32) int32
	actLevelWalk      func(act uintptr, index int32, out unsafe.Pointer, capacity int32, w, h *int32) int32

	levelName func(ctx uintptr, levelID int32, buf unsafe.Pointer, capacity int32) int32

	objectName func(txtFileNo int32, buf unsafe.Pointer, capacity int32) int32
	objectDesc func(txtFileNo int32, buf unsafe.Pointer, capacity int32) int32
}

var (
	loadOnce sync.Once
	loaded   *api
	loadErr  error
)

// load opens libd2drlg and binds every symbol, once per process. The whole table is bound up
// front rather than lazily so a mismatched library fails at New, not halfway through a
// generation.
func load() (*api, error) {
	loadOnce.Do(func() {
		l, err := lib.Open("d2drlg")
		if err != nil {
			loadErr = err
			return
		}
		a := &api{}
		binds := []struct {
			fn  any
			sym string
		}{
			{&a.abiVersion, "d2drlg_abi_version"},
			{&a.ctxCreate, "d2drlg_ctx_create"},
			{&a.ctxCore, "d2drlg_ctx_core"},
			{&a.ctxDestroy, "d2drlg_ctx_destroy"},
			{&a.genAct, "d2drlg_gen_act"},
			{&a.actFree, "d2drlg_act_free"},
			{&a.actLevelCount, "d2drlg_act_level_count"},
			{&a.actLevelID, "d2drlg_act_level_id"},
			{&a.actLevelType, "d2drlg_act_level_drlg_type"},
			{&a.actLevelPlaced, "d2drlg_act_level_placed"},
			{&a.actLevelRoomCount, "d2drlg_act_level_room_count"},
			{&a.actRooms, "d2drlg_act_rooms"},
			{&a.actLevelOrigin, "d2drlg_act_level_origin"},
			{&a.actLevelSize, "d2drlg_act_level_size"},
			{&a.actLevelPresets, "d2drlg_act_level_presets"},
			{&a.actLevelAdjacents, "d2drlg_act_level_adjacents"},
			{&a.actLevelCollision, "d2drlg_act_level_collision"},
			{&a.actLevelWalk, "d2drlg_act_level_walk"},
			{&a.levelName, "d2drlg_level_name"},
			{&a.objectName, "d2drlg_object_name"},
			{&a.objectDesc, "d2drlg_object_desc"},
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
