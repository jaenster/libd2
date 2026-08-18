# libd2 from JavaScript

```sh
npm install libd2
```

One package for the whole library, one WebAssembly module inside it, loaded on the first
`init()`. No native addon, no build step.

The wasm is freestanding and libc-free, so its import object is empty and the same package
runs in **Node, Bun, Deno and the browser** with no bundler configuration and no polyfills.

## Open a game

```ts
import { init, open, Areas } from 'libd2';

await init();
using game = open({ seed: 1337 });          // difficulty defaults to normal
```

`init()` is the one asynchronous thing: it fetches and instantiates the wasm. Everything after
it is synchronous, because the engine is in memory and a call into it is a function call.

`open()` generates nothing. An act is generated the first time you name an area inside it, and
one generation covers every area of that act:

```ts
const town = game.area(Areas.RogueEncampment);
game.generatedActs;                          // [0]
const moor = game.area(Areas.BloodMoor);     // free — same act
```

`using` closes the game at the end of the scope. Without it, call `game.close()` yourself; a
closed game refuses to be used again rather than reading freed memory.

## What an area knows

```ts
const cold = game.area(Areas.ColdPlains);

cold.name;            // 'Cold Plains'
cold.origin;          // where it sits in the world, in subtiles
cold.size;
cold.rooms;           // the rectangles the generator laid down
cold.objects;         // what it stood in them, with Objects.txt names
cold.exits;           // where it leads, and the cells you cross to get there
cold.collision;       // the subtile grid
cold.walk;            // the same grid reduced to walkable / not
cold.at(120, 200);    // a Location, which remembers its area
cold.middle;
```

Exits are generated data, so where a level leads is known before you ever stand in it:

```ts
for (const exit of cold.exits) console.log(`-> ${exit.to.name}`);
// -> Cave Level 1
// -> Blood Moor
// -> Burial Grounds
// -> Stony Field
```

An `Exit` also carries `points` (every cell the generator named for the crossing),
`nearestTo(from)` for the one closest to where you are standing, and `border` — the line two
outdoor levels meet along, or null when the far side is reached through a placed warp instead.

## Routing

`route()` crosses levels, so getting from town to a dungeon is one call:

```ts
import { route } from 'libd2';

const trip = route(town.middle, cold.middle, { teleport: true });
for (const leg of trip?.legs ?? []) console.log(`${leg.area.name}: ${leg.moves.length} moves`);
// Rogue Encampment: 3 moves
// Blood Moor: 6 moves
// Cold Plains: 5 moves
```

It returns `null` when there is no way through. A `Route` iterates its moves directly when you
do not care about the boundaries, and exposes `legs` when you do — a transition always runs
from a leg's last move to the next leg's first, whether it is a staircase, an area border or a
teleport cast.

`RouteOptions` covers the movement rules the server enforces: `teleport`,
`teleportAcrossAreas`, `maxCastDistance` (the engine's own gate is 50), `castMetric`,
`snapRadius` and `collisionMask`.

Also `walkableAt`, `snap`, `lineOfSight` and `areasBetween` — the last names the trip without
pathing inside any of it, which is much cheaper when you only want to know the way.

## Units get in the way

A path that ignores what is standing on the map is not a path a character can walk. Place
units into an area and routing goes around them:

```ts
cold.place({ id: 1, type: 1, x: 120, y: 200 });
cold.occupy(monsters);        // or a whole iterable at once
cold.lift(1);
cold.clearUnits();
```

## Drawing it

```ts
import { rasterize, twoTone, Minimap } from 'libd2';

const raster = rasterize(cold.collision, twoTone(0x2b2b2bff, 0x808080ff));
```

`rasterize` takes a grid and a `Paint` — a function from a cell's collision flags to an RGBA
number. `twoTone` is the usual one; writing your own is how you shade line-of-sight blockers
differently from walls, which is the whole reason it is a function and not a palette.

`Minimap` projects a level the way the game's automap does, and inverts exactly, so a click
maps back to a subtile. `wallSegments` and `floorRuns` give the geometry instead of pixels.

## ESM, and what that means for `require`

The package is **ESM only**. There is deliberately no CommonJS build: Node can `require()` an
ESM graph since 22.12 as long as it has no top-level await, and the shim has none. That sets
the floor at **Node 22.12**, which the package declares in `engines`.

## In the browser

The same import works unchanged. The shim resolves its wasm relative to its own module URL and
feature-detects how to read it, so it uses `fetch` on the web and the filesystem under Node
without being told which it is:

```html
<script type="module">
  import { init, open, Areas } from '/node_modules/libd2/index.js';
  await init();
  using game = open({ seed: 1337 });
  document.body.textContent = `${game.area(Areas.ColdPlains).rooms.length} rooms`;
</script>
```

## Coordinates

Positions are world **subtiles** unless something says otherwise; a `Location` carries its area
so `tile` and `world` are properties of it rather than conversions you have to remember. Areas
are addressed by their `Levels.txt` id, which is stable across seeds — `Areas` is the named
enum of them.

## The older per-subsystem packages

`@jaenster/d2drlg` was the previous shape: one npm package per subsystem, wrapping the C ABI
directly. It is deprecated in favour of `libd2`. Existing installs keep working; new code
should use `libd2`.
