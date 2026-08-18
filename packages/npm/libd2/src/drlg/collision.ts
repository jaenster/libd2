// What the map says about standing somewhere.
//
// Two grids over the same cells. Collision is the engine's own u16 per subtile, which is the truth
// and is awkward to draw. The walk grid is the question a router and a renderer actually ask —
// void, open or blocked — and the distinction between the first two matters: a wall line drawn
// where open meets VOID traces the edge of the data rather than the edge of the world.

import {Masks} from './collision.flags.ts';

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

/** What a walk-grid cell is. */
export const Walk = {
  /** No room covers this subtile. Outside the level, not a wall. */
  void: 0,
  open: 1,
  blocked: 2,
} as const;

/**
 * A level's walk grid: one byte per subtile, each {@link Walk}.
 *
 * The distinction that matters is between BLOCKED and VOID. Void is "no room covers this subtile",
 * so outlining it draws the room-union silhouette and every inter-room gap as spurious walls — a
 * map full of geometry the game does not have.
 */
export class WalkGrid {
  readonly width: number;
  readonly height: number;
  readonly cells: Uint8Array;

  constructor(width: number, height: number, cells: Uint8Array) {
    this.width = width;
    this.height = height;
    this.cells = cells;
  }

  /** The cell at a point. Outside the grid reads as void. */
  at(x: number, y: number): number {
    if (x < 0 || y < 0 || x >= this.width || y >= this.height) return Walk.void;
    return this.cells[y * this.width + x] ?? Walk.void;
  }

  isOpen(x: number, y: number): boolean {
    return this.at(x, y) === Walk.open;
  }
}
