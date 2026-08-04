# libd2

Clean-room reimplementation of the **Diablo II 1.14d** engine core, reverse-engineered from
the retail binary with no Blizzard code. Give it a seed and it produces the same world the
game does.

```sh
npm install libd2
```

This package is one entry point over the libd2 WebAssembly packages. Each subsystem lives
under its own namespace, and its wasm is only loaded if you actually touch it.

```ts
import { drlg } from 'libd2';

// Act I of seed 1337. The wasm loads on first call, so there is nothing to initialise.
const map = await drlg.render(1337, 0, 0);
console.log(`${map.levels.length} levels`);

for (const level of map.levels.slice(0, 3))
  console.log(`  ${level.displayName} — ${level.rooms.length} rooms, ${level.presets.length} objects`);
```

```text
39 levels
  Rogue Encampment — 35 rooms, 42 objects
  Blood Moor — 83 rooms, 12 objects
  Cold Plains — 97 rooms, 42 objects
```

The same seed always gives the same world. Each level carries its rooms, the objects and
monsters its map data places, where it connects to other levels, and its subtile collision
grid.

Pure WebAssembly and TypeScript: no native addon and no build step. The wasm is freestanding
and libc-free, so its import object is empty and the same package runs in **Node, Bun, Deno
and the browser**.

## Namespaces

| namespace | what it is |
|-|-|
| `drlg` | map generation: rooms, objects, monsters, level adjacency, subtile collision |

More subsystems land here as they ship their WebAssembly build. Each is also publishable on
its own as `@jaenster/d2<name>` if you would rather depend on just the one.

## Is it right?

Map generation is compared cell for cell against dumps captured from the retail engine:
11.1M subtiles per seed, every level of all five acts, zero differing cells, including seeds
held back and never looked at during development. See
[docs/VERIFICATION.md](https://github.com/jaenster/libd2/blob/main/docs/VERIFICATION.md).

If libd2 is useful to you, you can [sponsor the work](https://github.com/sponsors/jaenster).

## Licence

MIT. The repository embeds small binary blobs derived from Blizzard game data so the
generator builds and self-verifies; they are not redistributable game content. This project
is not affiliated with or endorsed by Blizzard Entertainment.
