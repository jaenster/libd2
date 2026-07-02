//! Unit model — the combat-relevant slice of D2UnitStrc.
//!
//! D2UnitStrc is the universal game-object record (players, monsters, missiles,
//! objects, items, tiles all share it, discriminated by dwUnitType). This is a
//! clean-room Zig-native subset holding exactly what the combat core reads:
//! type/id, position, owner, the stat list, and a weapon damage source.

const std = @import("std");
const stat = @import("stat.zig");

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

/// Clean-room unit for combat resolution.
pub const Unit = struct {
    unit_type: UnitType = .monster,
    unit_id: u32 = 0,
    class_id: u32 = 0, // char class (player) or monster type id
    x: i32 = 0,
    y: i32 = 0,
    owner_id: u32 = 0xFFFFFFFF, // owner unit id (missiles/minions); none = -1
    stats: stat.StatList = .{},
    weapon: Weapon = .{},

    pub fn init(unit_type: UnitType) Unit {
        return .{ .unit_type = unit_type };
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
};

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
