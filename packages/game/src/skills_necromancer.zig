//! Necromancer skill computations — faithful table-driven port of D2 1.14d
//! Skills.txt curse/summon/bone/poison columns via the calc VM.
//! Every number comes from Skills.txt; NO magic constants exist in this file.
//!
//! Recon ref: D2Common/Skills/SkillNec.cpp — Skills_SrvDoFunc_030_CastCurseAoE reads
//! auralencalc (duration), aurarangecalc (radius), aurastatcalc1..N (debuff magnitudes).
//! Ghidra session 62fbfe69, 1.14d Game.exe.

const std = @import("std");
const skill = @import("skill.zig");
const spell = @import("spell.zig");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;
const AuraStat = skill.AuraStat;
const SummonInfo = skill.SummonInfo;

// ---------------------------------------------------------------------------
// Curse result: debuff magnitude + AoE duration/radius, all table-driven.
// ---------------------------------------------------------------------------

pub const CurseValues = struct {
    /// The ItemStatCost stat name the curse debuffs (e.g. "damageresist", "velocitypercent").
    /// Empty string for state-only curses (Terror, Dim Vision, Confuse, Attract) or skills
    /// whose debuff comes from calc1 rather than aurastat1 (Iron Maiden, Life Tap).
    stat: []const u8 = "",
    /// The debuff magnitude at this level (negative = resistance penalty, etc.).
    value: i32 = 0,
    /// Duration in server frames (auralencalc = ln34: Param3 + lvl*Param4).
    duration: i32 = 0,
    /// Cast radius in subtiles (aurarangecalc = ln12: Param1 + lvl*Param2).
    radius: i32 = 0,
};

fn curseValuesFor(skills: *const Skills, name: []const u8, level: i32) CurseValues {
    if (level <= 0) return .{};
    const id = skills.idByName(name) orelse return .{};
    const aura = skills.auraValue(id, level);
    return .{
        .stat = aura.stat,
        .value = aura.value,
        .duration = skills.evalCalc(.{}, 0, id, level, "auralencalc"),
        .radius = skills.evalCalc(.{}, 0, id, level, "aurarangecalc"),
    };
}

/// Amplify Damage: damageresist debuff + duration/radius.
pub fn amplifyDamage(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Amplify Damage", level);
}

/// Weaken: damagepercent debuff + duration/radius.
pub fn weaken(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Weaken", level);
}

/// Decrepify: velocitypercent debuff + duration/radius.
pub fn decrepify(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Decrepify", level);
}

/// Lower Resist: resist debuff value + duration/radius. The stat is "fireresist"
/// (the engine applies the same value to all resists via the curse state).
pub fn lowerResist(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Lower Resist", level);
}

/// Iron Maiden: the % returned damage at this level (calc1 = ln56: par5 + lvl*par6).
/// Duration/radius come from auralencalc/aurarangecalc as for all curses.
/// aurastat1 is empty for Iron Maiden; the debuff comes from calc1.
pub fn ironMaiden(skills: *const Skills, level: i32) CurseValues {
    if (level <= 0) return .{};
    const id = skills.idByName("Iron Maiden") orelse return .{};
    return .{
        .stat = "",
        .value = skills.evalCalc(.{}, 0, id, level, "calc1"),
        .duration = skills.evalCalc(.{}, 0, id, level, "auralencalc"),
        .radius = skills.evalCalc(.{}, 0, id, level, "aurarangecalc"),
    };
}

/// Life Tap: leech percent at this level (calc1 = ln56: par5 + lvl*par6).
/// Duration/radius from ln34/ln12. aurastat1 is empty; the leech % comes from calc1.
pub fn lifeTap(skills: *const Skills, level: i32) CurseValues {
    if (level <= 0) return .{};
    const id = skills.idByName("Life Tap") orelse return .{};
    return .{
        .stat = "",
        .value = skills.evalCalc(.{}, 0, id, level, "calc1"),
        .duration = skills.evalCalc(.{}, 0, id, level, "auralencalc"),
        .radius = skills.evalCalc(.{}, 0, id, level, "aurarangecalc"),
    };
}

/// State-only curses (Dim Vision, Confuse, Attract, Terror): no stat debuff value,
/// duration and radius only. The engine applies the state effect via the AI behaviour
/// change (SKILLNEC_AssignCurseAiBehavior).
pub fn dimVision(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Dim Vision", level);
}
pub fn attract(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Attract", level);
}
pub fn confuse(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Confuse", level);
}
pub fn terror(skills: *const Skills, level: i32) CurseValues {
    return curseValuesFor(skills, "Terror", level);
}

// ---------------------------------------------------------------------------
// Summons — petmax count + monster class name, all via Skills.summonInfo.
// ---------------------------------------------------------------------------

pub fn raiseSkeleton(skills: *const Skills, level: i32) SummonInfo {
    const id = skills.idByName("Raise Skeleton") orelse return .{};
    return skills.summonInfo(id, level);
}

pub fn raiseSkeletalMage(skills: *const Skills, level: i32) SummonInfo {
    const id = skills.idByName("Raise Skeletal Mage") orelse return .{};
    return skills.summonInfo(id, level);
}

pub fn clayGolem(skills: *const Skills, level: i32) SummonInfo {
    const id = skills.idByName("Clay Golem") orelse return .{};
    return skills.summonInfo(id, level);
}

pub fn bloodGolem(skills: *const Skills, level: i32) SummonInfo {
    const id = skills.idByName("BloodGolem") orelse return .{};
    return skills.summonInfo(id, level);
}

pub fn ironGolem(skills: *const Skills, level: i32) SummonInfo {
    const id = skills.idByName("IronGolem") orelse return .{};
    return skills.summonInfo(id, level);
}

pub fn fireGolem(skills: *const Skills, level: i32) SummonInfo {
    const id = skills.idByName("FireGolem") orelse return .{};
    return skills.summonInfo(id, level);
}

/// Revive: max concurrent revives at `level` (petmax = lvl in the table).
/// Revive.summon is empty so summonInfo returns zero; read petmax directly.
pub fn reviveMax(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Revive") orelse return 0;
    const row = skills.rowById(id) orelse return 0;
    const expr = skills.table.get(row, "petmax");
    return skills.evalExpr(expr, id, level);
}

// ---------------------------------------------------------------------------
// Bone skills — absorb HP (Bone Armor) and wall/prison HP (Bone Wall / Prison).
// ---------------------------------------------------------------------------

/// Bone Armor absorb amount at `level` in actual hit points (the table stores
/// the value *256 in the bonearmor stat; we divide by 256 here so callers get
/// the game's displayed value). `book` supplies Bone Wall / Bone Prison synergy levels.
pub fn boneArmorAbsorb(skills: *const Skills, book: SkillBook, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Bone Armor") orelse return 0;
    const raw = skills.evalCalc(book, 0, id, level, "aurastatcalc1");
    return @divTrunc(raw, 256);
}

/// Bone Wall HP at `level`. `book` supplies Bone Armor / Bone Prison synergy levels.
pub fn boneWallHp(skills: *const Skills, book: SkillBook, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Bone Wall") orelse return 0;
    return skills.evalCalc(book, 0, id, level, "calc1");
}

/// Bone Prison HP at `level`. `book` supplies Bone Armor / Bone Wall synergy levels.
pub fn bonePrisonHp(skills: *const Skills, book: SkillBook, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Bone Prison") orelse return 0;
    return skills.evalCalc(book, 0, id, level, "calc1");
}

// ---------------------------------------------------------------------------
// Poison skills — damage range + length, table-driven from E* columns.
// ---------------------------------------------------------------------------

pub const PoisonSkillValues = struct {
    /// Minimum poison damage (ElementalDamage.minAt at this level).
    min: i32 = 0,
    /// Maximum poison damage (ElementalDamage.maxAt at this level).
    max: i32 = 0,
    /// Poison duration in server frames (ELen column).
    length_frames: i32 = 0,
};

fn poisonValues(skills: *const Skills, name: []const u8, level: i32) PoisonSkillValues {
    if (level <= 0) return .{};
    const id = skills.idByName(name) orelse return .{};
    const sd = skills.byId(id) orelse return .{};
    return .{
        .min = sd.dmg.minAt(level),
        .max = sd.dmg.maxAt(level),
        .length_frames = sd.e_len,
    };
}

pub fn poisonDagger(skills: *const Skills, level: i32) PoisonSkillValues {
    return poisonValues(skills, "Poison Dagger", level);
}

pub fn poisonExplosion(skills: *const Skills, level: i32) PoisonSkillValues {
    return poisonValues(skills, "Poison Explosion", level);
}

/// Poison Explosion cast radius (aurarangecalc = ln34: Param3 + lvl*Param4).
pub fn poisonExplosionRadius(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Poison Explosion") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurarangecalc");
}

pub fn poisonNova(skills: *const Skills, level: i32) PoisonSkillValues {
    return poisonValues(skills, "Poison Nova", level);
}

// ---------------------------------------------------------------------------
// Corpse Explosion — cast radius (the damage path is in skill.corpseExplosion).
// ---------------------------------------------------------------------------

/// Corpse Explosion AoE radius at `level` (aurarangecalc = ln34: par3 + lvl*par4).
pub fn corpseExplosionRadius(skills: *const Skills, level: i32) i32 {
    if (level <= 0) return 0;
    const id = skills.idByName("Corpse Explosion") orelse return 0;
    return skills.evalCalc(.{}, 0, id, level, "aurarangecalc");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Amplify Damage: stat, debuff value, duration, radius at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const ad1 = amplifyDamage(&skills, 1);
    try testing.expectEqualStrings("damageresist", ad1.stat);
    try testing.expectEqual(@as(i32, -100), ad1.value);
    // auralencalc = ln34: 200 + 1*75 = 275
    try testing.expectEqual(@as(i32, 275), ad1.duration);
    // aurarangecalc = ln12: 3 + 1*1 = 4
    try testing.expectEqual(@as(i32, 4), ad1.radius);

    const ad10 = amplifyDamage(&skills, 10);
    try testing.expectEqual(@as(i32, -100), ad10.value); // -par5 is flat
    // ln34: 200 + 10*75 = 950
    try testing.expectEqual(@as(i32, 950), ad10.duration);
    // ln12: 3 + 10*1 = 13
    try testing.expectEqual(@as(i32, 13), ad10.radius);
}

test "Weaken: damagepercent debuff at slvl 1/10" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const w1 = weaken(&skills, 1);
    try testing.expectEqualStrings("damagepercent", w1.stat);
    try testing.expectEqual(@as(i32, -33), w1.value);
    // ln12: 9 + 1*1 = 10
    try testing.expectEqual(@as(i32, 10), w1.radius);

    // slvl10: radius = 9 + 10*1 = 19
    const w10 = weaken(&skills, 10);
    try testing.expectEqual(@as(i32, 19), w10.radius);
}

test "Decrepify: velocitypercent debuff at slvl 1" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const d1 = decrepify(&skills, 1);
    try testing.expectEqualStrings("velocitypercent", d1.stat);
    // par5 = -50
    try testing.expectEqual(@as(i32, -50), d1.value);
    // duration ln34: 100 + 1*15 = 115
    try testing.expectEqual(@as(i32, 115), d1.duration);
    // radius ln12: 6 + 1*0 = 6
    try testing.expectEqual(@as(i32, 6), d1.radius);
}

test "Lower Resist: fireresist debuff (dm56) at slvl 1" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const lr1 = lowerResist(&skills, 1);
    try testing.expectEqualStrings("fireresist", lr1.stat);
    // -dm56 at slvl1: -diminishing(1, 25, 70) = -(divTrunc(divTrunc(110,7)*45,100)+25) = -(6+25) = -31
    try testing.expectEqual(@as(i32, -31), lr1.value);
}

test "Iron Maiden: % returned damage (calc1 = ln56) at slvl 1/5" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const im1 = ironMaiden(&skills, 1);
    // calc1 = ln56: par5 + lvl*par6 = 200 + 1*25 = 225
    try testing.expectEqual(@as(i32, 225), im1.value);

    const im5 = ironMaiden(&skills, 5);
    // 200 + 5*25 = 325
    try testing.expectEqual(@as(i32, 325), im5.value);
}

test "Life Tap: leech percent (calc1 = ln56) at slvl 1/5" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const lt1 = lifeTap(&skills, 1);
    // calc1 = ln56: par5 + lvl*par6 = 50 + 1*0 = 50
    try testing.expectEqual(@as(i32, 50), lt1.value);

    const lt5 = lifeTap(&skills, 5);
    // 50 + 5*0 = 50 (par6=0, flat)
    try testing.expectEqual(@as(i32, 50), lt5.value);
}

test "State curses: Dim Vision / Terror / Confuse / Attract have no debuff value" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const dv = dimVision(&skills, 1);
    try testing.expectEqual(@as(i32, 0), dv.value);
    // duration > 0 (has auralencalc)
    try testing.expect(dv.duration > 0);

    const te = terror(&skills, 1);
    try testing.expectEqual(@as(i32, 0), te.value);
    try testing.expect(te.duration > 0);
}

test "Raise Skeleton: petmax count at slvl 1/5/12" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // (lvl < 4) ? lvl : (2 + lvl/3)
    const s1 = raiseSkeleton(&skills, 1);
    try testing.expectEqualStrings("necroskeleton", s1.monster);
    try testing.expectEqual(@as(i32, 1), s1.count);

    const s5 = raiseSkeleton(&skills, 5);
    // 2 + 5/3 = 2 + 1 = 3
    try testing.expectEqual(@as(i32, 3), s5.count);

    const s12 = raiseSkeleton(&skills, 12);
    // 2 + 12/3 = 2 + 4 = 6
    try testing.expectEqual(@as(i32, 6), s12.count);
}

test "Raise Skeletal Mage: same petmax formula as Raise Skeleton" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const s1 = raiseSkeletalMage(&skills, 1);
    try testing.expectEqualStrings("necromage", s1.monster);
    try testing.expectEqual(@as(i32, 1), s1.count);

    const s5 = raiseSkeletalMage(&skills, 5);
    try testing.expectEqual(@as(i32, 3), s5.count);
}

test "Golems: petmax always 1, correct monster names" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const cg = clayGolem(&skills, 5);
    try testing.expectEqualStrings("ClayGolem", cg.monster);
    try testing.expectEqual(@as(i32, 1), cg.count);

    const bg = bloodGolem(&skills, 5);
    try testing.expectEqualStrings("BloodGolem", bg.monster);
    try testing.expectEqual(@as(i32, 1), bg.count);

    const ig = ironGolem(&skills, 5);
    try testing.expectEqualStrings("IronGolem", ig.monster);
    try testing.expectEqual(@as(i32, 1), ig.count);

    const fg = fireGolem(&skills, 5);
    try testing.expectEqualStrings("FireGolem", fg.monster);
    try testing.expectEqual(@as(i32, 1), fg.count);
}

test "Revive: max count = skill level" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    try testing.expectEqual(@as(i32, 1), reviveMax(&skills, 1));
    try testing.expectEqual(@as(i32, 5), reviveMax(&skills, 5));
    try testing.expectEqual(@as(i32, 18), reviveMax(&skills, 18));
}

test "Bone Armor: absorb HP at slvl 1/5 (no synergies)" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // aurastatcalc1 = (ln12 + 0*par8)*256; absorb = raw/256 = ln12 = par1 + lvl*par2
    // par1=20, par2=10: slvl1 = 20+1*10 = 30
    try testing.expectEqual(@as(i32, 30), boneArmorAbsorb(&skills, .{}, 1));
    // slvl5: 20+5*10 = 70
    try testing.expectEqual(@as(i32, 70), boneArmorAbsorb(&skills, .{}, 5));
}

test "Bone Wall: HP at slvl 1/5 (no synergies)" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // calc1 = (par1*(lvl-1)) + synergy*par8; par1=25, no synergies
    // slvl1: 25*(1-1) = 0
    try testing.expectEqual(@as(i32, 0), boneWallHp(&skills, .{}, 1));
    // slvl5: 25*(5-1) = 100
    try testing.expectEqual(@as(i32, 100), boneWallHp(&skills, .{}, 5));
}

test "Corpse Explosion: radius at slvl 1/5" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // aurarangecalc = ln34: par3 + lvl*par4 = 8 + 1*1 = 9
    try testing.expectEqual(@as(i32, 9), corpseExplosionRadius(&skills, 1));
    // slvl5: 8 + 5*1 = 13
    try testing.expectEqual(@as(i32, 13), corpseExplosionRadius(&skills, 5));
}

test "Poison Dagger: damage min/max scale with level, length_frames=50" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const pd1 = poisonDagger(&skills, 1);
    try testing.expectEqual(@as(i32, 50), pd1.length_frames);
    // HitShift=1: staged(1, 18, [10..]) << 1 >> 8 = 0 at slvl1 (damage is fixed-point, rounds down)
    try testing.expectEqual(@as(i32, 0), pd1.min);
    try testing.expect(pd1.max >= pd1.min);

    const pd20 = poisonDagger(&skills, 20);
    // slvl20: staged=(18+10*7+15*4)=158, 158<<1=316, 316>>8=1 min; scales up
    try testing.expect(pd20.min >= pd1.min);
    try testing.expectEqual(@as(i32, 50), pd20.length_frames);
}

test "Poison Nova: damage min/max scale with level, length_frames=50" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const pn1 = poisonNova(&skills, 1);
    try testing.expectEqual(@as(i32, 50), pn1.length_frames);
    // HitShift=4: staged(1, 16, [4..]) = 16<<4=256, 256>>8=1
    try testing.expectEqual(@as(i32, 1), pn1.min);

    const pn10 = poisonNova(&skills, 10);
    try testing.expect(pn10.min > pn1.min);
}

test "zero-level returns safe defaults" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    const z = amplifyDamage(&skills, 0);
    try testing.expectEqual(@as(i32, 0), z.value);
    try testing.expectEqual(@as(i32, 0), z.duration);

    try testing.expectEqual(@as(i32, 0), boneArmorAbsorb(&skills, .{}, 0));
    try testing.expectEqual(@as(i32, 0), reviveMax(&skills, 0));
}
