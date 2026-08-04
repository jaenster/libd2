# automap

A browser view of the clean-room D2 map generator with the pathfinder drawn on top of it: pick a
seed, look at any level's automap, click two points and see the route the engine's own collision
model would take — or ask for every route across a whole act at once.

Everything runs in the page. There is no server: `libd2.wasm` carries the generator, the game
tables and the router, and holds the generated world in its own linear memory.

```
pnpm install
pnpm dev          # http://localhost:5174 — builds the wasm first if it is stale
pnpm build        # type-check + production bundle into dist/
pnpm wasm         # rebuild libd2.wasm unconditionally
```

`pnpm dev` and `pnpm build` shell out to Zig 0.16 the first time (and whenever a `packages/` source
changes). If Zig is not on PATH, build the wasm elsewhere and drop it at `public/libd2.wasm`.

## What it shows

**Level view** — one level as a D2-style isometric automap. Wall lines are traced from the level's
collision grid under the same mask the router tests, so a wall you see is a wall the path had to go
around. Exits are ringed and labelled with the level they lead to.

**Click two points** — the first click sets A, the second B, and the route appears. Walked segments
are solid, teleport casts dashed. A click that lands on a wall snaps to the nearest walkable subtile,
because a pointer on an isometric map hits geometry constantly.

**All routes on this level** — every exit-to-exit route on the current level, overlaid. This is the
level's own internal connectivity: which parts of it you actually traverse getting from any entrance
to any other.

**Whole act / All routes across the act** — every level of the act drawn in the shared world frame it
generates into, plus one route from the act's town to every other level. Overlapping routes burn in
brighter, so the trunk that every trip shares stands out from the branches. This is the same
traversal the pathfinding suite performs, made visible.

**Collision** switches the mask between a walking player, a walking monster and a missile in flight.
The map redraws too, since passability *is* the map — a missile's world has different walls.

## How it is put together

| file | what |
|-|-|
| `src/libd2.ts` | the wasm binding — one instance holds one generated world |
| `src/automap.ts` | wall/floor geometry in subtile space + the isometric transform |
| `src/MapCanvas.tsx` | pan/zoom canvas, route polylines, markers, click picking |
| `src/App.tsx` | controls, routing, and the two bulk sweeps |

The wasm is `packages/wasm`, the combined module every subsystem's C ABI is linked into, built with
`-Dcapi=drlg,pf` so it carries the generator (`d2drlg_*`) and the router (`d2pf_*`) and nothing
else. The router is created over the generator's context (`d2pf_world_create(d2drlg_ctx_core(ctx),
…)`), so both halves share one linear memory and one set of loaded tables.

Exit kinds are read off the geometry rather than reported: a destination whose level shares an edge
with this one is a seam, one that does not is a warp, and an adjacency with no cell is a portal the
server opens at runtime.

## Deploying

`Dockerfile` builds the wasm with Zig, bundles the app, and serves it from nginx. **Its build context
is the repository root**, because the wasm needs the whole `packages/` tree:

```
docker build -f apps/automap/Dockerfile -t automap .
```

`nginx.conf` gzips `application/wasm` — the binary is mostly embedded TSV tables and compresses
several-fold, which is worth more than any code-size work.
