//! Unit stat model — the combat-relevant slice of D2's stat system.
//!
//! D2 stores per-unit stats in a D2StatListStrc chain hung off D2UnitStrc; each
//! stat is a (stat-id, layer, value) triple and the engine sums layers on lookup
//! (STATLIST_GetUnitStat / STATLIST_UnitGetStatValue). This is a clean-room
//! Zig-native store: a flat array keyed by the ItemStatCost stat id, which is all
//! the combat core needs (it reads *summed* stat values, never individual layers).
//!
//! The stat ids below are the 1.14d ItemStatCost.txt row indices — the exact ids
//! the engine's STAT_* getters use. Only the combat-relevant ids are named; the
//! store itself is a full array so any id can be set for tests.

const std = @import("std");

/// ItemStatCost stat ids (1.14d ItemStatCost.txt row order). Values are the
/// engine's — combat getters index the stat list by these exact numbers.
pub const Stat = enum(u16) {
    strength = 0,
    energy = 1,
    dexterity = 2,
    vitality = 3,
    statpts = 4,
    newskills = 5,
    hitpoints = 6, // current life (fixed-point: value << 8 internally; we keep whole)
    maxhp = 7,
    mana = 8,
    maxmana = 9,
    stamina = 10,
    maxstamina = 11,
    level = 12,
    experience = 13,
    gold = 14,
    goldbank = 15,
    item_armor_percent = 16,
    item_maxdamage_percent = 17,
    item_mindamage_percent = 18,
    tohit = 19, // attack rating (flat +AR from items/skills)
    toblock = 20,
    mindamage = 21, // flat +min physical damage
    maxdamage = 22, // flat +max physical damage
    secondary_mindamage = 23,
    secondary_maxdamage = 24,
    damagepercent = 25, // enhanced damage % (off-weapon, e.g. skills/other gear)
    manarecovery = 26,
    manarecoverybonus = 27,
    staminarecoverybonus = 28,
    lastexp = 29,
    nextexp = 30,
    armorclass = 31, // defense
    armorclass_vs_missile = 32,
    armorclass_vs_hth = 33,
    normal_damage_reduction = 34, // "damage reduced by N" (flat physical)
    magic_damage_reduction = 35, // "magic damage reduced by N" (flat)
    damageresist = 36, // "damage reduced by N%" (physical resist %)
    magicresist = 37,
    maxmagicresist = 38,
    fireresist = 39,
    maxfireresist = 40,
    lightresist = 41,
    maxlightresist = 42,
    coldresist = 43,
    maxcoldresist = 44,
    poisonresist = 45,
    maxpoisonresist = 46,
    hpregen = 74, // ItemStatCost hpregen — per-frame life-regen delta (engine keeps it <<8)
    item_normaldamage = 111, // flat physical damage add (both min and max)
    item_tohit_percent = 119, // +% attack rating
    _,
};

/// Number of stat slots we back. ItemStatCost 1.14d has far more ids (skills,
/// charges, per-level bonuses, …) but the combat core only touches the low block;
/// 512 covers the whole base-stat range with headroom and is cheap.
pub const NUM_STATS = 512;

/// Clean-room flat stat store. Holds the *summed* value per stat id (as the engine
/// returns from STATLIST_GetUnitStat). Signed 32-bit to match the engine's stat
/// value width and to allow negative reductions/resists.
pub const StatList = struct {
    values: [NUM_STATS]i32 = [_]i32{0} ** NUM_STATS,

    pub fn init() StatList {
        return .{};
    }

    /// Read a stat by id (STATLIST_GetUnitStat). Unknown/out-of-range ids read 0.
    pub fn get(self: *const StatList, s: Stat) i32 {
        const i: usize = @intFromEnum(s);
        if (i >= NUM_STATS) return 0;
        return self.values[i];
    }

    /// Set a stat's summed value (test/setup helper; the real engine mutates layers).
    pub fn set(self: *StatList, s: Stat, v: i32) void {
        const i: usize = @intFromEnum(s);
        if (i >= NUM_STATS) return;
        self.values[i] = v;
    }

    /// Add to a stat's value.
    pub fn add(self: *StatList, s: Stat, v: i32) void {
        const i: usize = @intFromEnum(s);
        if (i >= NUM_STATS) return;
        self.values[i] +%= v;
    }
};

test "stat store round-trips by id" {
    const testing = std.testing;
    var sl = StatList.init();
    sl.set(.strength, 156);
    sl.set(.dexterity, 88);
    sl.set(.tohit, 1200);
    sl.add(.tohit, 300);
    try testing.expectEqual(@as(i32, 156), sl.get(.strength));
    try testing.expectEqual(@as(i32, 88), sl.get(.dexterity));
    try testing.expectEqual(@as(i32, 1500), sl.get(.tohit));
    try testing.expectEqual(@as(i32, 0), sl.get(.maxhp)); // unset reads 0
}
