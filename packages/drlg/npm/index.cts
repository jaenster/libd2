// CommonJS build of the d2drlg wasm shim. Node runs .cts natively by stripping
// types, but does NOT rewrite export/import — so this file uses require() +
// module.exports + __dirname. Same lazy API as index.ts.
const { readFile } = require('node:fs/promises') as typeof import('node:fs/promises');
const { join } = require('node:path') as typeof import('node:path');
const { deflateSync } = require('node:zlib') as typeof import('node:zlib');

const PAGE = 65536;
const ROOM = 28; // sizeof(D2DrlgRoom): 7 x int32
const SHRINE = 12; // sizeof(D2DrlgShrine): 3 x int32
const PRESET = 16; // sizeof(D2DrlgPreset): 4 x int32
const ADJ = 12; // sizeof(D2DrlgAdjacent): 3 x int32

/** One room in the low-level `generateAct` view: world TILE rect + engine type fields. */
export interface D2ActRoom {
  x: number; y: number; w: number; h: number;
  /** RoomEx.nType */
  nType: number;
  /** RoomEx.nPresetType (1 outdoor/maze, 2 preset) */
  nPresetType: number;
  /** preset nPickedFile / outdoor nSubThemePicked; -1 if neither */
  pickedFile: number;
}
/** One level in the low-level `generateAct` view (world TILE coords). */
export interface D2ActLevel {
  /** Levels.txt id */
  id: number;
  /** 1 maze, 2 preset, 3 wilderness */
  drlgType: number;
  /** placed on the surface by the act placement graph (vs. interior) */
  placed: boolean;
  /** generated world origin in TILES [x, y] */
  origin: [number, number];
  /** generated world size in TILES [w, h] */
  size: [number, number];
  rooms: D2ActRoom[];
}
export interface D2Act {
  seed: number;
  /** 0 normal, 1 nightmare, 2 hell */
  difficulty: number;
  /** 0-based act number (0 = Act I) */
  act: number;
  levels: D2ActLevel[];
}

/** One room in the DeadlyBossMods map shape: level-local SUBTILE rect + DS1 pick. */
export interface D2Room {
  /** level-local subtile X */
  x: number;
  /** level-local subtile Y */
  y: number;
  /** subtile width (tile width * 5) */
  sizeX: number;
  /** subtile height (tile height * 5) */
  sizeY: number;
  /** the room's DS1 pick (preset nPickedFile / outdoor nSubThemePicked) */
  roomNo: number;
  /** same source as roomNo (DBM reports them equal) */
  subNo: number;
}
/** One level in the DeadlyBossMods map shape. */
export interface D2Level {
  /** Levels.txt id */
  levelNo: number;
  /** DBM canonical level name (TitleCase display name, no spaces) */
  name: string;
  /** Levels.txt LevelName (the in-game display name) */
  displayName: string;
  /** 1-based act number (Act I = 1) */
  act: number;
  /** world origin in SUBTILES [x, y] (tile origin * 5) */
  origin: [number, number];
  /** world size in SUBTILES [w, h] (tile size * 5) */
  size: [number, number];
  rooms: D2Room[];
  /** preset units (objects / npc markers), DBM shape */
  presets: D2Preset[];
  /** adjacent levels (filled by a later phase) */
  adjacents: D2Adjacent[];
  /** navigation tells (filled by a later phase) */
  tells: unknown[];
  /** collision grid width in SUBTILES (== size[0]) */
  collisionWidth: number;
  /** collision grid height in SUBTILES (== size[1]) */
  collisionHeight: number;
  /**
   * base64 of zlib-deflate of the level-local subtile CollMap: one little-endian
   * uint16 per cell, row-major (collisionWidth*collisionHeight cells). Each cell is
   * the raw engine Colbit flag set (0x01 wall, 0x02 visible, 0x04 missile_barrier,
   * 0x08 noplayer, 0x10 preset, 0x20 no_floor, ...); uncovered/OOB cells are 0xFFFF.
   * Inflate with `zlib.inflateSync` to recover the grid; the inflated grid matches
   * DeadlyBossMods cell-for-cell.
   */
  collisionDeflateB64: string;
}
/** A level's raw collision grid: level-local subtile CollMap flags, row-major. */
export interface D2Collision {
  /** width in subtiles */
  width: number;
  /** height in subtiles */
  height: number;
  /** raw Colbit u16 per cell, row-major (width*height); 0xFFFF = uncovered/OOB */
  cells: Uint16Array;
}
/** A whole act's map in the DeadlyBossMods response shape. */
export interface D2Map {
  seed: number;
  levels: D2Level[];
}
export interface D2Preset {
  /** 'obj' = DS1/preset object (etype 2), 'npc' = monster/preset marker (etype 1) */
  type: 'obj' | 'npc';
  /** Objects.txt row (obj) or MonStats/preset class id (npc) */
  txtFileNo: number;
  /** level-LOCAL subtile X (matches DBM's frame) */
  x: number;
  /** level-LOCAL subtile Y (matches DBM's frame) */
  y: number;
  /** Objects.txt "Name" — present for obj entries only */
  name?: string;
  /** Objects.txt description ("description - not loaded") — obj entries only */
  description?: string;
}
/** One adjacent-level bridge tile in the DeadlyBossMods map shape. */
export interface D2Adjacent {
  /** Levels.txt id of the destination level this bridge tile leads to */
  levelNo: number;
  /** DBM canonical (TitleCase, spaceless) name of the destination level */
  name: string;
  /** Levels.txt LevelName (in-game display name) of the destination level */
  displayName: string;
  /** level-LOCAL subtile X of the bridge tile (this level's frame) */
  bridgeX: number;
  /** level-LOCAL subtile Y of the bridge tile (this level's frame) */
  bridgeY: number;
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
  d2drlg_act_level_origin(act: number, i: number, ox: number, oy: number): number;
  d2drlg_act_level_size(act: number, i: number, w: number, h: number): number;
  d2drlg_level_name(ctx: number, levelId: number, buf: number, cap: number): number;
  d2drlg_level_shrines(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number): number;
  d2drlg_level_presets(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number): number;
  d2drlg_level_adjacents(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number): number;
  d2drlg_level_collision_raw(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number, outW: number, outH: number): number;
  d2drlg_object_name(txtFileNo: number, buf: number, cap: number): number;
  d2drlg_object_desc(txtFileNo: number, buf: number, cap: number): number;
  d2drlg_abi_version(): number;
}

function scratch(memory: WebAssembly.Memory, bytes: number): number {
  const prev = memory.grow(Math.ceil((bytes || 1) / PAGE) || 1);
  return prev * PAGE;
}

// DBM's `name` field is the canonical level enum name: the display name with each
// word TitleCased and joined (spaces removed). A few ids keep their classic short
// enum name; those are overridden explicitly.
const DBM_NAME_OVERRIDE: Record<number, string> = { 1: 'RogueCamp', 39: 'CowLevel' };
function dbmLevelName(levelNo: number, displayName: string): string {
  const o = DBM_NAME_OVERRIDE[levelNo];
  if (o) return o;
  return displayName
    .split(' ')
    .filter((w) => w.length > 0)
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join('');
}

// DBM's displayName for a few ids diverges from Levels.txt LevelName (an internal
// string). Override to the canonical in-game name DBM reports.
const DBM_DISPLAY_OVERRIDE: Record<number, string> = { 39: 'The Secret Cow Level' };
function dbmDisplayName(levelNo: number, raw: string): string {
  return DBM_DISPLAY_OVERRIDE[levelNo] ?? raw;
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
      const levels: D2ActLevel[] = [];
      const n = ex.d2drlg_act_level_count(act);
      for (let i = 0; i < n; i++) {
        const roomCount = ex.d2drlg_act_level_room_count(act, i);
        const OUT = 16;
        const base = scratch(ex.memory, roomCount * ROOM + OUT);
        const outp = base + roomCount * ROOM;
        ex.d2drlg_act_rooms(act, i, base, roomCount);
        ex.d2drlg_act_level_origin(act, i, outp, outp + 4);
        ex.d2drlg_act_level_size(act, i, outp + 8, outp + 12);
        const dv = new DataView(ex.memory.buffer);
        const rooms: D2ActRoom[] = [];
        for (let r = 0; r < roomCount; r++) {
          const b = base + r * ROOM;
          rooms.push({
            x: dv.getInt32(b, true), y: dv.getInt32(b + 4, true),
            w: dv.getInt32(b + 8, true), h: dv.getInt32(b + 12, true),
            nType: dv.getInt32(b + 16, true), nPresetType: dv.getInt32(b + 20, true),
            pickedFile: dv.getInt32(b + 24, true),
          });
        }
        levels.push({
          id: ex.d2drlg_act_level_id(act, i),
          drlgType: ex.d2drlg_act_level_drlg_type(act, i),
          placed: ex.d2drlg_act_level_placed(act, i) === 1,
          origin: [dv.getInt32(outp, true), dv.getInt32(outp + 4, true)],
          size: [dv.getInt32(outp + 8, true), dv.getInt32(outp + 12, true)],
          rooms,
        });
      }
      return { seed: seed >>> 0, difficulty, act: actNo, levels };
    } finally {
      ex.d2drlg_act_free(act);
    }
  }

  #levelName(levelId: number): string {
    const ex = this.#ex;
    const CAP = 128;
    const buf = scratch(ex.memory, CAP);
    const len = ex.d2drlg_level_name(this.#ctx, levelId, buf, CAP);
    if (len <= 0) return '';
    const n = Math.min(len, CAP);
    return new TextDecoder('utf-8', { fatal: false }).decode(new Uint8Array(ex.memory.buffer, buf, n));
  }

  // Read a level's RAW subtile CollMap (level-local, row-major LE u16). Two passes:
  // probe (cap 0) to learn the grid dims, then fetch the whole grid. Returns a COPY
  // (wasm memory.grow may detach the backing buffer after this returns).
  #collisionRaw(seed: number, levelId: number, difficulty: number): D2Collision {
    const ex = this.#ex;
    const probe = scratch(ex.memory, 8);
    const total = ex.d2drlg_level_collision_raw(this.#ctx, seed >>> 0, difficulty, levelId, probe, 0, probe, probe + 4);
    if (total < 0) throw new Error('d2drlg: level_collision_raw failed (' + total + ')');
    const dv = new DataView(ex.memory.buffer);
    const width = dv.getInt32(probe, true);
    const height = dv.getInt32(probe + 4, true);
    if (total === 0 || width <= 0 || height <= 0) return { width: 0, height: 0, cells: new Uint16Array(0) };
    const cells = width * height;
    const base = scratch(ex.memory, cells * 2 + 8);
    const outp = base + cells * 2;
    ex.d2drlg_level_collision_raw(this.#ctx, seed >>> 0, difficulty, levelId, base, cells, outp, outp + 4);
    const u16 = new Uint16Array(ex.memory.buffer, base, cells).slice();
    return { width, height, cells: u16 };
  }

  collision(seed: number, levelId: number, difficulty = 0): D2Collision {
    return this.#collisionRaw(seed, levelId, difficulty);
  }

  render(seed: number, actNo = 0, difficulty = 0): D2Map {
    const s = seed >>> 0;
    const act = this.generateAct(s, difficulty, actNo);
    const levels: D2Level[] = act.levels.map((lv) => {
      const [ox, oy] = lv.origin; // tiles
      const displayName = dbmDisplayName(lv.id, this.#levelName(lv.id));
      const rooms: D2Room[] = lv.rooms.map((r) => ({
        x: (r.x - ox) * 5,
        y: (r.y - oy) * 5,
        sizeX: r.w * 5,
        sizeY: r.h * 5,
        roomNo: r.pickedFile,
        subNo: r.pickedFile,
      }));
      const coll = this.#collisionRaw(s, lv.id, difficulty);
      const cw = coll.width || lv.size[0] * 5;
      const ch = coll.height || lv.size[1] * 5;
      const cellCount = cw * ch;
      const u16 = coll.cells.length === cellCount ? coll.cells : new Uint16Array(cellCount).fill(0xffff);
      const collisionDeflateB64 = deflateSync(Buffer.from(u16.buffer, u16.byteOffset, u16.byteLength)).toString('base64');
      return {
        levelNo: lv.id,
        name: dbmLevelName(lv.id, displayName),
        displayName,
        act: actNo + 1,
        origin: [ox * 5, oy * 5],
        size: [lv.size[0] * 5, lv.size[1] * 5],
        rooms,
        presets: this.presets(s, lv.id, difficulty),
        adjacents: this.adjacents(s, lv.id, difficulty),
        tells: [],
        collisionWidth: cw,
        collisionHeight: ch,
        collisionDeflateB64,
      };
    });
    return { seed: s, levels };
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

  #objName = new Map<number, string>();
  #objDesc = new Map<number, string>();
  #readObjStr(fn: (id: number, buf: number, cap: number) => number, id: number, buf: number, cap: number): string {
    const len = fn(id, buf, cap);
    if (len <= 0) return '';
    const n = Math.min(len, cap);
    const bytes = new Uint8Array(this.#ex.memory.buffer, buf, n);
    return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  }

  presets(seed: number, levelId: number, difficulty = 0): D2Preset[] {
    const ex = this.#ex;
    let cap = 128;
    let base = scratch(ex.memory, cap * PRESET);
    let n = ex.d2drlg_level_presets(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    if (n < 0) throw new Error('d2drlg: level_presets failed (' + n + ')');
    if (n > cap) {
      cap = n;
      base = scratch(ex.memory, cap * PRESET);
      n = ex.d2drlg_level_presets(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    }
    const STRCAP = 128;
    const strBuf = scratch(ex.memory, STRCAP);
    const dv = new DataView(ex.memory.buffer);
    const out: D2Preset[] = [];
    for (let i = 0; i < n; i++) {
      const b = base + i * PRESET;
      const etype = dv.getInt32(b, true);
      const txtFileNo = dv.getInt32(b + 4, true);
      const x = dv.getInt32(b + 8, true);
      const y = dv.getInt32(b + 12, true);
      if (etype === 2) {
        let name = this.#objName.get(txtFileNo);
        if (name === undefined) { name = this.#readObjStr(ex.d2drlg_object_name, txtFileNo, strBuf, STRCAP); this.#objName.set(txtFileNo, name); }
        let description = this.#objDesc.get(txtFileNo);
        if (description === undefined) { description = this.#readObjStr(ex.d2drlg_object_desc, txtFileNo, strBuf, STRCAP); this.#objDesc.set(txtFileNo, description); }
        out.push({ type: 'obj', txtFileNo, x, y, name, description });
      } else {
        out.push({ type: 'npc', txtFileNo, x, y });
      }
    }
    return out;
  }

  /**
   * A level's ADJACENT-LEVEL BRIDGE TILES in the DeadlyBossMods shape: one entry per
   * warp bridge tile, each `{levelNo, name, displayName, bridgeX, bridgeY}` where the
   * destination level's name/displayName are resolved the same way `render()` names
   * levels, and bridgeX/bridgeY are level-LOCAL subtile coords (this level's frame).
   * `levelId` is a Levels.txt id (Cold Plains = 3); the owning act is derived internally.
   * Returns [] if the level has no resolvable warp bridges.
   */
  adjacents(seed: number, levelId: number, difficulty = 0): D2Adjacent[] {
    const ex = this.#ex;
    let cap = 128;
    let base = scratch(ex.memory, cap * ADJ);
    let n = ex.d2drlg_level_adjacents(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    if (n < 0) throw new Error('d2drlg: level_adjacents failed (' + n + ')');
    if (n > cap) { // truncated: regrow to the full count and refetch
      cap = n;
      base = scratch(ex.memory, cap * ADJ);
      n = ex.d2drlg_level_adjacents(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    }
    // Read every raw (dest, x, y) triple BEFORE resolving names: #levelName grows wasm
    // memory, which detaches the backing buffer (invalidating `base`/any DataView).
    const dv = new DataView(ex.memory.buffer);
    const raw: Array<[number, number, number]> = [];
    for (let i = 0; i < n; i++) {
      const b = base + i * ADJ;
      raw.push([dv.getInt32(b, true), dv.getInt32(b + 4, true), dv.getInt32(b + 8, true)]);
    }
    const out: D2Adjacent[] = [];
    for (const [dest, bx, by] of raw) {
      const displayName = dbmDisplayName(dest, this.#levelName(dest));
      out.push({ levelNo: dest, name: dbmLevelName(dest, displayName), displayName, bridgeX: bx, bridgeY: by });
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
async function render(seed: number, actNo = 0, difficulty = 0): Promise<D2Map> {
  return (await inst()).render(seed, actNo, difficulty);
}
async function shrines(seed: number, levelId: number, difficulty = 0, actNo = 0): Promise<D2Shrine[]> {
  return (await inst()).shrines(seed, levelId, difficulty, actNo);
}
async function presets(seed: number, levelId: number, difficulty = 0): Promise<D2Preset[]> {
  return (await inst()).presets(seed, levelId, difficulty);
}
async function adjacents(seed: number, levelId: number, difficulty = 0): Promise<D2Adjacent[]> {
  return (await inst()).adjacents(seed, levelId, difficulty);
}
async function collision(seed: number, levelId: number, difficulty = 0): Promise<D2Collision> {
  return (await inst()).collision(seed, levelId, difficulty);
}
async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

module.exports = { generateAct, render, shrines, presets, adjacents, collision, abiVersion, open, Drlg };
module.exports.default = generateAct;
