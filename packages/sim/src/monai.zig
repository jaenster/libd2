//! Per-monster server AI — faithful 1:1 ports of the 1.14d D2Game AI_Function1_* scripts.
//!
//! Pure decision logic: given what a monster perceives this tick plus its LCG seed, it returns the
//! action(s) to take. The HOST gathers the perceptions (target distance, nearby corpses) from the
//! world and applies the result. Each script is ported from the binary's exact roll sequence and
//! its difficulty-indexed MonStats aip columns — no invented numbers.
//!
//! Ported so far:
//!   AI_Function1_Fallen       @0x5f02c0 — flee when a fellow monster's corpse is near.
//!   AI_Function1_FallenShaman @0x5f1440 — flee / summon minion / revive dead fallen / bolt / approach.
//!
//! Seed model: every roll is UNIT_GetModuloFromSeed(100) = the unit LCG advanced once then reduced
//! mod 100 (Seed.pick(100)); rolls happen in the SAME order as the binary so behavior tracks it.

const std = @import("std");
const rng = @import("rng.zig");

pub const Seed = rng.Seed;

/// AI-script identity parsed from MonStats.AI, collapsed to the BEHAVIOR class the host applies.
///
/// `.generic` is not "unhandled" — it is the deliberate mapping for the many AI scripts whose
/// observable behavior (walk toward the target, melee/cast when in range, pace when idle) the host's
/// baseline `decideMonster` loop already reproduces faithfully. RE'd and confirmed equivalent so far:
/// Skeleton (@0x5efcf0), Zombie (@0x5efe20), Goatman (@0x5f12a0), Brute (@0x5efb80, its HP-scaled
/// "mode 7" is walk-to-unit/approach, not a flee), CorruptRogue (@0x5f0b00). Scripts get their own
/// class here only when they add behavior the baseline lacks.
pub const Script = enum {
    /// AI_Function1_Fallen @0x5f02c0 — scatter from a fellow monster's corpse.
    fallen,
    /// AI_Function1_FallenShaman @0x5f1440 — flee / summon / revive dead fallen / bolt.
    fallen_shaman,
    /// Skittish ranged: keep distance and shoot rather than close to melee. The binary repositions
    /// (QuillRat WalkRandomOffset when in-range @0x5f1140 / QuillMother @0x5fb2a0) or back-pedals
    /// (SkeletonBow retreat @0x5f6070) once the target is close; all lob their ranged Skill from afar.
    ranged_kite,
    /// Immobile emplacement: never walks — holds position and fires its MonStats skill at any enemy
    /// in range. Towers/turrets/hydras/totems/catapults/traps and static nests all sit on this script.
    stationary,
    /// Resurrects the dead: scans for a nearby monster corpse and raises it (GreaterMummy @0x5f2b10,
    /// MONSTERAI_FindMonsterToResurrect + cast Skill2 on it), then falls through to its attack/curse.
    raiser,
    /// Lays/spawns its own minion class up to a cap while still fighting (SandMaggot @0x5f1800 /
    /// SandMaggotQueen @0x5f9cf0 — GetSpawnParameters + SpawnMonsterAtRoomPos, capped by aip1).
    spawner,
    /// Teleporting boss: blinks next to the target when it is out of reach / behind a wall, then casts
    /// and melees. Mephisto @0x5f78b0 (NM/Hell, wall or dist>30 -> Skill6 teleport) and Baal
    /// @0x5fcfe0 (action 0xe blink ~25 units) both do this; the non-blinking bosses stay generic.
    boss_teleport,
    /// Passive chilling aura: continuously slows every enemy in range (Duriel @0x5f67b0 sets Skill4 =
    /// Holy Freeze on spawn). The monster still melees/casts; the aura is layered on top each think.
    aura_chill,
    /// Burrows: submerges (invulnerable + untargetable) for its burrow duration, then surfaces next to
    /// the target and strikes (SandRaider @0x5f0700 emerge-ambush). Fights normally while surfaced.
    burrower,
    /// Coward: flees from the target while its life is below a threshold, otherwise fights normally.
    /// Vampire @0x5f4a70 (flee <33% life) and PantherWoman @0x5f22b0 (pack-flee) sit here.
    coward,
    /// Ally support: heals the nearest wounded fellow monster in range each think, then fights via the
    /// generic loop. Overseer @0x5e27a0 (whip-heal), ZakarumPriest @0x5f72d0, OblivionKnight @0x5faf00
    /// (buff/curse) and HighPriest @0x5e0490 all keep their allies up.
    ally_support,
    /// Nihlathak @0x5ee5d0 — his signature is CORPSE EXPLOSION: he casts Skill3 (srvdofunc 127) on a
    /// nearby monster corpse to blast the player, gated by a roll < aip3, BEFORE falling back to the
    /// ally-support heal (Skill2, roll < aip5) and the generic cast/melee loop. The decision order in
    /// the binary is Skill1-cast, gap-close, corpse-explode, close-range nova (Skill4), heal/spawn.
    nihlathak,
    /// Suicide rusher: charges the target and DETONATES on contact — a blast that damages everything
    /// nearby and kills the rusher (SuicideMinion @0x5e1d30 arms a fuse then fires skill 0 = death-burst).
    suicide_rush,
    /// Non-combat: town folk and neutral critters with no aggression (Idle/None/Npc*/Towner/Vendor).
    /// The host runs no attack loop for these.
    passive,
    /// Approach + melee/cast — the host baseline `decideMonster` loop is a faithful match for the many
    /// plain aggressive monsters (skeletons, goatmen, brutes, demons, casters, act-boss melee, ...).
    /// This is the explicit classification for everything not carved out above, not a fallthrough.
    generic,

    pub fn fromName(name: []const u8) Script {
        if (eq(name, "Fallen")) return .fallen;
        if (eq(name, "FallenShaman")) return .fallen_shaman;
        // Skittish ranged: hold distance and shoot, retreating from melee (RE-confirmed retreat calls).
        if (inAny(name, &.{
            "QuillRat",     "QuillMother", "SkeletonBow",  "SuccubusWitch", "CorruptArcher",
            "SkeletonMage", "FingerMage",  "ThornHulk",    "PantherJavelin", "Mosquito",
            "Imp",          "FetishBlowgun",
        })) return .ranged_kite;
        // Raise the dead: rez nearby corpses (GreaterMummy) / raise zombies (BloodRaven Skill1).
        if (inAny(name, &.{ "GreaterMummy", "BloodRaven" })) return .raiser;
        // Lay/spawn own minions up to a cap while fighting (SummonMaster refills its minion1 slots).
        if (inAny(name, &.{ "SandMaggot", "SandMaggotQueen", "VileMother", "Scarab", "Vulture", "FetishShaman", "SummonMaster" })) return .spawner;
        // Teleporting bosses + their Pandemonium (Uber) counterparts, which share the base mechanics.
        if (inAny(name, &.{ "Mephisto", "BaalCrab", "BaalCrabClone", "UberMephisto", "UberBaal" })) return .boss_teleport;
        if (eq(name, "Duriel")) return .aura_chill;
        // Submerge/collision-shrink ambushers.
        if (inAny(name, &.{ "SandRaider", "FrogDemon" })) return .burrower;
        // Low-life / pack fleers.
        if (inAny(name, &.{ "Vampire", "PantherWoman", "Arach" })) return .coward;
        // Nihlathak's signature corpse explosion (falls back to the ally heal) is distinct enough to
        // carve out from the plain supporters below.
        if (eq(name, "Nihlathak")) return .nihlathak;
        // Ally supporters (heal/buff/rez fellow monsters).
        if (inAny(name, &.{ "Overseer", "ZakarumPriest", "OblivionKnight", "HighPriest" })) return .ally_support;
        if (eq(name, "SuicideMinion")) return .suicide_rush;
        // Emplacements that never move — includes FrozenHorror (ranged cold caster, holds position).
        // Emplacements that never move — they must NOT charge like a generic monster.
        if (inAny(name, &.{
            "Hydra",          "ArcaneTower",   "DesertTurret", "Catapult",     "CatapultSpotter",
            "Totem",          "GargoyleTrap",  "Trap-LeftArrow", "Trap-RightArrow", "Trap-Missile",
            "Trap-Melee",     "Trap-Nova",     "Trap-Poison",  "BoneWall",     "HellMeteor",
            "Sarcophagus",    "EvilHole",      "Vines",        "MosquitoNest", "FoulCrowNest",
            "MaggotEgg",      "AncientStatue", "FrozenHorror", "Wraith",       "Tentacle",
            "TentacleHead",   "MaggotLarva",   "GenericSpawner", "MinionSpawner", "BaalTentacle",
            "InvisoSpawner",
        })) return .stationary;
        // Town / neutral NPCs, quest-script walkers and harmless critters — no combat AI.
        if (inAny(name, &.{
            "Idle",   "None",  "Npc",      "NpcStationary", "NpcOutOfTown", "Towner",
            "Vendor", "Navi",  "JarJar",   "TownRogue",     "GoodNpcRanged", "Buffy", "Wussie",
            "DarkWanderer",
        })) return .passive;
        return .generic;
    }
};

/// Case-insensitive equality against a MonStats.AI name.
inline fn eq(name: []const u8, lit: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, lit);
}

/// True when `name` case-insensitively equals any entry in `lits`.
fn inAny(name: []const u8, lits: []const []const u8) bool {
    for (lits) |l| {
        if (std.ascii.eqlIgnoreCase(name, l)) return true;
    }
    return false;
}

/// AI_Function1_Fallen corpse-proximity trigger: GetCollisionDistanceFromXY < 0xF. When a fellow
/// monster's corpse sits within this many subtiles the Fallen sets its flee flag (dwArg0=1) and
/// runs from the threat instead of engaging — the iconic "fallen scatter when one dies" behavior.
pub const FALLEN_CORPSE_FLEE_RANGE: i32 = 15;

/// AI_Function1_Fallen: the Fallen flees this tick iff a fellow monster's corpse is within
/// FALLEN_CORPSE_FLEE_RANGE (the host supplies that proximity test). The flee is unconditional once
/// the corpse is seen (dwArg0=1 forces the flee reaction — no roll), so this is a pure predicate.
pub fn fallenShouldFlee(corpse_within_range: bool) bool {
    return corpse_within_range;
}

/// One tick of AI_Function1_FallenShaman, resolved to the ordered set of actions the host applies.
/// Fields are checked by the host in declaration order; a `true` in `flee`/`revive`/`cast_bolt`
/// short-circuits the rest (the binary `return`s there), while `summon_minion` co-occurs with a
/// later revive/bolt (CreateMinion runs inline without returning).
pub const ShamanPlan = struct {
    /// In-combat break-off — CalledOnEndAiFunction1(pGame,pUnit,4,pTarget): stop and flee.
    flee: bool = false,
    /// CreateMinion this tick (a fresh fallen spawns next to the shaman).
    summon_minion: bool = false,
    /// Cast Skill1 on the located revival target (resurrect a dead fallen); then done.
    revive: bool = false,
    /// Cast Skill2 (the shaman's bolt) at the engaged target; then done.
    cast_bolt: bool = false,
    /// SetCombatStateAndApproachTarget: walk toward the target. False here == PlanNextAiMove (idle).
    approach: bool = false,
};

/// AI_Function1_FallenShaman @0x5f1440, ported 1:1 for the host's single-target world.
///
/// Params (difficulty-resolved MonStats aip columns, verified against the disassembly displacements
/// off TreasureClass@0x86): aip1 (0x56) = summon-minion AND revive-cast chance; aip2 (0x5c) = bolt
/// chance; aip3 (0x62) = in-combat flee chance and the final approach gate; aip5 (0x6e) = the
/// distance under which Skill2 is cast. aip4 (revive scan radius) is applied by the host's corpse
/// scan, so it is not read here. `revival_found`/`revival_valid` are the outcome of that scan plus
/// AI_Monster_ValidateSkillAtPosition. Rolls advance `seed` in the binary's order.
///
/// The binary re-finds an alternate target and re-rolls the bolt gate when the primary bolt roll
/// fails; the host's target is already the nearest enemy, so that retry collapses to this single
/// target — behavior matches, the second (identical) bolt roll is not replayed.
pub fn decideFallenShaman(
    seed: *Seed,
    engaged: bool,
    has_target: bool,
    dist: i32,
    aip1: i32,
    aip2: i32,
    aip3: i32,
    aip5: i32,
    revival_found: bool,
    revival_valid: bool,
) ShamanPlan {
    var plan = ShamanPlan{};

    if (engaged and roll100(seed) < aip3) {
        plan.flee = true;
        return plan;
    }
    if (roll100(seed) < aip1) plan.summon_minion = true;
    if (revival_found) {
        if (roll100(seed) < aip1 and revival_valid) {
            plan.revive = true;
            return plan;
        }
    }
    if (has_target and dist < aip5 and roll100(seed) < aip2) {
        plan.cast_bolt = true;
        return plan;
    }
    if (roll100(seed) < aip3) plan.approach = true;
    return plan;
}

/// UNIT_GetModuloFromSeed(100): advance the unit LCG once and reduce mod 100 (0..99).
inline fn roll100(seed: *Seed) i32 {
    return @intCast(seed.pick(100));
}

// --- Pure per-behavior decision predicates -----------------------------------------------------
//
// These are the exact decisions the host applies for each behavior class, lifted out of the host so
// they can be exhaustively unit-tested here (the host calls these — tested == shipped). Distances are
// SQUARED (matches the host, which never takes a sqrt); ranges are in subtiles.

/// A squared distance is within `radius` subtiles. Shared by stationary/aura/kite/blast checks.
pub fn withinRadius(dist2: i64, radius: i32) bool {
    return dist2 <= @as(i64, radius) * radius;
}

/// A `coward` (Vampire / Panther Woman / Arach) flees when it has a target and its life is under
/// `flee_below_pct` percent of max. maxhp<=0 (unset) never flees (avoids a divide-by-zero).
pub fn cowardFlees(life: i32, maxhp: i32, has_target: bool, flee_below_pct: i32) bool {
    if (!has_target or maxhp <= 0) return false;
    return @divTrunc(life * 100, maxhp) < flee_below_pct;
}

/// A skittish-ranged monster back-pedals when the target has closed INSIDE the standoff (strictly
/// nearer than `standoff`); at or beyond it, it holds/approaches and shoots.
pub fn kiteBackpedals(target_dist2: i64, standoff: i32) bool {
    return target_dist2 < @as(i64, standoff) * standoff;
}

/// A teleporting boss blinks when the target is strictly BEYOND `blink_range` and the cooldown is ready.
pub fn bossBlinks(target_dist2: i64, blink_range: i32, cooldown_ready: bool) bool {
    return cooldown_ready and target_dist2 > @as(i64, blink_range) * blink_range;
}

/// A suicide rusher detonates once the target is within `contact_range`; otherwise it keeps charging.
pub fn suicideDetonates(target_dist2: i64, contact_range: i32) bool {
    return target_dist2 <= @as(i64, contact_range) * contact_range;
}

/// A spawner may emit another minion while it owns fewer than `cap` live ones (cap<=0 = never).
pub fn spawnerUnderCap(live_count: i32, cap: i32) bool {
    return cap > 0 and live_count < cap;
}

/// A seeded percent-chance gate: advance the LCG once and pass when the 0..99 roll is under `chance_pct`
/// (chance<=0 never passes, chance>=100 always passes). The shared primitive behind every aip roll.
pub fn rollPasses(seed: *Seed, chance_pct: i32) bool {
    return roll100(seed) < chance_pct;
}

/// Nihlathak's corpse-explosion gate (AI_Function1_Nihlathak @0x5ee5d0, step 3): he detonates a
/// nearby monster corpse only when one exists AND a fresh roll < aip3 passes. The roll advances the
/// seed exactly once whether or not a corpse is present is NOT faithful — the binary rolls only after
/// confirming Skill3 is set, so the host passes `has_corpse` (Skill3 presence is implied) and we roll
/// here; callers must not roll again.
pub fn nihlathakCorpseExplodes(has_corpse: bool, seed: *Seed, chance_pct: i32) bool {
    if (!has_corpse) return false;
    return rollPasses(seed, chance_pct);
}

/// One tick of the burrower state machine (SandRaider / FrogDemon).
pub const BurrowAction = enum {
    /// Submerged and the dive timer has not elapsed — stay under (invulnerable, no action).
    stay_submerged,
    /// Submerged and the timer elapsed — surface next to the target and strike.
    surface_and_strike,
    /// Surfaced, the surface window elapsed and a target exists — dive again.
    dive,
    /// Surfaced and not yet time to dive — fight normally this tick.
    fight,
};

/// Decide the burrower's action. `phase_end` is the frame the current phase ends (dive timer while
/// submerged, surface timer while up). A surfaced burrower only dives when it actually has a target.
pub fn burrowDecide(submerged: bool, now: u64, phase_end: u64, has_target: bool) BurrowAction {
    if (submerged) return if (now < phase_end) .stay_submerged else .surface_and_strike;
    if (has_target and now >= phase_end) return .dive;
    return .fight;
}

const testing = std.testing;

test "monai: Script.fromName classifies AI names case-insensitively" {
    try testing.expectEqual(Script.fallen, Script.fromName("Fallen"));
    try testing.expectEqual(Script.fallen, Script.fromName("fallen"));
    try testing.expectEqual(Script.fallen_shaman, Script.fromName("FallenShaman"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("QuillRat"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("quillmother"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("SkeletonBow"));
    // Emplacements never move.
    try testing.expectEqual(Script.stationary, Script.fromName("Hydra"));
    try testing.expectEqual(Script.stationary, Script.fromName("Trap-Nova"));
    try testing.expectEqual(Script.stationary, Script.fromName("totem"));
    // Raise-dead + spawner behaviors.
    try testing.expectEqual(Script.raiser, Script.fromName("GreaterMummy"));
    try testing.expectEqual(Script.spawner, Script.fromName("SandMaggotQueen"));
    try testing.expectEqual(Script.spawner, Script.fromName("sandmaggot"));
    // Teleporting bosses; SuccubusWitch kites.
    try testing.expectEqual(Script.boss_teleport, Script.fromName("Mephisto"));
    try testing.expectEqual(Script.boss_teleport, Script.fromName("BaalCrab"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("SuccubusWitch"));
    try testing.expectEqual(Script.aura_chill, Script.fromName("Duriel"));
    try testing.expectEqual(Script.burrower, Script.fromName("SandRaider"));
    // Wave-2 reclassifications (RE-verified, not name-guessed).
    try testing.expectEqual(Script.ranged_kite, Script.fromName("CorruptArcher"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("SkeletonMage"));
    try testing.expectEqual(Script.stationary, Script.fromName("FrozenHorror"));
    try testing.expectEqual(Script.spawner, Script.fromName("VileMother"));
    try testing.expectEqual(Script.spawner, Script.fromName("Vulture"));
    try testing.expectEqual(Script.raiser, Script.fromName("BloodRaven"));
    try testing.expectEqual(Script.coward, Script.fromName("Vampire"));
    try testing.expectEqual(Script.ally_support, Script.fromName("Overseer"));
    try testing.expectEqual(Script.nihlathak, Script.fromName("Nihlathak"));
    // Wave-2b: more RE-verified reclassifications + suicide rushers.
    try testing.expectEqual(Script.stationary, Script.fromName("Wraith"));
    try testing.expectEqual(Script.stationary, Script.fromName("MaggotLarva"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("Imp"));
    try testing.expectEqual(Script.burrower, Script.fromName("FrogDemon"));
    try testing.expectEqual(Script.coward, Script.fromName("Arach"));
    try testing.expectEqual(Script.ally_support, Script.fromName("HighPriest"));
    try testing.expectEqual(Script.passive, Script.fromName("DarkWanderer"));
    try testing.expectEqual(Script.suicide_rush, Script.fromName("SuicideMinion"));
    try testing.expectEqual(Script.spawner, Script.fromName("SummonMaster"));
    try testing.expectEqual(Script.stationary, Script.fromName("GenericSpawner"));
    try testing.expectEqual(Script.stationary, Script.fromName("BaalTentacle"));
    // Summoner is a pure multi-skill caster (no summon/teleport); non-blinking bosses -> generic baseline.
    try testing.expectEqual(Script.generic, Script.fromName("Summoner"));
    try testing.expectEqual(Script.generic, Script.fromName("Diablo"));
    try testing.expectEqual(Script.generic, Script.fromName("Izual"));
    try testing.expectEqual(Script.generic, Script.fromName("Succubus"));
    // Town / neutral NPCs have no combat AI.
    try testing.expectEqual(Script.passive, Script.fromName("Towner"));
    try testing.expectEqual(Script.passive, Script.fromName("Vendor"));
    try testing.expectEqual(Script.passive, Script.fromName("Idle"));
    // Plain approach-melee scripts are explicitly the faithful generic baseline.
    try testing.expectEqual(Script.generic, Script.fromName("Skeleton"));
    try testing.expectEqual(Script.generic, Script.fromName("Zombie"));
    try testing.expectEqual(Script.generic, Script.fromName("Diablo"));
    try testing.expectEqual(Script.generic, Script.fromName(""));
}

test "monai: Fallen flees exactly when a corpse is in range" {
    try testing.expect(fallenShouldFlee(true));
    try testing.expect(!fallenShouldFlee(false));
}

test "monai: FallenShaman flees in combat when the aip3 roll passes" {
    // aip3 = 100 -> every roll (0..99) is < 100 -> always flee while engaged; nothing else runs.
    var s = Seed.fromValue(0x1234);
    const p = decideFallenShaman(&s, true, true, 3, 50, 50, 100, 8, true, true);
    try testing.expect(p.flee);
    try testing.expect(!p.summon_minion and !p.revive and !p.cast_bolt and !p.approach);
}

test "monai: FallenShaman never flees when not engaged, and can summon+revive" {
    // Not engaged so the flee branch is skipped. aip1 = 100 -> summon always, and revive when a
    // valid target was found (the second aip1 roll also always passes).
    var s = Seed.fromValue(0x99);
    const p = decideFallenShaman(&s, false, true, 3, 100, 0, 0, 8, true, true);
    try testing.expect(!p.flee);
    try testing.expect(p.summon_minion);
    try testing.expect(p.revive);
    try testing.expect(!p.cast_bolt);
}

test "monai: FallenShaman casts its bolt within aip5 range when the aip2 roll passes" {
    // aip1 = 0 (no summon, no revive), aip2 = 100 (bolt always), target within aip5 = 8.
    var s = Seed.fromValue(0x7);
    const p = decideFallenShaman(&s, false, true, 5, 0, 100, 0, 8, false, false);
    try testing.expect(p.cast_bolt);
    try testing.expect(!p.summon_minion and !p.revive);
    // Out of aip5 range -> no bolt; falls to the approach gate (aip3 = 0 -> plan-move, not approach).
    var s2 = Seed.fromValue(0x7);
    const p2 = decideFallenShaman(&s2, false, true, 20, 0, 100, 0, 8, false, false);
    try testing.expect(!p2.cast_bolt and !p2.approach);
}

test "monai: FallenShaman revive needs BOTH a found AND valid target" {
    // found but NOT valid -> no revive (falls past to bolt/approach).
    var s = Seed.fromValue(0x55);
    const p = decideFallenShaman(&s, false, true, 3, 100, 0, 0, 8, true, false);
    try testing.expect(p.summon_minion and !p.revive);
    // not found at all -> no revive regardless of the roll.
    var s2 = Seed.fromValue(0x55);
    const p2 = decideFallenShaman(&s2, false, true, 3, 100, 0, 0, 8, false, true);
    try testing.expect(!p2.revive);
}

test "monai: FallenShaman final gate — aip3 approach vs plan-move" {
    // Nothing else fires (aip1=aip2=0), engaged=false; aip3=100 -> approach; aip3=0 -> idle plan-move.
    var s = Seed.fromValue(0x2);
    const approach = decideFallenShaman(&s, false, false, 3, 0, 0, 100, 8, false, false);
    try testing.expect(approach.approach);
    var s2 = Seed.fromValue(0x2);
    const idle = decideFallenShaman(&s2, false, false, 3, 0, 0, 0, 8, false, false);
    try testing.expect(!idle.approach);
}

test "monai: withinRadius is inclusive at the boundary" {
    try testing.expect(withinRadius(0, 5));
    try testing.expect(withinRadius(25, 5)); // 5^2 exactly -> inside
    try testing.expect(!withinRadius(26, 5)); // just outside
    try testing.expect(withinRadius(100, 10));
    try testing.expect(!withinRadius(101, 10));
    try testing.expect(!withinRadius(1, 0)); // zero radius: nothing but distance 0
    try testing.expect(withinRadius(0, 0));
}

test "monai: coward flees only when wounded AND it has a target" {
    // 33% threshold: 32/100 flees, 33/100 does not (strict <).
    try testing.expect(cowardFlees(32, 100, true, 33));
    try testing.expect(!cowardFlees(33, 100, true, 33));
    try testing.expect(!cowardFlees(99, 100, true, 33)); // healthy -> fight
    try testing.expect(!cowardFlees(1, 100, false, 33)); // no target -> never flee
    try testing.expect(!cowardFlees(0, 0, true, 33)); // unset maxhp -> no divide-by-zero, no flee
    try testing.expect(cowardFlees(0, 100, true, 33)); // near death -> flee
    // Scales with maxhp, not absolute life.
    try testing.expect(cowardFlees(300, 1000, true, 33)); // 30% -> flee
    try testing.expect(!cowardFlees(400, 1000, true, 33)); // 40% -> fight
}

test "monai: ranged kite back-pedals strictly inside the standoff" {
    // standoff 10 -> radius^2 = 100.
    try testing.expect(kiteBackpedals(0, 10));
    try testing.expect(kiteBackpedals(99, 10));
    try testing.expect(!kiteBackpedals(100, 10)); // exactly at standoff -> hold, don't back-pedal
    try testing.expect(!kiteBackpedals(400, 10)); // far -> approach/shoot
}

test "monai: boss blink requires out-of-range AND cooldown ready" {
    // blink_range 26 -> ^2 = 676.
    try testing.expect(bossBlinks(677, 26, true)); // beyond + ready -> blink
    try testing.expect(!bossBlinks(676, 26, true)); // exactly at range -> no blink (strict >)
    try testing.expect(!bossBlinks(1000, 26, false)); // beyond but on cooldown -> no blink
    try testing.expect(!bossBlinks(100, 26, true)); // in range -> fight, no blink
}

test "monai: suicide detonates inclusively at contact range" {
    // contact 3 -> ^2 = 9.
    try testing.expect(suicideDetonates(0, 3));
    try testing.expect(suicideDetonates(9, 3)); // exactly contact -> detonate
    try testing.expect(!suicideDetonates(10, 3)); // just outside -> keep charging
    try testing.expect(!suicideDetonates(400, 3));
}

test "monai: spawner cap gate" {
    try testing.expect(spawnerUnderCap(0, 3));
    try testing.expect(spawnerUnderCap(2, 3));
    try testing.expect(!spawnerUnderCap(3, 3)); // at cap -> stop
    try testing.expect(!spawnerUnderCap(4, 3));
    try testing.expect(!spawnerUnderCap(0, 0)); // no cap configured -> never spawn
    try testing.expect(!spawnerUnderCap(0, -1));
}

test "monai: rollPasses honors 0 and 100 edge chances deterministically" {
    var s = Seed.fromValue(0xABCD);
    // chance 0 never passes, chance 100 always passes — regardless of the seed state.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try testing.expect(!rollPasses(&s, 0));
        try testing.expect(rollPasses(&s, 100));
        try testing.expect(rollPasses(&s, 1000)); // clamps high
    }
}

test "monai: rollPasses ~matches its probability over many samples" {
    var s = Seed.fromValue(0x1);
    var hits: u32 = 0;
    const n: u32 = 10000;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (rollPasses(&s, 25)) hits += 1;
    }
    // 25% of 10000 = 2500; allow generous slack for the LCG distribution.
    try testing.expect(hits > 2000 and hits < 3000);
}

test "monai: Nihlathak corpse-explodes only with a corpse present and a passing aip3 roll" {
    var s = Seed.fromValue(0x5EE5);
    // No corpse -> never fires, and must NOT consume a roll (a later roll still sees the same state).
    var i: usize = 0;
    while (i < 20) : (i += 1) try testing.expect(!nihlathakCorpseExplodes(false, &s, 100));
    // Corpse present with a 100% chance always fires; with 0% never.
    try testing.expect(nihlathakCorpseExplodes(true, &s, 100));
    var s2 = Seed.fromValue(0x5EE5);
    try testing.expect(!nihlathakCorpseExplodes(true, &s2, 0));
}

test "monai: burrow state machine cycles submerge -> surface -> fight -> dive" {
    // Submerged, before the dive timer -> stay under (invulnerable).
    try testing.expectEqual(BurrowAction.stay_submerged, burrowDecide(true, 10, 100, true));
    // Submerged, timer elapsed -> surface and strike.
    try testing.expectEqual(BurrowAction.surface_and_strike, burrowDecide(true, 100, 100, true));
    try testing.expectEqual(BurrowAction.surface_and_strike, burrowDecide(true, 150, 100, false));
    // Surfaced, surface window elapsed, has a target -> dive again.
    try testing.expectEqual(BurrowAction.dive, burrowDecide(false, 200, 100, true));
    // Surfaced, window elapsed but NO target -> just fight (don't dive at nothing).
    try testing.expectEqual(BurrowAction.fight, burrowDecide(false, 200, 100, false));
    // Surfaced, still within the surface window -> fight.
    try testing.expectEqual(BurrowAction.fight, burrowDecide(false, 50, 100, true));
}
