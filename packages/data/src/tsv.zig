//! Generic tab-separated excel-table reader for the real 1.14d Blizzard tables.
//!
//! D2's excel tables are `\t`-separated, `\r\n`-terminated text with a single
//! header row naming the columns. Column access is by header name (columns are
//! addressed by name, never by index, so a table with reordered columns still
//! resolves correctly). Empty cells read back as empty strings; typed getters
//! treat empty/blank as null so callers can supply their own default.
//!
//! This borrows nothing from the game engine — it's a plain in-memory parser over
//! bytes you already loaded (e.g. `@embedFile` or a file read).

const std = @import("std");

pub const Table = struct {
    /// Column header names, in file order.
    headers: [][]const u8,
    /// One slice of cells per data row; row[c] is the cell under headers[c].
    /// Rows shorter than the header are padded with "" so indexing is always safe.
    rows: [][][]const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    /// Resolve a header name to its column index (case-insensitive), or null.
    pub fn columnIndex(self: *const Table, name: []const u8) ?usize {
        for (self.headers, 0..) |h, i| {
            if (std.ascii.eqlIgnoreCase(h, name)) return i;
        }
        return null;
    }

    pub fn rowCount(self: *const Table) usize {
        return self.rows.len;
    }

    /// Raw cell string for (row, column-name). Returns "" for an unknown column
    /// or out-of-range row so callers never have to null-check the common path.
    pub fn get(self: *const Table, row: usize, col: []const u8) []const u8 {
        if (row >= self.rows.len) return "";
        const ci = self.columnIndex(col) orelse return "";
        const r = self.rows[row];
        if (ci >= r.len) return "";
        return r[ci];
    }

    /// Cell as an integer, or null if the column is unknown / the cell is blank /
    /// the cell doesn't parse. Handles a leading sign.
    pub fn getInt(self: *const Table, comptime T: type, row: usize, col: []const u8) ?T {
        const s = std.mem.trim(u8, self.get(row, col), " \t\r");
        if (s.len == 0) return null;
        return std.fmt.parseInt(T, s, 10) catch null;
    }

    /// Cell as a float, or null if unknown / blank / unparseable.
    pub fn getFloat(self: *const Table, comptime T: type, row: usize, col: []const u8) ?T {
        const s = std.mem.trim(u8, self.get(row, col), " \t\r");
        if (s.len == 0) return null;
        return std.fmt.parseFloat(T, s) catch null;
    }

    /// A D2 boolean cell: "1" is true, anything else (incl. blank) is false.
    pub fn getBool(self: *const Table, row: usize, col: []const u8) bool {
        const s = std.mem.trim(u8, self.get(row, col), " \t\r");
        return s.len == 1 and s[0] == '1';
    }

    /// Find the first row whose `col` equals `value` (case-sensitive). Useful for
    /// key columns like Skills."skill" or CharStats."class".
    pub fn findRow(self: *const Table, col: []const u8, value: []const u8) ?usize {
        const ci = self.columnIndex(col) orelse return null;
        for (self.rows, 0..) |r, i| {
            if (ci < r.len and std.mem.eql(u8, r[ci], value)) return i;
        }
        return null;
    }

    /// Find the first row whose integer column `col` equals `value` (blank / non-numeric
    /// cells are skipped). For numeric key columns like Skills."Id" or Missiles."Id".
    pub fn findByInt(self: *const Table, col: []const u8, value: i64) ?usize {
        const ci = self.columnIndex(col) orelse return null;
        for (self.rows, 0..) |r, i| {
            if (ci >= r.len) continue;
            const s = std.mem.trim(u8, r[ci], " \t\r");
            const v = std.fmt.parseInt(i64, s, 10) catch continue;
            if (v == value) return i;
        }
        return null;
    }
};

/// Parse TSV `bytes` into an owned Table. The Table owns all its strings via an
/// internal arena, so `bytes` may be freed after this returns. Blank lines are
/// skipped. Many D2 tables carry an "Expansion" sentinel row; it is kept verbatim
/// (callers that skip it do so by name), so nothing is silently dropped.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Table {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header_line = std.mem.trimEnd(u8, lines.next() orelse return error.EmptyTable, "\r");

    var headers: std.ArrayList([]const u8) = .empty;
    var hit = std.mem.splitScalar(u8, header_line, '\t');
    while (hit.next()) |h| try headers.append(a, try a.dupe(u8, h));
    const ncol = headers.items.len;
    if (ncol == 0) return error.EmptyTable;

    var rows: std.ArrayList([][]const u8) = .empty;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const cells = try a.alloc([]const u8, ncol);
        var i: usize = 0;
        var cit = std.mem.splitScalar(u8, line, '\t');
        while (cit.next()) |c| : (i += 1) {
            if (i < ncol) cells[i] = try a.dupe(u8, c);
        }
        // Pad a short row so every column index is in range.
        while (i < ncol) : (i += 1) cells[i] = "";
        try rows.append(a, cells);
    }

    return .{
        .headers = try headers.toOwnedSlice(a),
        .rows = try rows.toOwnedSlice(a),
        .arena = arena,
    };
}
