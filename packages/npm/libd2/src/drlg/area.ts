// One level: its geometry, what the generator put in it, and how to get out of it.
//
// Everything here is lazy and cached. Opening a game generates nothing; asking an area for its
// rooms generates the act that contains it, and asking a second area of the same act is then free.
// A run that only ever visits three levels never pays for the other forty.

import {engine} from '../internal.ts';
import {readString, SIZES} from '../wasm.ts';
import type {AreaId} from '../areas.ts';
import {SUBTILE, type Point, type Size} from './point.ts';
import {Location} from './location.ts';
import {makeExit, seams, type Exit} from './exit.ts';
import {objectName, type Room, type WorldObject} from './room.ts';
import {CollisionGrid, WalkGrid, Walk} from './collision.ts';
import {Colbit, Masks} from './collision.flags.ts';
import type {ActNumber, Game} from '../game/game.ts';

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
  #walk?: WalkGrid;

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
      const raw = new Map<AreaId, Location[]>();
      const placeless = new Set<AreaId>();
      const seen = new Set<string>();
      for (let i = 0; i < Math.min(written, CAP); i++) {
        const at = i * SIZES.ADJACENT;
        const toId = view.getInt32(at, true) as AreaId;
        const x = view.getInt32(at + 4, true);
        const y = view.getInt32(at + 8, true);
        if (x < 0 || y < 0) {
          placeless.add(toId);
          continue;
        }
        const key = `${toId}:${x}:${y}`;
        if (seen.has(key)) continue;
        seen.add(key);
        const into = raw.get(toId) ?? [];
        into.push(new Location(this, x, y));
        raw.set(toId, into);
      }

      const exits: Exit[] = [];
      for (const [toId, points] of raw) {
        const to = this.game.area(toId);
        for (const seam of seams(points)) exits.push(makeExit(this, to, seam));
      }
      // An adjacency with no cell of its own is still an adjacency: it says the two levels are
      // connected without saying where. Dropping it would make the area graph claim there is no
      // way through.
      for (const toId of placeless) {
        if (raw.has(toId)) continue;
        exits.push(makeExit(this, this.game.area(toId), []));
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

  /**
   * The walk grid for a walking player: one byte per subtile, classified into {@link Walk}.
   *
   * Derived from `collision` rather than fetched, because the classification depends on WHO is
   * walking. Passability is the map: a monster and a missile see different walls in the same level,
   * so a grid baked for one of them is the wrong map for the others. {@link Area.walkFor} is the
   * same thing under another movement model.
   */
  get walk(): WalkGrid {
    this.#walk ??= this.walkFor(Masks.playerPath);
    return this.#walk;
  }

  /** The walk grid under a given movement model — see {@link Masks}. */
  walkFor(mask: number): WalkGrid {
    const grid = this.collision;
    const cells = new Uint8Array(grid.cells.length);
    for (let i = 0; i < cells.length; i++) {
      const cell = grid.cells[i] ?? 0;
      // Blank is the engine's "no floor tile here", and it is NOT a wall. Collapsing the two is
      // what draws the room-union silhouette and every gap between rooms as geometry the game
      // does not have.
      cells[i] = (cell & Colbit.blank) !== 0
        ? Walk.void
        : (cell & mask) === 0 ? Walk.open : Walk.blocked;
    }
    return new WalkGrid(grid.width, grid.height, cells);
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
  /**
   * The rectangle this level occupies, in WORLD subtiles.
   *
   * Half-open: `x1`/`y1` is the first coordinate that is no longer ours. Levels of an act are laid
   * out in one coordinate space and neighbouring ones abut exactly, so `x1` of the level you are
   * on is `x0` of the level next to it — which is what makes a crossing a line rather than a door.
   */
  get worldBox(): {x0: number; y0: number; x1: number; y1: number} {
    const {x, y} = this.origin;
    const {width, height} = this.size;
    return {
      x0: x * SUBTILE,
      y0: y * SUBTILE,
      x1: (x + width) * SUBTILE,
      y1: (y + height) * SUBTILE,
    };
  }

  get middle(): Location {
    const {width, height} = this.size;
    return new Location(this, Math.floor((width * SUBTILE) / 2), Math.floor((height * SUBTILE) / 2));
  }

  contains(location: Location): boolean {
    return location.area.id === this.id;
  }

  // ── the live world ───────────────────────────────────────────────────────────────────────────
  //
  // Terrain is what the seed produced and never changes; a monster standing in a doorway is just
  // as impassable and is not in the seed at all. The router has always consulted both — a level
  // carries an occupancy grid alongside its collision — so a caller that knows where the units are
  // and does not say so is routing through them, and then cannot understand why the server refuses
  // to walk the path. Telling it is this.

  /**
   * Put a live unit on this level's map, or move one already there.
   *
   * `type` is the engine's own `eD2UnitType` (0 player, 1 monster, 2 object, 5 room tile) and
   * `size` its `GetUnitSizeX` — between them they pick the stamp and the collision bit the engine
   * would use. Every query from here on — walkability, routing, line of sight — sees it.
   */
  place(unit: {id: number; type: number; size?: number; x: number; y: number}): void {
    const {exports} = engine();
    exports.d2pf_unit_place(
      this.game.world, this.id, unit.id >>> 0, unit.type, unit.size ?? 1,
      Math.round(unit.x), Math.round(unit.y),
    );
  }

  /** Take a unit off this level, restoring every cell it covered. */
  lift(id: number): void {
    engine().exports.d2pf_unit_lift(this.game.world, this.id, id >>> 0);
  }

  /** Empty this level's live world. Leaving, or resyncing from scratch. */
  clearUnits(): void {
    engine().exports.d2pf_units_clear(this.game.world, this.id);
  }

  /**
   * Replace this level's live world with exactly these units.
   *
   * The wire gives whole snapshots far more often than it gives reliable departures, so "these and
   * nothing else" is the operation a caller actually has, and rebuilding is cheap next to being
   * wrong about a unit that left.
   */
  occupy(units: Iterable<{id: number; type: number; size?: number; x: number; y: number}>): void {
    this.clearUnits();
    for (const u of units) this.place(u);
  }

  toString(): string {
    return this.name;
  }
}
