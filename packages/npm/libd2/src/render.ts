// Turning a generated world into pixels — the part any renderer needs and nobody wants to write
// twice.
//
// What is here and what is deliberately NOT here is the whole point. This rasterises a collision
// grid and converts between the three coordinate frames. It does not know what colour a wall is,
// where the camera looks, or that monsters are dots: those are decisions about a particular viewer,
// and a library that bakes them in stops being a library. So `paint` is a parameter, the caller
// owns the palette, and nothing in this file imports a canvas or touches a DOM.
//
// It runs anywhere, including plain Node with no browser at all, which is what makes it testable.

import type {Area, CollisionGrid, Location, Point, WalkGrid} from './game.ts';
import {Colbit, Masks, Walk} from './game.ts';

/** An RGBA image, one entry per pixel, laid out the way `ImageData` wants it. */
export interface Raster {
  readonly width: number;
  readonly height: number;
  /** RGBA, four bytes per pixel, row-major from the top-left. */
  readonly pixels: Uint8ClampedArray;
}

/** A colour as `0xRRGGBBAA`. */
export type Rgba = number;

/**
 * What a cell looks like, given its collision flags.
 *
 * The one decision this file refuses to make. It is a function rather than a palette because the
 * interesting maps are the ones that read the flags — line-of-sight blockers shaded differently
 * from walls, doors picked out, void left transparent.
 */
export type Paint = (cell: number) => Rgba;

/**
 * The usual two-tone map: passable under `mask` one colour, everything else another.
 *
 * Cells outside the level get `outside`, transparent by default, so a level's silhouette is its
 * real shape rather than a rectangle. "Outside" is the engine's own `blank` bit — its marker for
 * "no floor tile here" — and not a guess about which value means nothing.
 */
export function twoTone(
  passable: Rgba,
  blocked: Rgba,
  {mask = Masks.playerPath, outside = 0x00000000 as Rgba}: {mask?: number; outside?: Rgba} = {},
): Paint {
  return (cell) => {
    if (cell === 0xffff || (cell & Colbit.blank) !== 0) return outside;
    return (cell & mask) === 0 ? passable : blocked;
  };
}

/**
 * Rasterise a collision grid, one pixel per subtile.
 *
 * One pixel per subtile and no scaling: a viewer that wants it bigger scales when it draws, which
 * is free on a canvas and lossless if it wants nearest-neighbour. Producing a pre-scaled buffer
 * here would be a decision about how it gets displayed.
 */
export function rasterize(grid: CollisionGrid, paint: Paint): Raster {
  const {width, height} = grid;
  const pixels = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const colour = paint(grid.cells[y * width + x] ?? 0xffff);
      const at = (y * width + x) * 4;
      pixels[at] = (colour >>> 24) & 0xff;
      pixels[at + 1] = (colour >>> 16) & 0xff;
      pixels[at + 2] = (colour >>> 8) & 0xff;
      pixels[at + 3] = colour & 0xff;
    }
  }
  return {width, height, pixels};
}

/**
 * The three frames, and how to get between them.
 *
 * There are three, they are easy to confuse, and confusing them is not a subtle bug — it puts you
 * thousands of cells outside the level:
 *
 *   world subtiles   what the server states every position in
 *   local subtiles   what an area's own map data uses, and what a Raster is indexed by
 *   pixels           where it lands on screen, after scale and pan
 *
 * A View owns the last hop. `Area.fromWorld` and `Location.world` own the first, and this defers to
 * them rather than repeating the arithmetic.
 */
export class View {
  readonly area: Area;
  /** Pixels per subtile. */
  readonly scale: number;
  /** Where the top-left of the image sits on screen, in pixels. */
  readonly panX: number;
  readonly panY: number;

  constructor(area: Area, {scale = 2, panX = 0, panY = 0} = {}) {
    this.area = area;
    this.scale = scale;
    this.panX = panX;
    this.panY = panY;
  }

  get width(): number {
    return this.area.collision.width * this.scale;
  }

  get height(): number {
    return this.area.collision.height * this.scale;
  }

  /** A point in the area, to a pixel. Takes either frame: a Location, or world subtiles. */
  toScreen(at: Location | Point, frame: 'local' | 'world' = 'local'): Point {
    const local = frame === 'world' ? this.area.fromWorld(at.x, at.y) : at;
    return {x: local.x * this.scale + this.panX, y: local.y * this.scale + this.panY};
  }

  /** A pixel back to a Location in this area. */
  toLocation(pixel: Point): Location {
    return this.area.at(
      Math.floor((pixel.x - this.panX) / this.scale),
      Math.floor((pixel.y - this.panY) / this.scale),
    );
  }

  /** A View of the same area panned so `at` sits in the middle of a `width` x `height` viewport. */
  centredOn(at: Location, width: number, height: number): View {
    return new View(this.area, {
      scale: this.scale,
      panX: Math.round(width / 2 - at.x * this.scale),
      panY: Math.round(height / 2 - at.y * this.scale),
    });
  }

  /** Whether a screen pixel falls inside the rasterised area at all. */
  contains(pixel: Point): boolean {
    const local = this.toLocation(pixel);
    return local.x >= 0 && local.y >= 0 &&
      local.x < this.area.collision.width && local.y < this.area.collision.height;
  }
}

// ── the map the game draws ─────────────────────────────────────────────────────────────────────
//
// Everything above is a top-down bitmap, which is useful and is not what the game shows you. The
// automap is isometric line art: walls traced where open ground meets solid, projected through the
// engine's own minimap transform.
//
// The geometry is built in SUBTILE space and handed back as plain numbers. That is deliberate — a
// caller projects it with a canvas transform, so panning and zooming never rebuild anything, and a
// route drawn through the same transform lands on the corridor it walks down by construction.
// Nothing here builds a Path2D, because Path2D is a browser type and this has to run in Node.

/**
 * The engine's own minimap projection: `sx = (x - y)·k`, `sy = (x + y)·k/2`.
 *
 * `Transform.cpp`'s `CoordsMiniMapToScreen`. It is linear, so it is exactly a 2x3 canvas matrix and
 * inverts exactly — a click maps back to a subtile with no search.
 */
export class Minimap {
  /** Screen pixels per subtile along the diamond's long axis. */
  readonly k: number;
  readonly ox: number;
  readonly oy: number;

  constructor({k = 2, ox = 0, oy = 0} = {}) {
    this.k = k;
    this.ox = ox;
    this.oy = oy;
  }

  project(x: number, y: number): Point {
    return {x: (x - y) * this.k + this.ox, y: (x + y) * (this.k / 2) + this.oy};
  }

  /** Screen pixels back to subtiles. Exact: the transform is a rotation and a scale. */
  unproject(sx: number, sy: number): Point {
    const u = (sx - this.ox) / this.k;
    const w = (sy - this.oy) / (this.k / 2);
    return {x: (u + w) / 2, y: (w - u) / 2};
  }

  /** As a canvas transform, for `ctx.setTransform(...)`. */
  get matrix(): [number, number, number, number, number, number] {
    return [this.k, this.k / 2, -this.k, this.k / 2, this.ox, this.oy];
  }

  /** A projection that fits a subtile box into a canvas. */
  static fit(
    canvasWidth: number, canvasHeight: number,
    x0: number, y0: number, x1: number, y1: number,
    padding = 16,
  ): Minimap {
    const span = Math.max(1, x1 - x0) + Math.max(1, y1 - y0);
    const k = Math.max(1e-4, Math.min(
      (canvasWidth - padding * 2) / span,
      (canvasHeight - padding * 2) / (span / 2),
    ));
    const centred = new Minimap({k});
    const middle = centred.project((x0 + x1) / 2, (y0 + y1) / 2);
    return new Minimap({k, ox: canvasWidth / 2 - middle.x, oy: canvasHeight / 2 - middle.y});
  }

  /** A projection of the same scale, panned so `at` sits in the middle of a viewport. */
  centredOn(at: Point, width: number, height: number): Minimap {
    const centred = new Minimap({k: this.k});
    const p = centred.project(at.x, at.y);
    return new Minimap({k: this.k, ox: width / 2 - p.x, oy: height / 2 - p.y});
  }
}

/**
 * Above this many boundary edges, wall LINES stop being the right drawing.
 *
 * A dense Act 5 Hell maze is mostly blocked with scattered open pockets, which is hundreds of
 * thousands of one-cell segments — enough to freeze a main thread stroking them. Past the cap the
 * caller should fill {@link floorRuns} instead, which is always O(w·h) and never O(segments).
 */
export const EDGE_CAP = 120_000;

/**
 * Wall lines in subtile space, as flat `[x0, y0, x1, y1, …]`.
 *
 * A line is drawn only where OPEN meets real BLOCKED, never where open meets VOID. Void is "no room
 * covers this subtile", so outlining it would trace the room-union silhouette and every gap between
 * rooms as walls the game does not have.
 *
 * Collinear edges merge into one segment, which is what keeps a 400x400 level to a few thousand
 * lines rather than 160,000. Null when the level is too fragmented to draw this way.
 */
export function wallSegments(grid: WalkGrid): Float32Array | null {
  if (grid.width <= 0 || grid.height <= 0) return null;
  const out: number[] = [];

  const isEdge = (ax: number, ay: number, bx: number, by: number): boolean => {
    const a = grid.at(ax, ay);
    const b = grid.at(bx, by);
    return (a === Walk.open && b === Walk.blocked) || (b === Walk.open && a === Walk.blocked);
  };

  for (let vx = 0; vx <= grid.width; vx++) {
    let run = -1;
    for (let y = 0; y <= grid.height; y++) {
      const edge = y < grid.height && isEdge(vx - 1, y, vx, y);
      if (edge && run < 0) run = y;
      else if (!edge && run >= 0) {
        out.push(vx, run, vx, y);
        run = -1;
      }
    }
    if (out.length / 4 > EDGE_CAP) return null;
  }
  for (let vy = 0; vy <= grid.height; vy++) {
    let run = -1;
    for (let x = 0; x <= grid.width; x++) {
      const edge = x < grid.width && isEdge(x, vy - 1, x, vy);
      if (edge && run < 0) run = x;
      else if (!edge && run >= 0) {
        out.push(run, vy, x, vy);
        run = -1;
      }
    }
    if (out.length / 4 > EDGE_CAP) return null;
  }
  return new Float32Array(out);
}

/**
 * The walkable interior as rectangles, flat `[x, y, width, 1, …]` — the backdrop the wall lines sit
 * on. Horizontal runs of open cells merge, and the projection draws each as a parallelogram.
 */
export function floorRuns(grid: WalkGrid): Float32Array {
  const out: number[] = [];
  for (let y = 0; y < grid.height; y++) {
    let run = -1;
    for (let x = 0; x <= grid.width; x++) {
      const open = x < grid.width && grid.isOpen(x, y);
      if (open && run < 0) run = x;
      else if (!open && run >= 0) {
        out.push(run, y, x - run, 1);
        run = -1;
      }
    }
  }
  return new Float32Array(out);
}

/** The subtile bounding box of everything walkable, for fitting a view to the level's real extent. */
export function walkableBounds(grid: WalkGrid): {x0: number; y0: number; x1: number; y1: number} {
  let x0 = grid.width;
  let y0 = grid.height;
  let x1 = 0;
  let y1 = 0;
  for (let y = 0; y < grid.height; y++) {
    for (let x = 0; x < grid.width; x++) {
      if (!grid.isOpen(x, y)) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  return x1 < x0 ? {x0: 0, y0: 0, x1: grid.width, y1: grid.height} : {x0, y0, x1, y1};
}
