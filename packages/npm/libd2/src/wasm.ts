// The combined libd2 module, and the raw C ABI over it.
//
// Nothing above this file knows there is a wasm. Nothing in it knows what a Game is.
//
// One module, not one per subsystem, and that is load-bearing: `d2pf_world_create` takes the
// pointer `d2drlg_ctx_core` returns, so the router reads the generator's collision grids in place.
// Two modules would be two linear memories and every route would copy a level's whole grid across
// the boundary.

/** 0 walk, 1 teleport, 2 pad — `D2PfMove.kind`. */
export const MOVE_KINDS = ['walk', 'teleport', 'pad'] as const;
export type MoveKind = (typeof MOVE_KINDS)[number];

/** sizeof each extern struct the ABI writes into caller memory. */
const ROOM = 28; // D2DrlgRoom: 7 x i32
const PRESET = 16; // D2DrlgPreset: 4 x i32
const ADJACENT = 12; // D2DrlgAdjacent: 3 x i32
const MOVE = 12; // D2PfMove: 3 x i32
const OPTIONS = 24; // D2PfOptions: u16 + 5 x i32, padded

export interface Exports {
  memory: WebAssembly.Memory;

  d2drlg_ctx_create(): number;
  d2drlg_ctx_core(ctx: number): number;
  d2drlg_ctx_destroy(ctx: number): void;
  d2drlg_gen_act(ctx: number, seed: number, difficulty: number, actNo: number): number;
  d2drlg_act_free(act: number): void;
  d2drlg_act_level_count(act: number): number;
  d2drlg_act_level_id(act: number, index: number): number;
  d2drlg_act_level_room_count(act: number, index: number): number;
  d2drlg_act_rooms(act: number, index: number, out: number, cap: number): number;
  d2drlg_act_level_origin(act: number, index: number, ox: number, oy: number): number;
  d2drlg_act_level_size(act: number, index: number, w: number, h: number): number;
  d2drlg_act_level_presets(act: number, index: number, out: number, cap: number): number;
  d2drlg_act_level_adjacents(act: number, index: number, out: number, cap: number): number;
  d2drlg_act_level_collision(
    act: number, index: number, out: number, cap: number, w: number, h: number,
  ): number;
  d2drlg_level_act(ctx: number, levelId: number): number;
  d2drlg_level_name(ctx: number, levelId: number, buf: number, cap: number): number;
  d2drlg_object_name(txtFileNo: number, buf: number, cap: number): number;
  d2drlg_abi_version(): number;

  d2pf_options_default(out: number): void;
  d2pf_world_create(ctx: number, seed: number, difficulty: number): number;
  d2pf_world_destroy(world: number): void;
  d2pf_world_load_act(world: number, actNo: number): number;
  d2pf_route(
    world: number, fromLevel: number, fromX: number, fromY: number,
    toLevel: number, toX: number, toY: number, opts: number,
  ): number;
  d2pf_route_free(route: number): void;
  d2pf_route_leg_count(route: number): number;
  d2pf_route_move_count(route: number): number;
  d2pf_route_leg_level(route: number, leg: number): number;
  d2pf_route_leg_exit(route: number, leg: number): number;
  d2pf_route_leg_moves(route: number, leg: number, out: number, cap: number): number;
  d2pf_level_route(world: number, from: number, to: number, out: number, cap: number): number;
  d2pf_walkable(world: number, levelId: number, x: number, y: number): number;
  d2pf_line_of_sight(
    world: number, levelId: number, fx: number, fy: number, tx: number, ty: number, mask: number,
  ): number;
  d2pf_nearest_passable(
    world: number, levelId: number, x: number, y: number, radius: number,
    outX: number, outY: number,
  ): number;
  d2pf_abi_version(): number;
}

async function moduleBytes(): Promise<BufferSource> {
  const url = new URL('./libd2.wasm', import.meta.url);
  if (url.protocol !== 'file:') {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`libd2: fetching ${url} failed with ${response.status}`);
    return await response.arrayBuffer();
  }
  const [{readFile}, {fileURLToPath}] = await Promise.all([
    import('node:fs/promises'),
    import('node:url'),
  ]);
  return await readFile(fileURLToPath(url));
}

let loading: Promise<Exports> | null = null;

/**
 * The instantiated module, loaded once per process.
 *
 * The import object is empty because the wasm is freestanding and libc-free, which is what lets the
 * same file run in Node, Bun, Deno and a browser with no polyfill and no bundler configuration.
 */
export function load(): Promise<Exports> {
  loading ??= (async () => {
    const {instance} = await WebAssembly.instantiate(await moduleBytes(), {});
    return instance.exports as unknown as Exports;
  })();
  return loading;
}

/**
 * A scratch region in wasm memory for the ABI to write into.
 *
 * The ABI never allocates for the caller: every list-returning export takes a pointer and a
 * capacity and returns the true count, so truncation is detectable rather than silent. This is
 * where those pointers point. It grows to fit and is reused, because the alternative — asking the
 * module for memory per call — is what makes a wasm boundary slow.
 */
export class Scratch {
  #exports: Exports;
  #base = 0;
  #capacity = 0;

  constructor(exports: Exports) {
    this.#exports = exports;
  }

  /** A byte view of `bytes` scratch bytes. Invalidated by the next `take`, and by memory growth. */
  take(bytes: number): {ptr: number; view: DataView} {
    if (bytes > this.#capacity) this.#reserve(bytes);
    return {ptr: this.#base, view: new DataView(this.#exports.memory.buffer, this.#base, bytes)};
  }

  bytes(ptr: number, length: number): Uint8Array {
    return new Uint8Array(this.#exports.memory.buffer, ptr, length);
  }

  #reserve(bytes: number): void {
    const PAGE = 65536;
    const memory = this.#exports.memory;
    const needed = Math.ceil(bytes / PAGE) + 1;
    // Grow at the END of linear memory and keep the region: the module's own allocator hands out
    // pages below whatever grow() returns, so a region taken this way is never handed out again.
    const first = memory.grow(needed);
    this.#base = first * PAGE;
    this.#capacity = needed * PAGE;
  }
}

/** Read a NUL-terminated (or length-delimited) UTF-8 string the ABI wrote. */
export function readString(scratch: Scratch, ptr: number, length: number): string {
  if (length <= 0) return '';
  const raw = scratch.bytes(ptr, length);
  const end = raw.indexOf(0);
  return new TextDecoder().decode(end === -1 ? raw : raw.subarray(0, end));
}

export const SIZES = {ROOM, PRESET, ADJACENT, MOVE, OPTIONS} as const;
