// Command tour walks through everything the libd2 Go bindings do, against one fixed seed.
//
// It is the worked version of docs/usage/go.md: every section here is a claim that guide makes,
// and its output is snapshotted in main_test.go so neither can drift from the engine.
//
//	go run github.com/libd2/go/examples/tour@latest
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/libd2/go/drlg"
	"github.com/libd2/go/item"
	"github.com/libd2/go/pathfinding"
)

// The seed every section uses. Any seed produces the same world every time; this one is only
// fixed so the output can be snapshotted.
const seed = 1337

// Levels.txt ids. They are stable across seeds, which is why routing names levels by them.
const (
	rogueEncampment = 1
	bloodMoor       = 2
	coldPlains      = 3
)

func main() {
	if err := run(os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "tour:", err)
		os.Exit(1)
	}
}

func run(w io.Writer) error {
	// One generator, reused: loading the game tables is the expensive part, and everything else
	// here borrows them.
	g, err := drlg.New()
	if err != nil {
		return err
	}
	defer g.Close()

	abi, err := drlg.ABIVersion()
	if err != nil {
		return err
	}
	fmt.Fprintf(w, "libd2 drlg ABI %d, seed %d\n", abi, seed)

	act, err := g.GenerateAct(seed, drlg.Normal, 0, drlg.WithCollision(), drlg.WithWalk())
	if err != nil {
		return err
	}

	if err := levels(w, act); err != nil {
		return err
	}
	frames(w, act)
	if err := grids(w, act); err != nil {
		return err
	}
	if err := routing(w, g); err != nil {
		return err
	}
	return drops(w)
}

// Act I as the generator produced it. Rooms are world tiles; presets are level-local subtiles.
func levels(w io.Writer, act *drlg.Act) error {
	fmt.Fprintf(w, "\n== Act %d: %d levels ==\n", act.Number+1, len(act.Levels))
	for _, l := range act.Levels[:6] {
		fmt.Fprintf(w, "%-28s %-11s %3d rooms  %3d presets  %2d warps  %dx%d tiles\n",
			l.Name, l.Type, len(l.Rooms), len(l.Presets), len(l.Adjacents), l.Width, l.Height)
	}

	// Warps come out as adjacents rather than presets: an adjacent says both where the exit is
	// and which level it leads to, so a consumer never has to match the two up itself.
	cold := act.Level(coldPlains)
	fmt.Fprintf(w, "\n%s leads to:\n", cold.Name)
	seen := map[int32]bool{}
	for _, a := range cold.Adjacents {
		if seen[a.DestLevelID] {
			continue
		}
		seen[a.DestLevelID] = true
		dest := "outside this act"
		if l := act.Level(a.DestLevelID); l != nil {
			dest = l.Name
		}
		fmt.Fprintf(w, "  %-28s via level-local subtile %d,%d\n", dest, a.BridgeX, a.BridgeY)
	}
	return nil
}

// The three coordinate frames, and the only conversion between them.
func frames(w io.Writer, act *drlg.Act) {
	cold := act.Level(coldPlains)
	ox, oy := cold.SubtileOrigin()
	fmt.Fprintf(w, "\n== Frames ==\n%s sits at tile %d,%d = subtile %d,%d, and is %dx%d tiles\n",
		cold.Name, cold.OriginX, cold.OriginY, ox, oy, cold.Width, cold.Height)

	shown := 0
	for _, p := range cold.Presets {
		if p.Kind != drlg.Object || shown == 3 {
			continue
		}
		// Plenty of Objects.txt rows are named "Dummy" — placeholders and invisible helpers. They
		// are real placements, just not worth showing off with.
		name, err := drlg.ObjectName(p.TxtFileNo)
		if err != nil || name == "" || name == "Dummy" {
			continue
		}
		fmt.Fprintf(w, "  %-22s local %4d,%-4d -> world subtile %d,%d\n", name, p.X, p.Y, ox+p.X, oy+p.Y)
		shown++
	}
}

// The two optional grids, and the fact that one is derived from the other.
func grids(w io.Writer, act *drlg.Act) error {
	moor := act.Level(bloodMoor)
	if moor.Collision == nil || moor.Walk == nil {
		return fmt.Errorf("%s has no grids; generate the act WithCollision and WithWalk", moor.Name)
	}

	var open, wall, void int
	for i, c := range moor.Collision.Cells {
		switch {
		case c == drlg.Void:
			void++
		case c&drlg.Wall != 0:
			wall++
		case moor.Walk.Cells[i] != 0:
			open++
		}
	}
	fmt.Fprintf(w, "\n== Grids ==\n%s collision is %dx%d subtiles: %d walkable, %d blocked terrain, %d never covered\n",
		moor.Name, moor.Collision.Width, moor.Collision.Height, open, wall, void)
	return nil
}

// Routing over the world the generator just produced, walking and then teleporting.
func routing(w io.Writer, g *drlg.Generator) error {
	world, err := pathfinding.New(g, seed, drlg.Normal)
	if err != nil {
		return err
	}
	defer world.Close()

	if err := world.LoadAct(0); err != nil {
		return err
	}

	// A generated level has no guaranteed-open coordinate, so snap to one. This is also what to
	// do before routing to a monster's reported position, which is often inside a wall.
	from, err := snap(world, rogueEncampment, 120, 120)
	if err != nil {
		return err
	}
	to, err := snap(world, coldPlains, 200, 200)
	if err != nil {
		return err
	}

	fmt.Fprintf(w, "\n== Routing ==\nlevel %d %d,%d -> level %d %d,%d\n",
		from.Level, from.X, from.Y, to.Level, to.X, to.Y)

	// The level graph alone, which is stable across seeds: the same areas connect in the same
	// order however the rooms come out.
	graph, err := world.LevelRoute(from.Level, to.Level)
	if err != nil {
		return err
	}
	fmt.Fprintf(w, "crosses %d levels: %v\n", len(graph), graph)

	walked, err := world.Route(from, to, nil)
	if err != nil {
		return err
	}
	if walked == nil {
		return fmt.Errorf("no route from %+v to %+v", from, to)
	}
	fmt.Fprintf(w, "walking: %d legs, %d moves\n", len(walked.Legs), walked.MoveCount())
	for _, leg := range walked.Legs {
		exit := "arrives"
		if leg.Exit >= 0 {
			exit = fmt.Sprintf("exits into level %d", leg.Exit)
		}
		fmt.Fprintf(w, "  level %d: %4d moves, %s\n", leg.Level, len(leg.Moves), exit)
	}

	// Teleport is off by default because it depends on the destination room being loaded
	// server-side. Start from the engine's own defaults and change only what you mean to.
	opts, err := pathfinding.DefaultOptions()
	if err != nil {
		return err
	}
	opts.Teleport = true
	cast, err := world.Route(from, to, &opts)
	if err != nil {
		return err
	}
	if cast == nil {
		return fmt.Errorf("teleporting found no route where walking did")
	}
	casts := 0
	for _, leg := range cast.Legs {
		for _, m := range leg.Moves {
			if m.Kind == pathfinding.Teleport {
				casts++
			}
		}
	}
	fmt.Fprintf(w, "teleporting: %d moves, %d of them casts (max %d subtiles each)\n",
		cast.MoveCount(), casts, opts.TeleportMaxCast)
	return nil
}

// One kill's worth of drops. The same seed always rolls the same items.
func drops(w io.Writer) error {
	c, err := item.New()
	if err != nil {
		return err
	}
	defer c.Close()

	const tc = "Act 5 (H) Super Cx"
	rolled, err := c.Roll(seed, tc, 87, 800)
	if err != nil {
		return err
	}
	fmt.Fprintf(w, "\n== Drops ==\n%q at mlvl 87 with 800 magic find: %d drops\n", tc, len(rolled))
	for _, d := range rolled {
		fmt.Fprintf(w, "  %-28s mod seed 0x%08x\n", d.String(), d.ItemSeed)
	}
	return nil
}

func snap(world *pathfinding.World, level, x, y int32) (pathfinding.Pos, error) {
	nx, ny, ok := world.NearestPassable(level, x, y, 100)
	if !ok {
		return pathfinding.Pos{}, fmt.Errorf("nothing passable within 100 subtiles of %d,%d in level %d", x, y, level)
	}
	return pathfinding.Pos{Level: level, X: nx, Y: ny}, nil
}
