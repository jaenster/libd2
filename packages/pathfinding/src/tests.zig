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
    ctx: drlg.Ctx,
    world: pf.World,

    fn load(alloc: std.mem.Allocator, acts: []const i32) !Fixture {
        var f = Fixture{
            .ctx = try drlg.Ctx.init(alloc),
            .world = pf.World.init(alloc, SEED, .normal),
        };
        for (acts) |a| try f.world.loadAct(&f.ctx, a);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.ctx.deinit();
    }
};

/// The passable cell nearest a level's centre — a position that exists on every level, so a test
/// does not have to hard-code coordinates that depend on the seed.
fn centre(lv: *pf.Level, mask: u16) !pf.Point {
    const pm = try lv.passMap(mask);
    return pf.grid.nearestPassable(pm, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), @max(lv.w, lv.h)) orelse
        error.NoPassableCell;
}

test "a whole act loads with collision, rooms and exits" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    try testing.expect(f.world.levels.items.len >= 30);
    const town = f.world.level(1) orelse return error.NoTown;
    try testing.expect(town.w > 0 and town.h > 0);
    try testing.expect(town.rooms.rooms.len > 0);
    try testing.expectEqual(pf.TeleportRule.allowed, town.teleport);

    // Every level should have somewhere to walk and something to walk into.
    var with_exits: usize = 0;
    for (f.world.levels.items) |*lv| {
        const pm = try lv.passMap(pf.Colmask.player_path);
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const cold_plains: i32 = 3;
    const stony_field: i32 = 4;
    const from = try centre(f.world.level(cold_plains).?, pf.Colmask.player_path);
    const to = try centre(f.world.level(stony_field).?, pf.Colmask.player_path);

    var r = try f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // Rogue Encampment to Tamoe Highland: the whole Act 1 overworld chain.
    const from = try centre(f.world.level(1).?, pf.Colmask.player_path);
    const to = try centre(f.world.level(7).?, pf.Colmask.player_path);

    var r = try f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const max_cast: i32 = pf.teleport.ENGINE_MAX_CAST;
    var checked: usize = 0;

    for (f.world.levels.items) |*lv| {
        if (lv.teleport == .forbidden) continue;
        const pm = try lv.passMap(pf.Colmask.player_path);
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 4), @divTrunc(lv.h, 4), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 4), lv.h - @divTrunc(lv.h, 4), 64) orelse continue;

        var r = f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // With no range limit the search collapses to the room graph, which is a different code path
    // — and it has to reach the same conclusion about what is legal.
    const lv = f.world.level(2) orelse return error.NoLevel;
    const pm = try lv.passMap(pf.Colmask.player_path);
    const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 4), @divTrunc(lv.h, 4), 64) orelse return;
    const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 4), lv.h - @divTrunc(lv.h, 4), 64) orelse return;

    var r = try f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(3) orelse return error.NoLevel;
    const pm = try lv.passMap(pf.Colmask.player_path);
    const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 8), @divTrunc(lv.h, 8), 64) orelse return;
    const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 8), lv.h - @divTrunc(lv.h, 8), 64) orelse return;
    const from = pf.Pos{ .level = lv.id, .x = a.x, .y = a.y };
    const to = pf.Pos{ .level = lv.id, .x = b.x, .y = b.y };

    var walk = try f.world.route(from, to, .{});
    defer walk.deinit();
    var tele = try f.world.route(from, to, .{ .teleport = true });
    defer tele.deinit();

    try testing.expect(tele.moveCount() <= walk.moveCount());
    // Every teleport move after the first is a cast, and a cast closes up to 50 subtiles per axis,
    // so a 400-subtile level should never need anything like a walk's worth of them.
    try testing.expect(tele.moveCount() < 40);
}

test "each mask's bitset is exactly that mask over the raw grid" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The mask IS the movement model, so the derived bitsets must be nothing more or less than
    // the mask applied to every cell — including the void fill, which no mask may pass.
    for (f.world.levels.items) |*lv| {
        const player = try lv.passMap(pf.Colmask.player_path);
        const missile = try lv.passMap(pf.Colmask.missile_flight);
        const monster = try lv.passMap(pf.Colmask.monster_path);
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
    var f = try Fixture.load(alloc, &.{0});
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
    var player_occ = try pf.grid.buildPassMap(alloc, occupied, lv.w, lv.h, pf.Colmask.player_path, .point);
    defer player_occ.deinit(alloc);
    var missile_occ = try pf.grid.buildPassMap(alloc, occupied, lv.w, lv.h, pf.Colmask.missile_flight, .point);
    defer missile_occ.deinit(alloc);

    const player_clean = try lv.passMap(pf.Colmask.player_path);
    const missile_clean = try lv.passMap(pf.Colmask.missile_flight);
    try testing.expectEqual(countSet(player_clean) - 64, countSet(&player_occ));
    try testing.expectEqual(countSet(missile_clean), countSet(&missile_occ));
}

fn countSet(pm: *const pf.PassMap) usize {
    var n: usize = 0;
    for (pm.bits) |w| n += @popCount(w);
    return n;
}

test "the Arcane Sanctuary is reachable once portals are in the graph" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{ 0, 1 });
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
    try f.world.levelRoute(40, pf.portals.ARCANE_SANCTUARY, &chain);
    try testing.expectEqual(@as(i32, 40), chain.items[0]);
    try testing.expectEqual(pf.portals.ARCANE_SANCTUARY, chain.items[chain.items.len - 1]);

    var via_palace = false;
    for (chain.items) |id| {
        if (id == pf.portals.PALACE_CELLAR_3) via_palace = true;
    }
    try testing.expect(via_palace);

    // The other side: the Summoner's portal out to the Canyon of the Magi.
    chain.clearRetainingCapacity();
    try f.world.levelRoute(pf.portals.ARCANE_SANCTUARY, pf.portals.CANYON_OF_THE_MAGI, &chain);
    try testing.expectEqual(@as(usize, 2), chain.items.len);
}

test "Lut Gholein routes the length of the Act 2 desert to the Valley of Snakes" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{1});
    defer f.deinit();

    // 40 Lut Gholein -> 41 Rocky Waste -> 42 Dry Hills -> 43 Far Oasis -> 44 Lost City
    // -> 45 Valley of Snakes. Five area borders, all of them outdoor seams rather than warps, so
    // this is the case that exercises seam adjacency end to end.
    const lut_gholein: i32 = 40;
    const valley_of_snakes: i32 = 45;

    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    try f.world.levelRoute(lut_gholein, valley_of_snakes, &chain);
    try testing.expectEqual(lut_gholein, chain.items[0]);
    try testing.expectEqual(valley_of_snakes, chain.items[chain.items.len - 1]);
    try testing.expect(chain.items.len >= 5);

    const from = try centre(f.world.level(lut_gholein).?, pf.Colmask.player_path);
    const to = try centre(f.world.level(valley_of_snakes).?, pf.Colmask.player_path);

    for ([_]bool{ false, true }) |use_teleport| {
        var r = try f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The gate is per-axis, so a cast may span (50,50) — about 70 subtiles of ground. A router that
    // modelled the limit as a 50-radius circle would never emit one. Prove we do.
    const max_cast = pf.teleport.ENGINE_MAX_CAST;
    var longest_euclidean: f64 = 0;
    for (f.world.levels.items) |*lv| {
        if (lv.teleport == .forbidden) continue;
        const pm = try lv.passMap(pf.Colmask.player_path);
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 8), @divTrunc(lv.h, 8), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 8), lv.h - @divTrunc(lv.h, 8), 64) orelse continue;
        var r = f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // The links are harvested from ppDrlgRoomsExNear, which only DRLGROOMEX_LinkNearRoomsByVis
    // fills — so a non-empty total proves the vis-slot linking ran and reached us.
    var total_links: usize = 0;
    for (f.world.levels.items) |*lv| total_links += lv.links.len;
    try testing.expect(total_links > 0);

    // Every link must name a level we loaded and a room index that exists there.
    for (f.world.levels.items) |*lv| {
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
    for (f.world.levels.items) |*lv| {
        for (f.world.levels.items) |*other| {
            if (other.id == lv.id) continue;
            const c = (try pf.World.crossLevelCast(lv, other, .{})) orelse continue;
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const from = try centre(f.world.level(1).?, pf.Colmask.player_path);
    const to = try centre(f.world.level(7).?, pf.Colmask.player_path);
    const a = pf.Pos{ .level = 1, .x = from.x, .y = from.y };
    const b = pf.Pos{ .level = 7, .x = to.x, .y = to.y };

    var walked = try f.world.route(a, b, .{ .teleport = true });
    defer walked.deinit();
    var cast = try f.world.route(a, b, .{ .teleport = true, .teleport_across_levels = true });
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
    var f = try Fixture.load(alloc, &.{1});
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
    for (f.world.levels.items) |*lv| {
        if (lv.id == pf.portals.DURIELS_LAIR) continue;
        try testing.expectEqual(base, lv.teleport.destinationMask(base));
    }
}

test "no emitted waypoint exceeds what a movement command may target" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // SCMD_0x01_WalkToLocation / SCMD_0x03_RunToLocation go through the SAME
    // CheckIfInrangeAndReassign gate as a skill cast, so a waypoint further than 50 subtiles is not
    // a slow walk — the handler drops the packet and resyncs the client. Compression alone happily
    // emits 100-subtile straight runs, so this is the check that keeps the output drivable.
    const gate = pf.ENGINE_MAX_COMMAND_RANGE;
    var checked: usize = 0;

    for (f.world.levels.items) |*lv| {
        const pm = try lv.passMap(pf.Colmask.player_path);
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 6), @divTrunc(lv.h, 6), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 6), lv.h - @divTrunc(lv.h, 6), 64) orelse continue;

        for ([_]bool{ false, true }) |tele| {
            var r = f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    var hug_off: usize = 0;
    var hug_on: usize = 0;
    var nodes_off: usize = 0;
    var nodes_on: usize = 0;

    for (f.world.levels.items) |*lv| {
        const pm = try lv.passMap(pf.Colmask.player_path);
        const cl = pm.clearance();
        const a = pf.grid.nearestPassable(pm, @divTrunc(lv.w, 6), @divTrunc(lv.h, 6), 64) orelse continue;
        const b = pf.grid.nearestPassable(pm, lv.w - @divTrunc(lv.w, 6), lv.h - @divTrunc(lv.h, 6), 64) orelse continue;

        for ([_]pf.WallAversion{ .{ .desired = 0 }, .{} }, 0..) |av, which| {
            var r = f.world.route(
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
    var pm = try pf.grid.buildPassMap(alloc, cells, 9, 9, pf.Colmask.player_path, .point);
    defer pm.deinit(alloc);
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // Rogue Encampment -> Blood Moor -> Cold Plains -> Stony Field -> Dark Wood -> Black Marsh ->
    // Tamoe Highland -> Monastery Gate -> Outer Cloister -> Barracks -> Jail 1/2/3 -> Inner
    // Cloister -> Cathedral -> Catacombs 1..4. Outdoor seams, then warp doors, then the
    // door-heavy Jail and Catacombs run.
    const ANDARIEL: i32 = 37; // Catacombs Level 4
    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    try f.world.levelRoute(1, ANDARIEL, &chain);

    try testing.expectEqual(@as(i32, 1), chain.items[0]);
    try testing.expectEqual(ANDARIEL, chain.items[chain.items.len - 1]);
    // The Catacombs are only reachable through the Cathedral, which is only reachable through the
    // Inner Cloister -- so the tail of the chain is forced and worth pinning.
    for ([_]i32{ 33, 34, 35, 36, 37 }) |want| {
        try testing.expect(std.mem.indexOfScalar(i32, chain.items, want) != null);
    }

    const from = try centre(f.world.level(1).?, pf.Colmask.player_path);
    const to = try centre(f.world.level(ANDARIEL).?, pf.Colmask.player_path);
    for ([_]bool{ false, true }) |tele| {
        var r = try f.world.route(
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
    var f = try Fixture.load(alloc, &.{0});
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
    const from = try centre(f.world.level(28).?, pf.Colmask.player_path);
    const to = try centre(f.world.level(31).?, pf.Colmask.player_path);
    var r = try f.world.route(
        .{ .level = 28, .x = from.x, .y = from.y },
        .{ .level = 31, .x = to.x, .y = to.y },
        .{},
    );
    defer r.deinit();

    var passed: std.ArrayListUnmanaged(pf.RouteDoor) = .empty;
    defer passed.deinit(alloc);
    try f.world.doorsAlong(&r, 12, &passed);
    var last_leg: usize = 0;
    for (passed.items) |rd| {
        try testing.expect(rd.leg >= last_leg); // in the order they are met
        last_leg = rd.leg;
        try testing.expect(rd.move < r.legs[rd.leg].moves.len);
    }
}

test "the whole game connects, bar one known hole" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{ 0, 1, 2, 3, 4 });
    defer f.deinit();
    try testing.expect(f.world.levels.items.len > 120);

    // Act 1 and Act 2 route forward from the start, boss to boss.
    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    for ([_][2]i32{ .{ 1, 37 }, .{ 37, 73 } }) |leg| {
        chain.clearRetainingCapacity();
        try f.world.levelRoute(leg[0], leg[1], &chain);
        try testing.expectEqual(leg[0], chain.items[0]);
        try testing.expectEqual(leg[1], chain.items[chain.items.len - 1]);
    }
    // Act 4 into Act 5, all the way past Baal. Baal is fought in the Throne of Destruction (131);
    // the Worldstone Chamber (132) beyond it is reached through the portal he opens on dying, which
    // portals.zig carries because map generation correctly emits no warp for a quest-gated link.
    for ([_][2]i32{ .{ 102, 108 }, .{ 108, 131 }, .{ 131, 132 } }) |leg| {
        chain.clearRetainingCapacity();
        try f.world.levelRoute(leg[0], leg[1], &chain);
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
    try f.world.levelRoute(75, 102, &chain);
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
    for (f.world.levels.items) |*lv| {
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
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    // Act 1 alone cannot reach an Act 3 level: no warp, no seam, no portal.
    try testing.expectError(error.NoLevelRoute, f.world.levelRoute(1, 83, &chain));
}

test "a bigger footprint is blocked by gaps a point walks through" {
    const alloc = testing.allocator;
    // A 1-subtile-wide corridor down the middle of a solid block. A point-sized unit fits; the
    // cross (CheckCollision_Cross) needs its east/west neighbours and does not; nor does the 3x3.
    var cells = [_]u16{pf.Colbit.wall} ** (9 * 9);
    for (0..9) |y| cells[y * 9 + 4] = 0;

    for ([_]struct { fp: pf.grid.Footprint, want: bool }{
        .{ .fp = .point, .want = true },
        .{ .fp = .cross, .want = false },
        .{ .fp = .box3, .want = false },
    }) |c| {
        var pm = try pf.grid.buildPassMap(alloc, &cells, 9, 9, pf.Colmask.player_path, c.fp);
        defer pm.deinit(alloc);
        try testing.expectEqual(c.want, pm.passable(4, 4));
    }
}

test "the cross clears a 3-wide corridor that the 3x3 box also clears" {
    const alloc = testing.allocator;
    var cells = [_]u16{pf.Colbit.wall} ** (9 * 9);
    for (0..9) |y| {
        for (3..6) |x| cells[y * 9 + x] = 0;
    }

    var cross = try pf.grid.buildPassMap(alloc, &cells, 9, 9, pf.Colmask.player_path, .cross);
    defer cross.deinit(alloc);
    var box = try pf.grid.buildPassMap(alloc, &cells, 9, 9, pf.Colmask.player_path, .box3);
    defer box.deinit(alloc);

    // Centre of the corridor: both fit. One subtile off centre: neither does, because the shape
    // then reaches into the wall.
    try testing.expect(cross.passable(4, 4));
    try testing.expect(box.passable(4, 4));
    try testing.expect(!cross.passable(3, 4));
    try testing.expect(!box.passable(3, 4));
}

test "footprint maps are cached per (mask, footprint) and are real alternatives" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const point = try lv.passMapFor(pf.Colmask.player_path, .point);
    const box = try lv.passMapFor(pf.Colmask.player_path, .box3);
    try testing.expect(point != box);
    try testing.expectEqual(point, try lv.passMapFor(pf.Colmask.player_path, .point));

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

test "the tracer stops on the first blocking cell and reports it" {
    const alloc = testing.allocator;
    // Open 9x9 with a vertical wall at x = 4.
    var cells = [_]u16{0} ** (9 * 9);
    for (0..9) |y| cells[y * 9 + 4] = pf.Colbit.wall;

    var pm = try pf.grid.buildPassMap(alloc, &cells, 9, 9, pf.Colmask.player_path, .point);
    defer pm.deinit(alloc);

    const hit = pf.grid.trace(&pm, .{ .x = 0, .y = 4 }, .{ .x = 8, .y = 4 });
    try testing.expect(hit.blocked);
    try testing.expectEqual(@as(i32, 4), hit.at.x);
    try testing.expectEqual(@as(i32, 4), hit.at.y);
    try testing.expect(!pf.grid.hasLineOfSight(&pm, .{ .x = 0, .y = 4 }, .{ .x = 8, .y = 4 }));

    // Along the wall, never across it.
    try testing.expect(pf.grid.hasLineOfSight(&pm, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 8 }));
    // Both endpoints are tested: aiming AT the wall is blocked even from right beside it.
    try testing.expect(!pf.grid.hasLineOfSight(&pm, .{ .x = 3, .y = 4 }, .{ .x = 4, .y = 4 }));
    // A cell is traced against itself.
    try testing.expect(pf.grid.hasLineOfSight(&pm, .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 }));
    try testing.expect(!pf.grid.hasLineOfSight(&pm, .{ .x = 4, .y = 3 }, .{ .x = 4, .y = 3 }));
}

test "an open grid traces clear in every direction, and leaving it blocks" {
    const alloc = testing.allocator;
    var open = [_]u16{0} ** (9 * 9);
    var pm = try pf.grid.buildPassMap(alloc, &open, 9, 9, pf.Colmask.player_path, .point);
    defer pm.deinit(alloc);

    var a: i32 = 0;
    while (a < 9) : (a += 1) {
        var b: i32 = 0;
        while (b < 9) : (b += 1) {
            try testing.expect(pf.grid.hasLineOfSight(&pm, .{ .x = 0, .y = a }, .{ .x = 8, .y = b }));
            try testing.expect(pf.grid.hasLineOfSight(&pm, .{ .x = a, .y = 0 }, .{ .x = b, .y = 8 }));
        }
    }
    // Off the grid is the engine's null-room case: blocked.
    try testing.expect(!pf.grid.hasLineOfSight(&pm, .{ .x = 4, .y = 4 }, .{ .x = 20, .y = 4 }));
    try testing.expect(!pf.grid.hasLineOfSight(&pm, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = -3 }));
}

test "line of sight is direction-dependent, as it is in the engine" {
    const alloc = testing.allocator;
    // A single blocking cell off the centre line. Bresenham visits a different chain of cells
    // depending on which end it starts from, so a thin obstacle can be clipped one way and
    // missed the other. TestCollision (0x64e260) has exactly this property, and the server
    // always traces FROM THE CASTER — so a bot must ask the question in that direction.
    var cells = [_]u16{0} ** (9 * 9);
    cells[3 * 9 + 6] = pf.Colbit.wall;
    var pm = try pf.grid.buildPassMap(alloc, &cells, 9, 9, pf.Colmask.player_path, .point);
    defer pm.deinit(alloc);

    var asymmetric: usize = 0;
    var a: i32 = 0;
    while (a < 9) : (a += 1) {
        var b: i32 = 0;
        while (b < 9) : (b += 1) {
            const fwd = pf.grid.hasLineOfSight(&pm, .{ .x = 0, .y = a }, .{ .x = 8, .y = b });
            const rev = pf.grid.hasLineOfSight(&pm, .{ .x = 8, .y = b }, .{ .x = 0, .y = a });
            if (fwd != rev) asymmetric += 1;
        }
    }
    try testing.expect(asymmetric > 0);
}

test "a missile flies where a player cannot walk" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    // A GENERATED grid cannot show this: every missile_barrier cell it emits also carries wall,
    // and noplayer/object/door never appear at all - they are runtime occupancy a live host ORs
    // in. So overlay what a host would: an object (blocks the player, not a missile) and a bare
    // missile barrier (blocks the missile, not the player), and check both models react.
    const lv = f.world.level(2) orelse return error.NoLevel;
    const walk_base = try lv.passMapFor(pf.Colmask.player_path, .point);
    const open = pf.grid.nearestPassable(walk_base, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), 128) orelse
        return error.NoPassableCell;
    // Three cells in a row, all clear, so a trace along them is unobstructed to begin with.
    if (!walk_base.passable(open.x + 1, open.y) or !walk_base.passable(open.x + 2, open.y)) return;

    const cells = try alloc.dupe(u16, lv.cells);
    defer alloc.free(cells);
    const obj_at: usize = @intCast(open.y * lv.w + open.x + 1);
    cells[obj_at] = pf.Colbit.object;

    var walk = try pf.grid.buildPassMap(alloc, cells, lv.w, lv.h, pf.Colmask.player_path, .point);
    defer walk.deinit(alloc);
    var fly = try pf.grid.buildPassMap(alloc, cells, lv.w, lv.h, pf.Colmask.missile_flight, .point);
    defer fly.deinit(alloc);

    const from = open;
    const to = pf.Point{ .x = open.x + 2, .y = open.y };
    try testing.expect(!pf.grid.hasLineOfSight(&walk, from, to)); // the object stops the player
    try testing.expect(pf.grid.hasLineOfSight(&fly, from, to)); // and not the missile

    // And the reverse: a barrier with no wall bit stops only the missile.
    cells[obj_at] = pf.Colbit.missile_barrier;
    var walk2 = try pf.grid.buildPassMap(alloc, cells, lv.w, lv.h, pf.Colmask.player_path, .point);
    defer walk2.deinit(alloc);
    var fly2 = try pf.grid.buildPassMap(alloc, cells, lv.w, lv.h, pf.Colmask.missile_flight, .point);
    defer fly2.deinit(alloc);
    try testing.expect(pf.grid.hasLineOfSight(&walk2, from, to));
    try testing.expect(!pf.grid.hasLineOfSight(&fly2, from, to));

    const stop = pf.grid.trace(&fly2, from, to);
    try testing.expectEqual(open.x + 1, stop.at.x);
}
