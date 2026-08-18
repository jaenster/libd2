// A point that knows which level it is in.
//
// Which is what makes the three coordinate frames safe to move between. A bare {x, y} is ambiguous
// — level-local subtiles, world subtiles and tiles all look like a pair of numbers, and mixing two
// of them puts you thousands of cells from where you meant with no error anywhere.

import {SUBTILE, type Point} from './point.ts';
import type {Area} from './area.ts';

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
