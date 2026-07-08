//! Typed views over the DRLG data tables. Only the fields generation reads.
//! Tables are embedded from data/excel so the tool is self-contained.

const std = @import("std");
const txt = @import("txt.zig");

pub const DrlgType = enum(u8) {
    none = 0,
    maze = 1, // LvlMaze: grid of rooms, each a DS1 preset
    preset = 2, // LvlPrest: a single fixed DS1 (towns, special areas)
    wilderness = 3, // outdoor placement
    _,
};

pub const Tables = struct {
    levels: txt.Table,
    lvl_prest: txt.Table,
    lvl_types: txt.Table,
    lvl_maze: txt.Table,
    lvl_sub: txt.Table,
    lvl_warp: txt.Table,

    pub fn load(gpa: std.mem.Allocator) !Tables {
        return .{
            .levels = try txt.Table.parse(gpa, @embedFile("excel/Levels.txt")),
            .lvl_prest = try txt.Table.parse(gpa, @embedFile("excel/LvlPrest.txt")),
            .lvl_types = try txt.Table.parse(gpa, @embedFile("excel/LvlTypes.txt")),
            .lvl_maze = try txt.Table.parse(gpa, @embedFile("excel/LvlMaze.txt")),
            .lvl_sub = try txt.Table.parse(gpa, @embedFile("excel/LvlSub.txt")),
            .lvl_warp = try txt.Table.parse(gpa, @embedFile("excel/LvlWarp.txt")),
        };
    }

    pub fn deinit(self: *Tables) void {
        self.levels.deinit();
        self.lvl_prest.deinit();
        self.lvl_types.deinit();
        self.lvl_maze.deinit();
        self.lvl_sub.deinit();
        self.lvl_warp.deinit();
    }

    // Levels.txt

    pub const Level = struct {
        row: usize,
        id: i64,
        name: []const u8,
        level_name: []const u8, // Levels.txt LevelName = the in-game display name
        act: i64, // 0-based act index
        drlg_type: DrlgType,
        lvl_type: i64, // -> LvlTypes.Id (tile library .dt1 set)
        size_x: i64,
        size_y: i64,
        offset_x: i64,
        offset_y: i64,
        depend: i64, // level this one is positioned relative to
    };

    pub fn level(self: *const Tables, id: i64) ?Level {
        const row = self.levels.findByInt("Id", id) orelse return null;
        return self.levelFromRow(row);
    }

    pub fn levelCount(self: *const Tables) usize {
        return self.levels.rowCount();
    }

    /// Level view for a raw table row (for iterating every level). Returns null
    /// for the "Null" id-0 placeholder row so callers can skip it.
    pub fn levelAtRow(self: *const Tables, row: usize) ?Level {
        if (row >= self.levels.rowCount()) return null;
        const id = self.levels.int(row, "Id");
        if (id == 0) return null;
        return self.levelFromRow(row);
    }

    fn levelFromRow(self: *const Tables, row: usize) Level {
        const t = &self.levels;
        return .{
            .row = row,
            .id = t.int(row, "Id"),
            .name = t.str(row, "Name"),
            .level_name = t.str(row, "LevelName"),
            .act = t.int(row, "Act"),
            .drlg_type = @enumFromInt(@as(u8, @intCast(t.int(row, "DrlgType")))),
            .lvl_type = t.int(row, "LevelType"),
            .size_x = t.int(row, "SizeX"),
            .size_y = t.int(row, "SizeY"),
            .offset_x = t.int(row, "OffsetX"),
            .offset_y = t.int(row, "OffsetY"),
            .depend = t.int(row, "Depend"),
        };
    }

    // LvlPrest.txt

    pub const Prest = struct {
        row: usize,
        def: i64,
        level_id: i64,
        size_x: i64,
        size_y: i64,
        files: i64, // count of random DS1 variants (0 => use the single named File)
        outdoors: i64,
        populate: i64,
        scan: i64,  // non-zero = BuildPresetArea loads DS1 + counts seed advances
        pops: i64,  // non-zero = same gate
        // DS1 filenames; "0" means empty slot
        file: [6][]const u8,

        pub fn ds1(self: *const Prest) ?[]const u8 {
            for (self.file) |f| {
                if (f.len > 0 and !std.mem.eql(u8, f, "0")) return f;
            }
            return null;
        }
    };

    /// LvlPrest row for a given level id (the preset map definition).
    pub fn prestForLevel(self: *const Tables, level_id: i64) ?Prest {
        const t = &self.lvl_prest;
        const row = t.findByInt("LevelId", level_id) orelse return null;
        return self.prestAt(row);
    }

    /// LvlPrest row for a given preset Def id (the value written into a room's
    /// pRoomExData[0] by DRLGMAZE_PickRoomPreset). Used to recover a maze room's
    /// Scan/Pops/Files for the AddPresetUnit seed-step count.
    pub fn prestById(self: *const Tables, def: i64) ?Prest {
        const t = &self.lvl_prest;
        const row = t.findByInt("Def", def) orelse return null;
        return self.prestAt(row);
    }

    pub fn prestAt(self: *const Tables, row: usize) Prest {
        const t = &self.lvl_prest;
        return .{
            .row = row,
            .def = t.int(row, "Def"),
            .level_id = t.int(row, "LevelId"),
            .size_x = t.int(row, "SizeX"),
            .size_y = t.int(row, "SizeY"),
            .files = t.int(row, "Files"),
            .outdoors = t.int(row, "Outdoors"),
            .populate = t.int(row, "Populate"),
            .scan = t.int(row, "Scan"),
            .pops = t.int(row, "Pops"),
            .file = .{
                t.str(row, "File1"), t.str(row, "File2"), t.str(row, "File3"),
                t.str(row, "File4"), t.str(row, "File5"), t.str(row, "File6"),
            },
        };
    }

    // LvlMaze.txt

    pub const Maze = struct {
        row: usize,
        level: i64,
        rooms: [3]i64, // normal/nightmare/hell room counts
        size_x: i64,
        size_y: i64,
        merge: i64,
    };

    pub fn mazeForLevel(self: *const Tables, level_id: i64) ?Maze {
        const t = &self.lvl_maze;
        const row = t.findByInt("Level", level_id) orelse return null;
        return .{
            .row = row,
            .level = level_id,
            .rooms = .{ t.int(row, "Rooms"), t.int(row, "Rooms(N)"), t.int(row, "Rooms(H)") },
            .size_x = t.int(row, "SizeX"),
            .size_y = t.int(row, "SizeY"),
            .merge = t.int(row, "Merge"),
        };
    }

    // LvlTypes.txt

    /// The .dt1 tile-library filenames for a level type (non-"0" slots).
    pub fn typeFiles(self: *const Tables, lvl_type: i64, out: *[32][]const u8) usize {
        return self.typeFilesCols(lvl_type, out, null);
    }

    /// Like typeFiles, but also reports each file's LvlTypes File COLUMN index
    /// (0-based, i.e. `File N` -> N-1). LvlPrest Dt1Mask bits address these
    /// column indices — rows with "0" gaps (e.g. Act 1 - Jail: File5/File8 = 0)
    /// make the compacted list position diverge from the mask bit.
    pub fn typeFilesCols(self: *const Tables, lvl_type: i64, out: *[32][]const u8, cols: ?*[32]u8) usize {
        const t = &self.lvl_types;
        const row = t.findByInt("Id", lvl_type) orelse return 0;
        var n: usize = 0;
        var i: usize = 1;
        var buf: [8]u8 = undefined;
        while (i <= 32) : (i += 1) {
            const name = std.fmt.bufPrint(&buf, "File {d}", .{i}) catch break;
            const f = t.str(row, name);
            if (f.len > 0 and !std.mem.eql(u8, f, "0")) {
                out[n] = f;
                if (cols) |c| c[n] = @intCast(i - 1);
                n += 1;
            }
        }
        return n;
    }
};

const testing = std.testing;

test "load tables and known level classifications" {
    var tb = try Tables.load(testing.allocator);
    defer tb.deinit();

    const town = tb.level(1).?;
    try testing.expectEqual(DrlgType.preset, town.drlg_type);
    try testing.expectEqual(@as(i64, 0), town.act);

    const wild = tb.level(2).?;
    try testing.expectEqual(DrlgType.wilderness, wild.drlg_type);

    const cave = tb.level(8).?;
    try testing.expectEqual(DrlgType.maze, cave.drlg_type);

    // Act 2 town is preset, act index 1
    const a2town = tb.level(40).?;
    try testing.expectEqual(DrlgType.preset, a2town.drlg_type);
    try testing.expectEqual(@as(i64, 1), a2town.act);
}

test "act topology: known levels map to the right act, every act has levels" {
    var tb = try Tables.load(testing.allocator);
    defer tb.deinit();

    // Anchor a known level per act (0-based act index).
    try testing.expectEqual(@as(i64, 0), tb.level(1).?.act); // Act 1 town
    try testing.expectEqual(@as(i64, 1), tb.level(40).?.act); // Act 2 town
    try testing.expectEqual(@as(i64, 2), tb.level(75).?.act); // Act 3 town (Kurast Docks)

    // Count generatable levels per act by iterating every row.
    var per_act = [_]usize{0} ** 5;
    var row: usize = 0;
    while (row < tb.levelCount()) : (row += 1) {
        const lv = tb.levelAtRow(row) orelse continue;
        if (lv.act >= 0 and lv.act < 5 and lv.drlg_type != .none) {
            per_act[@intCast(lv.act)] += 1;
        }
    }
    // Every act must have at least a handful of generatable levels.
    for (per_act, 0..) |n, act| {
        std.debug.print("act {d}: {d} generatable levels\n", .{ act, n });
        try testing.expect(n >= 5);
    }
}

test "maze room counts and preset DS1 lookup" {
    var tb = try Tables.load(testing.allocator);
    defer tb.deinit();

    // Act 1 Cave 1 (level 8): 24x24, 1 room on normal
    const m = tb.mazeForLevel(8).?;
    try testing.expectEqual(@as(i64, 24), m.size_x);
    try testing.expectEqual(@as(i64, 1), m.rooms[0]);

    // Act 1 town has a DS1 preset file
    const p = tb.prestForLevel(0) orelse tb.prestForLevel(1);
    try testing.expect(p != null);
}
