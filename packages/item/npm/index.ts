// Tiny typed shim over the d2item wasm C-ABI. Pure TypeScript — runs natively on
// Node (>=23.6 / --experimental-strip-types), Bun, Deno, and any TS bundler.
// Construction "just happens on usage": the top-level roll()/abiVersion() lazily
// load and instantiate the wasm on first call and cache a singleton. No
// open()/close() needed — but they are exported for lifecycle control.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const PAGE = 65536;

// D2ItemDrop layout (C ABI, extern struct — i32 fields force 4-byte alignment):
//   kind          u8    @ 0
//   item_code     u8[4] @ 1
//   quality       u8    @ 5
//   prefix_id     u16   @ 6
//   suffix_id     u16   @ 8
//   rare_prefix   u16[3]@ 10 (10,12,14)
//   rare_suffix   u16[3]@ 16 (16,18,20)
//   rare_prefix_name u16 @ 22
//   rare_suffix_name u16 @ 24
//   unique_id     u16   @ 26
//   set_id        u16   @ 28
//   quality_id    u16   @ 30
//   low_quality_id u16  @ 32
//   auto_prefix_id u16  @ 34
//   sockets       u8    @ 36
//   ethereal      u8    @ 37
//   quantity      i32   @ 40  (aligned up from 38)
//   item_level    i32   @ 44
//   item_seed     u32   @ 48
// total sizeof = 52 (already 4-aligned)
const DROP = 52;
const OFF = {
  kind: 0, itemCode: 1, quality: 5, prefixId: 6, suffixId: 8,
  rarePrefix: 10, rareSuffix: 16, rarePrefixName: 22, rareSuffixName: 24,
  uniqueId: 26, setId: 28, qualityId: 30, lowQualityId: 32, autoPrefixId: 34,
  sockets: 36, ethereal: 37, quantity: 40, itemLevel: 44, itemSeed: 48,
} as const;
const CAP = 64; // max drops per roll

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

/** Load the wasm + game tables and return a roller. */
export async function open(): Promise<Items> {
  const bytes = await readFile(fileURLToPath(new URL('./d2item.wasm', import.meta.url)));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const ex = instance.exports as unknown as Exports;
  const ctx = ex.d2item_create();
  if (!ctx) throw new Error('d2item: create failed');
  return new Items(ex, ctx);
}

export class Items {
  #ex: Exports;
  #ctx: number;
  constructor(ex: Exports, ctx: number) { this.#ex = ex; this.#ctx = ctx; }

  /** Roll a drop for (seed, tcName, mlvl, mf). Returns all produced drops. */
  roll(seed: number, tcName: string, mlvl: number, mf = 0): D2ItemDrop[] {
    const ex = this.#ex;
    const name = new TextEncoder().encode(tcName);
    // scratch region: NUL-terminated tc name + the out buffer, in one grow.
    const namePtr = scratch(ex.memory, name.length + 1 + CAP * DROP);
    const outPtr = namePtr + name.length + 1;
    const mem = new Uint8Array(ex.memory.buffer);
    mem.set(name, namePtr);
    mem[namePtr + name.length] = 0;
    const n = ex.d2item_roll(this.#ctx, seed >>> 0, namePtr, mlvl, mf, outPtr, CAP);
    if (n < 0) throw new Error(`d2item: roll failed (${n})`);
    return decodeDrops(ex.memory, outPtr, Math.min(n, CAP));
  }

  /** ABI version of the loaded module. */
  abiVersion(): number { return this.#ex.d2item_abi_version(); }

  /** Free the context. */
  close(): void { this.#ex.d2item_destroy(this.#ctx); }
}

// Lazy singleton: construction just happens on first use.
let _p: Promise<Items> | undefined;
const inst = (): Promise<Items> => (_p ??= open());

/** Roll a drop. Lazily loads the wasm on first call. */
export async function roll(seed: number, tcName: string, mlvl: number, mf = 0): Promise<D2ItemDrop[]> {
  return (await inst()).roll(seed, tcName, mlvl, mf);
}

/** ABI version of the module. Lazily loads the wasm on first call. */
export async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

export default roll;
