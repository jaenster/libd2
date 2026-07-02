//! D2 1.14d seed RNG (DRLG / item / monster rolls).
//!
//! The seed is a 64-bit LCG kept as two 32-bit halves {low, high}. Each step:
//!     state64 = low * 0x6ac690c5 + high
//!     low  = state64 & 0xFFFFFFFF
//!     high = state64 >> 32
//!
//! Ported bit-exact from the reconstructed 1.14d sources:
//!   D2_SEED_NEXT macro            (d2_platform.h)
//!   RANDOM_RandomNumberSelector   (1.14d 0045c3e0)
//!   RollRandomSeed                (1.14d 0045c370)
//!   SEED_RollRange                (1.14d 004bc500)
//!   SEED_GenerateRandomSeed       (1.14d 00650de0)

const MUL: u64 = 0x6ac690c5;

pub const Seed = struct {
    low: u32 = 1,
    high: u32 = 0x29a, // SEED_InitDefault

    pub fn init(low: u32, high: u32) Seed {
        return .{ .low = low, .high = high };
    }

    /// Seed from a single value with the engine's `InitSeed_Param_666` (high = 666).
    pub fn fromValue(v: u32) Seed {
        return .{ .low = v, .high = 666 };
    }

    /// Advance the LCG one step, returning the full 64-bit state (D2_SEED_NEXT).
    pub fn next(self: *Seed) u64 {
        const state: u64 = @as(u64, self.low) *% MUL +% @as(u64, self.high);
        self.low = @truncate(state);
        self.high = @truncate(state >> 32);
        return state;
    }

    /// RollRandomSeed: step, return the new low word.
    pub fn rollRandomSeed(self: *Seed) u32 {
        _ = self.next();
        return self.low;
    }

    /// RANDOM_RandomNumberSelector(nModulo): uniform in [0, modulo).
    /// Power-of-two modulo masks the low word; otherwise the new LOW WORD mod modulo
    /// (engine 0045c40b-0d: `XOR EDX,EDX; DIV ESI` on EDX:EAX = 0:newLow — low-word,
    /// NOT the full 64-bit state). A modulo whose top bit is set ((int)nModulo < 1)
    /// returns 0, matching the signed check.
    pub fn pick(self: *Seed, modulo: u32) u32 {
        if (@as(i32, @bitCast(modulo)) < 1) return 0;
        _ = self.next();
        if (modulo & (modulo - 1) != 0) {
            return self.low % modulo;
        }
        return self.low & (modulo - 1);
    }

    /// RollBetweenMinAndMax (1.14d 0x472280): min + RANDOM_RandomNumberSelector(max).
    /// LOW-WORD reduction (verified: reA_roll_primitives.c) — NOT the full-state
    /// rollRange below. This is the primitive the ITEM rollers use everywhere
    /// (affix weighted pick, tier 0-100 roll). max<=0 returns min without advancing.
    pub fn rollBetween(self: *Seed, min: i32, max: i32) i32 {
        return min +% @as(i32, @bitCast(self.pick(@bitCast(max))));
    }

    /// SEED_RollRange(min, max): uniform in [min, max). Returns min if max <= min.
    /// NOTE: uses the FULL 64-bit state for non-power-of-two (DRLG semantics). The
    /// item subsystem uses rollBetween (low-word) instead — do not mix them.
    pub fn rollRange(self: *Seed, min: i32, max: i32) i32 {
        if (max <= min) return min;
        const width: u32 = @intCast(max - min);
        const state = self.next();
        if (width & (width - 1) != 0) {
            return @as(i32, @intCast(state % width)) +% min;
        }
        return @as(i32, @bitCast(self.low & (width - 1))) +% min;
    }
};

/// The act "start seed" — the game's init seed stepped once. Every level seed in
/// the act derives from this. From DRLG_AllocDrlgActMisc (1.14d 006424xx):
///   nSeed = {init, 0x29a}; SEED_NEXT; dwStartSeed = nSeed.low
/// (dwStartSeed is captured before Act II's tomb-level rolls, so it's exactly one step.)
pub fn actStartSeed(init_seed: u32) u32 {
    var s = Seed.init(init_seed, 0x29a);
    _ = s.next();
    return s.low;
}

/// A level's RNG seed, from DRLGACTMISC_AllocDrlgLevel (Drlg.cpp:815):
///   sSeed = { dwStartSeed + levelId, 0x29a }
pub fn levelSeed(start_seed: u32, level_id: i32) Seed {
    return Seed.init(start_seed +% @as(u32, @bitCast(level_id)), 0x29a);
}

/// SEED_GenerateRandomSeed: tick/time-based seed (game-create entropy), masked to 31 bits.
/// Pure given its input so callers can reproduce a seed deterministically.
pub fn generateRandomSeed(tick_plus_time_plus_offset: u32) u32 {
    var v: u32 = tick_plus_time_plus_offset;
    inline for (0..3) |_| {
        v = v *% 0x19660d +% 0x3c6ef35f;
    }
    return v & 0x7fffffff;
}

const testing = @import("std").testing;

test "next splits 64-bit state into halves" {
    var s = Seed.init(1, 0x29a);
    const state = s.next();
    // state = 1 * 0x6ac690c5 + 0x29a = 0x6ac6935f
    try testing.expectEqual(@as(u64, 0x6ac690c5 + 0x29a), state);
    try testing.expectEqual(@as(u32, 0x6ac6935f), s.low);
    try testing.expectEqual(@as(u32, 0), s.high);
}

test "pick power-of-two masks low word" {
    var s = Seed.init(1, 0x29a);
    // after one step low=0x6ac6935f; pick(16) = low & 15 = 0xf
    try testing.expectEqual(@as(u32, 0x6ac6935f & 0xf), s.pick(16));
}

test "pick non-power-of-two uses new low-word modulo" {
    var s = Seed.init(1, 0x29a);
    // after one step low=0x6ac6935f (high=0); pick(100) = low % 100
    const expected: u32 = 0x6ac6935f % 100;
    try testing.expectEqual(expected, s.pick(100));
}

test "pick(0) and negative modulo return 0 without stepping" {
    var s = Seed.init(123, 456);
    const before = s;
    try testing.expectEqual(@as(u32, 0), s.pick(0));
    try testing.expectEqual(@as(u32, 0), s.pick(0x80000000));
    try testing.expectEqual(before.low, s.low);
    try testing.expectEqual(before.high, s.high);
}

test "level seed derivation is two-stage and deterministic" {
    // act start seed = init stepped once; level seed = start + levelId.
    const start = actStartSeed(12345);
    var s1 = Seed.init(12345, 0x29a);
    _ = s1.next();
    try testing.expectEqual(s1.low, start);

    const ls = levelSeed(start, 8);
    try testing.expectEqual(start +% 8, ls.low);
    try testing.expectEqual(@as(u32, 0x29a), ls.high);

    // distinct levels in the same act get distinct seeds
    try testing.expect(levelSeed(start, 1).low != levelSeed(start, 2).low);
}

test "rollRange returns min when max<=min and is deterministic" {
    var s = Seed.init(7, 11);
    try testing.expectEqual(@as(i32, 5), s.rollRange(5, 5));
    try testing.expectEqual(@as(i32, 5), s.rollRange(5, 3));
    var a = Seed.init(7, 11);
    var b = Seed.init(7, 11);
    try testing.expectEqual(a.rollRange(10, 100), b.rollRange(10, 100));
}
