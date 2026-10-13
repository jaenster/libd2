package pathfinding

import (
	"fmt"
	"runtime"
	"unsafe"
)

// Pos is a position in the world: a Levels.txt id and a level-local subtile.
type Pos struct {
	Level int32
	X     int32
	Y     int32
}

// MoveKind is how a step of a route is made.
type MoveKind int32

// The ways a route moves.
const (
	// Walk is a step on foot.
	Walk MoveKind = 0
	// Teleport is a cast. X/Y is where you land.
	Teleport MoveKind = 1
	// Pad means you arrived by stepping on a teleport pad — the Arcane Sanctuary ones. X/Y is
	// where you come OUT; the PREVIOUS move is the pad to step on.
	Pad MoveKind = 2
)

func (k MoveKind) String() string {
	switch k {
	case Walk:
		return "walk"
	case Teleport:
		return "teleport"
	case Pad:
		return "pad"
	default:
		return fmt.Sprintf("MoveKind(%d)", int32(k))
	}
}

// Move is one step of a route, in level-local subtiles.
//
// Mirrors D2PfMove; layout is part of the ABI.
type Move struct {
	X    int32
	Y    int32
	Kind MoveKind
}

// Leg is the part of a route that happens inside one level.
type Leg struct {
	// Level is the Levels.txt id this leg is walked in.
	Level int32
	// Exit is the level this leg leads into, or -1 for the last leg.
	//
	// A transition always runs from this leg's LAST move to the next leg's FIRST move, whether
	// it is a staircase, an area border or a teleport cast, so the far side never needs a case
	// of its own.
	Exit  int32
	Moves []Move
}

// Route is a way from one position to another, one leg per level crossed.
type Route struct {
	Legs []Leg
}

// MoveCount is the total number of moves across every leg — a cheap way to compare two routes.
func (r *Route) MoveCount() int {
	n := 0
	for _, l := range r.Legs {
		n += len(l.Moves)
	}
	return n
}

// Levels are the Levels.txt ids the route crosses, in order.
func (r *Route) Levels() []int32 {
	out := make([]int32, 0, len(r.Legs))
	for _, l := range r.Legs {
		out = append(out, l.Level)
	}
	return out
}

// Metric is the distance measure that bounds a teleport cast.
type Metric int32

// The two metrics.
const (
	// Chebyshev is the engine's own per-axis test, max(|dx|,|dy|).
	Chebyshev Metric = 0
	// Euclidean is the radial cap conventional bots apply. Strictly more conservative.
	Euclidean Metric = 1
)

// Options tunes how a route is found.
//
// Do not build one from a zero value: get the engine defaults from DefaultOptions and change
// what you mean to change. A zeroed struct means "no collision mask, no cast limit", which is
// not a sane default.
type Options struct {
	// Mask is the movement collision model. The default is what a walking player uses.
	Mask uint16
	// Teleport allows teleporting where the level permits it. Levels that forbid it fall back
	// to walking.
	Teleport bool
	// TeleportAcrossLevels crosses a level boundary with a single cast where the engine allows
	// one. Requires Teleport. Off by default because it depends on the destination room being
	// LOADED server-side: a planned cast into a room the server has not allocated silently
	// does nothing. Turn it on when the whole act is resident.
	TeleportAcrossLevels bool
	// TeleportMaxCast is the maximum cast distance in subtiles, the gate the packet handler
	// applies. The engine's own value is 50; lower it for margin against position lag. Negative
	// drops the distance gate and leaves only the adjacent-room rule.
	TeleportMaxCast int32
	// TeleportMetric is which distance measure TeleportMaxCast is applied with.
	TeleportMetric Metric
	// SnapRadius accepts a passable cell this far from a blocked start or goal.
	SnapRadius int32
}

// DefaultOptions is what the engine itself does. Start here.
func DefaultOptions() (Options, error) {
	a, err := Load()
	if err != nil {
		return Options{}, err
	}
	var c D2PfOptions
	a.OptionsDefault(unsafe.Pointer(&c))
	runtime.KeepAlive(c)
	return Options{
		Mask:                 c.Mask,
		Teleport:             c.Teleport != 0,
		TeleportAcrossLevels: c.TeleportAcrossLevels != 0,
		TeleportMaxCast:      c.TeleportMaxCast,
		TeleportMetric:       Metric(c.TeleportMetric),
		SnapRadius:           c.SnapRadius,
	}, nil
}

func (o *Options) toC() D2PfOptions {
	return D2PfOptions{
		Mask:                 o.Mask,
		Teleport:             boolToInt(o.Teleport),
		TeleportAcrossLevels: boolToInt(o.TeleportAcrossLevels),
		TeleportMaxCast:      o.TeleportMaxCast,
		TeleportMetric:       int32(o.TeleportMetric),
		SnapRadius:           o.SnapRadius,
	}
}

func boolToInt(b bool) int32 {
	if b {
		return 1
	}
	return 0
}
