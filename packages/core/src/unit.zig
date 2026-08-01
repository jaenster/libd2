//! Unit model — the combat-relevant slice of D2UnitStrc.
//!
//! D2UnitStrc is the universal game-object record (players, monsters, missiles,
//! objects, items, tiles all share it, discriminated by dwUnitType). This is a
//! clean-room Zig-native subset holding exactly what the combat core reads:
//! type/id, position, owner, the stat list, and a weapon damage source.

const std = @import("std");
const stat = @import("stat.zig");
const wire = @import("wire/item.zig");

/// eD2UnitType (1.14d). The combat core distinguishes player vs monster for the
/// attack-rating path (monsters fold dexterity*5 + tohit differently).
pub const UnitType = enum(u8) {
    player = 0,
    monster = 1,
    object = 2,
    missile = 3,
    item = 4,
    tile = 5,
    _,
};

/// Base physical weapon damage source. In the engine these come from the equipped
/// weapon's Items.txt row (mindam/maxdam, StrBonus, DexBonus); a bare-handed unit
/// falls back to the mindamage(21)/maxdamage(22) stats. Values are whole (not the
/// engine's <<8 fixed-point) — the damage calc scales to <<8 internally.
pub const Weapon = struct {
    min_damage: i32 = 0,
    max_damage: i32 = 0,
    /// Items.txt StrBonus: percent damage per point of strength / 100.
    str_bonus: i32 = 0,
    /// Items.txt DexBonus: percent damage per point of dexterity / 100.
    dex_bonus: i32 = 0,
};

/// Sentinel `owner_id` meaning "no owner" — a hostile, un-summoned unit. A minion/pet carries its
/// summoner's unit_id here instead, which is how targeting/collision tell friend from foe.
pub const NO_OWNER: u32 = 0xFFFFFFFF;

/// Clean-room unit for combat resolution.
pub const Unit = struct {
    unit_type: UnitType = .monster,
    unit_id: u32 = 0,
    class_id: u32 = 0, // char class (player) or monster type id
    x: i32 = 0,
    y: i32 = 0,
    owner_id: u32 = NO_OWNER, // owner unit id (missiles/minions); none = NO_OWNER
    stats: stat.StatList = .{},
    weapon: Weapon = .{},

    pub fn init(unit_type: UnitType) Unit {
        return .{ .unit_type = unit_type };
    }

    /// A summoned minion (skeleton / golem / valkyrie / …): a monster carrying a summoner's owner_id.
    pub fn isPet(self: *const Unit) bool {
        return self.unit_type == .monster and self.owner_id != NO_OWNER;
    }

    pub fn get(self: *const Unit, s: stat.Stat) i32 {
        return self.stats.get(s);
    }

    pub fn set(self: *Unit, s: stat.Stat, v: i32) void {
        self.stats.set(s, v);
    }

    pub fn level(self: *const Unit) i32 {
        return self.stats.get(.level);
    }

    /// Current life (whole). Engine stores hitpoints(6) as fixed-point <<8; this
    /// model keeps it whole for clarity — combat subtracts whole damage.
    pub fn life(self: *const Unit) i32 {
        return self.stats.get(.hitpoints);
    }

    pub fn setLife(self: *Unit, v: i32) void {
        self.stats.set(.hitpoints, v);
    }

    pub fn isAlive(self: *const Unit) bool {
        return self.life() > 0;
    }

    /// Advance the unit one tick toward (tx,ty) by up to `step` world units, snapping onto
    /// the target when within a single step. Returns true once arrived. Pure movement
    /// kinematics — the host does any wall routing (pathfinding) and calls this to walk the
    /// unit toward the next waypoint.
    pub fn stepToward(self: *Unit, tx: i32, ty: i32, step: i32) bool {
        const dx = tx - self.x;
        const dy = ty - self.y;
        const dist2 = dx * dx + dy * dy;
        if (dist2 <= step * step) {
            self.x = tx;
            self.y = ty;
            return true;
        }
        const dist = std.math.sqrt(@as(f64, @floatFromInt(dist2)));
        const fx = @as(f64, @floatFromInt(dx)) / dist;
        const fy = @as(f64, @floatFromInt(dy)) / dist;
        self.x += @intFromFloat(@round(fx * @as(f64, @floatFromInt(step))));
        self.y += @intFromFloat(@round(fy * @as(f64, @floatFromInt(step))));
        return false;
    }
};

/// Fold a decoded save/wire item's stats onto a unit's StatList, ACCUMULATING (items stack).
/// The ItemStatCost id and the `Stat` enum share ONE id space (both are the 1.14d
/// ItemStatCost.txt row indices — see stat.zig / wire/itemstatcost.zig), so the id -> Stat map is
/// the identity `@enumFromInt(id)`; no hand table. Ids past the backed stat range (NUM_STATS) are
/// silently dropped by StatList.add. Read the summed totals back off `unit.stats` afterward
/// (e.g. defense = get(.armorclass), fire = get(.fireresist), +skills = get(.allskills) +
/// get(.addclassskills)). The host owns any downstream difficulty penalty / quest reward / clamp.
pub fn applyItemStats(unit: *Unit, item: *const wire.Item) void {
    for (item.stats[0..item.n_stats]) |s| {
        unit.stats.add(@enumFromInt(s.id), s.value);
    }
}

test "applyItemStats accumulates decoded item stats by shared id space" {
    const testing = std.testing;
    var u = Unit.init(.player);
    var it = wire.Item{};
    it.stats[0] = .{ .id = 39, .value = 30 }; // fireresist
    it.stats[1] = .{ .id = 43, .value = 20 }; // coldresist
    it.n_stats = 2;
    u.set(.fireresist, 5); // pre-existing value proves ADD (not overwrite)
    applyItemStats(&u, &it);
    try testing.expectEqual(@as(i32, 35), u.get(.fireresist));
    try testing.expectEqual(@as(i32, 20), u.get(.coldresist));
}

test "unit basics" {
    const testing = std.testing;
    var u = Unit.init(.player);
    u.set(.level, 30);
    u.setLife(500);
    try testing.expectEqual(@as(i32, 30), u.level());
    try testing.expect(u.isAlive());
    u.setLife(0);
    try testing.expect(!u.isAlive());
}

test "stepToward advances by the step then snaps onto the target" {
    const testing = std.testing;
    var u = Unit.init(.monster);
    u.x = 0;
    u.y = 0;
    // Target far to the +X axis: one 10-unit step lands exactly at x=10, not reached.
    try testing.expect(!u.stepToward(100, 0, 10));
    try testing.expectEqual(@as(i32, 10), u.x);
    try testing.expectEqual(@as(i32, 0), u.y);
    // Diagonal step advances both axes and stays short of the target (not reached).
    u.x = 0;
    u.y = 0;
    try testing.expect(!u.stepToward(100, 100, 10));
    try testing.expect(u.x > 0 and u.x < 100 and u.y > 0 and u.y < 100);
    // Within one step of the target -> snap exactly onto it and report reached.
    u.x = 95;
    u.y = 0;
    try testing.expect(u.stepToward(100, 0, 10));
    try testing.expectEqual(@as(i32, 100), u.x);
    try testing.expectEqual(@as(i32, 0), u.y);
}
