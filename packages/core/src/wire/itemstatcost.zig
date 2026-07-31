//! ItemStatCost decode table — the bit widths that drive item stat-list decoding.
//!
//! Columns extracted from 1.14d ItemStatCost.txt: for each stat id, the item-stream value width
//! (Save Bits), param width (Save Param Bits), bias (Save Add) and left-shift (ValShift). At the
//! live wire version (0x60) the item decoder uses only the generic path
//!   param = read(saveParamBits) if saveParamBits>0;  value = (read(saveBits) - saveAdd) << valshift
//! (the legacy packed/encode special-cases are all version-gated off — see docs/re/sc-packets.md).

const std = @import("std");

const raw = @embedFile("data/itemstatcost.tsv");

pub const Row = struct {
    save_bits: u8 = 0,
    save_param_bits: u8 = 0,
    save_add: i32 = 0,
    valshift: u8 = 0,
    valid: bool = false,
};

pub const MAX_STAT = 512;
pub const STAT_LIST_TERMINATOR = 0x1FF; // 9-bit sentinel ending a stat list

pub const table: [MAX_STAT]Row = build: {
    @setEvalBranchQuota(2_000_000);
    var t = [_]Row{.{}} ** MAX_STAT;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next(); // header row
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, '\t');
        const id = std.fmt.parseInt(u16, it.next() orelse continue, 10) catch continue;
        const sb = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
        const spb = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
        const sa = std.fmt.parseInt(i32, it.next() orelse continue, 10) catch continue;
        const vs = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;
        if (id < MAX_STAT) t[id] = .{ .save_bits = sb, .save_param_bits = spb, .save_add = sa, .valshift = vs, .valid = true };
    }
    break :build t;
};

pub fn get(id: u16) ?Row {
    if (id >= MAX_STAT) return null;
    const r = table[id];
    return if (r.valid) r else null;
}

test "known stat widths match 1.14d" {
    try std.testing.expectEqual(@as(u8, 9), get(7).?.save_bits); // maxhp
    try std.testing.expectEqual(@as(i32, 32), get(7).?.save_add);
    try std.testing.expectEqual(@as(u8, 9), get(107).?.save_param_bits); // item_singleskill param
    try std.testing.expectEqual(@as(u8, 8), get(0).?.save_bits); // strength
    try std.testing.expect(get(9999) == null);
}
