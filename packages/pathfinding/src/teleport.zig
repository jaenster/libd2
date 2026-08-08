//! Teleport routing, under the engine's actual rules — both of them.
//!
//! A cast has to pass TWO independent gates, enforced in different places, and a router that
//! models only one of them plans casts that silently fail.
//!
//! **Gate 1 — distance, at the packet handler.** The skill code itself has no range check:
//! `Skills_SrvDoFunc_027_Teleport` (0x5ca360) hands the cursor position straight to
//! `SUNIT_RelocateUnit` (0x554ea0), and neither looks at distance. The limit lives one layer up, in
//! the packet handlers that receive the cast — `SCMD_0x05_LeftSkillOnLocation` (0x549d00) and
//! `SCMD_0x0C_RightSkillOnLocation` (0x549fc0). Both route through
//! `CheckIfInrangeAndReassign` (0x5496f0), which calls:
//!
//!     CheckIfCoordsAreInRange(pUnit, 0x32, nX, nY)          // 0x548ef0
//!         |dx| <= 50 && |dy| <= 50   (per axis, against GetXPos/GetYPos)
//!
//! and on failure RETURNS EARLY — the caller checks the status before ever reaching the skill, so
//! the cast never happens. It also sends packet 0x15 ReassignPlayer to snap the client back. The
//! decompiler's own note on that function calls it a guard "against teleport/warp exploits".
//!
//! So the real limit is **Chebyshev distance 50 in SUBTILES** — per axis, not radial. That is a
//! materially bigger reach than the folklore "about 40": a pure diagonal cast may span (50,50),
//! which is ~70 subtiles of actual distance. Treating the limit as a radius costs you casts.
//! (Units confirmed: the packet x/y are compared against `GetXPos(pDynamicPath)`, and the same
//! coordinates go to `SUNIT_RelocateUnit` -> `FindBetterNearbyRoom`, which tests them against the
//! runtime room's subtile-resolution `sCoords`.)
//!
//! **Gate 2 — topology, at the relocate.** `SUNIT_RelocateUnit` resolves the destination room via
//! `DRLGROOM_FindBetterNearbyRoom` (0x463740): your own room, or a room in its adjacent list, or
//! the cast fails. See rooms.zig. On a standard 8x8-tile room this is looser than gate 1, but on
//! small dungeon rooms it is the binding one — which is why both are checked.
//!
//! Why 39/40 is the number people use: it is a safety margin under gate 1. The server compares
//! against ITS view of your position, which lags the client's, so casting at exactly 50 risks a
//! rejection and a resync. `max_cast` defaults to the engine's own 50; lower it for margin.
//!
//! Cost is the number of CASTS, not distance — that is what a teleporting character actually
//! pays, in mana and in time — so the search minimises hops.
//!
//! Two searches, because the shape of the problem changes with the distance option:
//!   * bounded — A* over the level's TILE grid (25x fewer nodes than subtiles), where each tile
//!     carries a precomputed legal landing subtile and a hop must clear both gates.
//!   * unbounded (`max_cast = null`, gate 2 only) — one cast then reaches ANY cell of an adjacent
//!     room, so the problem collapses to breadth-first search over the room adjacency graph, which
//!     has tens of nodes instead of tens of thousands.

const std = @import("std");
const grid = @import("grid.zig");
const wd = @import("d2-world");
const rooms = wd.rooms;
const level_mod = wd.level;
const Nav = @import("nav.zig").Nav;
const collision = @import("d2-core").collision;

const Level = level_mod.Level;
pub const Point = grid.Point;

pub const Error = error{
    /// Levels.txt `Teleport` is 0 for this level: the server refuses the skill outright.
    Forbidden,
    StartBlocked,
    GoalBlocked,
    /// Start or goal sits in the gap between rooms, where `FindBetterNearbyRoom` finds nothing.
    OutsideAnyRoom,
    /// No chain of adjacent rooms connects the two positions.
    Unreachable,
    NodeLimit,
} || std.mem.Allocator.Error;

/// The cast gate. It is not teleport-specific — it is the packet layer's command range, which
/// gates walk and run the same way; see `grid.ENGINE_MAX_COMMAND_RANGE`.
pub const ENGINE_MAX_CAST: i32 = grid.ENGINE_MAX_COMMAND_RANGE;

/// How a cast's length is measured against `max_cast`.
pub const Metric = enum {
    /// What the engine does: `max(|dx|,|dy|) <= max_cast`, per axis. The legal region is a SQUARE,
    /// so a diagonal cast reaches `max_cast * sqrt(2)` of actual ground.
    chebyshev,
    /// What a bot that computes a distance does: `sqrt(dx^2+dy^2) <= max_cast`. The legal region is
    /// a DISK inscribed in the engine's square, so this is strictly more conservative — it never
    /// produces an illegal cast, it just declines legal ones. Provided to measure what the
    /// widespread "teleport 40" convention actually costs.
    euclidean,

    pub fn within(self: Metric, ax: i32, ay: i32, bx: i32, by: i32, max_cast: i32) bool {
        const dx: i64 = ax - bx;
        const dy: i64 = ay - by;
        return switch (self) {
            .chebyshev => @max(@abs(dx), @abs(dy)) <= max_cast,
            .euclidean => dx * dx + dy * dy <= @as(i64, max_cast) * @as(i64, max_cast),
        };
    }

    /// Distance under this metric, for the search heuristic. Must not overestimate, or A* stops
    /// being admissible.
    pub fn distance(self: Metric, ax: i32, ay: i32, bx: i32, by: i32) u32 {
        const dx: i64 = ax - bx;
        const dy: i64 = ay - by;
        return switch (self) {
            .chebyshev => @intCast(@max(@abs(dx), @abs(dy))),
            .euclidean => @intCast(std.math.sqrt(@as(u64, @intCast(dx * dx + dy * dy)))),
        };
    }
};

pub const Options = struct {
    /// Maximum CHEBYSHEV cast distance in subtiles (`max(|dx|,|dy|)`), matching
    /// `CheckIfCoordsAreInRange`. Lower it below the engine's 50 to leave margin for server/client
    /// position lag.
    ///
    /// Null drops gate 1 entirely and leaves only the room rule. Such a route WILL contain casts a
    /// real server rejects outright (packet dropped, position resynced) — it answers "what would
    /// the relocate code alone permit", and must not be used to drive a character.
    max_cast: ?i32 = ENGINE_MAX_CAST,
    /// Which shape `max_cast` describes. Defaults to the engine's per-axis test.
    metric: Metric = .chebyshev,
    /// Landing-cell collision mask. `SUNIT_RelocateUnit` snaps with COLMASK_PLAYER_PATH; a
    /// `.gated` level ORs in `COLMASK_PLAYER_FLYING` (0x804) on top (see `TeleportRule`).
    landing_mask: u16 = collision.Colmask.player_path,
    /// Accept a passable cell this far from a blocked start, as the engine's
    /// `GetFreeCoordinates_WithNeighboorRooms` snap does.
    snap_radius: i32 = 8,
    /// The same for the goal; null follows `snap_radius`. Split because a route's goal is often an
    /// approximate level-transition tile while its start is an exact position.
    goal_snap_radius: ?i32 = null,
    max_nodes: u32 = 500_000,
};

/// Chebyshev (max-norm) subtile distance — the metric `CheckIfCoordsAreInRange` (0x548ef0) applies,
/// which tests each axis separately rather than the radial distance.
pub inline fn chebyshev(ax: i32, ay: i32, bx: i32, by: i32) i32 {
    return @max(@as(i32, @intCast(@abs(ax - bx))), @as(i32, @intCast(@abs(ay - by))));
}

/// Would the packet handler accept a cast from `from` to `to`? This is gate 1 on its own, exactly
/// as `CheckIfCoordsAreInRange` (0x548ef0) spells it:
///
///     |dx| <= nRange && |dy| <= nRange        with nRange = 0x32 (MOV EBX,0x32 at 0x549742)
///
/// Note the comparison is INCLUSIVE — a cast of exactly 50 on an axis is accepted.
pub inline fn withinCastGate(from: Point, to: Point, max_cast: i32) bool {
    return Metric.chebyshev.within(from.x, from.y, to.x, to.y, max_cast);
}

/// Squared Euclidean subtile distance. Not a gate — only used to break ties when picking the
/// landing cell nearest a room's centre.
inline fn dist2(ax: i32, ay: i32, bx: i32, by: i32) i64 {
    const dx: i64 = ax - bx;
    const dy: i64 = ay - by;
    return dx * dx + dy * dy;
}

/// Append the landing spots of a teleport route from (sx,sy) to (gx,gy) to `out`. The first entry
/// is the (snapped) start; every later entry is one cast. Both coordinate pairs are level-local
/// subtiles.
pub fn find(
    alloc: std.mem.Allocator,
    nv: *Nav,
    sx: i32,
    sy: i32,
    gx: i32,
    gy: i32,
    opts: Options,
    out: *std.ArrayListUnmanaged(Point),
) Error!void {
    const level = nv.lv;
    if (level.teleport == .forbidden) return error.Forbidden;
    const mask = level.teleport.destinationMask(opts.landing_mask);

    const pm = try nv.passMap(mask);
    const start = grid.nearestPassable(pm, sx, sy, opts.snap_radius) orelse return error.StartBlocked;
    const goal = grid.nearestPassable(pm, gx, gy, opts.goal_snap_radius orelse opts.snap_radius) orelse
        return error.GoalBlocked;

    const start_room = level.rooms.atSubtile(start.x, start.y) orelse return error.OutsideAnyRoom;
    const goal_room = level.rooms.atSubtile(goal.x, goal.y) orelse return error.OutsideAnyRoom;

    try out.append(alloc, start);
    if (start.x == goal.x and start.y == goal.y) return;

    // One cast is enough whenever the goal clears both gates.
    if (canHop(level, start, goal, start_room, goal_room, opts.max_cast, opts.metric)) {
        try out.append(alloc, goal);
        return;
    }

    if (opts.max_cast) |max_cast| {
        // A non-positive limit means no cast can ever move you, and it would divide by zero in the
        // heuristic. The direct check above already covered "the goal is where you stand".
        if (max_cast <= 0) return error.Unreachable;
        return findBounded(alloc, nv, pm, start, goal, start_room, goal_room, max_cast, opts, out);
    }
    return findByRoom(alloc, level, pm, goal, start_room, goal_room, out);
}

/// Is a single cast from `from` to `to` legal? Both gates: the packet handler's per-axis distance
/// limit, and the room topology `SUNIT_RelocateUnit` enforces.
fn canHop(level: *const Level, from: Point, to: Point, from_room: u16, to_room: u16, max_cast: ?i32, metric: Metric) bool {
    if (max_cast) |m| {
        if (!metric.within(from.x, from.y, to.x, to.y, m)) return false;
    }
    return level.rooms.canTeleportBetween(from_room, to_room);
}

/// A* over tiles, one unit of cost per cast.
fn findBounded(
    alloc: std.mem.Allocator,
    nv: *Nav,
    pm: *grid.PassMap,
    start: Point,
    goal: Point,
    start_room: u16,
    goal_room: u16,
    max_cast: i32,
    opts: Options,
    out: *std.ArrayListUnmanaged(Point),
) Error!void {
    // Both ends have to be in the same walk-or-teleport region for any chain to exist. Teleport
    // crosses walls, so it is the ROOM graph that has to connect, not the collision components.
    const level = nv.lv;
    const reps = try nv.tileReps(pm.mask);
    const tw = level.tileW();
    const th = level.tileH();
    const node_count: usize = @intCast(@max(tw * th, 0));

    // The tile offsets a cast can reach. Because the gate is CHEBYSHEV, this is a SQUARE, not a
    // disk — the corners are legal, and they are where the reach is greatest (a (50,50) cast covers
    // ~70 subtiles of ground). A tile is a candidate when its nearest corner is within the limit on
    // both axes; the exact per-cell distance is re-checked against the real landing subtiles.
    const metric = opts.metric;
    const reach_tiles = @divTrunc(max_cast, grid.SUBTILES_PER_TILE) + 1;
    var offsets: std.ArrayListUnmanaged([2]i32) = .empty;
    defer offsets.deinit(alloc);
    {
        var dy: i32 = -reach_tiles;
        while (dy <= reach_tiles) : (dy += 1) {
            var dx: i32 = -reach_tiles;
            while (dx <= reach_tiles) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                // `@abs` on a signed int yields an unsigned one, so the -1 has to happen in
                // signed arithmetic or a zero delta wraps.
                const adx: i32 = @intCast(@abs(dx));
                const ady: i32 = @intCast(@abs(dy));
                const near_x = @max(adx - 1, 0) * grid.SUBTILES_PER_TILE;
                const near_y = @max(ady - 1, 0) * grid.SUBTILES_PER_TILE;
                if (!metric.within(0, 0, near_x, near_y, max_cast)) continue;
                try offsets.append(alloc, .{ dx, dy });
            }
        }
    }

    const g = try alloc.alloc(u32, node_count);
    defer alloc.free(g);
    const came = try alloc.alloc(i32, node_count);
    defer alloc.free(came);
    @memset(g, std.math.maxInt(u32));
    @memset(came, -1);

    var heap: std.ArrayListUnmanaged(u64) = .empty;
    defer heap.deinit(alloc);

    // Lower bound on the casts still needed: each one closes at most `max_cast` on the wider axis.
    // Admissible and consistent, so no node is ever re-expanded.
    const castsTo = struct {
        fn h(from: Point, to: Point, m: i32, mt: Metric) u32 {
            return std.math.divCeil(u32, mt.distance(from.x, from.y, to.x, to.y), @intCast(m)) catch 0;
        }
    }.h;

    // Seed: every tile reachable from the start cell in one cast.
    var seeded: usize = 0;
    for (offsets.items) |d| {
        const tx = @divFloor(start.x, grid.SUBTILES_PER_TILE) + d[0];
        const ty = @divFloor(start.y, grid.SUBTILES_PER_TILE) + d[1];
        if (tx < 0 or ty < 0 or tx >= tw or ty >= th) continue;
        const ti: usize = @intCast(ty * tw + tx);
        const land = repPoint(pm, reps, ti) orelse continue;
        const land_room = level.rooms.atSubtile(land.x, land.y) orelse continue;
        if (!canHop(level, start, land, start_room, land_room, max_cast, opts.metric)) continue;
        if (g[ti] <= 1) continue;
        g[ti] = 1;
        came[ti] = -1; // parent is the start cell
        try push(alloc, &heap, 1 + castsTo(land, goal, max_cast, metric), @intCast(ti));
        seeded += 1;
    }
    if (seeded == 0) return error.Unreachable;

    var expanded: u32 = 0;
    while (pop(&heap)) |entry| {
        const cur: usize = @intCast(entry & 0xFFFF_FFFF);
        const cur_g = g[cur];
        if (@as(u32, @intCast(entry >> 32)) != cur_g + castsTo(repPoint(pm, reps, cur).?, goal, max_cast, metric)) continue;

        const cur_pt = repPoint(pm, reps, cur).?;
        const cur_room = level.rooms.atSubtile(cur_pt.x, cur_pt.y).?;
        if (canHop(level, cur_pt, goal, cur_room, goal_room, max_cast, opts.metric)) {
            try emit(alloc, pm, reps, came, cur, out);
            try out.append(alloc, goal);
            return;
        }

        expanded += 1;
        if (expanded > opts.max_nodes) return error.NodeLimit;

        const cx: i32 = @intCast(cur % @as(usize, @intCast(tw)));
        const cy: i32 = @intCast(cur / @as(usize, @intCast(tw)));
        for (offsets.items) |d| {
            const tx = cx + d[0];
            const ty = cy + d[1];
            if (tx < 0 or ty < 0 or tx >= tw or ty >= th) continue;
            const ni: usize = @intCast(ty * tw + tx);
            if (g[ni] <= cur_g + 1) continue;
            const land = repPoint(pm, reps, ni) orelse continue;
            const land_room = level.rooms.atSubtile(land.x, land.y) orelse continue;
            if (!canHop(level, cur_pt, land, cur_room, land_room, max_cast, opts.metric)) continue;
            g[ni] = cur_g + 1;
            came[ni] = @intCast(cur);
            try push(alloc, &heap, cur_g + 1 + castsTo(land, goal, max_cast, metric), @intCast(ni));
        }
    }
    return error.Unreachable;
}

fn repPoint(pm: *const grid.PassMap, reps: []const i32, tile: usize) ?Point {
    const cell = reps[tile];
    if (cell < 0) return null;
    const c: usize = @intCast(cell);
    return .{
        .x = @intCast(c % @as(usize, @intCast(pm.w))),
        .y = @intCast(c / @as(usize, @intCast(pm.w))),
    };
}

fn emit(
    alloc: std.mem.Allocator,
    pm: *const grid.PassMap,
    reps: []const i32,
    came: []const i32,
    last: usize,
    out: *std.ArrayListUnmanaged(Point),
) Error!void {
    const first = out.items.len;
    var cur: i32 = @intCast(last);
    while (cur >= 0) {
        try out.append(alloc, repPoint(pm, reps, @intCast(cur)).?);
        cur = came[@intCast(cur)];
    }
    std.mem.reverse(Point, out.items[first..]);
}

/// No distance gate: one cast reaches anywhere in an adjacent room, so the minimum number of casts
/// is the breadth-first distance in the room adjacency graph. A level has tens to a few hundred
/// rooms, so this is effectively free.
fn findByRoom(
    alloc: std.mem.Allocator,
    level: *Level,
    pm: *grid.PassMap,
    goal: Point,
    start_room: u16,
    goal_room: u16,
    out: *std.ArrayListUnmanaged(Point),
) Error!void {
    const n = level.rooms.rooms.len;
    const came = try alloc.alloc(i32, n);
    defer alloc.free(came);
    @memset(came, -2); // -2 unvisited, -1 root

    // A room with nowhere legal to stand cannot be a step in the chain — walking THROUGH it is not
    // a thing teleport does, every hop has to land. Resolving each room's landing up front (and
    // refusing to enqueue the ones with none) keeps the chain and the emitted casts in agreement;
    // dropping such a room later would silently join two rooms that are not adjacent.
    const landing = try alloc.alloc(?Point, n);
    defer alloc.free(landing);
    for (landing, 0..) |*l, i| l.* = landingInRoom(pm, level.rooms.rooms[i]);

    var queue: std.ArrayListUnmanaged(u16) = .empty;
    defer queue.deinit(alloc);
    came[start_room] = -1;
    try queue.append(alloc, start_room);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const r = queue.items[head];
        if (r == goal_room) break;
        for (level.rooms.nearOf(r)) |nb| {
            if (came[nb] != -2) continue;
            if (nb != goal_room and landing[nb] == null) continue;
            came[nb] = @intCast(r);
            try queue.append(alloc, nb);
        }
    }
    if (came[goal_room] == -2) return error.Unreachable;

    // Walk the room chain back, then forward, landing in each room on the passable cell nearest
    // its centre. The final hop is the goal itself.
    var chain: std.ArrayListUnmanaged(u16) = .empty;
    defer chain.deinit(alloc);
    var cur: i32 = @intCast(goal_room);
    while (cur >= 0) {
        try chain.append(alloc, @intCast(cur));
        cur = came[@intCast(cur)];
    }
    std.mem.reverse(u16, chain.items);

    // chain[0] is the start room (already emitted as `start`) and the last is the goal room,
    // which the goal itself covers.
    // Every room in the chain was checked to have a landing before it was enqueued, so these are
    // all present — and each is INSIDE its own room, which is what keeps consecutive casts
    // adjacent.
    for (chain.items[1 .. chain.items.len - 1]) |room_id| {
        try out.append(alloc, landing[room_id].?);
    }
    try out.append(alloc, goal);
}

/// The passable subtile closest to a room's centre, searched only within the room's own extent.
fn landingInRoom(pm: *const grid.PassMap, box: rooms.Room) ?Point {
    const x0 = box.x * grid.SUBTILES_PER_TILE;
    const y0 = box.y * grid.SUBTILES_PER_TILE;
    const x1 = x0 + box.w * grid.SUBTILES_PER_TILE;
    const y1 = y0 + box.h * grid.SUBTILES_PER_TILE;
    const cx = @divTrunc(x0 + x1, 2);
    const cy = @divTrunc(y0 + y1, 2);

    var best: ?Point = null;
    var best_d: i64 = std.math.maxInt(i64);
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            if (!pm.passable(x, y)) continue;
            const d = dist2(x, y, cx, cy);
            if (d < best_d) {
                best_d = d;
                best = .{ .x = x, .y = y };
            }
        }
    }
    return best;
}

fn push(alloc: std.mem.Allocator, heap: *std.ArrayListUnmanaged(u64), f: u32, node: u32) !void {
    try heap.append(alloc, @as(u64, f) << 32 | node);
    var i = heap.items.len - 1;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (heap.items[parent] <= heap.items[i]) break;
        std.mem.swap(u64, &heap.items[parent], &heap.items[i]);
        i = parent;
    }
}

fn pop(heap: *std.ArrayListUnmanaged(u64)) ?u64 {
    if (heap.items.len == 0) return null;
    const top = heap.items[0];
    const last = heap.items[heap.items.len - 1];
    heap.items.len -= 1;
    const n = heap.items.len;
    if (n == 0) return top;
    heap.items[0] = last;
    var i: usize = 0;
    while (true) {
        const l = 2 * i + 1;
        if (l >= n) break;
        const r = l + 1;
        const child = if (r < n and heap.items[r] < heap.items[l]) r else l;
        if (heap.items[i] <= heap.items[child]) break;
        std.mem.swap(u64, &heap.items[i], &heap.items[child]);
        i = child;
    }
    return top;
}
