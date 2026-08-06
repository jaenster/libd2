package pathfinding

import (
	"testing"
	"unsafe"

	"github.com/libd2/go/drlg"
)

const (
	testSeed = 0x10000000

	rogueEncampment     = 1
	bloodMoor           = 2
	coldPlains          = 3
	stonyField          = 4
	darkWood            = 5
	undergroundPassage1 = 10
)

// Move is filled by the native side in place and Options is passed to it, so both layouts are
// the ABI. These are what d2pf.h defines.
func TestStructLayout(t *testing.T) {
	if got, want := unsafe.Sizeof(Move{}), uintptr(12); got != want {
		t.Errorf("sizeof(Move) = %d, want %d", got, want)
	}
	if got, want := unsafe.Offsetof(Move{}.Kind), uintptr(8); got != want {
		t.Errorf("offsetof(Move.Kind) = %d, want %d", got, want)
	}
	if got, want := unsafe.Sizeof(cOptions{}), uintptr(24); got != want {
		t.Errorf("sizeof(cOptions) = %d, want %d", got, want)
	}
	for _, c := range []struct {
		field string
		got   uintptr
		want  uintptr
	}{
		{"mask", unsafe.Offsetof(cOptions{}.mask), 0},
		{"teleport", unsafe.Offsetof(cOptions{}.teleport), 4},
		{"teleportAcrossLevels", unsafe.Offsetof(cOptions{}.teleportAcrossLevels), 8},
		{"teleportMaxCast", unsafe.Offsetof(cOptions{}.teleportMaxCast), 12},
		{"teleportMetric", unsafe.Offsetof(cOptions{}.teleportMetric), 16},
		{"snapRadius", unsafe.Offsetof(cOptions{}.snapRadius), 20},
	} {
		if c.got != c.want {
			t.Errorf("offsetof(cOptions.%s) = %d, want %d", c.field, c.got, c.want)
		}
	}
}

func TestABIVersion(t *testing.T) {
	got, err := ABIVersion()
	if err != nil {
		t.Fatal(err)
	}
	if got != abiVersion {
		t.Fatalf("ABIVersion() = %d, want %d", got, abiVersion)
	}
}

// The defaults have to be what the engine itself uses, which is exactly why Options must never
// be built from a zero value: a zeroed struct means no collision mask and no cast limit.
func TestDefaultOptions(t *testing.T) {
	o, err := DefaultOptions()
	if err != nil {
		t.Fatal(err)
	}
	if o.Mask == 0 {
		t.Error("the default collision mask is 0, which blocks nothing")
	}
	if o.TeleportMaxCast != 50 {
		t.Errorf("TeleportMaxCast = %d, want the engine's 50", o.TeleportMaxCast)
	}
	if o.Teleport {
		t.Error("Teleport defaults to on; a walking player is the documented default")
	}
}

// The level graph is what a trip's shape is decided by, and it is stable across seeds: the same
// areas connect in the same order however the rooms come out.
func TestLevelRoute(t *testing.T) {
	w := newWorld(t)

	got, err := w.LevelRoute(rogueEncampment, darkWood)
	if err != nil {
		t.Fatal(err)
	}
	// Not the direct Stony Field border but through the Underground Passage, which is how the
	// two areas actually connect.
	want := []int32{rogueEncampment, bloodMoor, coldPlains, stonyField, undergroundPassage1, darkWood}
	if len(got) != len(want) {
		t.Fatalf("LevelRoute(town -> Dark Wood) = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("LevelRoute(town -> Dark Wood) = %v, want %v", got, want)
		}
	}
}

// A route across levels comes back one leg per level, and every leg but the last says which
// level it exits into — the property a consumer walks the route by.
func TestRouteAcrossLevels(t *testing.T) {
	w := newWorld(t)

	from := passable(t, w, rogueEncampment)
	to := passable(t, w, coldPlains)

	route, err := w.Route(from, to, nil)
	if err != nil {
		t.Fatal(err)
	}
	if route == nil {
		t.Fatalf("no route from %+v to %+v, which should be walkable", from, to)
	}

	levels := route.Levels()
	want := []int32{rogueEncampment, bloodMoor, coldPlains}
	if len(levels) != len(want) {
		t.Fatalf("route crosses %v, want %v", levels, want)
	}
	for i := range want {
		if levels[i] != want[i] {
			t.Fatalf("route crosses %v, want %v", levels, want)
		}
	}

	for i, leg := range route.Legs {
		if len(leg.Moves) == 0 {
			t.Errorf("leg %d (level %d) has no moves", i, leg.Level)
		}
		wantExit := int32(-1)
		if i < len(route.Legs)-1 {
			wantExit = route.Legs[i+1].Level
		}
		if leg.Exit != wantExit {
			t.Errorf("leg %d (level %d) exits into %d, want %d", i, leg.Level, leg.Exit, wantExit)
		}
	}
	if route.MoveCount() == 0 {
		t.Error("the route has no moves at all")
	}

	// The first move is where we asked to start from and the last is where we asked to go.
	first := route.Legs[0].Moves[0]
	if first.X != from.X || first.Y != from.Y {
		t.Errorf("route starts at %d,%d, want %d,%d", first.X, first.Y, from.X, from.Y)
	}
	lastLeg := route.Legs[len(route.Legs)-1]
	last := lastLeg.Moves[len(lastLeg.Moves)-1]
	if last.X != to.X || last.Y != to.Y {
		t.Errorf("route ends at %d,%d, want %d,%d", last.X, last.Y, to.X, to.Y)
	}
}

// Teleport is off by default, so turning it on has to change the route — and it should need
// fewer moves than walking the same trip.
func TestTeleportShortensTheRoute(t *testing.T) {
	w := newWorld(t)

	from := passable(t, w, coldPlains)
	to := Pos{Level: coldPlains, X: from.X + 120, Y: from.Y + 120}
	if nx, ny, ok := w.NearestPassable(coldPlains, to.X, to.Y, 40); ok {
		to.X, to.Y = nx, ny
	} else {
		t.Skip("nothing passable near the far corner of this Cold Plains")
	}

	walking, err := w.Route(from, to, nil)
	if err != nil {
		t.Fatal(err)
	}
	if walking == nil {
		t.Skipf("no walking route from %+v to %+v in this Cold Plains", from, to)
	}

	opts, err := DefaultOptions()
	if err != nil {
		t.Fatal(err)
	}
	opts.Teleport = true
	casting, err := w.Route(from, to, &opts)
	if err != nil {
		t.Fatal(err)
	}
	if casting == nil {
		t.Fatal("teleporting found no route where walking did")
	}

	if casting.MoveCount() >= walking.MoveCount() {
		t.Errorf("teleporting took %d moves, walking took %d — teleport should be shorter",
			casting.MoveCount(), walking.MoveCount())
	}
	teleports := 0
	for _, leg := range casting.Legs {
		for _, m := range leg.Moves {
			if m.Kind == Teleport {
				teleports++
			}
		}
	}
	if teleports == 0 {
		t.Error("the teleporting route contains no teleport moves")
	}
}

// NearestPassable is what a caller reaches for when a position may be inside a wall, so the cell
// it returns has to actually be walkable, and a search that finds nothing has to say so.
func TestNearestPassable(t *testing.T) {
	w := newWorld(t)

	p := passable(t, w, bloodMoor)
	nx, ny, ok := w.NearestPassable(bloodMoor, p.X, p.Y, 10)
	if !ok {
		t.Fatalf("no passable cell within 10 of an already-passable %d,%d", p.X, p.Y)
	}
	if nx != p.X || ny != p.Y {
		t.Errorf("NearestPassable moved an already-passable cell from %d,%d to %d,%d", p.X, p.Y, nx, ny)
	}

	// Far outside any level's own frame, so there is nothing to snap to.
	if _, _, ok := w.NearestPassable(bloodMoor, 30000, 30000, 5); ok {
		t.Error("NearestPassable found a cell 30000,30000 subtiles out")
	}
}

func TestLineOfSight(t *testing.T) {
	w := newWorld(t)
	p := passable(t, w, bloodMoor)
	if !w.LineOfSight(bloodMoor, p.X, p.Y, p.X, p.Y, 0) {
		t.Error("a cell has no line of sight to itself")
	}
}

// An act that was never loaded has no levels to route between, and a closed world answers
// nothing at all rather than calling into a freed handle.
func TestLifecycle(t *testing.T) {
	g, err := drlg.New()
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()

	w, err := New(g, testSeed, drlg.Normal)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.LoadAct(7); err == nil {
		t.Error("LoadAct(7) succeeded, want an error")
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if err := w.LoadAct(0); err != ErrClosed {
		t.Errorf("LoadAct after Close = %v, want %v", err, ErrClosed)
	}
	if _, err := w.Route(Pos{}, Pos{}, nil); err != ErrClosed {
		t.Errorf("Route after Close = %v, want %v", err, ErrClosed)
	}
	if w.Walkable(bloodMoor, 0, 0) {
		t.Error("Walkable on a closed world returned true")
	}
}

// A world built on a closed generator has no tables to route over, and must say so rather than
// dereference a freed context.
func TestClosedGenerator(t *testing.T) {
	g, err := drlg.New()
	if err != nil {
		t.Fatal(err)
	}
	g.Close()
	if _, err := New(g, testSeed, drlg.Normal); err != drlg.ErrClosed {
		t.Errorf("New on a closed generator = %v, want %v", err, drlg.ErrClosed)
	}
}

func newWorld(t *testing.T) *World {
	t.Helper()
	g, err := drlg.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { g.Close() })

	w, err := New(g, testSeed, drlg.Normal)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.Close() })

	if err := w.LoadAct(0); err != nil {
		t.Fatal(err)
	}
	return w
}

// passable finds a cell a walking player fits in, so a route has somewhere real to start. The
// levels are generated, so no fixed coordinate is guaranteed to be open.
func passable(t *testing.T, w *World, level int32) Pos {
	t.Helper()
	for _, r := range []int32{40, 120, 300} {
		for _, c := range []Pos{{level, 100, 100}, {level, 200, 200}, {level, 150, 250}} {
			if nx, ny, ok := w.NearestPassable(level, c.X, c.Y, r); ok {
				return Pos{Level: level, X: nx, Y: ny}
			}
		}
	}
	t.Fatalf("no passable cell found anywhere in level %d", level)
	return Pos{}
}
