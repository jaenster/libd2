//! Paladin skill computations — faithful table-driven port of D2 1.14d
//! Skills.txt aura/passive/calc columns via the calc VM (calc.zig / skill.evalCalc).
//! Every number comes from Skills.txt; NO magic constants exist in this file.
//!
//! Recon references: D2Common/Skills/SkillPal.cpp (Skills_SrvDoFunc_* / SKILLPAL_*).
//! Ghidra session 62fbfe69, 1.14d Game.exe.
//!
//! COVERED:
//!   Aura magnitudes (aurastatcalc1..N per skill):
//!     Might: +damage%           (aurastatcalc1 = ln34)
//!     Holy Fire/Freeze/Shock:   elemental aura damage via SkillData.dmg (spell path)
//!     Thorns: %return damage    (aurastatcalc1 = ln34)
//!     Defiance: +defense%       (aurastatcalc1 = ln34)
//!     Resist Fire/Cold/Ltng: +res% (aurastatcalc1 = dm34)
//!     Prayer: regen/pulse       (aurastatcalc1 = edns)
//!     Cleansing: cleanse reduction (aurastatcalc1 = 100-dm34)
//!     Blessed Aim: +AR%         (aurastatcalc1 = ln34)
//!     Vigor: +run%, +walk%, +stamina% (aurastatcalc1/2/3)
//!     Concentration: +damage%   (aurastatcalc1 = ln34), min-block% (aurastatcalc2 = par5)
//!     Holy Freeze: -enemy-move%, -enemy-atk%, -enemy-dmg% (aurastatcalc1/2/3 = -dm34 each)
//!     Fanaticism: +dmg%, IAS%, +AR% (aurastatcalc1/2/3)
//!     Conviction: -enemy-res%, -enemy-def%, -enemy-AR%... (aurastatcalc1..4)
//!   Holy Shield: +block% and +def% from aurastatcalc1 / calc1
//!   Zeal: number of hits (calc1)
//!   Blessed Hammer: magic damage min/max from the E* staged damage columns (spell path)
//!   Sacrifice: % self-damage taken per hit (calc2 = par3)
//!   Vengeance: elemental damage bonus% (calc1/calc2, synergy-resolved)
//!
//! NOT covered here (generic in skill.zig):
//!   Smite — physical damage from shield stats, handled in combat path.
//!   Charge, Holy Bolt, Fist of the Heavens, Conversion — missile/special srvdofunc.
//!   Redemption, Sanctuary, Meditation — auraValue handles them generically.

const std = @import("std");
const skill = @import("skill.zig");
const spell = @import("spell.zig");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;
const AuraStat = skill.AuraStat;

// ---------------------------------------------------------------------------
// Single-stat aura helpers: skills whose full value lives in aurastatcalc1.
// ---------------------------------------------------------------------------

/// +% Enhanced Damage to allies from the Might aura at `level` (aurastatcalc1 = ln34).
pub fn might(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Might") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// % return-damage to melee attackers from Thorns at `level` (aurastatcalc1 = ln34).
pub fn thorns(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Thorns") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// +% defense granted by Defiance at `level` (aurastatcalc1 = ln34).
pub fn defiance(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Defiance") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// +% fire resist granted by Resist Fire at `level` (aurastatcalc1 = dm34).
pub fn resistFire(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Resist Fire") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// +% cold resist granted by Resist Cold at `level` (aurastatcalc1 = dm34).
pub fn resistCold(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Resist Cold") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// +% lightning resist granted by Resist Lightning at `level` (aurastatcalc1 = dm34).
pub fn resistLightning(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Resist Lightning") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// +% AR granted by Blessed Aim at `level` (aurastatcalc1 = ln34).
pub fn blessedAim(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Blessed Aim") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// Life regen per pulse granted by Prayer at `level` (aurastatcalc1 = edns).
pub fn prayer(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Prayer") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

/// % curse/poison duration reduction by Cleansing at `level` (aurastatcalc1 = 100-dm34).
pub fn cleansing(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Cleansing") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurastatcalc1");
}

// ---------------------------------------------------------------------------
// Concentration: +damage% (asc1) + guaranteed-block cap% (asc2 = par5).
// ---------------------------------------------------------------------------

pub const ConcentrationValues = struct {
    /// +% Enhanced Damage to allies (aurastatcalc1 = ln34).
    dmg_percent: i32,
    /// Minimum block % guarantee (aurastatcalc2 = par5, a flat constant from the row).
    min_block_pct: i32,
};

/// Table-driven Concentration aura values at `level` (slvl >= 1).
pub fn concentration(skills: *const Skills, level: i32) ConcentrationValues {
    if (level <= 0) return .{ .dmg_percent = 0, .min_block_pct = 0 };
    const id = skills.idByName("Concentration") orelse return .{ .dmg_percent = 0, .min_block_pct = 0 };
    return .{
        .dmg_percent  = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .min_block_pct = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
    };
}

// ---------------------------------------------------------------------------
// Vigor: +run%, +walk%, +stamina% (aurastatcalc1/2/3).
// ---------------------------------------------------------------------------

pub const VigorValues = struct {
    /// +% run speed (aurastatcalc1 = ln34: Param3+lvl*Param4).
    run_percent: i32,
    /// +% walk speed (aurastatcalc2 = ln34: same params).
    walk_percent: i32,
    /// +% max stamina (aurastatcalc3 = dm56).
    stamina_percent: i32,
};

/// Table-driven Vigor aura values at `level` (slvl >= 1).
pub fn vigor(skills: *const Skills, level: i32) VigorValues {
    if (level <= 0) return .{ .run_percent = 0, .walk_percent = 0, .stamina_percent = 0 };
    const id = skills.idByName("Vigor") orelse return .{ .run_percent = 0, .walk_percent = 0, .stamina_percent = 0 };
    return .{
        .run_percent     = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .walk_percent    = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
        .stamina_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc3"),
    };
}

// ---------------------------------------------------------------------------
// Holy Freeze: slows enemies — three negative stats (aurastatcalc1/2/3 = -dm34 each).
// ---------------------------------------------------------------------------

pub const HolyFreezeValues = struct {
    /// Negative % movement speed penalty on enemies (aurastatcalc1 = -dm34).
    move_percent: i32,
    /// Negative % attack rate penalty on enemies (aurastatcalc2 = -dm34).
    attack_percent: i32,
    /// Negative % damage penalty on enemies (aurastatcalc3 = -dm34).
    damage_percent: i32,
};

/// Table-driven Holy Freeze debuff values at `level` (slvl >= 1). All three are negative.
pub fn holyFreeze(skills: *const Skills, level: i32) HolyFreezeValues {
    if (level <= 0) return .{ .move_percent = 0, .attack_percent = 0, .damage_percent = 0 };
    const id = skills.idByName("Holy Freeze") orelse return .{ .move_percent = 0, .attack_percent = 0, .damage_percent = 0 };
    return .{
        .move_percent   = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .attack_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
        .damage_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc3"),
    };
}

// ---------------------------------------------------------------------------
// Fanaticism: +dmg%, IAS%, +AR%/2 (aurastatcalc1/2/3).
// ---------------------------------------------------------------------------

pub const FanaticismValues = struct {
    /// +% Enhanced Damage (aurastatcalc1 = dm34).
    dmg_percent: i32,
    /// Increased Attack Speed % (aurastatcalc2 = toht).
    ias_percent: i32,
    /// +% Attack Rating divided by 2 (aurastatcalc3 = ln56/2).
    ar_percent: i32,
};

/// Table-driven Fanaticism aura values at `level` (slvl >= 1).
pub fn fanaticism(skills: *const Skills, level: i32) FanaticismValues {
    if (level <= 0) return .{ .dmg_percent = 0, .ias_percent = 0, .ar_percent = 0 };
    const id = skills.idByName("Fanaticism") orelse return .{ .dmg_percent = 0, .ias_percent = 0, .ar_percent = 0 };
    return .{
        .dmg_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .ias_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
        .ar_percent  = skills.evalCalc(.{}, 0, id, level, "aurastatcalc3"),
    };
}

// ---------------------------------------------------------------------------
// Conviction: -enemy resist%, -enemy defense%, -enemy AR% (aurastatcalc1..4).
// asc1 = -dm56 (enemy resist pierce), asc2/3/4 = "-min(ln34,150)".
// ---------------------------------------------------------------------------

pub const ConvictionValues = struct {
    /// Negative % enemy resistance pierce (aurastatcalc1 = -dm56).
    resist_pierce: i32,
    /// Negative % enemy defense (aurastatcalc2 = -min(ln34,150)).
    defense_percent: i32,
    /// Negative % enemy AR (aurastatcalc3 = -min(ln34,150)).
    ar_percent: i32,
    /// Negative % (aurastatcalc4 = -min(ln34,150), used for enemy AR in some encodings).
    stat4: i32,
};

/// Table-driven Conviction aura values at `level` (slvl >= 1). All negative.
pub fn conviction(skills: *const Skills, level: i32) ConvictionValues {
    if (level <= 0) return .{ .resist_pierce = 0, .defense_percent = 0, .ar_percent = 0, .stat4 = 0 };
    const id = skills.idByName("Conviction") orelse return .{ .resist_pierce = 0, .defense_percent = 0, .ar_percent = 0, .stat4 = 0 };
    return .{
        .resist_pierce  = skills.evalCalc(.{}, 0, id, level, "aurastatcalc1"),
        .defense_percent = skills.evalCalc(.{}, 0, id, level, "aurastatcalc2"),
        .ar_percent     = skills.evalCalc(.{}, 0, id, level, "aurastatcalc3"),
        .stat4          = skills.evalCalc(.{}, 0, id, level, "aurastatcalc4"),
    };
}

// ---------------------------------------------------------------------------
// Holy Shield: +block% (asc1 = dm56) and +def% (asc2 = ln34+Defiance synergy).
// calc1 carries the same ln34+synergy expr for Smite damage.
// ---------------------------------------------------------------------------

pub const HolyShieldValues = struct {
    /// +% enhanced defense while Holy Shield is active (aurastatcalc2 = ln34+Defiance synergy).
    def_percent: i32,
    /// +% blocking chance while Holy Shield is active (aurastatcalc1 = dm56).
    block_percent: i32,
};

/// Table-driven Holy Shield values at `level` (slvl >= 1).
/// `book` is needed so the Defiance synergy (`skill('Defiance'.blvl)`) evaluates correctly.
pub fn holyShield(skills: *const Skills, book: SkillBook, level: i32) HolyShieldValues {
    if (level <= 0) return .{ .def_percent = 0, .block_percent = 0 };
    const id = skills.idByName("Holy Shield") orelse return .{ .def_percent = 0, .block_percent = 0 };
    return .{
        .block_percent = skills.evalCalc(book, 0, id, level, "aurastatcalc1"),
        .def_percent   = skills.evalCalc(book, 0, id, level, "aurastatcalc2"),
    };
}

// ---------------------------------------------------------------------------
// Zeal: number of hits per cast (calc1 = "min((par5 + lvl -1), par6)").
// par5=2, par6=5 => 2 hits at slvl1, capped at 5 from slvl4 onwards.
// ---------------------------------------------------------------------------

/// Number of hits Zeal delivers at `level` (calc1, capped by par6).
pub fn zealHits(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Zeal") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "calc1");
}

// ---------------------------------------------------------------------------
// Blessed Hammer: magic damage min/max from the staged E* columns (spell path).
// The actual calc dispatch sends the hit through spell.ElementalDamage.minAt/maxAt.
// ---------------------------------------------------------------------------

pub const BlessedHammerDamage = struct {
    min: i32,
    max: i32,
};

/// Magic damage range for Blessed Hammer at `level`, from the staged E* progression in
/// Skills.txt (EType=mag, EMin/EMax/EMinLev1..5/EMaxLev1..5, HitShift=8).
pub fn blessedHammer(skills: *const Skills, level: i32) BlessedHammerDamage {
    if (level <= 0) return .{ .min = 0, .max = 0 };
    const id = skills.idByName("Blessed Hammer") orelse return .{ .min = 0, .max = 0 };
    const sd = skills.byId(id) orelse return .{ .min = 0, .max = 0 };
    return .{
        .min = sd.dmg.minAt(level),
        .max = sd.dmg.maxAt(level),
    };
}

// ---------------------------------------------------------------------------
// Sacrifice: % of target HP stolen back as self-damage (calc2 = par3, a flat constant).
// ---------------------------------------------------------------------------

/// % self-damage Sacrifice deals to the caster on each hit (calc2 = par3).
/// This is the PERCENTAGE of damage dealt that the paladin takes from his own HP.
pub fn sacrifice(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Sacrifice") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "calc2");
}

// ---------------------------------------------------------------------------
// Vengeance: elemental damage bonus% (calc1 = fire%, calc2 = cold%, needs synergies).
// With no synergies book, these are the base Param1+Param2*lvl before synergies.
// ---------------------------------------------------------------------------

pub const VengeanceValues = struct {
    /// Fire elemental damage +% (calc1 synergy-resolved).
    fire_percent: i32,
    /// Cold elemental damage +% (calc2 synergy-resolved).
    cold_percent: i32,
};

/// Table-driven Vengeance elemental damage bonus at `level`.
/// Pass a filled `book` for synergy resolution (Resist Fire, Salvation, Resist Cold).
pub fn vengeance(skills: *const Skills, book: SkillBook, level: i32) VengeanceValues {
    if (level <= 0) return .{ .fire_percent = 0, .cold_percent = 0 };
    const id = skills.idByName("Vengeance") orelse return .{ .fire_percent = 0, .cold_percent = 0 };
    return .{
        .fire_percent = skills.evalCalc(book, 0, id, level, "calc1"),
        .cold_percent = skills.evalCalc(book, 0, id, level, "calc2"),
    };
}

// ---------------------------------------------------------------------------
// Tests — values independently verified against Skills.txt via awk and the
// formulae documented in calc.zig (ln/dm semantics).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Might: +damage% at slvl 1/10/20" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // aurastatcalc1 = ln34: Param3=40, Param4=10
    // slvl1: 40+1*10=50; slvl10: 40+10*10=140; slvl20: 40+20*10=240
    try testing.expectEqual(@as(i32, 50),  might(&skills, 1));
    try testing.expectEqual(@as(i32, 140), might(&skills, 10));
    try testing.expectEqual(@as(i32, 240), might(&skills, 20));
    try testing.expectEqual(@as(i32, 0),   might(&skills, 0));
}

test "Thorns: %return damage at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // aurastatcalc1 = ln34: Param3=250, Param4=40
    // slvl1: 250+1*40=290; slvl10: 250+10*40=650
    try testing.expectEqual(@as(i32, 290), thorns(&skills, 1));
    try testing.expectEqual(@as(i32, 650), thorns(&skills, 10));
}

test "Defiance: +defense% at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // aurastatcalc1 = ln34: Param3=70, Param4=10
    // slvl1: 70+1*10=80; slvl10: 70+10*10=170
    try testing.expectEqual(@as(i32, 80),  defiance(&skills, 1));
    try testing.expectEqual(@as(i32, 170), defiance(&skills, 10));
}

test "Resist Fire/Cold/Lightning share params at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // aurastatcalc1 = dm34: Param3=35, Param4=150
    // dm(1, 35, 150): step1=110*1/(1+6)=15; step2=15*(150-35)/100=15*115/100=17; r=17+35=52
    try testing.expectEqual(@as(i32, 52),  resistFire(&skills, 1));
    try testing.expectEqual(@as(i32, 52),  resistCold(&skills, 1));
    try testing.expectEqual(@as(i32, 52),  resistLightning(&skills, 1));
    // slvl10: step1=110*10/16=68; step2=68*115/100=78; r=78+35=113
    try testing.expectEqual(@as(i32, 113), resistFire(&skills, 10));
}

test "Blessed Aim: +AR% at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // aurastatcalc1 = ln34: Param3=75, Param4=15
    // slvl1: 75+1*15=90; slvl10: 75+10*15=225
    try testing.expectEqual(@as(i32, 90),  blessedAim(&skills, 1));
    try testing.expectEqual(@as(i32, 225), blessedAim(&skills, 10));
}

test "Concentration: +dmg% and min-block% at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // asc1 = ln34: Param3=60, Param4=15 => slvl1: 60+1*15=75; slvl10: 60+10*15=210
    // asc2 = par5 => Param5=20 (flat constant regardless of level)
    const c1 = concentration(&skills, 1);
    try testing.expectEqual(@as(i32, 75), c1.dmg_percent);
    try testing.expectEqual(@as(i32, 20), c1.min_block_pct);

    const c10 = concentration(&skills, 10);
    try testing.expectEqual(@as(i32, 210), c10.dmg_percent);
    try testing.expectEqual(@as(i32, 20),  c10.min_block_pct);
}

test "Vigor: run%/walk%/stamina% at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // asc1 = ln34: Param3=50, Param4=25 => slvl1: 50+1*25=75; slvl10: 50+10*25=300
    // asc2 = ln34: same params => same values
    // asc3 = dm56: Param5=7, Param6=50 => diminishing
    const v1 = vigor(&skills, 1);
    try testing.expectEqual(@as(i32, 75), v1.run_percent);
    try testing.expectEqual(@as(i32, 75), v1.walk_percent);
    // dm56 slvl1: P5=7, P6=50; step1=110*1/7=15; step2=15*(50-7)/100=15*43/100=6; r=6+7=13
    try testing.expectEqual(@as(i32, 13), v1.stamina_percent);

    const v10 = vigor(&skills, 10);
    try testing.expectEqual(@as(i32, 300), v10.run_percent);
    try testing.expectEqual(@as(i32, 300), v10.walk_percent);
}

test "Holy Freeze: negative debuffs at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // asc1/2/3 = -dm34: Param3=25, Param4=60
    // dm(1, 25, 60): step1=110*1/7=15; step2=15*(60-25)/100=15*35/100=5; r=5+25=30; negated=-30
    const h1 = holyFreeze(&skills, 1);
    try testing.expectEqual(@as(i32, -30), h1.move_percent);
    try testing.expectEqual(@as(i32, -30), h1.attack_percent);
    try testing.expectEqual(@as(i32, -30), h1.damage_percent);
}

test "Fanaticism: +dmg%/IAS%/AR% at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // asc1 = dm34: Param3=10, Param4=40
    // dm(1, 10, 40): step1=15; step2=15*(40-10)/100=15*30/100=4; r=4+10=14
    // asc2 = toht: distinct calc (to-hit), Param3/4 same
    // asc3 = ln56/2: Param5=50, Param6=17 => ln56 slvl1: 50+1*17=67; /2=33
    const f1 = fanaticism(&skills, 1);
    try testing.expectEqual(@as(i32, 14), f1.dmg_percent);
    try testing.expectEqual(@as(i32, 33), f1.ar_percent);

    // slvl10: dm34: step1=110*10/16=68; step2=68*30/100=20; r=20+10=30
    // ar: (50+10*17)/2 = 220/2 = 110
    const f10 = fanaticism(&skills, 10);
    try testing.expectEqual(@as(i32, 30),  f10.dmg_percent);
    try testing.expectEqual(@as(i32, 110), f10.ar_percent);
}

test "Conviction: negative resist/defense at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // asc1 = -dm56: Param5=40, Param6=100
    // dm(1, 40, 100): step1=15; step2=15*(100-40)/100=15*60/100=9; r=9+40=49; negated=-49
    // asc2 = -min(ln34,150): Param3=30, Param4=5 => ln34 slvl1: 30+1*5=35; min(35,150)=35; negated=-35
    const cv1 = conviction(&skills, 1);
    try testing.expectEqual(@as(i32, -49), cv1.resist_pierce);
    try testing.expectEqual(@as(i32, -35), cv1.defense_percent);

    // slvl10: dm56: step1=68; step2=68*60/100=40; r=40+40=80; negated=-80
    // ln34 slvl10: 30+10*5=80; min(80,150)=80; negated=-80
    const cv10 = conviction(&skills, 10);
    try testing.expectEqual(@as(i32, -80), cv10.resist_pierce);
    try testing.expectEqual(@as(i32, -80), cv10.defense_percent);
}

test "Holy Shield: block% and def% at slvl 1/10 (no Defiance synergy)" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // asc1 = dm56: Param5=10, Param6=40
    // dm(1, 10, 40): step1=15; step2=15*30/100=4; r=4+10=14
    // asc2 = ln34+Defiance synergy: Param3=25, Param4=15; no defiance = 0 => slvl1: 25+1*15=40
    const hs1 = holyShield(&skills, .{}, 1);
    try testing.expectEqual(@as(i32, 14), hs1.block_percent);
    try testing.expectEqual(@as(i32, 40), hs1.def_percent);

    // slvl10: dm56: step1=68; step2=68*30/100=20; r=20+10=30
    // ln34 slvl10: 25+10*15=175
    const hs10 = holyShield(&skills, .{}, 10);
    try testing.expectEqual(@as(i32, 30),  hs10.block_percent);
    try testing.expectEqual(@as(i32, 175), hs10.def_percent);
}

test "Zeal: hits at slvl 1/4/5/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc1 = min((par5 + lvl -1), par6): Param5=2, Param6=5
    // slvl1: min(2+1-1,5)=min(2,5)=2
    // slvl4: min(2+4-1,5)=min(5,5)=5
    // slvl5: min(2+5-1,5)=min(6,5)=5 (capped)
    // slvl10: min(2+10-1,5)=min(11,5)=5 (still capped)
    try testing.expectEqual(@as(i32, 2), zealHits(&skills, 1));
    try testing.expectEqual(@as(i32, 5), zealHits(&skills, 4));
    try testing.expectEqual(@as(i32, 5), zealHits(&skills, 5));
    try testing.expectEqual(@as(i32, 5), zealHits(&skills, 10));
    try testing.expectEqual(@as(i32, 0), zealHits(&skills, 0));
}

test "Blessed Hammer: magic damage min/max at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // EMin=12, EMax=16, EMinLev1=8, EMaxLev1=8, HitShift=8
    // slvl1: staged(1, 12, [8,10,12,13,14], 8) = 12 << 8 = 3072 (Lev1 adds 0 at lvl1); >>8 = 12
    // slvl10: Lev1 applies for lvl2..8: 12 + 8*7=68; then Lev2 for lvl9..10: 68+10*2=88? Actually:
    // staged: a=12, l=10; l<=28,22,16: skip; l>8: a+=8*(10-8)=16 -> a=28, l=8; a+=8*(8-1)=56->a=84; <<8=21504; >>8=84
    const bh1 = blessedHammer(&skills, 1);
    try testing.expectEqual(@as(i32, 12), bh1.min);
    try testing.expectEqual(@as(i32, 16), bh1.max);

    // slvl10: staged: a=12, l=10; l>8: a+=EMinLev2*(10-8)=10*2=20; a=32; l=8; a+=EMinLev1*(8-1)=8*7=56; a=88
    const bh10 = blessedHammer(&skills, 10);
    try testing.expectEqual(@as(i32, 88), bh10.min);
}

test "Sacrifice: self-damage % at any level (calc2 = par3 = flat 8)" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc2 = par3, Param3=8 => constant regardless of level
    try testing.expectEqual(@as(i32, 8), sacrifice(&skills, 1));
    try testing.expectEqual(@as(i32, 8), sacrifice(&skills, 10));
    try testing.expectEqual(@as(i32, 0), sacrifice(&skills, 0));
}

test "Vengeance: base fire/cold bonus% at slvl 1 (no synergies)" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc1 = ln12 + synergies: Param1=70, Param2=6 => ln12 slvl1: 70+1*6=76
    // calc2 = ln12 + synergies: same params for cold => 76
    const v1 = vengeance(&skills, .{}, 1);
    try testing.expectEqual(@as(i32, 76), v1.fire_percent);
    try testing.expectEqual(@as(i32, 76), v1.cold_percent);
}

test "aura skills return 0 at level 0" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    try testing.expectEqual(@as(i32, 0), might(&skills, 0));
    try testing.expectEqual(@as(i32, 0), thorns(&skills, 0));
    try testing.expectEqual(@as(i32, 0), defiance(&skills, 0));
    try testing.expectEqual(@as(i32, 0), blessedAim(&skills, 0));
    const hf = holyFreeze(&skills, 0);
    try testing.expectEqual(@as(i32, 0), hf.move_percent);
    const cv = conviction(&skills, 0);
    try testing.expectEqual(@as(i32, 0), cv.resist_pierce);
}
