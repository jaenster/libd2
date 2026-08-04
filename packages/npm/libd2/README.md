# libd2

Clean-room reimplementation of the **Diablo II 1.14d** engine core, reverse-engineered from
the retail binary with no Blizzard code. Give it a seed and it produces the same world the
game does.

```sh
npm install libd2
```

One package for the whole library. Each subsystem is a namespace carrying its own
WebAssembly build, fetched only when you call into it. No native addon, no build step,
nothing to initialise.

```ts
import { drlg } from 'libd2';

// Act I of seed 1337. difficulty 0/1/2, actNo 0-based. Cold Plains = level 3.
const map = await drlg.render(1337, 0, 0);
const coldPlains = map.levels.find(l => l.levelNo === 3)!;

console.log(`${map.levels.length} levels`);
console.log(`${coldPlains.displayName}: ${coldPlains.rooms.length} rooms`);

for (const sh of drlg.levelShrines(coldPlains))
  console.log(`${sh.isWell ? 'well  ' : 'shrine'} at tile (${sh.tileX}, ${sh.tileY})`);
```

```text
39 levels
Cold Plains: 97 rooms
shrine at tile (995, 1124)
shrine at tile (994, 1114)
shrine at tile (1050, 1098)
well   at tile (1010, 1091)
shrine at tile (1002, 1090)
```

The same seed always gives the same world, matching the retail engine cell for cell.

## Runs everywhere

The wasm is freestanding and libc-free, so its import object is empty and the same package
runs in **Node, Bun, Deno and the browser** with no bundler configuration and no polyfills.
The shim resolves its wasm relative to its own module URL and feature-detects how to read it.

ESM only, deliberately: Node has been able to `require()` an ESM graph since 22.12 and these
shims have no top-level await, so `require('libd2')` works without shipping a second build.
That is the floor declared in `engines`.

Every namespace is also a subpath export, so a bundler can pull in one subsystem's wasm
instead of all of them:

```ts
import * as drlg from 'libd2/drlg';
```

## Namespaces

| namespace | what it is |
|-|-|
| `drlg` | map generation: rooms, objects, monsters, level adjacency, subtile collision |

More land here as they grow a C ABI.

## Is it right?

Map generation is compared cell for cell against dumps captured from the retail engine:
11.1M subtiles per seed, every level of all five acts, zero differing cells, including seeds
held back and never looked at during development. See
[docs/VERIFICATION.md](https://github.com/jaenster/libd2/blob/main/docs/VERIFICATION.md).

Full guide: [docs/usage/node.md](https://github.com/jaenster/libd2/blob/main/docs/usage/node.md).

If libd2 is useful to you, you can [sponsor the work](https://github.com/sponsors/jaenster).

## Replaces @jaenster/d2drlg

`@jaenster/d2drlg` was the previous shape, one package per subsystem. It is deprecated in
favour of this package, which carries the same wasm and the same shim under the `drlg`
namespace.

## Licence

MIT. The repository embeds small binary blobs derived from Blizzard game data so the
generator builds and self-verifies; they are not redistributable game content. This project
is not affiliated with or endorsed by Blizzard Entertainment.
