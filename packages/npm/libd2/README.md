# libd2

Clean-room reimplementation of the **Diablo II 1.14d** engine core, reverse-engineered from
the retail binary with no Blizzard code. Give it a seed and it produces the same world the
game does.

```sh
npm install libd2
```

One package for the whole library, one WebAssembly module inside it. No native addon, no build
step, no bundler configuration.

```ts
import { init, open, Areas, route } from 'libd2';

await init();
using game = open({ seed: 1337 });

// Nothing is generated until an area is asked for; one generation covers its whole act.
const cold = game.area(Areas.ColdPlains);
console.log(`${cold.name}: ${cold.rooms.length} rooms, ${cold.exits.length} ways out`);

// Exits are generated data, so where a level leads is known before you ever stand in it.
for (const exit of cold.exits) console.log(`  -> ${exit.to.name}`);

// Routing crosses levels, so this is one call, not one per area. null means no way through.
const trip = route(game.area(Areas.RogueEncampment).middle, cold.middle, { teleport: true });
for (const leg of trip?.legs ?? []) console.log(`${leg.area.name}: ${leg.moves.length} moves`);
```

```text
Cold Plains: 97 rooms, 4 ways out
  -> Cave Level 1
  -> Blood Moor
  -> Burial Grounds
  -> Stony Field
Rogue Encampment: 3 moves
Blood Moor: 6 moves
Cold Plains: 5 moves
```

The same seed always gives the same world, matching the retail engine cell for cell.

## What you get

An object model over the generated world, not a JSON dump of it:

- **`Game`** — a seed and a difficulty. Generates an act the first time you name an area in it.
- **`Area`** — one level: `rooms`, `objects`, `exits`, `collision`, `walk`, and `at(x, y)` for a
  `Location` that knows which area it is in.
- **`route()`** — walk or teleport between two locations across as many levels as it takes, using
  the movement rules the server enforces. Also `walkableAt`, `snap`, `lineOfSight`, `areasBetween`.
- **`rasterize()`, `Minimap`** — turn a level into pixels, or project it the way the game's
  automap does.

Units can be placed into an area (`place`, `occupy`) so routing goes around what is standing
there, which is the difference between a path and a path a character can actually walk.

## Runs everywhere

The wasm is freestanding and libc-free, so its import object is empty and the same package runs
in **Node, Bun, Deno and the browser** with no polyfills. The shim resolves its wasm relative to
its own module URL and feature-detects how to read it.

ESM only, deliberately: Node has been able to `require()` an ESM graph since 22.12 and the shim
has no top-level await, so `require('libd2')` works without shipping a second build. That is the
floor declared in `engines`.

## Is it right?

Map generation is compared cell for cell against dumps captured from the retail engine:
11.1M subtiles per seed, every level of all five acts, zero differing cells, including seeds
held back and never looked at during development. See
[docs/VERIFICATION.md](https://github.com/jaenster/libd2/blob/main/docs/VERIFICATION.md).

Full guide: [docs/usage/node.md](https://github.com/jaenster/libd2/blob/main/docs/usage/node.md).

If libd2 is useful to you, you can [sponsor the work](https://github.com/sponsors/jaenster).

## Replaces @jaenster/d2drlg

`@jaenster/d2drlg` was the previous shape, one package per subsystem wrapping the C ABI
directly. It is deprecated in favour of this package.

## Licence

MIT. The repository embeds small binary blobs derived from Blizzard game data so the
generator builds and self-verifies; they are not redistributable game content. This project
is not affiliated with or endorsed by Blizzard Entertainment.
