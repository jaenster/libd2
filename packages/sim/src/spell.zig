//! Elemental spell damage — faithful port of the D2 1.14d sorceress cast-damage path.
//!
//! Sources (all faithful, no invented numbers):
//!   * Staged per-level damage progression: SKILLS_GetDamage staged breakpoints, mirrored by
//!     kolbot GameData.js `stagedDamage` (libs/modules/GameData.js:204). The engine folds the
//!     EMinLev1..5 / EMaxLev1..5 columns at hard breakpoints clvl 8 / 16 / 22 / 28:
//!       lvl>28: a += EMinLev5*(l-28); l=28
//!       lvl>22: a += EMinLev4*(l-22); l=22
//!       lvl>16: a += EMinLev3*(l-16); l=16
//!       lvl>8 : a += EMinLev2*(l-8) ; l=8
//!       a += EMinLev1*(max(0,l)-1)          (so level 1 == EMin, no per-level add)
//!       return (a) << HitShift                (HitShift is the skill's fixed-point shift)
//!   * Synergy: dmg *= 1 + Σ(otherHardSkillLevel * synergyPct)  (GameData.js:566-583).
//!     Per-synergy % is the skill's synergy calc (Skills.txt *Dmg columns); the cold-tree
//!     values are the standard 1.14d ones (GameData.js:247-253 `synergyCalc`).
//!   * Mastery: dmg *= 1 + passive_cold_mastery(331)/100 (GameData.js:602-606).
//!   * Element damage values are read from the 1.14d PC/mac Skills.txt row for the skill
//!     (EType/EMin/EMax/EMinLev1..5/EMaxLev1..5/ELen/HitShift). Ice Bolt (Id 39) is fully
//!     implemented as the single-target vertical slice; its row (verified from the 1.14d
//!     data): EType=cold EMin=6 EMax=10 EMinLev1..5=2,4,6,8,10 EMaxLev1..5=3,5,7,9,11
//!     ELen=150 HitShift=7.
//!
//! HitShift NOTE: the engine computes staged damage in a HitShift fixed-point space then the
//! display/applied damage is `value >> 8` (GameData.js:648-651 does `<<HitShift` then `>>8`).
//! For Ice Bolt HitShift=7, so the whole applied damage is `staged >> 1` — i.e. Ice Bolt at
//! clvl 1 is EMin>>1 = 3 to EMax>>1 = 5, exactly matching the in-game tooltip (3-5).

const std = @import("std");
const rng = @import("rng.zig");
const unit = @import("unit.zig");
const stat = @import("stat.zig");

const Seed = rng.Seed;
const Unit = unit.Unit;

/// Skills.txt EType — the element a skill's E* damage columns belong to.
pub const Element = enum {
    none,
    fire,
    lightning,
    magic,
    cold,
    poison,

    /// Parse the Skills.txt EType token.
    pub fn parse(s: []const u8) Element {
        if (std.mem.eql(u8, s, "fire")) return .fire;
        if (std.mem.eql(u8, s, "ltng")) return .lightning;
        if (std.mem.eql(u8, s, "mag")) return .magic;
        if (std.mem.eql(u8, s, "cold")) return .cold;
        if (std.mem.eql(u8, s, "pois")) return .poison;
        return .none;
    }

    /// The unit's resist stat id for this element (ItemStatCost). Physical/none => damageresist.
    pub fn resistStat(self: Element) stat.Stat {
        return switch (self) {
            .fire => .fireresist,
            .lightning => .lightresist,
            .cold => .coldresist,
            .poison => .poisonresist,
            .magic => .magicresist,
            .none => .damageresist,
        };
    }

    /// The Sorceress element-mastery passive stat id for this element (0 => none).
    pub fn masteryStat(self: Element) ?stat.Stat {
        return switch (self) {
            .fire => .passive_fire_mastery,
            .lightning => .passive_ltng_mastery,
            .cold => .passive_cold_mastery,
            .poison => .passive_pois_mastery,
            else => null,
        };
    }
};

/// A skill's elemental-damage row (Skills.txt E* columns) — the staged-progression inputs.
pub const ElementalDamage = struct {
    etype: Element = .none,
    e_min: i32 = 0,
    e_max: i32 = 0,
    e_min_lev: [5]i32 = .{ 0, 0, 0, 0, 0 }, // EMinLev1..5
    e_max_lev: [5]i32 = .{ 0, 0, 0, 0, 0 }, // EMaxLev1..5
    hit_shift: i32 = 0, // Skills.txt HitShift (fixed-point space of the staged calc)

    /// SKILLS_GetDamage staged progression (see module header). `base` is EMin or EMax; `lev`
    /// is the matching EMinLev1..5 / EMaxLev1..5 breakpoints. Returns the value in HitShift
    /// space (caller applies `>> 8`). `clvl` is the effective skill level (hard + item points).
    fn staged(clvl: i32, base: i32, lev: [5]i32, hit_shift: i32) i64 {
        var l = clvl;
        var a: i64 = base;
        if (l > 28) {
            a += @as(i64, lev[4]) * (l - 28);
            l = 28;
        }
        if (l > 22) {
            a += @as(i64, lev[3]) * (l - 22);
            l = 22;
        }
        if (l > 16) {
            a += @as(i64, lev[2]) * (l - 16);
            l = 16;
        }
        if (l > 8) {
            a += @as(i64, lev[1]) * (l - 8);
            l = 8;
        }
        a += @as(i64, lev[0]) * (@max(0, l) - 1);
        return a << @intCast(hit_shift);
    }

    /// Min damage in 1/256 fixed point at `clvl` (the SkillCalc `edns` value; edmn = this >> 8).
    pub fn min256(self: ElementalDamage, clvl: i32) i64 {
        return staged(clvl, self.e_min, self.e_min_lev, self.hit_shift);
    }
    /// Max damage in 1/256 fixed point at `clvl` (the SkillCalc `edxs`; edmx = this >> 8).
    pub fn max256(self: ElementalDamage, clvl: i32) i64 {
        return staged(clvl, self.e_max, self.e_max_lev, self.hit_shift);
    }

    /// Whole-damage min for this element at `clvl`, before synergy/mastery: staged(EMin) >> 8.
    pub fn minAt(self: ElementalDamage, clvl: i32) i32 {
        return @intCast(self.min256(clvl) >> 8);
    }

    /// Whole-damage max for this element at `clvl`, before synergy/mastery: staged(EMax) >> 8.
    pub fn maxAt(self: ElementalDamage, clvl: i32) i32 {
        return @intCast(self.max256(clvl) >> 8);
    }
};

/// One synergy contributor: `skill_id`'s hard level adds `pct` (as parts-per-100 ×10 for
/// precision — see below) to the 1.00 multiplier per level. We keep the percentage as an
/// integer permille (‰) so the multiplier is exact integer arithmetic: 0.15 (15%) = 150‰.
pub const Synergy = struct {
    /// Fraction added to the synergy multiplier per level of the referenced skill, in permille
    /// (‰): the D2 synergy % (e.g. 15% => 150). Faithful to Skills.txt *Dmg columns.
    permille: i32,
    /// Hard-point level of the referenced synergy skill (caller supplies from the char sheet).
    skill_level: i32,
};

/// A fully-specified cast: the skill's element row, the caster's effective skill level, its
/// synergies (with the caster's level in each), and the caster's element mastery. Pure inputs —
/// the caller resolves skill levels + synergy levels from the character sheet and passes them in.
/// Max synergy contributors a sealed (self-contained) Cast can carry inline. D2 skills reference
/// at most a handful; the cold tree's Ice Bolt has 5.
pub const MAX_SYNERGIES = 8;

pub const Cast = struct {
    dmg: ElementalDamage,
    /// Effective skill level: hard points + +skills from items (SKILLS_GetSkillLevel).
    skill_level: i32,
    /// Skills.txt ELen — the poison/effect duration in frames, carried so a poison missile can spread
    /// its resisted total as a DoT over this length at hit time (0 => instant / non-poison).
    e_len: i32 = 0,
    /// Synergy contributors for this skill (empty => none). Borrowed — valid only while the
    /// caller's backing array is alive. `seal` copies these inline so the Cast can outlive it
    /// (e.g. carried on a Missile as `elem_cast`); `damage` sums the slice AND the inline store.
    synergies: []const Synergy = &.{},
    /// Inline synergy store populated by `seal` (so a Cast can be stored/copied without a dangling
    /// `synergies` slice). `syn_count` entries of `syn_store` are live.
    syn_store: [MAX_SYNERGIES]Synergy = undefined,
    syn_count: u8 = 0,
    /// +% ELEMENT DAMAGE mastery (percent). Applies to Fire Mastery (passive_fire_mastery 329),
    /// Lightning Mastery (330) and Poison Mastery (332) — these ADD damage. Cold Mastery is NOT
    /// a damage bonus (see `pierce_percent`). 0 => none.
    mastery_percent: i32 = 0,
    /// RESIST-PIERCE percent (subtracted from the target's resist at application time). This is
    /// how COLD MASTERY works in 1.14d: passive_cold_pierce (ItemStatCost 335) — Param1=20 +
    /// Param2=5 per level => -20% enemy cold resist at slvl 1, +5%/level (SUnitDmg.cpp:767,
    /// TXT_Skills_GetPassiveState @0x00643690). Also covers -%enemy-resist items (e.g. facets).
    /// Applied by `resolveElemental` (skill.zig), NOT folded into `damage`.
    pierce_percent: i32 = 0,

    /// Final whole-damage bounds for this cast: base staged element damage, ×synergy, ×mastery.
    /// Synergy multiplier = 1 + Σ(level*permille)/1000; mastery multiplier = 1 + mastery%/100.
    /// Both are applied to the whole (>>8) staged min/max, matching the engine order
    /// (GameData.js:619-626 applies synergy to min/max; :602-606 applies mastery first). We fold
    /// synergy and mastery as a single rational scale to keep it exact integer arithmetic:
    ///   out = base * (1000 + Σlev*permille) / 1000 * (100 + mastery%) / 100
    /// Cold Mastery is deliberately absent here — it pierces resist, it does not add damage.
    pub fn damage(self: Cast) struct { min: i32, max: i32 } {
        const base_min = self.dmg.minAt(self.skill_level);
        const base_max = self.dmg.maxAt(self.skill_level);

        var syn_permille: i64 = 1000;
        for (self.synergies) |s| syn_permille += @as(i64, s.skill_level) * s.permille;
        for (self.syn_store[0..self.syn_count]) |s| syn_permille += @as(i64, s.skill_level) * s.permille;

        const mastery: i64 = 100 + self.mastery_percent;

        const min = scale(base_min, syn_permille, mastery);
        const max = scale(base_max, syn_permille, mastery);
        return .{ .min = min, .max = max };
    }

    fn scale(base: i32, syn_permille: i64, mastery: i64) i32 {
        // (base * syn/1000) then (* mastery/100), each truncating toward zero (D2ApplyPercent).
        const after_syn = @divTrunc(@as(i64, base) * syn_permille, 1000);
        const after_mastery = @divTrunc(after_syn * mastery, 100);
        return @intCast(after_mastery);
    }

    /// Roll a single hit's damage uniformly in [min, max] inclusive: min + RANDOM(max-min+1).
    /// This is the engine's on-hit damage roll (RANDOM_RandomNumberSelector over the inclusive
    /// span); min==max consumes no RNG step. Consumes one step otherwise.
    pub fn roll(self: Cast, seed: *Seed) i32 {
        const d = self.damage();
        if (d.max <= d.min) return d.min;
        return d.min + @as(i32, @bitCast(seed.pick(@bitCast(d.max - d.min + 1))));
    }

    /// Return a SELF-CONTAINED copy of this cast: the borrowed `synergies` slice is copied into the
    /// inline `syn_store` and the slice cleared, so the result can be stored/copied (e.g. onto a
    /// Missile as `elem_cast`) without holding a dangling pointer to the caller's stack array. The
    /// damage is identical (`damage` sums the inline store). Extra synergies beyond MAX_SYNERGIES
    /// are dropped (no real skill exceeds it).
    pub fn seal(self: Cast) Cast {
        var out = self;
        const n = @min(self.synergies.len, MAX_SYNERGIES);
        @memcpy(out.syn_store[0..n], self.synergies[0..n]);
        out.syn_count = @intCast(n);
        out.synergies = &.{};
        return out;
    }
};

// ---------------------------------------------------------------------------
// Resistance application
// ---------------------------------------------------------------------------

/// A target's resistance to one element, as a percentage. >=100 => immune; may be negative
/// (bonus damage). The standalone passes the monster's resist for the cast's element; combat
/// never hard-depends on drlg — this is the clean seam.
pub const ResistProfile = struct {
    /// Resist percent for the element being applied (the caller selects by element).
    percent: i32 = 0,

    /// Read the element-specific resist off a Unit's stat list (players / modelled monsters).
    pub fn fromUnit(u: *const Unit, element: Element) ResistProfile {
        return .{ .percent = u.get(element.resistStat()) };
    }
};

/// Final elemental damage after resistance:  dmg * (100 - resist) / 100.
///   resist >= 100  => 0 (immune).
///   resist  < 0    => amplified (returns > dmg).
/// Faithful to the 1.14d resist path (DAMAGE_ApplyElementalDamageWithResist @0057bf80 /
/// DAMAGE_CalculateResistance @0057be00): flat-DR is physical-only; the elemental branch is the
/// straight percentage. Absorb / pierce / per-difficulty resist penalty are the caller's job
/// (the standalone folds the difficulty penalty into `resist` before calling). Integer
/// truncation matches D2ApplyPercent.
pub fn applyResist(damage: i32, resist: i32) i32 {
    if (resist >= 100) return 0;
    const prod: i64 = @as(i64, damage) * @as(i64, 100 - resist);
    return @intCast(@divTrunc(prod, 100));
}

const testing = std.testing;

// Test fixture: a sample cold-element staged row (the shape of a 1.14d cold spell) used ONLY to
// exercise the pure staged/synergy/mastery math below. The live cast path reads every one of these
// numbers off Skills.txt — see skill.zig `buildElementalCast` + its table-parity tests, and
// character.zig — so nothing here feeds production; it is a unit-test input, not game data.
const TEST_COLD: ElementalDamage = .{
    .etype = .cold,
    .e_min = 6,
    .e_max = 10,
    .e_min_lev = .{ 2, 4, 6, 8, 10 },
    .e_max_lev = .{ 3, 5, 7, 9, 11 },
    .hit_shift = 7,
};

/// Build a Cast over TEST_COLD with an explicit synergy list + resist-pierce (test helper).
fn coldCast(skill_level: i32, synergies: []const Synergy, pierce: i32) Cast {
    return .{ .dmg = TEST_COLD, .skill_level = skill_level, .synergies = synergies, .pierce_percent = pierce };
}

test "staged element damage progression (HitShift=7 => >>1)" {
    // clvl 1: staged min = EMin=6 (no per-level add) << 7 = 768; >>8 => 3. max = 10<<7>>8 => 5.
    try testing.expectEqual(@as(i32, 3), TEST_COLD.minAt(1));
    try testing.expectEqual(@as(i32, 5), TEST_COLD.maxAt(1));
    // clvl 2: min = (6 + EMinLev1*(2-1)) = 6+2 = 8 => >>1 = 4. max = (10+3) = 13 => >>1 = 6.
    try testing.expectEqual(@as(i32, 4), TEST_COLD.minAt(2));
    try testing.expectEqual(@as(i32, 6), TEST_COLD.maxAt(2));
    // clvl 9 crosses the first breakpoint (l>8 uses EMinLev2): min base folds to
    //   6 + EMinLev1*(8-1) + EMinLev2*(9-8) = 6 + 2*7 + 4*1 = 24 => >>1 = 12.
    try testing.expectEqual(@as(i32, 12), TEST_COLD.minAt(9));
}

test "synergy scaling is integer-exact and pierce never touches damage" {
    // clvl 10 base: min = 6 + 2*7 (lvls 2..8) + 4*2 (lvls 9..10) = 6+14+8 = 28 << 7 >> 8 = 14.
    const c0 = coldCast(10, &.{}, 0);
    try testing.expectEqual(@as(i32, 14), c0.damage().min);

    // Add 20 levels of one synergy at 15% (permille 150) each => +300% => ×4.00.
    const c1 = coldCast(10, &.{.{ .permille = 150, .skill_level = 20 }}, 0);
    // syn_permille = 1000 + 20*150 = 4000 => ×4. 14*4000/1000 = 56.
    try testing.expectEqual(@as(i32, 56), c1.damage().min);

    // A resist-pierce (Cold Mastery) is carried on the cast but must NOT change damage bounds.
    const c2 = coldCast(10, &.{.{ .permille = 150, .skill_level = 20 }}, 40);
    try testing.expectEqual(@as(i32, 56), c2.damage().min);
    try testing.expectEqual(@as(i32, 40), c2.pierce_percent);
    try testing.expectEqual(@as(i32, 0), c2.mastery_percent);
}

test "Fire/Lightning mastery ARE a +% damage bonus (mastery_percent path)" {
    // Fire Bolt-style row with a fire mastery of 30% doubles-less: base*130/100.
    const fire: ElementalDamage = .{ .etype = .fire, .e_min = 10, .e_max = 10, .hit_shift = 8 };
    const c = Cast{ .dmg = fire, .skill_level = 1, .mastery_percent = 30 };
    // base = 10<<8>>8 = 10; ×130% = 13.
    try testing.expectEqual(@as(i32, 13), c.damage().min);
}

test "resist application: percentage, immunity, and negative-resist amplification" {
    try testing.expectEqual(@as(i32, 75), applyResist(100, 25)); // 25% cold resist
    try testing.expectEqual(@as(i32, 100), applyResist(100, 0)); // no resist
    try testing.expectEqual(@as(i32, 0), applyResist(100, 100)); // immune (>=100)
    try testing.expectEqual(@as(i32, 0), applyResist(100, 130)); // over-immune
    try testing.expectEqual(@as(i32, 150), applyResist(100, -50)); // -50% resist => +50%
    // truncation toward zero (D2ApplyPercent): 7 dmg at 30% resist => 7*70/100 = 4.
    try testing.expectEqual(@as(i32, 4), applyResist(7, 30));
}

test "ResistProfile reads the element-specific resist off a unit" {
    var mob = Unit.init(.monster);
    mob.set(.coldresist, 40);
    mob.set(.fireresist, -20);
    try testing.expectEqual(@as(i32, 40), ResistProfile.fromUnit(&mob, .cold).percent);
    try testing.expectEqual(@as(i32, -20), ResistProfile.fromUnit(&mob, .fire).percent);
}

test "Cast.seal makes the cast self-contained (identical damage, no borrowed synergy slice)" {
    const five = [5]Synergy{
        .{ .permille = 150, .skill_level = 1 },  .{ .permille = 150, .skill_level = 20 },
        .{ .permille = 150, .skill_level = 20 }, .{ .permille = 150, .skill_level = 20 },
        .{ .permille = 150, .skill_level = 20 },
    };
    const sealed = blk: {
        const syn = five; // a copy that goes out of scope at the block's end
        const c = coldCast(20, &syn, 40);
        break :blk c.seal();
    };
    // Rebuild the same cast with a live slice to compare — sealed must match it exactly.
    const live = coldCast(20, &five, 40);
    try testing.expectEqual(live.damage().min, sealed.damage().min);
    try testing.expectEqual(live.damage().max, sealed.damage().max);
    try testing.expectEqual(@as(usize, 0), sealed.synergies.len); // slice cleared
    try testing.expectEqual(@as(u8, 5), sealed.syn_count); // 5 synergies moved inline
    try testing.expectEqual(live.pierce_percent, sealed.pierce_percent);
}

test "Cast.roll stays within [min,max] and is deterministic for a seed" {
    const c = coldCast(20, &.{.{ .permille = 150, .skill_level = 20 }}, 0);
    const d = c.damage();
    var s1 = Seed.fromValue(0xCEB01);
    var s2 = Seed.fromValue(0xCEB01);
    for (0..32) |_| {
        const r1 = c.roll(&s1);
        const r2 = c.roll(&s2);
        try testing.expectEqual(r1, r2);
        try testing.expect(r1 >= d.min and r1 <= d.max);
    }
}
