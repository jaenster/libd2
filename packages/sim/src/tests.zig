//! Test aggregator + combat-core determinism / correctness tests.

const std = @import("std");
const testing = std.testing;
const sim = @import("lib.zig");
const combat = sim.combat;

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
