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

Language guides:

- [Zig](docs/usage/zig.md)
- [C](docs/usage/c.md)
- [C++](docs/usage/cpp.md)
- [C#](docs/usage/csharp.md)
- [Node (WebAssembly)](docs/usage/node.md)

Where to get the artifacts:
- **Native libs + headers** — attached to each package's GitHub Release
  (`<pkg>-vX.Y.Z`), one archive per target: linux / macos / windows × x64 / arm64.
- **WebAssembly** — published to npm as `@jaenster/d2<pkg>` (e.g. `@jaenster/d2items`).

### Reference API (the `items` package)

All the language guides use `items` (`d2items`) as the example. Its C API:

```c
typedef struct D2ItemsCtx D2ItemsCtx;
typedef struct {
    uint8_t  kind;               // 0 none, 1 gold, 2 item, 3 quiver, 4 bodypart
    uint8_t  item_code[4];       // e.g. "amu\0"
    uint8_t  quality;            // D2 quality enum
    uint16_t prefix_id, suffix_id;
    uint16_t rare_prefix_ids[3], rare_suffix_ids[3];
    uint8_t  sockets;
    int32_t  quantity;           // gold amount / quiver count
    int32_t  item_level;
} D2ItemsDrop;

D2ItemsCtx *d2items_create(void);
void        d2items_destroy(D2ItemsCtx *ctx);
// rolls a drop for (seed, treasure-class, monster-level, magic-find); writes up
// to `cap` drops into `out`; returns the count (may exceed cap → truncated) or <0 on error.
int32_t     d2items_roll(D2ItemsCtx *ctx, uint32_t seed, const char *tc_name,
                         int32_t mlvl, int32_t mf, D2ItemsDrop *out, int32_t cap);
uint32_t    d2items_abi_version(void);
```

Every other package follows the same shape: `d2<pkg>_create` / `_destroy`, typed
`extern struct` records, and a caller-provided output buffer.

## About the baked assets

`packages/drlg` embeds a handful of small, pre-baked binary blobs under
`src/blobs/` (subtile collision flags, DS1 level structure, automap sprites, and
a slice of tile art) plus a few `.dt1`/`.ds1` fixtures under `src/maps/`. These
are **derived from Blizzard game data** and are included only so the generator
builds and self-verifies out of the box. They are not redistributable game
content; this repository is not affiliated with or endorsed by Blizzard
Entertainment. Diablo II is © Blizzard Entertainment.
