// Tiny typed shim over the d2items wasm C-ABI. Pure TypeScript — runs natively on
// Node (>=23.6 / --experimental-strip-types), Bun, Deno, and any TS bundler.
// Construction "just happens on usage": the top-level roll()/abiVersion() lazily
// load and instantiate the wasm on first call and cache a singleton. No
// open()/close() needed — but they are exported for lifecycle control.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const PAGE = 65536;

// D2ItemsDrop layout (C ABI, extern struct — i32 fields force 4-byte alignment):
//   kind          u8    @ 0
//   item_code     u8[4] @ 1
//   quality       u8    @ 5
//   prefix_id     u16   @ 6
//   suffix_id     u16   @ 8
//   rare_prefix   u16[3]@ 10 (10,12,14)
//   rare_suffix   u16[3]@ 16 (16,18,20)
//   sockets       u8    @ 22
//   quantity      i32   @ 24  (aligned up from 23)
//   item_level    i32   @ 28
// total sizeof = 32 (already 4-aligned)
const DROP = 32;
const OFF = {
  kind: 0, itemCode: 1, quality: 5, prefixId: 6, suffixId: 8,
  rarePrefix: 10, rareSuffix: 16, sockets: 22, quantity: 24, itemLevel: 28,
} as const;
const CAP = 64; // max drops per roll

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

/** Load the wasm + game tables and return a roller. */
export async function open(): Promise<Items> {
  const bytes = await readFile(fileURLToPath(new URL('./d2items.wasm', import.meta.url)));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const ex = instance.exports as unknown as Exports;
  const ctx = ex.d2items_create();
  if (!ctx) throw new Error('d2items: create failed');
  return new Items(ex, ctx);
}

export class Items {
  #ex: Exports;
  #ctx: number;
  constructor(ex: Exports, ctx: number) { this.#ex = ex; this.#ctx = ctx; }

  /** Roll a drop for (seed, tcName, mlvl, mf). Returns all produced drops. */
  roll(seed: number, tcName: string, mlvl: number, mf = 0): D2ItemsDrop[] {
    const ex = this.#ex;
    const name = new TextEncoder().encode(tcName);
    // scratch region: NUL-terminated tc name + the out buffer, in one grow.
    const namePtr = scratch(ex.memory, name.length + 1 + CAP * DROP);
    const outPtr = namePtr + name.length + 1;
    const mem = new Uint8Array(ex.memory.buffer);
    mem.set(name, namePtr);
    mem[namePtr + name.length] = 0;
    const n = ex.d2items_roll(this.#ctx, seed >>> 0, namePtr, mlvl, mf, outPtr, CAP);
    if (n < 0) throw new Error(`d2items: roll failed (${n})`);
    return decodeDrops(ex.memory, outPtr, Math.min(n, CAP));
  }

  /** ABI version of the loaded module. */
  abiVersion(): number { return this.#ex.d2items_abi_version(); }

  /** Free the context. */
  close(): void { this.#ex.d2items_destroy(this.#ctx); }
}

// Lazy singleton: construction just happens on first use.
let _p: Promise<Items> | undefined;
const inst = (): Promise<Items> => (_p ??= open());

/** Roll a drop. Lazily loads the wasm on first call. */
export async function roll(seed: number, tcName: string, mlvl: number, mf = 0): Promise<D2ItemsDrop[]> {
  return (await inst()).roll(seed, tcName, mlvl, mf);
}

/** ABI version of the module. Lazily loads the wasm on first call. */
export async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

export default roll;
