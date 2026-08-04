// The isometric automap raster, ported from the d2-drlg web viewer's AutomapView.
//
// The map is traced from the SAME walk grid the router searches (the level's CollMap under the same mask), so a wall you
// see is a wall the path had to go around — there is no second source of truth. A line is drawn only
// where OPEN meets real BLOCKED terrain, never where open meets VOID: void is "no room covers this
// subtile", and outlining it would draw the room-union silhouette and every inter-room gap as
// spurious geometry.
//
// Everything here is built in SUBTILE space and projected by the canvas transform, so panning and
// zooming never rebuild geometry — and a route drawn through the same transform lands on the
// corridor it walks down by construction. The projection is the engine's own minimap transform
// (Transform.cpp CoordsMiniMapToScreen): sx = (x - y)·k, sy = (x + y)·k/2.

import { BLOCKED, VOID } from "./libd2";

export interface View {
  /** Screen px per subtile along the diamond's long axis. */
  k: number;
  ox: number;
  oy: number;
}

/** The view as a canvas transform. Isometric projection is linear, so it is exactly a 2×3 matrix. */
export function matrix(v: View): [number, number, number, number, number, number] {
  return [v.k, v.k / 2, -v.k, v.k / 2, v.ox, v.oy];
}

export function project(v: View, x: number, y: number): [number, number] {
  return [(x - y) * v.k + v.ox, (x + y) * (v.k / 2) + v.oy];
}

/** Screen px back to subtiles. Exact — the transform is a rotation plus a scale. */
export function unproject(v: View, sx: number, sy: number): [number, number] {
  const u = (sx - v.ox) / v.k;
  const w = (sy - v.oy) / (v.k / 2);
  return [(u + w) / 2, (w - u) / 2];
}

/** A view that fits the subtile box [x0,x1]×[y0,y1] into a `cw`×`ch` canvas. */
export function fitView(
  cw: number, ch: number,
  x0: number, y0: number, x1: number, y1: number,
  pad = 16,
): View {
  const w = Math.max(1, x1 - x0), h = Math.max(1, y1 - y0);
  const span = w + h;
  const k = Math.max(1e-4, Math.min((cw - pad * 2) / span, (ch - pad * 2) / (span / 2)));
  // Centre the diamond, then shift so the box's own origin — not (0,0) — is what got fitted.
  const v: View = { k, ox: 0, oy: 0 };
  const [cx, cy] = project(v, (x0 + x1) / 2, (y0 + y1) / 2);
  return { k, ox: cw / 2 - cx, oy: ch / 2 - cy };
}

/**
 * Above this many open↔blocked boundary edges the wall-LINE automap degenerates: a dense Act 5 Hell
 * maze is 85% blocked with scattered open pockets, which is hundreds of thousands of one-cell
 * segments whose Path2D stroke freezes the main thread. Past the cap we fill cells instead — always
 * O(w·h), never O(segments).
 */
const EDGE_CAP = 120_000;

export interface Grid { w: number; h: number; cells: Uint8Array }

function isWallEdge(g: Grid, ax: number, ay: number, bx: number, by: number): boolean {
  const at = (x: number, y: number) => (x >= 0 && y >= 0 && x < g.w && y < g.h ? g.cells[y * g.w + x] : VOID);
  const a = at(ax, ay), b = at(bx, by);
  return (a === 1 && b === BLOCKED) || (b === 1 && a === BLOCKED);
}

/** Wall lines in subtile space. Collinear edges merge into one segment, which is what keeps a
 *  400×400 level to a few thousand lines instead of 160k. Null when too fragmented to draw as
 *  lines — fall back to `buildFloorPath` alone, which is always bounded. */
export function buildWallPath(g: Grid): Path2D | null {
  if (!g.cells.length || g.w <= 0 || g.h <= 0) return null;

  const p = new Path2D();
  let edges = 0;
  for (let vx = 0; vx <= g.w; vx++) {
    let run = -1;
    for (let y = 0; y <= g.h; y++) {
      const edge = y < g.h && isWallEdge(g, vx - 1, y, vx, y);
      if (edge && run < 0) run = y;
      else if (!edge && run >= 0) { p.moveTo(vx, run); p.lineTo(vx, y); run = -1; edges++; }
    }
    if (edges > EDGE_CAP) return null;
  }
  for (let vy = 0; vy <= g.h; vy++) {
    let run = -1;
    for (let x = 0; x <= g.w; x++) {
      const edge = x < g.w && isWallEdge(g, x, vy - 1, x, vy);
      if (edge && run < 0) run = x;
      else if (!edge && run >= 0) { p.moveTo(run, vy); p.lineTo(x, vy); run = -1; edges++; }
    }
    if (edges > EDGE_CAP) return null;
  }
  return p;
}

/** The walkable interior as filled cells — the backdrop the wall lines sit on. Horizontal runs of
 *  open cells merge into one rectangle, which the iso transform draws as a parallelogram. */
export function buildFloorPath(g: Grid): Path2D {
  const p = new Path2D();
  for (let y = 0; y < g.h; y++) {
    let run = -1;
    for (let x = 0; x <= g.w; x++) {
      const open = x < g.w && g.cells[y * g.w + x] === 1;
      if (open && run < 0) run = x;
      else if (!open && run >= 0) { p.rect(run, y, x - run, 1); run = -1; }
    }
  }
  return p;
}
