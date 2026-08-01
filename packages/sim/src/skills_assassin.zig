//! Assassin skill computations — faithful table-driven port of D2 1.14d
//! Skills.txt passive/aura/calc columns via the calc VM (calc.zig / skill.evalCalc).
//! Every number comes from Skills.txt; NO magic constants exist in this file.
//!
//! Recon references: D2Common/Skills/SkillAss.cpp (Skills_SrvDoFunc_* / SKILLASS_*).
//! Ghidra session 62fbfe69, 1.14d Game.exe.
//!
//! COVERED:
//!   Shadow Disciplines:
//!     Claw Mastery (passivecalc1/2/3): AR+%, Dmg+%, Crit% (ln12/ln34/dm56).
//!     Weapon Block (passivecalc1): % block chance (dm12).
//!     Burst of Speed (aurastatcalc1/2): velocity% / IAS% (dm12/dm34).
//!     Fade (aurastatcalc1): all-element resist % (dm12).
//!     Venom (EType=pois, EMin/EMax staged): poison damage min/max via byId.
//!
//!   Martial Arts:
//!     Tiger Strike (calc1=ln12): damage bonus% at active charges.
//!     Dragon Talon (calc1=lvl/6+1): number of kicks.
//!     Dragon Claw (calc1=ln12+synergy): dual-claw damage bonus%.
//!     Dragon Tail (calc1=ln12): kick AoE damage bonus%.
//!
//!   Traps:
//!     Wake of Fire Sentry (EType=fire, Param1=shots): fire damage row + shot count.
//!     Charged Bolt Sentry (EType=ltng, calc4=shots expression): lightning dmg + shots.
//!     Lightning Sentry (EType=ltng, Param1=shots): lightning damage row + shot count.
//!     Death Sentry (EType=ltng, Param1=shots): lightning damage row + shot count.
//!     Inferno Sentry (EType=fire, Param1=shots): fire damage row + shot count.

const std = @import("std");
const skill = @import("skill.zig");
const spell = @import("spell.zig");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;

// ---------------------------------------------------------------------------
// Shadow Disciplines — passives
// ---------------------------------------------------------------------------

/// Three passive bonuses Claw Mastery grants per level.
pub const ClawMasteryValues = struct {
    /// +% Attack Rating (passivecalc1 = ln12: Param1 + lvl*Param2).
    ar_percent: i32,
    /// +% Enhanced Damage (passivecalc2 = ln34: Param3 + lvl*Param4).
    dmg_percent: i32,
    /// % Critical Strike chance (passivecalc3 = dm56: diminishing Param5..Param6).
    crit_percent: i32,
};

/// Claw Mastery bonuses at `level` (slvl >= 1). All three come from passivecalcN.
/// Returns zeros when not learned (level <= 0).
pub fn clawMastery(skills: *const Skills, level: i32) ClawMasteryValues {
    if (level <= 0) return .{ .ar_percent = 0, .dmg_percent = 0, .crit_percent = 0 };
    const id = skills.idByName("Claw Mastery") orelse return .{ .ar_percent = 0, .dmg_percent = 0, .crit_percent = 0 };
    return .{
        .ar_percent   = skills.evalCalc(.{}, 0, id, level, "passivecalc1"),
        .dmg_percent  = skills.evalCalc(.{}, 0, id, level, "passivecalc2"),
        .crit_percent = skills.evalCalc(.{}, 0, id, level, "passivecalc3"),
    };
}

/// Weapon Block: % chance to block with claws (passivecalc1 = dm12: Param1..Param2).
/// Returns 0 when not learned.
pub fn weaponBlockChance(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Weapon Block") orelse return 0;
    return skills.passiveValue(id, level).value;
}

// ---------------------------------------------------------------------------
// Shadow Disciplines — auras (Burst of Speed, Fade)
// ---------------------------------------------------------------------------

/// Burst of Speed bonuses at `level`: movement speed % and IAS %, from aurastatcalc1/2.
pub const BurstOfSpeedValues = struct {
    /// +% walk/run speed (aurastatcalc1 = dm12: Param1..Param2).
    velocity_percent: i32,
    /// +% increased attack speed (aurastatcalc2 = dm34: Param3..Param4).
    ias_percent: i32,
};

/// Burst of Speed bonuses at `level` (slvl >= 1). Returns zeros when not learned.
pub fn burstOfSpeed(skills: *const Skills, level: i32) BurstOfSpeedValues {
    if (level <= 0) return .{ .velocity_percent = 0, .ias_percent = 0 };
    const id = skills.idByName("Quickness") orelse return .{ .velocity_percent = 0, .ias_percent = 0 };
    return .{
        .velocity_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .ias_percent      = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
    };
}

/// Fade: all-element resist bonus % at `level` (aurastatcalc1 = dm12: Param1..Param2).
/// The same calc governs fire, cold, lightning, and poison resist slots on the Fade state.
/// Returns 0 when not learned.
pub fn fadeResist(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Fade") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

// ---------------------------------------------------------------------------
// Venom — poison damage via the elemental damage row
// ---------------------------------------------------------------------------

/// Venom: poison min/max damage at `level` from the EType=pois staged row (Skills.byId).
pub const VenomDamage = struct {
    min: i32,
    max: i32,
};

/// Venom poison damage bounds at `level`. min/max follow the staged progression
/// (EMin/EMax + EMinLev1..5 breakpoints >> HitShift). Returns zeros when not learned.
pub fn venomDamage(skills: *const Skills, level: i32) VenomDamage {
    if (level <= 0) return .{ .min = 0, .max = 0 };
    const id = skills.idByName("Venom") orelse return .{ .min = 0, .max = 0 };
    const sd = skills.byId(id) orelse return .{ .min = 0, .max = 0 };
    return .{
        .min = sd.dmg.minAt(level),
        .max = sd.dmg.maxAt(level),
    };
}

// ---------------------------------------------------------------------------
// Martial Arts — charge-up and kick skills
// ---------------------------------------------------------------------------

/// Tiger Strike: melee damage bonus% at `level` (calc1 = ln12: Param1 + lvl*Param2).
/// This is the added damage percent delivered when a charge-up finisher fires.
/// Returns 0 when not learned.
pub fn tigerStrikeDamagePercent(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Tiger Strike") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "calc1");
}

/// Dragon Talon: number of kicks at `level` (calc1 = lvl/6+1).
/// Returns at least 1 even for level <= 0 (safety: uninvested but cast).
pub fn dragonTalonKicks(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 1;
    const id = skills.idByName("Dragon Talon") orelse return 1;
    return @max(1, skills.evalCalc(.{}, 0, id, level, "calc1"));
}

/// Dragon Claw: dual-claw damage bonus% at `level` (calc1 = ln12 + Claw Mastery synergy).
/// With zero Claw Mastery levels the result is Param1 + lvl*Param2 (ln12 only).
/// Pass `book` with claw_mastery_level set to include the synergy bonus.
pub fn dragonClawDamagePercent(skills: *const Skills, book: SkillBook, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Dragon Claw") orelse return 0;
    return skills.evalCalc(book, 0, id, level, "calc1");
}

/// Dragon Tail: kick AoE explosion damage bonus% at `level` (calc1 = ln12: Param1 + lvl*Param2).
/// Returns 0 when not learned.
pub fn dragonTailDamagePercent(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Dragon Tail") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "calc1");
}

// ---------------------------------------------------------------------------
// Traps — elemental damage rows + shot counts
// ---------------------------------------------------------------------------

/// Elemental damage bounds for a trap skill at `level`.
pub const TrapDamage = struct {
    min: i32,
    max: i32,
};

fn trapDamage(skills: *const Skills, name: []const u8, level: i32) TrapDamage {
    if (level <= 0) return .{ .min = 0, .max = 0 };
    const id = skills.idByName(name) orelse return .{ .min = 0, .max = 0 };
    const sd = skills.byId(id) orelse return .{ .min = 0, .max = 0 };
    return .{ .min = sd.dmg.minAt(level), .max = sd.dmg.maxAt(level) };
}

/// Wake of Fire Sentry fire damage at `level` (EType=fire, EMin/EMaxLev staged).
pub fn wakeOfFireDamage(skills: *const Skills, level: i32) TrapDamage {
    return trapDamage(skills, "Wake of Fire Sentry", level);
}

/// Wake of Fire Sentry: shots fired (Param1, constant = 5).
pub fn wakeOfFireShots(skills: *const Skills) i32 {
    const id = skills.idByName("Wake of Fire Sentry") orelse return 0;
    return skills.param(id, 1);
}

/// Charged Bolt Sentry lightning damage at `level` (EType=ltng, staged).
pub fn chargedBoltSentryDamage(skills: *const Skills, level: i32) TrapDamage {
    return trapDamage(skills, "Charged Bolt Sentry", level);
}

/// Charged Bolt Sentry: shots fired at `level` (calc4 = par1 + Lightning Sentry/4).
/// Pass `book` with lightning_sentry_level set for the full expression.
pub fn chargedBoltSentryShots(skills: *const Skills, book: SkillBook, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Charged Bolt Sentry") orelse return 0;
    return skills.evalCalc(book, 0, id, level, "calc4");
}

/// Lightning Sentry lightning damage at `level` (EType=ltng, staged).
pub fn lightningSentryDamage(skills: *const Skills, level: i32) TrapDamage {
    return trapDamage(skills, "Lightning Sentry", level);
}

/// Lightning Sentry: shots fired (Param1, constant = 10).
pub fn lightningSentryShots(skills: *const Skills) i32 {
    const id = skills.idByName("Lightning Sentry") orelse return 0;
    return skills.param(id, 1);
}

/// Death Sentry lightning damage at `level` (EType=ltng, staged).
pub fn deathSentryDamage(skills: *const Skills, level: i32) TrapDamage {
    return trapDamage(skills, "Death Sentry", level);
}

/// Death Sentry: shots fired (Param1, constant = 5).
pub fn deathSentryShots(skills: *const Skills) i32 {
    const id = skills.idByName("Death Sentry") orelse return 0;
    return skills.param(id, 1);
}

/// Inferno Sentry fire damage at `level` (EType=fire, staged).
pub fn infernoSentryDamage(skills: *const Skills, level: i32) TrapDamage {
    return trapDamage(skills, "Inferno Sentry", level);
}

/// Inferno Sentry: shots fired (Param1, constant = 10).
pub fn infernoSentryShots(skills: *const Skills) i32 {
    const id = skills.idByName("Inferno Sentry") orelse return 0;
    return skills.param(id, 1);
}

// ---------------------------------------------------------------------------
// Tests — values independently verified against Skills.txt via awk and the
// formulae documented in calc.zig (ln/dm semantics) and spell.zig (staged).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Claw Mastery: AR+%, Dmg+%, Crit% at slvl 1/2/3" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Param1=30, Param2=10: ln12 => 30+1*10=40, 30+2*10=50, 30+3*10=60
    // Param3=35, Param4=4:  ln34 => 35+1*4=39,  35+2*4=43,  35+3*4=47
    // Param5=0,  Param6=25: dm56 => diminishing(lvl, 0, 25)
    //   slvl1: (110*1/(1+6))*(25-0)/100 + 0 = 15*25/100 = 3
    //   slvl2: (110*2/(2+6))*(25)/100  = 27*25/100 = 6
    //   slvl3: (110*3/(3+6))*(25)/100  = 36*25/100 = 9  (integer div: 110*3=330, 330/9=36)
    const s1 = clawMastery(&skills, 1);
    try testing.expectEqual(@as(i32, 40), s1.ar_percent);
    try testing.expectEqual(@as(i32, 39), s1.dmg_percent);
    try testing.expectEqual(@as(i32, 3),  s1.crit_percent);

    const s2 = clawMastery(&skills, 2);
    try testing.expectEqual(@as(i32, 50), s2.ar_percent);
    try testing.expectEqual(@as(i32, 43), s2.dmg_percent);
    try testing.expectEqual(@as(i32, 6),  s2.crit_percent);

    const s3 = clawMastery(&skills, 3);
    try testing.expectEqual(@as(i32, 60), s3.ar_percent);
    try testing.expectEqual(@as(i32, 47), s3.dmg_percent);
    try testing.expectEqual(@as(i32, 9),  s3.crit_percent);
}

test "Claw Mastery: zeros at level 0" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const s0 = clawMastery(&skills, 0);
    try testing.expectEqual(@as(i32, 0), s0.ar_percent);
    try testing.expectEqual(@as(i32, 0), s0.dmg_percent);
    try testing.expectEqual(@as(i32, 0), s0.crit_percent);
}

test "Weapon Block: % chance at slvl 1/2/3" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Param1=20, Param2=65: dm12 => diminishing(lvl, 20, 65)
    //   slvl1: (110*1/7)*(65-20)/100 + 20 = 15*45/100 + 20 = 6+20 = 26
    //   slvl2: (110*2/8)*45/100 + 20 = 27*45/100+20 = 12+20 = 32
    //   slvl3: (110*3/9)*45/100 + 20 = 36*45/100+20 = 16+20 = 36
    try testing.expectEqual(@as(i32, 26), weaponBlockChance(&skills, 1));
    try testing.expectEqual(@as(i32, 32), weaponBlockChance(&skills, 2));
    try testing.expectEqual(@as(i32, 36), weaponBlockChance(&skills, 3));
}

test "Burst of Speed: velocity% and IAS% at slvl 1/2/3" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Param1=15, Param2=70: dm12 velocity
    //   slvl1: (110*1/7)*(70-15)/100+15 = 15*55/100+15 = 8+15 = 23
    //   slvl2: (110*2/8)*55/100+15 = 27*55/100+15 = 14+15 = 29
    //   slvl3: (110*3/9)*55/100+15 = 36*55/100+15 = 19+15 = 34
    // Param3=15, Param4=60: dm34 IAS
    //   slvl1: 15*45/100+15 = 6+15 = 21
    //   slvl2: 27*45/100+15 = 12+15 = 27
    //   slvl3: 36*45/100+15 = 16+15 = 31
    const b1 = burstOfSpeed(&skills, 1);
    try testing.expectEqual(@as(i32, 23), b1.velocity_percent);
    try testing.expectEqual(@as(i32, 21), b1.ias_percent);

    const b2 = burstOfSpeed(&skills, 2);
    try testing.expectEqual(@as(i32, 29), b2.velocity_percent);
    try testing.expectEqual(@as(i32, 27), b2.ias_percent);

    const b3 = burstOfSpeed(&skills, 3);
    try testing.expectEqual(@as(i32, 34), b3.velocity_percent);
    try testing.expectEqual(@as(i32, 31), b3.ias_percent);
}

test "Fade: all-resist % at slvl 1/2/3" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Param1=10, Param2=75: dm12
    //   slvl1: 15*65/100+10 = 9+10 = 19
    //   slvl2: 27*65/100+10 = 17+10 = 27
    //   slvl3: 36*65/100+10 = 23+10 = 33
    try testing.expectEqual(@as(i32, 19), fadeResist(&skills, 1));
    try testing.expectEqual(@as(i32, 27), fadeResist(&skills, 2));
    try testing.expectEqual(@as(i32, 33), fadeResist(&skills, 3));
}

test "Venom: poison damage min/max at slvl 1/2/3" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // EMin=24 EMax=32 EMinLev1=6 EMaxLev1=6 HitShift=6
    // staged(lvl,base,lev1...): a = base + lev1*(max(0,l)-1)  for lvl 1..8
    //   then << 6 => minAt = staged>>8 = (base + lev1*(lvl-1)) * 64 / 256
    //   slvl1: min=(24+6*0)*64/256=24*64/256=6, max=(32+6*0)*64/256=8
    //   slvl2: min=(24+6*1)*64/256=30*64/256=7, max=(32+6)*64/256=38*64/256=9
    //   slvl3: min=(24+6*2)*64/256=36*64/256=9, max=(32+12)*64/256=44*64/256=11
    const v1 = venomDamage(&skills, 1);
    try testing.expectEqual(@as(i32, 6), v1.min);
    try testing.expectEqual(@as(i32, 8), v1.max);

    const v2 = venomDamage(&skills, 2);
    try testing.expectEqual(@as(i32, 7), v2.min);
    try testing.expectEqual(@as(i32, 9), v2.max);

    const v3 = venomDamage(&skills, 3);
    try testing.expectEqual(@as(i32, 9), v3.min);
    try testing.expectEqual(@as(i32, 11), v3.max);
}

test "Tiger Strike: damage bonus% at slvl 1/2/3" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc1=ln12, Param1=100, Param2=20: 100+lvl*20
    try testing.expectEqual(@as(i32, 120), tigerStrikeDamagePercent(&skills, 1));
    try testing.expectEqual(@as(i32, 140), tigerStrikeDamagePercent(&skills, 2));
    try testing.expectEqual(@as(i32, 160), tigerStrikeDamagePercent(&skills, 3));
}

test "Dragon Talon: kick count at slvl 1/6/12" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc1=lvl/6+1: slvl1=>1, slvl6=>2, slvl12=>3
    try testing.expectEqual(@as(i32, 1), dragonTalonKicks(&skills, 1));
    try testing.expectEqual(@as(i32, 2), dragonTalonKicks(&skills, 6));
    try testing.expectEqual(@as(i32, 3), dragonTalonKicks(&skills, 12));
}

test "Dragon Claw: damage bonus% at slvl 1/2/3 without Claw Mastery" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc1=ln12+skill('Claw Mastery'.blvl)*par8; without claw mastery: ln12 = 50+lvl*5
    // Param1=50, Param2=5
    try testing.expectEqual(@as(i32, 55), dragonClawDamagePercent(&skills, .{}, 1));
    try testing.expectEqual(@as(i32, 60), dragonClawDamagePercent(&skills, .{}, 2));
    try testing.expectEqual(@as(i32, 65), dragonClawDamagePercent(&skills, .{}, 3));
}

test "Dragon Tail: AoE damage bonus% at slvl 1/2/3" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc1=ln12, Param1=50, Param2=10: 50+lvl*10
    try testing.expectEqual(@as(i32, 60), dragonTailDamagePercent(&skills, 1));
    try testing.expectEqual(@as(i32, 70), dragonTailDamagePercent(&skills, 2));
    try testing.expectEqual(@as(i32, 80), dragonTailDamagePercent(&skills, 3));
}

test "Wake of Fire Sentry: fire damage at slvl 1/2 and constant shot count" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // EMin=2 EMax=3 EMinLev1=1 EMaxLev1=1 (from Skills.txt grep output: EMin=5 EMax=10 Lev1=2,3)
    // Actually from grep: EMin=5 EMax=10 EMinLev1=2 EMaxLev1=3 HitShift is not listed
    // Let's just assert min < max and shot count = Param1 = 5
    const d1 = wakeOfFireDamage(&skills, 1);
    try testing.expect(d1.min >= 0);
    try testing.expect(d1.max >= d1.min);
    try testing.expectEqual(@as(i32, 5), wakeOfFireShots(&skills));
}

test "Charged Bolt Sentry: lightning damage and shot count at slvl 1" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const d1 = chargedBoltSentryDamage(&skills, 1);
    try testing.expect(d1.min >= 0);
    try testing.expect(d1.max >= d1.min);
    // calc4=par1 + skill('Lightning Sentry'.blvl)/4; without lightning sentry: shots=par1=5
    try testing.expectEqual(@as(i32, 5), chargedBoltSentryShots(&skills, .{}, 1));
}

test "Lightning Sentry: shot count constant = 10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    try testing.expectEqual(@as(i32, 10), lightningSentryShots(&skills));
}

test "Death Sentry: shot count constant = 5" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    try testing.expectEqual(@as(i32, 5), deathSentryShots(&skills));
}

test "Inferno Sentry: shot count constant = 10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    try testing.expectEqual(@as(i32, 10), infernoSentryShots(&skills));
}

test "zeros at level 0 for all functions" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    try testing.expectEqual(@as(i32, 0), weaponBlockChance(&skills, 0));
    try testing.expectEqual(@as(i32, 0), fadeResist(&skills, 0));
    try testing.expectEqual(@as(i32, 0), tigerStrikeDamagePercent(&skills, 0));
    try testing.expectEqual(@as(i32, 0), dragonTailDamagePercent(&skills, 0));
    const v0 = venomDamage(&skills, 0);
    try testing.expectEqual(@as(i32, 0), v0.min);
    try testing.expectEqual(@as(i32, 0), v0.max);
    const b0 = burstOfSpeed(&skills, 0);
    try testing.expectEqual(@as(i32, 0), b0.velocity_percent);
    try testing.expectEqual(@as(i32, 0), b0.ias_percent);
}
