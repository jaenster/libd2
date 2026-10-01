//! extract_strings — pull the English string tables (string.tbl, expansionstring.tbl,
//! patchstring.tbl) out of a local 1.14d install into packages/data/src/strings/, layered
//! the way the retail loader does: Patch_D2 > d2exp > d2data.
//!
//! Build + run (StormLib via brew):
//!   SL=/opt/homebrew/opt/stormlib
//!   zig build-exe tools/extract_strings.zig -O ReleaseSafe -lc -lstorm -lz -lbz2 \
//!       -I"$SL/include" -L"$SL/lib" -femit-bin=tools/extract_strings
//!   D2_MPQ_DIR=/path/to/114d ./tools/extract_strings
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

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const dir = if (getenv("D2_MPQ_DIR")) |z| std.mem.span(z) else "/Users/jaenster/code/d2-clean-114d";

    const mpq_names = [_][]const u8{ "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq" };
    var mpqs: std.ArrayList(HANDLE) = .empty;
    for (mpq_names) |mn| {
        const p = try std.fs.path.joinZ(gpa, &.{ dir, mn });
        var h: HANDLE = null;
        if (SFileOpenArchive(p.ptr, 0, 0, &h)) try mpqs.append(gpa, h);
    }
    try cwd.createDirPath(io, "src/strings");
    const names = [_][]const u8{ "string", "expansionstring", "patchstring" };
    for (names) |n| {
        const member = try std.fmt.allocPrintSentinel(gpa, "data\\local\\lng\\eng\\{s}.tbl", .{n}, 0);
        var found: ?[]u8 = null;
        for (mpqs.items) |m| if (readMember(m, member.ptr)) |b| {
            found = b;
            break;
        };
        const b = found orelse {
            std.debug.print("missing {s}\n", .{n});
            continue;
        };
        const out = try std.fmt.allocPrint(gpa, "src/strings/{s}.tbl", .{n});
        try cwd.writeFile(io, .{ .sub_path = out, .data = b });
        std.debug.print("{s} {d} bytes\n", .{ out, b.len });
    }
}
