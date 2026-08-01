//! Barbarian skill computations — faithful table-driven port of D2 1.14d
//! Skills.txt passive/aura columns via the calc VM (calc.zig / skill.evalCalc).
//! Every number comes from Skills.txt; NO magic constants exist in this file.
//!
//! Recon references: D2Common/Skills/SkillBar.cpp (Skills_SrvDoFunc_* / SKILLBAR_*).
//! Ghidra session 62fbfe69, 1.14d Game.exe.
//!
//! COVERED:
//!   Weapon masteries (Sword/Axe/Mace/Polearm/Spear/Throwing): passivecalc1..3
//!     -> AR+%, Dmg+%, Crit% via ln12/ln34/dm56 respectively.
//!   Battle Cry (aurastatcalc1/2): -defense% / -damage% on enemies.
//!   Taunt (aurastatcalc1/2): -AR% / -damage% on enemies.
//!   Battle Orders (aurastatcalc1): +max-hp/mana/stamina% on allies (ln34).
//!
//! NOT covered here (already generic in skill.zig / not mastery/warcry):
//!   Increased Speed, Iron Skin, Natural Resistance, Shout — passiveValue /
//!   auraValue handle them generically. War Cry elemental damage is in the spell path.

const std = @import("std");
const skill = @import("skill.zig");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;

// ---------------------------------------------------------------------------
// Mastery result: the three passive bonuses a weapon mastery grants at `level`.
// ---------------------------------------------------------------------------

pub const MasteryValues = struct {
    /// +% to Attack Rating (passivecalc1 = ln12: Param1 + lvl*Param2).
    ar_percent: i32,
    /// +% Enhanced Damage (passivecalc2 = ln34: Param3 + lvl*Param4).
    dmg_percent: i32,
    /// % Deadly Strike / Critical Hit chance (passivecalc3 = dm56: diminishing Param5..Param6).
    crit_percent: i32,
};

/// Evaluate a weapon mastery at `level` (slvl >= 1). Returns all three bonus
/// columns — AR+%, Dmg+%, Crit% — purely from Skills.txt passivecalcN.
/// `level <= 0` returns all zeros (skill not learned).
fn masteryValues(skills: *const Skills, name: []const u8, level: i32) MasteryValues {
    if (level <= 0) return .{ .ar_percent = 0, .dmg_percent = 0, .crit_percent = 0 };
    const id = skills.idByName(name) orelse return .{ .ar_percent = 0, .dmg_percent = 0, .crit_percent = 0 };
    return .{
        .ar_percent  = skills.evalCalc(.{}, 0, id, level, "passivecalc1"),
        .dmg_percent = skills.evalCalc(.{}, 0, id, level, "passivecalc2"),
        .crit_percent = skills.evalCalc(.{}, 0, id, level, "passivecalc3"),
    };
}

pub fn swordMastery(skills: *const Skills, level: i32) MasteryValues {
    return masteryValues(skills, "Sword Mastery", level);
}
pub fn axeMastery(skills: *const Skills, level: i32) MasteryValues {
    return masteryValues(skills, "Axe Mastery", level);
}
pub fn maceMastery(skills: *const Skills, level: i32) MasteryValues {
    return masteryValues(skills, "Mace Mastery", level);
}
pub fn polearmMastery(skills: *const Skills, level: i32) MasteryValues {
    return masteryValues(skills, "Polearm Mastery", level);
}
pub fn spearMastery(skills: *const Skills, level: i32) MasteryValues {
    return masteryValues(skills, "Spear Mastery", level);
}
pub fn throwingMastery(skills: *const Skills, level: i32) MasteryValues {
    return masteryValues(skills, "Throwing Mastery", level);
}

// ---------------------------------------------------------------------------
// Battle Cry: debuffs enemies' defense and damage.
// ---------------------------------------------------------------------------

pub const BattleCryValues = struct {
    /// Negative % applied to enemy defense (aurastatcalc1 = ln34: Param3 + lvl*Param4).
    defense_percent: i32,
    /// Negative % applied to enemy damage (aurastatcalc2 = ln56: Param5 + lvl*Param6).
    damage_percent: i32,
};

/// Table-driven Battle Cry debuff values at `level` (slvl >= 1).
/// Both values are negative (they reduce defense/damage on the target).
pub fn battleCry(skills: *const Skills, level: i32) BattleCryValues {
    if (level <= 0) return .{ .defense_percent = 0, .damage_percent = 0 };
    const id = skills.idByName("Battle Cry") orelse return .{ .defense_percent = 0, .damage_percent = 0 };
    return .{
        .defense_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .damage_percent  = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
    };
}

// ---------------------------------------------------------------------------
// Taunt: reduces target's AR and damage, read from aurastatcalc1/2.
// ---------------------------------------------------------------------------

pub const TauntValues = struct {
    /// Negative % applied to enemy AR (aurastatcalc1 = ln12: Param1 + lvl*Param2).
    ar_percent: i32,
    /// Negative % applied to enemy damage (aurastatcalc2 = ln34: Param3 + lvl*Param4).
    damage_percent: i32,
};

/// Table-driven Taunt debuff values at `level` (slvl >= 1).
pub fn taunt(skills: *const Skills, level: i32) TauntValues {
    if (level <= 0) return .{ .ar_percent = 0, .damage_percent = 0 };
    const id = skills.idByName("Taunt") orelse return .{ .ar_percent = 0, .damage_percent = 0 };
    return .{
        .ar_percent     = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .damage_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
    };
}

// ---------------------------------------------------------------------------
// Battle Orders: +% max-hp, max-mana, stamina to allies.
// All three stats share aurastatcalc1 = ln34 (Param3 + lvl*Param4).
// ---------------------------------------------------------------------------

/// +% max-hp / max-mana / stamina granted by Battle Orders at `level`.
/// All three stats share the same calc column (aurastatcalc1).
pub fn battleOrders(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Battle Orders") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

// ---------------------------------------------------------------------------
// Tests — values independently verified against Skills.txt via awk and the
// formulae documented in calc.zig (ln/dm semantics).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Sword Mastery: AR+%, Dmg+%, Crit% at slvl 1/10/20" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const s1 = swordMastery(&skills, 1);
    try testing.expectEqual(@as(i32, 36), s1.ar_percent);  // ln12: 28+1*8=36
    try testing.expectEqual(@as(i32, 33), s1.dmg_percent); // ln34: 28+1*5=33
    try testing.expectEqual(@as(i32, 5),  s1.crit_percent); // dm56: diminishing(1,0,35)

    const s10 = swordMastery(&skills, 10);
    try testing.expectEqual(@as(i32, 108), s10.ar_percent);  // 28+10*8=108
    try testing.expectEqual(@as(i32, 78),  s10.dmg_percent); // 28+10*5=78
    try testing.expectEqual(@as(i32, 23),  s10.crit_percent); // dm56: integer-div steps give 23, not 24

    const s20 = swordMastery(&skills, 20);
    try testing.expectEqual(@as(i32, 188), s20.ar_percent);  // 28+20*8=188
    try testing.expectEqual(@as(i32, 128), s20.dmg_percent); // 28+20*5=128
    try testing.expectEqual(@as(i32, 29),  s20.crit_percent);
}

test "Throwing Mastery: AR+% base differs from melee masteries" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Throwing Mastery has Param1=30 (vs 28 for melee); Param2=8 same.
    const s1 = throwingMastery(&skills, 1);
    try testing.expectEqual(@as(i32, 38), s1.ar_percent);  // ln12: 30+1*8=38
    try testing.expectEqual(@as(i32, 33), s1.dmg_percent); // ln34: 28+1*5=33 (same params)
    try testing.expectEqual(@as(i32, 5),  s1.crit_percent);
}

test "Axe/Mace Mastery share Sword Mastery params; Spear has higher AR base like Throwing" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const lvl = 5;
    const sw  = swordMastery(&skills, lvl);   // Param1=28
    const ax  = axeMastery(&skills, lvl);     // Param1=28
    const ma  = maceMastery(&skills, lvl);    // Param1=28
    const sp  = spearMastery(&skills, lvl);   // Param1=30 (same as Throwing)
    const th  = throwingMastery(&skills, lvl); // Param1=30

    // Sword/Axe/Mace share AR base 28; all share same Dmg/Crit params.
    try testing.expectEqual(sw.ar_percent, ax.ar_percent);
    try testing.expectEqual(sw.ar_percent, ma.ar_percent);
    try testing.expectEqual(sw.dmg_percent, ax.dmg_percent);
    try testing.expectEqual(sw.crit_percent, ma.crit_percent);

    // Spear and Throwing share Param1=30, so their AR+% matches each other.
    try testing.expectEqual(sp.ar_percent, th.ar_percent);
    // Spear AR+% is higher than Sword AR+% (30 vs 28 base).
    try testing.expect(sp.ar_percent > sw.ar_percent);
}

test "Battle Cry: defense% and damage% debuff at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Param3=-50, Param4=-2 => ln34: -50+1*(-2)=-52 at slvl1
    // Param5=-25, Param6=-1 => ln56: -25+1*(-1)=-26 at slvl1
    const bc1 = battleCry(&skills, 1);
    try testing.expectEqual(@as(i32, -52), bc1.defense_percent);
    try testing.expectEqual(@as(i32, -26), bc1.damage_percent);

    // slvl10: ln34: -50+10*(-2)=-70; ln56: -25+10*(-1)=-35
    const bc10 = battleCry(&skills, 10);
    try testing.expectEqual(@as(i32, -70), bc10.defense_percent);
    try testing.expectEqual(@as(i32, -35), bc10.damage_percent);
}

test "Taunt: AR% and damage% debuff at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Param1=-5, Param2=-2 => ln12: -5+1*(-2)=-7 at slvl1
    // Param3=-5, Param4=-2 => ln34: -5+1*(-2)=-7 at slvl1
    const t1 = taunt(&skills, 1);
    try testing.expectEqual(@as(i32, -7), t1.ar_percent);
    try testing.expectEqual(@as(i32, -7), t1.damage_percent);

    // slvl10: ln12: -5+10*(-2)=-25; ln34: same
    const t10 = taunt(&skills, 10);
    try testing.expectEqual(@as(i32, -25), t10.ar_percent);
    try testing.expectEqual(@as(i32, -25), t10.damage_percent);
}

test "Battle Orders: +% max-hp/mana/stamina at slvl 1/10/20" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Param3=35, Param4=3 => ln34: 35+1*3=38 at slvl1
    try testing.expectEqual(@as(i32, 38), battleOrders(&skills, 1));
    // slvl10: 35+10*3=65
    try testing.expectEqual(@as(i32, 65), battleOrders(&skills, 10));
    // slvl20: 35+20*3=95
    try testing.expectEqual(@as(i32, 95), battleOrders(&skills, 20));
}

test "masteries return zeros at level 0 (not learned)" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const m = swordMastery(&skills, 0);
    try testing.expectEqual(@as(i32, 0), m.ar_percent);
    try testing.expectEqual(@as(i32, 0), m.dmg_percent);
    try testing.expectEqual(@as(i32, 0), m.crit_percent);

    try testing.expectEqual(@as(i32, 0), battleOrders(&skills, 0));
    const bc = battleCry(&skills, 0);
    try testing.expectEqual(@as(i32, 0), bc.defense_percent);
    const ta = taunt(&skills, 0);
    try testing.expectEqual(@as(i32, 0), ta.ar_percent);
}
