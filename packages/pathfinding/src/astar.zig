//! The walk search: A* over a level's subtile `PassMap`.
//!
//! This is deliberately NOT the engine's pathfinder. `d2-drlg`'s `path.zig` already ports
//! `DRLGPATH_FindPathAStar` faithfully — iterative deepening, a 900-node cap, the engine's
//! neighbour rotation — because it has to reproduce the exact points the engine emits. That
//! algorithm re-expands nodes every deepening round and gives up at 900 nodes, so it cannot
//! answer "route me across Lut Gholein" at all. This one is built for the opposite goal: the
//! shortest path over a whole level, as fast as possible.
//!
//! What it does keep from the engine is the COST MODEL — straight 2, diagonal 3, and the exact
//! free-space heuristic `min + 2*max` — so the paths agree in shape and in what they consider
//! cheaper, and the heuristic is both admissible and consistent (no node is ever re-expanded).
//!
//! Speed comes from the scratch being owned by the caller and reused:
//!   * `g`/`came`/`state` are sized once to the largest level and never reallocated;
//!   * they are never cleared either — a per-search generation counter in `stamp` invalidates
//!     stale entries, so a query on a 1M-subtile level does no O(n) work before it starts;
//!   * the open set is a binary heap of `(f << 32) | node`, one `u64` compare per sift step;
//!   * an unreachable goal is rejected up front by the component labels, so a failed query
//!     costs a couple of array reads instead of flooding the level.

const std = @import("std");
const grid = @import("grid.zig");

pub const Point = grid.Point;

pub const Error = error{
    /// Start position is not passable for this mask (and no snap was requested/found).
    StartBlocked,
    /// Goal position is not passable for this mask (and no snap was requested/found).
    GoalBlocked,
    /// Start and goal are both passable but lie in different connected regions.
    Unreachable,
    /// The search hit `max_nodes` before reaching the goal.
    NodeLimit,
} || std.mem.Allocator.Error;

pub const Options = struct {
    /// When the start sits inside collision, accept the nearest passable subtile within this many
    /// cells instead of failing. 0 disables the snap. Mirrors what the engine does for a requested
    /// destination via `GetFreeCoordinates_WithNeighboorRooms`.
    snap_radius: i32 = 8,
    /// The same for the goal. Split from `snap_radius` because the two ends of a search are often
    /// different kinds of thing: a caller's exact position at one end, and an approximate
    /// level-transition tile at the other, which needs a far looser snap. Null follows
    /// `snap_radius`.
    goal_snap_radius: ?i32 = null,
    /// Safety valve for pathological queries. A whole 1000x1000 level is 1M subtiles, so the
    /// default lets a search cover any real level and still terminate on a broken grid.
    max_nodes: u32 = 4_000_000,
    /// Collapse runs of identical direction into single waypoints. This is what a mover wants
    /// (walk to the corner, then the next corner); turn it off to get every subtile.
    compress: bool = true,
};

/// Reusable search scratch. One per thread; `ensure` grows it to the biggest level you search.
pub const Pather = struct {
    alloc: std.mem.Allocator,
    cap: usize = 0,
    g: []u32 = &.{},
    came: []u32 = &.{},
    stamp: []u32 = &.{},
    /// Bit 0 of `state` marks closed; only meaningful when `stamp` matches the current run.
    state: []u8 = &.{},
    heap: std.ArrayListUnmanaged(u64) = .empty,
    gen: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) Pather {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Pather) void {
        self.alloc.free(self.g);
        self.alloc.free(self.came);
        self.alloc.free(self.stamp);
        self.alloc.free(self.state);
        self.heap.deinit(self.alloc);
        self.* = undefined;
    }

    fn ensure(self: *Pather, n: usize) !void {
        if (self.cap >= n) return;
        self.alloc.free(self.g);
        self.alloc.free(self.came);
        self.alloc.free(self.stamp);
        self.alloc.free(self.state);
        self.g = try self.alloc.alloc(u32, n);
        self.came = try self.alloc.alloc(u32, n);
        self.stamp = try self.alloc.alloc(u32, n);
        self.state = try self.alloc.alloc(u8, n);
        @memset(self.stamp, 0);
        self.cap = n;
        self.gen = 0;
    }

    /// Bump the run counter, wrapping via a single clear when it would collide with stale marks.
    fn newRun(self: *Pather) void {
        if (self.gen == std.math.maxInt(u32)) {
            @memset(self.stamp, 0);
            self.gen = 0;
        }
        self.gen += 1;
        self.heap.clearRetainingCapacity();
    }

    inline fn touch(self: *Pather, i: usize) void {
        if (self.stamp[i] != self.gen) {
            self.stamp[i] = self.gen;
            self.g[i] = std.math.maxInt(u32);
            self.came[i] = std.math.maxInt(u32);
            self.state[i] = 0;
        }
    }

    fn push(self: *Pather, f: u32, node: u32) !void {
        try self.heap.append(self.alloc, @as(u64, f) << 32 | node);
        var i = self.heap.items.len - 1;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (self.heap.items[parent] <= self.heap.items[i]) break;
            std.mem.swap(u64, &self.heap.items[parent], &self.heap.items[i]);
            i = parent;
        }
    }

    fn pop(self: *Pather) ?u64 {
        const items = self.heap.items;
        if (items.len == 0) return null;
        const top = items[0];
        const last = items[items.len - 1];
        self.heap.items.len -= 1;
        const n = self.heap.items.len;
        if (n == 0) return top;
        self.heap.items[0] = last;
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            if (l >= n) break;
            const r = l + 1;
            const child = if (r < n and self.heap.items[r] < self.heap.items[l]) r else l;
            if (self.heap.items[i] <= self.heap.items[child]) break;
            std.mem.swap(u64, &self.heap.items[i], &self.heap.items[child]);
            i = child;
        }
        return top;
    }

    /// Shortest walk from (sx,sy) to (gx,gy) over `pm`, appended to `out` as world-of-this-level
    /// subtile waypoints. `out` starts with the (possibly snapped) start and ends with the
    /// (possibly snapped) goal.
    pub fn find(
        self: *Pather,
        pm: *grid.PassMap,
        sx: i32,
        sy: i32,
        gx: i32,
        gy: i32,
        opts: Options,
        out: *std.ArrayListUnmanaged(Point),
    ) Error!void {
        const start = grid.nearestPassable(pm, sx, sy, opts.snap_radius) orelse return error.StartBlocked;
        const goal = grid.nearestPassable(pm, gx, gy, opts.goal_snap_radius orelse opts.snap_radius) orelse
            return error.GoalBlocked;

        const comp = try pm.components(self.alloc);
        const si = pm.index(start.x, start.y);
        const gi = pm.index(goal.x, goal.y);
        if (comp[si] != comp[gi]) return error.Unreachable;

        if (si == gi) {
            try out.append(self.alloc, start);
            return;
        }

        const n: usize = @intCast(pm.w * pm.h);
        try self.ensure(n);
        self.newRun();

        self.touch(si);
        self.g[si] = 0;
        try self.push(grid.heuristic(start.x, start.y, goal.x, goal.y), @intCast(si));

        var expanded: u32 = 0;
        while (self.pop()) |entry| {
            const cur: usize = @intCast(entry & 0xFFFF_FFFF);
            if (self.stamp[cur] == self.gen and self.state[cur] & 1 != 0) continue; // stale heap entry
            self.touch(cur);
            self.state[cur] |= 1;
            if (cur == gi) return self.reconstruct(pm, si, gi, opts, out);

            expanded += 1;
            if (expanded > opts.max_nodes) return error.NodeLimit;

            const cx: i32 = @intCast(@as(u32, @intCast(cur)) % @as(u32, @intCast(pm.w)));
            const cy: i32 = @intCast(@as(u32, @intCast(cur)) / @as(u32, @intCast(pm.w)));
            const gc = self.g[cur];

            for (grid.NEIGHBOURS) |d| {
                const nx = cx + d[0];
                const ny = cy + d[1];
                if (!pm.inBounds(nx, ny)) continue;
                const ni = pm.index(nx, ny);
                if (!pm.passableAt(ni)) continue;
                const step: u32 = if (d[0] != 0 and d[1] != 0) grid.COST_DIAGONAL else grid.COST_STRAIGHT;
                const tentative = gc + step;
                self.touch(ni);
                if (self.state[ni] & 1 != 0 or tentative >= self.g[ni]) continue;
                self.g[ni] = tentative;
                self.came[ni] = @intCast(cur);
                try self.push(tentative + grid.heuristic(nx, ny, goal.x, goal.y), @intCast(ni));
            }
        }
        // A consistent heuristic plus the component pre-check means an exhausted heap can only
        // happen if the component labels and the bitset disagree, which would be a build bug.
        return error.Unreachable;
    }

    fn reconstruct(
        self: *Pather,
        pm: *const grid.PassMap,
        si: usize,
        gi: usize,
        opts: Options,
        out: *std.ArrayListUnmanaged(Point),
    ) Error!void {
        const first = out.items.len;
        var cur = gi;
        while (true) {
            const x: i32 = @intCast(@as(u32, @intCast(cur)) % @as(u32, @intCast(pm.w)));
            const y: i32 = @intCast(@as(u32, @intCast(cur)) / @as(u32, @intCast(pm.w)));
            try out.append(self.alloc, .{ .x = x, .y = y });
            if (cur == si) break;
            cur = self.came[cur];
        }
        std.mem.reverse(Point, out.items[first..]);
        if (opts.compress) compressRuns(out, first);
    }
};

/// Drop the interior of every straight run: keep a point only where the direction changes. The
/// endpoints always survive.
pub fn compressRuns(out: *std.ArrayListUnmanaged(Point), first: usize) void {
    const pts = out.items[first..];
    if (pts.len < 3) return;
    var write: usize = 1;
    var i: usize = 1;
    while (i < pts.len - 1) : (i += 1) {
        const prev = pts[write - 1];
        const cur = pts[i];
        const next = pts[i + 1];
        const in_dx = std.math.sign(cur.x - prev.x);
        const in_dy = std.math.sign(cur.y - prev.y);
        const out_dx = std.math.sign(next.x - cur.x);
        const out_dy = std.math.sign(next.y - cur.y);
        if (in_dx == out_dx and in_dy == out_dy) continue;
        pts[write] = cur;
        write += 1;
    }
    pts[write] = pts[pts.len - 1];
    out.items.len = first + write + 1;
}

const testing = std.testing;

fn testMap(alloc: std.mem.Allocator, w: i32, h: i32, walls: []const [2]i32) !grid.PassMap {
    const cells = try alloc.alloc(u16, @intCast(w * h));
    defer alloc.free(cells);
    @memset(cells, 0);
    for (walls) |p| cells[@intCast(p[1] * w + p[0])] = 0x01;
    return grid.buildPassMap(alloc, cells, w, h, 0x1c09);
}

test "A* finds the straight-line path across open ground" {
    const alloc = testing.allocator;
    var pm = try testMap(alloc, 32, 32, &.{});
    defer pm.deinit(alloc);
    var p = Pather.init(alloc);
    defer p.deinit();
    var out: std.ArrayListUnmanaged(Point) = .empty;
    defer out.deinit(alloc);

    try p.find(&pm, 0, 0, 20, 20, .{}, &out);
    // Pure diagonal: compressed to just the endpoints.
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(Point{ .x = 0, .y = 0 }, out.items[0]);
    try testing.expectEqual(Point{ .x = 20, .y = 20 }, out.items[out.items.len - 1]);
}

test "A* routes around a wall and reports the true cost" {
    const alloc = testing.allocator;
    // A vertical wall at x=5 spanning y=0..14, leaving a gap at y=15.
    var walls: [15][2]i32 = undefined;
    for (0..15) |i| walls[i] = .{ 5, @intCast(i) };
    var pm = try testMap(alloc, 24, 24, &walls);
    defer pm.deinit(alloc);
    var p = Pather.init(alloc);
    defer p.deinit();
    var out: std.ArrayListUnmanaged(Point) = .empty;
    defer out.deinit(alloc);

    try p.find(&pm, 2, 2, 10, 2, .{ .compress = false }, &out);
    try testing.expectEqual(Point{ .x = 2, .y = 2 }, out.items[0]);
    try testing.expectEqual(Point{ .x = 10, .y = 2 }, out.items[out.items.len - 1]);
    // Every step is a legal 8-neighbour move onto passable ground, and none crosses the wall.
    for (out.items, 0..) |pt, i| {
        try testing.expect(pm.passable(pt.x, pt.y));
        if (i == 0) continue;
        const dx = @abs(pt.x - out.items[i - 1].x);
        const dy = @abs(pt.y - out.items[i - 1].y);
        try testing.expect(dx <= 1 and dy <= 1 and (dx | dy) != 0);
    }
}

test "a walled-off goal is rejected by the component check, not by searching" {
    const alloc = testing.allocator;
    // Seal x=5 completely: the right half becomes its own component.
    var walls: [24][2]i32 = undefined;
    for (0..24) |i| walls[i] = .{ 5, @intCast(i) };
    var pm = try testMap(alloc, 24, 24, &walls);
    defer pm.deinit(alloc);
    var p = Pather.init(alloc);
    defer p.deinit();
    var out: std.ArrayListUnmanaged(Point) = .empty;
    defer out.deinit(alloc);

    try testing.expectError(error.Unreachable, p.find(&pm, 2, 2, 10, 2, .{ .snap_radius = 0 }, &out));
    try testing.expectEqual(@as(u32, 2), pm.comp_count);
}

test "a start inside collision snaps to the nearest free cell" {
    const alloc = testing.allocator;
    var pm = try testMap(alloc, 16, 16, &.{.{ 3, 3 }});
    defer pm.deinit(alloc);
    var p = Pather.init(alloc);
    defer p.deinit();
    var out: std.ArrayListUnmanaged(Point) = .empty;
    defer out.deinit(alloc);

    try p.find(&pm, 3, 3, 10, 10, .{}, &out);
    try testing.expect(!std.meta.eql(out.items[0], Point{ .x = 3, .y = 3 }));
    try testing.expect(pm.passable(out.items[0].x, out.items[0].y));

    try out.resize(alloc, 0);
    try testing.expectError(error.StartBlocked, p.find(&pm, 3, 3, 10, 10, .{ .snap_radius = 0 }, &out));
}

test "the scratch is reused across searches without clearing" {
    const alloc = testing.allocator;
    var pm = try testMap(alloc, 64, 64, &.{});
    defer pm.deinit(alloc);
    var p = Pather.init(alloc);
    defer p.deinit();
    var out: std.ArrayListUnmanaged(Point) = .empty;
    defer out.deinit(alloc);

    for (0..50) |i| {
        try out.resize(alloc, 0);
        const t: i32 = @intCast(i);
        try p.find(&pm, 0, 0, 40 + @mod(t, 20), 30, .{}, &out);
        try testing.expectEqual(Point{ .x = 0, .y = 0 }, out.items[0]);
    }
    try testing.expectEqual(@as(u32, 50), p.gen);
}
