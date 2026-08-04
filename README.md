# libd2

A clean-room reimplementation of the **Diablo II 1.14d** engine core in [Zig](https://ziglang.org),
reverse-engineered from the retail binary with no Blizzard code.

It began with the seed-driven map generator — give it a seed and it produces the same world the
game does — and now covers the systems around it: item generation, the rules the server applies,
the D2GS wire protocol, save files, and routing over a generated world. Every package stands on
its own; `drlg` and `item` additionally ship a C ABI and a WebAssembly build, so they are usable
from any language with a C FFI.

If libd2 is useful to you, you can [**sponsor the work on GitHub**](https://github.com/sponsors/jaenster).
It is a long reverse-engineering effort and sponsorship is what keeps it moving.

## Packages in this repo

Everything under `packages/` is a library, consumable on its own. Runnable programs
built on top of them live under `apps/`.

| package | module | depends on | what it is |
|-|-|-|-|
| [`data`](packages/data) | `d2-data` | — | The authoritative 1.14d Blizzard excel tables (Patch_D2 override order, extracted from the retail MPQs) plus a generic TSV reader. Every table is `@embedFile`d, so the loader needs no filesystem and cross-compiles to wasm. |
| [`core`](packages/core) | `d2-core` | `data` | The shared model foundation: the seed-RNG, the `Stat` enum + `StatList`, the `Unit` base type, ItemStatCost metadata, the save-file item bit-decoder, and the `Fog::Memory` segregated-slab pool allocator. Owning these here is what keeps them from being vendored twice. |
| [`formats`](packages/formats) | `d2-formats` | — | Pure parsers/decoders for D2 on-disk data: `ds1` (level structure), `dt1` (tile art + collision flags), `dc6`/`dcc`/`cof` (sprites/animations), `dt1pix`, the fixed `.d2s` save header, and the baked-blob container codecs. Byte slice in, typed records out; no engine state. |
| [`save`](packages/save) | `d2-save` | `core`, `data`, `item`, `formats` | The `.d2s` character save format, read and write: the marker-delimited quest, waypoint, NPC, attribute, skill and item sections on top of the fixed header `formats` owns. Byte-exact round-trip over real saves. |
| [`drlg`](packages/drlg) | `d2-drlg` | `formats`, `core`, `data` | **DRLG** — the map generator. Given a seed, produces the room/tile layout, collision grid, roads and object/monster population for every level in all five acts. Pure generation, verified byte-exact over 1000+ seeds. |
| [`render`](packages/render) | `d2-render` | `drlg`, `formats` | Turns drlg's generation output into visuals: automap sprite cells and real DT1 tile-art materialization. A pure post-generation consumer. |
| [`item`](packages/item) | `d2-item` | `core`, `data` | Seed-driven item drops: treasure-class resolution, item-class roll by level, quality, and magic/rare affix selection. |
| [`pathfinding`](packages/pathfinding) | `d2-pathfinding` | `drlg`, `core`, `data` | Routing over a generated world: walk and teleport, within a level and across as many as it takes. Models the gates the server actually applies — the cast range check, the adjacent-room rule, line of sight, and unit footprints — so a planned move is one the server would accept. |
| [`game`](packages/game) | `d2-game` | `core`, `data`, `drlg`, `net` | The rules engine: units, stats, combat, skills, monsters, missiles, objects and character state. What the server decides; the host only applies it. |
| [`net`](packages/net) | `d2-net` | — | The D2GS wire protocol, both directions: the server→client and client→server opcode spaces, byte-exact including the variable and bit-packed packets. |
| [`util`](packages/util) | `d2-util` | — | Cross-cutting primitives with no domain of their own: the D2GS server→client Huffman packet codec and the length-prefix framing / `AF` greeting around it. |

## Apps

| app | built on | what it is |
|-|-|-|
| [`drlg-server`](apps/drlg-server) | `drlg` | Native multi-threaded HTTP server that serves an act's map JSON straight from `d2-drlg`. Compresses per-level collision concurrently and gzips its responses. Runs at [libd2.typeguru.nl](https://libd2.typeguru.nl). |

## How it is verified

Every subsystem is checked against ground truth captured from the real 1.14d engine, not
against itself. Generation is compared cell-for-cell with engine dumps across many seeds,
and some seeds are held back as **blind holdouts** — never looked at while developing, so
they cannot have been fitted. Where the engine's own rule was recovered from the binary,
the address is in the comment next to the code that implements it.

```sh
zig build test               # every package
zig build test-drlg          # one package
cd packages/drlg && zig build test -Doptimize=ReleaseFast -Dtest-filter="all-acts golden"
```

Building the packages, native libs and wasm from source: see
[docs/BUILDING.md](docs/BUILDING.md).

## Using it

From Zig, add the packages as source modules and import them directly — that works for
all of them.

From anything else, use the **C ABI**: an `export fn` surface compiled to native shared +
static libs with a C header, plus a **WebAssembly** build, so the same artifacts work from
any language with a C FFI. Two packages ship that today — `drlg` and `item` — and they are
the ones the language guides below use.

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

Tiny typed shim, ESM + CommonJS, runs natively on modern Node/Bun/Deno. `item` has the
same shape, as `@jaenster/d2item`.

### Language guides

- [C](docs/usage/c.md)
- [C++](docs/usage/cpp.md)
- [C#](docs/usage/csharp.md)
- [Node (WebAssembly)](docs/usage/node.md)
- [Zig](docs/usage/zig.md)

Where to get the artifacts:
- **Native libs + headers** — attached to the package's GitHub Release
  (`<pkg>-vX.Y.Z`), one archive per target: linux / macos / windows × x64 / arm64.
- **WebAssembly** — published to npm as `@jaenster/d2<pkg>` (e.g. `@jaenster/d2drlg`),
  a tiny typed TypeScript shim over the wasm (ESM + CommonJS).

### Reference API (the `drlg` map generator)

The language guides use `drlg` (`d2drlg`) as the running example — given a seed it
generates an entire act's room layout — and `item` (`d2item`) as a second one.
The `drlg` C API:

```c
typedef struct D2DrlgCtx D2DrlgCtx;   // loaded game tables
typedef struct D2DrlgAct D2DrlgAct;   // a generated act
typedef struct D2DrlgRoom { int32_t x, y, w, h, n_type, n_preset_type; } D2DrlgRoom;
typedef struct D2DrlgShrine { int32_t class_id, x, y; } D2DrlgShrine;  // x/y are subtiles (÷5 for tiles)

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
// writes up to `cap` of a level's seeded outdoor shrines/wells; returns full count or <0.
int32_t    d2drlg_level_shrines(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty,
                                int32_t level_id, D2DrlgShrine *out, int32_t cap);
uint32_t   d2drlg_abi_version(void);
```

Both C APIs follow the same shape: `d2<pkg>_create`/`_destroy` (or `_ctx_create`), typed
`extern struct` records, and caller-provided output buffers. The headers ship in each
release and live at `packages/<pkg>/include/`.

## About the baked assets

`packages/drlg` embeds a handful of small, pre-baked binary blobs under
`src/blobs/` (subtile collision flags, DS1 level structure, automap sprites, and
a slice of tile art) plus a few `.dt1`/`.ds1` fixtures under `src/maps/`. These
are **derived from Blizzard game data** and are included only so the generator
builds and self-verifies out of the box. They are not redistributable game
content; this repository is not affiliated with or endorsed by Blizzard
Entertainment. Diablo II is © Blizzard Entertainment.

## License

[MIT](LICENSE) — the Zig source, that is. See the note above about the baked assets.
