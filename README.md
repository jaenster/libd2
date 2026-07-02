# libd2

A clean-room [Zig](https://ziglang.org) reimplementation of the deterministic
**Diablo II 1.14d** engine core — the seed-driven subsystems that turn a game
seed into a world. Reverse-engineered from the retail binary for byte-exact
fidelity, with no Blizzard code.

It is a monorepo of three independent, individually-consumable packages:

| package | what it does |
|-|-|
| [`packages/drlg`](packages/drlg) | **DRLG** — the map generator. Given a seed, produces the room/tile layout, collision grid, roads and object/monster population for every level in all five acts. |
| [`packages/items`](packages/items) | **Item generation** — the seed-driven drop pipeline: treasure-class resolution, item-class roll by level, quality, and magic/rare affix selection. |
| [`packages/sim`](packages/sim) | **Runtime simulation** — the stateful engine core (units, stats, RNG, combat, missiles) plus the byte-exact server↔client protocol layer. |

Each subsystem is validated against ground-truth captured from the real engine.

## Build & test

Requires Zig `0.16.0`.

```sh
zig build test          # run every package's suite
zig build test-drlg     # just one package
```

Or build a package on its own:

```sh
cd packages/items && zig build test
```

## Using a package

Each package exposes a Zig module. Depend on the one you need by path:

```zig
// build.zig.zon
.dependencies = .{
    .d2_drlg = .{ .path = "path/to/libd2/packages/drlg" },
},
```

```zig
// build.zig
const drlg = b.dependency("d2_drlg", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("d2-drlg", drlg.module("d2-drlg"));
```

## About the baked assets

`packages/drlg` embeds a handful of small, pre-baked binary blobs under
`src/blobs/` (subtile collision flags, DS1 level structure, automap sprites, and
a slice of tile art) plus a few `.dt1`/`.ds1` fixtures under `src/maps/`. These
are **derived from Blizzard game data** and are included only so the generator
builds and self-verifies out of the box. They are not redistributable game
content; this repository is not affiliated with or endorsed by Blizzard
Entertainment. Diablo II is © Blizzard Entertainment.

## Provenance

libd2 is a curated public mirror. The packages are copied verbatim from private
canonical dev repos by [`tools/sync.sh`](tools/sync.sh) (the web viewer, the raw
asset trees and the multi-GB verification corpora stay private). To refresh:

```sh
cp .env.example .env   # point at your local source repos
bash tools/sync.sh
```
