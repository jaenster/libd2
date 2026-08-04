import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import MapCanvas, { type Layer, type Line, type Marker } from "./MapCanvas";
import {
  EXIT_KIND_NAME, MOVE_PAD, MOVE_TELEPORT, PORTAL, SUBTILES_PER_TILE, World,
  levelColor, type LevelInfo, type Move, type RouteResult,
} from "./libd2";
import type { Grid } from "./automap";

const ACTS = ["Act I", "Act II", "Act III", "Act IV", "Act V"];
const DIFFICULTIES = ["Normal", "Nightmare", "Hell"];
const MASKS = ["player", "monster", "missile"] as const;
type MaskKind = (typeof MASKS)[number];

/** The level each act starts you in — where the "route everywhere" sweep is measured from. */
const TOWN_OF_ACT = [1, 40, 75, 103, 109];

type Mode = "level" | "act";
interface Pick { level: number; x: number; y: number; }

export default function App() {
  const [seedText, setSeedText] = useState("0x13572468");
  const [difficulty, setDifficulty] = useState(0);
  const [act, setAct] = useState(0);
  const [maskKind, setMaskKind] = useState<MaskKind>("player");
  const [teleport, setTeleport] = useState(false);

  const [world, setWorld] = useState<World | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [mode, setMode] = useState<Mode>("level");
  const [levelId, setLevelId] = useState(1);
  const [from, setFrom] = useState<Pick | null>(null);
  const [to, setTo] = useState<Pick | null>(null);
  const [route, setRoute] = useState<RouteResult | null>(null);
  const [routeNote, setRouteNote] = useState<string>("");
  const [bulk, setBulk] = useState<{ label: string; routes: RouteResult[]; failed: number } | null>(null);

  const worldRef = useRef<World | null>(null);

  const mask = useMemo(() => {
    if (!world) return undefined;
    return maskKind === "monster" ? world.maskMonster()
      : maskKind === "missile" ? world.maskMissile()
        : world.maskPlayer();
  }, [world, maskKind]);

  // Generating is seconds of synchronous wasm, so the "Generating…" banner has to reach the screen
  // before the call starts — hence the frame yield rather than a bare await.
  const generate = useCallback(async () => {
    const seed = Number(seedText.trim().startsWith("0x") ? seedText.trim() : `0x${seedText.trim()}`);
    if (!Number.isFinite(seed)) { setError(`"${seedText}" is not a seed`); return; }
    setError(null);
    setBusy(`Generating ${ACTS[act]} at seed 0x${(seed >>> 0).toString(16)}…`);
    setRoute(null); setBulk(null); setFrom(null); setTo(null);
    await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));
    try {
      worldRef.current?.destroy();
      worldRef.current = null;
      setWorld(null);
      const w = await World.create(seed >>> 0, difficulty);
      w.loadAct(act);
      worldRef.current = w;
      setWorld(w);
      const ids = w.levelIds();
      setLevelId(ids.includes(TOWN_OF_ACT[act]) ? TOWN_OF_ACT[act] : (ids[0] ?? 1));
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(null);
    }
  }, [seedText, difficulty, act]);

  useEffect(() => { void generate(); /* first paint has a map */ }, []);
  useEffect(() => () => worldRef.current?.destroy(), []);

  const levels: LevelInfo[] = useMemo(() => {
    if (!world) return [];
    return world.levelIds().map((id) => world.levelInfo(id)).filter((l): l is LevelInfo => !!l);
  }, [world]);

  const current = levels.find((l) => l.id === levelId) ?? null;

  // ── Geometry ────────────────────────────────────────────────────────────────
  const gridCache = useRef(new Map<string, Grid | null>());
  const compCache = useRef(new Map<number, { labels: Int32Array; main: number } | null>());
  useEffect(() => { gridCache.current.clear(); compCache.current.clear(); }, [world, mask]);

  const gridOf = useCallback((id: number): Grid | null => {
    if (!world || mask === undefined) return null;
    const key = `${id}:${mask}`;
    if (!gridCache.current.has(key)) gridCache.current.set(key, world.walkGrid(id, mask));
    return gridCache.current.get(key) ?? null;
  }, [world, mask]);

  const layers: Layer[] = useMemo(() => {
    if (!world) return [];
    if (mode === "level") {
      const g = gridOf(levelId);
      return g ? [{ levelId, grid: g, ox: 0, oy: 0, color: "#e8b04b" }] : [];
    }
    const out: Layer[] = [];
    for (const l of levels) {
      const g = gridOf(l.id);
      if (!g) continue;
      out.push({
        levelId: l.id,
        grid: g,
        ox: l.originX * SUBTILES_PER_TILE,
        oy: l.originY * SUBTILES_PER_TILE,
        color: levelColor(l.id),
        dim: l.id !== levelId,
      });
    }
    return out;
  }, [world, mode, levels, levelId, gridOf]);

  /**
   * 8-connected components of a level's walkable cells, and which of them is the biggest.
   *
   * A level is not one connected blob: the Arcane Sanctuary's four arms sit around sixteen isolated
   * pockets, and every outdoor level has ledges you can see but not stand on. Snapping a click to
   * the merely NEAREST ground therefore lands in unreachable geometry often enough to make routing
   * look broken, so picks are steered into a component instead — the main one for A, A's own for B.
   */
  const componentsOf = useCallback((id: number): { labels: Int32Array; main: number } | null => {
    const hit = compCache.current.get(id);
    if (hit !== undefined) return hit;
    const g = gridOf(id);
    if (!g) { compCache.current.set(id, null); return null; }
    const labels = new Int32Array(g.w * g.h).fill(-1);
    const sizes: number[] = [];
    const stack: number[] = [];
    for (let s = 0; s < labels.length; s++) {
      if (g.cells[s] !== 1 || labels[s] >= 0) continue;
      const id2 = sizes.length;
      let n = 0;
      stack.length = 0;
      stack.push(s);
      labels[s] = id2;
      while (stack.length) {
        const c = stack.pop()!;
        n++;
        const x = c % g.w, y = (c / g.w) | 0;
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            const nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= g.w || ny >= g.h) continue;
            const k = ny * g.w + nx;
            if (g.cells[k] === 1 && labels[k] < 0) { labels[k] = id2; stack.push(k); }
          }
        }
      }
      sizes.push(n);
    }
    const out = sizes.length ? { labels, main: sizes.indexOf(Math.max(...sizes)) } : null;
    compCache.current.set(id, out);
    return out;
  }, [gridOf]);

  /**
   * A walkable anchor for a level: the cell of its MAIN region closest to the level's centre. The
   * geometric centre itself is solid on most levels — a dungeon centre is usually wall, an outdoor
   * one frequently uncovered void — and the nearest ground to it is often an isolated ledge, so
   * routing "to the middle" fails for about half an act unless the target is resolved like this.
   */
  const anchorOf = useCallback((id: number): Pick | null => {
    const g = gridOf(id);
    const comp = componentsOf(id);
    if (!g || !comp) return null;
    const cx = g.w / 2, cy = g.h / 2;
    let best = -1, bestD = Infinity;
    for (let i = 0; i < g.cells.length; i++) {
      if (comp.labels[i] !== comp.main) continue;
      const dx = (i % g.w) - cx, dy = ((i / g.w) | 0) - cy;
      const d = dx * dx + dy * dy;
      if (d < bestD) { bestD = d; best = i; }
    }
    return best < 0 ? null : { level: id, x: best % g.w, y: (best / g.w) | 0 };
  }, [gridOf, componentsOf]);

  /**
   * The nearest passable cell to a click, preferring `want`'s component. The router's own
   * `snap_radius` is deliberately tight — a caller that names a coordinate meant that coordinate —
   * but a mouse pointer on an isometric map lands on a wall constantly, so the pick is what gets
   * snapped here rather than the search.
   */
  const snapPick = useCallback((p: Pick, want?: number, radius = 64): Pick | null => {
    const g = gridOf(p.level);
    if (!g) return null;
    const lab = want === undefined ? null : componentsOf(p.level)?.labels ?? null;
    const ok = (x: number, y: number) => {
      if (x < 0 || y < 0 || x >= g.w || y >= g.h) return false;
      const i = y * g.w + x;
      return g.cells[i] === 1 && (!lab || lab[i] === want);
    };
    if (ok(p.x, p.y)) return p;
    for (let r = 1; r <= radius; r++) {
      for (let d = -r; d <= r; d++) {
        for (const [x, y] of [[p.x + d, p.y - r], [p.x + d, p.y + r], [p.x - r, p.y + d], [p.x + r, p.y + d]]) {
          if (ok(x, y)) return { level: p.level, x, y };
        }
      }
    }
    return null;
  }, [gridOf, componentsOf]);

  /** Level-local subtiles → the act's shared world frame (act view), or through unchanged (level). */
  const toView = useCallback((lvl: number, x: number, y: number): [number, number] => {
    if (mode === "level") return [x, y];
    const info = levels.find((l) => l.id === lvl);
    if (!info) return [x, y];
    return [info.originX * SUBTILES_PER_TILE + x, info.originY * SUBTILES_PER_TILE + y];
  }, [mode, levels]);

  /** A route becomes one polyline per leg, plus a dashed connector across each level transition. */
  const routeLines = useCallback((r: RouteResult, color: string, alpha = 1): Line[] => {
    const out: Line[] = [];
    const byLeg = new Map<number, Move[]>();
    for (const m of r.moves) {
      if (mode === "level" && m.level !== levelId) continue;
      const arr = byLeg.get(m.leg) ?? [];
      arr.push(m);
      byLeg.set(m.leg, arr);
    }
    const legIdx = [...byLeg.keys()].sort((a, b) => a - b);
    for (const li of legIdx) {
      const ms = byLeg.get(li)!;
      // Teleport casts and pad jumps are separate hops, not a walked line — split so they read differently.
      let run: Move[] = [];
      const flush = (dashed: boolean) => {
        if (run.length >= 2) {
          out.push({ pts: run.map((m) => toView(m.level, m.x, m.y)), color, alpha, dashed, width: 2 });
        }
        run = [];
      };
      for (const m of ms) {
        if ((m.kind === MOVE_TELEPORT || m.kind === MOVE_PAD) && run.length) {
          const prev = run[run.length - 1];
          out.push({ pts: [toView(prev.level, prev.x, prev.y), toView(m.level, m.x, m.y)], color, alpha, dashed: true, width: 2 });
          run = [m];
          continue;
        }
        run.push(m);
      }
      flush(false);
    }
    // Cross-level transitions: last move of a leg to the first move of the next.
    if (mode === "act") {
      for (let i = 0; i + 1 < legIdx.length; i++) {
        const a = byLeg.get(legIdx[i])!, b = byLeg.get(legIdx[i + 1])!;
        if (!a.length || !b.length) continue;
        const p = a[a.length - 1], q = b[0];
        out.push({ pts: [toView(p.level, p.x, p.y), toView(q.level, q.x, q.y)], color, alpha: alpha * 0.6, dashed: true, width: 1.5 });
      }
    }
    return out;
  }, [mode, levelId, toView]);

  const lines: Line[] = useMemo(() => {
    const out: Line[] = [];
    if (bulk) {
      // Many overlapping routes: low alpha so the trunk everything shares burns in brightest.
      for (const r of bulk.routes) out.push(...routeLines(r, "#4fd0ff", 0.22));
    }
    if (route) out.push(...routeLines(route, "#66ff9e"));
    return out;
  }, [route, bulk, routeLines]);

  const markers: Marker[] = useMemo(() => {
    const out: Marker[] = [];
    if (!world) return out;
    if (mode === "level" && current) {
      for (const e of world.uniqueExits(levelId)) {
        if (e.kind === PORTAL || e.x < 0) continue;
        out.push({ ...pt(toView(levelId, e.x, e.y)), color: "#c98bff", hollow: true, label: String(e.toLevel) });
      }
    }
    if (from && (mode === "act" || from.level === levelId)) {
      out.push({ ...pt(toView(from.level, from.x, from.y)), color: "#66ff9e", label: "A" });
    }
    if (to && (mode === "act" || to.level === levelId)) {
      out.push({ ...pt(toView(to.level, to.x, to.y)), color: "#ff7b6b", label: "B" });
    }
    return out;
  }, [world, mode, current, levelId, from, to, toView]);

  // ── Routing ─────────────────────────────────────────────────────────────────
  const runRoute = useCallback((a: Pick, b: Pick) => {
    if (!world) return;
    const t0 = performance.now();
    const r = world.route(a, b, { mask, teleport, teleportAcrossLevels: teleport });
    const ms = performance.now() - t0;
    setRoute(r);
    if (r) {
      setRouteNote(`${r.moves.length} waypoints over ${r.legs.length} level${r.legs.length === 1 ? "" : "s"} — ${ms.toFixed(1)} ms`);
      return;
    }
    // Two very different failures wear the same null: the levels do not connect at all, or they do
    // but one of the endpoints sits somewhere the other cannot walk to.
    const chain = world.levelRoute(a.level, b.level);
    setRouteNote(chain
      ? `no route — B is walled off from A (${ms.toFixed(1)} ms)`
      : `no route — level ${a.level} and level ${b.level} are not connected`);
  }, [world, mask, teleport]);

  const onPick = useCallback((wx: number, wy: number) => {
    if (!world) return;
    let picked: Pick | null = null;
    if (mode === "level") {
      picked = { level: levelId, x: wx, y: wy };
    } else {
      // In the act view a click lands in world space; find whichever level's box contains it.
      for (const l of levels) {
        const ox = l.originX * SUBTILES_PER_TILE, oy = l.originY * SUBTILES_PER_TILE;
        if (wx >= ox && wy >= oy && wx < ox + l.w && wy < oy + l.h) {
          picked = { level: l.id, x: wx - ox, y: wy - oy };
          break;
        }
      }
      if (!picked) return;
    }
    const comp = componentsOf(picked.level);
    if (!from || (from && to)) {
      // A goes into the level's main region unless it is already standing on smaller ground.
      const snapped = snapPick(picked, comp?.main) ?? snapPick(picked);
      if (!snapped) { setRouteNote("that spot has no walkable ground near it"); return; }
      setBulk(null);
      setFrom(snapped); setTo(null); setRoute(null); setRouteNote("");
      return;
    }
    // B goes into A's OWN region when they share a level, so a click beside an isolated pocket does
    // not produce a route failure the map gives no way to see coming.
    const want = comp && from.level === picked.level
      ? comp.labels[from.y * (gridOf(from.level)?.w ?? 1) + from.x]
      : comp?.main;
    const snapped = snapPick(picked, want) ?? snapPick(picked);
    if (!snapped) { setRouteNote("that spot has no walkable ground near it"); return; }
    setBulk(null);
    setTo(snapped);
    runRoute(from, snapped);
  }, [world, mode, levelId, levels, from, to, runRoute, snapPick, componentsOf, gridOf]);

  /** Every exit-to-exit route on the current level: the level's own internal connectivity. */
  const bulkLevel = useCallback(async () => {
    if (!world) return;
    setBusy("Routing every exit pair on this level…");
    await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));
    try {
      const exits = world.uniqueExits(levelId).filter((e) => e.kind !== PORTAL && e.x >= 0);
      const routes: RouteResult[] = [];
      let failed = 0;
      for (let i = 0; i < exits.length; i++) {
        for (let j = i + 1; j < exits.length; j++) {
          const r = world.route(
            { level: levelId, x: exits[i].x, y: exits[i].y },
            { level: levelId, x: exits[j].x, y: exits[j].y },
            { mask, teleport },
          );
          if (r) routes.push(r); else failed++;
        }
      }
      setRoute(null); setFrom(null); setTo(null);
      setBulk({ label: `${routes.length} exit-to-exit routes on ${current?.name ?? levelId}`, routes, failed });
    } finally {
      setBusy(null);
    }
  }, [world, levelId, mask, teleport, current]);

  /** One route from the act's town to EVERY other level it holds — the whole act's traversal at
   *  once, the way the pathfinding suite walks the game. */
  const bulkAct = useCallback(async () => {
    if (!world) return;
    setMode("act");
    setBusy("Routing the whole act…");
    await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));
    try {
      const start = levels.find((l) => l.id === TOWN_OF_ACT[act]) ?? levels[0];
      const origin = start && anchorOf(start.id);
      if (!start || !origin) return;
      const routes: RouteResult[] = [];
      let failed = 0;
      for (const l of levels) {
        if (l.id === start.id) continue;
        const target = anchorOf(l.id);
        const r = target && world.route(origin, target, { mask, teleport });
        if (r) routes.push(r); else failed++;
      }
      setRoute(null); setFrom(null); setTo(null);
      setBulk({ label: `${routes.length} routes from ${start.name} to every level of ${ACTS[act]}`, routes, failed });
    } finally {
      setBusy(null);
    }
  }, [world, levels, act, mask, teleport, anchorOf]);

  const fitKey = `${mode}:${mode === "level" ? levelId : "act"}:${world?.seed}:${difficulty}:${act}`;

  return (
    <div className="app">
      <header>
        <h1>D2 Automap <span className="sub">clean-room DRLG + pathfinding</span></h1>
        <div className="controls">
          <label>Seed
            <input value={seedText} onChange={(e) => setSeedText(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && void generate()} spellCheck={false} />
          </label>
          <label>Difficulty
            <select value={difficulty} onChange={(e) => setDifficulty(Number(e.target.value))}>
              {DIFFICULTIES.map((d, i) => <option key={d} value={i}>{d}</option>)}
            </select>
          </label>
          <label>Act
            <select value={act} onChange={(e) => setAct(Number(e.target.value))}>
              {ACTS.map((a, i) => <option key={a} value={i}>{a}</option>)}
            </select>
          </label>
          <button onClick={() => void generate()} disabled={!!busy}>Generate</button>
          <span className="gap" />
          <label>Level
            <select value={levelId} onChange={(e) => { setLevelId(Number(e.target.value)); setRoute(null); setBulk(null); setFrom(null); setTo(null); }}>
              {levels.map((l) => <option key={l.id} value={l.id}>{l.id} — {l.name}</option>)}
            </select>
          </label>
          <label>Collision
            <select value={maskKind} onChange={(e) => setMaskKind(e.target.value as MaskKind)}>
              {MASKS.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>
          </label>
          <label className="check">
            <input type="checkbox" checked={teleport} onChange={(e) => setTeleport(e.target.checked)} /> teleport
          </label>
        </div>
        <div className="controls">
          <div className="tabs">
            <button className={mode === "level" ? "on" : ""} onClick={() => setMode("level")}>Level</button>
            <button className={mode === "act" ? "on" : ""} onClick={() => setMode("act")}>Whole act</button>
          </div>
          <button onClick={() => { setFrom(null); setTo(null); setRoute(null); setBulk(null); setRouteNote(""); }}>Clear</button>
          <button onClick={() => void bulkLevel()} disabled={!!busy || !world}>All routes on this level</button>
          <button onClick={() => void bulkAct()} disabled={!!busy || !world}>All routes across the act</button>
          <span className="gap" />
          <span className="note">
            {busy ? busy
              : error ? <span className="err">{error}</span>
                : bulk ? `${bulk.label}${bulk.failed ? ` (${bulk.failed} unreachable)` : ""}`
                  : routeNote ? routeNote
                    : from && !to ? "Now click B"
                      : "Click two points to route. Drag to pan, scroll to zoom."}
          </span>
        </div>
      </header>

      <main>
        {layers.length === 0 && !busy
          ? <div className="empty">{error ? "—" : "No geometry for this selection."}</div>
          : <MapCanvas layers={layers} lines={lines} markers={markers} onPick={onPick} fitKey={fitKey} />}
      </main>

      <footer>
        {current && (
          <>
            <b>{current.id} — {current.name}</b>
            <span>{current.w}×{current.h} subtiles</span>
            <span>origin {current.originX},{current.originY} tiles</span>
            <span>{current.exitCount} exit cells, {current.presetCount} presets</span>
            {world && <span className="exits">{world.uniqueExits(current.id).map((e) =>
              `→${e.toLevel}(${EXIT_KIND_NAME[e.kind] ?? e.kind})`).join("  ")}</span>}
          </>
        )}
      </footer>
    </div>
  );
}

function pt([x, y]: [number, number]) {
  return { x, y };
}
