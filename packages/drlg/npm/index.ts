// Tiny typed shim over the d2drlg wasm C-ABI. Pure TypeScript — runs natively on
// Node (>=23.6 / --experimental-strip-types), Bun, Deno, and any TS bundler.
// Construction "just happens on usage": the top-level functions lazily load and
// instantiate the wasm on first call and cache a singleton. No open()/close()
// needed — but they are exported for those who want lifecycle control.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const PAGE = 65536;
const ROOM = 24; // sizeof(D2DrlgRoom): 6 x int32

export interface D2Room {
  x: number; y: number; w: number; h: number;
  /** RoomEx.nType */
  nType: number;
  /** RoomEx.nPresetType */
  nPresetType: number;
}
export interface D2Level {
  /** Levels.txt id */
  id: number;
  /** 1 maze, 2 preset, 3 wilderness */
  drlgType: number;
  /** placed on the surface by the act placement graph (vs. interior) */
  placed: boolean;
  rooms: D2Room[];
}
export interface D2Act {
  seed: number;
  /** 0 normal, 1 nightmare, 2 hell */
  difficulty: number;
  /** 0-based act number (0 = Act I) */
  act: number;
  levels: D2Level[];
}

interface Exports {
  memory: WebAssembly.Memory;
  d2drlg_ctx_create(): number;
  d2drlg_ctx_destroy(ctx: number): void;
  d2drlg_gen_act(ctx: number, seed: number, diff: number, act: number): number;
  d2drlg_act_free(act: number): void;
  d2drlg_act_level_count(act: number): number;
  d2drlg_act_level_id(act: number, i: number): number;
  d2drlg_act_level_drlg_type(act: number, i: number): number;
  d2drlg_act_level_placed(act: number, i: number): number;
  d2drlg_act_level_room_count(act: number, i: number): number;
  d2drlg_act_rooms(act: number, i: number, out: number, cap: number): number;
  d2drlg_abi_version(): number;
}

// Grow linear memory by enough pages to hold `bytes`, returning the base offset of
// the freshly-added (guaranteed-unused) region. grow() detaches the old
// ArrayBuffer, so re-read `memory.buffer` after calling this.
function scratch(memory: WebAssembly.Memory, bytes: number): number {
  const prev = memory.grow(Math.ceil((bytes || 1) / PAGE) || 1);
  return prev * PAGE;
}

/** Load the wasm + game tables and return a generator. */
export async function open(): Promise<Drlg> {
  const bytes = await readFile(fileURLToPath(new URL('./d2drlg.wasm', import.meta.url)));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const ex = instance.exports as unknown as Exports;
  const ctx = ex.d2drlg_ctx_create();
  if (!ctx) throw new Error('d2drlg: ctx_create failed');
  return new Drlg(ex, ctx);
}

export class Drlg {
  #ex: Exports;
  #ctx: number;
  constructor(ex: Exports, ctx: number) { this.#ex = ex; this.#ctx = ctx; }

  /** Generate an entire act. difficulty 0/1/2, actNo 0..4. */
  generateAct(seed: number, difficulty = 0, actNo = 0): D2Act {
    const ex = this.#ex;
    const act = ex.d2drlg_gen_act(this.#ctx, seed >>> 0, difficulty, actNo);
    if (!act) throw new Error('d2drlg: gen_act failed');
    try {
      const levels: D2Level[] = [];
      const n = ex.d2drlg_act_level_count(act);
      for (let i = 0; i < n; i++) {
        const roomCount = ex.d2drlg_act_level_room_count(act, i);
        const base = scratch(ex.memory, roomCount * ROOM);
        ex.d2drlg_act_rooms(act, i, base, roomCount);
        const dv = new DataView(ex.memory.buffer);
        const rooms: D2Room[] = [];
        for (let r = 0; r < roomCount; r++) {
          const b = base + r * ROOM;
          rooms.push({
            x: dv.getInt32(b, true), y: dv.getInt32(b + 4, true),
            w: dv.getInt32(b + 8, true), h: dv.getInt32(b + 12, true),
            nType: dv.getInt32(b + 16, true), nPresetType: dv.getInt32(b + 20, true),
          });
        }
        levels.push({
          id: ex.d2drlg_act_level_id(act, i),
          drlgType: ex.d2drlg_act_level_drlg_type(act, i),
          placed: ex.d2drlg_act_level_placed(act, i) === 1,
          rooms,
        });
      }
      return { seed: seed >>> 0, difficulty, act: actNo, levels };
    } finally {
      ex.d2drlg_act_free(act);
    }
  }

  /** ABI version of the loaded module. */
  abiVersion(): number { return this.#ex.d2drlg_abi_version(); }

  /** Free the context. */
  close(): void { this.#ex.d2drlg_ctx_destroy(this.#ctx); }
}

// Lazy singleton: construction just happens on first use.
let _p: Promise<Drlg> | undefined;
const inst = (): Promise<Drlg> => (_p ??= open());

/** Generate an entire act. Lazily loads the wasm on first call. */
export async function generateAct(seed: number, difficulty = 0, actNo = 0): Promise<D2Act> {
  return (await inst()).generateAct(seed, difficulty, actNo);
}

/** ABI version of the module. Lazily loads the wasm on first call. */
export async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

export default generateAct;
