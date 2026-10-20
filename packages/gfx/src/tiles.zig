//! A DT1 as the renderer receives it: each 96-byte tile record is a tile library entry and each
//! 20-byte block header points at its pixels. And the two decodes the renderer makes textures from:
//! a floor or roof tile's blocks into one 256 x 128 index image (every block that is drawn, the
//! 15-row isometric diamond or the 15-row RLE), and a wall or shadow block on its own into 32 x 32.
//!
//! Record fields read (offsets in the 96-byte record): +0x00 direction (0..9), +0x04 i16 roof
//! height, +0x06 i16 flags (0x100: drawn at full light), +0x14 orientation, +0x18 main index,
//! +0x1C sub index, +0x48 the block headers' file offset, +0x50 the block count. Block header:
//! +0 i16 x, +2 i16 y, +6 grid x, +7 grid y, +8 i16 format (1: isometric, anything else RLE),
//! +0xA i32 length, +0x10 i32 data offset from the block headers.
const std = @import("std");

pub const Block = struct {
    x: i16,
    y: i16,
    /// The file's format word is 1 for an isometric diamond; every other block is RLE.
    iso: bool,
    px: []const u8,
};

pub const Tile = struct {
    direction: i32,
    roof_height: i16,
    flags: i16,
    orientation: i32,
    main: i32,
    sub: i32,
    blocks: []Block,

    /// Drawn at full light whatever the light map holds (lava; D2Client DrawFloorTile 0x4de410).
    pub fn fullLight(t: *const Tile) bool {
        return (@as(u16, @bitCast(t.flags)) & 0x100) != 0;
    }
};

pub const Library = struct {
    name: []const u8,
    tiles: []Tile,

    pub fn deinit(l: *Library, gpa: std.mem.Allocator) void {
        for (l.tiles) |t| gpa.free(t.blocks);
        gpa.free(l.tiles);
    }
};

pub const Error = error{ShortDt1} || std.mem.Allocator.Error;

fn int(comptime T: type, b: []const u8, off: usize) Error!T {
    if (off + @sizeOf(T) > b.len) return error.ShortDt1;
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

/// The library of a DT1's bytes, which it borrows.
pub fn load(gpa: std.mem.Allocator, name: []const u8, b: []const u8) Error!Library {
    const ntiles = try int(i32, b, 0x10c);
    const first = try int(i32, b, 0x110);
    if (ntiles < 0 or first < 0 or @as(usize, @intCast(first)) + @as(usize, @intCast(ntiles)) * 0x60 > b.len) return error.ShortDt1;
    const tiles = try gpa.alloc(Tile, @intCast(ntiles));
    var made: usize = 0;
    errdefer {
        for (tiles[0..made]) |t| gpa.free(t.blocks);
        gpa.free(tiles);
    }
    for (tiles, 0..) |*t, k| {
        const r = @as(usize, @intCast(first)) + k * 0x60;
        const headers = try int(i32, b, r + 0x48);
        const nblocks = try int(i32, b, r + 0x50);
        if (headers < 0 or nblocks < 0) return error.ShortDt1;
        const blocks = try gpa.alloc(Block, @intCast(nblocks));
        errdefer gpa.free(blocks);
        for (blocks, 0..) |*bl, j| {
            const h = @as(usize, @intCast(headers)) + j * 20;
            const len = try int(i32, b, h + 10);
            const data = try int(i32, b, h + 16);
            if (len < 0 or data < 0) return error.ShortDt1;
            const at = @as(usize, @intCast(headers)) + @as(usize, @intCast(data));
            if (at + @as(usize, @intCast(len)) > b.len) return error.ShortDt1;
            bl.* = .{
                .x = try int(i16, b, h),
                .y = try int(i16, b, h + 2),
                .iso = try int(i16, b, h + 8) == 1,
                .px = b[at..][0..@intCast(len)],
            };
        }
        t.* = .{
            .direction = try int(i32, b, r),
            .roof_height = try int(i16, b, r + 4),
            .flags = try int(i16, b, r + 6),
            .orientation = try int(i32, b, r + 0x14),
            .main = try int(i32, b, r + 0x18),
            .sub = try int(i32, b, r + 0x1c),
            .blocks = blocks,
        };
        made += 1;
    }
    return .{ .name = name, .tiles = tiles };
}

pub const floor_pitch = 256;
pub const floor_rows = 128;

/// A floor or roof tile's blocks into a 256 x 128 index image (zeroed first). A block's pixels
/// that run past the image are dropped.
pub fn decodeFloor(t: *const Tile, dest: *[floor_pitch * floor_rows]u8) void {
    @memset(dest, 0);
    for (t.blocks) |bl| {
        const ox: i32 = bl.x;
        const oy: i32 = bl.y;
        if (bl.iso) {
            // the diamond: 15 rows of 4, 8, .. 32, .. 8, 4 pixels, centred on the block's 32 columns
            var x: i32 = ox + 14;
            var y: i32 = oy;
            var n: usize = 4;
            var s: usize = 0;
            for (0..15) |row| {
                if (s + n > bl.px.len) break;
                put(dest, floor_pitch, floor_rows, x, y, bl.px[s..][0..n]);
                s += n;
                if (row < 7) {
                    x -= 2;
                    n += 4;
                } else {
                    x += 2;
                    n -= 4;
                }
                y += 1;
            }
        } else rle(dest, floor_pitch, floor_rows, ox, oy, 15, bl.px);
    }
}

/// A wall or shadow block on its own into 32 x 32 indices (32 RLE rows).
pub fn decodeBlock(bl: *const Block, dest: *[32 * 32]u8) void {
    @memset(dest, 0);
    rle(dest, 32, 32, 0, 0, 32, bl.px);
}

fn put(dest: []u8, pitch: usize, rows: usize, x: i32, y: i32, src: []const u8) void {
    if (y < 0 or y >= rows) return;
    for (src, 0..) |p, k| {
        const xx = x + @as(i32, @intCast(k));
        if (xx < 0 or xx >= pitch) continue;
        dest[@as(usize, @intCast(y)) * pitch + @as(usize, @intCast(xx))] = p;
    }
}

/// (skip, count) pairs with count pixels after each, (0, 0) ending a row.
fn rle(dest: []u8, pitch: usize, rows: usize, ox: i32, oy: i32, nrows: usize, src: []const u8) void {
    var s: usize = 0;
    var y: i32 = oy;
    for (0..nrows) |_| {
        var x: i32 = ox;
        while (s + 2 <= src.len) {
            const skip = src[s];
            const count = src[s + 1];
            s += 2;
            if (skip == 0 and count == 0) break;
            x += skip;
            const n = @min(@as(usize, count), src.len - s);
            put(dest, pitch, rows, x, y, src[s..][0..n]);
            s += n;
            x += count;
        }
        y += 1;
    }
}

test "the isometric diamond lands centred, row by row" {
    var px: [256]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i % 255 + 1);
    var blocks = [_]Block{.{ .x = 64, .y = 32, .iso = true, .px = &px }};
    const t: Tile = .{ .direction = 0, .roof_height = 0, .flags = 0, .orientation = 0, .main = 0, .sub = 0, .blocks = &blocks };
    var img: [floor_pitch * floor_rows]u8 = undefined;
    decodeFloor(&t, &img);
    // row 0: 4 pixels at x 64+14..64+17; row 7 the full 32 at 64..95
    try std.testing.expectEqual(@as(u8, 0), img[32 * 256 + 64 + 13]);
    try std.testing.expectEqual(@as(u8, 1), img[32 * 256 + 64 + 14]);
    try std.testing.expectEqual(@as(u8, 0), img[32 * 256 + 64 + 18]);
    try std.testing.expect(img[39 * 256 + 64] != 0 and img[39 * 256 + 95] != 0 and img[39 * 256 + 96] == 0);
}
