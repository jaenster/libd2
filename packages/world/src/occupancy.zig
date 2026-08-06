//! The live world: what is standing on a level right now, layered over the collision map that map
//! generation produced.
//!
//! A level's grid has two halves that the engine keeps in ONE array and every consumer here keeps
//! in two. The generated half is terrain — walls, water, the objects the DS1s placed — and it is
//! the same for every player who ever rolls that seed. The other half is written and rewritten
//! constantly: every player, monster, pet, item, object and corpse ORs its collision bits into the
//! cells it covers when it arrives and clears them when it leaves. `AddCollision_Type` (0x64ea90)
//! and `RemoveCollision_Type` (0x64ec10) are that write, and a walking unit calls the pair on every
//! single step (`RemoveGetCollision_Width`, 0x64ed20).
//!
//! The split exists because everything built ON a grid is derived and cached — d2-pathfinding's
//! per-mask passability bitsets, its connected-component labels, its distance transform. Rebuilding
//! those when a monster takes one step is not an option, so the terrain half stays immutable and
//! owns the caches, and the live half is a small sparse overlay consulted per cell. Since the
//! overlay only ever ADDS blockage, a component labelling of the terrain stays a valid "these two
//! cells can never be connected" test and nothing has to be invalidated.
//!
//! WHAT a unit stamps is not this module's business — see `unit.Collision`, which reproduces the
//! engine's per-unit-type table. This module is the grid it gets stamped into.
//!
//! **One divergence, on purpose.** The engine's remove is a bare `*pCell &= ~flags` with no
//! ownership tracking, so two units whose stamps overlap on one bit leave a hole: the first to
//! leave clears a bit the second still owns. It is reachable in the real game — two players share
//! the `player` bit and do not block each other — and it is harmless there only because nothing
//! reads that bit for movement. A router that answered from a stale hole would be wrong, so every
//! cell here counts its owners per bit and a bit survives until its last owner leaves. Placement is
//! otherwise identical, and no path mask can observe the difference.

const std = @import("std");
const collision = @import("d2-core").collision;

pub const Point = struct { x: i32, y: i32 };

/// One thing standing on the level, as the grid sees it.
pub const Occupant = struct {
    at: Point,
    /// What it paints and where — see `collision.Stamp`.
    stamp: collision.Stamp,
    /// Its class bit: `Colbit.player`, `.monster`, `.item`, `.object`, `.dead`. Exactly what the
    /// engine passes as `eCollisionFlag`.
    flags: u16,
};

const Word = u64;
const bits_per_word = @bitSizeOf(Word);

inline fn wordOf(cell: usize) usize {
    return cell / bits_per_word;
}

inline fn bitOf(cell: usize) Word {
    return @as(Word, 1) << @intCast(cell % bits_per_word);
}

/// Everything a level's live world adds to its terrain, and who owns it.
pub const Occupancy = struct {
    alloc: std.mem.Allocator,
    w: i32,
    h: i32,
    /// One bit per subtile, set when any occupant covers it. This is the whole reason a search can
    /// afford to consult the live world at all: the overwhelmingly common answer is "nothing here",
    /// and getting it costs one word load and a mask, with no hashing and no cache miss on the
    /// sparse side.
    present: []Word,
    /// Only the covered subtiles. Sparse because a busy level has a few hundred of them against a
    /// million cells.
    cells: std.AutoHashMapUnmanaged(u32, Cell) = .empty,
    /// Live occupants by the caller's id — a unit GUID, typically. Holding the placement is what
    /// lets `move` and `lift` undo exactly what `place` wrote, without the caller having to
    /// remember the stamp it used.
    occupants: std.AutoHashMapUnmanaged(u32, Occupant) = .empty,
    /// Bumped on every change, so a caller that memoises anything derived from the live world can
    /// tell in one compare whether it is still current.
    generation: u64 = 0,

    /// A covered subtile: the OR of its occupants' bits, plus how many owners each bit has, so a
    /// departure clears only what its owner actually put there.
    pub const Cell = struct {
        bits: u16 = 0,
        refs: [16]u16 = [_]u16{0} ** 16,
    };

    pub fn init(alloc: std.mem.Allocator, w: i32, h: i32) !Occupancy {
        const n: usize = @intCast(@max(w * h, 0));
        const present = try alloc.alloc(Word, std.math.divCeil(usize, n, bits_per_word) catch 0);
        @memset(present, 0);
        return .{ .alloc = alloc, .w = w, .h = h, .present = present };
    }

    pub fn deinit(self: *Occupancy) void {
        self.alloc.free(self.present);
        self.cells.deinit(self.alloc);
        self.occupants.deinit(self.alloc);
        self.* = undefined;
    }

    pub inline fn isEmpty(self: *const Occupancy) bool {
        return self.cells.count() == 0;
    }

    pub inline fn inBounds(self: *const Occupancy, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.w and y < self.h;
    }

    pub inline fn index(self: *const Occupancy, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * @as(usize, @intCast(self.w)) + @as(usize, @intCast(x));
    }

    /// The live bits on a subtile, by raw index. Callers that only need to know whether they are
    /// blocked should use `blocks`, which skips the hash lookup on the common empty cell.
    pub fn at(self: *const Occupancy, cell: usize) u16 {
        if (self.present[wordOf(cell)] & bitOf(cell) == 0) return 0;
        const e = self.cells.get(@intCast(cell)) orelse return 0;
        return e.bits;
    }

    /// Does the live world block a unit whose collision model is `mask` on this subtile?
    pub inline fn blocks(self: *const Occupancy, cell: usize, mask: u16) bool {
        if (self.present[wordOf(cell)] & bitOf(cell) == 0) return false;
        const e = self.cells.get(@intCast(cell)) orelse return false;
        return e.bits & mask != 0;
    }

    pub fn atXY(self: *const Occupancy, x: i32, y: i32) u16 {
        if (!self.inBounds(x, y)) return 0;
        return self.at(self.index(x, y));
    }

    /// Put `id` on the level, replacing wherever it was before. Re-placing an id that is already
    /// down lifts it first, so this is also the move that changes stamp or class.
    pub fn place(self: *Occupancy, id: u32, at_pos: Point, stamp: collision.Stamp, flags: u16) !void {
        self.lift(id);
        try self.occupants.put(self.alloc, id, .{ .at = at_pos, .stamp = stamp, .flags = flags });
        try self.apply(at_pos, stamp, flags, .add);
        self.generation += 1;
    }

    /// The same, taking the unit's whole collision profile — `unit.Collision.monster(...)` and
    /// friends — rather than a stamp and a bit picked out by hand.
    pub fn placeUnit(self: *Occupancy, id: u32, at_pos: Point, unit_collision: anytype) !void {
        try self.place(id, at_pos, unit_collision.stamp, unit_collision.flag);
    }

    /// Take `id` off the level, restoring every cell it covered to what the rest of the world says.
    pub fn lift(self: *Occupancy, id: u32) void {
        const kv = self.occupants.fetchRemove(id) orelse return;
        const o = kv.value;
        // `.remove` only ever decrements counters that `.add` incremented, so it cannot allocate.
        self.apply(o.at, o.stamp, o.flags, .remove) catch unreachable;
        self.generation += 1;
    }

    pub fn get(self: *const Occupancy, id: u32) ?Occupant {
        return self.occupants.get(id);
    }

    /// Walk `id` to a new subtile, keeping its stamp and class. A no-op for an id that is not down.
    pub fn moveTo(self: *Occupancy, id: u32, to: Point) !void {
        const o = self.occupants.get(id) orelse return;
        try self.place(id, to, o.stamp, o.flags);
    }

    /// `RemoveGetCollision_Width` (0x64ed20), the step a walking unit actually takes: lift, look at
    /// where it wants to go, and put it back where it was if the answer is geometry.
    ///
    /// Lifting FIRST is the point — a unit must not collide with the cells it is itself standing
    /// on, and with a footprint bigger than a point, a one-subtile step always overlaps them.
    ///
    /// The revert test is `TEST BL, 0x5` at 0x64ed58: `wall | missile_barrier`, and nothing else.
    /// So a step into another unit SUCCEEDS — units squeeze past each other, and keeping them apart
    /// is the pathfinder's job, not the mover's. Returns the collision bits found at the
    /// destination (0 when it was clear), whether or not the move was taken.
    pub fn step(self: *Occupancy, id: u32, to: Point, terrain: []const u16, mask: u16) !u16 {
        const o = self.occupants.get(id) orelse return 0;
        self.lift(id);
        const found = self.check(to, o.stamp, terrain, mask);
        const blocked = found & (collision.Colbit.wall | collision.Colbit.missile_barrier) != 0;
        try self.place(id, if (blocked) o.at else to, o.stamp, o.flags);
        return found;
    }

    /// `CheckCollision_BlockAll_Width` (0x64d9b0): the OR of everything the stamp's footprint sees,
    /// terrain and live world alike, narrowed to `mask`. `terrain` is the level's raw collision
    /// grid, row-major over the same `w`/`h`. Off-grid reads as `VOID`, which is what the engine's
    /// missing-room case amounts to.
    pub fn check(self: *const Occupancy, at_pos: Point, stamp: collision.Stamp, terrain: []const u16, mask: u16) u16 {
        var found: u16 = 0;
        var it = stampCells(at_pos, footprintOf(stamp));
        while (it.next()) |p| {
            if (!self.inBounds(p.x, p.y)) {
                found |= collision.VOID;
                continue;
            }
            const cell = self.index(p.x, p.y);
            found |= terrain[cell] | self.at(cell);
        }
        return found & mask;
    }

    /// Take everything off the level — a new game, or a level the caller stopped tracking.
    pub fn clear(self: *Occupancy) void {
        @memset(self.present, 0);
        self.cells.clearRetainingCapacity();
        self.occupants.clearRetainingCapacity();
        self.generation += 1;
    }

    pub fn count(self: *const Occupancy) usize {
        return self.occupants.count();
    }

    const Op = enum { add, remove };

    fn apply(self: *Occupancy, at_pos: Point, stamp: collision.Stamp, flags: u16, op: Op) !void {
        // The engine writes nothing at all for a zero flag, presence bit included: `TEST ESI,ESI`
        // at 0x64eabc guards every one of `AddCollision_Type`'s second writes.
        if (flags == 0) return;

        var it = stampCells(at_pos, footprintOf(stamp));
        while (it.next()) |p| try self.paint(p.x, p.y, flags, op);

        // Only a unit SHAPE carries a presence bit; a bare width or an object's box does not.
        const shape = switch (stamp) {
            .shape => |s| s,
            .width, .box => return,
        };
        const p = shape.presence() orelse return;
        var pit = stampCells(at_pos, .{ .cells = collision.cellsOf(p.over) });
        while (pit.next()) |c| try self.paint(c.x, c.y, p.bit, op);
    }

    /// One cell's worth of a stamp. Off-grid writes are dropped, which is what the engine does when
    /// `DRLGROOM_FindBetterNearbyRoom` finds no room for the coordinate.
    fn paint(self: *Occupancy, x: i32, y: i32, bits: u16, op: Op) !void {
        if (!self.inBounds(x, y)) return;
        const cell = self.index(x, y);
        switch (op) {
            .add => {
                const gop = try self.cells.getOrPut(self.alloc, @intCast(cell));
                if (!gop.found_existing) gop.value_ptr.* = .{};
                var rest = bits;
                while (rest != 0) : (rest &= rest - 1) gop.value_ptr.refs[@ctz(rest)] += 1;
                gop.value_ptr.bits |= bits;
                self.present[wordOf(cell)] |= bitOf(cell);
            },
            .remove => {
                const e = self.cells.getPtr(@intCast(cell)) orelse return;
                var rest = bits;
                while (rest != 0) : (rest &= rest - 1) {
                    const b: u4 = @intCast(@ctz(rest));
                    if (e.refs[b] == 0) continue;
                    e.refs[b] -= 1;
                    if (e.refs[b] == 0) e.bits &= ~(@as(u16, 1) << b);
                }
                if (e.bits != 0) return;
                _ = self.cells.remove(@intCast(cell));
                self.present[wordOf(cell)] &= ~bitOf(cell);
            },
        }
    }
};

/// A stamp's outline, in one of the two forms the engine expresses it: a fixed cell list for a
/// footprint, or a `w x h` rectangle for an object.
const Outline = union(enum) {
    cells: []const [2]i32,
    rect: struct { w: i32, h: i32 },
};

fn footprintOf(stamp: collision.Stamp) Outline {
    return switch (stamp) {
        .shape => |s| .{ .cells = collision.cellsOf(s.footprint()) },
        .width => |s| .{ .cells = collision.cellsOf(s) },
        .box => |b| .{ .rect = .{ .w = b.w, .h = b.h } },
    };
}

/// Walks the cells an outline covers when centred on `at`.
fn stampCells(at: Point, outline: Outline) CellIter {
    return .{ .at = at, .outline = outline };
}

const CellIter = struct {
    at: Point,
    outline: Outline,
    n: i32 = 0,

    fn next(self: *CellIter) ?Point {
        switch (self.outline) {
            .cells => |c| {
                if (self.n >= c.len) return null;
                const d = c[@intCast(self.n)];
                self.n += 1;
                return .{ .x = self.at.x + d[0], .y = self.at.y + d[1] };
            },
            // `AddCollision_Vector`'s own arithmetic: left = x - w/2, right = left + w - 1.
            .rect => |r| {
                if (r.w <= 0 or r.h <= 0 or self.n >= r.w * r.h) return null;
                const p: Point = .{
                    .x = self.at.x - @divTrunc(r.w, 2) + @mod(self.n, r.w),
                    .y = self.at.y - @divTrunc(r.h, 2) + @divTrunc(self.n, r.w),
                };
                self.n += 1;
                return p;
            },
        }
    }
};

const testing = std.testing;
const Colbit = collision.Colbit;
const Colmask = collision.Colmask;

fn shapeOf(s: collision.Shape) collision.Stamp {
    return .{ .shape = s };
}

test "a small unit stamps the cross with its class bit and the centre with nopath" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    try live.place(1, .{ .x = 10, .y = 10 }, shapeOf(.small_unit), Colbit.monster);

    try testing.expectEqual(Colbit.monster | Colbit.nopath, live.atXY(10, 10));
    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
        try testing.expectEqual(Colbit.monster, live.atXY(10 + d[0], 10 + d[1]));
    }
    // The cross and nothing more: the diagonals stay clean.
    try testing.expectEqual(@as(u16, 0), live.atXY(9, 9));
}

test "a big unit stamps the 3x3 box and puts nopath over the whole cross" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    try live.place(1, .{ .x = 10, .y = 10 }, shapeOf(.big_unit), Colbit.monster);

    try testing.expectEqual(Colbit.monster | Colbit.nopath, live.atXY(10, 10));
    try testing.expectEqual(Colbit.monster | Colbit.nopath, live.atXY(11, 10));
    // A box corner is outside the cross, so it carries the class bit but does not block a path.
    try testing.expectEqual(Colbit.monster, live.atXY(11, 11));
    try testing.expect(!live.blocks(live.index(11, 11), Colmask.player_path));
    try testing.expect(live.blocks(live.index(11, 10), Colmask.player_path));
}

test "a pet claims ground with pet rather than nopath, which is why players walk through it" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    try live.place(1, .{ .x = 5, .y = 5 }, shapeOf(.small_pet), Colbit.monster);
    try testing.expectEqual(Colbit.monster | Colbit.pet, live.atXY(5, 5));
    // monster_path (0x3c01) carries pet; player_path (0x1c09) does not.
    try testing.expect(live.blocks(live.index(5, 5), Colmask.monster_path));
    try testing.expect(!live.blocks(live.index(5, 5), Colmask.player_path));
}

test "an item claims no ground at all" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    try live.place(1, .{ .x = 5, .y = 5 }, .{ .width = .point }, Colbit.item);
    try testing.expectEqual(Colbit.item, live.atXY(5, 5));
    try testing.expect(!live.blocks(live.index(5, 5), Colmask.player_path));
}

test "an object stamps its Objects.txt rectangle, biased toward the origin on an even size" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    // 3x3 centred exactly: left = 10 - 1 = 9, right = 11.
    try live.place(1, .{ .x = 10, .y = 10 }, .{ .box = .{ .w = 3, .h = 3 } }, Colbit.object);
    try testing.expectEqual(Colbit.object, live.atXY(9, 9));
    try testing.expectEqual(Colbit.object, live.atXY(11, 11));
    try testing.expectEqual(@as(u16, 0), live.atXY(12, 10));
    live.lift(1);

    // 2x2: left = 20 - 1 = 19, right = 19 + 2 - 1 = 20.
    try live.place(2, .{ .x = 20, .y = 20 }, .{ .box = .{ .w = 2, .h = 2 } }, Colbit.object);
    try testing.expectEqual(Colbit.object, live.atXY(19, 19));
    try testing.expectEqual(Colbit.object, live.atXY(20, 20));
    try testing.expectEqual(@as(u16, 0), live.atXY(21, 20));
    live.lift(2);
    try testing.expect(live.isEmpty());
}

test "lifting a unit restores the cells it covered" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    try live.place(7, .{ .x = 4, .y = 4 }, shapeOf(.big_unit), Colbit.monster);
    try testing.expect(!live.isEmpty());
    live.lift(7);
    try testing.expect(live.isEmpty());
    try testing.expectEqual(@as(u16, 0), live.atXY(4, 4));
    try testing.expectEqual(@as(usize, 0), live.count());
}

test "moving a unit leaves nothing behind and blocks only where it now stands" {
    var live = try Occupancy.init(testing.allocator, 64, 64);
    defer live.deinit();

    try live.place(3, .{ .x = 20, .y = 20 }, shapeOf(.small_unit), Colbit.monster);
    try live.moveTo(3, .{ .x = 40, .y = 20 });

    try testing.expectEqual(@as(u16, 0), live.atXY(20, 20));
    try testing.expectEqual(@as(u16, 0), live.atXY(21, 20));
    try testing.expectEqual(Colbit.monster | Colbit.nopath, live.atXY(40, 20));
    try testing.expectEqual(@as(usize, 1), live.count());
}

test "one departure does not clear a bit another occupant still owns" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    // Two players one subtile apart. Their crosses overlap on (10,10) and (11,10), and both write
    // the same `player` bit there — the case the engine's bare AND-NOT gets wrong.
    try live.place(1, .{ .x = 10, .y = 10 }, shapeOf(.small_unit), Colbit.player);
    try live.place(2, .{ .x = 11, .y = 10 }, shapeOf(.small_unit), Colbit.player);
    try testing.expectEqual(Colbit.player | Colbit.nopath, live.atXY(10, 10));

    live.lift(1);
    // (10,10) is still inside 2's cross, so the class bit stays; only 1's nopath goes.
    try testing.expectEqual(Colbit.player, live.atXY(10, 10));
    try testing.expectEqual(Colbit.player | Colbit.nopath, live.atXY(11, 10));

    live.lift(2);
    try testing.expect(live.isEmpty());
}

test "re-placing an id replaces its stamp rather than adding a second one" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();

    try live.place(1, .{ .x = 8, .y = 8 }, shapeOf(.small_unit), Colbit.monster);
    try live.place(1, .{ .x = 8, .y = 8 }, shapeOf(.big_unit), Colbit.monster);
    live.lift(1);
    try testing.expect(live.isEmpty());
}

test "a stamp that runs off the grid is clipped, not wrapped" {
    var live = try Occupancy.init(testing.allocator, 16, 16);
    defer live.deinit();

    try live.place(1, .{ .x = 0, .y = 0 }, shapeOf(.big_unit), Colbit.monster);
    try testing.expectEqual(Colbit.monster | Colbit.nopath, live.atXY(0, 0));
    // Nothing landed on the opposite edge, which is where a wrapped index would have put it.
    try testing.expectEqual(@as(u16, 0), live.atXY(15, 15));
    try testing.expectEqual(@as(u16, 0), live.atXY(15, 0));
    live.lift(1);
    try testing.expect(live.isEmpty());
}

test "a zero class flag stamps nothing, presence bit included" {
    var live = try Occupancy.init(testing.allocator, 16, 16);
    defer live.deinit();

    try live.place(1, .{ .x = 8, .y = 8 }, shapeOf(.small_unit), 0);
    try testing.expect(live.isEmpty());
}

test "step walks into an empty cell and refuses a wall" {
    const alloc = testing.allocator;
    const w: i32 = 32;
    const terrain = try alloc.alloc(u16, @intCast(w * w));
    defer alloc.free(terrain);
    @memset(terrain, 0);
    terrain[@intCast(10 * w + 8)] = Colbit.wall;

    var live = try Occupancy.init(alloc, w, w);
    defer live.deinit();
    try live.place(1, .{ .x = 4, .y = 10 }, shapeOf(.small_unit), Colbit.player);

    const mask = Colmask.player_path;
    try testing.expectEqual(@as(u16, 0), try live.step(1, .{ .x = 5, .y = 10 }, terrain, mask));
    try testing.expectEqual(Point{ .x = 5, .y = 10 }, live.get(1).?.at);
    try testing.expectEqual(@as(u16, 0), try live.step(1, .{ .x = 6, .y = 10 }, terrain, mask));

    // The wall is at (8,10), and a small unit is checked over its whole cross — so (7,10) is
    // already refused, one subtile short of the wall itself, and the unit stays where it was.
    try testing.expectEqual(Colbit.wall, try live.step(1, .{ .x = 7, .y = 10 }, terrain, mask));
    try testing.expectEqual(Point{ .x = 6, .y = 10 }, live.get(1).?.at);
}

test "step into another unit succeeds — only geometry reverts it" {
    const alloc = testing.allocator;
    const terrain = try alloc.alloc(u16, 32 * 32);
    defer alloc.free(terrain);
    @memset(terrain, 0);

    var live = try Occupancy.init(alloc, 32, 32);
    defer live.deinit();
    try live.place(1, .{ .x = 10, .y = 10 }, shapeOf(.small_unit), Colbit.player);
    try live.place(2, .{ .x = 12, .y = 10 }, shapeOf(.small_unit), Colbit.monster);

    const hit = try live.step(1, .{ .x = 11, .y = 10 }, terrain, Colmask.any);
    try testing.expect(hit & Colbit.monster != 0);
    try testing.expectEqual(Point{ .x = 11, .y = 10 }, live.get(1).?.at);
}

test "clear empties the level" {
    var live = try Occupancy.init(testing.allocator, 32, 32);
    defer live.deinit();
    for (0..20) |i| {
        const n: i32 = @intCast(i);
        try live.place(@intCast(i), .{ .x = n * 2 + 1, .y = 5 }, shapeOf(.small_unit), Colbit.monster);
    }
    live.clear();
    try testing.expect(live.isEmpty());
    try testing.expectEqual(@as(usize, 0), live.count());
    try testing.expectEqual(@as(u16, 0), live.atXY(5, 5));
}
