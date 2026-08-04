# libd2

A clean-room reimplementation of the **Diablo II 1.14d** engine core in [Zig](https://ziglang.org)
([why Zig](docs/WHY-ZIG.md)), reverse-engineered from the retail binary with no Blizzard code.

It began with the seed-driven map generator: give it a seed and it produces the same world the
game does. It now covers the surrounding systems too, including item generation, the rules the server applies,
the D2GS wire protocol, save files, and routing over a generated world. Every package stands on
its own.

If libd2 is useful to you, you can [**sponsor the work on GitHub**](https://github.com/sponsors/jaenster).
It is a long reverse-engineering effort and sponsorship is what keeps it moving.

## Packages in this repo

Everything under `packages/` is a library, consumable on its own. Runnable programs
built on top of them live under `apps/`.

| package | module | depends on | what it is |
|-|-|-|-|
| [`data`](packages/data) | `d2-data` | — | The 1.14d Blizzard excel tables, `@embedFile`d, so no filesystem is needed and it cross-compiles to wasm. |
| [`core`](packages/core) | `d2-core` | `data` | Shared foundation: seed-RNG, stats, the `Unit` base type, the item bit-decoder, the Fog pool allocator. |
| [`formats`](packages/formats) | `d2-formats` | — | Parsers for D2 on-disk data: `ds1`, `dt1`, `dc6`/`dcc`/`cof`, the `.d2s` header. Bytes in, records out. |
| [`save`](packages/save) | `d2-save` | `core`, `data`, `item`, `formats` | The `.d2s` character save, read and write. Byte-exact round trip over real saves. |
| [`drlg`](packages/drlg) | `d2-drlg` | `formats`, `core`, `data` | **The map generator.** A seed in, and every level of all five acts out: rooms, tiles, collision, roads, objects and monsters. |
| [`render`](packages/render) | `d2-render` | `drlg`, `formats` | Turns generation output into visuals: automap cells and real DT1 tile art. |
| [`item`](packages/item) | `d2-item` | `core`, `data` | Seed-driven item drops: treasure class, item class, quality, and magic/rare affixes. |
| [`pathfinding`](packages/pathfinding) | `d2-pathfinding` | `drlg`, `core`, `data` | Routing over a generated world, walking or teleporting, across as many levels as it takes, using the movement gates the server enforces. |
| [`game`](packages/game) | `d2-game` | `core`, `data`, `drlg`, `net` | The rules engine: units, stats, combat, skills, monsters, missiles, objects, character state. |
| [`net`](packages/net) | `d2-net` | — | The D2GS wire protocol, both directions, including the variable and bit-packed packets. |
| [`util`](packages/util) | `d2-util` | — | Cross-cutting primitives: the D2GS Huffman packet codec and its framing. |

## Apps

| app | built on | what it is |
|-|-|-|
| [`drlg-server`](apps/drlg-server) | `drlg` | Serves a generated act as JSON over HTTP. A live instance runs at [libd2.typeguru.nl](https://libd2.typeguru.nl); see below. |

## Does it match the game?

Map generation is compared **cell for cell** against dumps captured from the retail engine:
11.1M subtiles per seed, every level of all five acts, zero differing cells. Two of the seeds
are blind holdouts, captured up front and never looked at while developing. Those per-cell
captures are all Nightmare; Normal and Hell are checked per level rather than per cell.

Other packages rest on weaker evidence than that, and it is worth knowing which before you
depend on one: [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Using it

From Zig, add the packages as source modules and import them directly. That works for
all of them. Building from source: [docs/BUILDING.md](docs/BUILDING.md); why the project is
written in Zig at all: [docs/WHY-ZIG.md](docs/WHY-ZIG.md).

From anything else, use the **C ABI**: an `export fn` surface compiled to native shared +
static libs with a C header, plus a **WebAssembly** build, so the same artifacts work from
any language with a C FFI. Two packages ship that today, `drlg` and `item`, and they are the
ones the language guides below use. For .NET there is a package that wraps it, so nothing about
the C boundary shows through:

```sh
dotnet add package LibD2
```

### Try it without installing anything

A `drlg-server` instance is live, so you can generate a real act with one request:

```sh
curl --compressed "https://libd2.typeguru.nl/api/render?seed=1337&acts=1&difficulty=0"
```

`acts` is 1..5 and `difficulty` is 0/1/2. That returns every level of the act: rooms,
preset objects and monsters, level adjacency, and the collision grid:

```json
{ "seed": 1337, "levels": [
    { "levelNo": 1, "name": "RogueCamp", "displayName": "Rogue Encampment", "act": 1,
      "origin": [5520, 5400], "size": [280, 200],
      "rooms": [ ... ], "presets": [ ... ], "adjacents": [ ... ],
      "collisionWidth": 280, "collisionHeight": 200 }
  ] }
```

Act I at seed 1337 is 39 levels and about 230 KB gzipped, generated on the fly in well
under a second. `GET /health` returns `ok`.

### Quick start: TypeScript

```sh
npm install @jaenster/d2drlg
```

```ts
import { shrines } from '@jaenster/d2drlg';

// Cold Plains (level 3) for seed 1337. The wasm loads lazily on first call, so no setup.
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

Tiny typed shim, ESM, no native addon and no build step. The same package runs
in **Node, Bun, Deno and the browser**. The wasm is freestanding and libc-free, so its import
object is empty and the shim reads it with `fetch` or the filesystem depending on where it finds
itself. `item` has the same shape, as `@jaenster/d2item`.

### Language guides

- [C](docs/usage/c.md)
- [C++](docs/usage/cpp.md)
- [C#](docs/usage/csharp.md)
- [Node (WebAssembly)](docs/usage/node.md)
- [Zig](docs/usage/zig.md)

Where to get the artifacts:
- **.NET**: `LibD2` on NuGet. One package for the whole library, carrying a native build for
  every platform .NET runs on, so there is nothing to place by hand.
- **Native libs + headers**: attached to the package's GitHub Release
  (`<pkg>-vX.Y.Z`), one archive per target: linux / macos / windows × x64 / arm64.
- **WebAssembly**: published to npm as `@jaenster/d2<pkg>` (e.g. `@jaenster/d2drlg`),
  a tiny typed TypeScript shim over the wasm. ESM; `require()` works from CommonJS on
  Node 22.12+, which is the floor the package declares.

## About the baked assets

`packages/drlg` embeds a handful of small, pre-baked binary blobs under
`src/blobs/` (subtile collision flags, DS1 level structure, automap sprites, and
a slice of tile art) plus a few `.dt1`/`.ds1` fixtures under `src/maps/`. These
are **derived from Blizzard game data** and are included only so the generator
builds and self-verifies out of the box. They are not redistributable game
content; this repository is not affiliated with or endorsed by Blizzard
Entertainment. Diablo II is © Blizzard Entertainment.

## License

[MIT](LICENSE), for the Zig source. See the note above about the baked assets.
