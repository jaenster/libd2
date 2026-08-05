package pathfinding

import (
	"sync"
	"unsafe"

	"github.com/libd2/go/internal/lib"
)

// abiVersion is the d2pf C ABI these bindings were written against.
const abiVersion = 1

// cOptions mirrors D2PfOptions exactly, which is why it is not the type callers see: Options
// spells the same settings with Go types, and this is what it converts into.
type cOptions struct {
	mask                 uint16
	teleport             int32
	teleportAcrossLevels int32
	teleportMaxCast      int32
	teleportMetric       int32
	snapRadius           int32
}

type api struct {
	abiVersion func() uint32

	optionsDefault func(out unsafe.Pointer)

	worldCreate  func(drlgCore uintptr, seed uint32, difficulty int32) uintptr
	worldDestroy func(world uintptr)
	worldLoadAct func(world uintptr, actNo int32) int32

	route     func(world uintptr, fromLevel, fromX, fromY, toLevel, toX, toY int32, opts unsafe.Pointer) uintptr
	routeFree func(route uintptr)

	routeLegCount  func(route uintptr) int32
	routeMoveCount func(route uintptr) int32
	routeLegLevel  func(route uintptr, leg int32) int32
	routeLegExit   func(route uintptr, leg int32) int32
	routeLegMoves  func(route uintptr, leg int32, out unsafe.Pointer, capacity int32) int32

	levelRoute      func(world uintptr, from, to int32, out unsafe.Pointer, capacity int32) int32
	walkable        func(world uintptr, levelID, x, y int32) int32
	lineOfSight     func(world uintptr, levelID, fromX, fromY, toX, toY int32, mask uint16) int32
	nearestPassable func(world uintptr, levelID, x, y, radius int32, outX, outY *int32) int32
}

var (
	loadOnce sync.Once
	loaded   *api
	loadErr  error
)

func load() (*api, error) {
	loadOnce.Do(func() {
		l, err := lib.Open("d2pf")
		if err != nil {
			loadErr = err
			return
		}
		a := &api{}
		binds := []struct {
			fn  any
			sym string
		}{
			{&a.abiVersion, "d2pf_abi_version"},
			{&a.optionsDefault, "d2pf_options_default"},
			{&a.worldCreate, "d2pf_world_create"},
			{&a.worldDestroy, "d2pf_world_destroy"},
			{&a.worldLoadAct, "d2pf_world_load_act"},
			{&a.route, "d2pf_route"},
			{&a.routeFree, "d2pf_route_free"},
			{&a.routeLegCount, "d2pf_route_leg_count"},
			{&a.routeMoveCount, "d2pf_route_move_count"},
			{&a.routeLegLevel, "d2pf_route_leg_level"},
			{&a.routeLegExit, "d2pf_route_leg_exit"},
			{&a.routeLegMoves, "d2pf_route_leg_moves"},
			{&a.levelRoute, "d2pf_level_route"},
			{&a.walkable, "d2pf_walkable"},
			{&a.lineOfSight, "d2pf_line_of_sight"},
			{&a.nearestPassable, "d2pf_nearest_passable"},
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
