# @jaenster/d2drlg

Faithful, clean-room **Diablo II 1.14d DRLG** (Diablo Resource Level Generation) —
the deterministic, seed-driven map generator — compiled to WebAssembly behind a
tiny typed shim. Given a seed it reproduces the room/tile layout and seeded object
placement for every level in all five acts, byte-for-byte with the original engine.

Pure Wasm + TypeScript: **no native addon, no build step**. Ships ESM and CommonJS
with `.d.ts` types; the wasm loads lazily on first call, so there's nothing to
initialise.

## Install

```sh
npm install @jaenster/d2drlg
# or: pnpm add @jaenster/d2drlg
```

## Usage

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

## API

- `shrines(seed, levelId, difficulty?=0, actNo?=0): Promise<D2Shrine[]>` — a level's
  seeded shrines/wells. `x`/`y` are world **subtiles**; `tileX`/`tileY` are
  `Math.floor(x/5)`; `isWell` is `classId === 130`.
- `generateAct(seed, difficulty?=0, actNo?=0): Promise<D2Act>` — every level in an act
  with its generated rooms.
- `abiVersion(): Promise<number>` — the module's C-ABI version.
- `open(): Promise<Drlg>` — a reusable instance with the same methods plus `close()`,
  for lifecycle control.

`difficulty` is `0` normal / `1` nightmare / `2` hell; `actNo` / `act` are 0-based
(Act I = 0); levels use their `Levels.txt` id (Cold Plains = 3).

Reproduces 1.14d generation faithfully — positions are the original engine's. Ships
no Blizzard assets, only the clean-room generator and the read-only data tables it
needs. MIT · part of [libd2](https://github.com/jaenster/libd2).
