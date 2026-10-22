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

import {EXPECTED_ABI, LAYOUT, type Exports} from './abi.ts';

export {EXPECTED_ABI, LAYOUT, type Exports};

/** sizeof each extern struct the ABI writes into caller memory, from the generated layout. */
const ROOM = LAYOUT.D2DrlgRoom.size;
const PRESET = LAYOUT.D2DrlgPreset.size;
const ADJACENT = LAYOUT.D2DrlgAdjacent.size;
const MOVE = LAYOUT.D2PfMove.size;
const OPTIONS = LAYOUT.D2PfOptions.size;

async function moduleBytes(file: string): Promise<BufferSource> {
  const url = new URL(`./${file}`, import.meta.url);
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

/**
 * Which module carries which library. The map, router, wire and scaler share one module (see the
 * top of this file); items are a second one, because the item tables would make every map consumer
 * download a module twice the size, and nothing passes a pointer between the two.
 */
export const MODULES = {
  'libd2.wasm': ['d2drlg', 'd2pf', 'd2net', 'd2util'],
  'items.wasm': ['d2item', 'd2itemdraw'],
} as const satisfies Record<string, readonly (keyof typeof EXPECTED_ABI)[]>;

const loading = new Map<string, Promise<Exports>>();

/**
 * One module, instantiated once per process. A module built from another revision than these
 * declarations fails here, not with a wrong struct offset somewhere later.
 *
 * The import object is empty because the wasm is freestanding and libc-free, which is what lets the
 * same file run in Node, Bun, Deno and a browser with no polyfill and no bundler configuration.
 */
function instantiate(file: keyof typeof MODULES): Promise<Exports> {
  let p = loading.get(file);
  if (!p) {
    p = (async () => {
      const {instance} = await WebAssembly.instantiate(await moduleBytes(file), {});
      const exports = instance.exports as Record<string, unknown>;
      for (const lib of MODULES[file]) {
        const version = exports[`${lib}_abi_version`];
        if (typeof version !== 'function') throw new Error(`libd2: ${file} has no ${lib}`);
        const found = Number((version as () => number)());
        const want = EXPECTED_ABI[lib];
        if (found !== want) throw new Error(`libd2: ${file}'s ${lib} speaks ABI ${found}, this package expects ${want}`);
      }
      return instance.exports as unknown as Exports;
    })();
    loading.set(file, p);
  }
  return p;
}

/** The map module (drlg, pf, net, util). Only those libraries' exports are present. */
export function load(): Promise<Exports> {
  return instantiate('libd2.wasm');
}

/** The item module (item, itemdraw). Only those libraries' exports are present. */
export function loadItems(): Promise<Exports> {
  return instantiate('items.wasm');
}

/** Every library's exports, for the generated smoke test: each lives in exactly one module. */
export async function loadAll(): Promise<Exports> {
  const [map, items] = await Promise.all([load(), loadItems()]);
  return {...(items as object), ...(map as object)} as Exports;
}

/**
 * A scratch region in wasm memory for the ABI to write into.
 *
 * The ABI never allocates for the caller: every list-returning export takes a pointer and a
 * capacity and returns the true count, so truncation is detectable rather than silent. This is
 * where those pointers point. It grows to fit and is reused, because the alternative — asking the
 * module for memory per call — is what makes a wasm boundary slow.
 */
/**
 * A window onto scratch memory that cannot go stale.
 *
 * Mirrors the slice of DataView the library actually uses. Each call builds a fresh view over the
 * module's CURRENT buffer, so it stays valid across a memory growth that would have detached a
 * held one.
 */
export class ScratchView {
  #exports: Exports;
  #base: number;
  #bytes: number;

  constructor(exports: Exports, base: number, bytes: number) {
    this.#exports = exports;
    this.#base = base;
    this.#bytes = bytes;
  }

  #dv(): DataView {
    return new DataView(this.#exports.memory.buffer, this.#base, this.#bytes);
  }

  getInt32(offset: number, littleEndian?: boolean): number {
    return this.#dv().getInt32(offset, littleEndian);
  }

  getUint16(offset: number, littleEndian?: boolean): number {
    return this.#dv().getUint16(offset, littleEndian);
  }

  setInt32(offset: number, value: number, littleEndian?: boolean): void {
    this.#dv().setInt32(offset, value, littleEndian);
  }

  setUint16(offset: number, value: number, littleEndian?: boolean): void {
    this.#dv().setUint16(offset, value, littleEndian);
  }
}

export class Scratch {
  #exports: Exports;
  #base = 0;
  #capacity = 0;

  constructor(exports: Exports) {
    this.#exports = exports;
  }

  /**
   * A region of `bytes` scratch bytes: a pointer, and a window onto it.
   *
   * The window is NOT a DataView. It rebuilds one per access, because any call into the module can
   * grow linear memory and growth DETACHES the old ArrayBuffer — every DataView made before that
   * call then throws `Cannot perform DataView.prototype.getInt32 on a detached ArrayBuffer` the
   * moment it is read. That hides until a level is big enough to trigger a grow, and then takes
   * down whatever was mid-read.
   *
   * A getter on the returned object is not enough, and that is the subtle part: every caller here
   * writes `const {ptr, view} = scratch.take(n)`, and destructuring EVALUATES a getter once and
   * keeps the result — reintroducing exactly the stale view it was meant to prevent. So the window
   * is an object whose own methods each rebuild, which stays correct however it is passed around.
   */
  take(bytes: number): {ptr: number; view: ScratchView} {
    if (bytes > this.#capacity) this.#reserve(bytes);
    return {ptr: this.#base, view: new ScratchView(this.#exports, this.#base, bytes)};
  }

  /** Bytes at `ptr`. Read them now: the next call into the module may detach the buffer. */
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
