//! Amazon skill helpers — faithful table-driven extractions from the D2 1.14d Skills.txt.
//!
//! Every number comes from the real table via `evalCalc` / `passiveValue` / `auraValue`.
//! No formula values are hardcoded in the logic; constants only appear in `test` blocks
//! where they are cross-checked against a second independent computation (Skills.txt via awk).
//!
//! Covered:
//!   Passive %-chance skills (passivecalc1 = dm12):
//!     Critical Strike, Dodge, Avoid, Evade, Pierce
//!   Passive +hit% skill (passivecalc1 = ln12):
//!     Penetrate
//!   Missile-count calc skills (calc1):
//!     Multiple Shot (min(24,ln12)), Strafe (min(par3+lvl-1,par4)),
//!     Charged Strike (#bolts = par1+lvl/par2), Lightning Fury (#chains = ln12)
//!   Aura-debuff skill (aurastatcalc1 = -edmn):
//!     Inner Sight (armorclass penalty on cursed enemies)
//!
//! Skills whose behaviour requires host game-loop wiring (Valkyrie pet stats, Jab
//! multi-hit timing, Slow Missiles duration) are intentionally not covered here.

const std = @import("std");
const skill = @import("skill.zig");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;

// ---------------------------------------------------------------------------
// Passive %-chance skills
// ---------------------------------------------------------------------------

/// Critical Strike: % chance to deal double physical damage.
/// passivecalc1 = dm12 (diminishing from Param1=5 to Param2=80).
pub fn criticalStrikeChance(skills: *const Skills, level: i32) i32 {
    const id = skills.idByName("Critical Strike") orelse return 0;
    return skills.passiveValue(id, level).value;
}

/// Dodge: % chance to evade a melee hit while standing.
/// passivecalc1 = dm12 (diminishing from Param1=10 to Param2=65).
pub fn dodgeChance(skills: *const Skills, level: i32) i32 {
    const id = skills.idByName("Dodge") orelse return 0;
    return skills.passiveValue(id, level).value;
}

/// Avoid: % chance to evade a ranged hit while standing.
/// passivecalc1 = dm12 (diminishing from Param1=15 to Param2=75).
pub fn avoidChance(skills: *const Skills, level: i32) i32 {
    const id = skills.idByName("Avoid") orelse return 0;
    return skills.passiveValue(id, level).value;
}

/// Evade: % chance to evade a melee or ranged hit while moving.
/// passivecalc1 = dm12 (diminishing from Param1=10 to Param2=65, same curve as Dodge).
pub fn evadeChance(skills: *const Skills, level: i32) i32 {
    const id = skills.idByName("Evade") orelse return 0;
    return skills.passiveValue(id, level).value;
}

/// Pierce: % chance for arrows/javelins to pierce through enemies.
/// passivecalc1 = dm12 (diminishing from Param1=10 to Param2=100).
pub fn pierceChance(skills: *const Skills, level: i32) i32 {
    const id = skills.idByName("Pierce") orelse return 0;
    return skills.passiveValue(id, level).value;
}

/// Penetrate: +% attack rating bonus for missile attacks.
/// passivecalc1 = ln12 (linear: Param1 + level*Param2 = 35 + level*10).
pub fn penetrateBonus(skills: *const Skills, level: i32) i32 {
    const id = skills.idByName("Penetrate") orelse return 0;
    return skills.passiveValue(id, level).value;
}

// ---------------------------------------------------------------------------
// Missile-count / strike-count calc skills
// ---------------------------------------------------------------------------

/// Multiple Shot: number of arrows fired = min(24, ln12) = min(24, par1+lvl*par2)
/// with Param1=2, Param2=1 => min(24, 2+level). Table column: calc1.
pub fn multipleShotCount(skills: *const Skills, book: SkillBook, level: i32) i32 {
    const id = skills.idByName("Multiple Shot") orelse return 1;
    return @max(1, skills.evalCalc(book, 0, id, level, "calc1"));
}

/// Strafe: number of arrows = min(par3+lvl-1, par4) with par3=4, par4=10.
/// Table column: calc1.
pub fn strafeCount(skills: *const Skills, book: SkillBook, level: i32) i32 {
    const id = skills.idByName("Strafe") orelse return 1;
    return @max(1, skills.evalCalc(book, 0, id, level, "calc1"));
}

/// Charged Strike: number of lightning bolts released = par1+lvl/par2
/// with Param1=3, Param2=5. Table column: calc1.
pub fn chargedStrikeBolts(skills: *const Skills, book: SkillBook, level: i32) i32 {
    const id = skills.idByName("Charged Strike") orelse return 1;
    return @max(1, skills.evalCalc(book, 0, id, level, "calc1"));
}

/// Lightning Fury: number of chain bolts released on impact = ln12 = par1+lvl*par2
/// with Param1=2, Param2=1 => 2+level. Table column: calc1.
pub fn lightningFuryChains(skills: *const Skills, book: SkillBook, level: i32) i32 {
    const id = skills.idByName("Lightning Fury") orelse return 1;
    return @max(1, skills.evalCalc(book, 0, id, level, "calc1"));
}

// ---------------------------------------------------------------------------
// Aura-debuff skill
// ---------------------------------------------------------------------------

/// Inner Sight: the armorclass penalty applied to enemies in range.
/// aurastatcalc1 = -edmn => negated staged elemental-min damage (EMin=40, EMinLev=[25..100],
/// HitShift=8). Returns a NEGATIVE value (the AC reduction). Uses auraValue.
pub fn innerSightDefensePenalty(skills: *const Skills, level: i32) i32 {
    const id = skills.idByName("Inner Sight") orelse return 0;
    return skills.auraValue(id, level).value;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Critical Strike: passivecalc1 = dm12 (Param1=5, Param2=80)" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    // dm(1, 5, 80) = ((110*1)*(80-5)) / (100*(1+6)) + 5 = 8250/700 + 5 = 11+5 = 16
    try testing.expectEqual(@as(i32, 16), criticalStrikeChance(&sk, 1));
    // dm(5, 5, 80) = ((110*5)*(75)) / (100*11) + 5 = 41250/1100 + 5 = 37+5 = 42
    try testing.expectEqual(@as(i32, 42), criticalStrikeChance(&sk, 5));
    // dm(20, 5, 80): ((110*20)*(75))/(100*26)+5 = 165000/2600+5 = 63+5=68
    try testing.expectEqual(@as(i32, 68), criticalStrikeChance(&sk, 20));
}

test "Dodge: passivecalc1 = dm12 (Param1=10, Param2=65)" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    // dm(1,10,65) = ((110*1)*(55))/(100*7)+10 = 6050/700+10 = 8+10 = 18
    try testing.expectEqual(@as(i32, 18), dodgeChance(&sk, 1));
    try testing.expectEqual(@as(i32, 37), dodgeChance(&sk, 5));
}

test "Avoid: passivecalc1 = dm12 (Param1=15, Param2=75)" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    // dm(1,15,75) = ((110*1)*(60))/(100*7)+15 = 6600/700+15 = 9+15 = 24
    try testing.expectEqual(@as(i32, 24), avoidChance(&sk, 1));
    try testing.expectEqual(@as(i32, 45), avoidChance(&sk, 5));
}

test "Evade: passivecalc1 = dm12 (Param1=10, Param2=65) — same curve as Dodge" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    try testing.expectEqual(@as(i32, 18), evadeChance(&sk, 1));
    try testing.expectEqual(@as(i32, 47), evadeChance(&sk, 10));
}

test "Pierce: passivecalc1 = dm12 (Param1=10, Param2=100)" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    // calc.zig diminishing: divTrunc(divTrunc(110*lvl, lvl+6)*(b-a), 100)+a
    // slvl1: divTrunc(divTrunc(110,7)*90, 100)+10 = divTrunc(15*90,100)+10 = 13+10 = 23
    try testing.expectEqual(@as(i32, 23), pierceChance(&sk, 1));
    // slvl5: divTrunc(divTrunc(550,11)*90,100)+10 = divTrunc(50*90,100)+10 = 45+10 = 55
    try testing.expectEqual(@as(i32, 55), pierceChance(&sk, 5));
}

test "Penetrate: passivecalc1 = ln12 (Param1=35, Param2=10)" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    // ln12 at slvl1: 35 + 1*10 = 45
    try testing.expectEqual(@as(i32, 45), penetrateBonus(&sk, 1));
    // ln12 at slvl5: 35 + 5*10 = 85
    try testing.expectEqual(@as(i32, 85), penetrateBonus(&sk, 5));
    // ln12 at slvl10: 35 + 10*10 = 135
    try testing.expectEqual(@as(i32, 135), penetrateBonus(&sk, 10));
}

test "Multiple Shot: calc1 = min(24,ln12) with Param1=2, Param2=1" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    const book = SkillBook{};
    // slvl1: min(24, 2+1*1) = 3
    try testing.expectEqual(@as(i32, 3), multipleShotCount(&sk, book, 1));
    // slvl5: min(24, 2+5*1) = 7
    try testing.expectEqual(@as(i32, 7), multipleShotCount(&sk, book, 5));
    // slvl22: min(24, 2+22) = 24 (capped)
    try testing.expectEqual(@as(i32, 24), multipleShotCount(&sk, book, 22));
}

test "Strafe: calc1 = min(par3+lvl-1,par4) with Param3=4, Param4=10" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    const book = SkillBook{};
    // slvl1: min(4+1-1,10) = min(4,10) = 4
    try testing.expectEqual(@as(i32, 4), strafeCount(&sk, book, 1));
    // slvl7: min(4+7-1,10) = min(10,10) = 10
    try testing.expectEqual(@as(i32, 10), strafeCount(&sk, book, 7));
    // slvl10: capped at 10
    try testing.expectEqual(@as(i32, 10), strafeCount(&sk, book, 10));
}

test "Charged Strike: calc1 = par1+lvl/par2 with Param1=3, Param2=5" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    const book = SkillBook{};
    // slvl1: 3 + 1/5 = 3
    try testing.expectEqual(@as(i32, 3), chargedStrikeBolts(&sk, book, 1));
    // slvl5: 3 + 5/5 = 4
    try testing.expectEqual(@as(i32, 4), chargedStrikeBolts(&sk, book, 5));
    // slvl10: 3 + 10/5 = 5
    try testing.expectEqual(@as(i32, 5), chargedStrikeBolts(&sk, book, 10));
}

test "Lightning Fury: calc1 = ln12 with Param1=2, Param2=1" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    const book = SkillBook{};
    // slvl1: 2 + 1*1 = 3
    try testing.expectEqual(@as(i32, 3), lightningFuryChains(&sk, book, 1));
    // slvl10: 2 + 10*1 = 12
    try testing.expectEqual(@as(i32, 12), lightningFuryChains(&sk, book, 10));
}

test "Inner Sight: aurastatcalc1 = -edmn (staged EMin=40, EMinLev=[25,45,60,80,100], HitShift=8)" {
    var sk = try Skills.load(testing.allocator);
    defer sk.deinit();
    // slvl1: staged(1,40,[25,45,60,80,100],8) = (40 + 25*(1-1)) << 8 = 40*256 = 10240; >>8 = 40; negated = -40
    try testing.expectEqual(@as(i32, -40), innerSightDefensePenalty(&sk, 1));
    // slvl5: staged = (40 + 25*(5-1)) = 40+100=140; <<8>>8=140; negated = -140
    try testing.expectEqual(@as(i32, -140), innerSightDefensePenalty(&sk, 5));
}
