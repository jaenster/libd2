//! DRLG txt-row structs — mechanical transform of the reconstructed 1.14d
//! table headers, with a loader that fills them from the .txt files.
//!
//! STRUCT LAYOUT is faithful to the recon (field order + types). Per the 64-bit
//! standalone key (see d2-drlg-closure-to-zig-transform memory): use field order
//! + types and let Zig compute offsets; the `/* 0x.. */` comments are 32-bit ABI
//! only. C-array fields (char File[6][60]) stay fixed-size buffers; runtime
//! pointer/grid members (filled later by the engine, not from .txt) are kept for
//! faithfulness but left zero/null by the loader.
//!
//! Sources:
//!   D2LvlPrestTxt   ghidra-reconstruct/output/D2Common/DataTbls/LvlTbls.h:45
//!   D2LvlTypesTxt   .../LvlTbls.h:73
//!   D2LvlWarpTxt    .../LvlTbls.h:81
//!   D2LvlMazeTxt    .../D2Common/Drlg/Drlg.h  (struct D2LvlMazeTxt)
//!   D2LvlSubTxt     .../D2Common/Drlg/Drlg.h  (struct D2LvlSubTxt)
//!   D2LevelDefsTxt  .../_unnamespaced.h       (struct D2LevelDefsTxt)
//!
//! FINDING: DRLG geometry (SizeX/DrlgType/LevelType/Depend/Offsets/Warp/Vis) is
//! read from D2LevelDefsTxt (TXT_LevelDefs_GetLine), NOT the monster/visual
//! D2LevelsTxt — both are parsed from the single Levels.txt. The closure reads
//! pLevelDefs->* exclusively for layout, so this delivers D2LevelDefsTxt as the
//! "Levels" geometry row struct.

const std = @import("std");
const structs = @import("structs.zig");
const D2DrlgGridStrc = structs.D2DrlgGridStrc;
const D2DrlgFileStrc = structs.D2DrlgFileStrc;

/// eD2LevelId / eD2DrlgType are plain ints in the recon.
const eD2LevelId = @import("../enums.zig").eD2LevelId;
const eD2DrlgType = @import("enums.zig").eDrlgType;
const eDrlgLevelType = @import("enums.zig").eDrlgLevelType;

// Row structs (faithful field order + types)

/// LvlPrest.txt row — LvlTbls.h:45. `File[6][60]` = up to 6 DS1 variant names.
pub const D2LvlPrestTxt = extern struct {
    Def: i32,
    LevelId: eD2LevelId,
    Populate: i32,
    Logicals: i32,
    Outdoors: i32,
    Animate: i32,
    KillEdge: i32,
    FillBlanks: i32,
    Expansion: i32,
    field_0x24: u8,
    SizeX: i32,
    SizeY: i32,
    AutoMap: i32,
    Scan: i32,
    Pops: i32,
    PopPad: i32,
    Files: i32,
    File: [6][60]u8,
    Dt1Mask: i32,
};

/// LvlMaze.txt row — Drlg.h. `Rooms[3]` = Normal/Nightmare/Hell section counts.
pub const D2LvlMazeTxt = extern struct {
    Level: eD2LevelId,
    Rooms: [3]i32,
    SizeX: i32,
    SizeY: i32,
    Merge: i32,
};

/// LvlTypes.txt row — LvlTbls.h:73. `File[32][60]` = .dt1 tile-library names.
/// (No Id field in the recon — the table is indexed by the Id column == row.)
pub const D2LvlTypesTxt = extern struct {
    File: [32][60]u8,
    Act: u8,
    Expansion: i32,
};

/// LvlSub.txt row — Drlg.h. Prob/Trials/Max are 5-wide. The grid/pDrlgFile
/// members are populated at runtime by TXT_AllocTxt_lvlsub, not from the .txt.
pub const D2LvlSubTxt = extern struct {
    Type: i32,
    File: [60]u8,
    CheckAll: i32,
    BordType: i32,
    Dt1Mask: i32,
    GridSize: i32,
    pDrlgFile: ?*D2DrlgFileStrc,
    pTileTypeGrid: [4]D2DrlgGridStrc,
    pWallGrid: [4]D2DrlgGridStrc,
    pFloorGrid: D2DrlgGridStrc,
    pShadowGrid: D2DrlgGridStrc,
    Prob: [5]i32,
    Trials: [5]i32,
    Max: [5]i32,
    Expansion: i32,
};

/// LvlWarp.txt row — LvlTbls.h:81.
pub const D2LvlWarpTxt = extern struct {
    Id: i32,
    SelectX: i32,
    SelectY: i32,
    SelectDX: i32,
    SelectDY: i32,
    ExitWalkX: i32,
    ExitWalkY: i32,
    OffsetX: i32,
    OffsetY: i32,
    LitVersion: i32,
    Tiles: i32,
    Direction: i32,
};

/// Levels.txt DRLG geometry row — D2LevelDefsTxt (_unnamespaced.h). This is what
/// the closure reads for layout (SizeX[diff]/SizeY[diff], DrlgType, LevelType, …).
pub const D2LevelDefsTxt = extern struct {
    QuestFlag: i32,
    QuestFlagEx: i32,
    Layer: i32,
    SizeX: [3]i32,
    SizeY: [3]i32,
    OffsetX: i32,
    OffsetY: i32,
    Depend: i32,
    DrlgType: eD2DrlgType,
    LevelType: eDrlgLevelType,
    SubType: i32,
    SubTheme: i32,
    SubWaypoint: i32,
    SubShrine: i32,
    Vis: [8]eD2LevelId,
    Warp: [8]i32,
    Intensity: i32,
    Red: i32,
    Green: i32,
    Blue: i32,
    Portal: i32,
    Position: i32,
    SaveMonsters: i32,
    LOSDraw: i32,
};

// Loader
//
// Reuses the repo's VERIFIED txt parsing (src/txt.zig via src/tables.zig) to
// fill the recon-faithful row structs by column name. The source txt.Tables are
// kept alive so lookups can index by Id/Def/Level via the parser's findByInt.

const srctables = @import("../tables.zig");
const txt = @import("../txt.zig");

fn copyStr(dst: []u8, s: []const u8) void {
    @memset(dst, 0);
    const n = @min(dst.len -| 1, s.len);
    @memcpy(dst[0..n], s[0..n]);
}

fn i32col(t: *const txt.Table, row: usize, name: []const u8) i32 {
    return @truncate(t.int(row, name));
}

pub const LvlTables = struct {
    gpa: std.mem.Allocator,
    src: srctables.Tables,
    lvl_prest: []D2LvlPrestTxt,
    lvl_maze: []D2LvlMazeTxt,
    lvl_types: []D2LvlTypesTxt,
    lvl_sub: []D2LvlSubTxt,
    lvl_warp: []D2LvlWarpTxt,
    level_defs: []D2LevelDefsTxt,

    pub fn load(gpa: std.mem.Allocator) !LvlTables {
        var src = try srctables.Tables.load(gpa);
        errdefer src.deinit();

        const lvl_prest = try buildPrest(gpa, &src.lvl_prest);
        errdefer gpa.free(lvl_prest);
        const lvl_maze = try buildMaze(gpa, &src.lvl_maze);
        errdefer gpa.free(lvl_maze);
        const lvl_types = try buildTypes(gpa, &src.lvl_types);
        errdefer gpa.free(lvl_types);
        const lvl_sub = try buildSub(gpa, &src.lvl_sub);
        errdefer gpa.free(lvl_sub);
        const lvl_warp = try buildWarp(gpa, &src.lvl_warp);
        errdefer gpa.free(lvl_warp);
        const level_defs = try buildLevelDefs(gpa, &src.levels);
        errdefer gpa.free(level_defs);

        return .{
            .gpa = gpa,
            .src = src,
            .lvl_prest = lvl_prest,
            .lvl_maze = lvl_maze,
            .lvl_types = lvl_types,
            .lvl_sub = lvl_sub,
            .lvl_warp = lvl_warp,
            .level_defs = level_defs,
        };
    }

    /// Clear per-generation pool-pointer caches on the shared tables. TileSub's
    /// InitializeDrlgFile caches a pDrlgFile (+ its substitution grids) allocated in
    /// the generation's fog pool onto each LvlSub row and short-circuits on the
    /// non-null cache. That is correct WITHIN one pool (across seeds — the DS1 parse
    /// is seedless), but a caller that tears its pool down and generates again on the
    /// same Ctx would then reuse a freed pointer (→ OOB in the outdoor border path).
    /// Callers that own a per-call pool MUST invoke this at generation start so the
    /// next run re-parses fresh. Gate-safe: re-parsing consumes no seed.
    pub fn resetGenCache(self: *LvlTables) void {
        for (self.lvl_sub) |*row| row.pDrlgFile = null;
    }

    pub fn deinit(self: *LvlTables) void {
        self.gpa.free(self.lvl_prest);
        self.gpa.free(self.lvl_maze);
        self.gpa.free(self.lvl_types);
        self.gpa.free(self.lvl_sub);
        self.gpa.free(self.lvl_warp);
        self.gpa.free(self.level_defs);
        self.src.deinit();
    }

    // Lookups mirror the recon TXT_*_GetLine / FindLineByLevelId helpers; row
    // order of the built slices matches the source txt.Table row order.

    /// TXT_LvlPrest_GetLine(def) — LvlTbls.h:140.
    pub fn prestById(self: *const LvlTables, def: i64) ?*const D2LvlPrestTxt {
        const r = self.src.lvl_prest.findByInt("Def", def) orelse return null;
        return &self.lvl_prest[r];
    }
    /// TXT_LvlPrest_FindLineByLevelId(level) — LvlTbls.h:142.
    pub fn prestForLevel(self: *const LvlTables, level_id: i64) ?*const D2LvlPrestTxt {
        const r = self.src.lvl_prest.findByInt("LevelId", level_id) orelse return null;
        return &self.lvl_prest[r];
    }
    /// TXT_LvlMaze_FindLineByLevelId(level) — LvlTbls.h:154.
    pub fn mazeForLevel(self: *const LvlTables, level_id: i64) ?*const D2LvlMazeTxt {
        const r = self.src.lvl_maze.findByInt("Level", level_id) orelse return null;
        return &self.lvl_maze[r];
    }
    /// TXT_LvlTypes_GetLine(id) — LvlTbls.h:130 (indexed by the Id column).
    pub fn lvlTypeById(self: *const LvlTables, id: i64) ?*const D2LvlTypesTxt {
        const r = self.src.lvl_types.findByInt("Id", id) orelse return null;
        return &self.lvl_types[r];
    }
    /// TXT_LvlSub_GetLineFromSubType(type) — LvlTbls.h:160.
    pub fn lvlSubByType(self: *const LvlTables, sub_type: i64) ?*const D2LvlSubTxt {
        const r = self.src.lvl_sub.findByInt("Type", sub_type) orelse return null;
        return &self.lvl_sub[r];
    }
    /// LvlWarp row by Id.
    pub fn warpById(self: *const LvlTables, id: i64) ?*const D2LvlWarpTxt {
        const r = self.src.lvl_warp.findByInt("Id", id) orelse return null;
        return &self.lvl_warp[r];
    }
    /// TXT_LevelDefs_GetLine(level) — LvlTbls.h:122 (Levels.txt geometry).
    pub fn levelDefById(self: *const LvlTables, id: i64) ?*const D2LevelDefsTxt {
        const r = self.src.levels.findByInt("Id", id) orelse return null;
        return &self.level_defs[r];
    }
};

// Recon-style free-function shims
//
// The DRLG closure calls the table accessors as free functions (e.g.
// `DataTbls::LvlTbls::TXT_LevelDefs_GetLine(level)`), not as methods. These
// shims provide that exact API for the transform, backed by a
// settable global LvlTables instance. They return mutable C pointers ([*c]T)
// INTO the contiguous row slices so callers can do pointer arithmetic
// (`row + 1`) and mutate runtime fields (e.g. TileSub sets pDrlgFile), matching
// the recon. The harness sets `g_lvl_tables` after LvlTables.load().

// Thread-local: each verify worker owns its own LvlTables (the file cache
// pDrlgFile is mutated into these rows during generation), so the active table
// set must be per-thread.
pub threadlocal var g_lvl_tables: ?*LvlTables = null;

/// TXT_LvlPrest_GetLine(def)
pub fn lvlPrestGetLine(def: i32) [*c]D2LvlPrestTxt {
    const t = g_lvl_tables orelse return null;
    const r = t.src.lvl_prest.findByInt("Def", def) orelse return null;
    return &t.lvl_prest[r];
}
/// TXT_LvlPrest_FindLineByLevelId(level)
pub fn lvlPrestFindLineByLevelId(level: eD2LevelId) [*c]D2LvlPrestTxt {
    const t = g_lvl_tables orelse return null;
    const r = t.src.lvl_prest.findByInt("LevelId", @intFromEnum(level)) orelse return null;
    return &t.lvl_prest[r];
}
/// TXT_LvlMaze_FindLineByLevelId(level)
pub fn lvlMazeFindLineByLevelId(level: eD2LevelId) [*c]D2LvlMazeTxt {
    const t = g_lvl_tables orelse return null;
    const r = t.src.lvl_maze.findByInt("Level", @intFromEnum(level)) orelse return null;
    return &t.lvl_maze[r];
}
/// TXT_LvlTypes_GetLine(id)
pub fn lvlTypesGetLine(id: i32) [*c]D2LvlTypesTxt {
    const t = g_lvl_tables orelse return null;
    const r = t.src.lvl_types.findByInt("Id", id) orelse return null;
    return &t.lvl_types[r];
}
/// TXT_LvlSub_GetLineFromSubType(type)
pub fn lvlSubGetLineFromSubType(sub_type: i32) [*c]D2LvlSubTxt {
    const t = g_lvl_tables orelse return null;
    const r = t.src.lvl_sub.findByInt("Type", sub_type) orelse return null;
    return &t.lvl_sub[r];
}
/// LvlWarp row by Id.
pub fn lvlWarpGetLine(id: i32) [*c]D2LvlWarpTxt {
    const t = g_lvl_tables orelse return null;
    const r = t.src.lvl_warp.findByInt("Id", id) orelse return null;
    return &t.lvl_warp[r];
}
/// TXT_LevelDefs_GetLine(level)
pub fn levelDefsGetLine(eLevel: eD2LevelId) [*c]D2LevelDefsTxt {
    const t = g_lvl_tables orelse return null;
    const r = t.src.levels.findByInt("Id", @intFromEnum(eLevel)) orelse return null;
    return &t.level_defs[r];
}

fn buildPrest(gpa: std.mem.Allocator, t: *const txt.Table) ![]D2LvlPrestTxt {
    const out = try gpa.alloc(D2LvlPrestTxt, t.rowCount());
    for (out, 0..) |*row, i| {
        row.* = std.mem.zeroes(D2LvlPrestTxt);
        row.Def = i32col(t, i, "Def");
        row.LevelId = @enumFromInt(i32col(t, i, "LevelId"));
        row.Populate = i32col(t, i, "Populate");
        row.Logicals = i32col(t, i, "Logicals");
        row.Outdoors = i32col(t, i, "Outdoors");
        row.Animate = i32col(t, i, "Animate");
        row.KillEdge = i32col(t, i, "KillEdge");
        row.FillBlanks = i32col(t, i, "FillBlanks");
        row.Expansion = i32col(t, i, "Expansion");
        row.SizeX = i32col(t, i, "SizeX");
        row.SizeY = i32col(t, i, "SizeY");
        row.AutoMap = i32col(t, i, "AutoMap");
        row.Scan = i32col(t, i, "Scan");
        row.Pops = i32col(t, i, "Pops");
        row.PopPad = i32col(t, i, "PopPad");
        row.Files = i32col(t, i, "Files");
        row.Dt1Mask = i32col(t, i, "Dt1Mask");
        inline for (0..6) |k| {
            var buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "File{d}", .{k + 1}) catch unreachable;
            copyStr(&row.File[k], t.str(i, name));
        }
    }
    return out;
}

fn buildMaze(gpa: std.mem.Allocator, t: *const txt.Table) ![]D2LvlMazeTxt {
    const out = try gpa.alloc(D2LvlMazeTxt, t.rowCount());
    for (out, 0..) |*row, i| {
        row.* = .{
            .Level = @enumFromInt(i32col(t, i, "Level")),
            .Rooms = .{ i32col(t, i, "Rooms"), i32col(t, i, "Rooms(N)"), i32col(t, i, "Rooms(H)") },
            .SizeX = i32col(t, i, "SizeX"),
            .SizeY = i32col(t, i, "SizeY"),
            .Merge = i32col(t, i, "Merge"),
        };
    }
    return out;
}

fn buildTypes(gpa: std.mem.Allocator, t: *const txt.Table) ![]D2LvlTypesTxt {
    const out = try gpa.alloc(D2LvlTypesTxt, t.rowCount());
    for (out, 0..) |*row, i| {
        row.* = std.mem.zeroes(D2LvlTypesTxt);
        row.Act = @intCast(@as(u8, @truncate(@as(u64, @bitCast(t.int(i, "Act"))))));
        row.Expansion = i32col(t, i, "Expansion");
        inline for (0..32) |k| {
            var buf: [12]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "File {d}", .{k + 1}) catch unreachable;
            copyStr(&row.File[k], t.str(i, name));
        }
    }
    return out;
}

fn buildSub(gpa: std.mem.Allocator, t: *const txt.Table) ![]D2LvlSubTxt {
    const out = try gpa.alloc(D2LvlSubTxt, t.rowCount());
    for (out, 0..) |*row, i| {
        row.* = std.mem.zeroes(D2LvlSubTxt);
        row.Type = i32col(t, i, "Type");
        copyStr(&row.File, t.str(i, "File"));
        row.CheckAll = i32col(t, i, "CheckAll");
        row.BordType = i32col(t, i, "BordType");
        row.Dt1Mask = i32col(t, i, "Dt1Mask");
        row.GridSize = i32col(t, i, "GridSize");
        row.Expansion = i32col(t, i, "Expansion");
        inline for (0..5) |k| {
            var b0: [8]u8 = undefined;
            var b1: [8]u8 = undefined;
            var b2: [8]u8 = undefined;
            row.Prob[k] = i32col(t, i, std.fmt.bufPrint(&b0, "Prob{d}", .{k}) catch unreachable);
            row.Trials[k] = i32col(t, i, std.fmt.bufPrint(&b1, "Trials{d}", .{k}) catch unreachable);
            row.Max[k] = i32col(t, i, std.fmt.bufPrint(&b2, "Max{d}", .{k}) catch unreachable);
        }
    }
    return out;
}

fn buildWarp(gpa: std.mem.Allocator, t: *const txt.Table) ![]D2LvlWarpTxt {
    const out = try gpa.alloc(D2LvlWarpTxt, t.rowCount());
    for (out, 0..) |*row, i| {
        row.* = .{
            .Id = i32col(t, i, "Id"),
            .SelectX = i32col(t, i, "SelectX"),
            .SelectY = i32col(t, i, "SelectY"),
            .SelectDX = i32col(t, i, "SelectDX"),
            .SelectDY = i32col(t, i, "SelectDY"),
            .ExitWalkX = i32col(t, i, "ExitWalkX"),
            .ExitWalkY = i32col(t, i, "ExitWalkY"),
            .OffsetX = i32col(t, i, "OffsetX"),
            .OffsetY = i32col(t, i, "OffsetY"),
            .LitVersion = i32col(t, i, "LitVersion"),
            .Tiles = i32col(t, i, "Tiles"),
            .Direction = i32col(t, i, "Direction"),
        };
    }
    return out;
}

fn buildLevelDefs(gpa: std.mem.Allocator, t: *const txt.Table) ![]D2LevelDefsTxt {
    const out = try gpa.alloc(D2LevelDefsTxt, t.rowCount());
    for (out, 0..) |*row, i| {
        row.* = std.mem.zeroes(D2LevelDefsTxt);
        row.QuestFlag = i32col(t, i, "QuestFlag");
        row.QuestFlagEx = i32col(t, i, "QuestFlagEx");
        row.Layer = i32col(t, i, "Layer");
        // SizeX/SizeY: [normal, nightmare, hell] — N/H columns are parenthesised.
        row.SizeX = .{ i32col(t, i, "SizeX"), i32col(t, i, "SizeX(N)"), i32col(t, i, "SizeX(H)") };
        row.SizeY = .{ i32col(t, i, "SizeY"), i32col(t, i, "SizeY(N)"), i32col(t, i, "SizeY(H)") };
        row.OffsetX = i32col(t, i, "OffsetX");
        row.OffsetY = i32col(t, i, "OffsetY");
        row.Depend = i32col(t, i, "Depend");
        row.DrlgType = @enumFromInt(i32col(t, i, "DrlgType"));
        row.LevelType = @enumFromInt(i32col(t, i, "LevelType"));
        row.SubType = i32col(t, i, "SubType");
        row.SubTheme = i32col(t, i, "SubTheme");
        row.SubWaypoint = i32col(t, i, "SubWaypoint");
        row.SubShrine = i32col(t, i, "SubShrine");
        row.LOSDraw = i32col(t, i, "LOSDraw");
        row.Portal = i32col(t, i, "Portal");
        row.Position = i32col(t, i, "Position");
        row.SaveMonsters = i32col(t, i, "SaveMonsters");
        row.Intensity = i32col(t, i, "Intensity");
        row.Red = i32col(t, i, "Red");
        row.Green = i32col(t, i, "Green");
        row.Blue = i32col(t, i, "Blue");
        inline for (0..8) |k| {
            var b0: [8]u8 = undefined;
            var b1: [8]u8 = undefined;
            row.Vis[k] = @enumFromInt(i32col(t, i, std.fmt.bufPrint(&b0, "Vis{d}", .{k}) catch unreachable));
            row.Warp[k] = i32col(t, i, std.fmt.bufPrint(&b1, "Warp{d}", .{k}) catch unreachable);
        }
    }
    return out;
}

// Cross-check vs the repo's verified src/tables.zig
const testing = std.testing;

fn strLen(buf: []const u8) usize {
    return std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
}
fn strSlice(buf: []const u8) []const u8 {
    return buf[0..strLen(buf)];
}

test "LvlPrest rows match verified src/tables.zig (all rows)" {
    var lt = try LvlTables.load(testing.allocator);
    defer lt.deinit();
    const t = &lt.src.lvl_prest;
    var i: usize = 0;
    while (i < t.rowCount()) : (i += 1) {
        const a = lt.lvl_prest[i];
        const b = lt.src.prestAt(i); // verified view
        try testing.expectEqual(@as(i32, @truncate(b.def)), a.Def);
        try testing.expectEqual(@as(i32, @truncate(b.level_id)), @intFromEnum(a.LevelId));
        try testing.expectEqual(@as(i32, @truncate(b.size_x)), a.SizeX);
        try testing.expectEqual(@as(i32, @truncate(b.size_y)), a.SizeY);
        try testing.expectEqual(@as(i32, @truncate(b.files)), a.Files);
        try testing.expectEqual(@as(i32, @truncate(b.scan)), a.Scan);
        try testing.expectEqual(@as(i32, @truncate(b.pops)), a.Pops);
        for (0..6) |k| try testing.expectEqualStrings(b.file[k], strSlice(&a.File[k]));
    }
}

test "LvlPrest cross-check on a preset level" {
    // NB: level 47 (Act 2 Sewer 1) is a MAZE, not a preset — it has no LvlPrest
    // row. Preset levels (towns/special areas) do; cross-check town (level 1).
    var lt = try LvlTables.load(testing.allocator);
    defer lt.deinit();
    const a = lt.prestForLevel(1) orelse return error.NoTownPrest;
    const b = lt.src.prestForLevel(1).?;
    try testing.expectEqual(@as(i32, @truncate(b.def)), a.Def);
    try testing.expectEqual(@as(i32, @truncate(b.level_id)), @intFromEnum(a.LevelId));
    try testing.expectEqual(@as(i32, @truncate(b.size_x)), a.SizeX);
    try testing.expectEqual(@as(i32, @truncate(b.size_y)), a.SizeY);
    try testing.expectEqual(@as(i32, @truncate(b.files)), a.Files);
}

test "LvlMaze rooms/sizes match verified src/tables.zig (per level id)" {
    var lt = try LvlTables.load(testing.allocator);
    defer lt.deinit();
    // Compare both sides via the same by-level lookup (the Level column is not
    // unique — e.g. treasure rows reuse Level 0 — so by-row would diverge).
    const t = &lt.src.lvl_maze;
    var i: usize = 0;
    while (i < t.rowCount()) : (i += 1) {
        const level: i64 = i32col(t, i, "Level");
        const a = lt.mazeForLevel(level).?;
        const vb = lt.src.mazeForLevel(level).?;
        try testing.expectEqual(@as(i32, @truncate(vb.rooms[0])), a.Rooms[0]);
        try testing.expectEqual(@as(i32, @truncate(vb.rooms[1])), a.Rooms[1]);
        try testing.expectEqual(@as(i32, @truncate(vb.rooms[2])), a.Rooms[2]);
        try testing.expectEqual(@as(i32, @truncate(vb.size_x)), a.SizeX);
        try testing.expectEqual(@as(i32, @truncate(vb.size_y)), a.SizeY);
        try testing.expectEqual(@as(i32, @truncate(vb.merge)), a.Merge);
    }
    // Task spot-check: Act 2 Sewer 1 (level 47) = 6/6/6 rooms.
    const sewer = lt.mazeForLevel(47).?;
    try testing.expectEqual([3]i32{ 6, 6, 6 }, sewer.Rooms);
}

test "LevelDefs geometry matches verified src/tables.zig level()" {
    var lt = try LvlTables.load(testing.allocator);
    defer lt.deinit();
    // Spot-check several levels: town(1), wilderness(2), and a maze.
    for ([_]i64{ 1, 2, 3, 8, 47 }) |id| {
        const def = lt.levelDefById(id) orelse continue;
        const lvl = lt.src.level(id) orelse continue;
        try testing.expectEqual(@as(i32, @truncate(lvl.size_x)), def.SizeX[0]);
        try testing.expectEqual(@as(i32, @truncate(lvl.size_y)), def.SizeY[0]);
        try testing.expectEqual(@as(i32, @truncate(lvl.offset_x)), def.OffsetX);
        try testing.expectEqual(@as(i32, @truncate(lvl.offset_y)), def.OffsetY);
        try testing.expectEqual(@as(i32, @truncate(lvl.depend)), def.Depend);
        try testing.expectEqual(@as(i32, @truncate(lvl.lvl_type)), @intFromEnum(def.LevelType));
        try testing.expectEqual(@as(i32, @intFromEnum(lvl.drlg_type)), @intFromEnum(def.DrlgType));
    }
}

test "LvlTypes/LvlSub/LvlWarp load without error" {
    var lt = try LvlTables.load(testing.allocator);
    defer lt.deinit();
    try testing.expect(lt.lvl_types.len > 0);
    try testing.expect(lt.lvl_sub.len > 0);
    try testing.expect(lt.lvl_warp.len > 0);
}
