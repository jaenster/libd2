import { useCallback, useEffect, useMemo, useRef } from "react";
import { buildFloorPath, buildWallPath, fitView, matrix, project, unproject, type Grid, type View } from "./automap";

/** One level's automap geometry, placed at a WORLD subtile offset. The level view passes one at
 *  (0,0); the act view passes every level of the act at its own origin, which is what makes the
 *  whole act one continuous map. */
export interface Layer {
  levelId: number;
  grid: Grid;
  ox: number;
  oy: number;
  color: string;
  dim?: boolean;
}

/** A route (or any polyline) in the same world subtile space as the layers. */
export interface Line {
  pts: [number, number][];
  color: string;
  width?: number;
  dashed?: boolean;
  alpha?: number;
}

export interface Marker {
  x: number;
  y: number;
  color: string;
  label?: string;
  /** Drawn as a ring rather than a filled dot — used for exits, which are approximate. */
  hollow?: boolean;
}

interface Props {
  layers: Layer[];
  lines?: Line[];
  markers?: Marker[];
  /** Called with WORLD subtile coords. */
  onPick?: (x: number, y: number) => void;
  /** Refit whenever this changes — it is the identity of what is being shown. */
  fitKey: string;
}

/**
 * Pan/zoom canvas over the isometric automap. Geometry is cached per layer in subtile space and
 * projected by the canvas transform, so a pan is a repaint and never a rebuild.
 */
export default function MapCanvas({ layers, lines = [], markers = [], onPick, fitKey }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const viewRef = useRef<View | null>(null);
  const dragRef = useRef<{ x: number; y: number; ox: number; oy: number; moved: boolean } | null>(null);

  // Wall/floor geometry is expensive to trace and independent of the view, so it is built once per
  // set of layers and reused across every pan, zoom and route change.
  const paths = useMemo(
    () => layers.map((l) => ({ layer: l, wall: buildWallPath(l.grid), floor: buildFloorPath(l.grid) })),
    [layers],
  );

  const bounds = useMemo(() => {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const l of layers) {
      x0 = Math.min(x0, l.ox); y0 = Math.min(y0, l.oy);
      x1 = Math.max(x1, l.ox + l.grid.w); y1 = Math.max(y1, l.oy + l.grid.h);
    }
    return isFinite(x0) ? { x0, y0, x1, y1 } : null;
  }, [layers]);

  const draw = useCallback(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;
    const dpr = window.devicePixelRatio || 1;
    const cw = canvas.clientWidth, ch = canvas.clientHeight;
    if (canvas.width !== Math.round(cw * dpr) || canvas.height !== Math.round(ch * dpr)) {
      canvas.width = Math.round(cw * dpr);
      canvas.height = Math.round(ch * dpr);
      viewRef.current = null;
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = "#0b0d12";
    ctx.fillRect(0, 0, cw, ch);
    if (!bounds) return;
    if (!viewRef.current) viewRef.current = fitView(cw, ch, bounds.x0, bounds.y0, bounds.x1, bounds.y1);
    const view = viewRef.current;

    const withLayer = (l: Layer, fn: () => void) => {
      const m = matrix({ k: view.k, ox: view.ox, oy: view.oy });
      ctx.save();
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.transform(m[0], m[1], m[2], m[3], m[4], m[5]);
      ctx.translate(l.ox, l.oy);
      fn();
      ctx.restore();
    };

    // A stroke under the iso transform is anisotropic (the matrix scales the two diagonals
    // differently); 1.3/k lands close to one device pixel in both directions.
    const hair = 1.3 / view.k;

    for (const { layer, wall, floor } of paths) {
      withLayer(layer, () => {
        ctx.globalAlpha = layer.dim ? 0.7 : 0.9;
        ctx.fillStyle = layer.dim ? "#1a212c" : "#232b38";
        ctx.fill(floor);
        if (wall) {
          ctx.globalAlpha = layer.dim ? 0.55 : 1;
          ctx.strokeStyle = layer.color;
          ctx.lineWidth = hair;
          ctx.lineJoin = "round";
          ctx.lineCap = "round";
          ctx.stroke(wall);
        } else {
          // Too fragmented for lines: outline the walkable area instead so the level still reads.
          ctx.globalAlpha = layer.dim ? 0.4 : 0.6;
          ctx.strokeStyle = layer.color;
          ctx.lineWidth = hair;
          ctx.stroke(floor);
        }
      });
    }

    // Routes and markers are drawn in screen space so their stroke width is honest and dashes are
    // not sheared by the projection.
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.globalAlpha = 1;
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    for (const line of lines) {
      if (line.pts.length < 2) continue;
      ctx.globalAlpha = line.alpha ?? 1;
      ctx.strokeStyle = line.color;
      ctx.lineWidth = line.width ?? 2;
      ctx.setLineDash(line.dashed ? [6, 5] : []);
      ctx.beginPath();
      line.pts.forEach(([x, y], i) => {
        const [sx, sy] = project(view, x, y);
        if (i === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy);
      });
      ctx.stroke();
    }
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;

    for (const m of markers) {
      const [sx, sy] = project(view, m.x, m.y);
      ctx.beginPath();
      ctx.arc(sx, sy, m.hollow ? 4 : 5, 0, Math.PI * 2);
      if (m.hollow) {
        ctx.strokeStyle = m.color;
        ctx.lineWidth = 2;
        ctx.stroke();
      } else {
        ctx.fillStyle = m.color;
        ctx.fill();
        ctx.strokeStyle = "#0b0d12";
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }
      if (m.label) {
        ctx.font = "11px ui-monospace, SFMono-Regular, Menlo, monospace";
        ctx.fillStyle = m.color;
        ctx.fillText(m.label, sx + 8, sy - 6);
      }
    }
  }, [paths, bounds, lines, markers]);

  useEffect(() => { viewRef.current = null; draw(); }, [fitKey]);
  useEffect(() => { draw(); }, [draw]);
  useEffect(() => {
    const onResize = () => { viewRef.current = null; draw(); };
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, [draw]);

  const onWheel = (e: React.WheelEvent) => {
    const view = viewRef.current;
    if (!view) return;
    const rect = canvasRef.current!.getBoundingClientRect();
    const mx = e.clientX - rect.left, my = e.clientY - rect.top;
    const ns = view.k * Math.exp(-e.deltaY * 0.0015);
    view.ox = mx - (mx - view.ox) * (ns / view.k);
    view.oy = my - (my - view.oy) * (ns / view.k);
    view.k = ns;
    draw();
  };

  const onDown = (e: React.MouseEvent) => {
    const view = viewRef.current;
    if (!view) return;
    dragRef.current = { x: e.clientX, y: e.clientY, ox: view.ox, oy: view.oy, moved: false };
  };
  const onMove = (e: React.MouseEvent) => {
    const d = dragRef.current, view = viewRef.current;
    if (!d || !view) return;
    if (Math.abs(e.clientX - d.x) + Math.abs(e.clientY - d.y) > 3) d.moved = true;
    view.ox = d.ox + (e.clientX - d.x);
    view.oy = d.oy + (e.clientY - d.y);
    draw();
  };
  const onUp = (e: React.MouseEvent) => {
    const d = dragRef.current;
    dragRef.current = null;
    // A drag pans; a click without movement picks. Same button, no modifier to remember.
    if (!d || d.moved || !onPick || !viewRef.current) return;
    const rect = canvasRef.current!.getBoundingClientRect();
    const [x, y] = unproject(viewRef.current, e.clientX - rect.left, e.clientY - rect.top);
    onPick(Math.round(x), Math.round(y));
  };

  return (
    <canvas
      ref={canvasRef}
      className="map"
      onWheel={onWheel}
      onMouseDown={onDown}
      onMouseMove={onMove}
      onMouseUp={onUp}
      onMouseLeave={() => { dragRef.current = null; }}
    />
  );
}
