// Package pathfinding routes over the worlds package drlg generates.
//
// It does not generate maps. A World is built on a running drlg.Generator and shares that
// generator's loaded tables, so routing runs over the very world it produced:
//
//	g, _ := drlg.New()
//	defer g.Close()
//
//	w, err := pathfinding.New(g, 1337, drlg.Normal)
//	if err != nil {
//		return err
//	}
//	defer w.Close()
//	w.LoadAct(0)
//
//	route, err := w.Route(pathfinding.Pos{Level: 1, X: 100, Y: 100},
//		pathfinding.Pos{Level: 3, X: 200, Y: 200}, nil)
//
// Every coordinate here is a LEVEL-LOCAL subtile, the frame drlg reports presets in. Levels are
// named by their Levels.txt id, which is stable across seeds.
//
// Part of libd2: https://github.com/jaenster/libd2 — the engine itself, what each subsystem is
// verified against, and the same C ABI from other languages. These bindings are generated from
// that repository; issues and pull requests belong there.
package pathfinding

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"github.com/libd2/go/drlg"
)

// ErrClosed is returned by every method of a World that has been closed.
var ErrClosed = errors.New("libd2/pathfinding: world is closed")

// World is the set of acts loaded for routing, with a collision map built per level.
//
// It borrows the generator's tables, so the generator has to outlive it. Calls are serialised;
// give each goroutine its own World to actually parallelise.
type World struct {
	mu    sync.Mutex
	api   *api
	world uintptr
	// gen is held so the generator cannot be collected while its tables are in use here.
	gen *drlg.Generator
}

// New builds a routing world over a generator's tables. Load the acts you intend to route
// across with LoadAct before routing.
func New(g *drlg.Generator, seed uint32, difficulty drlg.Difficulty) (*World, error) {
	if g == nil {
		return nil, errors.New("libd2/pathfinding: a generator is required")
	}
	a, err := load()
	if err != nil {
		return nil, err
	}
	core := g.Core()
	if core == 0 {
		return nil, drlg.ErrClosed
	}
	w := a.worldCreate(uintptr(core), seed, int32(difficulty))
	if w == 0 {
		return nil, fmt.Errorf("libd2/pathfinding: could not build a world for seed %d (%s)", seed, difficulty)
	}
	return &World{api: a, world: w, gen: g}, nil
}

// Close releases the world. Routes taken from it are plain Go data and outlive it. Safe to call
// more than once.
func (w *World) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world != 0 {
		w.api.worldDestroy(w.world)
		w.world = 0
	}
	return nil
}

// ABIVersion is the C ABI version of the native library in use.
func ABIVersion() (uint32, error) {
	a, err := load()
	if err != nil {
		return 0, err
	}
	return a.abiVersion(), nil
}

// LoadAct generates an act into the world and indexes its levels. act is 0-based: 0 is Act I.
func (w *World) LoadAct(act int) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return ErrClosed
	}
	if act < 0 || act > 4 {
		return fmt.Errorf("libd2/pathfinding: act is 0 (Act I) to 4 (Act V), got %d", act)
	}
	if rc := w.api.worldLoadAct(w.world, int32(act)); rc < 0 {
		return fmt.Errorf("libd2/pathfinding: loading act %d failed (%d)", act+1, rc)
	}
	return nil
}

// Route finds a way from one position to another, crossing levels as needed. opts may be nil for
// the engine defaults.
//
// A nil Route with a nil error is an answer, not a failure: some pairs genuinely are not
// connected.
func (w *World) Route(from, to Pos, opts *Options) (*Route, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return nil, ErrClosed
	}

	var (
		cOpts cOptions
		cPtr  unsafe.Pointer
	)
	if opts != nil {
		cOpts = opts.toC()
		cPtr = unsafe.Pointer(&cOpts)
	}

	handle := w.api.route(w.world, from.Level, from.X, from.Y, to.Level, to.X, to.Y, cPtr)
	runtime.KeepAlive(cOpts)
	if handle == 0 {
		return nil, nil
	}
	defer w.api.routeFree(handle)

	legCount := w.api.routeLegCount(handle)
	if legCount < 0 {
		return nil, fmt.Errorf("libd2/pathfinding: reading the route's leg count failed (%d)", legCount)
	}

	r := &Route{Legs: make([]Leg, 0, legCount)}
	for i := int32(0); i < legCount; i++ {
		moves, err := readMoves(w.api, handle, i)
		if err != nil {
			return nil, err
		}
		r.Legs = append(r.Legs, Leg{
			Level: w.api.routeLegLevel(handle, i),
			Exit:  w.api.routeLegExit(handle, i),
			Moves: moves,
		})
	}
	return r, nil
}

// LevelRoute is the level graph only: which levels a trip crosses, without pathing inside any of
// them. Cheap enough to call in a loop.
func (w *World) LevelRoute(from, to int32) ([]int32, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return nil, ErrClosed
	}
	n := w.api.levelRoute(w.world, from, to, nil, 0)
	if n < 0 {
		return nil, fmt.Errorf("libd2/pathfinding: routing level %d to %d failed (%d)", from, to, n)
	}
	if n == 0 {
		return nil, nil
	}
	buf := make([]int32, n)
	got := w.api.levelRoute(w.world, from, to, unsafe.Pointer(&buf[0]), n)
	runtime.KeepAlive(buf)
	if got < 0 {
		return nil, fmt.Errorf("libd2/pathfinding: routing level %d to %d failed (%d)", from, to, got)
	}
	if got > n {
		return nil, fmt.Errorf("libd2/pathfinding: the level route %d to %d grew from %d to %d between calls",
			from, to, n, got)
	}
	return buf[:got], nil
}

// Walkable reports whether a walking player fits at a level-local subtile.
func (w *World) Walkable(level, x, y int32) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return false
	}
	return w.api.walkable(w.world, level, x, y) == 1
}

// LineOfSight reports whether sight runs between two level-local subtiles. mask selects what
// blocks it; pass 0 for what the engine uses for a cast.
func (w *World) LineOfSight(level, fromX, fromY, toX, toY int32, mask uint16) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return false
	}
	return w.api.lineOfSight(w.world, level, fromX, fromY, toX, toY, mask) == 1
}

// NearestPassable is the closest cell to (x, y) a walking player fits in, searched outward to
// radius. ok is false when nothing within radius is passable.
//
// This is what to call before routing to a spot that may be inside a wall — a monster's reported
// position often is.
func (w *World) NearestPassable(level, x, y, radius int32) (nx, ny int32, ok bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return 0, 0, false
	}
	var ox, oy int32
	if w.api.nearestPassable(w.world, level, x, y, radius, &ox, &oy) != 1 {
		return 0, 0, false
	}
	return ox, oy, true
}

func readMoves(a *api, route uintptr, leg int32) ([]Move, error) {
	n := a.routeLegMoves(route, leg, nil, 0)
	if n < 0 {
		return nil, fmt.Errorf("libd2/pathfinding: reading the moves of leg %d failed (%d)", leg, n)
	}
	if n == 0 {
		return nil, nil
	}
	buf := make([]Move, n)
	got := a.routeLegMoves(route, leg, unsafe.Pointer(&buf[0]), n)
	runtime.KeepAlive(buf)
	if got < 0 {
		return nil, fmt.Errorf("libd2/pathfinding: reading the moves of leg %d failed (%d)", leg, got)
	}
	if got > n {
		return nil, fmt.Errorf("libd2/pathfinding: leg %d grew from %d to %d moves between calls", leg, n, got)
	}
	return buf[:got], nil
}

// UnitType is eD2UnitType: which kind of game object a unit is. It decides, together with the
// unit's size, which cells the unit claims in the collision grid and with which bit — exactly as
// the engine decides it when it allocates the unit's path.
type UnitType uint8

const (
	UnitPlayer   UnitType = 0
	UnitMonster  UnitType = 1
	UnitObject   UnitType = 2
	UnitMissile  UnitType = 3
	UnitItem     UnitType = 4
	UnitRoomTile UnitType = 5
)

// PlaceUnit puts a unit on a level, or moves one already there.
//
// Everything the world answers — Walkable, Route, LineOfSight, NearestPassable — sees it from the
// next call on. A monster standing in a doorway makes that doorway impassable, because that is
// what it does in the game.
//
// sizeX is the unit's GetUnitSizeX (0..3): 0 claims nothing, 1 and 2 claim a cross, 3 a 3x3 box.
// Calling it again for an id already placed MOVES that unit — the cells it used to cover go back
// to what the rest of the world says about them.
func (w *World) PlaceUnit(level int32, unitID uint32, t UnitType, sizeX, x, y int32) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return ErrClosed
	}
	if rc := w.api.unitPlace(w.world, level, unitID, uint8(t), sizeX, x, y); rc != 0 {
		return fmt.Errorf("libd2/pathfinding: placing unit %d on level %d failed (%d)", unitID, level, rc)
	}
	return nil
}

// RemoveUnit takes a unit off a level, restoring every cell it covered.
func (w *World) RemoveUnit(level int32, unitID uint32) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return ErrClosed
	}
	if rc := w.api.unitLift(w.world, level, unitID); rc != 0 {
		return fmt.Errorf("libd2/pathfinding: remove unit failed (%d)", rc)
	}
	return nil
}

// ClearUnits empties a level of everything standing on it, leaving terrain alone.
func (w *World) ClearUnits(level int32) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return ErrClosed
	}
	if rc := w.api.unitsClear(w.world, level); rc != 0 {
		return fmt.Errorf("libd2/pathfinding: clear units failed (%d)", rc)
	}
	return nil
}

// EditTerrain changes the map itself over an inclusive subtile rectangle: a door opens, a quest
// barrier drops. add and remove are raw collision-bit masks (0x01 wall, 0x800 door, ...).
//
// This is not the same thing as placing a unit, and it is far more expensive: it rewrites the
// generated grid and throws away the reachability caches built on it, because unlike a unit it can
// make a cell MORE passable and so join two regions that were separate. Use it for the handful of
// events per game that really change the map; use PlaceUnit for everything that merely stands on
// it.
func (w *World) EditTerrain(level, x0, y0, x1, y1 int32, add, remove uint16) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.world == 0 {
		return ErrClosed
	}
	if rc := w.api.terrainEdit(w.world, level, x0, y0, x1, y1, add, remove); rc != 0 {
		return fmt.Errorf("libd2/pathfinding: edit terrain failed (%d)", rc)
	}
	return nil
}
