// Package drlg generates Diablo II 1.14d worlds from a seed.
//
// Give it a seed and it produces the same world the game does: every level of an act, its rooms,
// the npcs, objects and exits placed in them, and optionally the subtile collision grid.
//
//	g, err := drlg.New()
//	if err != nil {
//		return err
//	}
//	defer g.Close()
//
//	act, err := g.GenerateAct(1337, drlg.Normal, 0)
//	for _, l := range act.Levels {
//		fmt.Printf("%s: %d rooms\n", l.Name, len(l.Rooms))
//	}
//
// The native library is bound with purego, so nothing here needs cgo and cross-compiling a
// consumer works normally. See package doc of internal/lib for where the binary comes from.
//
// Part of libd2: https://github.com/jaenster/libd2 — the engine itself, what each subsystem is
// verified against, and the same C ABI from other languages. These bindings are generated from
// that repository; issues and pull requests belong there.
package drlg

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"github.com/libd2/go/internal/core"
)

// ErrClosed is returned by every method of a Generator that has been closed.
var ErrClosed = errors.New("libd2/drlg: generator is closed")

// Generator owns the loaded game tables, which are the expensive part of generating anything.
// Keep one and reuse it rather than creating one per call.
//
// Calls are serialised: the native context is single-threaded, so a Generator shared between
// goroutines is safe but not concurrent. Give each goroutine its own to actually parallelise.
type Generator struct {
	mu    sync.Mutex
	api   *api
	ctx   uintptr
	names map[int32]string
}

// New loads the game tables. Close it when you are done with them.
func New() (*Generator, error) {
	a, err := load()
	if err != nil {
		return nil, err
	}
	ctx := a.ctxCreate()
	if ctx == 0 {
		return nil, errors.New("libd2/drlg: could not load the game tables")
	}
	return &Generator{api: a, ctx: ctx, names: map[int32]string{}}, nil
}

// Close releases the game tables. It is safe to call more than once.
func (g *Generator) Close() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.ctx != 0 {
		g.api.ctxDestroy(g.ctx)
		g.ctx = 0
	}
	return nil
}

// Core returns the loaded tables for a sibling subsystem to route over. It is deliberately
// typed so that only packages inside this module can name it.
func (g *Generator) Core() core.Ptr {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.ctx == 0 {
		return 0
	}
	return core.Ptr(g.api.ctxCore(g.ctx))
}

// ABIVersion is the C ABI version of the native library in use.
func ABIVersion() (uint32, error) {
	a, err := load()
	if err != nil {
		return 0, err
	}
	return a.abiVersion(), nil
}

type options struct {
	collision bool
	walk      bool
}

// Option changes what GenerateAct copies out.
type Option func(*options)

// WithCollision also copies every level's raw subtile collision grid. Off by default: a whole
// act's worth is tens of megabytes.
func WithCollision() Option { return func(o *options) { o.collision = true } }

// WithWalk also copies every level's derived walkability grid — one byte per subtile, ready to
// path on. Off by default for the same reason as WithCollision.
func WithWalk() Option { return func(o *options) { o.walk = true } }

// GenerateAct generates every level of one act. act is 0-based, as the engine numbers them:
// 0 is Act I, 4 is Act V.
//
// Everything is copied out before this returns and the native handle is released, so the Act is
// ordinary Go data with no lifetime attached to the Generator.
func (g *Generator) GenerateAct(seed uint32, difficulty Difficulty, act int, opts ...Option) (*Act, error) {
	if act < 0 || act > 4 {
		return nil, fmt.Errorf("libd2/drlg: act is 0 (Act I) to 4 (Act V), got %d", act)
	}
	var o options
	for _, fn := range opts {
		fn(&o)
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	if g.ctx == 0 {
		return nil, ErrClosed
	}

	handle := g.api.genAct(g.ctx, seed, int32(difficulty), int32(act))
	if handle == 0 {
		return nil, fmt.Errorf("libd2/drlg: generating act %d for seed %d (%s) failed", act+1, seed, difficulty)
	}
	defer g.api.actFree(handle)

	count := g.api.actLevelCount(handle)
	if count < 0 {
		return nil, fmt.Errorf("libd2/drlg: reading the level count of act %d failed (%d)", act+1, count)
	}

	levels := make([]Level, 0, count)
	for i := int32(0); i < count; i++ {
		l, err := g.readLevel(handle, i, o)
		if err != nil {
			return nil, err
		}
		levels = append(levels, l)
	}
	return &Act{Seed: seed, Difficulty: difficulty, Number: act, Levels: levels}, nil
}

func (g *Generator) readLevel(handle uintptr, index int32, o options) (Level, error) {
	id := g.api.actLevelID(handle, index)

	var ox, oy, w, h int32
	if rc := g.api.actLevelOrigin(handle, index, &ox, &oy); rc < 0 {
		return Level{}, fmt.Errorf("libd2/drlg: reading the origin of level index %d failed (%d)", index, rc)
	}
	if rc := g.api.actLevelSize(handle, index, &w, &h); rc < 0 {
		return Level{}, fmt.Errorf("libd2/drlg: reading the size of level index %d failed (%d)", index, rc)
	}

	rooms, err := readSlice[Room]("rooms", index, func(out unsafe.Pointer, capacity int32) int32 {
		return g.api.actRooms(handle, index, out, capacity)
	})
	if err != nil {
		return Level{}, err
	}
	presets, err := readSlice[PresetUnit]("presets", index, func(out unsafe.Pointer, capacity int32) int32 {
		return g.api.actLevelPresets(handle, index, out, capacity)
	})
	if err != nil {
		return Level{}, err
	}
	adjacents, err := readSlice[Adjacent]("adjacents", index, func(out unsafe.Pointer, capacity int32) int32 {
		return g.api.actLevelAdjacents(handle, index, out, capacity)
	})
	if err != nil {
		return Level{}, err
	}

	l := Level{
		ID:        id,
		Name:      g.levelName(id),
		Type:      Type(g.api.actLevelType(handle, index)),
		Placed:    g.api.actLevelPlaced(handle, index) == 1,
		OriginX:   ox,
		OriginY:   oy,
		Width:     w,
		Height:    h,
		Rooms:     rooms,
		Presets:   presets,
		Adjacents: adjacents,
	}

	if o.collision {
		cells, cw, ch, err := readGrid[uint16]("collision", index, func(out unsafe.Pointer, capacity int32, gw, gh *int32) int32 {
			return g.api.actLevelCollision(handle, index, out, capacity, gw, gh)
		})
		if err != nil {
			return Level{}, err
		}
		if cells != nil {
			l.Collision = &Collision{Width: cw, Height: ch, Cells: cells}
		}
	}
	if o.walk {
		cells, cw, ch, err := readGrid[uint8]("walk", index, func(out unsafe.Pointer, capacity int32, gw, gh *int32) int32 {
			return g.api.actLevelWalk(handle, index, out, capacity, gw, gh)
		})
		if err != nil {
			return Level{}, err
		}
		if cells != nil {
			l.Walk = &Walk{Width: cw, Height: ch, Cells: cells}
		}
	}
	return l, nil
}

// levelName caches Levels.txt lookups: an act asks for a few dozen names and the string comes
// back through two calls each time.
func (g *Generator) levelName(id int32) string {
	if n, ok := g.names[id]; ok {
		return n
	}
	n := readString(func(buf unsafe.Pointer, capacity int32) int32 {
		return g.api.levelName(g.ctx, id, buf, capacity)
	})
	g.names[id] = n
	return n
}

// ObjectName is an Objects.txt row's name, for the TxtFileNo of an Object preset unit.
func ObjectName(txtFileNo int32) (string, error) {
	a, err := load()
	if err != nil {
		return "", err
	}
	return readString(func(buf unsafe.Pointer, capacity int32) int32 {
		return a.objectName(txtFileNo, buf, capacity)
	}), nil
}

// ObjectDesc is an Objects.txt row's description column.
func ObjectDesc(txtFileNo int32) (string, error) {
	a, err := load()
	if err != nil {
		return "", err
	}
	return readString(func(buf unsafe.Pointer, capacity int32) int32 {
		return a.objectDesc(txtFileNo, buf, capacity)
	}), nil
}

// readSlice asks for the count first, then the data.
//
// Every list entry point reports the FULL count even when it wrote nothing, which is what makes
// a zero-capacity probe safe: the native side clamps its copy loop to the capacity, so a nil
// buffer is never touched. The element types are all plain int32 fields laid out to match their
// C structs, so the second call fills the Go slice in place with no marshalling.
func readSlice[T any](what string, index int32, call func(out unsafe.Pointer, capacity int32) int32) ([]T, error) {
	n := call(nil, 0)
	if n < 0 {
		return nil, fmt.Errorf("libd2/drlg: reading %s of level index %d failed (%d)", what, index, n)
	}
	if n == 0 {
		return nil, nil
	}
	buf := make([]T, n)
	got := call(unsafe.Pointer(&buf[0]), n)
	runtime.KeepAlive(buf)
	if got < 0 {
		return nil, fmt.Errorf("libd2/drlg: reading %s of level index %d failed (%d)", what, index, got)
	}
	if got > n {
		return nil, fmt.Errorf("libd2/drlg: %s of level index %d grew from %d to %d between calls", what, index, n, got)
	}
	return buf[:got], nil
}

// readGrid is readSlice for the two-dimensional grids, which report their dimensions through
// out-parameters on every call — including the probe, so the capacity is known before the
// allocation.
func readGrid[T any](what string, index int32, call func(out unsafe.Pointer, capacity int32, w, h *int32) int32) ([]T, int32, int32, error) {
	var w, h int32
	n := call(nil, 0, &w, &h)
	if n < 0 {
		return nil, 0, 0, fmt.Errorf("libd2/drlg: reading the %s grid of level index %d failed (%d)", what, index, n)
	}
	if n == 0 {
		return nil, 0, 0, nil
	}
	buf := make([]T, n)
	got := call(unsafe.Pointer(&buf[0]), n, &w, &h)
	runtime.KeepAlive(buf)
	if got < 0 {
		return nil, 0, 0, fmt.Errorf("libd2/drlg: reading the %s grid of level index %d failed (%d)", what, index, got)
	}
	if got > n {
		return nil, 0, 0, fmt.Errorf("libd2/drlg: the %s grid of level index %d grew from %d to %d between calls", what, index, n, got)
	}
	return buf[:got], w, h, nil
}

// readString reads a NUL-terminating string entry point: probe for the length, then fetch. The
// returned length excludes the terminator, so the buffer is one byte longer than it.
func readString(call func(buf unsafe.Pointer, capacity int32) int32) string {
	n := call(nil, 0)
	if n <= 0 {
		return ""
	}
	buf := make([]byte, n+1)
	got := call(unsafe.Pointer(&buf[0]), int32(len(buf)))
	runtime.KeepAlive(buf)
	if got < 0 {
		return ""
	}
	if got > n {
		got = n
	}
	return string(buf[:got])
}
