//! Player life / mana derivation — faithful port of the D2 1.14d CharStats.txt path.
//!
//! Sources (faithful, no invented numbers):
//!   * Base (level-1) creation — reconstructed D2Common SUnitMsg.cpp (1.14d win 0x570700-ish,
//!     INV_GetCharStatsTxtLine path):
//!         hitpoints = maxhp  = (hpadd + vit) * 0x100            // SUnitMsg.cpp:46-48
//!         mana      = maxmana = _int * 0x100                    // SUnitMsg.cpp:49-51 (int = energy)
//!         stamina   = maxstamina = stamina * 0x100              // SUnitMsg.cpp:52-54
//!     The stat store keeps life/mana in 1/256 fixed point; the whole value is `>> 8`. At
//!     creation the STARTING vitality/energy contribute 1:1 (folded into the base term above),
//!     NOT via LifePerVitality/ManaPerMagic.
//!   * Per-level — reconstructed D2Common UpdateGameInfo (1.14d win 0x570880):
//!         maxhp   += LifePerLevel  * levelDiff * 0x40           // SUnitMsg.cpp:127
//!         maxmana += ManaPerLevel  * levelDiff * 0x40           // SUnitMsg.cpp:135
//!     0x40 = 64 = 256/4, i.e. the CharStats per-X columns are in 1/4 units: each level adds
//!     LifePerLevel/4 WHOLE life. Confirmed identical in D2MOO PlayerStats.cpp:96 (`<< 6`).
//!   * Per added vitality / energy — reconstructed D2Common StatsEx.cpp (the op-stat listener):
//!         maxhp   += LifePerVitality * (vit - vit_start) * 0x40 // StatsEx.cpp:2204/2233
//!         maxmana += ManaPerMagic    * (enr - enr_start) * 0x40 // StatsEx.cpp:2155
//!     Same 0x40 fixed-point (D2MOO D2StatList.cpp:397, PlayerStats.cpp:178). "Magic" = energy.
//!
//! So the whole-value formulas (integer, truncating — the ×64 ÷256 collapses to ÷4):
//!   maxLife = (hpadd + vit_start)
//!           + LifePerLevel   * (level - 1)        / 4
//!           + LifePerVitality* (vit - vit_start)  / 4
//!   maxMana = enr_start
//!           + ManaPerLevel   * (level - 1)        / 4
//!           + ManaPerMagic   * (enr - enr_start)  / 4
//!
//! CharStats.txt values below are BYTE-VERIFIED from the shipped 1.14d charstats.bin (decoded
//! against the D2MOO D2CharStatsTxt struct layout, stride 0xC4; all 7 class rows validated).

const std = @import("std");

/// The CharStats.txt row fields this derivation reads (per class).
pub const CharStats = struct {
    str_start: i32,
    dex_start: i32,
    /// CharStats "int" column = starting ENERGY.
    energy_start: i32,
    vit_start: i32,
    stamina_start: i32,
    /// CharStats "hpadd" / nLifeAdd column — flat base life added on top of starting vitality.
    hpadd: i32,
    /// CharStats life/mana/stamina per-X columns, all in 1/4 (quarter) units.
    life_per_level: i32,
    stamina_per_level: i32,
    mana_per_level: i32,
    life_per_vitality: i32,
    stamina_per_vitality: i32,
    mana_per_magic: i32,
    /// StatPerLevel (attribute points granted per level).
    stat_per_level: i32,
    /// CharStats.txt BlockFactor (col 0x16) — flat class base block added in GetBlockRate before
    /// the (dex-15)*factor/(2*clvl) scale. All 7 1.14d classes ship BlockFactor = 20.
    block_factor: i32 = 20,
};

/// eD2PlayerClassID order (1.14d): Amazon 0, Sorceress 1, Necromancer 2, Paladin 3,
/// Barbarian 4, Druid 5, Assassin 6.
pub const Class = enum(u8) {
    amazon = 0,
    sorceress = 1,
    necromancer = 2,
    paladin = 3,
    barbarian = 4,
    druid = 5,
    assassin = 6,
};

/// All 7 CharStats rows — byte-verified from the 1.14d charstats.bin (see module header).
pub const CHAR_STATS = [_]CharStats{
    // Amazon
    .{ .str_start = 20, .dex_start = 25, .energy_start = 15, .vit_start = 20, .stamina_start = 84, .hpadd = 30, .life_per_level = 8, .stamina_per_level = 4, .mana_per_level = 6, .life_per_vitality = 12, .stamina_per_vitality = 4, .mana_per_magic = 6, .stat_per_level = 5 },
    // Sorceress
    .{ .str_start = 10, .dex_start = 25, .energy_start = 35, .vit_start = 10, .stamina_start = 74, .hpadd = 30, .life_per_level = 4, .stamina_per_level = 4, .mana_per_level = 8, .life_per_vitality = 8, .stamina_per_vitality = 4, .mana_per_magic = 8, .stat_per_level = 5 },
    // Necromancer
    .{ .str_start = 15, .dex_start = 25, .energy_start = 25, .vit_start = 15, .stamina_start = 79, .hpadd = 30, .life_per_level = 6, .stamina_per_level = 4, .mana_per_level = 8, .life_per_vitality = 8, .stamina_per_vitality = 4, .mana_per_magic = 8, .stat_per_level = 5 },
    // Paladin
    .{ .str_start = 25, .dex_start = 20, .energy_start = 15, .vit_start = 25, .stamina_start = 89, .hpadd = 30, .life_per_level = 8, .stamina_per_level = 4, .mana_per_level = 6, .life_per_vitality = 12, .stamina_per_vitality = 4, .mana_per_magic = 6, .stat_per_level = 5 },
    // Barbarian
    .{ .str_start = 30, .dex_start = 20, .energy_start = 10, .vit_start = 25, .stamina_start = 92, .hpadd = 30, .life_per_level = 8, .stamina_per_level = 4, .mana_per_level = 4, .life_per_vitality = 16, .stamina_per_vitality = 4, .mana_per_magic = 4, .stat_per_level = 5 },
    // Druid
    .{ .str_start = 15, .dex_start = 20, .energy_start = 20, .vit_start = 25, .stamina_start = 84, .hpadd = 30, .life_per_level = 6, .stamina_per_level = 4, .mana_per_level = 8, .life_per_vitality = 8, .stamina_per_vitality = 4, .mana_per_magic = 8, .stat_per_level = 5 },
    // Assassin
    .{ .str_start = 20, .dex_start = 20, .energy_start = 25, .vit_start = 20, .stamina_start = 95, .hpadd = 30, .life_per_level = 8, .stamina_per_level = 5, .mana_per_level = 6, .life_per_vitality = 12, .stamina_per_vitality = 5, .mana_per_magic = 7, .stat_per_level = 5 },
};

pub fn charStats(class: Class) CharStats {
    return CHAR_STATS[@intFromEnum(class)];
}

pub const Derived = struct {
    max_life: i32,
    max_mana: i32,
    max_stamina: i32,
};

/// Derive max life / mana / stamina for a character (see module header for the formula + cites).
/// `vitality`/`energy`/`stamina*`-start are the base attribute totals (as shown on the sheet,
/// including any spent points); the derivation adds the per-point bonus only for points ABOVE
/// the class start (the start is already in the base term). Item +maxlife/+maxmana are the
/// caller's concern (folded on the Unit's stat list separately).
pub fn derive(class: Class, level: i32, vitality: i32, energy: i32) Derived {
    const cs = charStats(class);
    const level_ups = @max(0, level - 1);

    const life = (cs.hpadd + cs.vit_start) +
        @divTrunc(cs.life_per_level * level_ups, 4) +
        @divTrunc(cs.life_per_vitality * @max(0, vitality - cs.vit_start), 4);

    const mana = cs.energy_start +
        @divTrunc(cs.mana_per_level * level_ups, 4) +
        @divTrunc(cs.mana_per_magic * @max(0, energy - cs.energy_start), 4);

    const stamina = cs.stamina_start +
        @divTrunc(cs.stamina_per_level * level_ups, 4) +
        @divTrunc(cs.stamina_per_vitality * @max(0, vitality - cs.vit_start), 4);

    return .{ .max_life = life, .max_mana = mana, .max_stamina = stamina };
}

const testing = std.testing;

test "Sorceress base stats at level 1 match the fresh-char sheet" {
    const cs = charStats(.sorceress);
    try testing.expectEqual(@as(i32, 10), cs.str_start);
    try testing.expectEqual(@as(i32, 25), cs.dex_start);
    try testing.expectEqual(@as(i32, 35), cs.energy_start);
    try testing.expectEqual(@as(i32, 10), cs.vit_start);
    // Fresh level-1 Sorc: life = hpadd(30)+vit(10) = 40; mana = int(35) = 35; stamina 74.
    const d = derive(.sorceress, 1, cs.vit_start, cs.energy_start);
    try testing.expectEqual(@as(i32, 40), d.max_life);
    try testing.expectEqual(@as(i32, 35), d.max_mana);
    try testing.expectEqual(@as(i32, 74), d.max_stamina);
}

test "Sorceress per-level scaling (no spent attributes) at clvl 20" {
    // 19 level-ups. life += LifePerLevel(4)*19/4 = 19; 40+19 = 59.
    // mana += ManaPerLevel(8)*19/4 = 38; 35+38 = 73.
    const cs = charStats(.sorceress);
    const d = derive(.sorceress, 20, cs.vit_start, cs.energy_start);
    try testing.expectEqual(@as(i32, 59), d.max_life);
    try testing.expectEqual(@as(i32, 73), d.max_mana);
}

test "Sorceress with spent vitality + energy above the start" {
    // clvl 20, vit 60 (50 spent), energy 85 (50 spent).
    // life = 40 + 4*19/4 + LifePerVit(8)*50/4 = 40 + 19 + 100 = 159.
    // mana = 35 + 8*19/4 + ManaPerMagic(8)*50/4 = 35 + 38 + 100 = 173.
    const d = derive(.sorceress, 20, 60, 85);
    try testing.expectEqual(@as(i32, 159), d.max_life);
    try testing.expectEqual(@as(i32, 173), d.max_mana);
}

test "Barbarian has the highest life-per-vitality (16/4 = 4 per point)" {
    const cs = charStats(.barbarian);
    try testing.expectEqual(@as(i32, 16), cs.life_per_vitality);
    // clvl 1, +10 vit: life = (30+25) + 0 + 16*10/4 = 55 + 40 = 95.
    const d = derive(.barbarian, 1, cs.vit_start + 10, cs.energy_start);
    try testing.expectEqual(@as(i32, 95), d.max_life);
}
