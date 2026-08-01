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
    /// Approach + melee/cast — the host baseline is faithful; see the type doc for the RE'd list.
    generic,

    pub fn fromName(name: []const u8) Script {
        if (std.ascii.eqlIgnoreCase(name, "Fallen")) return .fallen;
        if (std.ascii.eqlIgnoreCase(name, "FallenShaman")) return .fallen_shaman;
        if (std.ascii.eqlIgnoreCase(name, "QuillRat")) return .ranged_kite;
        if (std.ascii.eqlIgnoreCase(name, "QuillMother")) return .ranged_kite;
        if (std.ascii.eqlIgnoreCase(name, "SkeletonBow")) return .ranged_kite;
        return .generic;
    }
};

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

const testing = std.testing;

test "monai: Script.fromName classifies AI names case-insensitively" {
    try testing.expectEqual(Script.fallen, Script.fromName("Fallen"));
    try testing.expectEqual(Script.fallen, Script.fromName("fallen"));
    try testing.expectEqual(Script.fallen_shaman, Script.fromName("FallenShaman"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("QuillRat"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("quillmother"));
    try testing.expectEqual(Script.ranged_kite, Script.fromName("SkeletonBow"));
    // Plain approach-melee scripts intentionally fall to the faithful generic baseline.
    try testing.expectEqual(Script.generic, Script.fromName("Skeleton"));
    try testing.expectEqual(Script.generic, Script.fromName("Zombie"));
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
