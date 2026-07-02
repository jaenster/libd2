# libd2

A clean-room [Zig](https://ziglang.org) reimplementation of the deterministic
**Diablo II 1.14d** engine core — the seed-driven subsystems that turn a game
seed into a world. Reverse-engineered from the retail binary for byte-exact
fidelity, with no Blizzard code.

libd2 is a monorepo of small, independently-consumable packages. Each has its own
`build.zig` + `build.zig.zon`, exposes a Zig module, and can be built and tested
on its own.

## Packages

| package | module | depends on | what it is |
|-|-|-|-|
| [`formats`](packages/formats) | `d2-formats` | — | Pure parsers for D2 on-disk data: `ds1` (level structure) and `dt1` (tile art + collision flags). Byte slice in, typed records out; no engine state, no assets. |
| [`fog`](packages/fog) | `d2-fog` | — | A faithful replica of the engine's `Fog::Memory` segregated-slab pool allocator (fixed size-classes, bitmap slot reuse, wholesale teardown). Engine-agnostic. |
| [`drlg`](packages/drlg) | `d2-drlg` | `formats`, `fog` | **DRLG** — the map generator. Given a seed, produces the room/tile layout, collision grid, roads and object/monster population for every level in all five acts. Verified byte-exact over 1000+ seeds. |
| [`items`](packages/items) | `d2-items` | — | Seed-driven item drops: treasure-class resolution, item-class roll by level, quality, and magic/rare affix selection. |
| [`sim`](packages/sim) | `d2-sim` | — | Runtime simulation: units, stats, RNG, combat, missiles, plus the byte-exact server↔client protocol layer. |

Each subsystem is validated against ground truth captured from the real engine.

## Build & test

Requires Zig `0.16.0`.

```sh
zig build test            # every package's suite
zig build test-formats    # just one package
```

Or a single package on its own:

```sh
cd packages/formats && zig build test
```

## Using a package

Depend on the one you need by path, and import its module:

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
