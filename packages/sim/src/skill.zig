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
//!
//! ELEMENTAL DAMAGE: `resolveElemental` / `resolveElementalVsUnit` resolve a sorceress
//! cold/fire/light spell to real Skills.txt element damage (staged per-level progression +
//! synergies + mastery, see spell.zig) and apply the target's resist (Cold Mastery as a
//! resist-pierce). The standalone supplies the monster resist through the `target_resist` seam,
//! so this lib stays independent of drlg.

const std = @import("std");
const rng = @import("rng.zig");
const unit = @import("unit.zig");
const combat = @import("combat.zig");
const missile = @import("missile.zig");
const spell = @import("spell.zig");
const d2data = @import("d2-data");

const Seed = rng.Seed;
const Unit = unit.Unit;

/// srvdofunc values we act on (Skills.txt). Names follow the engine's DOFUNC_* space;
/// only the slice's value is enumerated, the rest fall through to `unknown`.
pub const DoFunc = enum(i32) {
    none = 0,
    attack = 1, // DOFUNC_ATTACK — normal melee/direct attack
    teleport = 27, // DOFUNC_TELEPORT — instant reposition to a passable target cell (Teleport Id 54)
    _,
};

/// One Skills.txt row, reduced to the dispatch-relevant fields plus the elemental-damage
/// columns. Column names are the REAL 1.14d Skills.txt headers (packages/data/src/excel):
///   dispatch:  Id, srvdofunc, srvmissile, mana, manashift
///   element:   EType, EMin, EMax, EMinLev1..5, EMaxLev1..5, ELen, HitShift
pub const SkillData = struct {
    id: u16 = 0,
    srvdofunc: i32 = 0,
    /// srvmissile — the Missiles.txt "Missile" name spawned server-side ("" = none).
    srvmissile: []const u8 = "",
    mana: i32 = 0,
    manashift: i32 = 0,
    /// The skill's Skills.txt elemental-damage row (EType/EMin.../HitShift), for the
    /// staged per-level progression in spell.zig. `.etype == .none` when the skill has no
    /// elemental damage columns filled in.
    dmg: spell.ElementalDamage = .{},
    /// ELen — the effect duration column (cold-length etc.); carried for completeness.
    e_len: i32 = 0,
    /// mana at level 1 minus manashift/lvlmana scaling reduced to the base per-cast cost. For
    /// Teleport this is the flat `mana` column (24); D2's per-level mana scaling barely moves it.
    /// Exposed so the host can gate a cast on the caster's mana pool.
    /// (mana/manashift already carried above.)

    pub fn kind(self: SkillData) Kind {
        if (self.srvdofunc == @intFromEnum(DoFunc.teleport)) return .teleport;
        if (self.srvmissile.len != 0) return .missile;
        if (self.srvdofunc == @intFromEnum(DoFunc.attack)) return .melee;
        return .unknown;
    }

    /// The per-cast mana cost read from the Skills.txt `mana` column (whole mana; the fixed-point
    /// `manashift`/`lvlmana` scaling is not modelled — Teleport's cost is effectively flat 24).
    pub fn manaCost(self: SkillData) i32 {
        return self.mana;
    }
};

pub const Kind = enum { melee, missile, unknown, teleport };

/// Loaded Skills.txt (the REAL 1.14d table from d2-data — ~256 columns, 357 rows),
/// indexed by numeric Id. Columns are addressed by NAME, never by index.
pub const Skills = struct {
    table: d2data.Table,

    pub fn load(gpa: std.mem.Allocator) !Skills {
        return .{ .table = try d2data.open(gpa, "Skills") };
    }
    pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Skills {
        return .{ .table = try d2data.tsv.parse(gpa, src) };
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
            .srvdofunc = t.getInt(i32, row, "srvdofunc") orelse 0,
            .srvmissile = t.get(row, "srvmissile"),
            .mana = t.getInt(i32, row, "mana") orelse 0,
            .manashift = t.getInt(i32, row, "manashift") orelse 0,
            .dmg = .{
                .etype = spell.Element.parse(t.get(row, "EType")),
                .e_min = t.getInt(i32, row, "EMin") orelse 0,
                .e_max = t.getInt(i32, row, "EMax") orelse 0,
                .e_min_lev = .{
                    t.getInt(i32, row, "EMinLev1") orelse 0,
                    t.getInt(i32, row, "EMinLev2") orelse 0,
                    t.getInt(i32, row, "EMinLev3") orelse 0,
                    t.getInt(i32, row, "EMinLev4") orelse 0,
                    t.getInt(i32, row, "EMinLev5") orelse 0,
                },
                .e_max_lev = .{
                    t.getInt(i32, row, "EMaxLev1") orelse 0,
                    t.getInt(i32, row, "EMaxLev2") orelse 0,
                    t.getInt(i32, row, "EMaxLev3") orelse 0,
                    t.getInt(i32, row, "EMaxLev4") orelse 0,
                    t.getInt(i32, row, "EMaxLev5") orelse 0,
                },
                .hit_shift = t.getInt(i32, row, "HitShift") orelse 0,
            },
            .e_len = t.getInt(i32, row, "ELen") orelse 0,
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
        // Teleport is a pure host-side reposition (move the caster to a passable target cell) — it
        // produces no combat/missile Outcome. The host detects `.teleport` via kind() and applies
        // the jump itself (dest-passable + range + mana gate); nothing to resolve here.
        .teleport => return .none,
        .unknown => return .none,
    }
}

/// Cast skill `skill_id` as an ELEMENTAL missile: spawn the skill's srvmissile aimed at `target`
/// and snapshot `elem_cast` onto it (the caster's build already folded in effective skill level +
/// synergies + mastery pierce). The missile is marked `caster_derived` so stepAll routes its on-hit
/// through the elemental path (missile.applyElementalHitVs) instead of the flat physical roll — the
/// applied damage is resolved per victim at hit time from the carried cast. Pure — the host assigns
/// the returned missile a guid + appends it. Returns `.none` when the skill/srvmissile is unknown.
pub fn cast(
    skills: *const Skills,
    missiles: *const missile.Missiles,
    caster: *const Unit,
    skill_id: u16,
    target: Target,
    elem_cast: spell.Cast,
) Outcome {
    const sd = skills.byId(skill_id) orelse return .none;
    const md = missiles.byName(sd.srvmissile) orelse return .none;
    const tx = if (target.unit) |u| u.x else target.x;
    const ty = if (target.unit) |u| u.y else target.y;
    var m = missile.Missile.create(md, caster.unit_id, caster.x, caster.y, tx, ty, 0, 0);
    m.caster_derived = true;
    // Seal the cast: copy its borrowed synergy slice inline so the missile can outlive the caller's
    // synergy storage without a dangling pointer (the on-hit resolution runs frames later).
    m.elem_cast = elem_cast.seal();
    return .{ .missile = m };
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

/// The result of resolving an elemental spell hit against a target.
pub const ElementalHit = struct {
    element: spell.Element,
    /// Rolled base elemental damage (after synergy + mastery, before the target's resist).
    raw: i32,
    /// Damage after the target's resist for this element: raw * (100 - resist) / 100.
    applied: i32,
    /// The resist value used (>=100 means the target was immune -> applied 0).
    resist: i32,
};

/// Resolve one elemental spell hit: roll the cast's (synergy+mastery-scaled) damage, then apply
/// the target's resist for the cast's element AFTER subtracting the cast's resist-pierce (Cold
/// Mastery / -%enemy-resist). `target_resist` is the seam the standalone fills from the monster's
/// resist (drlg-owned); this lib never depends on drlg. Consumes one RNG step (the damage roll).
/// Pure — does NOT mutate the target; call `applyElementalHit` to subtract.
///
/// This closes skill.zig's "skill elemental scaling is a TODO": a sorceress cold/fire/light cast
/// now deals its real Skills.txt element damage, synergy- and mastery-scaled, then resisted with
/// the correct Cold-Mastery-as-pierce behaviour.
pub fn resolveElemental(sp_cast: spell.Cast, target_resist: i32, seed: *Seed) ElementalHit {
    const raw = sp_cast.roll(seed);
    const effective_resist = target_resist - sp_cast.pierce_percent;
    const applied = spell.applyResist(raw, effective_resist);
    return .{ .element = sp_cast.dmg.etype, .raw = raw, .applied = applied, .resist = effective_resist };
}

/// Convenience: resolve against a Unit, reading the element-specific resist off its stat list
/// (players / modelled monsters). The standalone can instead call `resolveElemental` with a
/// resist value it pulled from the drlg monster table.
pub fn resolveElementalVsUnit(sp_cast: spell.Cast, target: *const Unit, seed: *Seed) ElementalHit {
    const resist = spell.ResistProfile.fromUnit(target, sp_cast.dmg.etype).percent;
    return resolveElemental(sp_cast, resist, seed);
}

/// Subtract an elemental hit's applied damage from the target's life (floored at 0).
pub fn applyElementalHit(hit: ElementalHit, target: *Unit) void {
    if (hit.applied > 0) combat.applyToLife(target, hit.applied);
}

const testing = std.testing;

test "resolveElemental: Ice Bolt vs a cold-resistant target applies the resist" {
    // clvl 20 Ice Bolt, no synergy/mastery: min = 6 + 4*2(9-16 span partial)... use the module's
    // verified staged value. Just assert the resist wiring: raw within [min,max], applied resisted.
    var syn: [5]spell.Synergy = undefined;
    const ic = spell.iceBolt(spell.ICE_BOLT, 20, 0, 0, 0, 0, 0, 0, &syn);
    const d = ic.damage();

    var mob = Unit.init(.monster);
    mob.set(.coldresist, 50); // 50% cold resist -> half damage
    mob.setLife(1000);

    var seed = Seed.fromValue(7);
    const hit = resolveElementalVsUnit(ic, &mob, &seed);
    try testing.expectEqual(spell.Element.cold, hit.element);
    try testing.expect(hit.raw >= d.min and hit.raw <= d.max);
    try testing.expectEqual(@as(i32, 50), hit.resist);
    try testing.expectEqual(@divTrunc(hit.raw * 50, 100), hit.applied); // (100-50)/100

    applyElementalHit(hit, &mob);
    try testing.expectEqual(1000 - hit.applied, mob.life());
}

test "resolveElemental: Cold Mastery pierces the target's cold resist" {
    var syn: [5]spell.Synergy = undefined;
    // slvl 5 Cold Mastery => -40% enemy cold resist.
    const ic = spell.iceBolt(spell.ICE_BOLT, 20, 0, 0, 0, 0, 0, 5, &syn);
    var mob = Unit.init(.monster);
    mob.set(.coldresist, 50); // 50% - 40% pierce = 10% effective resist.
    mob.setLife(1000);
    var seed = Seed.fromValue(11);
    const hit = resolveElementalVsUnit(ic, &mob, &seed);
    try testing.expectEqual(@as(i32, 10), hit.resist); // pierced 50 -> 10
    try testing.expectEqual(@divTrunc(hit.raw * 90, 100), hit.applied);
}

test "resolveElemental: cold-immune target takes zero" {
    var syn: [5]spell.Synergy = undefined;
    const ic = spell.iceBolt(spell.ICE_BOLT, 30, 0, 0, 0, 0, 0, 0, &syn);
    var mob = Unit.init(.monster);
    mob.set(.coldresist, 100); // immune
    mob.setLife(500);
    var seed = Seed.fromValue(3);
    const hit = resolveElementalVsUnit(ic, &mob, &seed);
    try testing.expectEqual(@as(i32, 0), hit.applied);
    applyElementalHit(hit, &mob);
    try testing.expectEqual(@as(i32, 500), mob.life()); // untouched
}

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

test "TABLE-DRIVEN: Teleport (Id 54) classifies as teleport with the real Skills.txt mana cost" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const tp = s.byId(54).?; // Teleport
    try testing.expectEqual(@as(i32, 27), tp.srvdofunc); // DOFUNC_TELEPORT
    try testing.expectEqual(Kind.teleport, tp.kind());
    try testing.expectEqual(@as(i32, 24), tp.mana); // Skills.txt mana column
    try testing.expectEqual(@as(i32, 24), tp.manaCost());
    try testing.expectEqualStrings("", tp.srvmissile); // reposition, not a missile
}

test "TABLE-DRIVEN: Ice Bolt (Id 39) element damage read from the REAL Skills.txt matches the parity anchor" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();
    const ib = s.byId(spell.ICE_BOLT_ID).?; // Id 39
    // The E* columns read straight from the real 1.14d Skills.txt row (no hardcoded literals):
    try testing.expectEqual(spell.Element.cold, ib.dmg.etype); // EType=cold
    try testing.expectEqual(@as(i32, 6), ib.dmg.e_min); // EMin=6
    try testing.expectEqual(@as(i32, 10), ib.dmg.e_max); // EMax=10
    try testing.expectEqual([5]i32{ 2, 4, 6, 8, 10 }, ib.dmg.e_min_lev); // EMinLev1..5
    try testing.expectEqual([5]i32{ 3, 5, 7, 9, 11 }, ib.dmg.e_max_lev); // EMaxLev1..5
    try testing.expectEqual(@as(i32, 7), ib.dmg.hit_shift); // HitShift=7
    try testing.expectEqual(@as(i32, 150), ib.e_len); // ELen=150

    // PARITY: the staged progression on the TABLE-DRIVEN row yields the known Ice Bolt numbers.
    // lvl 1 tooltip = 3-5; slvl 10 min = (6 + 2*7 + 4*2) = 28, <<7 >>8 = >>1 = 14.
    try testing.expectEqual(@as(i32, 3), ib.dmg.minAt(1));
    try testing.expectEqual(@as(i32, 5), ib.dmg.maxAt(1));
    try testing.expectEqual(@as(i32, 14), ib.dmg.minAt(10)); // the load-bearing parity number
}

test "TABLE-DRIVEN generalizes: Glacial Spike (Id 55) + Fire Bolt (Id 36) base damage from the real table" {
    var s = try Skills.load(testing.allocator);
    defer s.deinit();

    // Glacial Spike Id 55 (Skills.txt): EType=cold EMin=32 EMax=48 EMinLev1..5=14,26,28,30,32
    // EMaxLev1..5=15,27,29,31,33 HitShift=7 — proves the loader is not Ice-Bolt-specific.
    const gs = s.byId(55).?;
    try testing.expectEqual(spell.Element.cold, gs.dmg.etype);
    try testing.expectEqual(@as(i32, 32), gs.dmg.e_min);
    try testing.expectEqual(@as(i32, 48), gs.dmg.e_max);
    try testing.expectEqual([5]i32{ 14, 26, 28, 30, 32 }, gs.dmg.e_min_lev);
    try testing.expectEqual(@as(i32, 7), gs.dmg.hit_shift);
    // slvl 1 whole-damage: EMin>>1 = 16, EMax>>1 = 24 (matches the in-game 16-24 tooltip).
    try testing.expectEqual(@as(i32, 16), gs.dmg.minAt(1));
    try testing.expectEqual(@as(i32, 24), gs.dmg.maxAt(1));

    // Fire Bolt Id 36 (Skills.txt): EType=fire EMin=6 EMax=12 HitShift=7 => slvl1 = 3-6.
    const fb = s.byId(36).?;
    try testing.expectEqual(spell.Element.fire, fb.dmg.etype);
    try testing.expectEqual(@as(i32, 6), fb.dmg.e_min);
    try testing.expectEqual(@as(i32, 12), fb.dmg.e_max);
    try testing.expectEqual(@as(i32, 3), fb.dmg.minAt(1));
    try testing.expectEqual(@as(i32, 6), fb.dmg.maxAt(1));
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

test "cast: Ice Bolt spawns a caster_derived missile carrying the elemental cast" {
    var skills = try Skills.load(testing.allocator);
    defer skills.deinit();
    var missiles = try missile.Missiles.load(testing.allocator);
    defer missiles.deinit();

    var caster = Unit.init(.player);
    caster.unit_id = 7;
    caster.x = 0;
    caster.y = 0;
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.x = 300;
    mob.y = 0;
    mob.setLife(100);

    var syn: [5]spell.Synergy = undefined;
    const c = spell.iceBolt(spell.ICE_BOLT, 20, 1, 20, 20, 20, 20, 20, &syn);
    const out = cast(&skills, &missiles, &caster, 39, .{ .unit = &mob }, c); // Ice Bolt
    try testing.expect(out == .missile);
    const m = out.missile;
    try testing.expectEqual(missiles.byName("icebolt").?.id, m.id);
    try testing.expectEqual(@as(u32, 7), m.owner_id);
    try testing.expect(m.caster_derived);
    try testing.expect(m.elem_cast != null);
    try testing.expectEqual(spell.Element.cold, m.elem_cast.?.dmg.etype);
    try testing.expect(m.vx > 0); // aimed toward the monster (+X)
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
