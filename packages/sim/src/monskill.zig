//! Monster skill assignments — the Skill1..8 / Sk1..8mode / Sk1..8lvl columns of MonStats.txt
//! (D2Common MonsterTbls). These are the skills a monster's AI can cast (e.g. a Fallen Shaman's
//! Resurrect + ShamanFire, a Skeleton's SkeletonRaise). This module just READS the assignment off
//! a MonStats row; resolving the skill name to a Skills.txt id + actually casting is the AI's job
//! (skill.idByName + skill.castElemental / execute).
//!
//! Decoupled by design: the caller owns the MonStats table (so the returned name/mode slices stay
//! valid for its lifetime) and passes the row. No allocation.

const std = @import("std");
const d2data = @import("d2-data");

/// Max monster skill slots (MonStats Skill1..Skill8).
pub const MAX_SKILLS = 8;

/// One monster skill slot: the Skills.txt skill NAME the AI casts, the monster animation `mode`
/// it plays, and the fixed skill `level`. Slices borrow the MonStats table.
pub const MonSkill = struct {
    name: []const u8,
    mode: []const u8,
    level: i32,
};

/// Read a monster's non-empty skill slots from its MonStats row into `out`; returns the count.
/// Columns: Skill1..8 (name), Sk1..8mode (anim mode), Sk1..8lvl (level).
pub fn read(table: *const d2data.Table, row: usize, out: *[MAX_SKILLS]MonSkill) usize {
    var n: usize = 0;
    inline for (1..MAX_SKILLS + 1) |i| {
        const idx = std.fmt.comptimePrint("{d}", .{i});
        const name = table.get(row, "Skill" ++ idx);
        if (name.len != 0) {
            out[n] = .{
                .name = name,
                .mode = table.get(row, "Sk" ++ idx ++ "mode"),
                .level = table.getInt(i32, row, "Sk" ++ idx ++ "lvl") orelse 0,
            };
            n += 1;
        }
    }
    return n;
}

/// Read a monster's skills by its MonStats `Id` (the internal name, e.g. "fallenshaman1").
pub fn forMonster(table: *const d2data.Table, mon_id: []const u8, out: *[MAX_SKILLS]MonSkill) usize {
    const row = table.findRow("Id", mon_id) orelse return 0;
    return read(table, row, out);
}

const testing = std.testing;

test "read a monster's Skill1..8 assignments from the real MonStats.txt" {
    var t = try d2data.open(testing.allocator, "MonStats");
    defer t.deinit();

    var buf: [MAX_SKILLS]MonSkill = undefined;

    // A Fallen Shaman casts Resurrect + ShamanFire.
    const nsh = forMonster(&t, "fallenshaman1", &buf);
    try testing.expectEqual(@as(usize, 2), nsh);
    try testing.expectEqualStrings("Resurrect", buf[0].name);
    try testing.expectEqualStrings("ShamanFire", buf[1].name);

    // A Skeleton has a single skill (SkeletonRaise) at level 1.
    const nsk = forMonster(&t, "skeleton1", &buf);
    try testing.expectEqual(@as(usize, 1), nsk);
    try testing.expectEqualStrings("SkeletonRaise", buf[0].name);
    try testing.expectEqual(@as(i32, 1), buf[0].level);

    // A plain monster with no assigned skills reads zero.
    const nz = forMonster(&t, "skeleton1_zzz_missing", &buf);
    try testing.expectEqual(@as(usize, 0), nz);
}
