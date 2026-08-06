//! Integration tests against real generated maps.
//!
//! The unit tests next to each module prove the pieces in isolation on synthetic grids. These
//! prove the thing that actually matters: that routes over a genuine Act 1 hold up — that a
//! teleport route only ever makes casts the server would accept, that crossing an area border
//! produces a leg per area, and that the Arcane Sanctuary is reachable at all.

const std = @import("std");
const drlg = @import("d2-drlg");
const pf = @import("lib.zig");

const testing = std.testing;
const SEED: u32 = 0x13572468;

/// Act 1 at a fixed seed, loaded once per test that needs it. Generation is the slow part
/// (~150 ms); everything after is microseconds.
const Fixture = struct {
    alloc: std.mem.Allocator,
    ctx: drlg.Ctx,
    world: pf.World,
    router: pf.Router,

    /// Heap-allocated: the router borrows the world by pointer, so the world must not move.
    fn load(alloc: std.mem.Allocator, acts: []const i32) !*Fixture {
        const f = try alloc.create(Fixture);
        f.* = .{
            .alloc = alloc,
            .ctx = try drlg.Ctx.init(alloc),
            .world = pf.World.init(alloc, SEED, .normal),
            .router = undefined,
        };
        f.router = pf.Router.init(alloc, &f.world);
        for (acts) |a| try f.world.loadAct(&f.ctx, a);
        return f;
    }

    fn deinit(self: *Fixture) void {
        const alloc = self.alloc;
        self.router.deinit();
        self.world.deinit();
        self.ctx.deinit();
        alloc.destroy(self);
    }

    fn passMap(self: *Fixture, lv: *pf.Level, mask: u16) !*pf.PassMap {
        return (try self.router.navFor(lv)).passMap(mask);
    }

    fn passMapFor(self: *Fixture, lv: *pf.Level, mask: u16, fp: pf.grid.Footprint) !*pf.PassMap {
        return (try self.router.navFor(lv)).passMapFor(mask, fp);
    }
};

/// A synthetic level plus a view of it, for tests that want an exact grid rather than a real map.
/// Heap-allocated because a `PassMap` holds `*const Level`, which must not move.
const Bare = struct {
    alloc: std.mem.Allocator,
    lv: pf.Level,
    pm: pf.PassMap,

    fn init(alloc: std.mem.Allocator, w: i32, h: i32, cells: []const u16, mask: u16, fp: pf.grid.Footprint) !*Bare {
        const owned = try alloc.dupe(u16, cells);
        const self = try alloc.create(Bare);
        self.* = .{ .alloc = alloc, .lv = try pf.Level.initBare(alloc, w, h, owned), .pm = undefined };
        self.pm = try pf.grid.buildPassMap(alloc, &self.lv, mask, fp);
        return self;
    }

    fn deinit(self: *Bare) void {
        self.pm.deinit(self.alloc);
        self.lv.deinit();
        self.alloc.destroy(self);
    }
};

/// The passable cell nearest a level's centre — a position that exists on every level, so a test
/// does not have to hard-code coordinates that depend on the seed.
fn centre(f: *Fixture, lv: *pf.Level, mask: u16) !pf.Point {
    const pm = try f.passMap(lv, mask);
    return pf.grid.nearestPassable(pm, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), @max(lv.w, lv.h)) orelse
        error.NoPassableCell;
}

test "a whole act loads with collision, rooms and exits" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    try testing.expect(f.world.levels.items.len >= 30);
    const town = f.world.level(1) orelse return error.NoTown;
    try testing.expect(town.w > 0 and town.h > 0);
    try testing.expect(town.rooms.rooms.len > 0);
    try testing.expectEqual(pf.TeleportRule.allowed, town.teleport);

    // Every level should have somewhere to walk and something to walk into.
    var with_exits: usize = 0;
    for (f.world.levels.items) |lv| {
        const pm = try f.passMap(lv, pf.Colmask.player_path);
        var any = false;
        for (pm.bits) |wd| {
            if (wd != 0) any = true;
        }
        try testing.expect(any);
        if (lv.exits.len != 0) with_exits += 1;
    }
    try testing.expect(with_exits >= 20);
}

test "Cold Plains to Stony Field routes across the area border" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const cold_plains: i32 = 3;
    const stony_field: i32 = 4;
    const from = try centre(f, f.world.level(cold_plains).?, pf.Colmask.player_path);
    const to = try centre(f, f.world.level(stony_field).?, pf.Colmask.player_path);

    var r = try f.router.route(
        .{ .level = cold_plains, .x = from.x, .y = from.y },
        .{ .level = stony_field, .x = to.x, .y = to.y },
        .{},
    );
    defer r.deinit();

    // One leg per level traversed, first on the source and last on the destination.
    try testing.expect(r.legs.len >= 2);
    try testing.expectEqual(cold_plains, r.legs[0].level);
    try testing.expectEqual(stony_field, r.legs[r.legs.len - 1].level);
    // Every leg but the last says how it leaves; the last does not.
    for (r.legs[0 .. r.legs.len - 1]) |leg| try testing.expect(leg.exit != null);
    try testing.expect(r.legs[r.legs.len - 1].exit == null);
    for (r.legs) |leg| try testing.expect(leg.moves.len > 0);
}

test "a route across several intervening levels visits each of them once" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // Rogue Encampment to Tamoe Highland: the whole Act 1 overworld chain.
    const from = try centre(f, f.world.level(1).?, pf.Colmask.player_path);
    const to = try centre(f, f.world.level(7).?, pf.Colmask.player_path);

    var r = try f.router.route(
        .{ .level = 1, .x = from.x, .y = from.y },
        .{ .level = 7, .x = to.x, .y = to.y },
        .{},
    );
    defer r.deinit();

    try testing.expect(r.legs.len >= 3);
    var seen: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer seen.deinit(alloc);
    for (r.legs) |leg| {
        try testing.expect(!seen.contains(leg.level));
        try seen.put(alloc, leg.level, {});
    }
}

test "every teleport cast in a route is one the server would accept" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const max_cast: i32 = pf.teleport.ENGINE_MAX_CAST;
    var checked: usize = 0;

    for (f.world.levels.items) |lv| {
        if (lv.teleport == .forbidden) continue;
        const pm = try f.passMap(lv, pf.Colmask.player_path);
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 4), @divTrunc(lv.h, 4), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 4), lv.h - @divTrunc(lv.h, 4), 64) orelse continue;

        var r = f.router.route(
            .{ .level = lv.id, .x = a.x, .y = a.y },
            .{ .level = lv.id, .x = b.x, .y = b.y },
            .{ .teleport = true, .teleport_max_cast = max_cast },
        ) catch continue;
        defer r.deinit();

        for (r.legs) |leg| {
            var i: usize = 1;
            while (i < leg.moves.len) : (i += 1) {
                const prev = leg.moves[i - 1];
                const cur = leg.moves[i];
                if (cur.kind != .teleport) continue;
                checked += 1;

                // 1. The landing cell must be legal for a player to stand on — that is the
                //    GetFreeCoordinates snap SUNIT_RelocateUnit does with COLMASK_PLAYER_PATH.
                try testing.expect(pm.passable(cur.x, cur.y));

                // 2. The destination room must be the caster's room or one adjacent to it. This
                //    is the rule the server actually enforces (FindBetterNearbyRoom), and the
                //    only thing standing between a route and a cast that silently does nothing.
                const from_room = lv.rooms.atSubtile(prev.x, prev.y) orelse return error.NoRoom;
                const to_room = lv.rooms.atSubtile(cur.x, cur.y) orelse return error.NoRoom;
                try testing.expect(lv.rooms.canTeleportBetween(from_room, to_room));

                // 3. And inside the packet handler's per-axis gate. CHEBYSHEV, not radial:
                //    CheckIfCoordsAreInRange (0x548ef0) tests |dx| and |dy| separately against
                //    nRange = 0x32, so a (50,50) diagonal cast is legal even though it spans ~70
                //    subtiles of actual ground.
                try testing.expect(@abs(cur.x - prev.x) <= max_cast);
                try testing.expect(@abs(cur.y - prev.y) <= max_cast);
            }
        }
    }
    try testing.expect(checked > 50);
}

test "unbounded teleport still obeys the room rule" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // With no range limit the search collapses to the room graph, which is a different code path
    // — and it has to reach the same conclusion about what is legal.
    const lv = f.world.level(2) orelse return error.NoLevel;
    const pm = try f.passMap(lv, pf.Colmask.player_path);
    const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 4), @divTrunc(lv.h, 4), 64) orelse return;
    const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 4), lv.h - @divTrunc(lv.h, 4), 64) orelse return;

    var r = try f.router.route(
        .{ .level = lv.id, .x = a.x, .y = a.y },
        .{ .level = lv.id, .x = b.x, .y = b.y },
        .{ .teleport = true, .teleport_max_cast = null },
    );
    defer r.deinit();

    var casts: usize = 0;
    for (r.legs) |leg| {
        var i: usize = 1;
        while (i < leg.moves.len) : (i += 1) {
            if (leg.moves[i].kind != .teleport) continue;
            casts += 1;
            const from_room = lv.rooms.atSubtile(leg.moves[i - 1].x, leg.moves[i - 1].y) orelse return error.NoRoom;
            const to_room = lv.rooms.atSubtile(leg.moves[i].x, leg.moves[i].y) orelse return error.NoRoom;
            try testing.expect(lv.rooms.canTeleportBetween(from_room, to_room));
        }
    }
    try testing.expect(casts > 0);
}

test "teleporting takes far fewer moves than walking the same distance" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(3) orelse return error.NoLevel;
    const pm = try f.passMap(lv, pf.Colmask.player_path);
    const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 8), @divTrunc(lv.h, 8), 64) orelse return;
    const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 8), lv.h - @divTrunc(lv.h, 8), 64) orelse return;
    const from = pf.Pos{ .level = lv.id, .x = a.x, .y = a.y };
    const to = pf.Pos{ .level = lv.id, .x = b.x, .y = b.y };

    var walk = try f.router.route(from, to, .{});
    defer walk.deinit();
    var tele = try f.router.route(from, to, .{ .teleport = true });
    defer tele.deinit();

    try testing.expect(tele.moveCount() <= walk.moveCount());
    // Every teleport move after the first is a cast, and a cast closes up to 50 subtiles per axis,
    // so a 400-subtile level should never need anything like a walk's worth of them.
    try testing.expect(tele.moveCount() < 40);
}

test "each mask's bitset is exactly that mask over the raw grid" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The mask IS the movement model, so the derived bitsets must be nothing more or less than
    // the mask applied to every cell — including the void fill, which no mask may pass.
    for (f.world.levels.items) |lv| {
        const player = try f.passMap(lv, pf.Colmask.player_path);
        const missile = try f.passMap(lv, pf.Colmask.missile_flight);
        const monster = try f.passMap(lv, pf.Colmask.monster_path);
        var void_cells: usize = 0;
        for (lv.cells, 0..) |cell, i| {
            try testing.expectEqual(pf.collision.passable(cell, pf.Colmask.player_path), player.passableAt(i));
            try testing.expectEqual(pf.collision.passable(cell, pf.Colmask.missile_flight), missile.passableAt(i));
            try testing.expectEqual(pf.collision.passable(cell, pf.Colmask.monster_path), monster.passableAt(i));
            if (cell == pf.collision.VOID) {
                void_cells += 1;
                try testing.expect(!player.passableAt(i));
                try testing.expect(!missile.passableAt(i));
                try testing.expect(!monster.passableAt(i));
            }
        }
    }
}

test "runtime occupancy separates a missile's world from a player's" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // On GENERATED terrain the player and missile masks happen to agree: the DT1 subtile flags
    // never set the missile barrier (0x04) without the wall bit (0x01), and never set NOPLAYER
    // (0x08) at all. The divergence is entirely a runtime phenomenon — objects, doors and units a
    // host ORs into the grid as play proceeds. That is precisely why the search is parameterised
    // by mask rather than by a walkable/not-walkable boolean, so prove it on an occupied grid.
    const lv = f.world.level(1) orelse return error.NoTown;
    const occupied = try alloc.dupe(u16, lv.cells);
    defer alloc.free(occupied);

    const Colbit = pf.Colbit;
    var stamped: usize = 0;
    for (occupied) |*c| {
        if (c.* != 0) continue;
        // A stall in the bazaar: blocks a shopper, not an arrow.
        c.* |= if (stamped % 2 == 0) Colbit.object else Colbit.door;
        stamped += 1;
        if (stamped == 64) break;
    }
    try testing.expectEqual(@as(usize, 64), stamped);

    var only_missile: usize = 0;
    for (occupied) |c| {
        const p = pf.collision.passable(c, pf.Colmask.player_path);
        const m = pf.collision.passable(c, pf.Colmask.missile_flight);
        if (m and !p) only_missile += 1;
    }
    try testing.expectEqual(@as(usize, 64), only_missile);

    // And a search over the occupied grid sees it: the player's passable set shrinks by exactly
    // the stamped cells while the missile's does not move at all.
    const player_occ_b = try Bare.init(alloc, lv.w, lv.h, occupied, pf.Colmask.player_path, .point);
    defer player_occ_b.deinit();
    const player_occ = &player_occ_b.pm;
    const missile_occ_b = try Bare.init(alloc, lv.w, lv.h, occupied, pf.Colmask.missile_flight, .point);
    defer missile_occ_b.deinit();
    const missile_occ = &missile_occ_b.pm;

    const player_clean = try f.passMap(lv, pf.Colmask.player_path);
    const missile_clean = try f.passMap(lv, pf.Colmask.missile_flight);
    try testing.expectEqual(countSet(player_clean) - 64, countSet(player_occ));
    try testing.expectEqual(countSet(missile_clean), countSet(missile_occ));
}

fn countSet(pm: *const pf.PassMap) usize {
    var n: usize = 0;
    for (pm.bits) |w| n += @popCount(w);
    return n;
}

test "the Arcane Sanctuary is reachable once portals are in the graph" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{ 0, 1 });
    defer f.deinit();

    // Map generation gives the Arcane Sanctuary no Vis and no Warp entries at all, so without the
    // portal table the level graph has it as an isolated island.
    const arcane = f.world.level(pf.portals.ARCANE_SANCTUARY) orelse return error.NoArcane;
    try testing.expectEqual(@as(usize, 0), arcane.exits.len);

    var exits: std.ArrayListUnmanaged(pf.Exit) = .empty;
    defer exits.deinit(alloc);
    try f.world.exitsOf(pf.portals.ARCANE_SANCTUARY, &exits);
    try testing.expect(exits.items.len >= 2);

    // And it routes: from Lut Gholein, down the palace, through the portal.
    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    try f.router.levelRoute(40, pf.portals.ARCANE_SANCTUARY, &chain);
    try testing.expectEqual(@as(i32, 40), chain.items[0]);
    try testing.expectEqual(pf.portals.ARCANE_SANCTUARY, chain.items[chain.items.len - 1]);

    var via_palace = false;
    for (chain.items) |id| {
        if (id == pf.portals.PALACE_CELLAR_3) via_palace = true;
    }
    try testing.expect(via_palace);

    // The other side: the Summoner's portal out to the Canyon of the Magi.
    chain.clearRetainingCapacity();
    try f.router.levelRoute(pf.portals.ARCANE_SANCTUARY, pf.portals.CANYON_OF_THE_MAGI, &chain);
    try testing.expectEqual(@as(usize, 2), chain.items.len);
}

test "Lut Gholein routes the length of the Act 2 desert to the Valley of Snakes" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{1});
    defer f.deinit();

    // 40 Lut Gholein -> 41 Rocky Waste -> 42 Dry Hills -> 43 Far Oasis -> 44 Lost City
    // -> 45 Valley of Snakes. Five area borders, all of them outdoor seams rather than warps, so
    // this is the case that exercises seam adjacency end to end.
    const lut_gholein: i32 = 40;
    const valley_of_snakes: i32 = 45;

    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    try f.router.levelRoute(lut_gholein, valley_of_snakes, &chain);
    try testing.expectEqual(lut_gholein, chain.items[0]);
    try testing.expectEqual(valley_of_snakes, chain.items[chain.items.len - 1]);
    try testing.expect(chain.items.len >= 5);

    const from = try centre(f, f.world.level(lut_gholein).?, pf.Colmask.player_path);
    const to = try centre(f, f.world.level(valley_of_snakes).?, pf.Colmask.player_path);

    for ([_]bool{ false, true }) |use_teleport| {
        var r = try f.router.route(
            .{ .level = lut_gholein, .x = from.x, .y = from.y },
            .{ .level = valley_of_snakes, .x = to.x, .y = to.y },
            .{ .teleport = use_teleport },
        );
        defer r.deinit();

        try testing.expectEqual(chain.items.len, r.legs.len);
        for (r.legs, chain.items) |leg, want_level| {
            try testing.expectEqual(want_level, leg.level);
            try testing.expect(leg.moves.len > 0);
        }
        try testing.expect(r.legs[r.legs.len - 1].exit == null);

        // Teleport never crosses an area border (cross-level rooms are only linked by warp
        // vis-slots), so the move that leaves each leg is always a walk.
        if (use_teleport) {
            for (r.legs) |leg| try testing.expectEqual(pf.Move.Kind.walk, leg.moves[0].kind);
        }
    }
}

test "the diagonal reach of the cast gate is actually used" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The gate is per-axis, so a cast may span (50,50) — about 70 subtiles of ground. A router that
    // modelled the limit as a 50-radius circle would never emit one. Prove we do.
    const max_cast = pf.teleport.ENGINE_MAX_CAST;
    var longest_euclidean: f64 = 0;
    for (f.world.levels.items) |lv| {
        if (lv.teleport == .forbidden) continue;
        const pm = try f.passMap(lv, pf.Colmask.player_path);
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 8), @divTrunc(lv.h, 8), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 8), lv.h - @divTrunc(lv.h, 8), 64) orelse continue;
        var r = f.router.route(
            .{ .level = lv.id, .x = a.x, .y = a.y },
            .{ .level = lv.id, .x = b.x, .y = b.y },
            .{ .teleport = true },
        ) catch continue;
        defer r.deinit();
        for (r.legs) |leg| {
            var i: usize = 1;
            while (i < leg.moves.len) : (i += 1) {
                if (leg.moves[i].kind != .teleport) continue;
                const dx: f64 = @floatFromInt(leg.moves[i].x - leg.moves[i - 1].x);
                const dy: f64 = @floatFromInt(leg.moves[i].y - leg.moves[i - 1].y);
                longest_euclidean = @max(longest_euclidean, @sqrt(dx * dx + dy * dy));
            }
        }
    }
    // Strictly further than the gate's own number, which is only possible on the diagonal.
    try testing.expect(longest_euclidean > @as(f64, @floatFromInt(max_cast)));
}

test "the engine's cross-level room links come through, and gate a boundary cast" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The links are harvested from ppDrlgRoomsExNear, which only DRLGROOMEX_LinkNearRoomsByVis
    // fills — so a non-empty total proves the vis-slot linking ran and reached us.
    var total_links: usize = 0;
    for (f.world.levels.items) |lv| total_links += lv.links.len;
    try testing.expect(total_links > 0);

    // Every link must name a level we loaded and a room index that exists there.
    for (f.world.levels.items) |lv| {
        for (lv.links) |link| {
            try testing.expect(link.from_room < lv.rooms.rooms.len);
            const dst = f.world.level(link.to_level) orelse continue;
            try testing.expect(link.to_room < dst.rooms.rooms.len);
            try testing.expect(link.to_level != lv.id); // cross-level only
        }
    }

    // And where a cast across a boundary is offered, it must clear the distance gate in WORLD
    // coordinates — the two cells live in different level-local frames.
    var offered: usize = 0;
    for (f.world.levels.items) |lv| {
        for (f.world.levels.items) |other| {
            if (other.id == lv.id) continue;
            const c = (try f.router.crossLevelCast(lv, other, .{})) orelse continue;
            offered += 1;
            const a = lv.toWorld(c.at);
            const b = other.toWorld(c.land);
            try testing.expect(@abs(a.x - b.x) <= pf.teleport.ENGINE_MAX_CAST);
            try testing.expect(@abs(a.y - b.y) <= pf.teleport.ENGINE_MAX_CAST);
        }
    }
    // Not asserting `offered > 0`: whether any linked pair is ALSO within 50 subtiles is a
    // property of the seed's level placement, and most warp destinations sit far away in the
    // world frame. The gate check above is what matters.
}

test "crossing by cast never makes a route longer than crossing on foot" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const from = try centre(f, f.world.level(1).?, pf.Colmask.player_path);
    const to = try centre(f, f.world.level(7).?, pf.Colmask.player_path);
    const a = pf.Pos{ .level = 1, .x = from.x, .y = from.y };
    const b = pf.Pos{ .level = 7, .x = to.x, .y = to.y };

    var walked = try f.router.route(a, b, .{ .teleport = true });
    defer walked.deinit();
    var cast = try f.router.route(a, b, .{ .teleport = true, .teleport_across_levels = true });
    defer cast.deinit();

    try testing.expectEqual(walked.legs.len, cast.legs.len);
    try testing.expect(cast.moveCount() <= walked.moveCount());
}

test "the cast gate is per-axis and inclusive, exactly as the handler spells it" {
    const o = pf.Point{ .x = 100, .y = 100 };
    const max = pf.teleport.ENGINE_MAX_CAST;

    // Straight: 50 accepted, 51 not.
    try testing.expect(pf.teleport.withinCastGate(o, .{ .x = 150, .y = 100 }, max));
    try testing.expect(!pf.teleport.withinCastGate(o, .{ .x = 151, .y = 100 }, max));

    // Diagonal: (50,50) accepted even though it is ~70 subtiles of ground. This is the whole
    // reason the metric matters — a radial reading of the same limit would reject it.
    try testing.expect(pf.teleport.withinCastGate(o, .{ .x = 150, .y = 150 }, max));
    const euclidean = @sqrt(@as(f64, 50 * 50 + 50 * 50));
    try testing.expect(euclidean > 70.0);

    // But one subtile past on either axis is out, however short the other axis is.
    try testing.expect(!pf.teleport.withinCastGate(o, .{ .x = 150, .y = 151 }, max));
    // Symmetric in the negative direction: x = 49 is 51 away and fails; x = 50 is exactly 50.
    try testing.expect(!pf.teleport.withinCastGate(o, .{ .x = 49, .y = 100 }, max));
    try testing.expect(pf.teleport.withinCastGate(o, .{ .x = 50, .y = 100 }, max));
}

test "Duriel's Lair gates the destination with COLMASK_PLAYER_FLYING" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{1});
    defer f.deinit();

    // Levels.txt Teleport == 2 for exactly one level, and the branch it selects tests the
    // destination with 0x804 (PUSH 0x804 at 0x5ca3a6) — door | missile_barrier.
    const lair = f.world.level(pf.portals.DURIELS_LAIR) orelse return error.NoLair;
    try testing.expectEqual(pf.TeleportRule.gated, lair.teleport);

    const base = pf.Colmask.player_path;
    try testing.expectEqual(base | pf.Colmask.player_flying, lair.teleport.destinationMask(base));
    // A door is already in the player mask, but the missile barrier is NOT — that bit is the
    // difference this level makes, and it must actually block.
    try testing.expect(pf.collision.passable(pf.Colbit.missile_barrier, base));
    try testing.expect(!pf.collision.passable(pf.Colbit.missile_barrier, lair.teleport.destinationMask(base)));

    // Every other level leaves the mask alone.
    for (f.world.levels.items) |lv| {
        if (lv.id == pf.portals.DURIELS_LAIR) continue;
        try testing.expectEqual(base, lv.teleport.destinationMask(base));
    }
}

test "no emitted waypoint exceeds what a movement command may target" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // SCMD_0x01_WalkToLocation / SCMD_0x03_RunToLocation go through the SAME
    // CheckIfInrangeAndReassign gate as a skill cast, so a waypoint further than 50 subtiles is not
    // a slow walk — the handler drops the packet and resyncs the client. Compression alone happily
    // emits 100-subtile straight runs, so this is the check that keeps the output drivable.
    const gate = pf.ENGINE_MAX_COMMAND_RANGE;
    var checked: usize = 0;

    for (f.world.levels.items) |lv| {
        const pm = try f.passMap(lv, pf.Colmask.player_path);
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 6), @divTrunc(lv.h, 6), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 6), lv.h - @divTrunc(lv.h, 6), 64) orelse continue;

        for ([_]bool{ false, true }) |tele| {
            var r = f.router.route(
                .{ .level = lv.id, .x = a.x, .y = a.y },
                .{ .level = lv.id, .x = b.x, .y = b.y },
                .{ .teleport = tele },
            ) catch continue;
            defer r.deinit();
            for (r.legs) |leg| {
                var i: usize = 1;
                while (i < leg.moves.len) : (i += 1) {
                    const dx = leg.moves[i].x - leg.moves[i - 1].x;
                    const dy = leg.moves[i].y - leg.moves[i - 1].y;
                    try testing.expect(@max(@abs(dx), @abs(dy)) <= gate);
                    checked += 1;
                }
            }
        }
    }
    try testing.expect(checked > 200);
}

test "wall aversion keeps walked paths off the geometry" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    var hug_off: usize = 0;
    var hug_on: usize = 0;
    var nodes_off: usize = 0;
    var nodes_on: usize = 0;

    for (f.world.levels.items) |lv| {
        const pm = try f.passMap(lv, pf.Colmask.player_path);
        const cl = pm.clearance();
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 6), @divTrunc(lv.h, 6), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 6), lv.h - @divTrunc(lv.h, 6), 64) orelse continue;

        for ([_]pf.WallAversion{ .{ .desired = 0 }, .{} }, 0..) |av, which| {
            var r = f.router.route(
                .{ .level = lv.id, .x = a.x, .y = a.y },
                .{ .level = lv.id, .x = b.x, .y = b.y },
                .{ .wall_aversion = av },
            ) catch continue;
            defer r.deinit();
            for (r.legs) |leg| {
                for (leg.moves) |m| {
                    if (!pm.inBounds(m.x, m.y)) continue;
                    const touching = cl[pm.index(m.x, m.y)] <= 1;
                    if (which == 0) {
                        nodes_off += 1;
                        if (touching) hug_off += 1;
                    } else {
                        nodes_on += 1;
                        if (touching) hug_on += 1;
                    }
                }
            }
        }
    }
    try testing.expect(nodes_off > 100 and nodes_on > 100);
    // Not asserting a specific ratio — level geometry decides how much room there is to move away
    // from a wall — but the default must be a large, unambiguous improvement, not noise.
    const pct_off = hug_off * 100 / nodes_off;
    const pct_on = hug_on * 100 / nodes_on;
    try testing.expect(pct_on * 3 < pct_off);
}

test "the clearance transform is an exact Chebyshev distance to the nearest wall" {
    const alloc = testing.allocator;
    // Open 9x9 with a single wall in the middle: clearance must fall off in rings around it, and
    // the border counts as wall too.
    const cells = try alloc.alloc(u16, 81);
    defer alloc.free(cells);
    @memset(cells, 0);
    cells[4 * 9 + 4] = pf.Colbit.wall;
    const pm_b = try Bare.init(alloc, 9, 9, cells, pf.Colmask.player_path, .point);
    defer pm_b.deinit();
    const pm = &pm_b.pm;
    const cl = pm.clearance();

    try testing.expectEqual(@as(u8, 0), cl[4 * 9 + 4]); // the wall itself
    try testing.expectEqual(@as(u8, 1), cl[4 * 9 + 3]); // touching it
    try testing.expectEqual(@as(u8, 1), cl[3 * 9 + 3]); // diagonally touching it
    try testing.expectEqual(@as(u8, 2), cl[4 * 9 + 2]); // one further out
    try testing.expectEqual(@as(u8, 1), cl[0]); // the border is wall as well
    try testing.expectEqual(@as(u8, 1), cl[4 * 9 + 0]);
}

test "Act 1 routes town to Andariel, the way the game is played" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // Rogue Encampment -> Blood Moor -> Cold Plains -> Stony Field -> Dark Wood -> Black Marsh ->
    // Tamoe Highland -> Monastery Gate -> Outer Cloister -> Barracks -> Jail 1/2/3 -> Inner
    // Cloister -> Cathedral -> Catacombs 1..4. Outdoor seams, then warp doors, then the
    // door-heavy Jail and Catacombs run.
    const ANDARIEL: i32 = 37; // Catacombs Level 4
    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    try f.router.levelRoute(1, ANDARIEL, &chain);

    try testing.expectEqual(@as(i32, 1), chain.items[0]);
    try testing.expectEqual(ANDARIEL, chain.items[chain.items.len - 1]);
    // The Catacombs are only reachable through the Cathedral, which is only reachable through the
    // Inner Cloister -- so the tail of the chain is forced and worth pinning.
    for ([_]i32{ 33, 34, 35, 36, 37 }) |want| {
        try testing.expect(std.mem.indexOfScalar(i32, chain.items, want) != null);
    }

    const from = try centre(f, f.world.level(1).?, pf.Colmask.player_path);
    const to = try centre(f, f.world.level(ANDARIEL).?, pf.Colmask.player_path);
    for ([_]bool{ false, true }) |tele| {
        var r = try f.router.route(
            .{ .level = 1, .x = from.x, .y = from.y },
            .{ .level = ANDARIEL, .x = to.x, .y = to.y },
            .{ .teleport = tele },
        );
        defer r.deinit();
        try testing.expectEqual(chain.items.len, r.legs.len);
        for (r.legs) |leg| try testing.expect(leg.moves.len > 0);
    }
}

test "the Jail and Catacombs runs report the doors they pass" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The generated grid has no door bit, so the search walks through doorways as if open -- which
    // is right, a character opens what it walks into. The route still has to SAY so.
    var any: usize = 0;
    for ([_]i32{ 28, 29, 30, 31, 33, 34, 35, 36 }) |lid| {
        var doors: std.ArrayListUnmanaged(pf.Door) = .empty;
        defer doors.deinit(alloc);
        f.world.doorsOn(lid, &doors) catch continue;
        any += doors.items.len;
        // A door must sit somewhere inside its level.
        const lv = f.world.level(lid) orelse continue;
        for (doors.items) |d| try testing.expect(lv.inBounds(d.x, d.y));
    }
    try testing.expect(any > 0);

    // And a real route through them reports the ones it passes, in leg order.
    const from = try centre(f, f.world.level(28).?, pf.Colmask.player_path);
    const to = try centre(f, f.world.level(31).?, pf.Colmask.player_path);
    var r = try f.router.route(
        .{ .level = 28, .x = from.x, .y = from.y },
        .{ .level = 31, .x = to.x, .y = to.y },
        .{},
    );
    defer r.deinit();

    var passed: std.ArrayListUnmanaged(pf.RouteDoor) = .empty;
    defer passed.deinit(alloc);
    try f.router.doorsAlong(&r, 12, &passed);
    var last_leg: usize = 0;
    for (passed.items) |rd| {
        try testing.expect(rd.leg >= last_leg); // in the order they are met
        last_leg = rd.leg;
        try testing.expect(rd.move < r.legs[rd.leg].moves.len);
    }
}

test "the whole game connects, bar one known hole" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{ 0, 1, 2, 3, 4 });
    defer f.deinit();
    try testing.expect(f.world.levels.items.len > 120);

    // Act 1 and Act 2 route forward from the start, boss to boss.
    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    for ([_][2]i32{ .{ 1, 37 }, .{ 37, 73 } }) |leg| {
        chain.clearRetainingCapacity();
        try f.router.levelRoute(leg[0], leg[1], &chain);
        try testing.expectEqual(leg[0], chain.items[0]);
        try testing.expectEqual(leg[1], chain.items[chain.items.len - 1]);
    }
    // Act 4 into Act 5, all the way past Baal. Baal is fought in the Throne of Destruction (131);
    // the Worldstone Chamber (132) beyond it is reached through the portal he opens on dying, which
    // portals.zig carries because map generation correctly emits no warp for a quest-gated link.
    for ([_][2]i32{ .{ 102, 108 }, .{ 108, 131 }, .{ 131, 132 } }) |leg| {
        chain.clearRetainingCapacity();
        try f.router.levelRoute(leg[0], leg[1], &chain);
        try testing.expectEqual(leg[1], chain.items[chain.items.len - 1]);
    }

    // KNOWN GAP 1 -- quest gating, not a defect. Levels.txt gives 131 Vis1=132 Warp1=82 and 132
    // Vis0=131 Warp0=81, but generation emits no adjacency and is right not to: the portal does not
    // exist until Baal dies. Object 563 (WorldstonePortal) IS placed from the start, so the site is
    // routable even while the link is not.
    try testing.expect((try f.world.questPortalSite(131, 132)) != null);

    // Act 3 has no placement chain and no Levels.txt Vis between its outdoor levels; the engine
    // stitches them by testing level boxes pairwise (DRLGACT_SetWarpConnectionsBetweenTwoAreas),
    // so which levels are neighbours depends on where this seed placed them. Docks to Durance 3
    // must connect, in ascending order, through the Kurast levels — but not necessarily all of
    // them: on roughly half of all seeds Spider Forest touches Flayer Jungle and Great Marsh (77)
    // drops out of the chain, exactly as it does in the real game.
    chain.clearRetainingCapacity();
    try f.router.levelRoute(75, 102, &chain);
    const kurast = [_]i32{ 75, 76, 77, 78, 79, 80, 81, 82, 83, 100, 101, 102 };
    try testing.expectEqual(@as(i32, 75), chain.items[0]);
    try testing.expectEqual(@as(i32, 102), chain.items[chain.items.len - 1]);
    var k: usize = 0;
    for (chain.items) |lid| {
        while (k < kurast.len and kurast[k] != lid) k += 1;
        if (k == kurast.len) return error.NotAKurastChain; // out of order, or not a Kurast level
        k += 1;
    }
    // Only Great Marsh may be missing; everything else on the way is mandatory.
    for (kurast) |lid| {
        if (lid == 77) continue;
        try testing.expect(std.mem.indexOfScalar(i32, chain.items, lid) != null);
    }

    // Every Levels.txt Vis pair must still produce an adjacency, except the quest-gated one.
    //
    // NB this audit is Vis-only and so is BLIND to seams: two outdoor levels stitched by geometry
    // have no Vis entry between them, which is exactly how gap 2 above went unnoticed. It is a
    // regression guard on warp links, not a connectivity proof.
    var holes: usize = 0;
    for (f.world.levels.items) |lv| {
        const vis = try visOf(alloc, lv.id);
        defer alloc.free(vis);
        for (vis) |dest| {
            if (dest == 0 or dest == lv.id) continue;
            const dl = f.world.level(dest) orelse continue;
            var found = false;
            for (lv.exits) |e| {
                if (e.to_level == dest) found = true;
            }
            for (dl.exits) |e| {
                if (e.to_level == lv.id) found = true;
            }
            if (found) continue;
            holes += 1;
            const known = (lv.id == 131 and dest == 132) or (lv.id == 132 and dest == 131);
            if (!known) {
                std.debug.print("unexpected adjacency hole: {d} -> {d}\n", .{ lv.id, dest });
                return error.UnexpectedAdjacencyHole;
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), holes);
}

/// A level's Levels.txt Vis array.
fn visOf(alloc: std.mem.Allocator, level_id: i32) ![]i32 {
    const text = @import("d2-data").file("Levels");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return error.InvalidTable;
    var idc: usize = 0;
    var visc: [8]usize = @splat(0);
    var cols = std.mem.splitScalar(u8, header, '\t');
    var i: usize = 0;
    while (cols.next()) |c| : (i += 1) {
        const nm = std.mem.trim(u8, c, "\r");
        if (std.mem.eql(u8, nm, "Id")) idc = i;
        for (0..8) |v| {
            var buf: [8]u8 = undefined;
            const want = std.fmt.bufPrint(&buf, "Vis{d}", .{v}) catch continue;
            if (std.mem.eql(u8, nm, want)) visc[v] = i;
        }
    }
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, "\r \t").len == 0) continue;
        var c2 = std.mem.splitScalar(u8, line, '\t');
        var j: usize = 0;
        var lid: i32 = -1;
        var vis: [8]i32 = @splat(0);
        while (c2.next()) |c| : (j += 1) {
            const v = std.mem.trim(u8, c, "\r ");
            if (j == idc) lid = std.fmt.parseInt(i32, v, 10) catch -1;
            for (0..8) |k| {
                if (visc[k] != 0 and j == visc[k]) vis[k] = std.fmt.parseInt(i32, v, 10) catch 0;
            }
        }
        if (lid == level_id) return alloc.dupe(i32, &vis);
    }
    return alloc.dupe(i32, &[_]i32{});
}

test "an unreachable level fails fast instead of searching" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    // Act 1 alone cannot reach an Act 3 level: no warp, no seam, no portal.
    try testing.expectError(error.NoLevelRoute, f.router.levelRoute(1, 83, &chain));
}

test "a bigger footprint is blocked by gaps a point walks through" {
    const alloc = testing.allocator;
    // A 1-subtile-wide corridor down the middle of a solid block. A point-sized unit fits; the
    // cross (CheckCollision_Cross) needs its east/west neighbours and does not; nor does the 3x3.
    var cells = [_]u16{pf.Colbit.wall} ** (9 * 9);
    for (0..9) |y| cells[y * 9 + 4] = 0;

    for ([_]struct { fp: pf.grid.Footprint, want: bool }{
        .{ .fp = .point, .want = true },
        .{ .fp = .small, .want = false },
        .{ .fp = .big, .want = false },
    }) |c| {
        const b = try Bare.init(alloc, 9, 9, &cells, pf.Colmask.player_path, c.fp);
        defer b.deinit();
        try testing.expectEqual(c.want, b.pm.passable(4, 4));
    }
}

test "the cross clears a 3-wide corridor that the 3x3 box also clears" {
    const alloc = testing.allocator;
    var cells = [_]u16{pf.Colbit.wall} ** (9 * 9);
    for (0..9) |y| {
        for (3..6) |x| cells[y * 9 + x] = 0;
    }

    const cross_b = try Bare.init(alloc, 9, 9, &cells, pf.Colmask.player_path, .small);
    defer cross_b.deinit();
    const cross = &cross_b.pm;
    const box_b = try Bare.init(alloc, 9, 9, &cells, pf.Colmask.player_path, .big);
    defer box_b.deinit();
    const box = &box_b.pm;

    // Centre of the corridor: both fit. One subtile off centre: neither does, because the shape
    // then reaches into the wall.
    try testing.expect(cross.passable(4, 4));
    try testing.expect(box.passable(4, 4));
    try testing.expect(!cross.passable(3, 4));
    try testing.expect(!box.passable(3, 4));
}

test "footprint maps are cached per (mask, footprint) and are real alternatives" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const point = try f.passMapFor(lv, pf.Colmask.player_path, .point);
    const box = try f.passMapFor(lv, pf.Colmask.player_path, .big);
    try testing.expect(point != box);
    try testing.expectEqual(point, try f.passMapFor(lv, pf.Colmask.player_path, .point));

    // A 3x3 unit can never stand somewhere a point cannot, and on a real level it is strictly
    // more restricted — otherwise the erosion did nothing.
    var point_n: usize = 0;
    var box_n: usize = 0;
    for (0..@intCast(lv.w * lv.h)) |i| {
        if (point.passableAt(i)) point_n += 1;
        if (box.passableAt(i)) {
            box_n += 1;
            try testing.expect(point.passableAt(i));
        }
    }
    try testing.expect(box_n < point_n);
    try testing.expect(box_n > 0);
}




test "a missile flies where a player cannot walk" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // A GENERATED grid cannot show this: every missile_barrier cell it emits also carries wall,
    // and noplayer/object/door never appear at all - they are runtime occupancy a live host ORs
    // in. So overlay what a host would: an object (blocks the player, not a missile) and a bare
    // missile barrier (blocks the missile, not the player), and check both models react.
    const lv = f.world.level(2) orelse return error.NoLevel;
    const walk_base = try f.passMapFor(lv, pf.Colmask.player_path, .point);
    const open = pf.grid.nearestPassable(walk_base, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), 128) orelse
        return error.NoPassableCell;
    // Three cells in a row, all clear, so a trace along them is unobstructed to begin with.
    if (!walk_base.passable(open.x + 1, open.y) or !walk_base.passable(open.x + 2, open.y)) return;

    const cells = try alloc.dupe(u16, lv.cells);
    defer alloc.free(cells);
    const obj_at: usize = @intCast(open.y * lv.w + open.x + 1);
    cells[obj_at] = pf.Colbit.object;

    var probe = try pf.Level.initBare(alloc, lv.w, lv.h, try alloc.dupe(u16, cells));
    defer probe.deinit();

    const from = open;
    const to = pf.Point{ .x = open.x + 2, .y = open.y };
    try testing.expect(!probe.hasLineOfSight(from, to, pf.Colmask.player_path)); // the object stops the player
    try testing.expect(probe.hasLineOfSight(from, to, pf.Colmask.missile_flight)); // and not the missile

    // And the reverse: a barrier with no wall bit stops only the missile.
    probe.cells[obj_at] = pf.Colbit.missile_barrier;
    try testing.expect(probe.hasLineOfSight(from, to, pf.Colmask.player_path));
    try testing.expect(!probe.hasLineOfSight(from, to, pf.Colmask.missile_flight));

    const stop = probe.trace(from, to, pf.Colmask.missile_flight);
    try testing.expectEqual(open.x + 1, stop.at.x);
}

test "a cast is refused by range, by line of sight, or by having no rule" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const pm = try f.passMapFor(lv, pf.Colmask.radial_barrier, .point);
    const here = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), 128) orelse
        return error.NoPassableCell;

    // Casting at your own feet always clears both gates.
    try testing.expectEqual(pf.CastVerdict.ok, try pf.cast.canCast(try f.router.navFor(lv), here, here));

    // One subtile past the packet handler's gate. It is Chebyshev, so this is about the axis,
    // not the distance: a (50,50) diagonal is fine and a (51,0) straight line is not.
    const gate = pf.teleport.ENGINE_MAX_CAST;
    try testing.expectEqual(
        pf.CastVerdict.out_of_range,
        try pf.cast.canCast(try f.router.navFor(lv), here, .{ .x = here.x + gate + 1, .y = here.y }),
    );
    try testing.expectEqual(
        pf.CastVerdict.ok,
        try pf.cast.canCastAt(try f.router.navFor(lv), here, .{ .x = here.x, .y = here.y }, .barrier, gate),
    );

    // A skill whose lineofsight column is not one the jump table handles cannot be cast.
    try testing.expectEqual(
        pf.CastVerdict.no_line_of_sight_rule,
        try pf.cast.canCastAt(try f.router.navFor(lv), here, here, .none, gate),
    );

    // Somewhere on the level, something within cast range is behind a barrier — otherwise the
    // line-of-sight gate would never fire and would not be worth modelling.
    var blocked: usize = 0;
    for (f.world.levels.items) |l| {
        var y: i32 = 0;
        while (y < l.h) : (y += 20) {
            var x: i32 = 0;
            while (x < l.w) : (x += 20) {
                const a = pf.Point{ .x = x, .y = y };
                const b = pf.Point{ .x = @min(x + gate, l.w - 1), .y = @min(y + gate, l.h - 1) };
                if ((try pf.cast.canCast(try f.router.navFor(l), a, b)) == .no_line_of_sight) blocked += 1;
            }
        }
    }
    try testing.expect(blocked > 0);
}

test "canTeleportTo agrees with the route builder about every cast it emits" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The router already proves its casts against the room rule; this proves the standalone
    // predicate a bot would call reaches the same verdict, so the two cannot drift apart.
    var checked: usize = 0;
    for (f.world.levels.items) |lv| {
        if (lv.teleport == .forbidden) continue;
        const pm = try f.passMap(lv, pf.Colmask.player_path);
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 4), @divTrunc(lv.h, 4), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 4), lv.h - @divTrunc(lv.h, 4), 64) orelse continue;

        var r = f.router.route(
            .{ .level = lv.id, .x = a.x, .y = a.y },
            .{ .level = lv.id, .x = b.x, .y = b.y },
            .{ .teleport = true },
        ) catch continue;
        defer r.deinit();

        for (r.legs) |leg| {
            var i: usize = 1;
            while (i < leg.moves.len) : (i += 1) {
                if (leg.moves[i].kind != .teleport) continue;
                const from = pf.Point{ .x = leg.moves[i - 1].x, .y = leg.moves[i - 1].y };
                const to = pf.Point{ .x = leg.moves[i].x, .y = leg.moves[i].y };
                try testing.expect(try pf.cast.canTeleportTo(try f.router.navFor(lv), from, to, pf.teleport.ENGINE_MAX_CAST));
                checked += 1;
            }
        }
    }
    try testing.expect(checked > 50);
}

test "attack positions are in range, stand-able and can see the target" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const stand = try f.passMapFor(lv, pf.Colmask.player_path, .point);
    const target = pf.grid.nearestPassable(stand, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), 128) orelse
        return error.NoPassableCell;

    const spots = try pf.cast.attackPositions(alloc, try f.router.navFor(lv), target, .{ .min_range = 3, .max_range = 20 });
    defer alloc.free(spots);
    try testing.expect(spots.len > 0);

    for (spots) |s| {
        try testing.expect(s.dist >= 3 and s.dist <= 20);
        try testing.expectEqual(s.dist, @as(i32, @intCast(@max(@abs(s.at.x - target.x), @abs(s.at.y - target.y)))));
        try testing.expect(stand.passable(s.at.x, s.at.y));
        try testing.expect(pf.cast.unitsCanReach(lv, pf.Colmask.radial_barrier, target, 1, s.at, 1));
    }
    // Best first: roomier, then closer.
    for (spots[1..], 0..) |s, i| {
        const prev = spots[i];
        try testing.expect(prev.clearance > s.clearance or
            (prev.clearance == s.clearance and prev.dist <= s.dist));
    }
}

test "a big attacker gets fewer places to stand than a small one" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // Same target, same range, only the footprint differs — the 3x3 shape cannot use cells the
    // point-sized one can, which is the whole reason CheckCollision dispatches on unit size.
    var total_point: usize = 0;
    var total_box: usize = 0;
    for (f.world.levels.items) |lv| {
        const stand = try f.passMapFor(lv, pf.Colmask.player_path, .point);
        const t = pf.grid.nearestPassable(stand, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), 128) orelse continue;
        const small = try pf.cast.attackPositions(alloc, try f.router.navFor(lv), t, .{ .max_range = 12, .limit = 4096 });
        defer alloc.free(small);
        const big = try pf.cast.attackPositions(alloc, try f.router.navFor(lv), t, .{ .max_range = 12, .limit = 4096, .footprint = .big });
        defer alloc.free(big);
        try testing.expect(big.len <= small.len);
        total_point += small.len;
        total_box += big.len;
    }
    try testing.expect(total_box < total_point);
    try testing.expect(total_box > 0);
}

test "unitsCanReach shrinks the segment by each radius before tracing" {
    const alloc = testing.allocator;
    // Wall at x = 4. Two units either side, radius 2 each.
    var cells = [_]u16{0} ** (11 * 11);
    for (0..11) |y| cells[y * 11 + 4] = pf.Colbit.wall;
    const pm_b = try Bare.init(alloc, 11, 11, &cells, pf.Colmask.radial_barrier, .point);
    defer pm_b.deinit();

    const a = pf.Point{ .x = 0, .y = 5 };
    const b = pf.Point{ .x = 10, .y = 5 };
    try testing.expect(!pf.cast.unitsCanReach(&pm_b.lv, pf.Colmask.radial_barrier, a, 2, b, 2));

    // Close enough that the Manhattan check short-circuits: the engine reports no collision
    // without tracing at all, even standing right on the wall.
    const near = pf.Point{ .x = 4, .y = 5 };
    try testing.expect(pf.cast.unitsCanReach(&pm_b.lv, pf.Colmask.radial_barrier, near, 2, .{ .x = 5, .y = 5 }, 2));

    // Radii are clamped, so anything at or above 2 behaves identically.
    var open = [_]u16{0} ** (11 * 11);
    const pm2_b = try Bare.init(alloc, 11, 11, &open, pf.Colmask.radial_barrier, .point);
    defer pm2_b.deinit();
    try testing.expectEqual(
        pf.cast.unitsCanReach(&pm2_b.lv, pf.Colmask.radial_barrier, a, 2, b, 2),
        pf.cast.unitsCanReach(&pm2_b.lv, pf.Colmask.radial_barrier, a, 99, b, 99),
    );
}





test "the Arcane Sanctuary is crossable only because of its teleport pads" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{1});
    defer f.deinit();

    const lv = f.world.level(pf.portals.ARCANE_SANCTUARY) orelse return error.NoLevel;
    // Ground truth for the premise: the walkable surface really is many islands, and the pads
    // really do pair up. If either stops being true this test is no longer testing anything.
    const pm = try f.passMap(lv, pf.Colmask.player_path);
    const comp = try pm.components(alloc);
    try testing.expect(pm.comp_count > 5);
    try testing.expect(lv.pads.len > 0);
    for (lv.pads) |p| try testing.expect(p.at.x != p.to.x or p.at.y != p.to.y);

    // Start at the entry portal — where a character actually arrives — and aim at the far end
    // of a pad that drops into a different region. Picking arbitrary cells does not work: several
    // of the 17 islands are pockets no pad serves, and a route between two of those SHOULD fail.
    var portal: ?pf.Point = null;
    for (lv.presets) |up| {
        if (up.etype == 2 and up.txt_file_no == 298) portal = .{ .x = up.x, .y = up.y };
    }
    const from = pf.grid.nearestPassable(pm, (portal orelse return error.NoPortal).x, (portal orelse return error.NoPortal).y, 32) orelse
        return error.NoPassableCell;
    const from_c = comp[pm.index(from.x, from.y)];

    var to: ?pf.Point = null;
    for (lv.pads) |pd| {
        const land = pf.grid.nearestPassable(pm, pd.to.x, pd.to.y, 8) orelse continue;
        if (comp[pm.index(land.x, land.y)] != from_c) {
            to = land;
            break;
        }
    }
    const goal = to orelse return error.NoFarRegion;

    var r = try f.router.route(
        .{ .level = lv.id, .x = from.x, .y = from.y },
        .{ .level = lv.id, .x = goal.x, .y = goal.y },
        .{},
    );
    defer r.deinit();

    var pads_used: usize = 0;
    for (r.legs) |leg| {
        for (leg.moves) |m| {
            if (m.kind == .pad) pads_used += 1;
        }
    }
    try testing.expect(pads_used > 0);

    // Every pad move must land on a real pad's far end — snapped to walkable ground, since the
    // pad object itself can sit on a cell the mask rejects.
    for (r.legs) |leg| {
        for (leg.moves, 0..) |m, mi| {
            if (m.kind != .pad or mi == 0) continue;
            var matched = false;
            for (lv.pads) |p| {
                if (@abs(p.to.x - m.x) <= 8 and @abs(p.to.y - m.y) <= 8) matched = true;
            }
            try testing.expect(matched);
        }
    }
}

test "levels without pads are unaffected by the pad search" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // Act 1 has no teleport pads at all, so no level there may grow one, and routing must still
    // produce pure walks.
    for (f.world.levels.items) |lv| try testing.expectEqual(@as(usize, 0), lv.pads.len);

    const lv = f.world.level(2) orelse return error.NoLevel;
    const pm = try f.passMap(lv, pf.Colmask.player_path);
    const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 4), @divTrunc(lv.h, 4), 64) orelse return;
    const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 4), lv.h - @divTrunc(lv.h, 4), 64) orelse return;
    var r = try f.router.route(
        .{ .level = lv.id, .x = a.x, .y = a.y },
        .{ .level = lv.id, .x = b.x, .y = b.y },
        .{},
    );
    defer r.deinit();
    for (r.legs) |leg| {
        for (leg.moves) |m| try testing.expect(m.kind == .walk);
    }
}

test "the live world blocks a real level's cells and gives them back when the unit leaves" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const pm = try f.passMap(lv, pf.Colmask.player_path);

    var spot: ?pf.Point = null;
    for (0..@intCast(lv.w * lv.h)) |i| {
        if (!pm.passableAt(i)) continue;
        spot = .{ .x = @intCast(i % @as(usize, @intCast(lv.w))), .y = @intCast(i / @as(usize, @intCast(lv.w))) };
        break;
    }
    const at = spot orelse return error.NoOpenCell;

    const before_comp = (try pm.components(alloc))[pm.index(at.x, at.y)];
    try lv.addUnit(1, at, .monster(2, false, .{}));

    try testing.expect(!pm.passable(at.x, at.y));
    // Terrain never changed, so the cached labels are untouched and still say what they said.
    try testing.expect(pm.staticPassable(at.x, at.y));
    try testing.expectEqual(before_comp, (try pm.components(alloc))[pm.index(at.x, at.y)]);

    lv.removeUnit(1);
    try testing.expect(pm.passable(at.x, at.y));
    try testing.expect(lv.units.isEmpty());
}

test "opening terrain rewrites the grid, and the next view asked for is rebuilt" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const before = try f.passMap(lv, pf.Colmask.player_path);
    _ = try before.components(alloc);
    try testing.expect(before.comp_built);

    // Find a wall subtile that a room actually covers, and knock it out.
    var wall: ?pf.Point = null;
    for (0..@intCast(lv.w * lv.h)) |i| {
        const v = lv.cells[i];
        if (v == pf.collision.VOID or v & pf.Colbit.wall == 0) continue;
        wall = .{ .x = @intCast(i % @as(usize, @intCast(lv.w))), .y = @intCast(i / @as(usize, @intCast(lv.w))) };
        break;
    }
    const w = wall orelse return error.NoWall;
    try testing.expect(!before.passable(w.x, w.y));

    try testing.expect(lv.editTerrain(pf.Rect.at(w.x, w.y), .{ .remove = pf.Colmask.player_path }));

    // A view is refreshed when it is ASKED for, not spontaneously — a `*PassMap` a caller already
    // holds cannot know the level changed under it. Every search re-fetches, so this is the path
    // that matters.
    const after = try f.passMap(lv, pf.Colmask.player_path);
    try testing.expectEqual(before, after); // the same cached object, rebuilt in place
    try testing.expect(after.passable(w.x, w.y));
    // Passability GREW, which can join two components, so the labels were thrown away.
    try testing.expect(!after.comp_built);
    try testing.expect((try after.components(alloc))[after.index(w.x, w.y)] != pf.PassMap.NO_COMPONENT);

    // And it puts back: a barrier dropped onto the same cell closes it again.
    try testing.expect(lv.editTerrain(pf.Rect.at(w.x, w.y), .{ .add = pf.Colbit.wall }));
    try testing.expect(!(try f.passMap(lv, pf.Colmask.player_path)).passable(w.x, w.y));
}

test "a route re-planned after a monster lands on it goes around" {
    const alloc = testing.allocator;
    const f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const a = try centre(f, lv, pf.Colmask.player_path);
    const pm = try f.passMap(lv, pf.Colmask.player_path);

    var r = f.router.route(
        .{ .level = 2, .x = a.x, .y = a.y },
        .{ .level = 2, .x = @min(a.x + 60, lv.w - 2), .y = a.y },
        .{ .compress = false },
    ) catch return; // some seeds have no room to run; the point is the re-plan, not this level
    defer r.deinit();
    if (r.legs.len == 0 or r.legs[0].moves.len < 8) return;

    // Drop a monster on a subtile the route walks through, then ask again.
    const on_path = r.legs[0].moves[r.legs[0].moves.len / 2];
    try lv.addUnit(1, .{ .x = on_path.x, .y = on_path.y }, .monster(2, false, .{}));
    try testing.expect(!pm.passable(on_path.x, on_path.y));

    var r2 = f.router.route(
        .{ .level = 2, .x = a.x, .y = a.y },
        .{ .level = 2, .x = @min(a.x + 60, lv.w - 2), .y = a.y },
        .{ .compress = false },
    ) catch {
        lv.removeUnit(1);
        return; // sealing the only corridor is a legitimate outcome
    };
    defer r2.deinit();

    for (r2.legs[0].moves) |m| {
        try testing.expect(!std.meta.eql(m, on_path));
    }
    lv.removeUnit(1);
}
