# libd2 from JavaScript

```sh
npm install libd2
```

One package for the whole library. Each subsystem is a namespace carrying its own
WebAssembly build, and the wasm for a namespace is only fetched when you actually call into
it. No native addon, no build step, nothing to initialise.

The wasm is freestanding and libc-free, so its import object is empty and the same package
runs in **Node, Bun, Deno and the browser** with no bundler configuration and no polyfills.

## Generate a map from a seed

```ts
import { drlg } from 'libd2';

// A whole act in the map shape: every level with its rooms, presets, adjacents and
// collision grid. difficulty 0/1/2, actNo 0-based (Act I = 0). Cold Plains = level 3.
const map = await drlg.render(1337, 0, 0);
const coldPlains = map.levels.find(l => l.levelNo === 3)!;

console.log(`${map.levels.length} levels`);
console.log(`${coldPlains.displayName}: ${coldPlains.rooms.length} rooms`);

// Shrines and wells are already among the level's presets, so reading them off a
// generated level is a filter rather than a second generation.
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

`generateAct(seed, difficulty, actNo)` is the cheaper call when you only want room layout
and not the per-level map data.

## Importing one namespace

Every namespace is also a subpath export, so a bundler can pull in one subsystem's wasm
instead of all of them:

```ts
import * as drlg from 'libd2/drlg';
```

## ESM, and what that means for `require`

The package is **ESM only**. There is deliberately no CommonJS build: Node can `require()` an
ESM graph since 22.12 as long as it has no top-level await, and these shims have none. So
this works from CommonJS without a second build:

```js
const { drlg } = require('libd2');
drlg.render(1337, 0, 0).then(map => console.log(map.levels.length));
```

That sets the floor at **Node 22.12**, which the package declares in `engines`.

## In the browser

The same import works unchanged. The shim resolves its wasm relative to its own module URL
and feature-detects how to read it, so it uses `fetch` on the web and the filesystem under
Node without being told which it is:

```html
<script type="module">
  import * as drlg from '/node_modules/libd2/drlg/index.js';
  const map = await drlg.render(1337, 0, 0);
  document.body.textContent = `${map.levels.length} levels`;
</script>
```

## Coordinates and ids

Shrine `x`/`y` are world **subtiles**; `tileX`/`tileY` are `Math.floor(x/5)`; `isWell` is
`classId === 130`. Preset units come back in **level-local** subtiles, which is the frame the
level's own map data is authored in — `levelShrines` is what converts them to world subtiles,
using the level's origin. Levels are addressed by their `Levels.txt` id, which is stable
across seeds.

## Lifecycle

The top-level functions load the wasm on first call and cache a single instance, which is
what you want most of the time. For explicit control, `open()` returns an instance exposing
the same methods plus `close()`:

```ts
import { drlg } from 'libd2';

const d = await drlg.open();
try {
  const map = d.render(1337, 0);
  console.log(drlg.levelShrines(map.levels.find(l => l.levelNo === 3)!).length);
} finally {
  d.close();
}
```

## Namespaces

| namespace | what it is |
|-|-|
| `drlg` | map generation: rooms, objects, monsters, level adjacency, subtile collision |

More land here as they grow a C ABI.

## The older per-subsystem packages

`@jaenster/d2drlg` was the previous shape, one npm package per subsystem. It is deprecated in
favour of `libd2`, which carries the same wasm and the same shim under the `drlg` namespace.
Existing installs keep working; new code should use `libd2`.
