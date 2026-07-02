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
import { shrines, generateAct } from '@jaenster/d2drlg';

// Seeded outdoor shrines/wells of a level. Cold Plains = level 3.
const s = await shrines(1337, 3);
for (const sh of s)
  console.log(`${sh.isWell ? 'well ' : 'shrine'} at tile (${sh.tileX}, ${sh.tileY})`);

// Or a whole act's room layout (difficulty 0/1/2, actNo 0..4).
const act = await generateAct(305419896, 0, 0);
console.log(`Act I: ${act.levels.length} levels, town has ${act.levels[0].rooms.length} rooms`);
```

CommonJS is identical via `require`:

```js
const { shrines } = require('@jaenster/d2drlg');
shrines(1337, 3).then(list => console.log(list));
```

`x`/`y` on a shrine are world **subtiles**; `tileX`/`tileY` are `Math.floor(x/5)`;
`isWell` is `classId === 130`. `difficulty` is `0` normal / `1` nightmare / `2`
hell; `actNo` is 0-based (Act I = 0); levels use their `Levels.txt` id.

For lifecycle control, `open()` returns a reusable instance exposing the same
methods plus `close()`:

```ts
import { open } from '@jaenster/d2drlg';
const drlg = await open();
try { console.log(drlg.shrines(1337, 3)); }
finally { drlg.close(); }
```

Every other package (e.g. `@jaenster/d2items`) ships the same shape: lazy
top-level functions over its own typed shim.
