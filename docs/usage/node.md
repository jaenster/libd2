# libd2 from Node (WebAssembly)

The libc-free wasm build is published to npm (freestanding — it imports nothing,
so it just instantiates). See the
[API reference](../../README.md#reference-api-the-drlg-map-generator).

## drlg — generate a map from a seed

```sh
npm install @jaenster/d2drlg
```

```js
import { instantiate } from '@jaenster/d2drlg';

const { exports, memory } = await instantiate();
const ctx = exports.d2drlg_ctx_create();
const act = exports.d2drlg_gen_act(ctx, 305419896, 0, 0);   // seed, normal, Act I
console.log('act I:', exports.d2drlg_act_level_count(act), 'levels');

// d2drlg_act_rooms writes D2DrlgRoom[] (6 × int32 = 24 bytes each) at a scratch ptr
const outPtr = 65536, cap = 128;
const n = exports.d2drlg_act_rooms(act, 0, outPtr, cap);
const view = new DataView(memory.buffer);
for (let i = 0; i < Math.min(n, cap); i++) {
  const b = outPtr + i * 24;
  console.log(`room ${i}: (${view.getInt32(b, true)},${view.getInt32(b + 4, true)}) ` +
              `${view.getInt32(b + 8, true)}x${view.getInt32(b + 12, true)}`);
}
exports.d2drlg_act_free(act);
exports.d2drlg_ctx_destroy(ctx);
```

The npm package exposes the raw C-ABI exports plus the wasm `memory`; you pass
output buffers as byte offsets into that memory, as shown. Every other package
(e.g. `@jaenster/d2items`) works the same way.
