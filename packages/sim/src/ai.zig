//! Monster AI decision core — a pure state-machine step for a single monster.
//!
//! Ghidra session 62fbfe69, 1.14d Game.exe: the aggro / approach / melee-cadence loop is a
//! slice-level approximation of the monster AI srvdofunc path (AI_*); exact per-AI behaviours
//! (fleeing, casting, packs) are a TODO. The host iterates its unit set, supplies each monster
//! its nearest player and the shared config, and EXECUTES the returned AiAction (move via
//! Unit.stepToward, attack via combat.attackAndApply). decideMonster only decides; it mutates
//! the passed-in per-monster AI state and nothing else.

const unit = @import("unit.zig");
const Unit = unit.Unit;

/// Tunables the host shares across every monster (were hardcoded in the game host).
pub const AiConfig = struct {
    /// Aggro radius (world subtiles): a monster only pursues a player inside this range.
    aggro_radius: i32 = 80,
    /// Melee reach (world subtiles).
    melee_range: i32 = 8,
    /// Movement per tick (world subtiles).
    monster_step: i32 = 5,
    /// Ticks between a monster's melee swings.
    attack_interval: u64 = 8,
};

pub const State = enum { idle, approach, attack };

/// Per-monster AI state the host stores and threads back in each tick.
pub const MonsterAI = struct {
    state: State = .idle,
    next_attack_tick: u64 = 0,
};

/// What the host should do with this monster this tick.
pub const AiAction = union(enum) {
    idle,
    approach: struct { tx: i32, ty: i32 },
    attack,
};

/// Decide a monster's action for tick `tick` given its `nearest_player` (null = none in the
/// level). Updates `state` (aggro state + the swing-cooldown stamp); returns the action for
/// the host to execute. `.attack` is only returned when a swing is off cooldown — in reach
/// but cooling down yields `.idle` (hold position, no swing), matching the game host.
pub fn decideMonster(m: *const Unit, nearest_player: ?*const Unit, cfg: AiConfig, tick: u64, state: *MonsterAI) AiAction {
    const tgt = nearest_player orelse {
        state.state = .idle;
        return .idle;
    };
    const d2 = sq(tgt.x - m.x) + sq(tgt.y - m.y);
    if (d2 > sq(cfg.aggro_radius)) {
        state.state = .idle;
        return .idle;
    }
    if (d2 <= sq(cfg.melee_range)) {
        state.state = .attack;
        if (tick >= state.next_attack_tick) {
            state.next_attack_tick = tick + cfg.attack_interval;
            return .attack;
        }
        return .idle;
    }
    state.state = .approach;
    return .{ .approach = .{ .tx = tgt.x, .ty = tgt.y } };
}

fn sq(v: i32) i64 {
    const w: i64 = v;
    return w * w;
}

const std = @import("std");
const testing = std.testing;

fn mkMonster(x: i32, y: i32) Unit {
    var m = Unit.init(.monster);
    m.x = x;
    m.y = y;
    m.setLife(60);
    return m;
}
fn mkPlayer(x: i32, y: i32) Unit {
    var p = Unit.init(.player);
    p.x = x;
    p.y = y;
    p.setLife(100);
    return p;
}

test "no player -> idle" {
    const m = mkMonster(0, 0);
    var st = MonsterAI{};
    try testing.expect(decideMonster(&m, null, .{}, 0, &st) == .idle);
    try testing.expectEqual(State.idle, st.state);
}

test "player beyond aggro radius -> idle" {
    const m = mkMonster(0, 0);
    const p = mkPlayer(1000, 0); // > aggro 80
    var st = MonsterAI{};
    try testing.expect(decideMonster(&m, &p, .{}, 5, &st) == .idle);
    try testing.expectEqual(State.idle, st.state);
}

test "player in aggro but out of melee -> approach toward the player" {
    const m = mkMonster(0, 0);
    const p = mkPlayer(50, 0); // within aggro 80, outside melee 8
    var st = MonsterAI{};
    const a = decideMonster(&m, &p, .{}, 5, &st);
    try testing.expect(a == .approach);
    try testing.expectEqual(@as(i32, 50), a.approach.tx);
    try testing.expectEqual(State.approach, st.state);
}

test "player in melee -> attack, then cooldown gates the next swing" {
    const m = mkMonster(0, 0);
    const p = mkPlayer(4, 0); // within melee 8
    var st = MonsterAI{};
    // First swing lands at tick 10, arming cooldown to 10 + interval(8) = 18.
    try testing.expect(decideMonster(&m, &p, .{}, 10, &st) == .attack);
    try testing.expectEqual(@as(u64, 18), st.next_attack_tick);
    try testing.expectEqual(State.attack, st.state);
    // Still cooling down at tick 12 -> idle (holds, no swing).
    try testing.expect(decideMonster(&m, &p, .{}, 12, &st) == .idle);
    try testing.expectEqual(State.attack, st.state);
    // Cooldown elapsed at tick 18 -> swings again.
    try testing.expect(decideMonster(&m, &p, .{}, 18, &st) == .attack);
    try testing.expectEqual(@as(u64, 26), st.next_attack_tick);
}
