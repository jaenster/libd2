//! Baal's weighted combat-action selection — faithful port of AI_Baal_SelectActionWeighted @0x5fc450
//! (the wall/worldstone-chamber chooser; the throne-room chooser @0x5fc300 and clone chooser @0x5fc1c0
//! share the same weighted-random core @0x5fc130). Every think the engine builds a 16-entry weight array
//! on the stack (NO static table), rolls the TARGET unit's seed against the running total, and walks the
//! cumulative weights to pick the action. This module reproduces that weight computation + roll so the
//! host drives Baal with the binary's real action mix (blink ~20/total, clones early, mostly casting)
//! instead of a fixed round-robin.
//!
//! Weights (base = NM/Hell; Normal raises the Maul base 100->125 and lowers cold 60->40):
//!   [1] Maul (Skill1)        100 + (100 - target_life%)   — primary strike, boosted as the target bleeds
//!   [2][3][4] Skill2/3/4      5 each
//!   [5] cond (target visible) 60 when visible, else 0
//!   [6] ranged               5 (-> 15 when dist > 35)
//!   [8][9] Skill6/7          40 each
//!   [0xb] BaalNova           70 (-> 0 when dist > 25)
//!   [0xc] BaalInferno        80
//!   [0xd] BaalColdMissiles   60 NM/Hell, 40 Normal (-> 0 when dist > 35)
//!   [0xe] Teleport           20 (+30 when dist > 25)
//!   [0xf] Clone spawn        (2 - clones_spawned) * 10, clamped >= 0 (zeroed after 2 clones)

const std = @import("std");
const rng = @import("rng.zig");

pub const Seed = rng.Seed;

/// The 16 action slots of Baal's chooser, in weight-array index order.
pub const Action = enum(u8) {
    idle = 0,
    maul = 1,
    skill2 = 2,
    skill3 = 3,
    skill4 = 4,
    cond5 = 5,
    ranged = 6,
    cond7 = 7,
    skill6 = 8,
    skill7 = 9,
    unused_a = 10,
    nova = 11,
    inferno = 12,
    cold = 13,
    teleport = 14,
    clone = 15,
};

pub const NUM_ACTIONS = 16;

/// Perceptions the weight computation reads at think-time.
pub const Context = struct {
    /// Target life as a 0..100 percentage of its max (drives the Maul boost).
    target_life_pct: i32,
    /// Distance to the target (same units the engine compares against 25 / 35).
    dist: i32,
    /// How many clones Baal has already spawned this fight (caps the clone weight at 2).
    clones_spawned: i32,
    /// Whether the target is currently visible (nParam4 != 0 — enables slot 5).
    target_visible: bool,
    /// Normal difficulty raises the Maul base and lowers the cold-missile weight.
    normal_difficulty: bool,
};

/// Build the 16-entry weight array for this think (AI_Baal_SelectActionWeighted @0x5fc450).
pub fn actionWeights(ctx: Context) [NUM_ACTIONS]i32 {
    var w = [_]i32{0} ** NUM_ACTIONS;
    const life = std.math.clamp(ctx.target_life_pct, 0, 100);
    const maul_base: i32 = if (ctx.normal_difficulty) 125 else 100;
    w[1] = maul_base + (100 - life);
    w[2] = 5;
    w[3] = 5;
    w[4] = 5;
    if (ctx.target_visible) w[5] = 60;
    w[6] = 5;
    w[8] = 40;
    w[9] = 40;
    w[11] = 70; // BaalNova
    w[12] = 80; // BaalInferno
    w[13] = if (ctx.normal_difficulty) 40 else 60; // BaalColdMissiles
    w[14] = 20; // Teleport
    w[15] = @max(0, (2 - ctx.clones_spawned) * 10); // Clone spawn (zeroed after 2)

    // Distance modifiers, applied after the base weights.
    if (ctx.dist > 25) {
        w[14] += 30; // teleport in from afar
        w[11] = 0; // nova only up close
    }
    if (ctx.dist > 35) {
        w[6] = 15; // favor the ranged skill at long range
        w[13] = 0; // cold missiles drop out
    }
    return w;
}

/// Roll the weighted action (AI_BAAL_SelectWeightedAction @0x5fc130): advance `seed` once, reduce it
/// modulo the total weight, and walk the cumulative weights returning the first slot the roll falls in.
/// Faithful to the engine's `roll < accum` scan; the power-of-two `& (total-1)` fast path the binary uses
/// equals `% total` for those totals, so Seed.pick (which reduces mod the modulus) matches either way.
/// Falls back to `.maul` (slot 1) when every weight is zero, as the binary does.
pub fn selectAction(ctx: Context, seed: *Seed) Action {
    const w = actionWeights(ctx);
    var total: i32 = 0;
    for (w) |x| total += x;
    if (total <= 0) return .maul;
    const roll: i32 = @intCast(seed.pick(@intCast(total)));
    var accum: i32 = 0;
    for (w, 0..) |x, i| {
        accum += x;
        if (roll < accum) return @enumFromInt(@as(u8, @intCast(i)));
    }
    return .maul;
}

/// Baal's Throne-of-Destruction minion waves (AI_Function1_BaalThrone @0x5ef320). Five superunique
/// wave bosses (BAALWAVES_UniqueHardcodedIndex @0x6e3528 — "Baal Subject 1-5" = Colenzo / Achmel /
/// Bartuc / Ventar / Lister) spawn one at a time, each only after the previous wave is cleared; after
/// the fifth the throne yields Baal himself (the engine transforms the throne entity to BaalCrab).
pub const NUM_WAVES = 5;

/// What the throne should do this think, given the current wave cursor (0..NUM_WAVES), whether any wave
/// monster is still alive, and whether Baal has spawned.
pub const WaveAction = union(enum) {
    wait, // the current wave is still alive — do nothing
    spawn_wave: u8, // the room is clear — spawn wave N (0-based)
    spawn_baal, // all waves cleared — bring out Baal
    done, // Baal is out; the sequence is finished
};

pub fn nextWaveAction(wave: u8, wave_alive: bool, baal_spawned: bool) WaveAction {
    if (wave_alive) return .wait; // never advance while the current wave lives
    if (wave < NUM_WAVES) return .{ .spawn_wave = wave };
    if (!baal_spawned) return .spawn_baal;
    return .done;
}

const testing = std.testing;

test "baal waves: advance only on a clear room, then Baal after the fifth" {
    // A live wave blocks progress regardless of cursor.
    try testing.expectEqual(WaveAction.wait, nextWaveAction(0, true, false));
    try testing.expectEqual(WaveAction.wait, nextWaveAction(4, true, false));
    // A clear room spawns the wave at the cursor.
    try testing.expectEqual(WaveAction{ .spawn_wave = 0 }, nextWaveAction(0, false, false));
    try testing.expectEqual(WaveAction{ .spawn_wave = 4 }, nextWaveAction(4, false, false));
    // After all five waves, Baal comes out once.
    try testing.expectEqual(WaveAction.spawn_baal, nextWaveAction(5, false, false));
    try testing.expectEqual(WaveAction.done, nextWaveAction(5, false, true));
}

test "baal weights: Maul scales with target's missing life; clone caps at 2" {
    const full = actionWeights(.{ .target_life_pct = 100, .dist = 10, .clones_spawned = 0, .target_visible = true, .normal_difficulty = false });
    try testing.expectEqual(@as(i32, 100), full[1]); // 100 + (100-100)
    const hurt = actionWeights(.{ .target_life_pct = 30, .dist = 10, .clones_spawned = 0, .target_visible = true, .normal_difficulty = false });
    try testing.expectEqual(@as(i32, 170), hurt[1]); // 100 + (100-30)
    try testing.expectEqual(@as(i32, 20), full[15]); // (2-0)*10
    const two = actionWeights(.{ .target_life_pct = 50, .dist = 10, .clones_spawned = 2, .target_visible = true, .normal_difficulty = false });
    try testing.expectEqual(@as(i32, 0), two[15]); // clones exhausted
    const three = actionWeights(.{ .target_life_pct = 50, .dist = 10, .clones_spawned = 3, .target_visible = true, .normal_difficulty = false });
    try testing.expectEqual(@as(i32, 0), three[15]); // clamped, never negative
}

test "baal weights: distance modifiers gate nova/cold and boost teleport/ranged" {
    const near = actionWeights(.{ .target_life_pct = 100, .dist = 10, .clones_spawned = 0, .target_visible = false, .normal_difficulty = false });
    try testing.expectEqual(@as(i32, 70), near[11]); // nova up close
    try testing.expectEqual(@as(i32, 20), near[14]); // base teleport
    try testing.expectEqual(@as(i32, 0), near[5]); // not visible
    const far = actionWeights(.{ .target_life_pct = 100, .dist = 40, .clones_spawned = 0, .target_visible = true, .normal_difficulty = false });
    try testing.expectEqual(@as(i32, 0), far[11]); // nova zeroed past 25
    try testing.expectEqual(@as(i32, 50), far[14]); // 20 + 30 past 25
    try testing.expectEqual(@as(i32, 15), far[6]); // ranged boosted past 35
    try testing.expectEqual(@as(i32, 0), far[13]); // cold zeroed past 35
    try testing.expectEqual(@as(i32, 60), far[5]); // visible
}

test "baal weights: Normal difficulty raises Maul base and lowers cold" {
    const norm = actionWeights(.{ .target_life_pct = 100, .dist = 10, .clones_spawned = 0, .target_visible = false, .normal_difficulty = true });
    try testing.expectEqual(@as(i32, 125), norm[1]); // base 125 on Normal
    try testing.expectEqual(@as(i32, 40), norm[13]); // cold 40 on Normal
}

test "baal select: a valid action every roll; never the zero-weight slots" {
    var seed = Seed.fromValue(0xBAA1);
    const ctx = Context{ .target_life_pct = 60, .dist = 10, .clones_spawned = 0, .target_visible = true, .normal_difficulty = false };
    const w = actionWeights(ctx);
    for (0..500) |_| {
        const a = selectAction(ctx, &seed);
        try testing.expect(w[@intFromEnum(a)] > 0); // only positive-weight slots are ever picked
    }
}

test "baal select: teleport fires far more often at long range than up close" {
    const near = Context{ .target_life_pct = 100, .dist = 10, .clones_spawned = 2, .target_visible = true, .normal_difficulty = false };
    const far = Context{ .target_life_pct = 100, .dist = 40, .clones_spawned = 2, .target_visible = true, .normal_difficulty = false };
    var s1 = Seed.fromValue(0x7);
    var s2 = Seed.fromValue(0x7);
    var near_tp: u32 = 0;
    var far_tp: u32 = 0;
    for (0..4000) |_| {
        if (selectAction(near, &s1) == .teleport) near_tp += 1;
        if (selectAction(far, &s2) == .teleport) far_tp += 1;
    }
    try testing.expect(far_tp > near_tp * 2); // 50/total far vs 20/total near, and nova drops out far
}
