// CommonJS build of the d2drlg wasm shim. Node runs .cts natively by stripping
// types, but does NOT rewrite export/import — so this file uses require() +
// module.exports + __dirname. Same lazy API as index.ts.
const { readFile } = require('node:fs/promises') as typeof import('node:fs/promises');
const { join } = require('node:path') as typeof import('node:path');

const PAGE = 65536;
const ROOM = 24; // sizeof(D2DrlgRoom): 6 x int32
const SHRINE = 12; // sizeof(D2DrlgShrine): 3 x int32

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
export interface D2Shrine {
  /** objects.txt class id: 130=Well, 84/2/81/83=Shrine variants */
  classId: number;
  /** world SUBTILE X */
  x: number;
  /** world SUBTILE Y */
  y: number;
  /** tile X = floor(x / 5) */
  tileX: number;
  /** tile Y = floor(y / 5) */
  tileY: number;
  /** classId === 130 */
  isWell: boolean;
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
  d2drlg_level_shrines(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number): number;
  d2drlg_abi_version(): number;
}

function scratch(memory: WebAssembly.Memory, bytes: number): number {
  const prev = memory.grow(Math.ceil((bytes || 1) / PAGE) || 1);
  return prev * PAGE;
}

async function open(): Promise<Drlg> {
  const bytes = await readFile(join(__dirname, 'd2drlg.wasm'));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const ex = instance.exports as unknown as Exports;
  const ctx = ex.d2drlg_ctx_create();
  if (!ctx) throw new Error('d2drlg: ctx_create failed');
  return new Drlg(ex, ctx);
}

class Drlg {
  #ex: Exports;
  #ctx: number;
  constructor(ex: Exports, ctx: number) { this.#ex = ex; this.#ctx = ctx; }

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

  shrines(seed: number, levelId: number, difficulty = 0, actNo = 0): D2Shrine[] {
    void actNo; // the owning act is derived from levelId; actNo accepted for API symmetry
    const ex = this.#ex;
    let cap = 64;
    let base = scratch(ex.memory, cap * SHRINE);
    let n = ex.d2drlg_level_shrines(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    if (n < 0) throw new Error('d2drlg: level_shrines failed (' + n + ')');
    if (n > cap) {
      cap = n;
      base = scratch(ex.memory, cap * SHRINE);
      n = ex.d2drlg_level_shrines(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    }
    const dv = new DataView(ex.memory.buffer);
    const out: D2Shrine[] = [];
    for (let i = 0; i < n; i++) {
      const b = base + i * SHRINE;
      const classId = dv.getInt32(b, true);
      const x = dv.getInt32(b + 4, true);
      const y = dv.getInt32(b + 8, true);
      out.push({ classId, x, y, tileX: Math.floor(x / 5), tileY: Math.floor(y / 5), isWell: classId === 130 });
    }
    return out;
  }

  abiVersion(): number { return this.#ex.d2drlg_abi_version(); }
  close(): void { this.#ex.d2drlg_ctx_destroy(this.#ctx); }
}

let _p: Promise<Drlg> | undefined;
const inst = (): Promise<Drlg> => (_p ??= open());

async function generateAct(seed: number, difficulty = 0, actNo = 0): Promise<D2Act> {
  return (await inst()).generateAct(seed, difficulty, actNo);
}
async function shrines(seed: number, levelId: number, difficulty = 0, actNo = 0): Promise<D2Shrine[]> {
  return (await inst()).shrines(seed, levelId, difficulty, actNo);
}
async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

module.exports = { generateAct, shrines, abiVersion, open, Drlg };
module.exports.default = generateAct;
