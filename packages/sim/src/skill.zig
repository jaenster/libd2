//! Skill dispatch — faithful port of the D2 1.14d server "do skill" path.
//!
//! Ghidra session 62fbfe69, 1.14d Game.exe. Modelled entry points:
//!   SKILL_ExecuteClientDoFunc         the server acting on a client skill request
//!   (Skills.txt srvdofunc dispatch)   the server "do function" switch per skill
//!
//! A skill row (Skills.txt) selects behaviour via a srvdofunc-style switch:
//!   * srvdofunc == 1 (DOFUNC_ATTACK)  -> a melee/direct attack resolved through the
//!                                        combat core (DAMAGE_* path).
//!   * srvmissile set (references a     -> a ranged cast: spawn the named missile
//!     Missiles.txt "Missile" name)       aimed at the target (see missile.zig).
//! Everything else is UNKNOWN this pass. This is the FRAMEWORK plus a vertical slice
//! (Attack + a bolt); the ~300-skill catalog, aura/passive/state srvdofuncs, mana
//! enforcement, cooldowns, LoS and multi-missile fan patterns are explicit TODOs.

const std = @import("std");
const rng = @import("rng.zig");
const unit = @import("unit.zig");
const combat = @import("combat.zig");
const missile = @import("missile.zig");
const txt = @import("txt.zig");

const Seed = rng.Seed;
const Unit = unit.Unit;

/// srvdofunc values we act on (Skills.txt). Names follow the engine's DOFUNC_* space;
/// only the slice's value is enumerated, the rest fall through to `unknown`.
pub const DoFunc = enum(i32) {
    none = 0,
    attack = 1, // DOFUNC_ATTACK — normal melee/direct attack
    _,
};

/// One Skills.txt row, reduced to the dispatch-relevant fields.
pub const SkillData = struct {
    id: u16 = 0,
    srvdofunc: i32 = 0,
    /// srvmissile — the Missiles.txt "Missile" name spawned server-side ("" = none).
    srvmissile: []const u8 = "",
    mana: i32 = 0,
    manashift: i32 = 0,

    pub fn kind(self: SkillData) Kind {
        if (self.srvmissile.len != 0) return .missile;
        if (self.srvdofunc == @intFromEnum(DoFunc.attack)) return .melee;
        return .unknown;
    }
};

pub const Kind = enum { melee, missile, unknown };

/// Loaded Skills.txt, indexed by numeric Id.
pub const Skills = struct {
    table: txt.Table,

    pub const EMBEDDED = @embedFile("excel/Skills.txt");

    pub fn load(gpa: std.mem.Allocator) !Skills {
        return .{ .table = try txt.Table.parse(gpa, EMBEDDED) };
    }
    pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Skills {
        return .{ .table = try txt.Table.parse(gpa, src) };
    }
    pub fn deinit(self: *Skills) void {
        self.table.deinit();
    }

    /// Look up a skill by numeric Id. The returned srvmissile slice borrows the
    /// table's arena (valid for the lifetime of this Skills).
    pub fn byId(self: *const Skills, id: u16) ?SkillData {
        const row = self.table.findByInt("Id", id) orelse return null;
        const t = &self.table;
        return .{
            .id = id,
            .srvdofunc = @intCast(t.int(row, "srvdofunc")),
            .srvmissile = t.str(row, "srvmissile"),
            .mana = @intCast(t.int(row, "mana")),
            .manashift = @intCast(t.int(row, "manashift")),
        };
    }
};

/// Where a cast is aimed. `unit` is the target unit for entity-targeted casts (melee
/// needs it; a missile aims at its position). `x`/`y` is the cast location (used when
/// there is no target unit, e.g. LeftSkillOnLocation).
pub const Target = struct {
    x: i32 = 0,
    y: i32 = 0,
    unit: ?*const Unit = null,
};

/// The result of a cast, for the host to apply against live game state.
pub const Outcome = union(enum) {
    /// Skill not found, no valid target, or an unmodelled srvdofunc — nothing happens.
    none,
    /// A resolved melee attack. Apply `.result.damage` to the target on `.hit`.
    melee: combat.AttackResult,
    /// A spawned missile to add to the game (assign it a guid first).
    missile: missile.Missile,
};

/// SKILL_ExecuteClientDoFunc (slice): run skill `skill_id` cast by `caster` at
/// `target`, drawing from `skills`/`missiles`. Pure — it never mutates game state;
/// the host applies the returned Outcome (subtract melee damage / add the missile).
///
/// Mana is NOT enforced this pass (the runtime player has no mana pool yet) — the
/// cost is exposed on SkillData for the host to gate later; see module TODOs.
pub fn execute(
    skills: *const Skills,
    missiles: *const missile.Missiles,
    caster: *const Unit,
    skill_id: u16,
    target: Target,
    seed: *Seed,
) Outcome {
    const sd = skills.byId(skill_id) orelse return .none;
    switch (sd.kind()) {
        .melee => {
            const t = target.unit orelse return .none;
            if (!t.isAlive()) return .none;
            return .{ .melee = combat.resolveAttack(caster, t, seed, .{}) };
        },
        .missile => {
            const md = missiles.byName(sd.srvmissile) orelse return .none;
            // Damage: explicit Missiles.txt damage if present, else derive the bounds
            // from the caster's physical damage (skill elemental scaling is a TODO).
            var dmin = md.min_damage;
            var dmax = md.max_damage;
            if (dmax <= dmin) {
                const pd = combat.rollPhysicalDamage(caster, seed, .{});
                dmin = pd.min256 >> 8;
                dmax = pd.max256 >> 8;
            }
            // Aim at the target unit's position when entity-targeted, else the location.
            const tx = if (target.unit) |u| u.x else target.x;
            const ty = if (target.unit) |u| u.y else target.y;
            const m = missile.Missile.create(md, caster.unit_id, caster.x, caster.y, tx, ty, dmin, dmax);
            return .{ .missile = m };
        },
        .unknown => return .none,
    }
}

/// Apply an Outcome: the melee arm subtracts its damage from `target`'s life (pure — mutates
/// only that unit); the missile arm is RETURNED for the host to assign a guid + append (the
/// lib never sees a guid allocator or the missile collection). Returns null for `.none` and
/// the applied melee arm.
pub fn applyOutcome(out: Outcome, target: ?*Unit) ?missile.Missile {
    switch (out) {
        .none => return null,
        .melee => |res| {
            if (res.hit) if (target) |t| combat.applyToLife(t, res.damage);
            return null;
        },
        .missile => |m| return m,
    }
}

const testing = std.testing;

test "applyOutcome: melee arm subtracts life, missile arm is returned for the host" {
    var mob = Unit.init(.monster);
    mob.setLife(50);
    const hit = Outcome{ .melee = .{ .hit = true, .chance = 95, .ar = 0, .def = 0, .raw_damage = 12, .damage = 12 } };
    try testing.expectEqual(@as(?missile.Missile, null), applyOutcome(hit, &mob));
    try testing.expectEqual(@as(i32, 38), mob.life());

    const miss = Outcome{ .melee = .{ .hit = false, .chance = 5, .ar = 0, .def = 0, .raw_damage = 0, .damage = 0 } };
    try testing.expectEqual(@as(?missile.Missile, null), applyOutcome(miss, &mob));
    try testing.expectEqual(@as(i32, 38), mob.life()); // unchanged on a miss

    const spawn = Outcome{ .missile = .{ .guid = 0, .id = 58 } };
    const out = applyOutcome(spawn, null);
    try testing.expect(out != null);
    try testing.expectEqual(@as(u16, 58), out.?.id);
}

test "classify: Attack is melee, Fire Bolt is a missile" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(Kind.melee, s.byId(0).?.kind()); // Attack
    try testing.expectEqual(Kind.missile, s.byId(36).?.kind()); // Fire Bolt
    try testing.expectEqualStrings("firebolt", s.byId(36).?.srvmissile);
    try testing.expectEqual(@as(?SkillData, null), s.byId(9999));
}

test "execute: melee skill resolves through the combat core" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();

    var caster = Unit.init(.player);
    caster.unit_id = 1;
    caster.set(.level, 30);
    caster.set(.dexterity, 120);
    caster.set(.tohit, 5000);
    caster.weapon = .{ .min_damage = 20, .max_damage = 60 };
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.set(.level, 1);
    mob.setLife(50);

    var seed = Seed.fromValue(0xC0FFEE);
    const out = execute(&skills, &missiles, &caster, 0, .{ .unit = &mob }, &seed);
    try testing.expect(out == .melee);
    try testing.expect(out.melee.chance >= 5 and out.melee.chance <= 95);
}

test "execute: bolt skill spawns a missile aimed at the target" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();

    var caster = Unit.init(.player);
    caster.unit_id = 1;
    caster.x = 0;
    caster.y = 0;
    caster.weapon = .{ .min_damage = 3, .max_damage = 5 };
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.x = 200;
    mob.y = 0;
    mob.setLife(50);

    var seed = Seed.fromValue(1);
    const out = execute(&skills, &missiles, &caster, 36, .{ .unit = &mob }, &seed); // Fire Bolt
    try testing.expect(out == .missile);
    try testing.expectEqual(@as(u16, 58), out.missile.id); // firebolt
    try testing.expectEqual(@as(u32, 1), out.missile.owner_id);
    try testing.expect(out.missile.vx > 0); // aimed toward +X (the monster)
    try testing.expect(out.missile.dmg_max >= out.missile.dmg_min);
}

test "execute: unknown skill / dead target -> none" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();
    var caster = Unit.init(.player);
    var seed = Seed.fromValue(1);
    try testing.expect(execute(&skills, &missiles, &caster, 4242, .{}, &seed) == .none);
    var dead = Unit.init(.monster);
    dead.setLife(0);
    try testing.expect(execute(&skills, &missiles, &caster, 0, .{ .unit = &dead }, &seed) == .none);
}
