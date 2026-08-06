//! A level's collision as the search sees it: the raw `u16` subtile grid, plus per-mask
//! derived views that make the actual searching cheap.
//!
//! The raw grid is what d2-drlg composites for a level (level-local subtiles, row-major,
//! `0xFFFF` where no room covers). Everything a search needs beyond that is a function of
//! (grid, mask), so it is computed once per mask and cached on the level:
//!
//!   * `bits` — one bit per subtile, set when the mask passes. A* reads this instead of the
//!     u16 grid, so the hot loop touches 1/16th the memory and stays in L2 on a big level.
//!   * `comp` — 8-connected component label per subtile. An unreachable goal is then a single
//!     array compare instead of a search that expands the entire reachable region before
//!     giving up, which is the difference between microseconds and tens of milliseconds on a
//!     failed query.
//!
//! Components use 8-connectivity because the engine's A* does: DRLGPATH_AStarExpandNode
//! (0x67a740) tests only the destination subtile of a diagonal step, never the two orthogonal
//! cells beside it, so a diagonal gap between two walls is passable and the component labelling
//! has to agree with that or `comp` would reject reachable goals.

const std = @import("std");
const collision = @import("d2-core").collision;
const wd = @import("d2-world");

pub const SUBTILES_PER_TILE: i32 = wd.SUBTILES_PER_TILE;

/// The furthest a single movement COMMAND may target, in subtiles, measured Chebyshev (per axis).
///
/// This is not a teleport rule — it is the packet layer, and it gates every "do this at x,y"
/// command alike: `SCMD_0x01_WalkToLocation` (0x5497e0), `SCMD_0x03_RunToLocation` (0x5498d0) and
/// the skill-on-location handlers all route through `CheckIfInrangeAndReassign` (0x5496f0), which
/// calls `CheckIfCoordsAreInRange(pUnit, 0x32, x, y)` (0x548ef0, `MOV EBX,0x32` at 0x549742).
///
/// Over the limit the command is DROPPED — the handler returns before doing anything — and the
/// server sends `0x15` ReassignPlayer to snap the client back to where it thinks you are. So a
/// mover that emits a waypoint 100 subtiles away does not walk there slowly; it does not move at
/// all, and it desyncs. Emitted waypoints must respect this.
///
/// (It is roughly the screen radius, which is why a human clicking can never exceed it.)
pub const ENGINE_MAX_COMMAND_RANGE: i32 = 50;

/// What a mover should actually cap its steps at, rather than the raw gate.
///
/// The gate is evaluated against the SERVER'S view of your position, and while you are moving that
/// view lags yours: your own click applies locally at once, the server learns of it a round-trip
/// later and is still stepping you along the previous order in the meantime. So the origin the
/// server measures from is behind the origin you measured from, and a step you computed as 49 can
/// arrive as 60-something and be thrown out — taking a `0x15` resync with it, which is precisely
/// the stutter this is meant to avoid.
///
/// Leaving ten subtiles of slack absorbs ordinary latency. It is not a magic number; it is the
/// same margin the established bots settled on, and this is the reason for it.
pub const SAFE_COMMAND_STEP: i32 = 40;

pub const Point = wd.Point;

/// The passability bitset packs one subtile per bit. Both helpers divide by a power-of-two
/// constant, so they compile to the same shift-and-mask the hand-written version was — they just
/// say which is the word index and which is the bit inside it.
const Word = u64;
const bits_per_word = @bitSizeOf(Word);

inline fn wordOf(cell: usize) usize {
    return cell / bits_per_word;
}

inline fn bitOf(cell: usize) Word {
    return @as(Word, 1) << @intCast(cell % bits_per_word);
}

/// How much of the grid a unit occupies. The engine never tests a bare cell for a real unit:
/// `CheckCollision_BlockPlayer_Type` (0x64d910) and `CheckCollision_BlockAll_Width` (0x64d9b0)
/// dispatch on the unit's size and OR together every cell of its shape, so a big monster is
/// blocked by a gap a small one walks through.
/// It is `eD2CollisionUnitSize` itself, from d2-core: the size a unit STAMPS with and the size it
/// is CHECKED with are one field on the unit, and modelling them as two types here would let a
/// caller pair a small monster's occupancy with a big monster's passability.
pub const Footprint = collision.Size;

pub const PassMap = struct {
    mask: u16,
    footprint: Footprint,
    w: i32,
    h: i32,
    /// 1 = a unit with this mask may occupy the subtile.
    bits: []Word,
    /// 8-connected region label, `NO_COMPONENT` where impassable. Lazily built.
    comp: []u32,
    comp_built: bool,
    comp_count: u32,
    /// Chebyshev distance from each cell to the nearest impassable cell, saturating at
    /// `CLEARANCE_MAX`. 0 on an impassable cell, 1 on one that touches a wall. Lazily built.
    clear: []u8,
    clear_built: bool,
    /// The level this is a view of. Everything above this line is derived from `level.cells` and
    /// cached; everything the level knows about UNITS is not cached anywhere, because it changes on
    /// every monster step, and is consulted per cell by `passableAt`.
    ///
    /// That split is what keeps `comp` and `clear` valid — they never see a unit — and it is safe
    /// because occupancy only ever ADDS blockage, so `comp` remains an exact "these two cells can
    /// never be connected" test. Terrain edits DO invalidate them, which is what `terrain_gen`
    /// catches: see `Nav.passMapFor`.
    level: *const wd.Level,
    /// The level's `terrain_gen` when `bits` was last built.
    terrain_gen: u64 = 0,

    pub const NO_COMPONENT: u32 = 0;

    /// Clearance saturates here: beyond a few subtiles "far from a wall" is far enough, and one
    /// byte per cell keeps the map cheap next to the collision grid itself.
    pub const CLEARANCE_MAX: u8 = 15;

    pub fn deinit(self: *PassMap, alloc: std.mem.Allocator) void {
        alloc.free(self.bits);
        alloc.free(self.comp);
        alloc.free(self.clear);
        self.* = undefined;
    }

    /// Build (or return) the clearance map: for every cell, how far it is from the nearest wall.
    ///
    /// Two chamfer passes over the grid — forward taking the min of the already-settled neighbours
    /// plus one, backward doing the same from the other corner — which is the standard way to get
    /// an exact Chebyshev distance transform in O(n) without a queue. Out-of-bounds counts as wall,
    /// so the level border pushes paths inward like any other.
    pub fn clearance(self: *PassMap) []const u8 {
        if (self.clear_built) return self.clear;
        const w: usize = @intCast(self.w);
        const h: usize = @intCast(self.h);

        for (self.clear, 0..) |*c, i| c.* = if (self.staticPassableAt(i)) CLEARANCE_MAX else 0;

        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const i = y * w + x;
                if (self.clear[i] == 0) continue;
                // Out of bounds is wall: a missing neighbour contributes 0, giving this cell 1.
                var best: u8 = if (y == 0 or x == 0 or x + 1 == w) 0 else CLEARANCE_MAX;
                if (y > 0) {
                    best = @min(best, self.clear[i - w]);
                    if (x > 0) best = @min(best, self.clear[i - w - 1]);
                    if (x + 1 < w) best = @min(best, self.clear[i - w + 1]);
                }
                if (x > 0) best = @min(best, self.clear[i - 1]);
                self.clear[i] = @min(self.clear[i], best +| 1);
            }
        }
        y = h;
        while (y > 0) {
            y -= 1;
            var x: usize = w;
            while (x > 0) {
                x -= 1;
                const i = y * w + x;
                if (self.clear[i] == 0) continue;
                var best: u8 = if (y + 1 == h or x + 1 == w or x == 0) 0 else CLEARANCE_MAX;
                if (y + 1 < h) {
                    best = @min(best, self.clear[i + w]);
                    if (x > 0) best = @min(best, self.clear[i + w - 1]);
                    if (x + 1 < w) best = @min(best, self.clear[i + w + 1]);
                }
                if (x + 1 < w) best = @min(best, self.clear[i + 1]);
                self.clear[i] = @min(self.clear[i], best +| 1);
            }
        }

        self.clear_built = true;
        return self.clear;
    }

    pub inline fn index(self: *const PassMap, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * @as(usize, @intCast(self.w)) + @as(usize, @intCast(x));
    }

    pub inline fn inBounds(self: *const PassMap, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.w and y < self.h;
    }

    /// Passable as far as TERRAIN is concerned, at a raw index, with the footprint already folded
    /// in. This is what `comp` and `clear` are built from — they must not see the live world, or a
    /// monster taking one step would invalidate a cache that costs a full pass to rebuild.
    pub inline fn staticPassableAt(self: *const PassMap, cell: usize) bool {
        return self.bits[wordOf(cell)] & bitOf(cell) != 0;
    }

    pub inline fn staticPassable(self: *const PassMap, x: i32, y: i32) bool {
        return self.inBounds(x, y) and self.staticPassableAt(self.index(x, y));
    }

    /// Passable at a raw index — callers that already bounds-checked use this.
    ///
    /// Terrain first, because it is one bit test and it rejects most of the grid; only then the
    /// live world, which is itself one bit test in the overwhelmingly common "nobody here" case.
    pub inline fn passableAt(self: *const PassMap, cell: usize) bool {
        if (!self.staticPassableAt(cell)) return false;
        const units = &self.level.units;
        if (units.isEmpty()) return true;
        return !self.liveBlocked(units, cell);
    }

    /// A footprint's worth of live world. The static side pre-eroded the footprint into `bits` once
    /// at build time; the live side cannot, so the shape is walked here — the engine ORs it too
    /// (`CheckCollision_BlockAll_Width`, 0x64d9b0). Cells off the grid are skipped rather than
    /// treated as blocking, because erosion already rejected any cell whose shape leaves the grid.
    fn liveBlocked(self: *const PassMap, units: *const wd.Occupancy, cell: usize) bool {
        if (self.footprint == .point) return units.blocks(cell, self.mask);
        const uw: usize = @intCast(self.w);
        const x: i32 = @intCast(cell % uw);
        const y: i32 = @intCast(cell / uw);
        for (collision.cellsOf(self.footprint)) |d| {
            const nx = x + d[0];
            const ny = y + d[1];
            if (!self.inBounds(nx, ny)) continue;
            if (units.blocks(self.index(nx, ny), self.mask)) return true;
        }
        return false;
    }

    /// Rebuild the terrain bitset over a rectangle whose raw cells changed, and drop the caches
    /// derived from it. Terrain edits can make a cell MORE passable, which can join two components,
    /// so `comp` and `clear` go rather than being patched.
    ///
    /// The bounds are inclusive and name the CHANGED cells; footprint erosion means a neighbour's
    /// bit can change too, so the rebuild covers one extra ring.
    pub fn repatch(self: *PassMap, x0: i32, y0: i32, x1: i32, y1: i32) void {
        const pad: i32 = if (self.footprint == .point) 0 else 1;
        const lo_x = @max(0, x0 - pad);
        const hi_x = @min(self.w - 1, x1 + pad);
        const lo_y = @max(0, y0 - pad);
        const hi_y = @min(self.h - 1, y1 + pad);
        var y = lo_y;
        while (y <= hi_y) : (y += 1) {
            var x = lo_x;
            while (x <= hi_x) : (x += 1) {
                const i = self.index(x, y);
                if (self.footprintFits(x, y)) {
                    self.bits[wordOf(i)] |= bitOf(i);
                } else {
                    self.bits[wordOf(i)] &= ~bitOf(i);
                }
            }
        }
        self.comp_built = false;
        self.clear_built = false;
    }

    /// Does every cell of the footprint centred here pass the mask? The same predicate `erode`
    /// applies in bulk at build time, spelled once more for the incremental path.
    fn footprintFits(self: *const PassMap, x: i32, y: i32) bool {
        const cells = self.level.cells;
        for (collision.cellsOf(self.footprint)) |d| {
            const nx = x + d[0];
            const ny = y + d[1];
            if (!self.inBounds(nx, ny)) return false;
            if (!collision.passable(cells[self.index(nx, ny)], self.mask)) return false;
        }
        return true;
    }

    pub inline fn passable(self: *const PassMap, x: i32, y: i32) bool {
        return self.inBounds(x, y) and self.passableAt(self.index(x, y));
    }

    /// Build (or return) the component labelling. Iterative flood fill over a reused stack, so a
    /// 1000x1000 level costs one pass and no recursion.
    pub fn components(self: *PassMap, alloc: std.mem.Allocator) ![]const u32 {
        if (self.comp_built) return self.comp;
        @memset(self.comp, NO_COMPONENT);

        var stack: std.ArrayListUnmanaged(u32) = .empty;
        defer stack.deinit(alloc);

        var next_label: u32 = NO_COMPONENT;
        var y: i32 = 0;
        while (y < self.h) : (y += 1) {
            var x: i32 = 0;
            while (x < self.w) : (x += 1) {
                const seed = self.index(x, y);
                if (!self.staticPassableAt(seed) or self.comp[seed] != NO_COMPONENT) continue;
                next_label += 1;
                self.comp[seed] = next_label;
                try stack.append(alloc, @intCast(seed));
                while (stack.pop()) |cur| {
                    const cx: i32 = @intCast(@as(u32, @intCast(cur)) % @as(u32, @intCast(self.w)));
                    const cy: i32 = @intCast(@as(u32, @intCast(cur)) / @as(u32, @intCast(self.w)));
                    for (NEIGHBOURS) |d| {
                        const nx = cx + d[0];
                        const ny = cy + d[1];
                        if (!self.inBounds(nx, ny)) continue;
                        const ni = self.index(nx, ny);
                        if (!self.staticPassableAt(ni) or self.comp[ni] != NO_COMPONENT) continue;
                        self.comp[ni] = next_label;
                        try stack.append(alloc, @intCast(ni));
                    }
                }
            }
        }
        self.comp_count = next_label;
        self.comp_built = true;
        return self.comp;
    }
};

/// The eight step directions, in the engine's order (E, SE, S, SW, W, NW, N, NE as x/y deltas).
pub const NEIGHBOURS = [8][2]i32{
    .{ 1, 0 },  .{ 1, 1 },   .{ 0, 1 },  .{ -1, 1 },
    .{ -1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
};

/// Move costs from DRLGPATH_AStarExpandNode (0x67a740): a straight step costs 2, a diagonal 3.
pub const COST_STRAIGHT: u32 = 2;
pub const COST_DIAGONAL: u32 = 3;

/// The engine's heuristic, `min(|dx|,|dy|) + 2*max(|dx|,|dy|)`. With costs 2/3 this is the exact
/// free-space distance (3*min + 2*(max-min)), so it is admissible AND consistent — A* expands the
/// minimum possible number of nodes on open terrain.
pub inline fn heuristic(ax: i32, ay: i32, bx: i32, by: i32) u32 {
    const dx: u32 = @intCast(@abs(ax - bx));
    const dy: u32 = @intCast(@abs(ay - by));
    return @min(dx, dy) + 2 * @max(dx, dy);
}

/// Build the passability bitset for `mask` over `cells`. Cells are the level-local u16 composite;
/// `collision.VOID` fails naturally because it has every bit set.
pub fn buildPassMap(
    alloc: std.mem.Allocator,
    level: *const wd.Level,
    mask: u16,
    footprint: Footprint,
) !PassMap {
    const cells = level.cells;
    const w = level.w;
    const h = level.h;
    const n: usize = @intCast(w * h);
    const bits = try alloc.alloc(Word, std.math.divCeil(usize, n, bits_per_word) catch unreachable);
    errdefer alloc.free(bits);
    @memset(bits, 0);

    for (cells, 0..) |cell, i| {
        if (collision.passable(cell, mask)) bits[wordOf(i)] |= bitOf(i);
    }
    if (footprint != .point) try erode(alloc, bits, w, h, footprint);

    const comp = try alloc.alloc(u32, n);
    errdefer alloc.free(comp);
    const clear = try alloc.alloc(u8, n);
    errdefer alloc.free(clear);

    return .{
        .mask = mask,
        .footprint = footprint,
        .w = w,
        .h = h,
        .level = level,
        .terrain_gen = level.terrain_gen,
        .bits = bits,
        .comp = comp,
        .comp_built = false,
        .comp_count = 0,
        .clear = clear,
        .clear_built = false,
    };
}

/// Shrink a point-passability bitset to a footprint's: a cell stays set only when every cell of
/// the shape centred on it is set. The engine ORs the shape's flags on every query; folding that
/// in once here keeps a neighbour test one bit lookup instead of five or nine. Cells off the grid
/// count as blocked, which is what the engine's out-of-room fallback amounts to.
fn erode(alloc: std.mem.Allocator, bits: []Word, w: i32, h: i32, footprint: Footprint) !void {
    const src = try alloc.dupe(Word, bits);
    defer alloc.free(src);
    @memset(bits, 0);

    if (footprint == .point or footprint == .none) return;
    const shape = collision.cellsOf(footprint);

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const fits = for (shape) |d| {
                const nx = x + d[0];
                const ny = y + d[1];
                if (nx < 0 or ny < 0 or nx >= w or ny >= h) break false;
                const j: usize = @intCast(ny * w + nx);
                if (src[wordOf(j)] & bitOf(j) == 0) break false;
            } else true;
            if (fits) {
                const i: usize = @intCast(y * w + x);
                bits[wordOf(i)] |= bitOf(i);
            }
        }
    }
}

/// Nearest passable subtile to (x,y) within `radius`, searched in rings so the first hit is the
/// closest. Returns null when nothing within the radius passes. This is our stand-in for the
/// engine's `GetFreeCoordinates_WithNeighboorRooms` snap (0x64c2b0 family): callers hand us a
/// requested position — a warp tile, a teleport landing, a caller's goal — that may sit inside a
/// wall, and the search needs a real cell to start or end on.
pub fn nearestPassable(pm: *const PassMap, x: i32, y: i32, radius: i32) ?Point {
    return nearestWhere(pm, x, y, radius, false);
}

/// `nearestPassable` over terrain alone. Anything CACHED has to use this: a cache that snapped
/// around a monster would still be pointing there after the monster walked off.
pub fn nearestStaticPassable(pm: *const PassMap, x: i32, y: i32, radius: i32) ?Point {
    return nearestWhere(pm, x, y, radius, true);
}

fn nearestWhere(pm: *const PassMap, x: i32, y: i32, radius: i32, comptime terrain_only: bool) ?Point {
    const S = struct {
        pm: *const PassMap,
        fn ok(ctx: @This(), cx: i32, cy: i32) bool {
            return if (terrain_only) ctx.pm.staticPassable(cx, cy) else ctx.pm.passable(cx, cy);
        }
    };
    // Same ring order as `Level.nearestFree`, shared rather than restated: the cached answer and
    // the direct one must not disagree about which cell is "nearest".
    return wd.ringSearch(S{ .pm = pm }, x, y, radius, S.ok);
}
