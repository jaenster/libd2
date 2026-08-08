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

import {readString, SIZES, type Exports, type Scratch} from './wasm.ts';
import {engineFor, initRuntime, runtimeOrNull} from './internal.ts';
import type {AreaId} from './areas.ts';

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

/** The module, for the places inside this file that reach for it before a Game exists. */
function engine(): {exports: Exports; scratch: Scratch} {
  const runtime = runtimeOrNull();
  if (!runtime) throw new Error('libd2: call `await init()` before opening a game');
  return runtime;
}

/** Where something is, in the frame the caller asked for. */
export interface Point {
  readonly x: number;
  readonly y: number;
}

export interface Size {
  readonly width: number;
  readonly height: number;
}

/** Subtiles per tile. The engine's own ratio, and the only place it should be written down. */
const SUBTILE = 5;

/**
 * A point in the world that knows where it is. An immutable value: no identity, no lifecycle.
 *
 * `x` and `y` are level-local subtiles, the frame an area's own map data uses. It carries its Area
 * so the other frames are properties rather than arithmetic no caller should be writing.
 */
export class Location {
  readonly area: Area;
  readonly x: number;
  readonly y: number;

  constructor(area: Area, x: number, y: number) {
    this.area = area;
    this.x = x;
    this.y = y;
  }

  /** The same point in world subtiles, the frame in-game positions use. */
  get world(): Point {
    const origin = this.area.origin;
    return {x: origin.x * SUBTILE + this.x, y: origin.y * SUBTILE + this.y};
  }

  /** The same point in world tiles, the frame rooms and area origins use. */
  get tile(): Point {
    const origin = this.area.origin;
    return {x: origin.x + Math.floor(this.x / SUBTILE), y: origin.y + Math.floor(this.y / SUBTILE)};
  }

  /**
   * Straight-line distance in subtiles, measured in the world frame.
   *
   * Works between areas of the same act, because their origins are placed in one coordinate space.
   * Across acts it throws, because two acts' origins are two different rulers and a number would be
   * worse than an error.
   */
  distanceTo(other: Location): number {
    if (other.area.actNumber !== this.area.actNumber) {
      throw new RangeError(
        `${this.area.name} and ${other.area.name} are in different acts; there is no distance between them`,
      );
    }
    const a = this.world;
    const b = other.world;
    return Math.hypot(a.x - b.x, a.y - b.y);
  }

  offset(dx: number, dy: number): Location {
    return new Location(this.area, this.x + dx, this.y + dy);
  }

  equals(other: Location): boolean {
    return this.area.id === other.area.id && this.x === other.x && this.y === other.y;
  }

  toString(): string {
    return `${this.area.name} (${this.x},${this.y})`;
  }
}

/** A rectangle of an area, in world tiles. */
export interface Room {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  /** RoomEx.nType */
  readonly type: number;
  /** 1 outdoor/maze, 2 preset. */
  readonly presetType: number;
  /** Preset nPickedFile, or outdoor nSubThemePicked. -1 when neither. */
  readonly pickedFile: number;
}

/** A way out of an area, carrying where it leads. */
export interface Exit {
  readonly from: Area;
  readonly to: Area;
  /** Where it stands, when the generator placed a physical warp. */
  readonly location: Location | null;
}

/** Something the generator placed: a preset object, by its Objects.txt id. */
export interface WorldObject {
  readonly area: Area;
  readonly location: Location;
  /** Objects.txt row. */
  readonly classId: number;
  readonly name: string;
}

/**
 * One level of one act.
 *
 * Everything on it is read from the act's generated data on demand and then kept, so the first
 * `rooms` costs a copy out of wasm memory and the rest cost nothing.
 */
export class Area {
  readonly game: Game;
  readonly id: AreaId;
  readonly actNumber: ActNumber;
  /** This level's index within its act's generated data — the handle the ABI wants. */
  readonly #index: number;

  #name?: string;
  #origin?: Point;
  #size?: Size;
  #rooms?: readonly Room[];
  #exits?: readonly Exit[];
  #objects?: readonly WorldObject[];
  #collision?: CollisionGrid;

  constructor(game: Game, id: AreaId, actNumber: ActNumber, index: number) {
    this.game = game;
    this.id = id;
    this.actNumber = actNumber;
    this.#index = index;
  }

  get name(): string {
    if (this.#name === undefined) {
      const {exports, scratch} = engine();
      const {ptr} = scratch.take(64);
      const n = exports.d2drlg_level_name(this.game.ctx, this.id, ptr, 64);
      this.#name = readString(scratch, ptr, n);
    }
    return this.#name;
  }

  /** Where this area sits, in world tiles. */
  get origin(): Point {
    if (this.#origin === undefined) {
      const {exports, scratch} = engine();
      const {ptr, view} = scratch.take(8);
      exports.d2drlg_act_level_origin(this.game.act(this.actNumber), this.#index, ptr, ptr + 4);
      this.#origin = {x: view.getInt32(0, true), y: view.getInt32(4, true)};
    }
    return this.#origin;
  }

  /** How big it is, in tiles. */
  get size(): Size {
    if (this.#size === undefined) {
      const {exports, scratch} = engine();
      const {ptr, view} = scratch.take(8);
      exports.d2drlg_act_level_size(this.game.act(this.actNumber), this.#index, ptr, ptr + 4);
      this.#size = {width: view.getInt32(0, true), height: view.getInt32(4, true)};
    }
    return this.#size;
  }

  get rooms(): readonly Room[] {
    if (this.#rooms === undefined) {
      const {exports, scratch} = engine();
      const act = this.game.act(this.actNumber);
      const count = exports.d2drlg_act_level_room_count(act, this.#index);
      const rooms: Room[] = [];
      if (count > 0) {
        const {ptr, view} = scratch.take(count * SIZES.ROOM);
        const written = exports.d2drlg_act_rooms(act, this.#index, ptr, count);
        for (let i = 0; i < Math.min(written, count); i++) {
          const at = i * SIZES.ROOM;
          rooms.push({
            x: view.getInt32(at, true),
            y: view.getInt32(at + 4, true),
            width: view.getInt32(at + 8, true),
            height: view.getInt32(at + 12, true),
            type: view.getInt32(at + 16, true),
            presetType: view.getInt32(at + 20, true),
            pickedFile: view.getInt32(at + 24, true),
          });
        }
      }
      this.#rooms = rooms;
    }
    return this.#rooms;
  }

  /** The ways out, each carrying the area it leads to. */
  get exits(): readonly Exit[] {
    if (this.#exits === undefined) {
      const {exports, scratch} = engine();
      const act = this.game.act(this.actNumber);
      const CAP = 64;
      const {ptr, view} = scratch.take(CAP * SIZES.ADJACENT);
      const written = exports.d2drlg_act_level_adjacents(act, this.#index, ptr, CAP);
      const exits: Exit[] = [];
      const seen = new Set<string>();
      for (let i = 0; i < Math.min(written, CAP); i++) {
        const at = i * SIZES.ADJACENT;
        const toId = view.getInt32(at, true) as AreaId;
        const x = view.getInt32(at + 4, true);
        const y = view.getInt32(at + 8, true);
        const to = this.game.area(toId);
        // The adjacency list names a crossing once per room that touches it, so the same way out
        // arrives several times. A run wants the ways out, not the rooms that produced them.
        const key = `${toId}:${x}:${y}`;
        if (seen.has(key)) continue;
        seen.add(key);
        exits.push({from: this, to, location: x < 0 || y < 0 ? null : new Location(this, x, y)});
      }
      this.#exits = exits;
    }
    return this.#exits;
  }

  /** What the generator placed here, by Objects.txt id. */
  get objects(): readonly WorldObject[] {
    if (this.#objects === undefined) {
      const {exports, scratch} = engine();
      const act = this.game.act(this.actNumber);
      const CAP = 512;
      const {ptr, view} = scratch.take(CAP * SIZES.PRESET);
      const written = exports.d2drlg_act_level_presets(act, this.#index, ptr, CAP);
      const objects: WorldObject[] = [];
      for (let i = 0; i < Math.min(written, CAP); i++) {
        const at = i * SIZES.PRESET;
        const classId = view.getInt32(at, true);
        const x = view.getInt32(at + 4, true);
        const y = view.getInt32(at + 8, true);
        objects.push({
          area: this,
          location: new Location(this, x, y),
          classId,
          name: objectName(classId),
        });
      }
      this.#objects = objects;
    }
    return this.#objects;
  }

  /** The subtile collision grid. One `u16` of flags per subtile; see {@link CollisionGrid}. */
  get collision(): CollisionGrid {
    if (this.#collision === undefined) {
      const {exports, scratch} = engine();
      const act = this.game.act(this.actNumber);

      // Probe with a zero capacity first. The ABI always writes the true dims and returns the true
      // cell count, so one probe beats guessing — and the grids are large enough that guessing
      // wrong means either a wasted megabyte or a silently truncated level.
      const dims = scratch.take(8);
      exports.d2drlg_act_level_collision(act, this.#index, 0, 0, dims.ptr, dims.ptr + 4);
      const width = dims.view.getInt32(0, true);
      const height = dims.view.getInt32(4, true);
      const cells = width * height;
      if (cells <= 0) {
        this.#collision = new CollisionGrid(0, 0, new Uint16Array(0));
      } else {
        // Two bytes per cell: the grid is u16 flags, not a byte per subtile.
        const {ptr, view} = scratch.take(cells * 2 + 8);
        exports.d2drlg_act_level_collision(
          act, this.#index, ptr, cells, ptr + cells * 2, ptr + cells * 2 + 4,
        );
        const grid = new Uint16Array(cells);
        for (let i = 0; i < cells; i++) grid[i] = view.getUint16(i * 2, true);
        this.#collision = new CollisionGrid(width, height, grid);
      }
    }
    return this.#collision;
  }

  /** A Location in this area, from level-local subtiles. */
  at(x: number, y: number): Location {
    return new Location(this, x, y);
  }

  /**
   * A Location in this area, from WORLD subtiles — the frame in-game positions arrive in.
   *
   * The inverse of {@link Location.world}, and the one a live client needs: the server states
   * every position in world subtiles, while an area's own map data is level-local. Getting this
   * backwards puts you thousands of cells outside the level, where routing correctly finds
   * nothing.
   */
  fromWorld(x: number, y: number): Location {
    const origin = this.origin;
    return new Location(this, x - origin.x * SUBTILE, y - origin.y * SUBTILE);
  }

  /** The geometric middle. Often inside a wall — `snap` it before routing to it. */
  get middle(): Location {
    const {width, height} = this.size;
    return new Location(this, Math.floor((width * SUBTILE) / 2), Math.floor((height * SUBTILE) / 2));
  }

  contains(location: Location): boolean {
    return location.area.id === this.id;
  }

  toString(): string {
    return this.name;
  }
}

/**
 * A level's subtile collision: one `u16` of flags per cell.
 *
 * Collision is a MASK, not a boolean. Every test is `cell & mask === 0`, so a walking player, a
 * walking monster and a missile in flight are the same question with three different masks —
 * missiles pass objects and doors that stop a player. {@link Masks} is the vocabulary; `walkableAt`
 * is what to ask rather than reading bits by hand. The raw cells are here because a renderer wants
 * them all at once.
 */
export class CollisionGrid {
  readonly width: number;
  readonly height: number;
  readonly cells: Uint16Array;

  constructor(width: number, height: number, cells: Uint16Array) {
    this.width = width;
    this.height = height;
    this.cells = cells;
  }

  /** The flags at a cell. Outside the grid reads as VOID, which fails every mask. */
  at(x: number, y: number): number {
    if (x < 0 || y < 0 || x >= this.width || y >= this.height) return 0xffff;
    return this.cells[y * this.width + x] ?? 0xffff;
  }

  /** Whether a unit with this movement model may stand here. */
  passable(x: number, y: number, mask: number = Masks.playerPath): boolean {
    return (this.at(x, y) & mask) === 0;
  }
}

/**
 * The engine's own collision bits, from `d2-core`'s `Colbit`. One flag per meaning, so a caller
 * that wants to draw doors differently from walls can ask rather than guess.
 */
export const Colbit = {
  /** Blocks walking. The primary terrain bit. */
  wall: 0x01,
  /** Blocks line of sight. */
  visible: 0x02,
  missileBarrier: 0x04,
  /** Blocks players only — monsters path straight through. Town borders use it. */
  noPlayer: 0x08,
  preset: 0x10,
  /** "No floor tile here": the engine's own marker for outside the level. Not a movement blocker. */
  blank: 0x20,
  missile: 0x40,
  player: 0x80,
  monster: 0x100,
  item: 0x200,
  object: 0x400,
  /** A closed door blocks; a host clears the bit when it opens. */
  door: 0x800,
  noPath: 0x1000,
} as const;

/**
 * The engine's own movement models, from `d2-core`'s `Colmask` — the same names the producer of a
 * grid uses, so the two cannot drift apart.
 */
export const Masks = {
  /** A walking player. The default everywhere a mask is optional. */
  playerPath: 0x1c09,
  playerFlying: 0x804,
  monsterPath: 0x3c01,
  monsterMissile: 0x101,
  /** `COLBIT_MISSILE_BARRIER | COLBIT_WALL`, as SKILL_CheckMissileCollisionAtTarget spells it. */
  missileFlight: 0x1001,
  spawn: 0x3e01,
  placement: 0x3f11,
  any: 0xffff,
} as const;

function objectName(classId: number): string {
  const {exports, scratch} = engine();
  const {ptr} = scratch.take(64);
  const n = exports.d2drlg_object_name(classId, ptr, 64);
  return readString(scratch, ptr, n);
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
