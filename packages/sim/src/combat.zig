//! Combat core — faithful port of the D2 1.14d physical attack-resolution path.
//!
//! Ghidra session 62fbfe69, 1.14d Game.exe. Ported functions:
//!   DAMAGE_RollAttackHit          @0057d9b0  chance-to-hit roll (AR vs defense)
//!   DAMAGE_CalculatePhysicalDamage@0057b420  base + str/dex + ED -> rolled damage
//!   DAMAGE_ApplyElementalDamageWithResist @0057bf80 / DAMAGE_CalculateResistance
//!                                  @0057be00  flat-DR then resist%, physical only
//!   GetDefense                    @006223f0  armorclass + dex/4, ×item_armor%
//!   GetAttackRate                 (partial; character-AR base only, see below)
//!
//! All damage is fixed-point <<8 internally, exactly as the engine (D2ApplyPercent
//! rounds toward zero). Elemental/poison/DOT, blocking, dodge/evade, crushing blow,
//! deadly strike and the PvP penalty are OUT OF SCOPE this pass (see TODOs).

const std = @import("std");
const stat = @import("stat.zig");
const unit = @import("unit.zig");
const rng = @import("rng.zig");

const Stat = stat.Stat;
const Unit = unit.Unit;
const Seed = rng.Seed;

/// D2ApplyPercent(v, p, d) = v*p/d, C integer division (truncates toward zero).
pub fn applyPercent(v: i32, p: i32, d: i32) i32 {
    if (d == 0) return 0;
    const prod: i64 = @as(i64, v) * @as(i64, p);
    return @intCast(@divTrunc(prod, @as(i64, d)));
}

// ---------------------------------------------------------------------------
// Attack rating & defense (inputs to the to-hit roll)
// ---------------------------------------------------------------------------

/// GetDefense @006223f0: base armorclass(31) + dexterity/4, then scaled by
/// item_armor_percent(16). skill_armor_percent(171)/armor_override_percent(182)
/// are out of scope this pass.
pub fn getDefense(u: *const Unit) i32 {
    var def = u.get(.armorclass) + @divTrunc(u.get(.dexterity), 4);
    def += applyPercent(def, u.get(.item_armor_percent), 100);
    return def;
}

/// Attack rating. PARTIAL port of GetAttackRate: the full engine function folds
/// class/skill bases; here we model the documented character-AR base plus the
/// tohit(19) stat and item_tohit_percent(119). Players: base = (dex-7)*5;
/// monsters: base = dexterity*5 (DAMAGE_RollAttackHit's monster path). Prefer
/// passing a precomputed AR to `chanceToHit` when exactness matters.
pub fn getAttackRating(u: *const Unit) i32 {
    const dex = u.get(.dexterity);
    const base: i32 = switch (u.unit_type) {
        .player => (dex - 7) * 5,
        else => dex * 5,
    };
    var ar = base + u.get(.tohit);
    ar += applyPercent(ar, u.get(.item_tohit_percent), 100);
    return ar;
}

// ---------------------------------------------------------------------------
// To-hit / chance-to-hit  (DAMAGE_RollAttackHit @0057d9b0)
// ---------------------------------------------------------------------------

/// Chance to hit, clamped to [5, 95] percent. `ar` = attacker attack rating,
/// `def` = defender defense, `alvl`/`dlvl` = attacker/defender level.
///
/// Engine math (@0057d9b0):
///   negatives cross over: if def<0 {ar-=def; def=0} if ar<0 {def-=ar; ar=0} if def<0 {def=0}
///   pct    = (def+ar==0) ? 100 : ar*100/(def+ar)
///   chance = pct * 2 * alvl / (alvl + dlvl)
///   clamp  = chance<6 ? 5 : chance>94 ? 95 : chance
/// NOTE: the RE dump labelled the numerator level `defLvl`; that inverts the
/// documented AR formula (higher attacker level must raise hit%), so we use the
/// attacker level `alvl` in the numerator — matching 200%*(AR/(AR+DR))*(alvl/(alvl+dlvl)).
pub fn chanceToHit(ar_in: i32, def_in: i32, alvl: i32, dlvl: i32) i32 {
    var ar = ar_in;
    var def = def_in;
    if (def < 0) {
        ar -= def;
        def = 0;
    }
    if (ar < 0) {
        def -= ar;
        ar = 0;
    }
    if (def < 0) def = 0;

    const denom_arac = def + ar;
    const pct: i32 = if (denom_arac == 0) 100 else @divTrunc(ar * 100, denom_arac);

    const denom_lvl = alvl + dlvl;
    var chance: i32 = if (denom_lvl == 0) pct else @divTrunc(pct * 2 * alvl, denom_lvl);

    if (chance < 6) {
        chance = 5;
    } else if (chance > 94) {
        chance = 95;
    }
    return chance;
}

/// Roll the hit: rand = RANDOM_RandomNumberSelector(100) (low-word mod 100);
/// hit if rand < chance. Consumes one RNG step.
pub fn rollHit(seed: *Seed, chance: i32) bool {
    const roll: i32 = @intCast(seed.pick(100));
    return roll < chance;
}

// ---------------------------------------------------------------------------
// Physical damage  (DAMAGE_CalculatePhysicalDamage @0057b420)
// ---------------------------------------------------------------------------

/// Skill / off-weapon inputs that feed the damage percent and are not read from
/// the unit's own stat list. `ed_percent` is param3 (SKILLS enhanced-damage %);
/// it is added to damagepercent(25) before the str/dex bonuses.
pub const DamageParams = struct {
    ed_percent: i32 = 0,
};

/// Rolled physical damage in <<8 fixed-point. `.whole` is the display value.
pub const PhysDamage = struct {
    min256: i32,
    max256: i32,
    rolled256: i32,

    pub fn whole(self: PhysDamage) i32 {
        return self.rolled256 >> 8;
    }
};

/// DAMAGE_CalculatePhysicalDamage @0057b420. Consumes one RNG step for the roll.
pub fn rollPhysicalDamage(attacker: *const Unit, seed: *Seed, params: DamageParams) PhysDamage {
    // Base min/max: weapon damage, else the mindamage(21)/maxdamage(22) stats.
    var base_min = if (attacker.weapon.min_damage > 0) attacker.weapon.min_damage else attacker.get(.mindamage);
    var base_max = if (attacker.weapon.max_damage > 0) attacker.weapon.max_damage else attacker.get(.maxdamage);
    // Flat item_normaldamage(111) add to both.
    const flat = attacker.get(.item_normaldamage);
    base_min += flat;
    base_max += flat;

    // Scale to <<8, then the engine's floor: min>=1<<8, max>=min+(1<<8).
    var min256 = base_min << 8;
    var max256 = base_max << 8;
    if (min256 < 1) min256 = 256;
    if (max256 <= min256) max256 = min256 + 256;

    // Damage percent: param3 + damagepercent(25) + str bonus + dex bonus.
    var dmg_pct = params.ed_percent + attacker.get(.damagepercent);
    dmg_pct += @divTrunc(attacker.get(.strength) * attacker.weapon.str_bonus, 100);
    dmg_pct += @divTrunc(attacker.get(.dexterity) * attacker.weapon.dex_bonus, 100);
    // SKILLS_GetItemBonusDamage folds in here in the engine; folded into ed_percent.
    if (dmg_pct < -90) dmg_pct = -90;

    // Apply percents: min uses item_mindamage_percent(18), max uses item_maxdamage_percent(17).
    const min_out = min256 + applyPercent(min256, attacker.get(.item_mindamage_percent) + dmg_pct, 100);
    const max_out = max256 + applyPercent(max256, attacker.get(.item_maxdamage_percent) + dmg_pct, 100);

    // Roll: min + RANDOM(max-min).
    const range = max_out - min_out;
    const rolled = if (range > 0) min_out + @as(i32, @bitCast(seed.pick(@bitCast(range)))) else min_out;
    return .{ .min256 = min_out, .max256 = max_out, .rolled256 = rolled };
}

// ---------------------------------------------------------------------------
// Damage application  (DAMAGE_ApplyElementalDamageWithResist @0057bf80, physical)
// ---------------------------------------------------------------------------

/// Physical damage default resist cap (0x32) — from DAMAGE_CalculateResistance.
pub const PHYS_RESIST_CAP: i32 = 50;

/// Apply the defender's physical mitigation to an incoming <<8 damage value.
/// Order (per @0057bf80): (1) flat "damage reduced by N" normal_damage_reduction(34),
/// then (2) resist% damageresist(36) clamped to [-100, 50]. Absorb, pierce and the
/// per-difficulty resist penalty (which does NOT apply to damageresist) are out of
/// scope. Returns the reduced <<8 damage.
pub fn applyPhysical(incoming256: i32, defender: *const Unit) i32 {
    // (1) flat reduction (×256), floored at 0.
    var dmg = incoming256 - (defender.get(.normal_damage_reduction) << 8);
    if (dmg < 0) dmg = 0;

    // (2) resist%.
    var resist = defender.get(.damageresist);
    if (resist < -100) resist = -100;
    if (resist > PHYS_RESIST_CAP) resist = PHYS_RESIST_CAP;
    if (resist > 99) resist = 100;
    dmg = applyPercent(dmg, 100 - resist, 100);
    return dmg;
}

// ---------------------------------------------------------------------------
// Top-level resolution
// ---------------------------------------------------------------------------

pub const AttackResult = struct {
    hit: bool,
    chance: i32, // clamped hit chance used
    ar: i32,
    def: i32,
    raw_damage: i32, // pre-mitigation, whole
    damage: i32, // post-mitigation, whole (subtract from defender life)
};

/// Resolve one physical melee attack: roll to-hit, then (on hit) roll and mitigate
/// physical damage. RNG order matches the engine: hit roll first, damage roll
/// second — so (attacker, defender, seed) fully determines the outcome. Does NOT
/// mutate the defender; call `applyToLife` to subtract.
pub fn resolveAttack(attacker: *const Unit, defender: *const Unit, seed: *Seed, params: DamageParams) AttackResult {
    const ar = getAttackRating(attacker);
    const def = getDefense(defender);
    const chance = chanceToHit(ar, def, attacker.level(), defender.level());
    const hit = rollHit(seed, chance);
    if (!hit) {
        return .{ .hit = false, .chance = chance, .ar = ar, .def = def, .raw_damage = 0, .damage = 0 };
    }
    const phys = rollPhysicalDamage(attacker, seed, params);
    const applied = applyPhysical(phys.rolled256, defender);
    return .{
        .hit = true,
        .chance = chance,
        .ar = ar,
        .def = def,
        .raw_damage = phys.whole(),
        .damage = applied >> 8,
    };
}

/// Subtract a whole damage value from a unit's hitpoints(6), floored at 0.
pub fn applyToLife(u: *Unit, damage: i32) void {
    var hp = u.life() - damage;
    if (hp < 0) hp = 0;
    u.setLife(hp);
}
