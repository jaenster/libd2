const std = @import("std");
const data = @import("lib.zig");

test "every embedded table parses and has rows" {
    const gpa = std.testing.allocator;
    for (data.tables) |t| {
        var tbl = try data.load(gpa, t.name);
        defer tbl.deinit();
        try std.testing.expect(tbl.headers.len >= 1);
        try std.testing.expect(tbl.rowCount() >= 1);
    }
}

test "CharStats sorceress row" {
    const gpa = std.testing.allocator;
    var tbl = try data.load(gpa, "CharStats");
    defer tbl.deinit();
    const row = tbl.findRow("class", "Sorceress") orelse return error.NoSorceress;
    // 1.14d CharStats: the energy column is named "int". Sorceress base is 10/25/35/10.
    try std.testing.expectEqual(@as(i32, 10), tbl.getInt(i32, row, "str").?);
    try std.testing.expectEqual(@as(i32, 25), tbl.getInt(i32, row, "dex").?);
    try std.testing.expectEqual(@as(i32, 35), tbl.getInt(i32, row, "int").?);
    try std.testing.expectEqual(@as(i32, 10), tbl.getInt(i32, row, "vit").?);
}

test "ItemStatCost has the full 1.14d stat set" {
    const gpa = std.testing.allocator;
    var tbl = try data.load(gpa, "ItemStatCost");
    defer tbl.deinit();
    // 1.14d ItemStatCost carries the ~250+ stat definitions; guard a floor.
    try std.testing.expect(tbl.rowCount() >= 250);
    try std.testing.expect(tbl.findRow("Stat", "strength") != null);
}

test "unknown table errors, has() is honest" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownTable, data.load(gpa, "NoSuchTable"));
    try std.testing.expect(!data.has("NoSuchTable"));
    try std.testing.expect(data.has("weapons"));
}

test "single-column name list parses (LowQualityItems)" {
    const gpa = std.testing.allocator;
    var tbl = try data.load(gpa, "LowQualityItems");
    defer tbl.deinit();
    try std.testing.expectEqual(@as(usize, 1), tbl.headers.len);
    try std.testing.expect(tbl.findRow("Name", "Crude") != null);
}
