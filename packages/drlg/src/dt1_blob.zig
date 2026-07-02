//! Compact DT1 subtile-flag blob. dt1.parse already discards the pixel blocks and
//! keeps only each tile's identity (orientation/main/sub/rarity) + its 5x5 = 25
//! collision-flag bytes, so the whole 230-file DT1 set bakes into a small blob
//! (raw DT1s are ~134 MB; the flags are a fraction of a MB). Keyed by lowercased
//! rel path under assets/tiles/ — the same key form LvlTypes File columns use.
//!
//! The blob container (MAGIC / count / index / records) + compression + index
//! lookup are shared verbatim with ds1_blob; only the per-record payload differs.

const std = @import("std");
/// Re-exported so the generator (a separate build module) shares this exact dt1
/// module instance — keeping dt1.Dt1 one type across pack and unpack.
pub const dt1 = @import("d2-formats").dt1;
const ds1blob = @import("ds1_blob.zig");

pub const MAGIC = ds1blob.MAGIC;
pub const compress = ds1blob.compress;
pub const decompress = ds1blob.decompress;
pub const Index = ds1blob.Index;
pub const buildIndex = ds1blob.buildIndex;

const U8List = std.ArrayListUnmanaged(u8);

fn putU32(l: *U8List, a: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try l.appendSlice(a, &b);
}

/// Serialize one parsed DT1's tiles: count, then per tile
/// orientation/main/sub/rarity (i32 LE) + 25 flag bytes.
pub fn packRecord(l: *U8List, a: std.mem.Allocator, d: *const dt1.Dt1) !void {
    try putU32(l, a, @intCast(d.tiles.len));
    for (d.tiles) |t| {
        try putU32(l, a, @bitCast(t.orientation));
        try putU32(l, a, @bitCast(t.main));
        try putU32(l, a, @bitCast(t.sub));
        try putU32(l, a, @bitCast(t.rarity));
        try l.appendSlice(a, &t.flags);
    }
}

/// Rebuild a dt1.Dt1 (identity + flags only) from a record. Caller owns it (deinit).
pub fn unpack(a: std.mem.Allocator, rec: []const u8) !dt1.Dt1 {
    if (rec.len < 4) return error.BadBlob;
    var pos: usize = 0;
    const count = std.mem.readInt(u32, rec[0..4], .little);
    pos += 4;
    const tiles = try a.alloc(dt1.Tile, count);
    errdefer a.free(tiles);
    for (tiles) |*t| {
        if (pos + 16 + 25 > rec.len) return error.BadBlob;
        t.orientation = std.mem.readInt(i32, rec[pos..][0..4], .little);
        t.main = std.mem.readInt(i32, rec[pos + 4 ..][0..4], .little);
        t.sub = std.mem.readInt(i32, rec[pos + 8 ..][0..4], .little);
        t.rarity = std.mem.readInt(i32, rec[pos + 12 ..][0..4], .little);
        @memcpy(&t.flags, rec[pos + 16 ..][0..25]);
        pos += 16 + 25;
    }
    return .{ .allocator = a, .version_major = 0, .version_minor = 0, .tiles = tiles };
}
