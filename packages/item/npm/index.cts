// CommonJS build of the d2item wasm shim. Node runs .cts natively by stripping
// types, but does NOT rewrite export/import — so this file uses require() +
// module.exports + __dirname. Same lazy API as index.ts.
const { readFile } = require('node:fs/promises') as typeof import('node:fs/promises');
const { join } = require('node:path') as typeof import('node:path');

const PAGE = 65536;

// D2ItemDrop layout (C ABI, extern struct — i32 fields force 4-byte alignment):
//   kind u8@0, item_code u8[4]@1, quality u8@5, prefix_id u16@6, suffix_id u16@8,
//   rare_prefix u16[3]@10, rare_suffix u16[3]@16, rare_prefix_name u16@22,
//   rare_suffix_name u16@24, unique_id u16@26, set_id u16@28, quality_id u16@30,
//   low_quality_id u16@32, auto_prefix_id u16@34, sockets u8@36, ethereal u8@37,
//   quantity i32@40, item_level i32@44, item_seed u32@48 ; sizeof = 52
const DROP = 52;
const OFF = {
  kind: 0, itemCode: 1, quality: 5, prefixId: 6, suffixId: 8,
  rarePrefix: 10, rareSuffix: 16, rarePrefixName: 22, rareSuffixName: 24,
  uniqueId: 26, setId: 28, qualityId: 30, lowQualityId: 32, autoPrefixId: 34,
  sockets: 36, ethereal: 37, quantity: 40, itemLevel: 44, itemSeed: 48,
} as const;
const CAP = 64;

export interface D2ItemDrop {
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
  /** RarePrefix/RareSuffix.txt rows (1-based) forming the item's rare NAME */
  rarePrefixName: number;
  rareSuffixName: number;
  /** UniqueItems / SetItems / QualityItems / LowQualityItems rows (1-based, 0 = none) */
  uniqueId: number;
  setId: number;
  qualityId: number;
  lowQualityId: number;
  /** MagicPrefix.txt row (1-based) of the base item's automagic affix */
  autoPrefixId: number;
  sockets: number;
  ethereal: boolean;
  /** gold amount / stack size */
  quantity: number;
  itemLevel: number;
  /** low word of the item's mod seed — replays its property rolls */
  itemSeed: number;
}

interface Exports {
  memory: WebAssembly.Memory;
  d2item_create(): number;
  d2item_destroy(ctx: number): void;
  d2item_roll(ctx: number, seed: number, tcName: number, mlvl: number, mf: number, out: number, cap: number): number;
  d2item_abi_version(): number;
}

function scratch(memory: WebAssembly.Memory, bytes: number): number {
  const prev = memory.grow(Math.ceil((bytes || 1) / PAGE) || 1);
  return prev * PAGE;
}

function decodeDrops(memory: WebAssembly.Memory, base: number, count: number): D2ItemDrop[] {
  const dv = new DataView(memory.buffer);
  const u8 = new Uint8Array(memory.buffer);
  const out: D2ItemDrop[] = [];
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
      rarePrefixName: dv.getUint16(b + OFF.rarePrefixName, true),
      rareSuffixName: dv.getUint16(b + OFF.rareSuffixName, true),
      uniqueId: dv.getUint16(b + OFF.uniqueId, true),
      setId: dv.getUint16(b + OFF.setId, true),
      qualityId: dv.getUint16(b + OFF.qualityId, true),
      lowQualityId: dv.getUint16(b + OFF.lowQualityId, true),
      autoPrefixId: dv.getUint16(b + OFF.autoPrefixId, true),
      sockets: u8[b + OFF.sockets],
      ethereal: u8[b + OFF.ethereal] !== 0,
      quantity: dv.getInt32(b + OFF.quantity, true),
      itemLevel: dv.getInt32(b + OFF.itemLevel, true),
      itemSeed: dv.getUint32(b + OFF.itemSeed, true),
    });
  }
  return out;
}

async function open(): Promise<Items> {
  const bytes = await readFile(join(__dirname, 'd2item.wasm'));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const ex = instance.exports as unknown as Exports;
  const ctx = ex.d2item_create();
  if (!ctx) throw new Error('d2item: create failed');
  return new Items(ex, ctx);
}

class Items {
  #ex: Exports;
  #ctx: number;
  constructor(ex: Exports, ctx: number) { this.#ex = ex; this.#ctx = ctx; }

  roll(seed: number, tcName: string, mlvl: number, mf = 0): D2ItemDrop[] {
    const ex = this.#ex;
    const name = new TextEncoder().encode(tcName);
    const namePtr = scratch(ex.memory, name.length + 1 + CAP * DROP);
    const outPtr = namePtr + name.length + 1;
    const mem = new Uint8Array(ex.memory.buffer);
    mem.set(name, namePtr);
    mem[namePtr + name.length] = 0;
    const n = ex.d2item_roll(this.#ctx, seed >>> 0, namePtr, mlvl, mf, outPtr, CAP);
    if (n < 0) throw new Error(`d2item: roll failed (${n})`);
    return decodeDrops(ex.memory, outPtr, Math.min(n, CAP));
  }

  abiVersion(): number { return this.#ex.d2item_abi_version(); }
  close(): void { this.#ex.d2item_destroy(this.#ctx); }
}

let _p: Promise<Items> | undefined;
const inst = (): Promise<Items> => (_p ??= open());

async function roll(seed: number, tcName: string, mlvl: number, mf = 0): Promise<D2ItemDrop[]> {
  return (await inst()).roll(seed, tcName, mlvl, mf);
}
async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

module.exports = { roll, abiVersion, open, Items };
module.exports.default = roll;
