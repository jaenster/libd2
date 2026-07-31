//! extract_excel — pull the COMPLETE real 1.14d Expansion excel table set out of a
//! local install's MPQs into packages/data/src/excel/. In-process via StormLib (no
//! game engine, no wine). MPQ override order: Patch_D2 > d2exp > d2data, exactly
//! as the retail loader layers them, so every table is the real Patch_D2-overridden
//! 1.14d bytes.
//!
//! The tables are Blizzard's copyrighted data. Extraction pulls them from YOUR
//! install; whether the checked-in excel/ is committed is a repo policy decision.
//!
//! Config: env D2_MPQ_DIR = dir holding d2data.mpq / d2exp.mpq / Patch_D2.mpq
//! (defaults to the repo's known 114clean dir if that env is unset).
//!
//! Build + run (StormLib via brew):
//!   SL=/opt/homebrew/opt/stormlib
//!   zig build-exe tools/extract_excel.zig -O ReleaseSafe -lc -lstorm -lz -lbz2 \
//!       -I"$SL/include" -L"$SL/lib" -femit-bin=tools/extract_excel
//!   D2_MPQ_DIR=/path/to/114clean ./tools/extract_excel
const std = @import("std");

const HANDLE = ?*anyopaque;
extern fn SFileOpenArchive(name: [*:0]const u8, priority: u32, flags: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileCloseArchive(mpq: HANDLE) callconv(.c) bool;
extern fn SFileOpenFileEx(mpq: HANDLE, name: [*:0]const u8, scope: u32, out: *HANDLE) callconv(.c) bool;
extern fn SFileGetFileSize(file: HANDLE, high: ?*u32) callconv(.c) u32;
extern fn SFileReadFile(file: HANDLE, buf: [*]u8, to_read: u32, read: *u32, ov: ?*anyopaque) callconv(.c) bool;
extern fn SFileCloseFile(file: HANDLE) callconv(.c) bool;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const gpa = std.heap.c_allocator;

// The full standard 1.14d Expansion excel table list. Each entry is the on-disk
// filename under data\global\excel\. `Experience.txt` is the file name (the game's
// "ExperienceE" logical table). Genuinely-absent files are logged, not fatal.
const tables = [_][]const u8{
    "Armor",             "Belts",         "BodyLocs",      "Books",
    "CharStats",         "Colors",        "CompCode",      "Composit",
    "CubeMain",          "DifficultyLevels", "ElemTypes",  "Events",
    "Experience",        "Gamble",        "Gems",          "Hireling",
    "HirelingDesc",      "Inventory",     "ItemRatio",     "ItemStatCost",
    "ItemTypes",         "Levels",        "LowQualityItems", "LvlMaze",
    "LvlPrest",          "LvlSub",        "LvlTypes",      "LvlWarp",
    "MagicPrefix",       "MagicSuffix",   "Misc",          "MissCalc",
    "Missiles",          "MonAI",         "MonEquip",      "MonLvl",
    "MonMode",           "MonPlace",      "MonPreset",     "MonProp",
    "MonSeq",            "MonSounds",     "MonStats",      "MonStats2",
    "MonType",           "MonUMod",       "NPC",           "Objects",
    "ObjMode",           "Overlay",       "PetType",       "Properties",
    "QualityItems",      "RarePrefix",    "RareSuffix",    "Runes",
    "SetItems",          "Sets",          "Shrines",       "SkillCalc",
    "SkillDesc",         "Skills",        "Sounds",        "States",
    "SuperUniques",      "TreasureClassEx", "UniqueAppellation", "UniquePrefix",
    "UniqueSuffix",      "UniqueItems",   "Weapons",       "WanderingMon",
    "AutoMap",           "objgroup",      "shrines",       "MonMode",
    "ObjGroup",
};

fn readMember(mpq: HANDLE, name: [*:0]const u8) ?[]u8 {
    var fh: HANDLE = null;
    if (!SFileOpenFileEx(mpq, name, 0, &fh)) return null;
    defer _ = SFileCloseFile(fh);
    const size = SFileGetFileSize(fh, null);
    if (size == 0 or size == 0xFFFF_FFFF) return null;
    const buf = gpa.alloc(u8, size) catch return null;
    var got: u32 = 0;
    if (!SFileReadFile(fh, buf.ptr, size, &got, null)) {
        gpa.free(buf);
        return null;
    }
    return buf[0..got];
}

fn readAny(mpqs: []const HANDLE, name: [*:0]const u8) ?[]u8 {
    for (mpqs) |m| if (readMember(m, name)) |b| return b;
    return null;
}

// A real excel table has a header line + at least one non-empty data row. Most are
// tab-separated; a handful (LowQualityItems, UniquePrefix, MonPlace, ...) are
// single-column name lists with no tabs, which are still valid tables.
fn looksLikeTable(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    if (header.len == 0) return false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len != 0) return true;
    }
    return false;
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const default_dir = "/Users/jaenster/code/zig/d2gs/114clean";
    const env_dir = if (getenv("D2_MPQ_DIR")) |z| std.mem.span(z) else default_dir;

    const mpq_names = [_][]const u8{ "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq" };
    var mpqs: std.ArrayList(HANDLE) = .empty;
    defer mpqs.deinit(gpa);
    for (mpq_names) |mn| {
        const p = try std.fs.path.joinZ(gpa, &.{ env_dir, mn });
        defer gpa.free(p);
        var h: HANDLE = null;
        if (SFileOpenArchive(p.ptr, 0, 0, &h)) {
            try mpqs.append(gpa, h);
            std.debug.print("opened {s}\n", .{mn});
        } else std.debug.print("skip (missing) {s}\n", .{mn});
    }
    if (mpqs.items.len == 0) return error.NoArchives;
    defer for (mpqs.items) |m| {
        _ = SFileCloseArchive(m);
    };

    try cwd.createDirPath(io, "src/excel");

    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();

    var ok: usize = 0;
    var miss: usize = 0;
    for (tables) |t| {
        // De-dup case-insensitively (the list carries a couple of casing variants).
        const lower = try std.ascii.allocLowerString(gpa, t);
        defer gpa.free(lower);
        if (seen.contains(lower)) continue;
        try seen.put(try gpa.dupe(u8, lower), {});

        const member = try std.fmt.allocPrintSentinel(gpa, "data\\global\\excel\\{s}.txt", .{t}, 0);
        defer gpa.free(member);
        if (readAny(mpqs.items, member.ptr)) |bytes| {
            defer gpa.free(bytes);
            if (!looksLikeTable(bytes)) {
                std.debug.print("  BAD (not TSV) {s}.txt ({d} bytes)\n", .{ t, bytes.len });
                miss += 1;
                continue;
            }
            const out = try std.fmt.allocPrint(gpa, "src/excel/{s}.txt", .{t});
            defer gpa.free(out);
            try cwd.writeFile(io, .{ .sub_path = out, .data = bytes });
            ok += 1;
            std.debug.print("  ok  {s}.txt ({d} bytes)\n", .{ t, bytes.len });
        } else {
            miss += 1;
            std.debug.print("  MISS {s}.txt\n", .{t});
        }
    }
    std.debug.print("\nextracted {d} excel tables, {d} missing\n", .{ ok, miss });
}
