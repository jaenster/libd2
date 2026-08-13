// What a route is.
//
// A path is not a list of points. It is a sequence of LEGS, one per area it passes through, because
// crossing from one level to the next is a different act from walking within one — the server has
// to describe the far side before you are there. Keeping the legs apart is what stops a caller
// treating a level transition as one more step.

import type {Area} from './drlg/area.ts';
import type {Location} from './drlg/location.ts';
import type {MoveKind} from './wasm.ts';

export type {MoveKind};

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
