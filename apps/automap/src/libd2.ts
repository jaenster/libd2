// Binding for libd2.wasm — the combined C ABI built from packages/wasm with the generator (d2drlg_*)
// and the router (d2pf_*) in it. The module is a freestanding reactor: it imports nothing, so it
// instantiates with an empty import object and is never started.
//
// One module rather than two because d2pf_world_create takes the pointer d2drlg_ctx_core returns:
// the router reads the generator's tables in the same linear memory, so nothing crosses a module
// boundary. The map is read from the act d2drlg generated and the routes from the router's own load
// of that act — the same seed through the same generator, so the two describe the same cells.

export interface WasmExports {
  memory: WebAssembly.Memory;

  d2drlg_ctx_create(): number;
  d2drlg_ctx_core(ctx: number): number;
  d2drlg_ctx_destroy(ctx: number): void;
  d2drlg_gen_act(ctx: number, seed: number, difficulty: number, actNo: number): number;
  d2drlg_act_free(act: number): void;
  d2drlg_act_level_count(act: number): number;
  d2drlg_act_level_id(act: number, index: number): number;
  d2drlg_act_level_origin(act: number, index: number, ox: number, oy: number): number;
  d2drlg_act_level_size(act: number, index: number, w: number, h: number): number;
  d2drlg_act_level_presets(act: number, index: number, out: number, cap: number): number;
  d2drlg_act_level_adjacents(act: number, index: number, out: number, cap: number): number;
  d2drlg_act_level_collision(act: number, index: number, out: number, cap: number, w: number, h: number): number;
  d2drlg_level_name(ctx: number, levelId: number, buf: number, cap: number): number;

  d2pf_options_default(out: number): void;
  d2pf_world_create(ctxCore: number, seed: number, difficulty: number): number;
  d2pf_world_destroy(world: number): void;
  d2pf_world_load_act(world: number, actNo: number): number;
  d2pf_route(
    world: number, fromLevel: number, fx: number, fy: number,
    toLevel: number, tx: number, ty: number, opts: number,
  ): number;
  d2pf_route_free(route: number): void;
  d2pf_route_leg_count(route: number): number;
  d2pf_route_leg_level(route: number, leg: number): number;
  d2pf_route_leg_exit(route: number, leg: number): number;
  d2pf_route_leg_moves(route: number, leg: number, out: number, cap: number): number;
  d2pf_level_route(world: number, from: number, to: number, out: number, cap: number): number;
}

/** Subtiles per DS1 tile — level origins and sizes are reported in tiles, everything else in subtiles. */
export const SUBTILES_PER_TILE = 5;

/** Walk-grid cell states. */
export const VOID = 0, OPEN = 1, BLOCKED = 2;

/**
 * What kind of way out an exit is. The ABI reports only a destination and a bridge cell; the kind is
 * read off the geometry. Levels that share an edge are crossed by walking over it (a seam), levels
 * that do not are reached through a placed warp, and an adjacency with no cell at all is one the
 * server opens at runtime (a quest portal).
 */
export const WARP = 0, SEAM = 1, PORTAL = 2;
export const EXIT_KIND_NAME = ["warp", "seam", "portal"];

/** `D2PfMove.kind`. */
export const MOVE_WALK = 0, MOVE_TELEPORT = 1, MOVE_PAD = 2;

/** The engine's movement models, `d2-core`'s `Colmask`. */
export const Masks = {
  playerPath: 0x1c09,
  monsterPath: 0x3c01,
  /** `COLBIT_MISSILE_BARRIER | COLBIT_WALL`. */
  missileFlight: 0x1001,
} as const;

/** "No floor tile here": the engine's marker for outside the level. Not a movement blocker. */
const COLBIT_BLANK = 0x20;

/** sizeof each extern struct the ABI writes into caller memory. */
const ADJACENT = 12; // D2DrlgAdjacent: 3 x i32
const MOVE = 12; // D2PfMove: 3 x i32
const OPTIONS = 24; // D2PfOptions: u16 + 5 x i32, padded

export interface LevelInfo {
  id: number;
  name: string;
  act: number;
  /** World TILE origin — multiply by 5 to place the level in the act's shared subtile frame. */
  originX: number;
  originY: number;
  /** Grid dimensions in SUBTILES. */
  w: number;
  h: number;
  /** Adjacency bridge cells the generator reported (one per warp slot / seam room). */
  exitCount: number;
  presetCount: number;
}

export interface Exit { toLevel: number; x: number; y: number; kind: number; }
export interface Move { leg: number; level: number; x: number; y: number; kind: number; }
export interface Leg { level: number; moveCount: number; exitToLevel: number; }
export interface RouteResult { legs: Leg[]; moves: Move[]; }

export interface RouteOptions {
  mask?: number;
  teleport?: boolean;
  teleportAcrossLevels?: boolean;
}

let compiled: Promise<WebAssembly.Module> | null = null;

function getCompiled(): Promise<WebAssembly.Module> {
  if (!compiled) {
    compiled = (async () => {
      const resp = await fetch(new URL(`${import.meta.env.BASE_URL}libd2.wasm`, location.href));
      if (!resp.ok) {
        throw new Error(`libd2.wasm not found (${resp.status}). Build it with \`pnpm wasm\`.`);
      }
      return WebAssembly.compileStreaming(resp);
    })();
  }
  return compiled;
}

const decoder = new TextDecoder();

interface ActLevel { act: number; handle: number; index: number; }

/**
 * A generated world plus the routing index over it.
 *
 * Each instance owns a FRESH wasm instance (its own linear memory), so changing the seed throws the
 * old world away wholesale. Wasm memory only ever grows, and a whole act is tens of megabytes of it,
 * so reusing one instance across seeds would keep every act ever viewed resident.
 */
export class World {
  private ex: WasmExports;
  private ctx: number;
  private world: number;
  /** Scratch in wasm memory, grown on demand. Every `out` pointer in the ABI points here. */
  private scratch = 0;
  private scratchLen = 0;
  private acts = new Map<number, number>();
  private levels = new Map<number, ActLevel>();
  private infoCache = new Map<number, LevelInfo>();
  private exitCache = new Map<number, Exit[]>();

  readonly seed: number;
  readonly difficulty: number;

  private constructor(ex: WasmExports, ctx: number, world: number, seed: number, difficulty: number) {
    this.ex = ex;
    this.ctx = ctx;
    this.world = world;
    this.seed = seed;
    this.difficulty = difficulty;
  }

  static async create(seed: number, difficulty: number): Promise<World> {
    const module = await getCompiled();
    const instance = await WebAssembly.instantiate(module, {});
    const ex = instance.exports as unknown as WasmExports;
    const ctx = ex.d2drlg_ctx_create();
    if (!ctx) throw new Error("d2drlg_ctx_create failed — game tables did not load");
    const world = ex.d2pf_world_create(ex.d2drlg_ctx_core(ctx), seed >>> 0, difficulty);
    if (!world) {
      ex.d2drlg_ctx_destroy(ctx);
      throw new Error("d2pf_world_create failed");
    }
    return new World(ex, ctx, world, seed >>> 0, difficulty);
  }

  destroy() {
    if (!this.ctx) return;
    this.ex.d2pf_world_destroy(this.world);
    for (const handle of this.acts.values()) this.ex.d2drlg_act_free(handle);
    this.ex.d2drlg_ctx_destroy(this.ctx);
    this.acts.clear();
    this.world = 0;
    this.ctx = 0;
  }

  /**
   * Scratch big enough for `bytes`. It is taken by growing linear memory and keeping the new pages:
   * the module's allocator only ever hands out memory below what it has grown itself, so a region
   * grown here is never handed out again. Views onto it must be rebuilt after any call that can
   * grow memory, since growth detaches the old ArrayBuffer.
   */
  private scr(bytes: number): number {
    if (bytes > this.scratchLen) {
      const PAGE = 65536;
      const pages = Math.ceil(bytes / PAGE) + 1;
      this.scratch = this.ex.memory.grow(pages) * PAGE;
      this.scratchLen = pages * PAGE;
    }
    return this.scratch;
  }

  private i32(ptr: number, count: number): Int32Array {
    return new Int32Array(this.ex.memory.buffer.slice(ptr, ptr + count * 4));
  }

  /** Generate one act (0-based) for both the map and the router, and keep it resident. Idempotent. */
  loadAct(actNo: number) {
    if (this.acts.has(actNo)) return;
    const handle = this.ex.d2drlg_gen_act(this.ctx, this.seed, this.difficulty, actNo);
    if (!handle) throw new Error(`d2drlg_gen_act(${actNo}) failed`);
    const rc = this.ex.d2pf_world_load_act(this.world, actNo);
    if (rc !== 0) {
      this.ex.d2drlg_act_free(handle);
      throw new Error(`d2pf_world_load_act(${actNo}) failed: ${rc}`);
    }
    this.acts.set(actNo, handle);
    const n = this.ex.d2drlg_act_level_count(handle);
    for (let index = 0; index < n; index++) {
      const id = this.ex.d2drlg_act_level_id(handle, index);
      if (id > 0 && !this.levels.has(id)) this.levels.set(id, { act: actNo, handle, index });
    }
  }

  levelIds(): number[] {
    return [...this.levels.keys()];
  }

  levelName(id: number): string {
    const p = this.scr(64);
    const len = this.ex.d2drlg_level_name(this.ctx, id, p, 64);
    if (len <= 0) return `Level ${id}`;
    const raw = new Uint8Array(this.ex.memory.buffer, p, Math.min(len, 64));
    const end = raw.indexOf(0);
    return decoder.decode(end < 0 ? raw : raw.subarray(0, end));
  }

  private pair(fn: (a: number, b: number) => number): [number, number] | null {
    const p = this.scr(8);
    if (fn(p, p + 4) < 0) return null;
    const v = this.i32(p, 2);
    return [v[0], v[1]];
  }

  levelInfo(id: number): LevelInfo | null {
    const hit = this.infoCache.get(id);
    if (hit) return hit;
    const lv = this.levels.get(id);
    if (!lv) return null;
    const origin = this.pair((a, b) => this.ex.d2drlg_act_level_origin(lv.handle, lv.index, a, b));
    // The collision grid's dims, probed with a zero capacity: the ABI always writes them.
    const dims = this.pair((a, b) => this.ex.d2drlg_act_level_collision(lv.handle, lv.index, 0, 0, a, b));
    if (!origin || !dims) return null;
    const info: LevelInfo = {
      id, name: this.levelName(id), act: lv.act,
      originX: origin[0], originY: origin[1], w: dims[0], h: dims[1],
      exitCount: Math.max(0, this.ex.d2drlg_act_level_adjacents(lv.handle, lv.index, 0, 0)),
      presetCount: Math.max(0, this.ex.d2drlg_act_level_presets(lv.handle, lv.index, 0, 0)),
    };
    this.infoCache.set(id, info);
    return info;
  }

  /**
   * The level's grid reduced to one byte per subtile under `mask`: 0 void, 1 passable, 2 blocked.
   * Classified from the raw u16 CollMap with the same `cell & mask` test the router applies, which
   * is why switching the movement model redraws the walls: passability IS the map.
   */
  walkGrid(id: number, mask: number): { w: number; h: number; cells: Uint8Array } | null {
    const info = this.levelInfo(id);
    const lv = this.levels.get(id);
    if (!info || !lv || info.w <= 0 || info.h <= 0) return null;
    const total = info.w * info.h;
    const p = this.scr(total * 2 + 8);
    const got = this.ex.d2drlg_act_level_collision(lv.handle, lv.index, p, total, p + total * 2, p + total * 2 + 4);
    if (got <= 0) return null;
    const raw = new Uint16Array(this.ex.memory.buffer, p, total);
    const cells = new Uint8Array(total);
    for (let i = 0; i < total; i++) {
      const c = raw[i];
      cells[i] = (c & COLBIT_BLANK) !== 0 ? VOID : (c & mask) === 0 ? OPEN : BLOCKED;
    }
    return { w: info.w, h: info.h, cells };
  }

  /** Whether two levels share an edge in the act's world frame — the difference between a seam and a warp. */
  private abuts(a: LevelInfo, b: LevelInfo): boolean {
    if (a.act !== b.act) return false;
    const ax0 = a.originX * SUBTILES_PER_TILE, ay0 = a.originY * SUBTILES_PER_TILE;
    const bx0 = b.originX * SUBTILES_PER_TILE, by0 = b.originY * SUBTILES_PER_TILE;
    const ax1 = ax0 + a.w, ay1 = ay0 + a.h, bx1 = bx0 + b.w, by1 = by0 + b.h;
    const overlapY = Math.min(ay1, by1) > Math.max(ay0, by0);
    const overlapX = Math.min(ax1, bx1) > Math.max(ax0, bx0);
    return (overlapY && (ax1 === bx0 || ax0 === bx1)) || (overlapX && (ay1 === by0 || ay0 === by1));
  }

  /** Every bridge cell out of a level, in level-local subtiles. Runtime portals carry x/y -1. */
  exitsOf(id: number): Exit[] {
    const hit = this.exitCache.get(id);
    if (hit) return hit;
    const lv = this.levels.get(id);
    const from = this.levelInfo(id);
    if (!lv || !from) return [];
    const total = this.ex.d2drlg_act_level_adjacents(lv.handle, lv.index, 0, 0);
    const out: Exit[] = [];
    if (total > 0) {
      const p = this.scr(total * ADJACENT);
      const n = Math.min(this.ex.d2drlg_act_level_adjacents(lv.handle, lv.index, p, total), total);
      const v = this.i32(p, n * 3);
      for (let i = 0; i < n; i++) {
        const toLevel = v[i * 3], x = v[i * 3 + 1], y = v[i * 3 + 2];
        const to = this.levelInfo(toLevel);
        const kind = x < 0 || y < 0 ? PORTAL : to && this.abuts(from, to) ? SEAM : WARP;
        out.push({ toLevel, x, y, kind });
      }
    }
    this.exitCache.set(id, out);
    return out;
  }

  /**
   * One exit per destination level. A seam arrives as one bridge cell per border room, so the one
   * kept is the cell nearest the middle of them — a point on the crossing rather than its end.
   */
  uniqueExits(id: number): Exit[] {
    const byDest = new Map<number, Exit[]>();
    for (const e of this.exitsOf(id)) {
      const arr = byDest.get(e.toLevel) ?? [];
      arr.push(e);
      byDest.set(e.toLevel, arr);
    }
    const out: Exit[] = [];
    for (const group of byDest.values()) {
      const placed = group.filter((e) => e.x >= 0 && e.y >= 0);
      if (!placed.length) { out.push(group[0]); continue; }
      const cx = placed.reduce((s, e) => s + e.x, 0) / placed.length;
      const cy = placed.reduce((s, e) => s + e.y, 0) / placed.length;
      let best = placed[0], bestD = Infinity;
      for (const e of placed) {
        const d = Math.hypot(e.x - cx, e.y - cy);
        if (d < bestD) { bestD = d; best = e; }
      }
      out.push(best);
    }
    return out;
  }

  /** The chain of level ids from `from` to `to`, or null if they are not connected. */
  levelRoute(from: number, to: number): number[] | null {
    const cap = 256;
    const p = this.scr(cap * 4);
    const n = this.ex.d2pf_level_route(this.world, from, to, p, cap);
    if (n <= 0) return null;
    return Array.from(this.i32(p, Math.min(n, cap)));
  }

  private writeOptions(ptr: number, opts: RouteOptions) {
    this.ex.d2pf_options_default(ptr);
    const dv = new DataView(this.ex.memory.buffer, ptr, OPTIONS);
    if (opts.mask !== undefined) dv.setUint16(0, opts.mask, true);
    if (opts.teleport !== undefined) dv.setInt32(4, opts.teleport ? 1 : 0, true);
    if (opts.teleportAcrossLevels !== undefined) dv.setInt32(8, opts.teleportAcrossLevels ? 1 : 0, true);
  }

  /** Route between two LEVEL-LOCAL positions, across as many levels as it takes. */
  route(
    from: { level: number; x: number; y: number },
    to: { level: number; x: number; y: number },
    opts: RouteOptions = {},
  ): RouteResult | null {
    const optPtr = this.scr(OPTIONS);
    this.writeOptions(optPtr, opts);
    const r = this.ex.d2pf_route(this.world, from.level, from.x, from.y, to.level, to.x, to.y, optPtr);
    if (!r) return null;
    try {
      const legs: Leg[] = [];
      const moves: Move[] = [];
      const nLegs = this.ex.d2pf_route_leg_count(r);
      for (let i = 0; i < nLegs; i++) {
        const level = this.ex.d2pf_route_leg_level(r, i);
        const exitToLevel = this.ex.d2pf_route_leg_exit(r, i);
        // Probe with a zero capacity: the ABI returns the true count either way.
        const total = this.ex.d2pf_route_leg_moves(r, i, 0, 0);
        let count = 0;
        if (total > 0) {
          const p = this.scr(total * MOVE);
          count = Math.min(this.ex.d2pf_route_leg_moves(r, i, p, total), total);
          const v = this.i32(p, count * 3);
          for (let m = 0; m < count; m++) {
            moves.push({ leg: i, level, x: v[m * 3], y: v[m * 3 + 1], kind: v[m * 3 + 2] });
          }
        }
        legs.push({ level, moveCount: count, exitToLevel });
      }
      return { legs, moves };
    } finally {
      this.ex.d2pf_route_free(r);
    }
  }

  maskPlayer(): number { return Masks.playerPath; }
  maskMonster(): number { return Masks.monsterPath; }
  maskMissile(): number { return Masks.missileFlight; }
}

/** Stable, well-spread colour per level id — the same one across every view. */
export function levelColor(id: number, sat = 65, light = 55): string {
  return `hsl(${(id * 47) % 360} ${sat}% ${light}%)`;
}
