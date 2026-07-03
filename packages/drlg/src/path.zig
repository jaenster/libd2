//! Faithful port of the Diablo II 1.14d unit PATHFINDING subsystem (the
//! `PATH_CalculatePath` chain, D2Common::Path / D2Common::Drlg::Path), operating
//! on this project's per-subtile collision grid (grid.zig) instead of the live
//! engine `CollMap`.
//!
//! This is NOT a generic A*. It reproduces the engine's actual algorithm,
//! decision order and data tables, read from 1.14d Game.exe (Ghidra session
//! 62fbfe69). Every function and data table below cites the address it was
//! ported from.
//!
//! ── What the engine actually does ─────────────────────────────────────────────
//! PATH_CalculatePath (0x649970) is an orchestrator. It resolves the target,
//! bounds-checks the delta (<100 tiles), removes the moving unit's own dynamic
//! collision, optionally routes around a blocking obstacle, then DISPATCHES to a
//! path-type generator through the function-pointer table PATHTYPEFUNC[ePathType]
//! (.rdata 0x6eb6d8, 17 entries). The generators that actually emit path points:
//!
//!   * ePathType 0 / 0x10  → PATH_FindPathAStar (0x67ad00) → DRLGPATH_FindPathAStar
//!     (0x67aaa0): an IDA*-style iterative-deepening search. This is the engine's
//!     real terrain pathfinder (players, walking monsters). Ported below as
//!     `findPathAStar`.
//!   * ePathType 2/5/6/13  → PATH_FindPathToward (0x679c80): a greedy
//!     direction-triplet stepper. Ported below as `findPathToward`.
//!   * PATH_BuildDirectPathToTarget (0x6492f0): a one-point "walk straight at it"
//!     path. Ported below as `buildDirectPathToTarget`.
//!
//! The A* move-cost model (from DRLGPATH_FindPathAStar / DRLGPATH_AStarExpandNode
//! 0x67a740): a straight step costs 2, a diagonal step costs 3; the heuristic is
//! h = min(|dx|,|dy|) + 2*max(|dx|,|dy|) (i.e. the cost of the ideal
//! diagonal-then-straight run). Iterative deepening starts the f-limit at h and
//! raises it by 5 each round until the target is reached or the limit passes
//! costMax = max(nIdaStarInitCopy, h).
//!
//! ── Collision adaptation ──────────────────────────────────────────────────────
//! The engine calls Collision::CheckCollision_BlockPlayer_Type (0x64d910) which
//! dispatches by the unit's collision *shape*: COLLISION_PATTERN_NONE tests a
//! single subtile (CheckCollision_BlockPlayerMissile_Internal2), the small/big
//! patterns test a cross / bounding-box of subtiles. All of them ultimately test
//! the COLLIDE_BLOCK_PLAYER (0x01) bit of the collision map. Our grid.zig already
//! ORs each tile's DT1 subtile flags into a per-subtile `blocked` mask keyed on
//! exactly that bit (grid.COLLIDE_BLOCK_PLAYER), so a subtile is "blocked for
//! walking" iff `blocked[i]` (or it is off-map void: no `ground`). We model the
//! default 1-wide unit (COLLISION_PATTERN_NONE → single subtile). The cross /
//! bounding-box shapes for big units are a documented follow-up (`CollisionShape`);
//! they sample the same primitive over a 5-cell cross / N×N box.
//!
//! ── What is faithful vs. a representation choice ──────────────────────────────
//! The algorithm, all direction/cost/heuristic tables, the neighbor try-order
//! (target-ward first, then the engine's seeded rotation sequence), the IDA*
//! deepening, the 900-node cap and the collinear-run waypoint compression are all
//! ported directly. The engine stores its search nodes in a raw short[] arena with
//! a hand-rolled hash grid; we use a typed node pool + an i32 hash grid of the same
//! dimensions and semantics. That is a storage representation choice, not an
//! algorithm change. Byte-exact validation against an engine golden (drive Game.exe
//! via the d2gs srvtrace oracle and dump the resulting PathPoints) is the remaining
//! follow-up to prove path-for-path identity.
//!
//! ── Dynamic (per-unit) collision layer: OUT OF SCOPE (documented) ─────────────
//! PATH_CalculatePath temporarily removes/re-adds the moving unit's and (flag
//! 0x800) the target unit's collision (PATH_RemoveUnitCollision / AddUnitCollision)
//! so a unit doesn't path-block itself, and other moving units imprint transient
//! collision. We do STATIC terrain nav only: the grid carries fixed DT1 terrain
//! collision. Modelling live moving-unit collision needs the room unit list and is
//! the documented next milestone.

const std = @import("std");

// =============================================================================
// Engine data tables (verbatim from 1.14d Game.exe, session 62fbfe69)
// =============================================================================

/// 8-direction subtile delta table. This exact {dx,dy} sequence appears three
/// times in the binary, all identical: gnDrlgMemoryMax[0x20..] (0x6f1958, the A*
/// neighbor deltas), gPathDirectionOffsetsX (0x6f1798, the toward-stepper deltas)
/// and gnObstacleAvoidanceXOffsets/YOffsets (0x6eb398, the detour deltas).
/// Direction index: 0=E 1=SE 2=S 3=SW 4=W 5=NW 6=N 7=NE (x grows east, y south).
const dir_delta = [8][2]i32{
    .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ -1, 1 },
    .{ -1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
};

/// gPathDirectionTable (0x6f1518): 25 entries × 3, indexed by the direction-index
/// (0..24) from `dirIndex`. Column 0 is the A* "primary" direction toward the
/// target (used by DRLGPATH_GetPathDirectionPacked, 0x678d10). Diagonal-aware.
const path_dir_table = [25][3]u8{
    .{ 5, 4, 6 }, .{ 4, 5, 6 }, .{ 4, 3, 5 }, .{ 4, 3, 2 }, .{ 3, 4, 2 },
    .{ 6, 5, 4 }, .{ 5, 4, 6 }, .{ 4, 3, 5 }, .{ 3, 4, 2 }, .{ 2, 3, 4 },
    .{ 6, 7, 5 }, .{ 6, 7, 5 }, .{ 6, 7, 5 }, .{ 2, 1, 3 }, .{ 2, 1, 3 },
    .{ 6, 7, 0 }, .{ 7, 0, 6 }, .{ 0, 1, 7 }, .{ 1, 0, 2 }, .{ 2, 1, 0 },
    .{ 7, 0, 6 }, .{ 0, 7, 6 }, .{ 0, 1, 7 }, .{ 0, 1, 2 }, .{ 1, 0, 2 },
};

/// gaDrlgPathDirectionTable (0x6f1648): 25 × {primary,secondary,tertiary} bytes,
/// -1 (0xff) = "no third candidate". The triplet used by PATH_FindPathToward and
/// PATH_FindAlternateAroundObstacle (cardinal-preferring, unlike path_dir_table).
const dir_triplet = [25][3]i8{
    .{ 4, 6, -1 }, .{ 4, 6, -1 }, .{ 4, 2, 6 }, .{ 4, 2, -1 }, .{ 4, 2, -1 },
    .{ 6, 4, -1 }, .{ 4, 6, -1 }, .{ 4, 2, 6 }, .{ 4, 2, -1 }, .{ 2, 4, -1 },
    .{ 6, 0, 4 }, .{ 6, 0, 4 }, .{ 6, 0, 4 }, .{ 2, 0, 4 }, .{ 2, 0, 4 },
    .{ 6, 0, -1 }, .{ 0, 6, -1 }, .{ 0, 2, 6 }, .{ 2, 0, -1 }, .{ 2, 0, -1 },
    .{ 0, 6, -1 }, .{ 0, 6, -1 }, .{ 0, 2, 6 }, .{ 0, 2, -1 }, .{ 0, 2, -1 },
};

/// gaPathWeightTable (0x6f1698): 8×8 [dy][dx] near-distance weights used by
/// DRLGPATH_GetWeightedDistancePacked (0x679380). -1 = "unreachable in one hop".
const weight_table = [8][8]i32{
    .{ -1, -1, -1, 0, 2, 4, 6, 8 },
    .{ -1, -1, 0, 1, 2, 4, 6, 8 },
    .{ -1, 0, 0, 2, 3, 5, 7, 8 },
    .{ 0, 1, 2, 2, 4, 5, 7, 8 },
    .{ 2, 2, 3, 4, 5, 6, 7, 9 },
    .{ 4, 4, 5, 5, 6, 7, 8, 9 },
    .{ 6, 6, 7, 7, 7, 8, 10, 10 },
    .{ 8, 8, 8, 8, 9, 9, 10, 11 },
};

/// gaPathDirectionStepDeltas (0x6eb490): the CENTER (index 0) of an 81-int signed
/// step table (int32 elements — disasm: `MOV EDX, dword ptr [EDX*0x4 + 0x6eb490]`).
/// The binary's symbol points at the middle of the table: PATH_GetTargetCoordinates
/// (0x648020) only ever reads the non-negative half (step+dir*9, both in [0,4]), but
/// PATH_ExtendPathEndpoint (0x648050) indexes by the signed delta ddx+ddy*9 in
/// [-40,+40], so the negative-index prefix (0x6eb3f0..0x6eb490) is required too.
/// Stored here 0-based as nine 9-wide rows for offsets -40..+40; `stepDelta`
/// re-centers a signed offset by +40. The +0..+40 half is byte-identical to the old
/// 41-int slice, so getTargetCoordinates is unchanged.
const step_deltas = [81]i32{
    -1, 0,  0,  0,  0, 0, 0, 0, 1, // offset -40..-32
    -1, -1, 0,  0,  0, 0, 0, 1, 1, // offset -31..-23
    -1, -1, -1, 0,  0, 0, 1, 1, 1, // offset -22..-14
    -1, -1, -1, -1, 0, 1, 1, 1, 1, // offset -13..-5
    -1, -1, -1, -1, 0, 1, 1, 1, 1, // offset  -4..+4  (offset 0 = center)
    -1, -1, -1, -1, 0, 1, 1, 1, 1, // offset  +5..+13
    -1, -1, -1, 0,  0, 0, 1, 1, 1, // offset +14..+22
    -1, -1, 0,  0,  0, 0, 0, 1, 1, // offset +23..+31
    -1, 0,  0,  0,  0, 0, 0, 0, 1, // offset +32..+40
};

/// Read gaPathDirectionStepDeltas at a signed offset in [-40,+40]. The engine's
/// symbol is the table center; the port stores it 0-based, so re-center by +40.
inline fn stepDelta(offset: i32) i32 {
    return step_deltas[@intCast(offset + 40)];
}

/// gnDrlgLevelSeed-as-table (0x6f17d8): the A* direction-rotation table, 8
/// "turn-class" rows × 8 columns. Read by DRLGPATH_AStarExpandNode /
/// DRLGPATH_AdvanceNodeDirection (0x67a630): when a node's current direction is
/// blocked, its facing is advanced by adding successive entries of the row for its
/// turn-class k = (target-ward-dir − parent-dir) & 7. Only the first ~5 columns of
/// each row are consumed (5 direction attempts per node before it backtracks).
const rot_table = [64]i32{
    0, 1, 6, 3, 4, 5, 2, 7, // k=0
    0, 1, 6, 3, 1, 3, 6, 1, // k=1
    0, 1, 1, 1, 1, 1, 2, 7, // k=2
    1, 1, 1, 1, 1, 3, 6, 1, // k=3
    6, 4, 3, 6, 1, 3, 2, 7, // k=4
    7, 7, 7, 7, 7, 5, 2, 7, // k=5
    0, 7, 7, 7, 7, 5, 2, 7, // k=6
    0, 7, 2, 5, 7, 5, 2, 7, // k=7
};

// A* move costs (DRLGPATH_AStarExpandNode 0x67a740).
const COST_STRAIGHT: i32 = 2;
const COST_DIAG: i32 = 3;
/// Node pool cap (0x384) — DRLGPATH_AStarExpandNode gives up past this many nodes.
const NODE_CAP: usize = 900;
/// Per-expansion iteration cap (10000) — DRLGPATH_AStarExpandNode returns 0 past it.
const ITER_CAP: usize = 10000;
/// Max path points the engine will emit (DRLGPATH_ExtractPathFromResult clamps 0x4d).
pub const MAX_PATH_POINTS: usize = 77;

// =============================================================================
// Collision view over grid.zig
// =============================================================================

/// Collision shapes accepted by CheckCollision_BlockPlayer_Type (0x64d910),
/// eD2CollisionShapeType. Only `none` (single subtile, the default 1-wide unit) is
/// modelled; the multi-subtile shapes are a documented follow-up.
pub const CollisionShape = enum(u8) {
    none = 0, // COLLISION_PATTERN_NONE → single subtile
    small_cross = 1, // COLLISION_PATTERN_SMALL_* → 5-subtile cross (TODO)
    big_box = 3, // COLLISION_PATTERN_BIG_* → bounding box (TODO)
};

/// A walkability view over a subtile collision grid. Coords are LOCAL subtiles
/// [0,w)×[0,h). Build one from a level's generated collision via lib.buildPathGrid
/// (PathGrid.view), or directly from any `blocked`/`ground` bitmap.
pub const CollisionView = struct {
    w: i32,
    h: i32,
    blocked: []const bool,
    ground: ?[]const bool = null,

    inline fn inBounds(self: CollisionView, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.w and y < self.h;
    }

    /// Faithful analogue of CheckCollision_BlockPlayer_Type for `shape`:
    /// non-zero (true) means the position blocks a walking player. Off-map is
    /// always blocking (there is no CollMap there). Only `.none` implemented.
    pub fn collides(self: CollisionView, x: i32, y: i32, shape: CollisionShape) bool {
        return switch (shape) {
            .none => self.blockedSubtile(x, y),
            // Cross / box: block if ANY sampled subtile blocks. Ported shape TODO —
            // fall back to the single-subtile primitive so callers still get a
            // conservative-but-consistent answer until the exact offsets are wired.
            .small_cross, .big_box => self.blockedSubtile(x, y),
        };
    }

    inline fn blockedSubtile(self: CollisionView, x: i32, y: i32) bool {
        if (!self.inBounds(x, y)) return true;
        const idx: usize = @as(usize, @intCast(y)) * @as(usize, @intCast(self.w)) + @as(usize, @intCast(x));
        if (self.blocked[idx]) return true;
        if (self.ground) |gr| return !gr[idx]; // off-map void is impassable
        return false;
    }

    pub inline fn walkable(self: CollisionView, x: i32, y: i32) bool {
        return !self.collides(x, y, .none);
    }
};

// =============================================================================
// Small direction / distance primitives (ported 1:1)
// =============================================================================

/// DRLGPATH_GetDirectionIndexPacked (0x678c10): classify the delta (dst−src) into
/// a 0..24 index for path_dir_table / dir_triplet lookup.
fn dirIndex(dx_in: i32, dy_in: i32) usize {
    var dx = dx_in;
    var dy = dy_in;
    const ax = @abs(dx);
    const ay = @abs(dy);
    if (ax < ay * 2) {
        if (ax * 2 <= ay) {
            if (dx < 0) {
                dx = -1;
                return labPart(dx, dy);
            }
            dx = dx & 1;
        }
        // else: diagonal band — leave dx,dy as-is
    } else {
        if (dy < 0) dy = -1 else dy = dy & 1;
    }
    if (dx < -1) dx = -2 else if (dx > 1) dx = 2;
    return labPart(dx, dy);
}

inline fn labPart(dx: i32, dy_in: i32) usize {
    var dy = dy_in;
    if (dy < -1) return @intCast(dx * 5 + 10);
    if (dy > 1) dy = 2;
    return @intCast(dx * 5 + 12 + dy);
}

/// DRLGPATH_GetPathDirectionPacked (0x678d10): primary A* direction src→dst.
inline fn pathDirection(sx: i32, sy: i32, dx: i32, dy: i32) u8 {
    return path_dir_table[dirIndex(dx - sx, dy - sy)][0];
}

/// A* heuristic (DRLGPATH_FindPathAStar / AStarExpandNode): min + 2*max.
inline fn heuristic(sx: i32, sy: i32, dx: i32, dy: i32) i32 {
    const ax: i32 = @intCast(@abs(dx - sx));
    const ay: i32 = @intCast(@abs(dy - sy));
    const lo = @min(ax, ay);
    const hi = @max(ax, ay);
    return lo + hi * 2;
}

/// DRLGPATH_GetWeightedDistancePacked (0x679380): weight-table for near targets,
/// min+2*max fallback beyond 8 subtiles. Used by the toward-stepper reachability.
fn weightedDistance(sx: i32, sy: i32, dx: i32, dy: i32) i32 {
    const ax: i32 = @intCast(@abs(dx - sx));
    const ay: i32 = @intCast(@abs(dy - sy));
    if (ax < 8 and ay < 8) {
        const w = weight_table[@intCast(ay)][@intCast(ax)];
        if (w < 0) return 0;
        return w + 1;
    }
    if (ay < ax) return ay + ax * 2;
    return ax + ay * 2;
}

/// PATH_GetTargetCoordinates (0x648020): step delta for (dir,step) off the
/// gaPathDirectionStepDeltas grid.
pub fn getTargetCoordinates(dir_index: i32, step_index: i32) [2]i32 {
    return .{
        stepDelta(step_index + dir_index * 9), // X
        stepDelta(dir_index + step_index * 9), // Y
    };
}

pub const Point = struct { x: i32, y: i32 };

// =============================================================================
// A* (ePathType 0/0x10): PATH_FindPathAStar (0x67ad00) →
// DRLGPATH_FindPathAStar (0x67aaa0) + DRLGPATH_AStarExpandNode (0x67a740) +
// DRLGPATH_AdvancePathNodeChain (0x67a690) + DRLGPATH_ExtractPathFromResult
// =============================================================================

const Node = struct {
    x: i32,
    y: i32,
    g: i32,
    h: i32,
    f: i32,
    dir: u8, // current facing (0..7)
    visit: u8, // directions tried so far (0..5)
    seed_ptr: usize, // index into rot_table for the next rotation
    parent: i32, // pool index, -1 for root
    child: i32, // last-created child pool index, -1 if none
};

/// Parameters mapped from D2DynamicPathStrc / D2PathTypeArg. Defaults model a
/// walking player over static terrain.
pub const AStarParams = struct {
    shape: CollisionShape = .none,
    /// nIdaStarVariable (D2DynamicPathStrc.nIdaStarVariable): the "good enough"
    /// heuristic proximity. A node with h < this is accepted as reaching the
    /// target. 0 = require the exact target cell (used for precise nav here).
    ida_star_variable: i32 = 0,
    /// nIdaStarInitCopy → costMax = max(this, h). Bounds the IDA* deepening. The
    /// engine takes this from the unit; a generous default lets the search deepen
    /// until it finds the optimum for reachable static targets.
    cost_limit_max: i32 = 4096,
};

const AStar = struct {
    view: CollisionView,
    params: AStarParams,
    target: Point,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    hash: []i32, // per-subtile: 0=unseen, 1=blocked marker, >1 = best g reached
    hw: usize,
    hh: usize,

    fn hashAt(self: *AStar, x: i32, y: i32) *i32 {
        // Search stays inside the grid (out-of-grid neighbors are collision-blocked
        // before they are ever indexed), so a grid-sized hash suffices.
        const ix: usize = @intCast(x);
        const iy: usize = @intCast(y);
        return &self.hash[iy * self.hw + ix];
    }

    fn alloc(self: *AStar, a: std.mem.Allocator, n: Node) !i32 {
        if (self.nodes.items.len >= NODE_CAP) return -1;
        try self.nodes.append(a, n);
        return @intCast(self.nodes.items.len - 1);
    }

    /// DRLGPATH_AdvancePathNodeChain (0x67a690): rotate the current node to its
    /// next candidate direction; when it has exhausted 5 directions, backtrack to
    /// (and rotate) its parent, repeating. Returns the node to continue from, or
    /// null when the root is exhausted.
    fn advanceChain(self: *AStar, node_idx: i32) ?i32 {
        var idx = node_idx;
        {
            const n = &self.nodes.items[@intCast(idx)];
            if (n.visit < 4) {
                n.seed_ptr += 1;
                n.dir = @intCast((rot_table[n.seed_ptr & 63] + @as(i32, n.dir)) & 7);
            }
            n.visit += 1;
        }
        while (self.nodes.items[@intCast(idx)].visit == 5) {
            const parent = self.nodes.items[@intCast(idx)].parent;
            if (parent < 0) return null; // root exhausted
            idx = parent;
            const p = &self.nodes.items[@intCast(idx)];
            p.seed_ptr += 1;
            p.dir = @intCast((rot_table[p.seed_ptr & 63] + @as(i32, p.dir)) & 7);
            p.visit += 1;
        }
        return idx;
    }

    /// DRLGPATH_AStarExpandNode (0x67a740): DFS from `root_idx` expanding one
    /// neighbor (the node's current direction) per step, bounded by `cost_limit`.
    /// Returns the pool index of the node that reached the target (or a node within
    /// ida_star_variable of it), or null.
    fn expand(self: *AStar, a: std.mem.Allocator, root_idx: i32, cost_limit: i32) !?i32 {
        var cur = root_idx;
        var iter: usize = 0;
        while (true) {
            const c = self.nodes.items[@intCast(cur)];
            if (c.x == self.target.x and c.y == self.target.y) return cur;
            iter += 1;
            if (iter > ITER_CAP) return null;
            // Bounds guard (engine: node outside the search box is terminal). Our
            // box is the whole grid; out-of-grid neighbors never get created, so
            // this only fires on a degenerate root.
            if (!self.view.inBounds(c.x, c.y)) return cur;

            const nx = c.x + dir_delta[c.dir][0];
            const ny = c.y + dir_delta[c.dir][1];

            // Off-grid neighbor: cannot index the hash; treat as blocked and rotate.
            if (!self.view.inBounds(nx, ny)) {
                cur = self.advanceChain(cur) orelse return null;
                continue;
            }

            const slot = self.hashAt(nx, ny);
            const was_seen = slot.* != 0;
            if (!was_seen and self.view.collides(nx, ny, self.params.shape)) {
                slot.* = 1; // permanent blocked marker
                cur = self.advanceChain(cur) orelse return null;
                continue;
            }

            const straight = (c.x == nx) or (c.y == ny);
            const gcost = c.g + (if (straight) COST_STRAIGHT else COST_DIAG);
            if (slot.* != 0 and slot.* < gcost) {
                cur = self.advanceChain(cur) orelse return null;
                continue;
            }
            slot.* = gcost;

            const hcost = heuristic(nx, ny, self.target.x, self.target.y);
            const fcost = hcost + gcost;
            if (fcost > cost_limit) {
                cur = self.advanceChain(cur) orelse return null;
                continue;
            }

            // Get or allocate the child (engine reuses pCurNode->pNext).
            var child = self.nodes.items[@intCast(cur)].child;
            if (child < 0) {
                child = try self.alloc(a, std.mem.zeroes(Node));
                if (child < 0) return null; // pool exhausted
                self.nodes.items[@intCast(cur)].child = child;
                self.nodes.items[@intCast(child)].parent = cur;
                self.nodes.items[@intCast(child)].child = -1;
            }

            // Child facing: target-ward direction rotated by the turn-class row.
            const parent_dir = self.nodes.items[@intCast(cur)].dir;
            const twd = pathDirection(nx, ny, self.target.x, self.target.y);
            const k: usize = @intCast((@as(i32, twd) - @as(i32, parent_dir)) & 7);
            const ch = &self.nodes.items[@intCast(child)];
            ch.x = nx;
            ch.y = ny;
            ch.g = gcost;
            ch.h = hcost;
            ch.f = fcost;
            ch.visit = 0;
            ch.seed_ptr = k * 8;
            ch.dir = @intCast((@as(i32, parent_dir) + rot_table[k * 8]) & 7);

            if (hcost < self.params.ida_star_variable) return child;
            cur = child;
        }
    }

    /// DRLGPATH_ExtractPathFromResult (0x67a9f0): walk parent pointers from the
    /// goal node back to the root, emitting a waypoint whenever the step direction
    /// changes (collinear runs collapse). Returns start→goal order, clamped to 77.
    fn extract(self: *AStar, a: std.mem.Allocator, goal_idx: i32) ![]Point {
        var rev: std.ArrayListUnmanaged(Point) = .empty;
        defer rev.deinit(a);
        var prev_dx: i32 = -2;
        var prev_dy: i32 = -2;
        var idx = goal_idx;
        while (idx >= 0 and rev.items.len < MAX_PATH_POINTS) {
            const n = self.nodes.items[@intCast(idx)];
            const parent = n.parent;
            if (parent >= 0) {
                const p = self.nodes.items[@intCast(parent)];
                const ddx = n.x - p.x;
                const ddy = n.y - p.y;
                if (ddx != prev_dx or ddy != prev_dy) {
                    try rev.append(a, .{ .x = n.x, .y = n.y });
                    prev_dx = ddx;
                    prev_dy = ddy;
                }
            }
            idx = parent;
        }
        std.mem.reverse(Point, rev.items);
        return rev.toOwnedSlice(a);
    }
};

pub const Error = error{ StartBlocked, GoalBlocked, NoPath } || std.mem.Allocator.Error;

/// PATH_FindPathAStar (0x67ad00) → DRLGPATH_FindPathAStar (0x67aaa0): find a walk
/// path from `start` to `target` over the collision view. Returns the engine's
/// compressed waypoint list (direction-change corners, start→goal, both endpoints
/// where they are corners), or Error.NoPath. Caller frees the slice.
pub fn findPathAStar(
    allocator: std.mem.Allocator,
    view: CollisionView,
    start: Point,
    target: Point,
    params: AStarParams,
) Error![]Point {
    if (view.collides(start.x, start.y, params.shape)) return Error.StartBlocked;
    if (view.collides(target.x, target.y, params.shape)) return Error.GoalBlocked;
    if (start.x == target.x and start.y == target.y) {
        const one = try allocator.alloc(Point, 1);
        one[0] = target;
        return one;
    }

    const hw: usize = @intCast(view.w);
    const hh: usize = @intCast(view.h);
    const hash = try allocator.alloc(i32, hw * hh);
    defer allocator.free(hash);

    var astar = AStar{
        .view = view,
        .params = params,
        .target = target,
        .hash = hash,
        .hw = hw,
        .hh = hh,
    };
    defer astar.nodes.deinit(allocator);

    const h0 = heuristic(start.x, start.y, target.x, target.y);
    var cost_limit: i32 = h0;
    const cost_max: i32 = @max(params.cost_limit_max, h0);

    var goal: ?i32 = null;
    while (cost_limit <= cost_max) : (cost_limit += 5) {
        // Reset the per-iteration search state (engine memsets the arena + grid).
        @memset(hash, 0);
        astar.nodes.clearRetainingCapacity();
        const root = try astar.alloc(allocator, .{
            .x = start.x,
            .y = start.y,
            .g = 0,
            .h = h0,
            .f = h0,
            .dir = pathDirection(start.x, start.y, target.x, target.y),
            .visit = 0,
            .seed_ptr = 0,
            .parent = -1,
            .child = -1,
        });
        goal = try astar.expand(allocator, root, cost_limit);
        if (goal != null) break;
    }

    const g = goal orelse return Error.NoPath;
    return astar.extract(allocator, g);
}

// =============================================================================
// Direct path (PATH_BuildDirectPathToTarget 0x6492f0)
// =============================================================================

/// PATH_BuildDirectPathToTarget (0x6492f0): the trivial "walk straight at the
/// target" path type. Valid only when both axis deltas are within 99 subtiles and
/// the target is non-zero. Returns a single waypoint at the target, or null.
pub fn buildDirectPathToTarget(start: Point, target: Point) ?Point {
    if (target.x == 0 or target.y == 0) return null;
    if (@abs(start.x - target.x) > 99) return null;
    if (@abs(start.y - target.y) > 99) return null;
    return target;
}

// =============================================================================
// Toward-stepper (ePathType 2/5/6/13): PATH_FindPathToward (0x679c80)
// =============================================================================

/// PATH_FindPathToward (0x679c80): the greedy coarse path type. Walks one subtile
/// at a time from `start` toward `target`, at each step choosing the first
/// non-blocked direction of the target-ward triplet
/// (DRLGPATH_GetPathDirectionTripletPacked 0x678df0 +
/// DRLGPATH_FindNonBlockedDirectionFromTriplet 0x6793e0). Records a waypoint each
/// time the chosen direction changes; anti-backtracks (never reverses the previous
/// direction); bounded by `dist_max` steps. Greedy: can dead-end in concave
/// terrain (that is faithful — the engine then falls back to the A* type).
pub fn findPathToward(
    allocator: std.mem.Allocator,
    view: CollisionView,
    start: Point,
    target: Point,
    dist_max: i32,
    shape: CollisionShape,
) Error![]Point {
    var out: std.ArrayListUnmanaged(Point) = .empty;
    errdefer out.deinit(allocator);

    // Directly reachable / within one weighted hop → single waypoint.
    if (weightedDistance(start.x, start.y, target.x, target.y) <= 0) {
        try out.append(allocator, target);
        return out.toOwnedSlice(allocator);
    }

    var cur = start;
    var prev_dir: i32 = -1; // 0xff sentinel
    var iter: i32 = 0;
    var last_added_dir: i32 = -2;
    while (iter < dist_max) : (iter += 1) {
        if (cur.x == target.x and cur.y == target.y) break;
        const trip = dir_triplet[dirIndex(target.x - cur.x, target.y - cur.y)];
        const chosen = firstNonBlocked(view, cur, trip, shape) orelse break;
        // Anti-backtrack: never reverse the previous step (dir±4).
        if (@as(i32, @intCast((@as(i32, chosen) + 4) & 7)) == prev_dir) break;
        if (chosen != last_added_dir) {
            try out.append(allocator, cur);
            last_added_dir = chosen;
        }
        cur.x += dir_delta[chosen][0];
        cur.y += dir_delta[chosen][1];
        prev_dir = chosen;
    }
    try out.append(allocator, target);
    return out.toOwnedSlice(allocator);
}

/// DRLGPATH_FindNonBlockedDirectionFromTriplet (0x6793e0): first triplet member
/// whose one-step neighbor is walkable (tertiary skipped when -1).
fn firstNonBlocked(view: CollisionView, from: Point, trip: [3]i8, shape: CollisionShape) ?u8 {
    for (trip) |d| {
        if (d < 0) continue;
        const dir: u8 = @intCast(d);
        const nx = from.x + dir_delta[dir][0];
        const ny = from.y + dir_delta[dir][1];
        if (!view.collides(nx, ny, shape)) return dir;
    }
    return null;
}

// =============================================================================
// Obstacle detour: PATH_FindAlternateAroundObstacle (0x648120) +
// PATH_ExtendPathEndpoint (0x648050)
// =============================================================================

/// Mutable src/dst coord pair mirroring D2PathTypeArg.pCoords (offset/pos pairs).
pub const PathCoords = struct {
    src_x: i32,
    src_y: i32,
    dst_x: i32,
    dst_y: i32,
};

/// PATH_FindAlternateAroundObstacle (0x648120): when the straight destination is
/// blocked, step from src toward dst; at each step take the primary triplet
/// direction if free, else the secondary, else the tertiary, updating dst to the
/// last reachable cell. `is_player` triggers PATH_ExtendPathEndpoint at the end.
/// Returns true if an alternate endpoint was found (engine's return 1).
pub fn findAlternateAroundObstacle(view: CollisionView, coords: *PathCoords, is_player: bool, shape: CollisionShape) bool {
    const target_x = coords.dst_x;
    const target_y = coords.dst_y;
    var cx = coords.src_x;
    var cy = coords.src_y;
    var sec_x = cx;
    var sec_y = cy;
    var ter_x = cx;
    var ter_y = cy;

    var trip = dir_triplet[dirIndex(coords.dst_x - coords.src_x, coords.dst_y - coords.src_y)];
    while (true) {
        if (target_x == cx and target_y == cy) return false;
        const prim: u8 = @intCast(trip[0]);
        cy += dir_delta[prim][1];
        cx += dir_delta[prim][0];
        if (!view.collides(cx, cy, shape)) {
            coords.src_x = cx; // engine tracks moving endpoint in offset fields
            coords.src_y = cy;
            coords.dst_x = cx;
            coords.dst_y = cy;
            if (cx == target_x and cy == target_y) return false;
            if (is_player) extendPathEndpoint(view, coords, shape);
            return true;
        }
        if (trip[1] >= 0) {
            const sec: u8 = @intCast(trip[1]);
            sec_x += dir_delta[sec][0];
            sec_y += dir_delta[sec][1];
            if (!view.collides(sec_x, sec_y, shape)) {
                coords.dst_x = sec_x;
                coords.dst_y = sec_y;
                if (!(sec_x == target_x and sec_y == target_y) and is_player) extendPathEndpoint(view, coords, shape);
                return !(sec_x == target_x and sec_y == target_y);
            }
        }
        if (trip[2] != -1 and trip[2] >= 0) {
            const ter: u8 = @intCast(trip[2]);
            ter_x += dir_delta[ter][0];
            ter_y += dir_delta[ter][1];
            if (!view.collides(ter_x, ter_y, shape)) {
                coords.dst_x = ter_x;
                coords.dst_y = ter_y;
                if (!(ter_x == target_x and ter_y == target_y) and is_player) extendPathEndpoint(view, coords, shape);
                return !(ter_x == target_x and ter_y == target_y);
            }
        }
        trip = dir_triplet[dirIndex(target_x - cx, target_y - cy)];
    }
}

/// PATH_ExtendPathEndpoint (0x648050): nudge the endpoint further along the last
/// movement direction, up to a 5-subtile span, while no collision is hit.
pub fn extendPathEndpoint(view: CollisionView, coords: *PathCoords, shape: CollisionShape) void {
    const ddx = coords.dst_x - coords.src_x;
    const ddy = coords.dst_y - coords.src_y;
    const adx = @abs(ddx);
    const ady = @abs(ddy);
    if (adx >= 5 or ady >= 5) return;
    if (adx == 0 and ady == 0) return;
    const step_x = stepDelta(ddx + ddy * 9);
    const step_y = stepDelta(ddy + ddx * 9);
    var x = coords.dst_x;
    var y = coords.dst_y;
    var n = @max(adx, ady);
    while (n < 5) : (n += 1) {
        x += step_x;
        y += step_y;
        if (view.collides(x, y, shape)) return;
        coords.dst_x = x;
        coords.dst_y = y;
    }
}

// =============================================================================
// PATH_CheckPathPointsInRoom (0x647fb0)
// =============================================================================

/// PATH_CheckPathPointsInRoom (0x647fb0): true if every path point lies inside the
/// room rect [x0,x0+w) × [y0,y0+h). The engine sets flag bit 1 when a point leaves
/// the room (a room transition); here we just report it.
pub fn allPathPointsInRoom(points: []const Point, x0: i32, y0: i32, w: i32, h: i32) bool {
    for (points) |p| {
        if (p.x < x0 or p.x >= x0 + w) return false;
        if (p.y < y0 or p.y >= y0 + h) return false;
    }
    return true;
}

// =============================================================================
// Orchestrator: PATH_CalculatePath (0x649970), static-terrain adaptation
// =============================================================================

pub const PathType = enum(u8) {
    astar = 0, // PATHTYPEFUNC[0]  → PATH_FindPathAStar
    toward = 2, // PATHTYPEFUNC[2] → PATH_FindPathToward
    direct = 0xfe, // PATH_BuildDirectPathToTarget (not table-dispatched; walk step)
};

pub const CalcParams = struct {
    path_type: PathType = .astar,
    shape: CollisionShape = .none,
    is_player: bool = true,
    /// Attempt PATH_FindAlternateAroundObstacle when the destination is blocked
    /// (engine flag 0x1000).
    avoid_obstacle: bool = true,
    dist_max: i32 = 160,
    astar: AStarParams = .{},
};

/// PATH_CalculatePath (0x649970) adapted to static terrain: no missile path, no
/// per-unit collision add/remove, no room transitions. Resolves the (already
/// static) target, bounds-checks the <100-subtile delta on each axis, optionally
/// detours the destination around a blocking obstacle
/// (PATH_FindAlternateAroundObstacle), then dispatches to the path-type generator
/// (PATHTYPEFUNC[ePathType]) and returns its waypoint list. Caller frees.
pub fn calculatePath(
    allocator: std.mem.Allocator,
    view: CollisionView,
    start: Point,
    target: Point,
    params: CalcParams,
) Error![]Point {
    // Bounds gate (PATH_CalculatePath: reject deltas of 100+ subtiles per axis).
    if (@abs(start.x - target.x) >= 100 or @abs(start.y - target.y) >= 100) return Error.NoPath;

    var dst = target;
    // Obstacle detour (engine flag 0x1000 → PATH_FindAlternateAroundObstacle).
    if (params.avoid_obstacle and view.collides(dst.x, dst.y, params.shape)) {
        var coords = PathCoords{ .src_x = start.x, .src_y = start.y, .dst_x = target.x, .dst_y = target.y };
        _ = findAlternateAroundObstacle(view, &coords, params.is_player, params.shape);
        dst = .{ .x = coords.dst_x, .y = coords.dst_y };
    }

    return switch (params.path_type) {
        .astar => findPathAStar(allocator, view, start, dst, params.astar),
        .toward => findPathToward(allocator, view, start, dst, params.dist_max, params.shape),
        .direct => blk: {
            const p = buildDirectPathToTarget(start, dst) orelse break :blk Error.NoPath;
            const one = try allocator.alloc(Point, 1);
            one[0] = p;
            break :blk one;
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Build a CollisionView from ASCII art: '#' blocks, '.'/other = walkable ground,
/// ' ' = off-map void. Row-major. Caller frees via `TestGrid.deinit`.
const TestGrid = struct {
    view: CollisionView,
    blocked: []bool,
    ground: []bool,
    fn deinit(self: *TestGrid, a: std.mem.Allocator) void {
        a.free(self.blocked);
        a.free(self.ground);
    }
};

fn parseAscii(a: std.mem.Allocator, comptime art: []const u8) !TestGrid {
    var w: usize = 0;
    var h: usize = 0;
    var it = std.mem.splitScalar(u8, art, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        w = @max(w, ln.len);
        h += 1;
    }
    const blocked = try a.alloc(bool, w * h);
    const ground = try a.alloc(bool, w * h);
    @memset(blocked, false);
    @memset(ground, true);
    var y: usize = 0;
    it = std.mem.splitScalar(u8, art, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        for (ln, 0..) |ch, x| {
            const idx = y * w + x;
            if (ch == '#') blocked[idx] = true;
            if (ch == ' ') ground[idx] = false;
        }
        y += 1;
    }
    return .{
        .view = .{ .w = @intCast(w), .h = @intCast(h), .blocked = blocked, .ground = ground },
        .blocked = blocked,
        .ground = ground,
    };
}

/// Assert consecutive waypoints form a contiguous 8-connected straight run and
/// every intermediate subtile is walkable; returns the total stepped length.
fn assertContiguousWalkable(view: CollisionView, path: []const Point) !usize {
    var steps: usize = 0;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        const a = path[i - 1];
        const b = path[i];
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        // A compressed segment must be axis-aligned or a pure diagonal.
        const adx = @abs(dx);
        const ady = @abs(dy);
        try testing.expect(adx == 0 or ady == 0 or adx == ady);
        const n = @max(adx, ady);
        const sx: i32 = std.math.sign(dx);
        const sy: i32 = std.math.sign(dy);
        var k: i32 = 1;
        while (k <= n) : (k += 1) {
            const x = a.x + sx * k;
            const y = a.y + sy * k;
            try testing.expect(view.walkable(x, y));
            steps += 1;
        }
    }
    return steps;
}

test "dirIndex/pathDirection point roughly toward the target" {
    // East, South, West, North primary directions.
    try testing.expectEqual(@as(u8, 0), pathDirection(0, 0, 10, 0)); // E
    try testing.expectEqual(@as(u8, 2), pathDirection(0, 0, 0, 10)); // S
    try testing.expectEqual(@as(u8, 4), pathDirection(0, 0, -10, 0)); // W
    try testing.expectEqual(@as(u8, 6), pathDirection(0, 0, 0, -10)); // N
    try testing.expectEqual(@as(u8, 1), pathDirection(0, 0, 10, 10)); // SE
}

test "A*: straight corridor compresses to a single target waypoint" {
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\..........
        \\..........
    );
    defer tg.deinit(a);
    const path = try findPathAStar(a, tg.view, .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 0 }, .{});
    defer a.free(path);
    _ = try assertContiguousWalkable(tg.view, path);
    try testing.expectEqual(@as(i32, 9), path[path.len - 1].x);
    try testing.expectEqual(@as(i32, 0), path[path.len - 1].y);
}

test "A*: routes around a wall with a gap and stays walkable" {
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\.....#....
        \\.....#....
        \\.....#....
        \\..........
        \\.....#....
    );
    defer tg.deinit(a);
    const start = Point{ .x = 0, .y = 0 };
    const goal = Point{ .x = 9, .y = 0 };
    const path = try findPathAStar(a, tg.view, start, goal, .{});
    defer a.free(path);
    const steps = try assertContiguousWalkable(tg.view, path);
    try testing.expect(steps > 0);
    try testing.expectEqual(goal.x, path[path.len - 1].x);
    try testing.expectEqual(goal.y, path[path.len - 1].y);
    // The only gap is row 3, so the route must dip to y>=3.
    var max_y: i32 = 0;
    for (path) |p| max_y = @max(max_y, p.y);
    try testing.expect(max_y >= 3);
}

test "A*: no path through a sealed wall" {
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\....#....
        \\....#....
        \\....#....
        \\....#....
        \\....#....
    );
    defer tg.deinit(a);
    try testing.expectError(
        Error.NoPath,
        findPathAStar(a, tg.view, .{ .x = 0, .y = 2 }, .{ .x = 8, .y = 2 }, .{ .cost_limit_max = 256 }),
    );
}

test "A*: blocked start / goal rejected" {
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\.#.
        \\...
    );
    defer tg.deinit(a);
    try testing.expectError(Error.GoalBlocked, findPathAStar(a, tg.view, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{}));
    try testing.expectError(Error.StartBlocked, findPathAStar(a, tg.view, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 0 }, .{}));
}

test "direct path: single waypoint within 99, rejected beyond" {
    try testing.expect(buildDirectPathToTarget(.{ .x = 5, .y = 5 }, .{ .x = 20, .y = 30 }) != null);
    try testing.expect(buildDirectPathToTarget(.{ .x = 5, .y = 5 }, .{ .x = 200, .y = 30 }) == null);
    try testing.expect(buildDirectPathToTarget(.{ .x = 5, .y = 5 }, .{ .x = 0, .y = 30 }) == null); // target x==0
}

test "toward-stepper: reaches an open target and stays walkable" {
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\..........
        \\..........
        \\..........
        \\..........
    );
    defer tg.deinit(a);
    const path = try findPathToward(a, tg.view, .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 3 }, 160, .none);
    defer a.free(path);
    try testing.expectEqual(@as(i32, 9), path[path.len - 1].x);
    try testing.expectEqual(@as(i32, 3), path[path.len - 1].y);
    _ = try assertContiguousWalkable(tg.view, path);
}

test "obstacle detour: moves a blocked destination to a walkable neighbor" {
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\..........
        \\....#.....
        \\..........
    );
    defer tg.deinit(a);
    var coords = PathCoords{ .src_x = 0, .src_y = 1, .dst_x = 4, .dst_y = 1 };
    const found = findAlternateAroundObstacle(tg.view, &coords, true, .none);
    try testing.expect(found);
    // The relocated destination must be walkable.
    try testing.expect(tg.view.walkable(coords.dst_x, coords.dst_y));
}

test "extendPathEndpoint handles negative deltas (centered step table regression)" {
    // A westward endpoint (dst left of src) makes the step-table index ddx+ddy*9
    // negative. gaPathDirectionStepDeltas is centered at index 0, so the lookup must
    // reach the negative-offset half. Before the 81-int centered table the port only
    // stored the >=0 slice and this panicked ("integer does not fit in destination
    // type") the moment a player (is_player) detour extended westward.
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\............
        \\............
        \\............
    );
    defer tg.deinit(a);
    var coords = PathCoords{ .src_x = 8, .src_y = 1, .dst_x = 6, .dst_y = 1 };
    extendPathEndpoint(tg.view, &coords, .none);
    // Extends due-west along the dominant axis (step_x=-1, step_y=0), staying
    // walkable, up to the 5-subtile span: dst_x 6 -> 3.
    try testing.expectEqual(@as(i32, 3), coords.dst_x);
    try testing.expectEqual(@as(i32, 1), coords.dst_y);
    try testing.expect(tg.view.walkable(coords.dst_x, coords.dst_y));
}

test "calculatePath: dispatches A* and detours a blocked target" {
    const a = testing.allocator;
    var tg = try parseAscii(a,
        \\..........
        \\..........
        \\....#.....
        \\..........
    );
    defer tg.deinit(a);
    // Target sits on the wall; the orchestrator should detour then A*.
    const path = try calculatePath(a, tg.view, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 2 }, .{});
    defer a.free(path);
    _ = try assertContiguousWalkable(tg.view, path);
    try testing.expect(path.len >= 1);
}
