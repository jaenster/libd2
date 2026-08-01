//! Per-difficulty combat rules, read from the real 1.14d DifficultyLevels.txt (d2-data) — no
//! transcribed literals. Currently the resist penalty; the same file also carries the death XP
//! penalty, monster CE damage %, etc. if those are needed later.

const std = @import("std");
const d2data = @import("d2-data");
const ctsv = @import("ctsv.zig");

pub const Difficulty = @import("montable.zig").Difficulty;

/// DifficultyLevels.txt ResistPenalty per difficulty (Normal 0 / Nightmare -40 / Hell -100),
/// derived at comptime from the real table. Subtracted from a unit's summed resist.
pub const RESIST_PENALTY = blk: {
    @setEvalBranchQuota(50000);
    const txt = d2data.file("DifficultyLevels");
    const hdr = ctsv.header(txt);
    break :blk [3]i32{
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Normal").?, "ResistPenalty"),
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Nightmare").?, "ResistPenalty"),
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Hell").?, "ResistPenalty"),
    };
};

/// The all-resist penalty subtracted from a character's summed resist at this difficulty.
pub fn resistPenalty(diff: Difficulty) i32 {
    return RESIST_PENALTY[@intFromEnum(diff)];
}

/// DifficultyLevels.txt StaticFieldMin per difficulty (Normal 0 / Nightmare 33 / Hell 50) — the
/// minimum % of max life Static Field can leave a monster at (it can't reduce below this fraction).
pub const STATIC_FIELD_MIN = blk: {
    @setEvalBranchQuota(50000);
    const txt = d2data.file("DifficultyLevels");
    const hdr = ctsv.header(txt);
    break :blk [3]i32{
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Normal").?, "StaticFieldMin"),
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Nightmare").?, "StaticFieldMin"),
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Hell").?, "StaticFieldMin"),
    };
};

/// The Static Field life floor (% of max life) at this difficulty — Static Field won't take a
/// monster below `staticFieldMin(diff)`% of its max life.
pub fn staticFieldMin(diff: Difficulty) i32 {
    return STATIC_FIELD_MIN[@intFromEnum(diff)];
}

/// DifficultyLevels.txt Life/Mana-StealDivisor (Normal 1 / Nightmare 2 / Hell 3): life & mana leech
/// are DIVIDED by this at higher difficulty (Hell leech is 1/3 as effective).
pub const LIFE_STEAL_DIVISOR = stealDivisor("LifeStealDivisor");
pub const MANA_STEAL_DIVISOR = stealDivisor("ManaStealDivisor");

fn stealDivisor(comptime col: []const u8) [3]i32 {
    @setEvalBranchQuota(50000);
    const txt = d2data.file("DifficultyLevels");
    const hdr = ctsv.header(txt);
    return .{
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Normal").?, col),
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Nightmare").?, col),
        ctsv.cellInt(hdr, ctsv.findRow(txt, "Hell").?, col),
    };
}

pub fn lifeStealDivisor(diff: Difficulty) i32 {
    return LIFE_STEAL_DIVISOR[@intFromEnum(diff)];
}
pub fn manaStealDivisor(diff: Difficulty) i32 {
    return MANA_STEAL_DIVISOR[@intFromEnum(diff)];
}

const testing = std.testing;

test "resist penalty comes from DifficultyLevels.txt (0 / -40 / -100)" {
    try testing.expectEqual(@as(i32, 0), resistPenalty(.normal));
    try testing.expectEqual(@as(i32, -40), resistPenalty(.nightmare));
    try testing.expectEqual(@as(i32, -100), resistPenalty(.hell));
}

test "per-difficulty caps from DifficultyLevels.txt (StaticFieldMin, steal divisors)" {
    try testing.expectEqual(@as(i32, 0), staticFieldMin(.normal));
    try testing.expectEqual(@as(i32, 33), staticFieldMin(.nightmare));
    try testing.expectEqual(@as(i32, 50), staticFieldMin(.hell));
    // Life/mana steal divided by 1 / 2 / 3.
    try testing.expectEqual(@as(i32, 1), lifeStealDivisor(.normal));
    try testing.expectEqual(@as(i32, 2), lifeStealDivisor(.nightmare));
    try testing.expectEqual(@as(i32, 3), lifeStealDivisor(.hell));
    try testing.expectEqual(@as(i32, 3), manaStealDivisor(.hell));
}
