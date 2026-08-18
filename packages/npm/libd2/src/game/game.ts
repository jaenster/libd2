// One seed at one difficulty: the whole world it produces.
//
// `init()` is the only asynchronous thing in the library, and it is asynchronous for one reason —
// fetching and instantiating a WebAssembly module is. Everything after it is synchronous, because
// everything after it is arithmetic: generating an act, reading its rooms, routing across it. None
// of that waits on anything, so none of it should colour a caller's code with `await`.
//
// That matters more than it sounds. A renderer drawing a frame, a bot deciding its next step and a
// predicate re-evaluated on every packet all want an answer now, and an `await` in any of them is a
// yield to the event loop in the middle of work that never needed one.

import {engine, initRuntime, runtimeOrNull} from '../internal.ts';
import {Area} from '../drlg/area.ts';
import type {AreaId} from '../areas.ts';

export type Difficulty = 'normal' | 'nightmare' | 'hell';
const DIFFICULTIES: Difficulty[] = ['normal', 'nightmare', 'hell'];

export type ActNumber = 0 | 1 | 2 | 3 | 4;

/**
 * Load the engine. Once per process, before anything else.
 *
 *     await init();
 *     using game = open({seed: 1337, difficulty: 'hell'});
 *
 * Idempotent and safe to call concurrently — the module is instantiated once and every caller gets
 * the same one.
 */
export async function init(): Promise<void> {
  await initRuntime();
}

export function isInitialised(): boolean {
  return runtimeOrNull() !== null;
}

/**
 * One seed at one difficulty.
 *
 * The aggregate root, the way it is in the engine — a game IS a seed and a difficulty, and
 * everything else is a view onto it. Which is why nothing below takes a seed, a difficulty or an
 * act number: the Game is the only thing that could answer those, and it already has.
 *
 * It generates what you ask for and nothing else. The engine's unit of generation is the ACT — the
 * placement graph positions a whole act's levels together, so there is no such thing as generating
 * one level — and holding every act at once costs roughly half a gigabyte of wasm linear memory,
 * which never shrinks. Asking for the areas a run actually visits costs the acts they are in.
 *
 * A Game owns native handles, so close it, or declare it with `using` and let the block do it.
 */
export class Game implements Disposable {
  readonly seed: number;
  readonly difficulty: Difficulty;

  /** The generation context handle, for the exports that take one. */
  readonly ctx: number;
  /** The routing world, sharing this context's memory. */
  readonly world: number;

  #acts = new Map<ActNumber, number>();
  #areas = new Map<number, Area>();
  #closed = false;

  constructor(options: {seed: number; difficulty?: Difficulty}) {
    const {exports} = engine();
    this.seed = options.seed;
    this.difficulty = options.difficulty ?? 'normal';
    const difficulty = DIFFICULTIES.indexOf(this.difficulty);
    if (difficulty < 0) throw new RangeError(`unknown difficulty ${options.difficulty}`);

    this.ctx = exports.d2drlg_ctx_create();
    if (!this.ctx) throw new Error('libd2: could not create a generation context');
    this.world = exports.d2pf_world_create(exports.d2drlg_ctx_core(this.ctx), this.seed, difficulty);
    if (!this.world) {
      exports.d2drlg_ctx_destroy(this.ctx);
      throw new Error('libd2: could not create a routing world');
    }
  }

  /** The generated handle for an act, generating it on first ask. */
  act(n: ActNumber): number {
    this.#assertOpen();
    const existing = this.#acts.get(n);
    if (existing !== undefined) return existing;

    const {exports} = engine();
    const difficulty = DIFFICULTIES.indexOf(this.difficulty);
    const handle = exports.d2drlg_gen_act(this.ctx, this.seed, difficulty, n);
    if (!handle) throw new Error(`libd2: generating act ${n + 1} of seed ${this.seed} failed`);
    this.#acts.set(n, handle);
    // The router keeps its own view of an act's levels, and a route across one it has not loaded
    // finds nothing rather than failing, which is the worse of the two.
    exports.d2pf_world_load_act(this.world, n);
    return handle;
  }

  /** One area, generating its act if that has not happened yet. */
  area(id: AreaId): Area {
    this.#assertOpen();
    const cached = this.#areas.get(id);
    if (cached) return cached;

    const {exports} = engine();
    const actNumber = exports.d2drlg_level_act(this.ctx, id);
    if (actNumber < 0) throw new RangeError(`no act contains area ${id}`);

    const handle = this.act(actNumber as ActNumber);
    const count = exports.d2drlg_act_level_count(handle);
    for (let index = 0; index < count; index++) {
      const levelId = exports.d2drlg_act_level_id(handle, index) as AreaId;
      if (this.#areas.has(levelId)) continue;
      this.#areas.set(levelId, new Area(this, levelId, actNumber as ActNumber, index));
    }

    const area = this.#areas.get(id);
    if (!area) throw new RangeError(`act ${actNumber + 1} generated without area ${id}`);
    return area;
  }

  /**
   * Several areas at once, as a tuple as long as the list:
   *
   *     const [town, catacombs2, catacombs4] = game.areas(1, 35, 37);
   *
   * Ids in the same act cost one generation between them.
   */
  areas<const Ids extends readonly [AreaId, ...AreaId[]]>(...ids: Ids): {[K in keyof Ids]: Area} {
    return ids.map((id) => this.area(id)) as {[K in keyof Ids]: Area};
  }

  /** Every area of an act. */
  actAreas(n: ActNumber): readonly Area[] {
    const handle = this.act(n);
    const {exports} = engine();
    const count = exports.d2drlg_act_level_count(handle);
    const areas: Area[] = [];
    for (let index = 0; index < count; index++) {
      areas.push(this.area(exports.d2drlg_act_level_id(handle, index) as AreaId));
    }
    return areas;
  }

  /** The area with this display name, or undefined. Case-insensitive, across generated acts only. */
  findArea(name: string): Area | undefined {
    const wanted = name.toLowerCase();
    for (const area of this.#areas.values()) {
      if (area.name.toLowerCase() === wanted) return area;
    }
    return undefined;
  }

  /** What has been generated. For diagnostics, not for logic. */
  get generatedActs(): readonly ActNumber[] {
    return [...this.#acts.keys()];
  }

  isGenerated(n: ActNumber): boolean {
    return this.#acts.has(n);
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    const {exports} = engine();
    exports.d2pf_world_destroy(this.world);
    for (const handle of this.#acts.values()) exports.d2drlg_act_free(handle);
    exports.d2drlg_ctx_destroy(this.ctx);
    this.#acts.clear();
    this.#areas.clear();
  }

  [Symbol.dispose](): void {
    this.close();
  }

  #assertOpen(): void {
    if (this.#closed) throw new Error('libd2: this game is closed');
  }
}

/**
 * Open a game. Synchronous, and cheap: no act is generated until one is asked for.
 *
 *     await init();
 *     using game = open({seed: 1337, difficulty: 'hell'});
 *     const town = game.area(Areas.RogueEncampment);
 */
export function open(options: {seed: number; difficulty?: Difficulty}): Game {
  return new Game(options);
}
