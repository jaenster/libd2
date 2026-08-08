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

import type {Area, CollisionGrid, Location, Point} from './game.ts';
import {Colbit, Masks} from './game.ts';

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
