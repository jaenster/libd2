//! Automap tile-lookup — resolves a placed map tile to its automap DC6 frame.
//! Faithful to 1.14d GetRandomCellNo: scans AutoMap.txt for the first row whose
//! level type, tile orientation, style/index and sub-index range all match, then
//! returns one of that row's Cel columns (the DC6 frame number). RE-confirmed.
//!
//! Data (committed): src/excel/AutoMap.txt + src/excel/LvlTypes.txt.

const std = @import("std");
const txt = @import("txt.zig");

const WILDCARD: i32 = 0xff;

/// One resolved AutoMap.txt row.
pub const Row = struct {
    level_type: i32, // LvlTypes.Id resolved from LevelName ("1 Cave" -> "Act 1 - Cave" -> 3)
    orientation: i32, // TileName -> DT1 nOrientation (fl=0, wl=1, ...)
    style: i32, // 0xff = wildcard (matches any index)
    sub_start: i32, // StartSequence
    sub_end: i32, // EndSequence
    cels: [4]i32, // Cel1..4; -1 = absent
    n_cels: u32, // count of present (>=0) cels
};

pub const AutomapTable = struct {
    gpa: std.mem.Allocator,
    rows: []Row,

    /// Number of AutoMap.txt data rows seen and how many resolved a level type.
    parsed: usize,
    resolved: usize,

    pub fn load(gpa: std.mem.Allocator) !AutomapTable {
        var lvl_types = try txt.Table.parse(gpa, @embedFile("excel/LvlTypes.txt"));
        defer lvl_types.deinit();
        var amap = try txt.Table.parse(gpa, @embedFile("excel/AutoMap.txt"));
        defer amap.deinit();

        var list: std.ArrayListUnmanaged(Row) = .empty;
        errdefer list.deinit(gpa);

        var resolved: usize = 0;
        const parsed = amap.rowCount();

        var r: usize = 0;
        while (r < parsed) : (r += 1) {
            const lvl_name = amap.str(r, "LevelName");
            const level_type = resolveLevelType(&lvl_types, lvl_name) orelse continue;

            const orientation = resolveOrientation(amap.str(r, "TileName")) orelse continue;
            resolved += 1;

            var cels = [4]i32{ -1, -1, -1, -1 };
            var n_cels: u32 = 0;
            inline for (.{ "Cel1", "Cel2", "Cel3", "Cel4" }, 0..) |name, i| {
                const s = amap.str(r, name);
                if (s.len != 0) {
                    const v = std.fmt.parseInt(i32, s, 10) catch -1;
                    if (v >= 0) {
                        cels[i] = v;
                        n_cels += 1;
                    }
                }
            }

            try list.append(gpa, .{
                .level_type = level_type,
                .orientation = orientation,
                .style = @intCast(amap.int(r, "Style")),
                .sub_start = @intCast(amap.int(r, "StartSequence")),
                .sub_end = @intCast(amap.int(r, "EndSequence")),
                .cels = cels,
                .n_cels = n_cels,
            });
        }

        return .{
            .gpa = gpa,
            .rows = try list.toOwnedSlice(gpa),
            .parsed = parsed,
            .resolved = resolved,
        };
    }

    pub fn deinit(self: *AutomapTable) void {
        self.gpa.free(self.rows);
        self.* = undefined;
    }

    /// Mirror of GetRandomCellNo: return the DC6 frame for a placed tile, or -1
    /// if the tile is not drawn on the automap. `pick` chooses the random variant
    /// (pick % n_cels); pass 0 for the deterministic first cel.
    pub fn lookup(
        self: *const AutomapTable,
        level_type: i32,
        orientation: i32,
        index: i32,
        sub_index: i32,
        pick: u32,
    ) i32 {
        for (self.rows) |row| {
            if (row.level_type != level_type) continue;
            if (row.orientation != orientation) continue;
            if (row.style != WILDCARD and row.style != index) continue;
            // StartSequence/EndSequence of -1 (empty in the txt) is a WILDCARD:
            // match any subindex. Only a non-negative range constrains it. (Most
            // dungeon wall rows use -1/-1; caves use real floor sub ranges.)
            if (row.sub_start >= 0 and (sub_index < row.sub_start or sub_index > row.sub_end)) continue;
            if (row.n_cels == 0) return -1;
            return row.cels[pick % row.n_cels];
        }
        return -1;
    }
};

/// "1 Cave" -> "Act 1 - Cave" -> LvlTypes.Id. null if the name has no match.
fn resolveLevelType(lvl_types: *const txt.Table, level_name: []const u8) ?i32 {
    const sp = std.mem.indexOfScalar(u8, level_name, ' ') orelse return null;
    const act = level_name[0..sp];
    const rest = level_name[sp + 1 ..];
    if (act.len == 0 or rest.len == 0) return null;

    var buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "Act {s} - {s}", .{ act, rest }) catch return null;

    // Exact match first.
    var i: usize = 0;
    while (i < lvl_types.rowCount()) : (i += 1) {
        if (std.mem.eql(u8, lvl_types.str(i, "Name"), want)) {
            return @intCast(lvl_types.int(i, "Id"));
        }
    }
    // Prefix fallback: AutoMap.txt abbreviates some names, e.g. "5 Ice" ->
    // "Act 5 - Ice" vs LvlTypes "Act 5 - Ice Caves". Match the first LvlTypes whose
    // Name starts with the reconstructed "Act N - rest".
    i = 0;
    while (i < lvl_types.rowCount()) : (i += 1) {
        if (std.mem.startsWith(u8, lvl_types.str(i, "Name"), want)) {
            return @intCast(lvl_types.int(i, "Id"));
        }
    }
    return null;
}

/// TileName -> DT1 nOrientation. RE-confirmed against placed DT1 tiles. A TileName
/// of "0" (or starting with '0') maps to orientation 0. null = unknown tile.
fn resolveOrientation(tile: []const u8) ?i32 {
    if (tile.len == 0) return null;
    if (tile[0] == '0') return 0;
    const map = .{
        .{ "fl", 0 },   .{ "wl", 1 },   .{ "wr", 2 },   .{ "wtlr", 3 },
        .{ "wtll", 4 }, .{ "wtr", 5 },  .{ "wbl", 6 },  .{ "wbr", 7 },
        .{ "wld", 8 },  .{ "wrd", 9 },  .{ "wle", 10 }, .{ "wre", 11 },
        .{ "co", 12 },  .{ "sh", 13 },  .{ "tr", 14 },  .{ "rf", 15 },
        .{ "ld", 16 },  .{ "rd", 17 },  .{ "fd", 18 },  .{ "fi", 19 },
    };
    inline for (map) |e| {
        if (std.mem.eql(u8, tile, e[0])) return e[1];
    }
    return null;
}

const testing = std.testing;

test "automap table loads and resolves level types" {
    var tbl = try AutomapTable.load(testing.allocator);
    defer tbl.deinit();

    // Nearly every AutoMap.txt row's LevelName maps to a LvlTypes.Id; the LoD table
    // has a stray "Expansion" meta row that has no "Act N - …" form, so allow a few
    // unresolved rather than requiring an exact match.
    try testing.expect(tbl.parsed > 3000);
    // Only the stray "Expansion" meta row (no "Act N - …" form) stays unresolved.
    try testing.expect(tbl.resolved >= tbl.parsed - 2);

    // Some Act-1 (levelType 1..11) tile resolves to a real frame — broad scan since
    // exact orient/index/sub vary by table version (functional coverage is verified
    // by the render + the `amdiag` dev command).
    var hits: usize = 0;
    var lt: i32 = 1;
    while (lt <= 11) : (lt += 1) {
        var orient: i32 = 0;
        while (orient <= 12) : (orient += 1) {
            var index: i32 = 0;
            while (index <= 40) : (index += 1) {
                if (tbl.lookup(lt, orient, index, 0, 0) >= 0) hits += 1;
            }
        }
    }
    try testing.expect(hits > 0);

    // Impossible level type -> not drawn on the automap.
    try testing.expectEqual(@as(i32, -1), tbl.lookup(9999, 0, 0, 0, 0));
}
