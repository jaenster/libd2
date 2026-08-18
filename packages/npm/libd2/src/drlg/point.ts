// The two shapes every other measurement is made of, and the ratio between the frames.

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
export const SUBTILE = 5;
