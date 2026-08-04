# libd2 from Node (WebAssembly)

Each package is published to npm as `@jaenster/d2<pkg>` — the libc-free wasm build
behind a tiny typed shim. Pure Wasm + TypeScript: **no native addon, no build
step**. Ships ESM and CommonJS with `.d.ts` types; the wasm loads lazily on first
call, so there's nothing to initialise.

## drlg — generate a map from a seed

```sh
npm install @jaenster/d2drlg
# or: pnpm add @jaenster/d2drlg
```

The top-level functions lazily load the wasm and cache a singleton:

```ts
import { render, levelShrines, generateAct } from '@jaenster/d2drlg';

// A whole act in the map shape: every level with its rooms, presets, adjacents and
// collision grid (difficulty 0/1/2, actNo 0..4). Cold Plains = level 3.
const map = await render(1337, 0, 0);
const coldPlains = map.levels.find(l => l.levelNo === 3)!;

// A level's seeded outdoor shrines/wells are already among its presets, so reading
// them off a generated level is a filter — no second generation.
for (const sh of levelShrines(coldPlains))
  console.log(`${sh.isWell ? 'well ' : 'shrine'} at tile (${sh.tileX}, ${sh.tileY})`);

// Or just an act's room layout, without the per-level map data.
const act = await generateAct(305419896, 0, 0);
console.log(`Act I: ${act.levels.length} levels, town has ${act.levels[0].rooms.length} rooms`);
```

CommonJS is identical via `require`:

```js
const { render, levelShrines } = require('@jaenster/d2drlg');
render(1337, 0, 0).then(map => console.log(levelShrines(map.levels.find(l => l.levelNo === 3))));
```

`x`/`y` on a shrine are world **subtiles**; `tileX`/`tileY` are `Math.floor(x/5)`;
`isWell` is `classId === 130`. `levelShrines` is synchronous and touches no wasm — it
filters the level's own `presets` for the rows the outdoor spawner uses
(`SHRINE_TXT_FILE_NOS`) and shifts them from level-local into world subtiles.
`difficulty` is `0` normal / `1` nightmare / `2` hell; `actNo` is 0-based (Act I = 0);
levels use their `Levels.txt` id.

The seed-keyed `shrines(seed, levelId)` still exists and still returns the same values,
but it is **deprecated**: it generates an entire act to hand back data the level already
carries. Prefer `levelShrines(level)`.

For lifecycle control, `open()` returns a reusable instance exposing the same
methods plus `close()`:

```ts
import { open, levelShrines } from '@jaenster/d2drlg';
const drlg = await open();
try { console.log(levelShrines(drlg.render(1337, 0).levels.find(l => l.levelNo === 3)!)); }
finally { drlg.close(); }
```

Every other package (e.g. `@jaenster/d2item`) ships the same shape: lazy
top-level functions over its own typed shim.
