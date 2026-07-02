//! extract_assets — pull the item inventory sprites (DC6) + a palette the item
//! renderer needs straight out of a local 1.14d install's MPQs into a gitignored
//! assets/ dir. In-process via StormLib — no game engine, no wine.
//!
//! These are Blizzard's copyrighted assets: NEVER committed. This pulls them from
//! YOUR install. The invfile list is read from src/excel/{Weapons,Armor,Misc}.txt
//! (the `invfile` column). MPQ override order: Patch_D2 > d2exp > d2data.
//!
//! StormLib is the one C dependency here (encryption + compression); the runtime
//! d2-items library itself stays pure Zig. Config: env D2_MPQ_DIR = dir with
//! d2data.mpq / d2exp.mpq / Patch_D2.mpq.
//!
//! Build (StormLib via brew):
//!   SL=/opt/homebrew/opt/stormlib
//!   zig build-exe tools/extract_assets.zig -O ReleaseSafe -lc -lstorm -lz -lbz2 \
//!       -I"$SL/include" -L"$SL/lib" -femit-bin=tools/extract_assets
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

/// Read a member from the first archive in `mpqs` that has it (override order).
fn readAny(mpqs: []const HANDLE, name: [*:0]const u8) ?[]u8 {
    for (mpqs) |m| if (readMember(m, name)) |b| return b;
    return null;
}

/// Collect distinct `invfile` values from a tab-separated item table.
fn collectInvfiles(set: *std.StringHashMap(void), table_bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, table_bytes, '\n');
    const header = std.mem.trimEnd(u8, lines.next() orelse return, "\r");
    var col: ?usize = null;
    var hi: usize = 0;
    var hcols = std.mem.splitScalar(u8, header, '\t');
    while (hcols.next()) |h| : (hi += 1) {
        if (std.mem.eql(u8, h, "invfile")) col = hi;
    }
    const c = col orelse return;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fi: usize = 0;
        var fields = std.mem.splitScalar(u8, line, '\t');
        while (fields.next()) |f| : (fi += 1) {
            if (fi == c) {
                if (f.len != 0 and !set.contains(f)) {
                    const key = try gpa.dupe(u8, f);
                    try set.put(key, {});
                }
                break;
            }
        }
    }
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const env_z = getenv("D2_MPQ_DIR") orelse {
        std.debug.print("set D2_MPQ_DIR to your 1.14d install (dir with d2data.mpq)\n", .{});
        return error.NoMpqDir;
    };
    const env_dir = std.mem.span(env_z);

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

    try cwd.createDirPath(io, "assets/items");
    try cwd.createDirPath(io, "assets/palette");

    // Palette: ACT1 pal.dat (768-byte BGR).
    if (readAny(mpqs.items, "data\\global\\palette\\ACT1\\pal.dat")) |pal| {
        defer gpa.free(pal);
        try cwd.writeFile(io, .{ .sub_path = "assets/palette/ACT1.pal", .data = pal });
        std.debug.print("palette ACT1.pal ({d} bytes)\n", .{pal.len});
    } else std.debug.print("WARN: ACT1 pal.dat not found\n", .{});

    // Invfiles from the three item tables.
    var set = std.StringHashMap(void).init(gpa);
    defer set.deinit();
    inline for (.{ "Weapons.txt", "Armor.txt", "Misc.txt" }) |tbl| {
        const bytes = try cwd.readFileAlloc(io, "src/excel/" ++ tbl, gpa, .limited(8 * 1024 * 1024));
        defer gpa.free(bytes);
        try collectInvfiles(&set, bytes);
    }
    std.debug.print("{d} distinct invfiles\n", .{set.count()});

    var ok: usize = 0;
    var miss: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |k| {
        const invfile = k.*;
        const member = try std.fmt.allocPrintSentinel(gpa, "data\\global\\items\\{s}.dc6", .{invfile}, 0);
        defer gpa.free(member);
        if (readAny(mpqs.items, member.ptr)) |dc6| {
            defer gpa.free(dc6);
            const out = try std.fmt.allocPrint(gpa, "assets/items/{s}.dc6", .{invfile});
            defer gpa.free(out);
            try cwd.writeFile(io, .{ .sub_path = out, .data = dc6 });
            ok += 1;
        } else {
            miss += 1;
            std.debug.print("  miss: {s}\n", .{invfile});
        }
    }
    std.debug.print("extracted {d} item DC6s, {d} missing\n", .{ ok, miss });
}
