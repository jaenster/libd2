# libd2 from Node (WebAssembly)

The wasm build is published to npm. See the
[API reference](../../README.md#reference-api-the-items-package).

```sh
npm install @jaenster/d2items
```

```js
import { instantiate } from '@jaenster/d2items';

const { exports, memory } = await instantiate();
const ctx = exports.d2items_create();

// write the treasure-class string into wasm memory
const enc = new TextEncoder().encode("Act 1 Equip A\0");
const strPtr = 1024;                       // scratch offset
new Uint8Array(memory.buffer).set(enc, strPtr);

const outPtr = 4096, cap = 16;
const n = exports.d2items_roll(ctx, 12345, strPtr, 5, 0, outPtr, cap);

// D2ItemsDrop is 28 bytes; item_code is at offset 1, item_level at 24
const mem = new DataView(memory.buffer);
for (let i = 0; i < Math.min(n, cap); i++) {
  const base = outPtr + i * 28;
  const code = String.fromCharCode(...new Uint8Array(memory.buffer, base + 1, 4)).replace(/\0/g, '');
  console.log(`drop ${i}: ${code} ilvl=${mem.getInt32(base + 24, true)}`);
}
exports.d2items_destroy(ctx);
```

The npm package exposes the raw C-ABI exports plus the wasm `memory`; you pass
strings/structs as byte offsets into that memory, as shown above.
