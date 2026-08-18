// The ways out of a level, and what kind of thing each one is.
//
// Two shapes, and telling them apart is the whole file. Levels that ABUT share a border you walk
// over; a level that shares no edge is somewhere else in the coordinate space and is reached
// through a warp the server has to place. A run that treats both the same either clicks at empty
// ground or walks into a wall.

import {SUBTILE, type Point} from './point.ts';
import type {Area} from './area.ts';
import type {Location} from './location.ts';

/** A way out of an area, carrying where it leads. */
/**
 * A way out of one area and into another.
 *
 * Rarely a door. Between two outdoor levels the crossing is a SEAM: a run of cells along a shared
 * border, any of which gets you across. The generator names one point per room that touches that
 * border, so a single seam arrives as a handful of collinear points one room apart — treating each
 * of those as a separate exit turns one way out of the Blood Moor into seven, and a route that
 * picks between them is choosing between spellings of the same thing.
 */
/**
 * The line two levels meet along, in world subtiles.
 *
 * `axis: 'x'` is a vertical line: every point on it has `x === at`, and `y` runs from `from` to
 * `to`. `step` says which way to walk to end up in the other level.
 */
export interface Border {
  readonly axis: 'x' | 'y';
  readonly at: number;
  readonly from: number;
  readonly to: number;
  readonly step: 1 | -1;
}

/** One world point either side of a border: the last cell that is ours, the first that is not. */
export interface Crossing {
  readonly inside: Point;
  readonly outside: Point;
}

export interface Exit {
  readonly from: Area;
  readonly to: Area;
  /** The middle of the crossing — a point on it, and the one furthest from either end. */
  readonly location: Location | null;
  /** Every cell the generator named for this crossing, in the order it named them. */
  readonly points: readonly Location[];
  /** The point on this crossing closest to `from`, measured in world subtiles. */
  nearestTo(from: Point): Location | null;
  /**
   * The line the two levels meet along, when they abut.
   *
   * Null when they do not — a cave or a tomb is somewhere else entirely and is reached through a
   * placed warp, which is a unit the server has to describe before it can be used. Two outdoor
   * levels share an edge instead, and crossing it is just walking.
   */
  readonly border: Border | null;
  /**
   * Where to walk to get across, nearest to `at`.
   *
   * `inside` is `margin` subtiles back on our side — far enough that a route to it is a route
   * within this level rather than onto the boundary strip, which belongs to neither. `outside` is
   * the same distance into the level beyond, which is where you point the last command.
   */
  crossingNear(at: Point, margin?: number): Crossing | null;
}

/**
 * How far apart two named points can be and still be the same crossing.
 *
 * The generator names one point per room along a shared border, so consecutive points on a seam
 * sit exactly one room — 8 tiles, 40 subtiles — apart. Two rooms of slack tolerates a border room
 * that contributed nothing without merging anything real: two genuinely separate crossings into
 * the same level are on different sides of it, hundreds of subtiles away. Splitting one seam in
 * half would be the worse mistake, because it puts a phantom second exit into the area graph.
 */
const SEAM_GAP = 80;

/** Partition crossing points into the seams they lie on. */
export function seams(points: readonly Location[]): Location[][] {
  const groups: Location[][] = [];
  for (const point of points) {
    const joined = groups.find((group) =>
      group.some((p) => Math.max(Math.abs(p.x - point.x), Math.abs(p.y - point.y)) <= SEAM_GAP));
    if (joined) joined.push(point);
    else groups.push([point]);
  }
  // Two points can each be near a different group and near each other, which leaves one seam in
  // two groups. Fold groups together until nothing else touches.
  for (let i = 0; i < groups.length; i++) {
    for (let j = i + 1; j < groups.length; ) {
      const touching = groups[i]!.some((a) =>
        groups[j]!.some((b) => Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y)) <= SEAM_GAP));
      if (touching) groups[i]!.push(...groups.splice(j, 1)[0]!);
      else j++;
    }
  }
  return groups;
}

function clamp(v: number, low: number, high: number): number {
  return v < low ? low : v > high ? high : v;
}

/**
 * The line two level rectangles share, or null if they do not touch.
 *
 * Levels of an act are placed in one coordinate space and laid out without gaps, so two connected
 * outdoor levels meet exactly: one's right edge IS the other's left edge. An interior — a cave, a
 * tomb, the Den of Evil — is generated somewhere else in that space and shares no edge at all,
 * which is precisely the difference between a crossing you walk over and a warp you click.
 */
function borderBetween(from: Area, to: Area): Border | null {
  const a = from.worldBox;
  const b = to.worldBox;
  const overlapY = {from: Math.max(a.y0, b.y0), to: Math.min(a.y1, b.y1)};
  const overlapX = {from: Math.max(a.x0, b.x0), to: Math.min(a.x1, b.x1)};
  if (overlapY.to > overlapY.from) {
    if (a.x1 === b.x0) return {axis: 'x', at: a.x1, ...overlapY, step: 1};
    if (a.x0 === b.x1) return {axis: 'x', at: a.x0, ...overlapY, step: -1};
  }
  if (overlapX.to > overlapX.from) {
    if (a.y1 === b.y0) return {axis: 'y', at: a.y1, ...overlapX, step: 1};
    if (a.y0 === b.y1) return {axis: 'y', at: a.y0, ...overlapX, step: -1};
  }
  return null;
}

export function makeExit(from: Area, to: Area, points: readonly Location[]): Exit {
  const border = borderBetween(from, to);
  return {
    from,
    to,
    points,
    border,
    // A margin of 12 put `inside` within the boundary strip on levels whose walkable ground
    // reaches the very edge — which is most of them — and routing to a cell in that strip is
    // exactly what does not work: it belongs to the crossing rather than the level, so the router
    // treats it as its own island. Far enough in to be ordinary ground, close enough that the
    // step across is still one command.
    crossingNear(at: Point, margin = 26): Crossing | null {
      if (!border) return null;
      const {axis, step} = border;
      // Along the shared edge, stay level with where we are — but inside the part the two levels
      // actually share, since the overlap is usually shorter than either level's side.
      const along = clamp(axis === 'x' ? at.y : at.x, border.from, border.to - 1);
      const inside = border.at - step * margin;
      const outside = border.at + step * margin;
      return axis === 'x'
        ? {inside: {x: inside, y: along}, outside: {x: outside, y: along}}
        : {inside: {x: along, y: inside}, outside: {x: along, y: outside}};
    },
    // The middle by position, not by index: the points arrive in room order, which is not the
    // order they lie along the border.
    location: points.length === 0 ? null : middleOf(points),
    nearestTo(at: Point): Location | null {
      let best: Location | null = null;
      let bestAway = Infinity;
      const origin = from.origin;
      for (const p of points) {
        const away = Math.hypot(origin.x * SUBTILE + p.x - at.x, origin.y * SUBTILE + p.y - at.y);
        if (away < bestAway) {
          bestAway = away;
          best = p;
        }
      }
      return best;
    },
  };
}

/** The point of a seam furthest from either of its ends. */
function middleOf(points: readonly Location[]): Location {
  const cx = points.reduce((sum, p) => sum + p.x, 0) / points.length;
  const cy = points.reduce((sum, p) => sum + p.y, 0) / points.length;
  let best = points[0]!;
  let bestAway = Infinity;
  for (const p of points) {
    const away = Math.hypot(p.x - cx, p.y - cy);
    if (away < bestAway) {
      bestAway = away;
      best = p;
    }
  }
  return best;
}
