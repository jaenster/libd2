// CommonJS build of the d2items wasm shim. Node runs .cts natively by stripping
// types, but does NOT rewrite export/import — so this file uses require() +
// module.exports + __dirname. Same lazy API as index.ts.
const { readFile } = require('node:fs/promises') as typeof import('node:fs/promises');
const { join } = require('node:path') as typeof import('node:path');

const PAGE = 65536;

// D2ItemsDrop layout (C ABI, extern struct — i32 fields force 4-byte alignment):
//   kind u8@0, item_code u8[4]@1, quality u8@5, prefix_id u16@6, suffix_id u16@8,
//   rare_prefix u16[3]@10, rare_suffix u16[3]@16, sockets u8@22,
//   quantity i32@24, item_level i32@28 ; sizeof = 32
const DROP = 32;
const OFF = {
  kind: 0, itemCode: 1, quality: 5, prefixId: 6, suffixId: 8,
  rarePrefix: 10, rareSuffix: 16, sockets: 22, quantity: 24, itemLevel: 28,
} as const;
const CAP = 64;

export interface D2ItemsDrop {
  /** DropKind: none=0 gold=1 item=2 quiver=3 bodypart=4 */
  kind: number;
  /** base item code (4-char, NUL-trimmed) */
  itemCode: string;
  /** Quality: invalid=0 low=1 normal=2 superior=3 magic=4 set=5 rare=6 unique=7 crafted=8 tempered=9 */
  quality: number;
  prefixId: number;
  suffixId: number;
  rarePrefixIds: number[];
  rareSuffixIds: number[];
  sockets: number;
  /** gold amount / quiver count */
  quantity: number;
  itemLevel: number;
}

interface Exports {
  memory: WebAssembly.Memory;
  d2items_create(): number;
  d2items_destroy(ctx: number): void;
  d2items_roll(ctx: number, seed: number, tcName: number, mlvl: number, mf: number, out: number, cap: number): number;
  d2items_abi_version(): number;
}

function scratch(memory: WebAssembly.Memory, bytes: number): number {
  const prev = memory.grow(Math.ceil((bytes || 1) / PAGE) || 1);
  return prev * PAGE;
}

function decodeDrops(memory: WebAssembly.Memory, base: number, count: number): D2ItemsDrop[] {
  const dv = new DataView(memory.buffer);
  const u8 = new Uint8Array(memory.buffer);
  const out: D2ItemsDrop[] = [];
  for (let i = 0; i < count; i++) {
    const b = base + i * DROP;
    let itemCode = '';
    for (let c = 0; c < 4; c++) {
      const ch = u8[b + OFF.itemCode + c];
      if (ch === 0) break;
      itemCode += String.fromCharCode(ch);
    }
    out.push({
      kind: u8[b + OFF.kind],
      itemCode,
      quality: u8[b + OFF.quality],
      prefixId: dv.getUint16(b + OFF.prefixId, true),
      suffixId: dv.getUint16(b + OFF.suffixId, true),
      rarePrefixIds: [0, 1, 2].map((j) => dv.getUint16(b + OFF.rarePrefix + j * 2, true)),
      rareSuffixIds: [0, 1, 2].map((j) => dv.getUint16(b + OFF.rareSuffix + j * 2, true)),
      sockets: u8[b + OFF.sockets],
      quantity: dv.getInt32(b + OFF.quantity, true),
      itemLevel: dv.getInt32(b + OFF.itemLevel, true),
    });
  }
  return out;
}

async function open(): Promise<Items> {
  const bytes = await readFile(join(__dirname, 'd2items.wasm'));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const ex = instance.exports as unknown as Exports;
  const ctx = ex.d2items_create();
  if (!ctx) throw new Error('d2items: create failed');
  return new Items(ex, ctx);
}

class Items {
  #ex: Exports;
  #ctx: number;
  constructor(ex: Exports, ctx: number) { this.#ex = ex; this.#ctx = ctx; }

  roll(seed: number, tcName: string, mlvl: number, mf = 0): D2ItemsDrop[] {
    const ex = this.#ex;
    const name = new TextEncoder().encode(tcName);
    const namePtr = scratch(ex.memory, name.length + 1 + CAP * DROP);
    const outPtr = namePtr + name.length + 1;
    const mem = new Uint8Array(ex.memory.buffer);
    mem.set(name, namePtr);
    mem[namePtr + name.length] = 0;
    const n = ex.d2items_roll(this.#ctx, seed >>> 0, namePtr, mlvl, mf, outPtr, CAP);
    if (n < 0) throw new Error(`d2items: roll failed (${n})`);
    return decodeDrops(ex.memory, outPtr, Math.min(n, CAP));
  }

  abiVersion(): number { return this.#ex.d2items_abi_version(); }
  close(): void { this.#ex.d2items_destroy(this.#ctx); }
}

let _p: Promise<Items> | undefined;
const inst = (): Promise<Items> => (_p ??= open());

async function roll(seed: number, tcName: string, mlvl: number, mf = 0): Promise<D2ItemsDrop[]> {
  return (await inst()).roll(seed, tcName, mlvl, mf);
}
async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

module.exports = { roll, abiVersion, open, Items };
module.exports.default = roll;
