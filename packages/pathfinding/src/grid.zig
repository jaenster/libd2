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

pub const SUBTILES_PER_TILE: i32 = 5;

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

pub const Point = struct { x: i32, y: i32 };

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

/// One mask's derived view of a level. Owned by the `Level` that built it.
/// How much of the grid a unit occupies. The engine never tests a bare cell for a real unit:
/// `CheckCollision_BlockPlayer_Type` (0x64d910) and `CheckCollision_BlockAll_Width` (0x64d9b0)
/// dispatch on the unit's size and OR together every cell of its shape, so a big monster is
/// blocked by a gap a small one walks through.
pub const Footprint = enum {
    /// `COLLISION_UNIT_SIZE_POINT` / `COLLISION_PATTERN_NONE` — the cell alone.
    point,
    /// `COLLISION_UNIT_SIZE_SMALL` / the `*_SMALL_*` patterns — `CheckCollision_Cross`
    /// (0x64d100): the cell plus its four cardinal neighbours.
    cross,
    /// `COLLISION_UNIT_SIZE_BIG` / the `*_BIG_*` patterns — `CheckCollision_BoundingBox1`
    /// (0x64d4a0), which builds `[x-1, x+1] x [y-1, y+1]`.
    box3,
};

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

        for (self.clear, 0..) |*c, i| c.* = if (self.passableAt(i)) CLEARANCE_MAX else 0;

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

    /// Passable at a raw index — callers that already bounds-checked use this.
    pub inline fn passableAt(self: *const PassMap, cell: usize) bool {
        return self.bits[wordOf(cell)] & bitOf(cell) != 0;
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
                if (!self.passableAt(seed) or self.comp[seed] != NO_COMPONENT) continue;
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
                        if (!self.passableAt(ni) or self.comp[ni] != NO_COMPONENT) continue;
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
    cells: []const u16,
    w: i32,
    h: i32,
    mask: u16,
    footprint: Footprint,
) !PassMap {
    const n: usize = @intCast(w * h);
    std.debug.assert(cells.len == n);
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
        .bits = bits,
        .comp = comp,
        .comp_built = false,
        .comp_count = 0,
        .clear = clear,
        .clear_built = false,
    };
}

pub const Trace = struct {
    /// Where the walk stopped: the blocking cell when `blocked`, otherwise the destination.
    at: Point,
    blocked: bool,
};

/// Walk the line from `from` to `to`, stopping at the first cell `pm`'s mask rejects. Both
/// endpoints are tested, and a cell off the grid blocks — the engine's null-room case.
///
/// This is `Collision::TestCollision` (0x64e260) with the room walk collapsed, because a
/// `PassMap` is already one flat level-wide grid where the engine has to re-resolve the room at
/// every boundary. Same four cases (degenerate, vertical, horizontal, and Bresenham split on
/// which axis is major), same order — test the cell, then advance — so the same set of cells is
/// visited. Note the engine's own return is inverted: `TestCollision` yields TRUE for a HIT, and
/// `SKILLS_HasLineOfSight` (0x645910) is a one-line negation of it.
///
/// The mask lives in the `PassMap`, which is what makes this one function serve every caller the
/// engine has: line of sight with the caster's mask, a missile with `Colmask.missile_flight`, an
/// area-of-effect check with whatever the skill passes.
pub fn trace(pm: *const PassMap, from: Point, to: Point) Trace {
    var x = from.x;
    var y = from.y;
    const span_x = to.x - x;
    const span_y = to.y - y;
    const step_x: i32 = if (span_x < 0) -1 else 1;
    const step_y: i32 = if (span_y < 0) -1 else 1;
    const dx: i32 = if (span_x < 0) -span_x else span_x;
    const dy: i32 = if (span_y < 0) -span_y else span_y;

    if (dx < dy) {
        // Steep: y advances every step, x follows the error term.
        var err: i32 = 0;
        while (true) {
            if (!pm.passable(x, y)) return .{ .at = .{ .x = x, .y = y }, .blocked = true };
            if (y == to.y) return .{ .at = .{ .x = x, .y = y }, .blocked = false };
            y += step_y;
            err += dx;
            if (err >= dy) {
                err -= dy;
                x += step_x;
            }
        }
    }
    // Shallow, and the degenerate/axis-aligned cases fall out of it: when dy is 0 the error term
    // never fires and y never moves, and when both are 0 the first cell is also the last.
    var err: i32 = 0;
    while (true) {
        if (!pm.passable(x, y)) return .{ .at = .{ .x = x, .y = y }, .blocked = true };
        if (x == to.x) return .{ .at = .{ .x = x, .y = y }, .blocked = false };
        err += dy;
        x += step_x;
        if (err >= dx) {
            err -= dx;
            y += step_y;
        }
    }
}

/// `SKILLS_HasLineOfSight` (0x645910): is the line clear end to end?
pub fn hasLineOfSight(pm: *const PassMap, from: Point, to: Point) bool {
    return !trace(pm, from, to).blocked;
}

/// Shrink a point-passability bitset to a footprint's: a cell stays set only when every cell of
/// the shape centred on it is set. The engine ORs the shape's flags on every query; folding that
/// in once here keeps a neighbour test one bit lookup instead of five or nine. Cells off the grid
/// count as blocked, which is what the engine's out-of-room fallback amounts to.
fn erode(alloc: std.mem.Allocator, bits: []Word, w: i32, h: i32, footprint: Footprint) !void {
    const src = try alloc.dupe(Word, bits);
    defer alloc.free(src);
    @memset(bits, 0);

    const cross = [_][2]i32{ .{ 0, 0 }, .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    const box3 = [_][2]i32{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },  .{ 0, 0 },  .{ 1, 0 },
        .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
    };
    const shape: []const [2]i32 = switch (footprint) {
        .point => return,
        .cross => &cross,
        .box3 => &box3,
    };

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
    if (pm.passable(x, y)) return .{ .x = x, .y = y };
    var r: i32 = 1;
    while (r <= radius) : (r += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const dys = [_]i32{ -r, r };
            for (dys) |dy| {
                if (pm.passable(x + dx, y + dy)) return .{ .x = x + dx, .y = y + dy };
            }
        }
        var dy: i32 = -r + 1;
        while (dy <= r - 1) : (dy += 1) {
            const dxs = [_]i32{ -r, r };
            for (dxs) |ddx| {
                if (pm.passable(x + ddx, y + dy)) return .{ .x = x + ddx, .y = y + dy };
            }
        }
    }
    return null;
}
