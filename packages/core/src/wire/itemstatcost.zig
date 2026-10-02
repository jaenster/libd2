//! ItemStatCost decode table — the bit widths that drive item stat-list decoding.
//!
//! Columns extracted from 1.14d ItemStatCost.txt: for each stat id, the item-stream value width
//! (Save Bits), param width (Save Param Bits), bias (Save Add) and left-shift (ValShift). At the
//! live wire version (0x60) the item decoder uses only the generic path
//!   param = read(saveParamBits) if saveParamBits>0;  value = (read(saveBits) - saveAdd) << valshift
//! (the legacy packed/encode special-cases are all version-gated off — see docs/re/sc-packets.md).

const std = @import("std");
const d2data = @import("d2-data");

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

/// The table read from the game's own ItemStatCost.txt by `install`, when a program plays a modified game; null means
/// the embedded stock one.
var installed: ?*const [MAX_STAT]Row = null;

pub fn get(id: u16) ?Row {
    if (id >= MAX_STAT) return null;
    const r = (installed orelse &table)[id];
    return if (r.valid) r else null;
}

/// The widths of ItemStatCost.txt as the data package holds it now (`d2data.setOverride`): a program that plays a
/// modified game supplies its own table there, calls this once at start, and the stat decoder then reads the widths of
/// every stat that table has. The table lives for the rest of the process. Not thread safe against readers.
pub fn install(gpa: std.mem.Allocator) !void {
    const t = try gpa.create([MAX_STAT]Row);
    errdefer gpa.destroy(t);
    t.* = try fromTable(gpa, d2data.raw("ItemStatCost").?);
    installed = t;
}

/// Back to the embedded stock widths.
pub fn uninstall() void {
    installed = null;
}

/// The Row of every stat of an ItemStatCost.txt, by its ID column.
fn fromTable(gpa: std.mem.Allocator, bytes: []const u8) ![MAX_STAT]Row {
    var tbl = try d2data.tsv.parse(gpa, bytes);
    defer tbl.deinit();
    var t = [_]Row{.{}} ** MAX_STAT;
    for (0..tbl.rowCount()) |row| {
        const id = tbl.getInt(u16, row, "ID") orelse continue;
        const sb = tbl.getInt(u8, row, "Save Bits") orelse 0;
        const spb = tbl.getInt(u8, row, "Save Param Bits") orelse 0;
        const sa = tbl.getInt(i32, row, "Save Add") orelse 0;
        const vs = tbl.getInt(u8, row, "ValShift") orelse 0;
        if (id < MAX_STAT) t[id] = .{ .save_bits = sb, .save_param_bits = spb, .save_add = sa, .valshift = vs, .valid = true };
    }
    return t;
}

test "known stat widths match 1.14d" {
    try std.testing.expectEqual(@as(u8, 9), get(7).?.save_bits); // maxhp
    try std.testing.expectEqual(@as(i32, 32), get(7).?.save_add);
    try std.testing.expectEqual(@as(u8, 9), get(107).?.save_param_bits); // item_singleskill param
    try std.testing.expectEqual(@as(u8, 8), get(0).?.save_bits); // strength
    try std.testing.expect(get(9999) == null);
}

test "the widths read from the game's ItemStatCost.txt are the embedded ones" {
    const t = try fromTable(std.testing.allocator, d2data.raw("ItemStatCost").?);
    for (t, table, 0..) |a, b, id| {
        try std.testing.expectEqual(b.valid, a.valid);
        if (!b.valid) continue;
        try std.testing.expectEqual(b.save_bits, a.save_bits);
        try std.testing.expectEqual(b.save_param_bits, a.save_param_bits);
        try std.testing.expectEqual(b.save_add, a.save_add);
        try std.testing.expectEqual(b.valshift, a.valshift);
        _ = id;
    }
}

test "a stat the supplied table adds is known once installed, and not before" {
    const gpa = std.testing.allocator;
    const stock = d2data.raw("ItemStatCost").?;
    const header = stock[0..std.mem.indexOfScalar(u8, stock, '\n').?];
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, std.mem.trimEnd(u8, stock, "\r\n"));
    try text.append(gpa, '\n');
    // one more stat, made through the header so the test does not depend on the column order
    var cols = std.mem.splitScalar(u8, std.mem.trimEnd(u8, header, "\r"), '\t');
    var first = true;
    while (cols.next()) |name| {
        if (!first) try text.append(gpa, '\t');
        first = false;
        const eq = std.mem.eql;
        try text.appendSlice(gpa, if (eq(u8, name, "Stat")) "test_extra_stat" else if (eq(u8, name, "ID")) "400" else if (eq(u8, name, "Save Bits")) "11" else "");
    }
    try text.append(gpa, '\n');
    try d2data.setOverride("ItemStatCost", text.items);
    defer d2data.clearOverrides();
    try std.testing.expect(get(400) == null);
    try install(gpa);
    defer {
        gpa.destroy(installed.?);
        uninstall();
    }
    try std.testing.expectEqual(@as(u8, 11), get(400).?.save_bits);
    try std.testing.expectEqual(@as(u8, 9), get(7).?.save_bits); // the stock stats are still there
}
