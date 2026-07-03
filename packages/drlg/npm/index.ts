// Tiny typed shim over the d2drlg wasm C-ABI. Pure TypeScript — runs natively on
// Node (>=23.6 / --experimental-strip-types), Bun, Deno, and any TS bundler.
// Construction "just happens on usage": the top-level functions lazily load and
// instantiate the wasm on first call and cache a singleton. No open()/close()
// needed — but they are exported for those who want lifecycle control.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// Base64-encode raw bytes with ZERO host dependency. The collision grid is now
// deflated INSIDE the wasm (std.compress.flate, zlib container), so the shim only
// needs to base64 the compressed bytes — no node:zlib, works in Node/browser/Bun/Deno.
// Prefer Node's Buffer when present (fastest); otherwise chunk through btoa (browser).
function bytesToBase64(bytes: Uint8Array): string {
  const B = (globalThis as { Buffer?: { from(b: Uint8Array): { toString(enc: string): string } } }).Buffer;
  if (B) return B.from(bytes).toString('base64');
  let bin = '';
  const CHUNK = 0x8000; // avoid arg-count limits on String.fromCharCode
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK) as unknown as number[]);
  }
  return btoa(bin);
}

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
  /** adjacent-level bridge tiles (DBM shape): one entry per warp bridge tile */
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
   * Inflate with `zlib.inflateSync` to recover the grid. Byte-for-byte the deflate
   * output differs from other zlib implementations, but the INFLATED grid matches
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
  // Generate-once accessors: pull a level's presets/adjacents/collision straight from an
  // already-generated act handle (no regeneration). Keyed by 0-based act level index.
  d2drlg_act_level_presets(act: number, i: number, out: number, cap: number): number;
  d2drlg_act_level_adjacents(act: number, i: number, out: number, cap: number): number;
  d2drlg_act_level_collision(act: number, i: number, out: number, cap: number, outW: number, outH: number): number;
  d2drlg_act_level_collision_zlib(act: number, i: number, out: number, cap: number, outW: number, outH: number): number;
  d2drlg_deflate_zlib(inPtr: number, inLen: number, out: number, cap: number): number;
  d2drlg_level_name(ctx: number, levelId: number, buf: number, cap: number): number;
  d2drlg_level_shrines(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number): number;
  d2drlg_level_presets(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number): number;
  d2drlg_level_adjacents(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number): number;
  d2drlg_level_collision_raw(ctx: number, seed: number, diff: number, levelId: number, out: number, cap: number, outW: number, outH: number): number;
  d2drlg_object_name(txtFileNo: number, buf: number, cap: number): number;
  d2drlg_object_desc(txtFileNo: number, buf: number, cap: number): number;
  d2drlg_abi_version(): number;
}

// DBM's `name` field is the canonical level enum name: the display name with each
// word TitleCased and joined (spaces removed). A few ids diverge from that rule and
// keep their classic short enum name; those are overridden explicitly.
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

// DBM's displayName for a few ids diverges from Levels.txt LevelName (which holds an
// internal/dev string). Override to the canonical in-game name DBM reports.
const DBM_DISPLAY_OVERRIDE: Record<number, string> = { 39: 'The Secret Cow Level' };
function dbmDisplayName(levelNo: number, raw: string): string {
  return DBM_DISPLAY_OVERRIDE[levelNo] ?? raw;
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

  // A SINGLE reusable scratch region in wasm linear memory. Unlike a per-call grow (which
  // never reclaims and makes memory climb forever), this grows only when a request needs
  // MORE than the current region, then hands back the same base for every smaller request.
  // Callers must copy their bytes out before the next #scratch call (the region is reused).
  // grow() detaches the ArrayBuffer, so re-read `memory.buffer` after any call that grows.
  #sbase = 0;
  #scap = 0;
  #scratch(bytes: number): number {
    const need = bytes || 1;
    if (need > this.#scap) {
      const pages = Math.ceil(need / PAGE);
      const prev = this.#ex.memory.grow(pages);
      this.#sbase = prev * PAGE;
      this.#scap = pages * PAGE;
    }
    return this.#sbase;
  }

  /** Generate an entire act (low-level view, world TILE coords). difficulty 0/1/2, actNo 0..4. */
  generateAct(seed: number, difficulty = 0, actNo = 0): D2Act {
    const ex = this.#ex;
    const act = ex.d2drlg_gen_act(this.#ctx, seed >>> 0, difficulty, actNo);
    if (!act) throw new Error('d2drlg: gen_act failed');
    try {
      const levels: D2ActLevel[] = [];
      const n = ex.d2drlg_act_level_count(act);
      for (let i = 0; i < n; i++) {
        const roomCount = ex.d2drlg_act_level_room_count(act, i);
        // One scratch region per level: rooms, then 4 int32 out-params (ox,oy,w,h).
        const OUT = 16;
        const base = this.#scratch(roomCount * ROOM + OUT);
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

  // Levels.txt LevelName cache, keyed by level id. Uses a fresh scratch region per
  // call (memory.grow may have happened since); safe to call between other reads.
  #levelName(levelId: number): string {
    const ex = this.#ex;
    const CAP = 128;
    const buf = this.#scratch(CAP);
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
    // Probe: cap 0 writes nothing but fills out_w/out_h; the `out` pointer is unused.
    const probe = this.#scratch(8);
    const total = ex.d2drlg_level_collision_raw(this.#ctx, seed >>> 0, difficulty, levelId, probe, 0, probe, probe + 4);
    if (total < 0) throw new Error('d2drlg: level_collision_raw failed (' + total + ')');
    let dv = new DataView(ex.memory.buffer);
    const width = dv.getInt32(probe, true);
    const height = dv.getInt32(probe + 4, true);
    if (total === 0 || width <= 0 || height <= 0) return { width: 0, height: 0, cells: new Uint16Array(0) };
    const cells = width * height; // == total
    const base = this.#scratch(cells * 2 + 8);
    const outp = base + cells * 2;
    ex.d2drlg_level_collision_raw(this.#ctx, seed >>> 0, difficulty, levelId, base, cells, outp, outp + 4);
    // Copy out of wasm linear memory before any later grow detaches the buffer.
    const u16 = new Uint16Array(ex.memory.buffer, base, cells).slice();
    return { width, height, cells: u16 };
  }

  /**
   * A level's RAW subtile collision grid (level-local, row-major). Each cell is the
   * engine Colbit flag set; uncovered/OOB cells are 0xFFFF. `levelId` is a Levels.txt
   * id (Cold Plains = 3); the owning act is derived internally.
   */
  collision(seed: number, levelId: number, difficulty = 0): D2Collision {
    return this.#collisionRaw(seed, levelId, difficulty);
  }

  /**
   * Assemble a whole act in the DeadlyBossMods map shape: per-level metadata
   * (levelNo/name/displayName/act/origin/size), rooms in level-local SUBTILE coords,
   * preset units, adjacent-level bridge tiles, and the collision grid. `tells` is
   * left empty (a later phase fills it). difficulty 0/1/2, actNo 0..4.
   *
   * GENERATE ONCE: the act is generated a SINGLE time (`d2drlg_gen_act`) and every
   * per-level field is pulled from that one handle via the act-index accessors. This
   * replaces the old path that re-generated the whole act separately for each level's
   * rooms/collision/presets/adjacents (≈4 full act gens × 39 levels per render).
   */
  render(seed: number, actNo = 0, difficulty = 0): D2Map {
    const ex = this.#ex;
    const s = seed >>> 0;
    const act = ex.d2drlg_gen_act(this.#ctx, s, difficulty, actNo);
    if (!act) throw new Error('d2drlg: gen_act failed');
    try {
      const n = ex.d2drlg_act_level_count(act);
      const levels: D2Level[] = [];
      for (let i = 0; i < n; i++) {
        const levelNo = ex.d2drlg_act_level_id(act, i);
        // Rooms + world origin/size (TILES) — copied into JS before any later #scratch
        // reuse detaches or overwrites the region.
        const roomCount = ex.d2drlg_act_level_room_count(act, i);
        const OUT = 16;
        const rbase = this.#scratch(roomCount * ROOM + OUT);
        const outp = rbase + roomCount * ROOM;
        ex.d2drlg_act_rooms(act, i, rbase, roomCount);
        ex.d2drlg_act_level_origin(act, i, outp, outp + 4);
        ex.d2drlg_act_level_size(act, i, outp + 8, outp + 12);
        const dv = new DataView(ex.memory.buffer);
        const ox = dv.getInt32(outp, true), oy = dv.getInt32(outp + 4, true); // tiles
        const sw = dv.getInt32(outp + 8, true), sh = dv.getInt32(outp + 12, true); // tiles
        const rooms: D2Room[] = [];
        for (let r = 0; r < roomCount; r++) {
          const b = rbase + r * ROOM;
          const rx = dv.getInt32(b, true), ry = dv.getInt32(b + 4, true);
          const rw = dv.getInt32(b + 8, true), rh = dv.getInt32(b + 12, true);
          const pickedFile = dv.getInt32(b + 24, true);
          rooms.push({ x: (rx - ox) * 5, y: (ry - oy) * 5, sizeX: rw * 5, sizeY: rh * 5, roomNo: pickedFile, subNo: pickedFile });
        }
        const displayName = dbmDisplayName(levelNo, this.#levelName(levelNo));
        // Collision is deflated INSIDE the wasm (zlib container) and only base64'd here —
        // no host zlib. The act-level export both yields dims and the deflated bytes in one
        // call; a level with no grid falls back to an in-wasm-deflated OOB-fill grid.
        const czl = this.#actCollisionZlib(act, i, sw * 5, sh * 5);
        const cw = czl.width;
        const ch = czl.height;
        const collisionDeflateB64 = czl.b64;
        levels.push({
          levelNo,
          name: dbmLevelName(levelNo, displayName),
          displayName,
          act: actNo + 1,
          origin: [ox * 5, oy * 5],
          size: [sw * 5, sh * 5],
          rooms,
          presets: this.#actPresets(act, i),
          adjacents: this.#actAdjacents(act, i),
          tells: [],
          collisionWidth: cw,
          collisionHeight: ch,
          collisionDeflateB64,
        });
      }
      return { seed: s, levels };
    } finally {
      ex.d2drlg_act_free(act);
    }
  }

  /**
   * The seeded OUTDOOR SHRINES/WELLS of one level. `levelId` is a Levels.txt id
   * (Cold Plains = 3); the owning act is derived internally, so `actNo` is accepted
   * only for API symmetry and is ignored. Returns [] if the level has none.
   */
  shrines(seed: number, levelId: number, difficulty = 0, actNo = 0): D2Shrine[] {
    void actNo;
    const ex = this.#ex;
    let cap = 64;
    let base = this.#scratch(cap * SHRINE);
    let n = ex.d2drlg_level_shrines(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    if (n < 0) throw new Error('d2drlg: level_shrines failed (' + n + ')');
    if (n > cap) { // truncated: regrow to the full count and refetch
      cap = n;
      base = this.#scratch(cap * SHRINE);
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

  // Objects.txt Name/description cache, keyed by txtFileNo. `buf` is a persistent
  // scratch region in wasm memory reused across lookups.
  #objName = new Map<number, string>();
  #objDesc = new Map<number, string>();
  #readObjStr(fn: (id: number, buf: number, cap: number) => number, id: number, buf: number, cap: number): string {
    const len = fn(id, buf, cap);
    if (len <= 0) return '';
    const n = Math.min(len, cap);
    // Re-read the buffer each call: no memory.grow happens during string reads.
    const bytes = new Uint8Array(this.#ex.memory.buffer, buf, n);
    return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  }

  /**
   * A level's PRESET UNITS in the DeadlyBossMods shape: objects (type 'obj') and
   * monster/preset markers (type 'npc'), at level-LOCAL subtile coords (the DBM
   * frame — the coordinate transform is done in the Zig lib). obj entries carry
   * Objects.txt name+description. `levelId` is a Levels.txt id (Cold Plains = 3);
   * the owning act is derived internally. Returns [] if the level has none.
   */
  presets(seed: number, levelId: number, difficulty = 0): D2Preset[] {
    const ex = this.#ex;
    let cap = 128;
    let base = this.#scratch(cap * PRESET);
    let n = ex.d2drlg_level_presets(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    if (n < 0) throw new Error('d2drlg: level_presets failed (' + n + ')');
    if (n > cap) { // truncated: regrow to the full count and refetch
      cap = n;
      base = this.#scratch(cap * PRESET);
      n = ex.d2drlg_level_presets(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    }
    return this.#buildPresets(base, n);
  }

  // A level's presets read from an already-generated act handle (no regeneration).
  #actPresets(act: number, i: number): D2Preset[] {
    const ex = this.#ex;
    let cap = 128;
    let base = this.#scratch(cap * PRESET);
    let n = ex.d2drlg_act_level_presets(act, i, base, cap);
    if (n < 0) throw new Error('d2drlg: act_level_presets failed (' + n + ')');
    if (n > cap) { cap = n; base = this.#scratch(cap * PRESET); n = ex.d2drlg_act_level_presets(act, i, base, cap); }
    return this.#buildPresets(base, n);
  }

  // Decode `n` D2DrlgPreset records at `base` into the DBM shape. Two-phase: copy every
  // (etype,txt,x,y) tuple out of the shared scratch region FIRST, then resolve obj
  // name/description strings (those reuse the scratch region, so they must run after the
  // array is fully read out).
  #buildPresets(base: number, n: number): D2Preset[] {
    const ex = this.#ex;
    const dv = new DataView(ex.memory.buffer);
    const tuples: Array<[number, number, number, number]> = [];
    for (let i = 0; i < n; i++) {
      const b = base + i * PRESET;
      tuples.push([dv.getInt32(b, true), dv.getInt32(b + 4, true), dv.getInt32(b + 8, true), dv.getInt32(b + 12, true)]);
    }
    const STRCAP = 128;
    const out: D2Preset[] = [];
    for (const [etype, txtFileNo, x, y] of tuples) {
      if (etype === 2) {
        let name = this.#objName.get(txtFileNo);
        if (name === undefined) { name = this.#readObjStr(ex.d2drlg_object_name, txtFileNo, this.#scratch(STRCAP), STRCAP); this.#objName.set(txtFileNo, name); }
        let description = this.#objDesc.get(txtFileNo);
        if (description === undefined) { description = this.#readObjStr(ex.d2drlg_object_desc, txtFileNo, this.#scratch(STRCAP), STRCAP); this.#objDesc.set(txtFileNo, description); }
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
    let base = this.#scratch(cap * ADJ);
    let n = ex.d2drlg_level_adjacents(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    if (n < 0) throw new Error('d2drlg: level_adjacents failed (' + n + ')');
    if (n > cap) { // truncated: regrow to the full count and refetch
      cap = n;
      base = this.#scratch(cap * ADJ);
      n = ex.d2drlg_level_adjacents(this.#ctx, seed >>> 0, difficulty, levelId, base, cap);
    }
    return this.#buildAdjacents(base, n);
  }

  // A level's adjacents read from an already-generated act handle (no regeneration).
  #actAdjacents(act: number, i: number): D2Adjacent[] {
    const ex = this.#ex;
    let cap = 128;
    let base = this.#scratch(cap * ADJ);
    let n = ex.d2drlg_act_level_adjacents(act, i, base, cap);
    if (n < 0) throw new Error('d2drlg: act_level_adjacents failed (' + n + ')');
    if (n > cap) { cap = n; base = this.#scratch(cap * ADJ); n = ex.d2drlg_act_level_adjacents(act, i, base, cap); }
    return this.#buildAdjacents(base, n);
  }

  // Decode `n` D2DrlgAdjacent records at `base`. Read every raw (dest,x,y) triple BEFORE
  // resolving names: #levelName reuses the scratch region (and may grow/detach it).
  #buildAdjacents(base: number, n: number): D2Adjacent[] {
    const ex = this.#ex;
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

  // A level's collision grid, DEFLATED (zlib) inside the wasm and base64'd here — no host
  // zlib. Probe (cap 0) returns the deflated length + fills out_w/out_h; then fetch the
  // compressed bytes and base64 them. If the level has no grid, deflate a full OOB-fill
  // (0xFFFF) grid of fw×fh in-wasm so the emitted shape stays consistent.
  #actCollisionZlib(act: number, i: number, fw: number, fh: number): { width: number; height: number; b64: string } {
    const ex = this.#ex;
    const probe = this.#scratch(8);
    const len = ex.d2drlg_act_level_collision_zlib(act, i, probe, 0, probe, probe + 4);
    if (len < 0) throw new Error('d2drlg: act_level_collision_zlib failed (' + len + ')');
    const dv = new DataView(ex.memory.buffer);
    const w = dv.getInt32(probe, true);
    const h = dv.getInt32(probe + 4, true);
    if (len > 0 && w > 0 && h > 0) {
      const base = this.#scratch(len + 8);
      const outp = base + len;
      ex.d2drlg_act_level_collision_zlib(act, i, base, len, outp, outp + 4);
      const b64 = bytesToBase64(new Uint8Array(ex.memory.buffer, base, len));
      return { width: w, height: h, b64 };
    }
    const oob = new Uint8Array(fw * fh * 2).fill(0xff); // 0xFFFF LE per cell
    return { width: fw, height: fh, b64: this.#deflateBytes(oob) };
  }

  // Deflate arbitrary JS bytes (zlib container) via the wasm and return the base64 of the
  // compressed bytes — no host zlib. Copies the input into wasm scratch, probes the deflated
  // length (cap 0), then compresses into a disjoint output region.
  #deflateBytes(src: Uint8Array): string {
    const ex = this.#ex;
    const inLen = src.byteLength;
    let base = this.#scratch(inLen + 8);
    new Uint8Array(ex.memory.buffer, base, inLen).set(src);
    const dlen = ex.d2drlg_deflate_zlib(base, inLen, base, 0);
    if (dlen < 0) throw new Error('d2drlg: deflate_zlib failed (' + dlen + ')');
    base = this.#scratch(inLen + dlen + 8);
    new Uint8Array(ex.memory.buffer, base, inLen).set(src); // grow may have detached; re-copy
    const outBase = base + inLen;
    ex.d2drlg_deflate_zlib(base, inLen, outBase, dlen);
    return bytesToBase64(new Uint8Array(ex.memory.buffer, outBase, dlen));
  }

  /**
   * A level's RAW collision grid, zlib-DEFLATED inside the wasm and base64-encoded — the
   * same `collisionDeflateB64` payload `render()` emits, but for a single level. `levelId`
   * is a Levels.txt id (Cold Plains = 3); the owning act is derived internally. Inflate the
   * decoded bytes with any standard zlib to recover the row-major LE u16 grid.
   */
  collisionZlib(seed: number, levelId: number, difficulty = 0): { width: number; height: number; deflateB64: string } {
    const { width, height, cells } = this.#collisionRaw(seed, levelId, difficulty);
    const src = new Uint8Array(cells.buffer, cells.byteOffset, cells.byteLength);
    return { width, height, deflateB64: this.#deflateBytes(src) };
  }

  /** ABI version of the loaded module. */
  abiVersion(): number { return this.#ex.d2drlg_abi_version(); }

  /** Free the context. */
  close(): void { this.#ex.d2drlg_ctx_destroy(this.#ctx); }
}

// Lazy singleton: construction just happens on first use.
let _p: Promise<Drlg> | undefined;
const inst = (): Promise<Drlg> => (_p ??= open());

/** Generate an entire act (low-level view). Lazily loads the wasm on first call. */
export async function generateAct(seed: number, difficulty = 0, actNo = 0): Promise<D2Act> {
  return (await inst()).generateAct(seed, difficulty, actNo);
}

/** Assemble a whole act in the DeadlyBossMods map shape. Lazily loads the wasm on first call. */
export async function render(seed: number, actNo = 0, difficulty = 0): Promise<D2Map> {
  return (await inst()).render(seed, actNo, difficulty);
}

/** A level's seeded outdoor shrines/wells. Lazily loads the wasm on first call. */
export async function shrines(seed: number, levelId: number, difficulty = 0, actNo = 0): Promise<D2Shrine[]> {
  return (await inst()).shrines(seed, levelId, difficulty, actNo);
}

/** A level's preset units (DBM shape). Lazily loads the wasm on first call. */
export async function presets(seed: number, levelId: number, difficulty = 0): Promise<D2Preset[]> {
  return (await inst()).presets(seed, levelId, difficulty);
}

/** A level's adjacent-level bridge tiles (DBM shape). Lazily loads the wasm on first call. */
export async function adjacents(seed: number, levelId: number, difficulty = 0): Promise<D2Adjacent[]> {
  return (await inst()).adjacents(seed, levelId, difficulty);
}

/** A level's raw subtile collision grid. Lazily loads the wasm on first call. */
export async function collision(seed: number, levelId: number, difficulty = 0): Promise<D2Collision> {
  return (await inst()).collision(seed, levelId, difficulty);
}

/** A level's collision grid, zlib-deflated in-wasm + base64'd (no host zlib). Lazy. */
export async function collisionZlib(seed: number, levelId: number, difficulty = 0): Promise<{ width: number; height: number; deflateB64: string }> {
  return (await inst()).collisionZlib(seed, levelId, difficulty);
}

/** ABI version of the module. Lazily loads the wasm on first call. */
export async function abiVersion(): Promise<number> {
  return (await inst()).abiVersion();
}

export default generateAct;
