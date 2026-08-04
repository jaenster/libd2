# d2-pathfinding

Fast routing over Diablo II 1.14d maps: walk or teleport, within a level or across a dozen of them.

Consumes [`d2-drlg`](../drlg) for the world (collision grids, rooms, warp/seam adjacency) and
[`d2-core`](../core) for the collision bit/mask vocabulary. Pure Zig, no libc.

```zig
const drlg = @import("d2-drlg");
const pf = @import("d2-pathfinding");

var ctx = try drlg.Ctx.init(gpa);
defer ctx.deinit();

var world = pf.World.init(gpa, 0x13572468, .normal);
defer world.deinit();
try world.loadAct(&ctx, 0);          // act 1, generated once (~150 ms)

var route = try world.route(
    .{ .level = 3, .x = 100, .y = 100 },   // Cold Plains
    .{ .level = 4, .x = 200, .y = 200 },   // Stony Field
    .{ .teleport = true },
);
defer route.deinit();

for (route.legs) |leg| {
    // leg.level, leg.moves (each .walk or .teleport), leg.exit
}
```

Positions are **level-local subtiles**. Only levels of the same act share a world frame, so a
`(level, x, y)` triple is unambiguous everywhere; `Level.toWorld` converts to what a game client
reports.

## What it gets right

**Levels are a graph, not a grid.** Cold Plains to Stony Field crosses an area border; Lut Gholein
to the Valley of Snakes crosses five. `route` searches the level graph first, then paths inside each
level, and hands back one leg per level with the exit taken out of it.

**Teleport clears two gates, and both are modelled.** The distance limit is not in the skill code at
all — it is in the cast packet handler, `CheckIfCoordsAreInRange` (0x548ef0) with `nRange = 0x32`,
and it is **Chebyshev**: `|dx| ≤ 50 && |dy| ≤ 50` in subtiles, tested per axis and *rejected* rather
than clamped. That is a bigger reach than the folklore "about 40" — a diagonal (50,50) cast covers
~70 subtiles of ground, and treating the limit as a radius costs extra casts. The second gate is
topological: `SUNIT_RelocateUnit` resolves the destination room and fails unless it is your room or
one adjacent to it, which is the binding one inside small dungeon rooms. See
**[docs/teleport.md](docs/teleport.md)** for the full writeup with addresses.

**Collision is a mask, not a boolean.** Every search is `cell & mask == 0`, so a walking player, a
walking monster and a missile in flight are one implementation with three different `u16`s:

| Model | Mask | Value |
|-|-|-|
| Walking player | `Colmask.player_path` | `0x1c09` |
| Walking monster | `Colmask.monster_path` | `0x3c01` |
| Missile in flight | `Colmask.missile_flight` | `0x05` |
| Line of sight | `Colmask.line_of_sight` | `0x03` |

**Runtime portals are in the graph.** The Arcane Sanctuary has `Vis0-7 = 0` and `Warp0-7 = -1` in
`Levels.txt`, so map generation reports it with zero neighbours — an island. Quest code spawns the
portals at runtime, so [`portals.zig`](src/portals.zig) carries them, each row labelled with how
well it is established.

## Speed

Load once, then never allocate in the hot path: per-mask passability bitsets (1 bit per subtile),
connected-component labels that reject an unreachable goal without searching, and generation-stamped
A* scratch that is reused rather than cleared.

`zig build bench -Doptimize=ReleaseFast -- <seed> <act>` routes corner to corner across every level
of an act. On an M-series Mac, act 1 at seed `0x13572468`:

```
39 levels loaded in 149 ms
walk: 39 routes, mean 0.51 ms, worst 1.87 ms
tele: 39 routes, mean 0.61 ms
```

Loading is the expensive part, and it is `d2-drlg` generating the act — searching it afterwards is
sub-millisecond even corner-to-corner on a 1000×1000-subtile level.

## Layout

| File | |
|-|-|
| `src/world.zig` | `World`: loaded acts, the level graph, `route` |
| `src/level.zig` | one level's grid, rooms, exits, per-mask views |
| `src/rooms.zig` | `DefineRoomsNear` port — teleport's topology gate |
| `src/teleport.zig` | teleport routing, both gates |
| `src/astar.zig` | the walk search |
| `src/grid.zig` | passability bitsets, components, the cost model |
| `src/portals.zig` | quest portals map generation cannot see |
| `src/tests.zig` | integration tests against real generated acts |

## Not covered

- Act travel by caravan/ship/Tyrael dialogue between town levels. That is an NPC conversation, not
  a map link, and its availability depends on quest state a map router has no view of.
- The uber level portals (Matron's Den, Forgotten Sands, Furnace of Pain, Uber Tristram), which are
  opened by item combinations rather than by quest progress.
- Which of the seven Tal Rasha tombs holds the real orifice down to Duriel's Lair. All seven appear
  in the portal table as candidates; a caller that knows the real one should filter the rest.
- Runtime occupancy — objects, doors, monsters. Generated collision carries terrain only; a host
  that tracks units ORs those bits into `Level.cells` and rebuilds the affected mask.
- Teleporting ACROSS a level boundary. It is possible in the engine, but only over a warp/vis link
  and only while the destination room is loaded server-side — runtime state a map-level router
  cannot know. Seam borders (every overworld border) can never be teleported and are routed as
  walks. A caller with live room state can add the hop itself.
