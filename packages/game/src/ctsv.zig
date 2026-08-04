//! Comptime TSV reader — pulls values out of an embedded d2-data excel table AT COMPILE TIME so a
//! pure (allocator-free) module can be driven by the real 1.14d tables instead of transcribed
//! literals. Rows are matched by their first column; cells are read by header name. This is the
//! comptime sibling of d2-data/tsv.zig (which is the runtime loader).

const std = @import("std");

/// The header line (first line, trailing CR stripped).
pub fn header(comptime txt: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, txt, '\n');
    return std.mem.trimEnd(u8, lines.first(), "\r");
}

/// The data line whose first (tab-delimited) column equals `key`, or null. Skips the header and any
/// divider rows (e.g. "Expansion") automatically since they won't match a real key.
pub fn findRow(comptime txt: []const u8, comptime key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, txt, '\n');
    _ = lines.first(); // header
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const first = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
        if (std.mem.eql(u8, first, key)) return line;
    }
    return null;
}

/// 0-based index of the column named `col` in a tab-separated header, or null.
pub fn columnIndex(comptime hdr: []const u8, comptime col: []const u8) ?usize {
    var fields = std.mem.splitScalar(u8, hdr, '\t');
    var i: usize = 0;
    while (fields.next()) |f| : (i += 1) {
        if (std.mem.eql(u8, std.mem.trim(u8, f, " \r"), col)) return i;
    }
    return null;
}

/// The integer value of column `col` (by header name) in tab-separated `row`. Empty cell => 0.
pub fn cellInt(comptime hdr: []const u8, comptime row: []const u8, comptime col: []const u8) i32 {
    const idx = columnIndex(hdr, col) orelse @compileError("ctsv: no column " ++ col);
    var fields = std.mem.splitScalar(u8, row, '\t');
    var i: usize = 0;
    while (fields.next()) |f| : (i += 1) {
        if (i == idx) {
            const s = std.mem.trim(u8, f, " \r");
            if (s.len == 0) return 0;
            return std.fmt.parseInt(i32, s, 10) catch @compileError("ctsv: non-integer " ++ col ++ " = '" ++ f ++ "'");
        }
    }
    return 0;
}
