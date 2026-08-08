//! The loaded world: every level of every act you asked for, and how they connect.
//!
//! Generation happens once, here. `loadAct` runs d2-drlg for an act and turns each level into a
//! `Level` — its collision grid, its rooms, its preset units, its exits — and keeps them. After
//! that a `World` is what a running game holds: the map as it stands, including whoever is walking
//! around on it. Nothing here searches; searching is d2-pathfinding's job, over exactly this.
//!
//! Levels are held BY POINTER so that loading another act cannot move one. Everything that
//! remembers a level — a unit's home, a cached passability view, a route in flight — holds
//! `*Level`, and that has to survive the next act being generated.

const std = @import("std");
const drlg = @import("d2-drlg");
const d2data = @import("d2-data");
const core = @import("d2-core");
const collision = core.collision;

const rooms_mod = @import("rooms.zig");
const level_mod = @import("level.zig");
const portals = @import("portals.zig");
const occupancy = @import("occupancy.zig");

pub const Level = level_mod.Level;
pub const Exit = level_mod.Exit;
pub const Door = level_mod.Door;
pub const Point = level_mod.Point;

pub const Error = error{
    UnknownLevel,
    NoLevelRoute,
} || std.mem.Allocator.Error;

pub const World = struct {
    alloc: std.mem.Allocator,
    seed: u32,
    difficulty: drlg.Difficulty,
    /// By pointer: see the module comment. Owned.
    levels: std.ArrayListUnmanaged(*Level) = .empty,
    /// Level id -> index into `levels`.
    by_id: std.AutoHashMapUnmanaged(i32, u32) = .empty,
    /// Levels.txt `Teleport` by level id, parsed once at first load.
    teleport_rule: []level_mod.TeleportRule = &.{},
    /// Objects.txt `OperateFn` for every row NAMED "door", by class id; -1 for everything else.
    /// Parsed once at first load rather than transcribed, so a data change cannot leave a stale
    /// hardcoded list behind.
    door_fn: []i16 = &.{},
    /// Objects.txt ids whose `OperateFn` is 27 — the teleport pads. Indexed by class id.
    pad_class: []bool = &.{},

    pub fn init(alloc: std.mem.Allocator, seed: u32, difficulty: drlg.Difficulty) World {
        return .{ .alloc = alloc, .seed = seed, .difficulty = difficulty };
    }

    pub fn deinit(self: *World) void {
        for (self.levels.items) |l| {
            l.deinit();
            self.alloc.destroy(l);
        }
        self.levels.deinit(self.alloc);
        self.by_id.deinit(self.alloc);
        if (self.teleport_rule.len != 0) self.alloc.free(self.teleport_rule);
        if (self.door_fn.len != 0) self.alloc.free(self.door_fn);
        if (self.pad_class.len != 0) self.alloc.free(self.pad_class);
        self.* = undefined;
    }

    pub fn level(self: *World, id: i32) ?*Level {
        const idx = self.by_id.get(id) orelse return null;
        return self.levels.items[idx];
    }

    pub fn loadAct(self: *World, ctx: *drlg.Ctx, act_no: i32) !void {
        if (self.teleport_rule.len == 0) self.teleport_rule = try parseTeleportColumn(self.alloc);
        if (self.door_fn.len == 0) self.door_fn = try parseDoorClasses(self.alloc);
        if (self.pad_class.len == 0) self.pad_class = try parsePadClasses(self.alloc);

        var full = try drlg.generateActFull(ctx, self.alloc, act_no, self.seed, self.difficulty, .{
            .room_links = true,
            .raw_collision = true,
        });
        defer full.deinit(self.alloc);

        for (full.levels) |lf| {
            if (lf.coll_w <= 0 or lf.coll_h <= 0 or lf.raw.len == 0) continue;
            try self.addLevel(ctx, lf);
        }
    }

    fn addLevel(self: *World, ctx: *drlg.Ctx, lf: drlg.LevelFull) !void {
        _ = ctx;
        const w = lf.coll_w;
        const h = lf.coll_h;
        const cell_count: usize = @intCast(w * h);

        // `raw_collision` skips the deflate a pathfinder would only undo again: the grid arrives
        // as LE u16 bytes, which on a little-endian host is already the cell array.
        const cells = try self.alloc.alloc(u16, cell_count);
        errdefer self.alloc.free(cells);
        if (@import("builtin").cpu.arch.endian() == .little) {
            @memcpy(std.mem.sliceAsBytes(cells), lf.raw[0 .. cell_count * @sizeOf(u16)]);
        } else {
            for (cells, 0..) |*c, i| c.* = std.mem.readInt(u16, lf.raw[i * 2 ..][0..2], .little);
        }

        // Room boxes come out of drlg in WORLD tiles; rebase them onto this level's own frame so
        // rooms, collision and positions all agree.
        var boxes = try self.alloc.alloc(rooms_mod.Room, lf.meta.rooms.len);
        defer self.alloc.free(boxes);
        for (lf.meta.rooms, 0..) |r, i| boxes[i] = .{
            .x = r.x - lf.meta.origin_x,
            .y = r.y - lf.meta.origin_y,
            .w = r.w,
            .h = r.h,
        };
        var room_set = try rooms_mod.build(
            self.alloc,
            boxes,
            @divTrunc(w, level_mod.SUBTILES_PER_TILE),
            @divTrunc(h, level_mod.SUBTILES_PER_TILE),
        );
        errdefer room_set.deinit(self.alloc);

        const exits = try self.alloc.alloc(Exit, lf.adjacents.len);
        errdefer self.alloc.free(exits);
        for (lf.adjacents, 0..) |a, i| exits[i] = .{
            .to_level = a.dest_level_id,
            .x = a.x,
            .y = a.y,
            .kind = switch (a.kind) {
                .warp => .warp,
                .seam => .seam,
            },
        };

        const links = try self.alloc.dupe(drlg.RoomLink, lf.room_links);
        errdefer self.alloc.free(links);
        const presets = try self.alloc.dupe(drlg.PresetUnit, lf.presets);
        errdefer self.alloc.free(presets);
        const pads = try self.buildPads(presets, &room_set);
        errdefer self.alloc.free(pads);

        const id = lf.meta.level_id;
        var units = try occupancy.Occupancy.init(self.alloc, w, h);
        errdefer units.deinit();

        const lv = try self.alloc.create(Level);
        errdefer self.alloc.destroy(lv);
        lv.* = .{
            .id = id,
            .origin_x = lf.meta.origin_x,
            .origin_y = lf.meta.origin_y,
            .w = w,
            .h = h,
            .cells = cells,
            .rooms = room_set,
            .links = links,
            .pads = pads,
            .presets = presets,
            .exits = exits,
            .teleport = self.teleportRuleFor(id),
            .alloc = self.alloc,
            .units = units,
        };
        try self.levels.append(self.alloc, lv);
        try self.by_id.put(self.alloc, id, @intCast(self.levels.items.len - 1));
    }

    fn teleportRuleFor(self: *const World, id: i32) level_mod.TeleportRule {
        if (id < 0 or @as(usize, @intCast(id)) >= self.teleport_rule.len) return .allowed;
        return self.teleport_rule[@intCast(id)];
    }

    /// Where a quest portal out of `from_level` toward `to_level` stands, if the map data marks it
    /// with an object. Lets a character be routed to a portal that is not open yet — the object is
    /// placed from the start even though the link is not usable until the quest fires.
    pub fn questPortalSite(self: *World, from_level: i32, to_level: i32) !?Point {
        const lv = self.level(from_level) orelse return error.UnknownLevel;
        for (portals.LINKS) |link| {
            if (link.from != from_level or link.to != to_level) continue;
            const cls = link.object_id orelse continue;
            for (lv.presets) |unit| {
                if (unit.etype == 2 and unit.txt_file_no == cls) return .{ .x = unit.x, .y = unit.y };
            }
        }
        return null;
    }

    /// Every DOOR on a level, in that level's local subtiles.
    ///
    /// Doors matter to a mover but not to the search. The generated collision grid carries no door
    /// bit at all — `COLBIT_DOOR` is runtime occupancy a host ORs in while a door is shut — so a
    /// path already runs straight through a doorway, which is correct: a walking character opens
    /// what it walks into. What the search cannot do is tell you that you will have to. These are
    /// the positions to check a route against so the mover knows to stop and open one.
    ///
    /// (Teleport sidesteps the question: a cast passes through the wall the door sits in. It only
    /// cannot LAND on the door's own cell, since `COLMASK_PLAYER_PATH` includes 0x800.)
    pub fn doorsOn(self: *World, level_id: i32, out: *std.ArrayListUnmanaged(Door)) !void {
        const lv = self.level(level_id) orelse return error.UnknownLevel;
        for (lv.presets) |unit| {
            if (unit.etype != 2) continue;
            const cls = unit.txt_file_no;
            if (cls < 0 or @as(usize, @intCast(cls)) >= self.door_fn.len) continue;
            const ofn = self.door_fn[@intCast(cls)];
            if (ofn < 0) continue;
            try out.append(self.alloc, .{ .class_id = cls, .x = unit.x, .y = unit.y, .operate_fn = ofn });
        }
    }

    /// The doors a route passes within `radius` subtiles of, in the order they are met. This is the
    /// list a mover needs: "on leg 3, at this waypoint, there is a door to open".
    pub fn exitsOf(self: *World, id: i32, buf: *std.ArrayListUnmanaged(Exit)) !void {
        if (self.level(id)) |lv| try buf.appendSlice(self.alloc, lv.exits);
        for (portals.LINKS) |link| {
            if (link.from == id) {
                try buf.append(self.alloc, .{ .to_level = link.to, .x = -1, .y = -1, .kind = .portal });
            } else if (link.to == id and !link.one_way) {
                try buf.append(self.alloc, .{ .to_level = link.from, .x = -1, .y = -1, .kind = .portal });
            }
        }
    }

    /// The chain of levels from `from` to `to`, breadth-first over the level graph. Breadth-first
    /// on level COUNT (rather than weighted by in-level distance) because that is what actually
    /// costs a player time — every transition is a loading screen and a walk to a staircase, and
    /// the alternative routes through one extra area are essentially never worth it.
    pub fn levelRoute(self: *World, from: i32, to: i32, out: *std.ArrayListUnmanaged(i32)) !void {
        if (from == to) {
            try out.append(self.alloc, from);
            return;
        }
        var came: std.AutoHashMapUnmanaged(i32, i32) = .empty;
        defer came.deinit(self.alloc);
        var queue: std.ArrayListUnmanaged(i32) = .empty;
        defer queue.deinit(self.alloc);
        var scratch: std.ArrayListUnmanaged(Exit) = .empty;
        defer scratch.deinit(self.alloc);

        try came.put(self.alloc, from, from);
        try queue.append(self.alloc, from);
        var head: usize = 0;
        var found = false;
        while (head < queue.items.len and !found) : (head += 1) {
            const cur = queue.items[head];
            scratch.clearRetainingCapacity();
            try self.exitsOf(cur, &scratch);
            for (scratch.items) |e| {
                if (came.contains(e.to_level)) continue;
                try came.put(self.alloc, e.to_level, cur);
                if (e.to_level == to) {
                    found = true;
                    break;
                }
                try queue.append(self.alloc, e.to_level);
            }
        }
        if (!found) return error.NoLevelRoute;

        const first = out.items.len;
        var cur = to;
        while (cur != from) {
            try out.append(self.alloc, cur);
            cur = came.get(cur).?;
        }
        try out.append(self.alloc, from);
        std.mem.reverse(i32, out.items[first..]);
    }

    /// The whole thing: a route from `from` to `to`, across as many levels as it takes.
    fn buildPads(self: *World, presets: []const drlg.PresetUnit, room_set: *const rooms_mod.RoomSet) ![]level_mod.Pad {
        var out: std.ArrayListUnmanaged(level_mod.Pad) = .empty;
        errdefer out.deinit(self.alloc);

        for (presets, 0..) |p, i| {
            if (p.etype != 2) continue;
            const cid = p.txt_file_no;
            if (cid < 0 or @as(usize, @intCast(cid)) >= self.pad_class.len) continue;
            if (!self.pad_class[@intCast(cid)]) continue;
            const my_room = room_set.atSubtile(p.x, p.y) orelse continue;

            var same: ?Point = null;
            var near: ?Point = null;
            for (presets, 0..) |q, j| {
                if (i == j or q.etype != 2 or q.txt_file_no != cid) continue;
                const qr = room_set.atSubtile(q.x, q.y) orelse continue;
                if (qr == my_room) {
                    same = .{ .x = q.x, .y = q.y };
                    break;
                }
                if (near == null and room_set.canTeleportBetween(my_room, qr)) near = .{ .x = q.x, .y = q.y };
            }
            const to = same orelse near orelse continue;
            try out.append(self.alloc, .{ .at = .{ .x = p.x, .y = p.y }, .to = to, .class_id = cid });
        }
        return out.toOwnedSlice(self.alloc);
    }

};

fn parseTeleportColumn(alloc: std.mem.Allocator) ![]level_mod.TeleportRule {
    const text = d2data.file("Levels");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return error.InvalidTable;

    var id_col: ?usize = null;
    var tele_col: ?usize = null;
    {
        var cols = std.mem.splitScalar(u8, header, '\t');
        var i: usize = 0;
        while (cols.next()) |c| : (i += 1) {
            const name = std.mem.trim(u8, c, "\r");
            if (std.mem.eql(u8, name, "Id")) id_col = i;
            if (std.mem.eql(u8, name, "Teleport")) tele_col = i;
        }
    }
    const idc = id_col orelse return error.InvalidTable;
    const tc = tele_col orelse return error.InvalidTable;

    var rows: std.ArrayListUnmanaged(level_mod.TeleportRule) = .empty;
    errdefer rows.deinit(alloc);
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, "\r \t").len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        var i: usize = 0;
        var id: ?i32 = null;
        var tele: u8 = 1;
        while (cols.next()) |c| : (i += 1) {
            const v = std.mem.trim(u8, c, "\r ");
            if (i == idc) id = std.fmt.parseInt(i32, v, 10) catch null;
            if (i == tc) tele = std.fmt.parseInt(u8, v, 10) catch 1;
        }
        const lid = id orelse continue;
        if (lid < 0) continue;
        const want: usize = @intCast(lid + 1);
        if (rows.items.len < want) try rows.appendNTimes(alloc, .allowed, want - rows.items.len);
        rows.items[@intCast(lid)] = switch (tele) {
            0 => .forbidden,
            2 => .gated,
            else => .allowed,
        };
    }
    return rows.toOwnedSlice(alloc);
}

/// Objects.txt rows NAMED "door", mapped id -> OperateFn (-1 where the row is not a door).
///
/// Matching on the name rather than on OperateFn deliberately: the ordinary door is OperateFn 8,
/// but secret doors (18), the Act 3 slime doors (29) and Tyrael's door (0) are doors too, and a
/// route should mention them. "TrappDoor" is excluded by the exact-name match — it is a level
/// transition, not something you open.
/// Objects.txt ids with `OperateFn` 27, indexed by class id. Exactly four rows have it and all
/// four are teleport pads (192, 304, 305, 306), so the column IS the selector — no name matching
/// needed and no false positives to filter.
fn parsePadClasses(alloc: std.mem.Allocator) ![]bool {
    const text = d2data.file("Objects");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return error.InvalidTable;

    var id_col: ?usize = null;
    var fn_col: ?usize = null;
    {
        var cols = std.mem.splitScalar(u8, header, '\t');
        var i: usize = 0;
        while (cols.next()) |c| : (i += 1) {
            const name = std.mem.trim(u8, c, "\r");
            if (std.mem.eql(u8, name, "Id")) id_col = i;
            if (std.mem.eql(u8, name, "OperateFn")) fn_col = i;
        }
    }
    const idc = id_col orelse return error.InvalidTable;
    const fc = fn_col orelse return error.InvalidTable;

    var out: std.ArrayListUnmanaged(bool) = .empty;
    errdefer out.deinit(alloc);
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, "\r \t").len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        var i: usize = 0;
        var id: ?i32 = null;
        var ofn: i16 = -1;
        while (cols.next()) |c| : (i += 1) {
            const v = std.mem.trim(u8, c, "\r ");
            if (i == idc) id = std.fmt.parseInt(i32, v, 10) catch null;
            if (i == fc) ofn = std.fmt.parseInt(i16, v, 10) catch -1;
        }
        const cid = id orelse continue;
        if (cid < 0) continue;
        const want: usize = @intCast(cid + 1);
        if (out.items.len < want) try out.appendNTimes(alloc, false, want - out.items.len);
        if (ofn == 27) out.items[@intCast(cid)] = true;
    }
    return out.toOwnedSlice(alloc);
}

fn parseDoorClasses(alloc: std.mem.Allocator) ![]i16 {
    const text = d2data.file("Objects");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return error.InvalidTable;

    var id_col: ?usize = null;
    var fn_col: ?usize = null;
    var name_col: ?usize = null;
    {
        var cols = std.mem.splitScalar(u8, header, '\t');
        var i: usize = 0;
        while (cols.next()) |c| : (i += 1) {
            const name = std.mem.trim(u8, c, "\r");
            if (std.mem.eql(u8, name, "Id")) id_col = i;
            if (std.mem.eql(u8, name, "OperateFn")) fn_col = i;
            if (name_col == null and std.mem.eql(u8, name, "Name")) name_col = i;
        }
    }
    const idc = id_col orelse return error.InvalidTable;
    const fc = fn_col orelse return error.InvalidTable;
    const nc = name_col orelse return error.InvalidTable;

    var out: std.ArrayListUnmanaged(i16) = .empty;
    errdefer out.deinit(alloc);
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, "\r \t").len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        var i: usize = 0;
        var id: ?i32 = null;
        var is_door = false;
        var ofn: i16 = 0;
        while (cols.next()) |c| : (i += 1) {
            const v = std.mem.trim(u8, c, "\r ");
            if (i == idc) id = std.fmt.parseInt(i32, v, 10) catch null;
            if (i == nc) is_door = std.ascii.eqlIgnoreCase(v, "door");
            if (i == fc) ofn = std.fmt.parseInt(i16, v, 10) catch 0;
        }
        const cid = id orelse continue;
        if (cid < 0) continue;
        const want: usize = @intCast(cid + 1);
        if (out.items.len < want) try out.appendNTimes(alloc, -1, want - out.items.len);
        if (is_door) out.items[@intCast(cid)] = ofn;
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "Levels.txt Teleport parses to the rule the engine applies" {
    const alloc = testing.allocator;
    const rules = try parseTeleportColumn(alloc);
    defer alloc.free(rules);

    // Only the Null level refuses teleport outright, and only Duriel's Lair gates the
    // destination — that is what Skills_SrvDoFunc_027_Teleport's two branches key on.
    try testing.expectEqual(level_mod.TeleportRule.forbidden, rules[0]);
    try testing.expectEqual(level_mod.TeleportRule.gated, rules[portals.DURIELS_LAIR]);
    try testing.expectEqual(level_mod.TeleportRule.allowed, rules[portals.ARCANE_SANCTUARY]);
    try testing.expectEqual(level_mod.TeleportRule.allowed, rules[1]);

    var forbidden: usize = 0;
    var gated: usize = 0;
    for (rules) |r| {
        if (r == .forbidden) forbidden += 1;
        if (r == .gated) gated += 1;
    }
    try testing.expectEqual(@as(usize, 1), forbidden);
    try testing.expectEqual(@as(usize, 1), gated);
}

/// A real Act 1 at a fixed seed. Generation is the slow part (~150 ms); everything after is
/// microseconds, so the tests that need a genuine map share one.
const Fixture = struct {
    ctx: drlg.Ctx,
    world: World,

    const SEED: u32 = 0x13572468;

    fn load(alloc: std.mem.Allocator, act: i32) !Fixture {
        var f = Fixture{ .ctx = try drlg.Ctx.init(alloc), .world = World.init(alloc, SEED, .normal) };
        try f.world.loadAct(&f.ctx, act);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.ctx.deinit();
    }
};

/// The first walkable subtile on a level, scanning row-major — a position that exists on every
/// level, so a test need not hard-code coordinates that depend on the seed.
fn anyOpenCell(lv: *const Level, mask: u16) ?Point {
    var y: i32 = 0;
    while (y < lv.h) : (y += 1) {
        var x: i32 = 0;
        while (x < lv.w) : (x += 1) {
            if (lv.passable(x, y, mask)) return .{ .x = x, .y = y };
        }
    }
    return null;
}

test "an act loads into levels that carry collision, rooms and exits" {
    const alloc = std.testing.allocator;
    var f = try Fixture.load(alloc, 0);
    defer f.deinit();

    try std.testing.expect(f.world.levels.items.len >= 30);
    const town = f.world.level(1) orelse return error.NoTown;
    try std.testing.expect(town.w > 0 and town.h > 0);
    try std.testing.expect(town.rooms.rooms.len > 0);
    try std.testing.expectEqual(level_mod.TeleportRule.allowed, town.teleport);
    try std.testing.expect(anyOpenCell(town, collision.Colmask.player_path) != null);
}

test "a monster claims ground the moment it is added and gives it back when it leaves" {
    const alloc = std.testing.allocator;
    var f = try Fixture.load(alloc, 0);
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const mask = collision.Colmask.player_path;
    const spot = anyOpenCell(lv, mask) orelse return error.NoOpenCell;

    try lv.addUnit(1, spot, .monster(2, false, .{}));
    try std.testing.expect(!lv.passable(spot.x, spot.y, mask));
    // Terrain is untouched: only the live half answered differently.
    try std.testing.expect(lv.at(spot.x, spot.y) & mask == 0);
    try std.testing.expectEqual(@as(u64, 0), lv.terrain_gen);

    lv.removeUnit(1);
    try std.testing.expect(lv.passable(spot.x, spot.y, mask));
    try std.testing.expect(lv.units.isEmpty());
}

test "a player walks past a monster but a monster does not walk past a pet" {
    const alloc = std.testing.allocator;
    var f = try Fixture.load(alloc, 0);
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const spot = anyOpenCell(lv, collision.Colmask.player_path) orelse return error.NoOpenCell;

    // A boss/champion is promoted to a PET shape, which claims ground with `pet` rather than
    // `nopath` — and only monster_path carries `pet`.
    try lv.addUnit(1, spot, .monster(2, true, .{}));
    try std.testing.expect(lv.passable(spot.x, spot.y, collision.Colmask.player_path));
    try std.testing.expect(!lv.passable(spot.x, spot.y, collision.Colmask.monster_path));
}

test "opening terrain changes the grid itself and says so" {
    const alloc = std.testing.allocator;
    var f = try Fixture.load(alloc, 0);
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    var wall: ?Point = null;
    for (0..@intCast(lv.w * lv.h)) |i| {
        const v = lv.cells[i];
        if (v == collision.VOID or v & collision.Colbit.wall == 0) continue;
        wall = .{ .x = @intCast(i % @as(usize, @intCast(lv.w))), .y = @intCast(i / @as(usize, @intCast(lv.w))) };
        break;
    }
    const p = wall orelse return error.NoWall;
    const mask = collision.Colmask.player_path;
    try std.testing.expect(!lv.passable(p.x, p.y, mask));

    try std.testing.expect(lv.editTerrain(.at(p.x, p.y), .{ .remove = mask }));
    try std.testing.expect(lv.passable(p.x, p.y, mask));
    try std.testing.expectEqual(@as(u64, 1), lv.terrain_gen);
    // A no-op edit does not bump the generation, so a consumer's cache is not thrown away for free.
    try std.testing.expect(!lv.editTerrain(.at(p.x, p.y), .{ .remove = mask }));
    try std.testing.expectEqual(@as(u64, 1), lv.terrain_gen);
}

test "line of sight sees a unit that a mask cares about and ignores one it does not" {
    const alloc = std.testing.allocator;
    var f = try Fixture.load(alloc, 0);
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const mask = collision.Colmask.player_path;

    // Find a clear horizontal run of five cells so the trace has something to walk.
    var from: ?Point = null;
    var y: i32 = 0;
    outer: while (y < lv.h) : (y += 1) {
        var x: i32 = 0;
        while (x + 4 < lv.w) : (x += 1) {
            var ok = true;
            for (0..5) |k| {
                if (!lv.passable(x + @as(i32, @intCast(k)), y, mask)) ok = false;
            }
            if (ok) {
                from = .{ .x = x, .y = y };
                break :outer;
            }
        }
    }
    const a = from orelse return error.NoClearRun;
    const b: Point = .{ .x = a.x + 4, .y = a.y };
    try std.testing.expect(lv.hasLineOfSight(a, b, mask));

    // A monster in the middle blocks a trace with the path mask (it carries `nopath`)...
    try lv.addUnit(1, .{ .x = a.x + 2, .y = a.y }, .monster(2, false, .{}));
    try std.testing.expect(!lv.hasLineOfSight(a, b, mask));
    // ...and not one with the terrain-only mask, nor a missile in flight.
    try std.testing.expect(lv.hasLineOfSight(a, b, mask & ~collision.PRESENCE_BITS));
    try std.testing.expect(lv.hasLineOfSight(a, b, collision.Colmask.missile_flight));
}

test "freeCoordinates puts a blocked drop on the nearest free cell" {
    const alloc = std.testing.allocator;
    var f = try Fixture.load(alloc, 0);
    defer f.deinit();

    const lv = f.world.level(2) orelse return error.NoLevel;
    const mask = collision.Colmask.player_path;
    const spot = anyOpenCell(lv, mask) orelse return error.NoOpenCell;

    try std.testing.expectEqual(spot, lv.freeCoordinates(spot, .point, mask, .{}).?);
    try lv.addUnit(1, spot, .monster(2, false, .{}));
    const moved = lv.freeCoordinates(spot, .point, mask, .{}) orelse return error.NoFreeCell;
    try std.testing.expect(!std.meta.eql(moved, spot));
    try std.testing.expect(lv.passable(moved.x, moved.y, mask));
}
