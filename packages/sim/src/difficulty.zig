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

const testing = std.testing;

test "resist penalty comes from DifficultyLevels.txt (0 / -40 / -100)" {
    try testing.expectEqual(@as(i32, 0), resistPenalty(.normal));
    try testing.expectEqual(@as(i32, -40), resistPenalty(.nightmare));
    try testing.expectEqual(@as(i32, -100), resistPenalty(.hell));
}
