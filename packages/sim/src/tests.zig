//! Test aggregator + combat-core determinism / correctness tests.

const std = @import("std");
const testing = std.testing;
const sim = @import("lib.zig");
const combat = sim.combat;
const montable = sim.montable;
const spell = sim.spell;

test {
    // Pull in module-local tests (rng, stat, unit).
    _ = sim;
}

fn mkAttacker() sim.Unit {
    var a = sim.Unit.init(.player);
    a.set(.level, 30);
    a.set(.dexterity, 120);
    a.set(.strength, 150);
    a.set(.tohit, 1500);
    a.weapon = .{ .min_damage = 20, .max_damage = 60, .str_bonus = 100, .dex_bonus = 0 };
    return a;
}

fn mkDefender() sim.Unit {
    var d = sim.Unit.init(.monster);
    d.set(.level, 28);
    d.set(.armorclass, 800);
    d.setLife(1200);
    return d;
}

test "determinism: same (attacker, defender, seed) -> identical result" {
    const a = mkAttacker();
    const d = mkDefender();
    var s1 = sim.Seed.fromValue(0xC0FFEE);
    var s2 = sim.Seed.fromValue(0xC0FFEE);
    for (0..64) |_| {
        const r1 = combat.resolveAttack(&a, &d, &s1, .{});
        const r2 = combat.resolveAttack(&a, &d, &s2, .{});
        try testing.expectEqual(r1.hit, r2.hit);
        try testing.expectEqual(r1.chance, r2.chance);
        try testing.expectEqual(r1.damage, r2.damage);
        try testing.expectEqual(r1.raw_damage, r2.raw_damage);
    }
}

test "hit chance clamps to [5, 95]" {
    // Overwhelming AR, target level 1, attacker high level -> clamps at 95.
    try testing.expectEqual(@as(i32, 95), combat.chanceToHit(1_000_000, 1, 99, 1));
    // Zero AR against huge defense -> clamps at 5.
    try testing.expectEqual(@as(i32, 5), combat.chanceToHit(0, 1_000_000, 1, 99));
    // Every result stays within bounds across a sweep.
    var ar: i32 = 0;
    while (ar <= 5000) : (ar += 137) {
        var def: i32 = 0;
        while (def <= 5000) : (def += 211) {
            const c = combat.chanceToHit(ar, def, 30, 30);
            try testing.expect(c >= 5 and c <= 95);
        }
    }
}

test "chanceToHit matches the documented integer formula" {
    // ar=1500 def=800 alvl=30 dlvl=28:
    //   pct = 1500*100/(800+1500) = 150000/2300 = 65
    //   chance = 65*2*30/(30+28) = 3900/58 = 67
    try testing.expectEqual(@as(i32, 67), combat.chanceToHit(1500, 800, 30, 28));
}

test "getDefense = armorclass + dex/4, scaled by item_armor_percent" {
    var d = sim.Unit.init(.monster);
    d.set(.armorclass, 800);
    d.set(.dexterity, 40); // +10
    try testing.expectEqual(@as(i32, 810), combat.getDefense(&d));
    d.set(.item_armor_percent, 50); // 810 + 810*50/100 = 810 + 405
    try testing.expectEqual(@as(i32, 1215), combat.getDefense(&d));
}

test "physical damage: known stat combo produces the expected range" {
    // Weapon 20-60, str 150 @ str_bonus 100 -> +150% ED. No item mindmg/maxdmg %.
    //   min256 = 20<<8 = 5120; max256 = 60<<8 = 15360
    //   dmg_pct = 0 (damagepercent) + 150*100/100 = 150
    //   min_out = 5120 + 5120*150/100 = 5120 + 7680 = 12800  (=> 50 whole)
    //   max_out = 15360 + 15360*150/100 = 15360 + 23040 = 38400 (=> 150 whole)
    var a = mkAttacker();
    var s = sim.Seed.fromValue(42);
    const pd = combat.rollPhysicalDamage(&a, &s, .{});
    try testing.expectEqual(@as(i32, 12800), pd.min256);
    try testing.expectEqual(@as(i32, 38400), pd.max256);
    try testing.expect(pd.rolled256 >= pd.min256 and pd.rolled256 < pd.max256);
    // whole rolled damage lands in [50, 150).
    try testing.expect(pd.whole() >= 50 and pd.whole() < 150);
}

test "damage application: flat DR then resist%" {
    var d = sim.Unit.init(.monster);
    d.set(.normal_damage_reduction, 10); // flat 10 (=2560 in <<8)
    d.set(.damageresist, 25); // 25% physical resist
    // incoming 100 whole = 25600 <<8. minus 2560 = 23040. *75/100 = 17280 (=67 whole).
    const out = combat.applyPhysical(100 << 8, &d);
    try testing.expectEqual(@as(i32, 17280), out);
    try testing.expectEqual(@as(i32, 67), out >> 8);
}

test "physical resist clamps at cap 50" {
    var d = sim.Unit.init(.monster);
    d.set(.damageresist, 90); // clamps to 50
    const out = combat.applyPhysical(100 << 8, &d);
    try testing.expectEqual(@as(i32, 50 << 8), out); // 50% of 100
}

test "applyToLife floors at zero" {
    var d = mkDefender();
    combat.applyToLife(&d, 5000);
    try testing.expectEqual(@as(i32, 0), d.life());
    try testing.expect(!d.isAlive());
}

test "chanceToHit: known AR/DEF/levels -> exact percent (attacker level in numerator)" {
    // Attacker AR=2000, defender DEF=1000, alvl=40, dlvl=30 (from DAMAGE_RollAttackHit).
    //   pct    = 2000*100/(1000+2000) = 200000/3000 = 66
    //   chance = 66 * 2*40 / (40+30) = 66*80/70 = 5280/70 = 75
    try testing.expectEqual(@as(i32, 75), combat.chanceToHit(2000, 1000, 40, 30));
    // Higher ATTACKER level must RAISE the chance (confirms the numerator is attacker level):
    const lo = combat.chanceToHit(2000, 1000, 20, 30);
    const hi = combat.chanceToHit(2000, 1000, 60, 30);
    try testing.expect(hi > lo);
}

test "blockChance: (dex-15)*(toblock+BlockFactor)/(2*clvl), capped at 75" {
    // toblock stat 0, BlockFactor 20, dex 115, clvl 20:
    //   (115-15)*(0+20)/(2*20) = 100*20/40 = 2000/40 = 50.
    try testing.expectEqual(@as(i32, 50), combat.blockChance(0, combat.BLOCK_FACTOR, 115, 20));
    // High dex + low level saturates the 75 cap: (215-15)*20/(2*10) = 200*20/20 = 200 -> 75.
    try testing.expectEqual(@as(i32, 75), combat.blockChance(0, combat.BLOCK_FACTOR, 215, 10));
    // clvl floors at 1: (35-15)*20/(2*1) = 20*20/2 = 200 -> 75.
    try testing.expectEqual(@as(i32, 75), combat.blockChance(0, combat.BLOCK_FACTOR, 35, 0));
}

test "unified model: a blocked hit lands but deals zero damage" {
    // Attacker guaranteed to hit; defender is a player with max block -> forced block.
    var atk = sim.Unit.init(.monster);
    atk.set(.level, 1);
    atk.set(.tohit, 1_000_000);
    atk.weapon = .{ .min_damage = 50, .max_damage = 90 };
    var def = sim.Unit.init(.player);
    def.set(.level, 5);
    def.set(.dexterity, 400); // huge dex -> block caps at 75
    def.set(.toblock, 200);
    def.setLife(500);

    // Scan seeds until we observe a block; assert blocked => hit but zero damage.
    var found = false;
    var v: u32 = 1;
    while (v < 400 and !found) : (v += 1) {
        var s = sim.Seed.fromValue(v);
        const r = combat.resolveAttack(&atk, &def, &s, .{ .defender_block_factor = combat.BLOCK_FACTOR });
        if (r.blocked) {
            try testing.expect(r.hit);
            try testing.expectEqual(@as(i32, 0), r.damage);
            found = true;
        }
    }
    try testing.expect(found);
}

test "unified model: elemental rider is resisted separately from physical" {
    var atk = sim.Unit.init(.player);
    atk.set(.level, 30);
    atk.set(.dexterity, 200);
    atk.set(.tohit, 1_000_000); // always hits
    atk.weapon = .{ .min_damage = 10, .max_damage = 10 }; // fixed 10 physical
    var def = sim.Unit.init(.monster);
    def.set(.level, 1);
    def.set(.fireresist, 50); // 50% fire resist -> half the fire rider
    def.setLife(1000);

    var s = sim.Seed.fromValue(0xF12E);
    // 20 fixed fire damage rider; monster has no physical resist so physical applies in full.
    const r = combat.resolveAttack(&atk, &def, &s, .{ .elem_element = .fire, .elem_min = 20, .elem_max = 20 });
    try testing.expect(r.hit);
    try testing.expectEqual(spell.Element.fire, r.elem_element);
    try testing.expectEqual(@as(i32, 10), r.elem_damage); // 20 * (100-50)/100 = 10
    // total = physical(10) + resisted fire(10) = 20.
    try testing.expectEqual(@as(i32, 20), r.damage);
}

test "unified model: monster physical resist is UNCAPPED (unlike the player 50 cap)" {
    // Player defender: damageresist clamps to 50.
    var pl = sim.Unit.init(.player);
    pl.set(.damageresist, 90);
    try testing.expectEqual(@as(i32, 50 << 8), combat.applyPhysicalFor(100 << 8, &pl)); // 50%
    // Monster defender: same 90% is applied uncapped -> only 10% gets through.
    var mob = sim.Unit.init(.monster);
    mob.set(.damageresist, 90);
    try testing.expectEqual(@as(i32, 10 << 8), combat.applyPhysicalFor(100 << 8, &mob));
    // Monster physical-immune (>=100) takes zero.
    mob.set(.damageresist, 100);
    try testing.expectEqual(@as(i32, 0), combat.applyPhysicalFor(100 << 8, &mob));
}

test "montable: MonLvl-scaled monster AC + AR feed a monster->player attack" {
    var t = try montable.Tables.load(testing.allocator);
    defer t.deinit();

    // Fallen (class 19) at monster level 30, Normal. AC = MonLvl.AC[30] * MonStats.AC / 100.
    const mc = t.combat(19).?;
    const row = t.lvlRow(30).?;
    const sc = t.scaled(19, 30, .normal).?;
    try testing.expectEqual(@divTrunc(row.ac[0] * mc.ac[0], 100), sc.armor_class);
    try testing.expectEqual(@divTrunc(row.th[0] * mc.a1_th[0], 100), sc.attack_rating_a1);

    // Drive a monster->player swing with the scaled A1 through the unified model.
    var player = sim.Unit.init(.player);
    player.set(.level, 30);
    player.set(.armorclass, 200);
    player.setLife(400);
    const atk = combat.MonsterAttack{
        .attack_rating = sc.attack_rating_a1,
        .min_damage = @max(1, sc.a1_min),
        .max_damage = @max(2, sc.a1_max),
        .monster_level = 30,
    };
    var s = sim.Seed.fromValue(0xB0B);
    const before = player.life();
    const r = combat.resolveMonsterAttack(atk, &player, &s, combat.BLOCK_FACTOR);
    try testing.expect(r.chance >= 5 and r.chance <= 95);
    try testing.expectEqual(sc.attack_rating_a1, r.ar);
    // Determinism + damage sanity: same seed reproduces; life drops by the applied damage.
    var s2 = sim.Seed.fromValue(0xB0B);
    const r2 = combat.resolveMonsterAttack(atk, &player, &s2, combat.BLOCK_FACTOR);
    try testing.expectEqual(r.hit, r2.hit);
    try testing.expectEqual(r.damage, r2.damage);
    if (r.hit and !r.blocked) {
        combat.applyToLife(&player, r.damage);
        try testing.expectEqual(@max(@as(i32, 0), before - r.damage), player.life());
    }
}

test "miss deals no damage" {
    const a = mkAttacker();
    const d = mkDefender();
    // chance floor is 5%; find a seed that misses by scanning.
    var found_miss = false;
    var seed_val: u32 = 1;
    while (seed_val < 200 and !found_miss) : (seed_val += 1) {
        var s = sim.Seed.fromValue(seed_val);
        const r = combat.resolveAttack(&a, &d, &s, .{});
        if (!r.hit) {
            try testing.expectEqual(@as(i32, 0), r.damage);
            try testing.expectEqual(@as(i32, 0), r.raw_damage);
            found_miss = true;
        }
    }
    try testing.expect(found_miss);
}
