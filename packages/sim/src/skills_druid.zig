//! Druid class skill computations — faithful table-driven port of the D2 1.14d server
//! shapeshifting (Skills_SrvDoFunc_116_Werewolf / _Werebear), spirit aura and summon paths.
//!
//! Every number comes from Skills.txt via the calc VM — zero hardcoded formula values.
//! Recon references: D2Common/Skills/SkillDruid.cpp (D2SetAurastatsFromSkills),
//! D2Common/Skills/SkillsDru.cpp (shapeshifting state apply).

const std = @import("std");
const skill = @import("skill.zig");

const Skills = skill.Skills;
const SkillBook = skill.SkillBook;
const AuraStat = skill.AuraStat;
const SummonInfo = skill.SummonInfo;

/// One aura-slot stat granted by a shapeshifting form or spirit aura, table-driven from
/// aurastatN / aurastatcalcN. `slot` is 1-based (1..6 matching the D2SetAurastatsFromSkills loop).
/// `book` threads through so skill('Shape Shifting'.ln34) synergy refs evaluate correctly.
pub fn shapeshiftAuraStat(skills: *const Skills, book: SkillBook, form_name: []const u8, level: i32, slot: u8) AuraStat {
    const id = skills.idByName(form_name) orelse return .{};
    var col_buf: [16]u8 = undefined;
    var calc_buf: [24]u8 = undefined;
    const stat_col = std.fmt.bufPrint(&col_buf, "aurastat{d}", .{slot}) catch return .{};
    const calc_col = std.fmt.bufPrint(&calc_buf, "aurastatcalc{d}", .{slot}) catch return .{};
    const row = skills.rowById(id) orelse return .{};
    const stat = skills.table.get(row, stat_col);
    if (stat.len == 0) return .{};
    return .{ .stat = stat, .value = skills.evalCalc(book, 0, id, level, calc_col) };
}

/// Shapeshift form duration in server frames (Skills.txt auralencalc).
/// Formula: 1000 + skill('Shape Shifting'.ln12) = 1000 + (1000 + shape_shifting_lvl*500).
pub fn shapeshiftDuration(skills: *const Skills, book: SkillBook, form_name: []const u8, level: i32) i32 {
    const id = skills.idByName(form_name) orelse return 0;
    return skills.evalCalc(book, 0, id, level, "auralencalc");
}

/// The stat a spirit totem's AURA grants at `aura_level`. The totem casts a separate "...Aura"
/// skill (Oak Sage Aura / Wolverine Aura / Barbs Aura); this reads aurastat1 / aurastatcalc1
/// via the same auraValue path used for paladin auras.
pub fn spiritAuraStat(skills: *const Skills, aura_skill_name: []const u8, aura_level: i32) AuraStat {
    const id = skills.idByName(aura_skill_name) orelse return .{};
    return skills.auraValue(id, aura_level);
}

/// Second aura-slot stat for spirit totems with two aura stats (Wolverine Aura has
/// item_tohit_percent in slot 1 and damagepercent in slot 2).
pub fn spiritAuraStat2(skills: *const Skills, aura_skill_name: []const u8, aura_level: i32) AuraStat {
    const id = skills.idByName(aura_skill_name) orelse return .{};
    const row = skills.rowById(id) orelse return .{};
    const stat = skills.table.get(row, "aurastat2");
    if (stat.len == 0) return .{};
    return .{ .stat = stat, .value = skills.evalCalc(.{}, 0, id, aura_level, "aurastatcalc2") };
}

/// What a Druid summon skill spawns + the max concurrent count at `level`, table-driven
/// from Skills.txt summon / petmax columns via the calc VM. Delegates to Skills.summonInfo.
pub fn druidSummonInfo(skills: *const Skills, summon_name: []const u8, level: i32) SummonInfo {
    const id = skills.idByName(summon_name) orelse return .{};
    return skills.summonInfo(id, level);
}

const testing = std.testing;

test "Wearwolf: table-driven aura stats at various skill levels" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Slot 1: staminapercent = par1 = 25 (flat, any level)
    const s1 = shapeshiftAuraStat(&skills, .{}, "Wearwolf", 1, 1);
    try testing.expectEqualStrings("skill_staminapercent", s1.stat);
    try testing.expectEqual(@as(i32, 25), s1.value);

    const s1_5 = shapeshiftAuraStat(&skills, .{}, "Wearwolf", 5, 1);
    try testing.expectEqual(@as(i32, 25), s1_5.value);

    // Slot 2: attackrate = dm34 (P3=10, P4=80), diminishing returns
    // slvl1: divTrunc(divTrunc(110,7)*70,100)+10 = divTrunc(15*70,100)+10 = 10+10 = 20
    // slvl5: divTrunc(divTrunc(550,11)*70,100)+10 = divTrunc(50*70,100)+10 = 35+10 = 45
    const s2_1 = shapeshiftAuraStat(&skills, .{}, "Wearwolf", 1, 2);
    try testing.expectEqualStrings("attackrate", s2_1.stat);
    try testing.expectEqual(@as(i32, 20), s2_1.value);
    const s2_5 = shapeshiftAuraStat(&skills, .{}, "Wearwolf", 5, 2);
    try testing.expectEqual(@as(i32, 45), s2_5.value);

    // Slot 4: item_maxhp_percent = par2 + skill('Shape Shifting'.ln34)
    // 0 shape shifting: 25 + (20+0) = 45
    const s4_1_nosynergy = shapeshiftAuraStat(&skills, .{}, "Wearwolf", 1, 4);
    try testing.expectEqualStrings("item_maxhp_percent", s4_1_nosynergy.stat);
    try testing.expectEqual(@as(i32, 45), s4_1_nosynergy.value);

    // With 5 pts Shape Shifting: 25 + (20+5*5) = 25+45 = 70
    const ss_id = skills.idByName("Shape Shifting").?;
    var book = SkillBook{};
    book.set(ss_id, 5);
    const s4_1_synergy = shapeshiftAuraStat(&skills, book, "Wearwolf", 1, 4);
    try testing.expectEqual(@as(i32, 70), s4_1_synergy.value);
}

test "Wearbear: table-driven aura stats" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Slot 1: damagepercent = ln12 (P1=55, P2=8) => slvl1=63, slvl5=95
    const s1 = shapeshiftAuraStat(&skills, .{}, "Wearbear", 1, 1);
    try testing.expectEqualStrings("damagepercent", s1.stat);
    try testing.expectEqual(@as(i32, 63), s1.value);
    const s1_5 = shapeshiftAuraStat(&skills, .{}, "Wearbear", 5, 1);
    try testing.expectEqual(@as(i32, 95), s1_5.value);

    // Slot 2: skill_armor_percent = ln34 (P3=25, P4=6) => slvl1=31
    const s2 = shapeshiftAuraStat(&skills, .{}, "Wearbear", 1, 2);
    try testing.expectEqualStrings("skill_armor_percent", s2.stat);
    try testing.expectEqual(@as(i32, 31), s2.value);

    // Slot 3: item_maxhp_percent = par5+skill('Shape Shifting'.ln34)
    // 0 shape shifting: 75 + 20 = 95
    const s3 = shapeshiftAuraStat(&skills, .{}, "Wearbear", 1, 3);
    try testing.expectEqualStrings("item_maxhp_percent", s3.stat);
    try testing.expectEqual(@as(i32, 95), s3.value);
}

test "shapeshift duration: table-driven from auralencalc" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // auralencalc = 1000 + skill('Shape Shifting'.ln12) where ln12 = 1000 + lvl*500
    // 0 shape_shifting: 1000 + (1000 + 0) = 2000
    const dur0 = shapeshiftDuration(&skills, .{}, "Wearwolf", 1);
    try testing.expectEqual(@as(i32, 2000), dur0);

    // 2 pts Shape Shifting: 1000 + (1000 + 2*500) = 3000
    const ss_id = skills.idByName("Shape Shifting").?;
    var book = SkillBook{};
    book.set(ss_id, 2);
    const dur2 = shapeshiftDuration(&skills, book, "Wearwolf", 1);
    try testing.expectEqual(@as(i32, 3000), dur2);
}

test "Oak Sage Aura: table-driven life% aura" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Oak Sage Aura: as1=item_maxhp_percent, ln34 (P3=30, P4=5) => slvl1=35, slvl5=55, slvl10=80
    const s1 = spiritAuraStat(&skills, "Oak Sage Aura", 1);
    try testing.expectEqualStrings("item_maxhp_percent", s1.stat);
    try testing.expectEqual(@as(i32, 35), s1.value);

    const s5 = spiritAuraStat(&skills, "Oak Sage Aura", 5);
    try testing.expectEqual(@as(i32, 55), s5.value);

    const s10 = spiritAuraStat(&skills, "Oak Sage Aura", 10);
    try testing.expectEqual(@as(i32, 80), s10.value);
}

test "Wolverine Aura: table-driven tohit% and damage% aura" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Slot 1: item_tohit_percent ln34 (P3=25, P4=7) => slvl1=32
    const s1 = spiritAuraStat(&skills, "Wolverine Aura", 1);
    try testing.expectEqualStrings("item_tohit_percent", s1.stat);
    try testing.expectEqual(@as(i32, 32), s1.value);

    // Slot 2: damagepercent ln56 (P5=20, P6=7) => slvl1=27
    const s2 = spiritAuraStat2(&skills, "Wolverine Aura", 1);
    try testing.expectEqualStrings("damagepercent", s2.stat);
    try testing.expectEqual(@as(i32, 27), s2.value);
}

test "Spirit of Barbs Aura: table-driven thorns% aura" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Barbs Aura: as1=thorns_percent ln34 (P3=50, P4=10) => slvl1=60, slvl5=100
    const s1 = spiritAuraStat(&skills, "Barbs Aura", 1);
    try testing.expectEqualStrings("thorns_percent", s1.stat);
    try testing.expectEqual(@as(i32, 60), s1.value);

    const s5 = spiritAuraStat(&skills, "Barbs Aura", 5);
    try testing.expectEqual(@as(i32, 100), s5.value);
}

test "Druid summons: table-driven petmax counts and monster names" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();

    // Spirit Wolf: summon=spiritwolf, petmax=min(lvl,5)
    const sw1 = druidSummonInfo(&skills, "Summon Spirit Wolf", 1);
    try testing.expectEqualStrings("spiritwolf", sw1.monster);
    try testing.expectEqual(@as(i32, 1), sw1.count);

    const sw5 = druidSummonInfo(&skills, "Summon Spirit Wolf", 5);
    try testing.expectEqual(@as(i32, 5), sw5.count);

    const sw8 = druidSummonInfo(&skills, "Summon Spirit Wolf", 8);
    try testing.expectEqual(@as(i32, 5), sw8.count);

    // Dire Wolf (Fenris): summon=fenris, petmax=min(lvl,3)
    const df1 = druidSummonInfo(&skills, "Summon Fenris", 1);
    try testing.expectEqualStrings("fenris", df1.monster);
    try testing.expectEqual(@as(i32, 1), df1.count);

    const df3 = druidSummonInfo(&skills, "Summon Fenris", 3);
    try testing.expectEqual(@as(i32, 3), df3.count);

    const df5 = druidSummonInfo(&skills, "Summon Fenris", 5);
    try testing.expectEqual(@as(i32, 3), df5.count);

    // Grizzly: summon=druidbear, petmax=1
    const grz1 = druidSummonInfo(&skills, "Summon Grizzly", 1);
    try testing.expectEqualStrings("druidbear", grz1.monster);
    try testing.expectEqual(@as(i32, 1), grz1.count);

    // Oak Sage: summon=oaksage, petmax=1
    const oak = druidSummonInfo(&skills, "Oak Sage", 1);
    try testing.expectEqualStrings("oaksage", oak.monster);
    try testing.expectEqual(@as(i32, 1), oak.count);
}
