# libd2

A reimplementation of the deterministic **Diablo II 1.14d** engine core in [Zig](https://ziglang.org) —
the seed-driven subsystems that turn a game seed into a world. 
Reverse-engineered from the retail binary, with no Blizzard code.

## Packages in this repo

| package | module | depends on | what it is |
|-|-|-|-|
| [`formats`](packages/formats) | `d2-formats` | — | Pure parsers/decoders for D2 on-disk data: `ds1` (level structure), `dt1` (tile art + collision flags), `dc6`/`dcc`/`cof` (sprites/animations), `dt1pix`, and the baked-blob container codecs. Byte slice in, typed records out; no engine state. |
| [`fog`](packages/fog) | `d2-fog` | — | A faithful replica of the engine's `Fog::Memory` segregated-slab pool allocator (fixed size-classes, bitmap slot reuse, wholesale teardown). Engine-agnostic. |
| [`drlg`](packages/drlg) | `d2-drlg` | `formats`, `fog` | **DRLG** — the map generator. Given a seed, produces the room/tile layout, collision grid, roads and object/monster population for every level in all five acts. Pure generation, verified byte-exact over 1000+ seeds. |
| [`render`](packages/render) | `d2-render` | `drlg`, `formats` | Turns drlg's generation output into visuals: automap sprite cells and real DT1 tile-art materialization. A pure post-generation consumer. |
| [`items`](packages/items) | `d2-items` | — | Seed-driven item drops: treasure-class resolution, item-class roll by level, quality, and magic/rare affix selection. |
| [`sim`](packages/sim) | `d2-sim` | — | Runtime simulation: units, stats, RNG, combat, missiles, plus the byte-exact server↔client protocol layer. |

Each subsystem is validated against ground truth captured from the real engine.

Building the packages, tests, native libs and wasm from source: see
[docs/BUILDING.md](docs/BUILDING.md).

## Using it

Consume `libd2` from your language of choice — Zig uses the packages as source
modules; everyone else uses the **C ABI** every package ships (a `export fn`
surface compiled to native shared + static libs with a C header, plus a
**WebAssembly** build). The C boundary means the *same* artifacts work from any
language with a C FFI.

### Quick start — TypeScript / Node

```sh
npm install @jaenster/d2drlg
```

```ts
import { shrines } from '@jaenster/d2drlg';

// Cold Plains (level 3) for seed 1337. The wasm loads lazily on first call — no setup.
const s = await shrines(1337, 3);
console.log(`${s.length} shrines/wells:`);
for (const sh of s)
  console.log(`  ${sh.isWell ? 'well ' : 'shrine'} class ${sh.classId} at tile (${sh.tileX}, ${sh.tileY})`);

// 5 shrines/wells:
//   shrine class 2 at tile (995, 1124)
//   shrine class 84 at tile (994, 1114)
//   shrine class 81 at tile (1050, 1098)
//   well  class 130 at tile (1010, 1091)
//   shrine class 83 at tile (1002, 1090)
```

Tiny typed shim, ESM + CommonJS, runs natively on modern Node/Bun/Deno. Same
shape for every package (`@jaenster/d2items`, …).

### Language guides

- [C](docs/usage/c.md)
- [C++](docs/usage/cpp.md)
- [C#](docs/usage/csharp.md)
- [Node (WebAssembly)](docs/usage/node.md)
- [Zig](docs/usage/zig.md)

Where to get the artifacts:
- **Native libs + headers** — attached to each package's GitHub Release
  (`<pkg>-vX.Y.Z`), one archive per target: linux / macos / windows × x64 / arm64.
- **WebAssembly** — published to npm as `@jaenster/d2<pkg>` (e.g. `@jaenster/d2drlg`),
  a tiny typed TypeScript shim over the wasm (ESM + CommonJS).

### Reference API (the `drlg` map generator)

The language guides use `drlg` (`d2drlg`) as the running example — given a seed it
generates an entire act's room layout — and `items` (`d2items`) as a second one.
The `drlg` C API:

```c
typedef struct D2DrlgCtx D2DrlgCtx;   // loaded game tables
typedef struct D2DrlgAct D2DrlgAct;   // a generated act
typedef struct D2DrlgRoom { int32_t x, y, w, h, n_type, n_preset_type; } D2DrlgRoom;

D2DrlgCtx *d2drlg_ctx_create(void);
void       d2drlg_ctx_destroy(D2DrlgCtx *ctx);
// generate a whole act. difficulty 0/1/2; act_no 0..4. NULL on error.
D2DrlgAct *d2drlg_gen_act(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty, int32_t act_no);
void       d2drlg_act_free(D2DrlgAct *act);
int32_t    d2drlg_act_level_count(D2DrlgAct *act);
int32_t    d2drlg_act_level_id(D2DrlgAct *act, int32_t level_index);
int32_t    d2drlg_act_level_room_count(D2DrlgAct *act, int32_t level_index);
// writes up to `cap` rooms of a level into `out`; returns full count (may exceed cap) or <0.
int32_t    d2drlg_act_rooms(D2DrlgAct *act, int32_t level_index, D2DrlgRoom *out, int32_t cap);
uint32_t   d2drlg_abi_version(void);
```

Every package follows the same shape: `d2<pkg>_create`/`_destroy` (or `_ctx_create`),
typed `extern struct` records, and caller-provided output buffers. The full headers
ship in each release (and live at `packages/<pkg>/include/`).

## About the baked assets

`packages/drlg` embeds a handful of small, pre-baked binary blobs under
`src/blobs/` (subtile collision flags, DS1 level structure, automap sprites, and
a slice of tile art) plus a few `.dt1`/`.ds1` fixtures under `src/maps/`. These
are **derived from Blizzard game data** and are included only so the generator
builds and self-verifies out of the box. They are not redistributable game
content; this repository is not affiliated with or endorsed by Blizzard
Entertainment. Diablo II is © Blizzard Entertainment.
