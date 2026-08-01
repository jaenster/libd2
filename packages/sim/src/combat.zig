//! Combat core — faithful port of the D2 1.14d physical attack-resolution path.
//!
//! Ghidra session 62fbfe69, 1.14d Game.exe. Ported functions:
//!   DAMAGE_RollAttackHit          @0057d9b0  chance-to-hit roll (AR vs defense)
//!   DAMAGE_CalculatePhysicalDamage@0057b420  base + str/dex + ED -> rolled damage
//!   DAMAGE_ApplyElementalDamageWithResist @0057bf80 / DAMAGE_CalculateResistance
//!                                  @0057be00  flat-DR then resist%, physical only
//!   GetDefense                    @006223f0  armorclass + dex/4, ×item_armor%
//!   GetAttackRate                 (partial; character-AR base only, see below)
//!   GetBlockRate                  @00622720  block% = (dex-15)*(toblock+BlockFactor)/(2*clvl), cap 75
//!   DAMAGE_CalculateResistance    @0057be00  physical PDR cap 50 (players only; monsters uncapped)
//!   MONSTER_CalculateLevelScaledStats @006538a0 (montable.zig)  MonLvl-scaled AC/AR/damage
//!
//! All damage is fixed-point <<8 internally, exactly as the engine (D2ApplyPercent
//! rounds toward zero). This pass adds BLOCKING, the UNIFIED damage model (physical +
//! elemental, each resist-mitigated), and MONSTER->player attacks. Poison/DOT, dodge/evade,
//! crushing blow, deadly strike, the moving-block ÷3 penalty and the PvP penalty remain
//! OUT OF SCOPE (see TODOs).

const std = @import("std");
const stat = @import("stat.zig");
const unit = @import("unit.zig");
const rng = @import("rng.zig");
const spell = @import("spell.zig");
const montable = @import("montable.zig");

const Stat = stat.Stat;
const Unit = unit.Unit;
const Seed = rng.Seed;
const Element = spell.Element;

/// D2ApplyPercent(v, p, d) = v*p/d, C integer division (truncates toward zero).
pub fn applyPercent(v: i32, p: i32, d: i32) i32 {
    if (d == 0) return 0;
    const prod: i64 = @as(i64, v) * @as(i64, p);
    return @intCast(@divTrunc(prod, @as(i64, d)));
}

// ---------------------------------------------------------------------------
// Attack rating & defense (inputs to the to-hit roll)
// ---------------------------------------------------------------------------

/// GetDefense (Units.cpp:2304): base armorclass(31) + dexterity/4, then scaled by
/// skill_armor_percent(171) + item_armor_percent(16) summed (so Defiance / Iron Skin actually raise
/// defense). The Holy Shield state bonus (a skill.calc read) is still out of scope.
pub fn getDefense(u: *const Unit) i32 {
    var def = u.get(.armorclass) + @divTrunc(u.get(.dexterity), 4);
    def += applyPercent(def, u.get(.item_armor_percent) + u.get(.skill_armor_percent), 100);
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
    /// On-weapon / skill elemental damage rolled ALONGSIDE the physical hit (e.g. a fire-damage
    /// weapon, a Zeal that carries elemental). `.none`/0 => pure physical. Applied through the
    /// unified damage model (spell.applyResist) after the physical component.
    elem_element: Element = .none,
    elem_min: i32 = 0,
    elem_max: i32 = 0,
    /// The DEFENDER's block factor for the block roll: BLOCK_FACTOR when the defender is a player
    /// with a shield, 0 for a monster (monster toblock is raw). When null, blocking is skipped
    /// entirely (attacks that cannot be blocked / callers that model no shield).
    defender_block_factor: ?i32 = null,
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
// Blocking  (GetBlockRate @00622720 / DAMAGE_CheckBlockAndEvasion @SUnitDmg.cpp:3320)
// ---------------------------------------------------------------------------

/// Block-chance cap (0x4b) — GetBlockRate returns this whenever the computed block >= 75.
pub const BLOCK_CAP: i32 = 75;

/// CharStats.txt BlockFactor — the flat class base block added before the dex/level scale.
/// All 7 1.14d classes ship BlockFactor = 20 (CharStats.txt col 0x16). GetBlockRate:
///   nToBlock += BlockFactor.
pub const BLOCK_FACTOR: i32 = 20;

/// GetBlockRate @00622720 (player expansion path). Faithful:
///   nToBlock  = toblock(20 stat) + BlockFactor
///   clvl      = max(1, level)
///   block%    = (dexterity - 15) * nToBlock / (2 * clvl)
///   cap       = min(block%, 75)
/// A negative intermediate floors at 0 (a real char can't have a negative dex-15 with a
/// shield equipped in normal play; we clamp for safety). `toblock` is the unit's toblock(20)
/// stat, `dexterity`/`level` its current stats. The classic (non-expansion) path returns the
/// raw toblock stat; the sim targets 1.14d LoD, so this is the expansion formula.
pub fn blockChance(toblock: i32, block_factor: i32, dexterity: i32, level: i32) i32 {
    const to_block = toblock + block_factor;
    const clvl = @max(1, level);
    var pct = @divTrunc((dexterity - 15) * to_block, 2 * clvl);
    if (pct < 0) pct = 0;
    if (pct > BLOCK_CAP) pct = BLOCK_CAP;
    return pct;
}

/// Player block chance for a Unit: reads toblock(20)/dexterity(2)/level(12) off its stats and
/// adds the class BlockFactor. Monsters block off their raw toblock stat (still 75-capped) —
/// GetBlockRate's monster branch returns min(toblock, 75). `block_factor` is the caster's class
/// BlockFactor (BLOCK_FACTOR for any 1.14d class); pass 0 for a monster (its toblock is raw).
pub fn blockChanceForUnit(u: *const Unit, block_factor: i32) i32 {
    if (u.unit_type == .monster) {
        var b = u.get(.toblock);
        if (b < 0) b = 0;
        if (b > BLOCK_CAP) b = BLOCK_CAP;
        return b;
    }
    return blockChance(u.get(.toblock), block_factor, u.get(.dexterity), u.level());
}

/// Roll a block: rand = seed % 100 (D2_SEED_NEXT then low%100); blocked if rand < chance.
/// Consumes one RNG step. DAMAGE_CheckBlockAndEvasion halves-to-third (÷3) the chance while the
/// player is moving in a non-walk mode; the sim's units carry no movement mode yet, so the
/// static-stance chance is used (the ÷3 moving penalty is a documented follow-up).
pub fn rollBlock(seed: *Seed, chance: i32) bool {
    if (chance <= 0) return false;
    const roll: i32 = @intCast(seed.pick(100));
    return roll < chance;
}

// ---------------------------------------------------------------------------
// Unified damage model  (physical + elemental, resist-mitigated)
// ---------------------------------------------------------------------------

/// One element of an attack's damage. `element == .none` is the physical component and is
/// mitigated by applyPhysical (flat DR then damageresist%, physical-only cap); every other
/// element is mitigated by spell.applyResist (percentage, >=100 immune). Amounts are WHOLE.
pub const DamagePacket = struct {
    element: Element = .none,
    /// Whole (not <<8) damage of this element before the target's resist.
    amount: i32 = 0,
};

/// The mitigated result of applying a DamagePacket to a defender.
pub const AppliedComponent = struct {
    element: Element,
    raw: i32, // pre-resist whole
    applied: i32, // post-resist whole
    resist: i32, // the resist value used (physical: damageresist; else element resist)
};

/// Mitigate ONE damage element against a defender, faithfully routing physical vs elemental:
///   physical (.none) -> applyPhysical: flat normal_damage_reduction(34) then damageresist(36)%
///                       (physical cap 50 for players; monsters use raw resist).
///   elemental        -> spell.applyResist against the element's resist stat (>=100 immune).
/// `whole` is the pre-mitigation whole damage. Physical is shifted to <<8 for applyPhysical's
/// flat-DR arithmetic then shifted back (matching the engine's fixed-point path). Returns the
/// component with its raw + applied + resist used.
pub fn applyDamageComponent(whole: i32, element: Element, defender: *const Unit) AppliedComponent {
    if (element == .none) {
        const applied = applyPhysicalFor(whole << 8, defender) >> 8;
        return .{ .element = .none, .raw = whole, .applied = applied, .resist = defender.get(.damageresist) };
    }
    const resist = defender.get(element.resistStat());
    return .{ .element = element, .raw = whole, .applied = spell.applyResist(whole, resist), .resist = resist };
}

/// applyPhysical but the physical resist cap depends on the defender: players cap at 50
/// (PHYS_RESIST_CAP); MONSTERS have NO cap (DAMAGE_CalculateResistance applies the 0x32 cap only
/// when !bDefenderIsMonster). This keeps monster physical-immunity / high-PDR faithful.
pub fn applyPhysicalFor(incoming256: i32, defender: *const Unit) i32 {
    var dmg = incoming256 - (defender.get(.normal_damage_reduction) << 8);
    if (dmg < 0) dmg = 0;
    var resist = defender.get(.damageresist);
    if (defender.unit_type != .monster) {
        if (resist < -100) resist = -100;
        if (resist > PHYS_RESIST_CAP) resist = PHYS_RESIST_CAP;
    }
    if (resist >= 100) return 0; // physical immune
    dmg = applyPercent(dmg, 100 - resist, 100);
    return dmg;
}

// ---------------------------------------------------------------------------
// Top-level resolution
// ---------------------------------------------------------------------------

pub const AttackResult = struct {
    hit: bool,
    blocked: bool = false, // defender blocked the (landed) hit -> no damage
    chance: i32, // clamped hit chance used
    ar: i32,
    def: i32,
    raw_damage: i32, // pre-mitigation physical, whole
    damage: i32, // post-mitigation total (physical + elemental), whole
    /// Elemental component of the hit after resist (0 when a pure physical attack).
    elem_damage: i32 = 0,
    elem_element: Element = .none,
};

/// Resolve one attack through the UNIFIED damage model: roll to-hit (miss => no damage), then
/// the defender's BLOCK roll (a block => landed but 0 damage), then roll + mitigate the physical
/// component AND any elemental component, each reduced by the target's matching resist. RNG order
/// matches the engine: hit roll first, block roll second, physical damage roll third, elemental
/// roll fourth — so (attacker, defender, seed, params) fully determines the outcome. Does NOT
/// mutate the defender; call `applyToLife` to subtract `.damage`.
///
/// This is the single path BOTH player->monster and monster->player attacks route through:
/// physical melee now rolls to-hit + block (not auto-hit), and elemental riders are resisted the
/// same way spells are (spell.applyResist). See applyDamageComponent / applyPhysicalFor.
/// On-hit ELEMENTAL damage carried by the attacker's stats (firemindam/maxdam, coldmindam/maxdam,
/// lightmindam/maxdam, magicmindam/maxdam) — added to a melee/ranged hit ALONGSIDE the physical, each
/// element rolled uniformly [min,max] and reduced by the defender's matching resist. This is how
/// elemental-damage GEAR and skills like Enchant / Holy Fire / a fire-damage charm actually add their
/// damage to attacks. Poison is a damage-over-time (not summed here). Consumes RNG per rolled element.
pub fn onHitElementalFromStats(attacker: *const Unit, defender: *const Unit, seed: *Seed) i32 {
    const elems = .{
        .{ Stat.firemindam, Stat.firemaxdam, Element.fire },
        .{ Stat.coldmindam, Stat.coldmaxdam, Element.cold },
        .{ Stat.lightmindam, Stat.lightmaxdam, Element.lightning },
        .{ Stat.magicmindam, Stat.magicmaxdam, Element.magic },
    };
    var total: i32 = 0;
    inline for (elems) |e| {
        const mn = attacker.get(e[0]);
        const mx = attacker.get(e[1]);
        if (mx > 0 or mn > 0) {
            const roll: i32 = if (mx > mn) mn + @as(i32, @bitCast(seed.pick(@bitCast(mx - mn + 1)))) else mn;
            total += applyDamageComponent(roll, e[2], defender).applied;
        }
    }
    return total;
}

pub fn resolveAttack(attacker: *const Unit, defender: *const Unit, seed: *Seed, params: DamageParams) AttackResult {
    const ar = getAttackRating(attacker);
    const def = getDefense(defender);
    const chance = chanceToHit(ar, def, attacker.level(), defender.level());
    const hit = rollHit(seed, chance);
    if (!hit) {
        return .{ .hit = false, .chance = chance, .ar = ar, .def = def, .raw_damage = 0, .damage = 0 };
    }

    // Block roll (only when the caller says the defender can block). A block stops all damage.
    if (params.defender_block_factor) |bf| {
        const bc = blockChanceForUnit(defender, bf);
        if (rollBlock(seed, bc)) {
            return .{ .hit = true, .blocked = true, .chance = chance, .ar = ar, .def = def, .raw_damage = 0, .damage = 0 };
        }
    }

    // Physical component (fixed-point <<8), mitigated by applyPhysicalFor (player cap 50, monster
    // uncapped). rollPhysicalDamage consumes one RNG step.
    const phys = rollPhysicalDamage(attacker, seed, params);
    const phys_applied = applyPhysicalFor(phys.rolled256, defender) >> 8;

    // Elemental rider, if any: roll uniformly [min,max], resist via spell.applyResist.
    var elem_applied: i32 = 0;
    if (params.elem_element != .none and params.elem_max > params.elem_min) {
        const span: u32 = @bitCast(params.elem_max - params.elem_min + 1);
        const roll: i32 = params.elem_min + @as(i32, @bitCast(seed.pick(span)));
        const comp = applyDamageComponent(roll, params.elem_element, defender);
        elem_applied = comp.applied;
    } else if (params.elem_element != .none and params.elem_max == params.elem_min and params.elem_min > 0) {
        const comp = applyDamageComponent(params.elem_min, params.elem_element, defender);
        elem_applied = comp.applied;
    }
    // Plus the attacker's own on-hit elemental damage stats (gear + Enchant/Holy Fire/etc.).
    elem_applied += onHitElementalFromStats(attacker, defender, seed);

    return .{
        .hit = true,
        .blocked = false,
        .chance = chance,
        .ar = ar,
        .def = def,
        .raw_damage = phys.whole(),
        .damage = phys_applied + elem_applied,
        .elem_damage = elem_applied,
        .elem_element = params.elem_element,
    };
}

/// Subtract a whole damage value from a unit's hitpoints(6), floored at 0.
/// Life/mana STOLEN from a physical hit: `damage * leech_pct / 100`, then DIVIDED by the difficulty
/// steal divisor (Normal 1 / Nightmare 2 / Hell 3 — see sim.difficulty.lifeStealDivisor). D2 leech is
/// off the PHYSICAL damage dealt; the divisor is why life/mana leech is weak in Nightmare/Hell.
pub fn leech(damage: i32, leech_pct: i32, divisor: i32) i32 {
    if (leech_pct <= 0 or divisor <= 0 or damage <= 0) return 0;
    return @intCast(@divTrunc(@divTrunc(@as(i64, damage) * leech_pct, 100), divisor));
}

pub fn applyToLife(u: *Unit, damage: i32) void {
    var hp = u.life() - damage;
    if (hp < 0) hp = 0;
    u.setLife(hp);
}

/// Resolve an attack and, on a hit, subtract the rolled damage from the defender's life —
/// the ubiquitous resolveAttack + applyToLife pair (monster swings, the melee arm of a
/// skill). Returns the AttackResult so the host can emit the resulting S->C packets. Pure:
/// mutates only the defender's life; the host owns everything else.
pub fn attackAndApply(attacker: *const Unit, defender: *Unit, seed: *Seed, params: DamageParams) AttackResult {
    const res = resolveAttack(attacker, defender, seed, params);
    if (res.hit) applyToLife(defender, res.damage);
    return res;
}

// ---------------------------------------------------------------------------
// Monster -> player attack  (MonLvl-scaled A1/A2 damage through the unified model)
// ---------------------------------------------------------------------------

/// A monster's per-attack combat stats for one swing: the MonLvl-scaled attack rating and
/// physical damage range (montable.ScaledCombat's A1 or A2 fields). `min == max == 0` is a
/// non-attack (the monster has no such attack). The monster's own level drives the to-hit.
pub const MonsterAttack = struct {
    attack_rating: i32,
    min_damage: i32,
    max_damage: i32,
    monster_level: i32,
};

/// Write a monster's MonLvl-scaled COMBAT stats onto its Unit's stat list (MONSTER_InitStats path,
/// same 0x6538a0 scaling that produced `sc`): defense (armorclass), A1 attack rating (tohit) and A1
/// physical min/max damage. The host does the montable.scaled lookup + monster-level assignment; this
/// folds the result onto the unit so resolveMonsterAttack (via monsterAttackFrom) and the to-hit roll
/// read them back. HP/resists/regen are seeded by the host on their own faithful paths.
pub fn initMonsterStats(u: *Unit, sc: montable.ScaledCombat) void {
    u.set(.armorclass, sc.armor_class);
    u.set(.tohit, sc.attack_rating_a1);
    u.set(.mindamage, sc.a1_min);
    u.set(.maxdamage, sc.a1_max);
}

/// Read a monster's A1 attack off its Unit's stat list into a MonsterAttack (the swing
/// resolveMonsterAttack resolves): its tohit as the attack rating, mindamage/maxdamage as the
/// physical range, and its level as the attacker level. The inverse of `initMonsterStats`.
pub fn monsterAttackFrom(u: *const Unit) MonsterAttack {
    return .{
        .attack_rating = u.get(.tohit),
        .min_damage = u.get(.mindamage),
        .max_damage = u.get(.maxdamage),
        .monster_level = u.level(),
    };
}

/// Resolve a MONSTER's swing at a player through the SAME unified model (to-hit, player block,
/// physical mitigation via the player's defense/DR/damageresist). The monster's attack rating
/// and damage are the MonLvl-scaled A1/A2 values (from montable.scaled); the to-hit uses the
/// monster's level as the attacker level. RNG order: hit roll, block roll, damage roll — the
/// player's block uses BLOCK_FACTOR (its class base block) when it has a shield.
///
/// `player_block_factor` = the player's CharStats BlockFactor (combat.BLOCK_FACTOR) when it can
/// block, else null to skip blocking. Physical damage is the monster's flat min..max range (no
/// str/dex/ED — monster damage is already fully MonLvl-scaled). Pure: caller applies `.damage`.
pub fn resolveMonsterAttack(atk: MonsterAttack, defender: *const Unit, seed: *Seed, player_block_factor: ?i32) AttackResult {
    const def = getDefense(defender);
    const chance = chanceToHit(atk.attack_rating, def, atk.monster_level, defender.level());
    const hit = rollHit(seed, chance);
    if (!hit) {
        return .{ .hit = false, .chance = chance, .ar = atk.attack_rating, .def = def, .raw_damage = 0, .damage = 0 };
    }
    if (player_block_factor) |bf| {
        const bc = blockChanceForUnit(defender, bf);
        if (rollBlock(seed, bc)) {
            return .{ .hit = true, .blocked = true, .chance = chance, .ar = atk.attack_rating, .def = def, .raw_damage = 0, .damage = 0 };
        }
    }
    // Monster damage: flat min..max (already MonLvl-scaled), then the player's physical mitigation.
    var min256 = atk.min_damage << 8;
    var max256 = atk.max_damage << 8;
    if (min256 < 1) min256 = 256;
    if (max256 <= min256) max256 = min256 + 256;
    const range = max256 - min256;
    const rolled = if (range > 0) min256 + @as(i32, @bitCast(seed.pick(@bitCast(range)))) else min256;
    const applied = applyPhysicalFor(rolled, defender) >> 8;
    return .{
        .hit = true,
        .blocked = false,
        .chance = chance,
        .ar = atk.attack_rating,
        .def = def,
        .raw_damage = rolled >> 8,
        .damage = applied,
    };
}

test "initMonsterStats writes AC/AR/damage onto the unit; monsterAttackFrom reads them back" {
    const testing = std.testing;
    var u = Unit.init(.monster);
    u.set(.level, 42);
    const sc = montable.ScaledCombat{
        .armor_class = 1500,
        .attack_rating_a1 = 3200,
        .attack_rating_a2 = 0,
        .a1_min = 40,
        .a1_max = 90,
        .a2_min = 0,
        .a2_max = 0,
        .to_block = 0,
        .resist = .{},
    };
    initMonsterStats(&u, sc);
    try testing.expectEqual(@as(i32, 1500), u.get(.armorclass));
    try testing.expectEqual(@as(i32, 3200), u.get(.tohit));
    try testing.expectEqual(@as(i32, 40), u.get(.mindamage));
    try testing.expectEqual(@as(i32, 90), u.get(.maxdamage));

    const atk = monsterAttackFrom(&u);
    try testing.expectEqual(@as(i32, 3200), atk.attack_rating);
    try testing.expectEqual(@as(i32, 40), atk.min_damage);
    try testing.expectEqual(@as(i32, 90), atk.max_damage);
    try testing.expectEqual(@as(i32, 42), atk.monster_level);
}

test "attackAndApply subtracts rolled damage on a hit, leaves life untouched on a miss" {
    const testing = std.testing;
    var attacker = Unit.init(.player);
    attacker.set(.level, 30);
    attacker.set(.dexterity, 120);
    attacker.set(.tohit, 5000);
    attacker.weapon = .{ .min_damage = 20, .max_damage = 60 };
    var defender = Unit.init(.monster);
    defender.set(.level, 1);
    defender.setLife(1000);

    var seed = Seed.fromValue(0xC0FFEE);
    const before = defender.life();
    const res = attackAndApply(&attacker, &defender, &seed, .{});
    // Post-condition holds regardless of the RNG outcome: on a hit the defender's life
    // dropped by exactly the rolled damage (clamped at 0); on a miss nothing changed.
    if (res.hit) {
        try testing.expect(res.damage > 0);
        try testing.expectEqual(@max(@as(i32, 0), before - res.damage), defender.life());
    } else {
        try testing.expectEqual(before, defender.life());
    }
}

test "attackAndApply clamps a lethal blow to zero life, never negative" {
    const testing = std.testing;
    var attacker = Unit.init(.player);
    attacker.set(.level, 30);
    attacker.set(.dexterity, 120);
    attacker.set(.tohit, 100000);
    attacker.weapon = .{ .min_damage = 500, .max_damage = 900 };
    var defender = Unit.init(.monster);
    defender.set(.level, 1);
    defender.setLife(5);

    var seed = Seed.fromValue(0xBADF00D);
    const res = attackAndApply(&attacker, &defender, &seed, .{});
    try testing.expect(defender.life() >= 0);
    if (res.hit) try testing.expectEqual(@as(i32, 0), defender.life());
}

test "on-hit elemental from stats adds to a physical hit (Enchant fire damage)" {
    const testing = std.testing;
    var attacker = Unit.init(.player);
    attacker.set(.level, 30);
    attacker.set(.dexterity, 200);
    attacker.set(.tohit, 100000);
    attacker.weapon = .{ .min_damage = 10, .max_damage = 10 };
    var bare = Unit.init(.monster);
    bare.set(.level, 1);
    bare.setLife(100000);

    var s1 = Seed.fromValue(0xE7);
    const phys_only = resolveAttack(&attacker, &bare, &s1, .{});

    // Enchant-style +fire damage on the attacker; the defender has 0 fire resist.
    attacker.set(.firemindam, 200);
    attacker.set(.firemaxdam, 200);
    var s2 = Seed.fromValue(0xE7);
    const with_fire = resolveAttack(&attacker, &bare, &s2, .{});
    try testing.expect(with_fire.hit and phys_only.hit);
    try testing.expectEqual(@as(i32, 200), with_fire.elem_damage); // 200 fire, 0 resist
    try testing.expect(with_fire.damage > phys_only.damage); // total went up by the fire
}

test "leech divides by the difficulty steal divisor (Hell is 1/3)" {
    const testing = std.testing;
    const difficulty = @import("difficulty.zig");
    // 10% life steal off 300 physical = 30 in Normal, 15 in NM, 10 in Hell.
    try testing.expectEqual(@as(i32, 30), leech(300, 10, difficulty.lifeStealDivisor(.normal)));
    try testing.expectEqual(@as(i32, 15), leech(300, 10, difficulty.lifeStealDivisor(.nightmare)));
    try testing.expectEqual(@as(i32, 10), leech(300, 10, difficulty.lifeStealDivisor(.hell)));
    try testing.expectEqual(@as(i32, 0), leech(300, 0, 1)); // no leech stat -> nothing
}
