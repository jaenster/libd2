// Moving through the world.
//
// These are functions rather than methods, and the reason is in the signatures. Every one needs
// something the object it looks like it belongs on does not have: `walkableAt` needs a movement
// policy (a walking player, a monster, a missile and a flying caster get different answers for the
// same cell), `route` needs the area graph and both endpoints, `areasBetween` needs a graph no
// single Area holds. Data and its own algebra stay on the objects — `location.distanceTo`,
// `area.rooms`. Anything that has to be TOLD something is a function that says so.
//
// All of it is synchronous. Routing is a search over grids already in memory; there is nothing to
// wait for, so there is no reason to make a caller await.

import {Area, Location, Masks, type Game} from './game.ts';
import {engineFor} from './internal.ts';
import {MOVE_KINDS, SIZES, type MoveKind} from './wasm.ts';

/** One step of a route. */
export interface Move {
  readonly location: Location;
  readonly kind: MoveKind;
}

/** The part of a route inside one area. */
export interface Leg {
  readonly area: Area;
  readonly moves: readonly Move[];
  /** The area this leg leads into, or null on the last one. */
  readonly exit: Area | null;
}

/**
 * A way from one Location to another.
 *
 * Iterating a Route walks its moves in order across every area, because that is what a consumer
 * almost always wants. `legs` is there for when the boundaries matter — and a transition always
 * runs from a leg's last move to the next leg's first, whether it is a staircase, an area border or
 * a teleport cast, so the far side never needs a case of its own.
 */
export class Route implements Iterable<Move> {
  readonly from: Location;
  readonly to: Location;
  readonly legs: readonly Leg[];

  constructor(from: Location, to: Location, legs: readonly Leg[]) {
    this.from = from;
    this.to = to;
    this.legs = legs;
  }

  get moves(): readonly Move[] {
    return this.legs.flatMap((leg) => leg.moves);
  }

  get areas(): readonly Area[] {
    return this.legs.map((leg) => leg.area);
  }

  /** Total moves across every leg. A cheap way to compare two routes. */
  get length(): number {
    return this.legs.reduce((total, leg) => total + leg.moves.length, 0);
  }

  [Symbol.iterator](): Iterator<Move> {
    return this.moves[Symbol.iterator]();
  }
}

export interface RouteOptions {
  /** Teleport where the area permits it. Areas that forbid it fall back to walking. */
  teleport?: boolean;
  /** Teleport across level boundaries too, rather than only within one. */
  teleportAcrossAreas?: boolean;
  /** Maximum cast distance in subtiles. The engine's own gate is 50. */
  maxCastDistance?: number;
  castMetric?: 'chebyshev' | 'euclidean';
  /** Accept a walkable cell this far from a blocked start or goal. */
  snapRadius?: number;
  /** Movement collision model. Defaults to {@link Masks.playerPath}. */
  collisionMask?: number;
}

/**
 * Whether something can stand at a point.
 *
 * Only the point's own area is consulted, which is why this takes no Game.
 */
export function walkableAt(location: Location): boolean {
  const {exports} = engineFor(location.area.game);
  const {game, id} = location.area;
  game.act(location.area.actNumber); // ensure the router has the act
  return exports.d2pf_walkable(game.world, id, location.x, location.y) > 0;
}

/**
 * The closest point to `location` that {@link walkableAt} accepts, searched outward to `radius`, or
 * null when nothing that near does.
 *
 * This is what to call before routing anywhere you did not pick yourself: an area's `middle` is as
 * likely to be inside a wall as not, and a monster's own cell usually is.
 */
export function snap(location: Location, radius = 20): Location | null {
  const {exports, scratch} = engineFor(location.area.game);
  const {game, id} = location.area;
  game.act(location.area.actNumber);
  const {ptr, view} = scratch.take(8);
  const found = exports.d2pf_nearest_passable(
    game.world, id, location.x, location.y, radius, ptr, ptr + 4,
  );
  if (found <= 0) return null;
  return new Location(location.area, view.getInt32(0, true), view.getInt32(4, true));
}

function writeOptions(game: Game, options: RouteOptions): number {
  const {exports, scratch} = engineFor(game);
  const {ptr, view} = scratch.take(SIZES.OPTIONS);
  exports.d2pf_options_default(ptr);
  if (options.collisionMask !== undefined) view.setUint16(0, options.collisionMask, true);
  if (options.teleport !== undefined) view.setInt32(4, options.teleport ? 1 : 0, true);
  if (options.teleportAcrossAreas !== undefined) {
    view.setInt32(8, options.teleportAcrossAreas ? 1 : 0, true);
  }
  if (options.maxCastDistance !== undefined) view.setInt32(12, options.maxCastDistance, true);
  if (options.castMetric !== undefined) {
    view.setInt32(16, options.castMetric === 'euclidean' ? 1 : 0, true);
  }
  if (options.snapRadius !== undefined) view.setInt32(20, options.snapRadius, true);
  return ptr;
}

/**
 * A way from one point to another, crossing areas as needed.
 *
 * Null when there is none, which is an answer and not a failure: some pairs genuinely are not
 * connected. Both endpoints must be walkable or within `options.snapRadius` of somewhere that is.
 *
 * Areas are generated on demand, so a route into an act that has not been touched simply generates
 * it — the endpoints are Locations, and a Location already knows its Area.
 */
export function route(from: Location, to: Location, options: RouteOptions = {}): Route | null {
  const game = from.area.game;
  if (to.area.game !== game) {
    throw new RangeError('cannot route between two different games');
  }
  const {exports, scratch} = engineFor(game);
  game.act(from.area.actNumber);
  game.act(to.area.actNumber);

  const handle = exports.d2pf_route(
    game.world,
    from.area.id, from.x, from.y,
    to.area.id, to.x, to.y,
    writeOptions(game, options),
  );
  if (!handle) return null;

  try {
    const legCount = exports.d2pf_route_leg_count(handle);
    const legs: Leg[] = [];
    for (let i = 0; i < legCount; i++) {
      const areaId = exports.d2pf_route_leg_level(handle, i);
      const area = game.area(areaId as never);
      const exitId = exports.d2pf_route_leg_exit(handle, i);

      // Ask with a zero capacity first: the ABI returns the true count either way, so one probe
      // beats guessing a cap and silently losing the tail of a long leg.
      const total = exports.d2pf_route_leg_moves(handle, i, 0, 0);
      const moves: Move[] = [];
      if (total > 0) {
        const {ptr, view} = scratch.take(total * SIZES.MOVE);
        const written = exports.d2pf_route_leg_moves(handle, i, ptr, total);
        for (let m = 0; m < Math.min(written, total); m++) {
          const at = m * SIZES.MOVE;
          moves.push({
            location: new Location(area, view.getInt32(at, true), view.getInt32(at + 4, true)),
            kind: MOVE_KINDS[view.getInt32(at + 8, true)] ?? 'walk',
          });
        }
      }
      legs.push({area, moves, exit: exitId < 0 ? null : game.area(exitId as never)});
    }
    return new Route(from, to, legs);
  } finally {
    exports.d2pf_route_free(handle);
  }
}

/**
 * Which areas a trip crosses, `from` first and `to` last, without pathing inside any of them. Cheap
 * enough to call in a loop. Empty when they are not connected.
 */
export function areasBetween(from: Area, to: Area): readonly Area[] {
  const game = from.game;
  const {exports, scratch} = engineFor(game);
  game.act(from.actNumber);
  game.act(to.actNumber);
  const CAP = 64;
  const {ptr, view} = scratch.take(CAP * 4);
  const written = exports.d2pf_level_route(game.world, from.id, to.id, ptr, CAP);
  const areas: Area[] = [];
  for (let i = 0; i < Math.min(written, CAP); i++) {
    areas.push(game.area(view.getInt32(i * 4, true) as never));
  }
  return areas;
}

/** The exit to take out of `from` heading towards `to`, or null when there is none. */
export function exitFrom(from: Area, towards: Area): Area | null {
  const path = areasBetween(from, towards);
  return path.length >= 2 ? (path[1] ?? null) : null;
}

/**
 * Whether sight runs between two points. False across areas, which is not a question with an
 * answer. `mask` is what blocks sight, defaulting to what the engine uses for a cast.
 */
export function lineOfSight(from: Location, to: Location, mask = Masks.missileFlight): boolean {
  if (from.area.id !== to.area.id) return false;
  const {exports} = engineFor(from.area.game);
  const {game, id} = from.area;
  game.act(from.area.actNumber);
  return exports.d2pf_line_of_sight(game.world, id, from.x, from.y, to.x, to.y, mask) > 0;
}
