# libd2 from Go

```sh
go get github.com/libd2/go
```

Go 1.24 or newer. **No cgo.** The engine is called through
[purego](https://github.com/ebitengine/purego), which resolves the C ABI at run time rather than
through a compiler, so `CGO_ENABLED=0` builds work and cross-compiling a consumer needs no
toolchain at all:

```sh
GOOS=windows GOARCH=amd64 go build ./...   # from any host
```

The module carries one native shared library per platform and a build compiles in only the one
matching its own GOOS/GOARCH, so there is nothing to install and nothing to place at run time.

Go 1.24 is a hard floor rather than a preference: purego makes the binary dynamically linked, and
macOS 15+ refuses to load one without an `LC_UUID`, which Go only started emitting in 1.24.

The bindings are developed in this repository under `packages/go/libd2` and published to
[libd2/go](https://github.com/libd2/go), because a Go module is published by tagging the
repository its import path names. That repository is generated: it carries a `SOURCE` file naming
the commit here it was cut from, and issues and pull requests belong here rather than there.

Everything below is real output from
[`examples/tour`](https://github.com/libd2/go/tree/main/examples/tour), whose output is
snapshotted in its own test — so the numbers on this page cannot drift away from the engine
without a test failing. `go run github.com/libd2/go/examples/tour@latest` prints the lot.

## Generate a world from a seed

```go
import "github.com/libd2/go/drlg"

// One generator, reused. Loading the game tables is the expensive part.
g, err := drlg.New()
if err != nil {
	return err
}
defer g.Close()

// act counts from zero the way the engine does: 0 is Act I, 4 is Act V.
act, err := g.GenerateAct(1337, drlg.Normal, 0)
if err != nil {
	return err
}
for _, l := range act.Levels[:6] {
	fmt.Printf("%-28s %-11s %3d rooms  %3d presets  %2d warps  %dx%d tiles\n",
		l.Name, l.Type, len(l.Rooms), len(l.Presets), len(l.Adjacents), l.Width, l.Height)
}
```

```text
Rogue Encampment             preset       35 rooms   42 presets  20 warps  56x40 tiles
Blood Moor                   wilderness   83 rooms   12 presets  36 warps  96x56 tiles
Cold Plains                  wilderness   97 rooms   42 presets  40 warps  80x80 tiles
Stony Field                  wilderness   91 rooms   55 presets  16 warps  80x80 tiles
Dark Wood                    wilderness   93 rooms   79 presets  19 warps  80x80 tiles
Black Marsh                  wilderness   93 rooms   47 presets  41 warps  80x80 tiles
```

The same seed always gives the same world, matching the retail engine cell for cell.

An `Act` is plain Go data. Everything is copied out of native memory before `GenerateAct` returns
and the native handle is released there, so there is nothing to free, nothing that can be used
after free, and no lifetime tying the result to the generator that made it.

Find a level by its Levels.txt id, which is stable across seeds:

```go
coldPlains := act.Level(3)
```

## What a level carries

| field | frame | what it is |
|-|-|-|
| `Rooms` | world tiles | every generated room rectangle, with its `Kind` and `PresetKind` |
| `Presets` | level-local subtiles | the npcs and objects placed in it |
| `Adjacents` | level-local subtiles | each warp: where it sits, and which level it leads to |
| `Collision`, `Walk` | level-local subtiles | the grids, when asked for |
| `OriginX/Y`, `Width`, `Height` | world tiles | where the level sits and how big it is |

Warps come out as **adjacents**, not as presets. An adjacent says both where the exit is and what
is on the other side, so nothing has to be matched up afterwards:

```go
for _, a := range coldPlains.Adjacents {
	fmt.Printf("%-28s via level-local subtile %d,%d\n", act.Level(a.DestLevelID).Name, a.BridgeX, a.BridgeY)
}
```

```text
Cave Level 1                 via level-local subtile 300,220
Blood Moor                   via level-local subtile 380,380
Burial Grounds               via level-local subtile 140,380
Stony Field                  via level-local subtile 300,20
```

There is one adjacent per warp slot, so a level with two ways into the same place lists it twice.

### Shrines, wells and chests

There is no shrine entry point, because there does not need to be one: shrines and wells are
already among a level's presets, as the Objects.txt rows the outdoor spawner draws from. Filter
for them:

```go
shrineRows := map[int32]string{2: "shrine", 81: "shrine", 83: "shrine", 84: "shrine", 130: "well"}

for _, p := range coldPlains.Presets {
	if p.Kind != drlg.Object {
		continue
	}
	if kind, ok := shrineRows[p.TxtFileNo]; ok {
		fmt.Printf("%s class %d at tile (%d, %d)\n",
			kind, p.TxtFileNo, coldPlains.OriginX+p.X/5, coldPlains.OriginY+p.Y/5)
	}
}
```

```text
shrine class 2 at tile (995, 1124)
shrine class 84 at tile (994, 1114)
shrine class 81 at tile (1050, 1098)
well class 130 at tile (1010, 1091)
shrine class 83 at tile (1002, 1090)
```

Which is the same five, in the same order, that the TypeScript quick start on the front page
prints for that seed — two bindings over the same C ABI agreeing. There is a test asserting it.

`drlg.ObjectName` and `drlg.ObjectDesc` turn any `TxtFileNo` into its Objects.txt name. Plenty of
rows are called `Dummy`: real placements, but placeholders and invisible helpers.

## Coordinates

The engine works in three frames and mixing them is the easiest mistake to make against this
data:

- **World tiles** — a level's `OriginX`/`OriginY` and `Width`/`Height`, and every `Room`.
- **World subtiles** — five to a tile, the frame in-game positions use.
- **Level-local subtiles** — what a level's own map data is authored in: every `PresetUnit`, every
  `Adjacent` bridge, every cell of `Collision` and `Walk`, and everything in `pathfinding`.

`SubtileOrigin` is the only conversion you need. To put a preset on the world map:

```go
ox, oy := coldPlains.SubtileOrigin()   // 4920,5400 for tile origin 984,1080
worldX, worldY := ox+p.X, oy+p.Y
```

```text
Cold Plains sits at tile 984,1080 = subtile 4920,5400, and is 80x80 tiles
  bed                    local  303,258  -> world subtile 5223,5658
  chest                  local  250,100  -> world subtile 5170,5500
  fire                   local  172,55   -> world subtile 5092,5455
```

## Collision and walkability

Both grids are off by default, because a whole act's worth is tens of megabytes:

```go
act, err := g.GenerateAct(1337, drlg.Normal, 0, drlg.WithCollision(), drlg.WithWalk())

moor := act.Level(2) // Blood Moor
fmt.Println(moor.Collision.At(100, 100)&drlg.Wall != 0) // blocked terrain?
fmt.Println(moor.Walk.At(100, 100))                     // can a player stand here?
```

`Collision` is the raw engine CollMap, one flag word per subtile: `drlg.Wall`, `drlg.Visible`,
`drlg.NoPlayer`, `drlg.Door` and the rest, with `drlg.Void` for a cell the generator never covered
— outside the level rather than merely blocked. `Walk` is the grid derived from it, one byte per
subtile, ready to path on directly. Both have the same dimensions and the same origin, so they
index identically:

```text
Blood Moor collision is 480x280 subtiles: 82696 walkable, 50104 blocked terrain, 1600 never covered
```

`At` bounds-checks, and a nil grid reads as `Void` / not walkable, so a level generated without
the grids does not need a nil check at every use.

## Item drops

```go
import "github.com/libd2/go/item"

c, err := item.New()
if err != nil {
	return err
}
defer c.Close()

drops, err := c.Roll(1337, "Act 5 (H) Super Cx", 87, 800) // seed, treasure class, mlvl, magic find
for _, d := range drops {
	fmt.Printf("%-28s mod seed 0x%08x\n", d, d.ItemSeed)
}
```

```text
magic 7p7 ilvl 87            mod seed 0x920e3483
normal hp4 ilvl 87           mod seed 0x46cfa5c4
normal hp5 ilvl 87           mod seed 0xf273dad5
normal hp4 ilvl 87           mod seed 0xa6f9b2b0
normal hp4 ilvl 87           mod seed 0x6e41c74c
```

An empty result is an answer, not an error — most rolls drop nothing, and an unknown treasure
class simply has no row to roll rather than failing.

Which of a `Drop`'s id fields carry anything depends on its `Quality`: a magic item has
`PrefixID`/`SuffixID`, a rare has `RarePrefixIDs`/`RareSuffixIDs` plus a name from
`RarePrefixName`/`RareSuffixName`, a unique has `UniqueID`. Every id is a 1-based row in the table
its name says. `Code()` is the base item's code with the padding stripped, and `ItemSeed` is the
low word of the item's own mod seed — what replays its property rolls.

## Routing

`pathfinding` does not generate maps. It builds on a running generator and shares that
generator's loaded tables, so routing runs over the very world it produced rather than a second
copy of it. The generator has to outlive the world.

```go
import "github.com/libd2/go/pathfinding"

w, err := pathfinding.New(g, 1337, drlg.Normal)
if err != nil {
	return err
}
defer w.Close()

if err := w.LoadAct(0); err != nil { // load every act you mean to route across
	return err
}
```

A generated level has no coordinate guaranteed to be open, so snap before routing. This is also
what to do before routing to a monster's reported position, which is often inside a wall:

```go
x, y, ok := w.NearestPassable(1, 120, 120, 100)
if !ok {
	return fmt.Errorf("nothing passable near there")
}
from := pathfinding.Pos{Level: 1, X: x, Y: y}
```

`LevelRoute` answers which areas a trip crosses without pathing inside any of them — cheap enough
to call in a loop when that is all you need:

```go
w.LevelRoute(1, 3)   // [1 2 3]
```

A full route comes back as one leg per level crossed. Every leg but the last says which level it
exits into, and a transition always runs from that leg's last move to the next leg's first —
staircase, area border and teleport cast alike, so the far side never needs a case of its own:

```go
route, err := w.Route(from, to, nil) // nil options means the engine's defaults
for _, leg := range route.Legs {
	fmt.Printf("level %d: %4d moves, exits into %d\n", leg.Level, len(leg.Moves), leg.Exit)
}
```

```text
walking: 3 legs, 36 moves
  level 1:    9 moves, exits into level 2
  level 2:   18 moves, exits into level 3
  level 3:    9 moves, arrives
```

A nil route with a nil error means there is no way between those two points. That is an answer,
not a failure.

Teleport is off by default, because a cast across a level boundary depends on the destination room
being loaded server-side: planned into a room the server has not allocated, it silently does
nothing. Start from the engine's own defaults and change only what you mean to — a zero `Options`
means no collision mask and no cast limit, which is not a sane default:

```go
opts, err := pathfinding.DefaultOptions()
opts.Teleport = true
route, err = w.Route(from, to, &opts)
```

```text
teleporting: 14 moves, 11 of them casts (max 50 subtiles each)
```

`TeleportMaxCast` defaults to the engine's 50 subtiles; lower it for margin against position lag,
or set it negative to drop the distance gate and leave only the adjacent-room rule.
`TeleportMetric` picks between the engine's own per-axis test (`Chebyshev`) and the stricter radial
cap conventional bots apply (`Euclidean`).

## Using a library from disk

Each subsystem embeds its own native library, so importing `drlg` costs about 2 MB of binary and
importing nothing costs nothing. The libraries are stripped and gzipped, and decompressed into the
user cache directory the first time a given version runs.

To point at a build on disk instead — a local libd2 checkout, or a platform with no shipped
binary:

| variable | meaning |
|-|-|
| `LIBD2_D2DRLG_PATH` | an exact file, per library (`LIBD2_D2ITEM_PATH`, `LIBD2_D2PF_PATH` likewise) |
| `LIBD2_PATH` | a directory holding platform-named libraries |

Both are checked before the embedded copy, so a local build overrides a shipped one without a
rebuild. `-tags libd2_nolib` leaves the embedded binaries out altogether, for a small binary
against a system-installed library. When nothing resolves, the error names every location it
tried and the variable to set.

The Linux binaries are glibc builds. On Alpine or another musl system, point `LIBD2_PATH` at a
musl build.

FreeBSD needs `CGO_ENABLED=1` — purego's FreeBSD support does, not these bindings. That is the
default on a FreeBSD host with the base clang, so it only bites when cross-compiling to FreeBSD
with cgo off. Every other platform builds with cgo off.

## Costs

On an M3 Max:

| | |
|-|-|
| `drlg.New()`, once | 13 ms |
| `GenerateAct`, Act I | 198 ms, of which 175 ms is the generator itself |
| the same, `WithCollision()` | 206 ms |
| a trivial FFI call | 0.6 µs |

The boundary is not the expensive part of generating a world. It is worth knowing about for the
small calls, though: purego marshals through reflection, so `Walkable` and `LineOfSight` cost most
of a microsecond each. Per-cell loops belong on the native side — that is what `Route` and the
`Walk` grid are for.

## Threading

A `Generator`, `Context` or `World` serialises its own calls: sharing one between goroutines is
safe, but not concurrent. Give each goroutine its own to actually parallelise — the tables cost
about 13 ms to load and nothing after that.

## What is not bound

A few entry points in the C ABI have no Go equivalent, deliberately:

- The **per-level seed-based accessors** (`d2drlg_level_presets` and friends). Each regenerates a
  whole act internally; `GenerateAct` does it once and reads every level off the one handle.
- `d2drlg_level_shrines`, which is deprecated upstream: every shrine it returns is already in the
  level's presets, as shown above.
- The **zlib helpers**, which exist so a WebAssembly host can deflate without its own zlib. Go has
  `compress/zlib`.
