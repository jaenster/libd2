//! d2-sim demo CLI: resolve one physical attack (attacker vs defender) for a seed
//! and print the deterministic outcome. Illustrative — the library is the product.

const std = @import("std");
const sim = @import("lib.zig");

pub fn main() !void {
    var seed = sim.Seed.fromValue(0xC0FFEE);

    var attacker = sim.Unit.init(.player);
    attacker.set(.level, 30);
    attacker.set(.dexterity, 120);
    attacker.set(.strength, 150);
    attacker.set(.tohit, 1500);
    attacker.weapon = .{ .min_damage = 20, .max_damage = 60, .str_bonus = 100, .dex_bonus = 0 };

    var defender = sim.Unit.init(.monster);
    defender.set(.level, 28);
    defender.set(.armorclass, 800);
    defender.set(.damageresist, 20);
    defender.setLife(1200);

    const stdout = std.debug;
    stdout.print("d2-sim attack demo (seed=0xC0FFEE)\n", .{});
    for (0..5) |i| {
        const r = sim.resolveAttack(&attacker, &defender, &seed, .{});
        stdout.print(
            "swing {d}: AR={d} DEF={d} chance={d}% {s} raw={d} dealt={d} (def life {d}->",
            .{ i + 1, r.ar, r.def, r.chance, if (r.hit) "HIT " else "MISS", r.raw_damage, r.damage, defender.life() },
        );
        sim.combat.applyToLife(&defender, r.damage);
        stdout.print("{d})\n", .{defender.life()});
    }
}
