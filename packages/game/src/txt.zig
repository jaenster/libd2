//! Generic reader for D2's tab-separated Excel tables (data\global\excel\*.txt).
//! Header row maps column name -> index; data rows are slices into an owned copy of
//! the source. Empty fields read as 0 for integer accessors (D2's convention).
//!
//! Mirrors the sibling d2-items txt.Table; kept local so d2-sim has no cross-lib dep.

const std = @import("std");

pub const Table = struct {
    cols: std.StringHashMapUnmanaged(usize) = .{},
    rows: [][]const []const u8 = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Table {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const a = arena.allocator();
        var t = Table{ .arena = arena };

        var lines = std.mem.splitScalar(u8, src, '\n');
        const header = lines.next() orelse return t;
        var ci: usize = 0;
        var hcols = std.mem.splitScalar(u8, trimCR(header), '\t');
        while (hcols.next()) |name| : (ci += 1) {
            try t.cols.put(a, name, ci);
        }

        var rowlist: std.ArrayListUnmanaged([]const []const u8) = .empty;
        while (lines.next()) |raw| {
            const line = trimCR(raw);
            if (line.len == 0) continue;
            var fields: std.ArrayListUnmanaged([]const u8) = .empty;
            var fc = std.mem.splitScalar(u8, line, '\t');
            while (fc.next()) |f| try fields.append(a, f);
            try rowlist.append(a, try fields.toOwnedSlice(a));
        }
        t.rows = try rowlist.toOwnedSlice(a);
        t.arena = arena; // re-point arena into the returned struct copy
        return t;
    }

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    pub fn col(self: *const Table, name: []const u8) ?usize {
        return self.cols.get(name);
    }

    pub fn rowCount(self: *const Table) usize {
        return self.rows.len;
    }

    /// Raw string cell, or "" if out of range / unknown column.
    pub fn str(self: *const Table, row: usize, name: []const u8) []const u8 {
        const c = self.cols.get(name) orelse return "";
        if (row >= self.rows.len or c >= self.rows[row].len) return "";
        return self.rows[row][c];
    }

    /// Integer cell; empty / non-numeric reads as 0 (D2 convention).
    pub fn int(self: *const Table, row: usize, name: []const u8) i64 {
        const s = self.str(row, name);
        if (s.len == 0) return 0;
        return std.fmt.parseInt(i64, s, 10) catch 0;
    }

    /// Find the first row whose integer column `name` equals `value`, else null.
    pub fn findByInt(self: *const Table, name: []const u8, value: i64) ?usize {
        const c = self.cols.get(name) orelse return null;
        for (self.rows, 0..) |r, i| {
            if (c >= r.len) continue;
            const v = std.fmt.parseInt(i64, r[c], 10) catch continue;
            if (v == value) return i;
        }
        return null;
    }

    /// Find the first row whose string column `name` equals `value` (case-sensitive), else null.
    pub fn findByStr(self: *const Table, name: []const u8, value: []const u8) ?usize {
        const c = self.cols.get(name) orelse return null;
        for (self.rows, 0..) |r, i| {
            if (c >= r.len) continue;
            if (std.mem.eql(u8, r[c], value)) return i;
        }
        return null;
    }
};

fn trimCR(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r");
}

const testing = std.testing;

test "parse header and integer access" {
    const src = "Name\tId\tVal\nFoo\t3\t10\nBar\t7\t\n";
    var t = try Table.parse(testing.allocator, src);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.rowCount());
    try testing.expectEqualStrings("Foo", t.str(0, "Name"));
    try testing.expectEqual(@as(i64, 3), t.int(0, "Id"));
    try testing.expectEqual(@as(i64, 0), t.int(1, "Val")); // empty -> 0
    try testing.expectEqual(@as(?usize, 1), t.findByInt("Id", 7));
    try testing.expectEqual(@as(?usize, 0), t.findByStr("Name", "Foo"));
}
