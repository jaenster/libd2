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
    var player_occ = try pf.grid.buildPassMap(alloc, occupied, lv.w, lv.h, pf.Colmask.player_path);
    defer player_occ.deinit(alloc);
    var missile_occ = try pf.grid.buildPassMap(alloc, occupied, lv.w, lv.h, pf.Colmask.missile_flight);
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

test "an unreachable level fails fast instead of searching" {
    const alloc = testing.allocator;
    var f = try Fixture.load(alloc, &.{0});
    defer f.deinit();

    var chain: std.ArrayListUnmanaged(i32) = .empty;
    defer chain.deinit(alloc);
    // Act 1 alone cannot reach an Act 3 level: no warp, no seam, no portal.
    try testing.expectError(error.NoLevelRoute, f.world.levelRoute(1, 83, &chain));
}
