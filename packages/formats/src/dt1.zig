//! Parser for Diablo II `.dt1` tile-library files — the graphics + collision
//! data for the tiles a DS1 places. For the clean-room collision grid we only
//! need each tile's identity (orientation / mainIndex / subIndex / rarity) and
//! its 5x5 block of per-subtile collision flags; the pixel blocks are skipped.
//!
//! Header layout (version 7.6, the 1.14d format):
//!   0x000 i32 versionMajor (7)
//!   0x004 i32 versionMinor (6)
//!   0x008 .. 0x10C  unknown / zero padding (260 bytes)
//!   0x10C i32 numTiles
//!   0x110 i32 tileHeadersOffset
//! Each tile header is 96 bytes:
//!   +0x14 i32 orientation   +0x18 i32 mainIndex   +0x1C i32 subIndex
//!   +0x20 i32 rarityOrFrame +0x28 u8[25] subTileFlags
//!
//! Subtile flag bits (per the DT1 collision model): bit0 0x01 = block walk,
//! bit1 0x02 = block light / line-of-sight. Higher bits are used by specific
//! tile roles (jump/player-only walls) and are preserved raw.

const std = @import("std");

/// Collision-flag bits on a single subtile byte.
pub const SubtileFlag = struct {
    pub const block_walk: u8 = 0x01;
    pub const block_los: u8 = 0x02;
};

/// One tile-library entry. `flags[25]` is the 5x5 subtile collision block, in
/// file order: index = row*5 + col, row 0 = top. `orientation`/`main`/`sub`
/// are the identity a DS1 cell resolves against; `rarity` disambiguates when
/// several entries share that identity (weighted random pick at runtime).
pub const Tile = struct {
    orientation: i32,
    main: i32,
    sub: i32,
    rarity: i32,
    flags: [25]u8,

    /// Collision flags at subtile (sx, sy), sx/sy in 0..5. Returns 0 out of range.
    pub inline fn subtile(self: *const Tile, sx: usize, sy: usize) u8 {
        if (sx >= 5 or sy >= 5) return 0;
        return self.flags[sy * 5 + sx];
    }
};

pub const Dt1 = struct {
    allocator: std.mem.Allocator,
    version_major: i32,
    version_minor: i32,
    tiles: []Tile,

    pub fn deinit(self: *Dt1) void {
        self.allocator.free(self.tiles);
    }

    /// First tile matching (orientation, main, sub). When several share the
    /// identity (rarity variants) this returns the first; the runtime picks by
    /// weighted rarity, but for a walk/LOS mask the collision block is identical
    /// across floor/roof rarity variants, so the first is sufficient.
    pub fn find(self: *const Dt1, orientation: i32, main: i32, sub: i32) ?*const Tile {
        for (self.tiles) |*t| {
            if (t.orientation == orientation and t.main == main and t.sub == sub) return t;
        }
        return null;
    }
};

const HEADER_NUMTILES_OFFSET = 0x10C;
const TILE_HEADER_SIZE = 96;

fn readI32(bytes: []const u8, off: usize) !i32 {
    if (off + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(i32, bytes[off..][0..4], .little);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Dt1 {
    const version_major = try readI32(bytes, 0x00);
    const version_minor = try readI32(bytes, 0x04);
    const num_tiles = try readI32(bytes, HEADER_NUMTILES_OFFSET);
    const headers_off = try readI32(bytes, HEADER_NUMTILES_OFFSET + 4);
    if (num_tiles < 0 or headers_off < 0) return error.Corrupt;

    const count: usize = @intCast(num_tiles);
    const base: usize = @intCast(headers_off);
    if (base + count * TILE_HEADER_SIZE > bytes.len) return error.Truncated;

    const tiles = try allocator.alloc(Tile, count);
    errdefer allocator.free(tiles);

    for (tiles, 0..) |*t, i| {
        const o = base + i * TILE_HEADER_SIZE;
        t.orientation = try readI32(bytes, o + 0x14);
        t.main = try readI32(bytes, o + 0x18);
        t.sub = try readI32(bytes, o + 0x1C);
        t.rarity = try readI32(bytes, o + 0x20);
        @memcpy(&t.flags, bytes[o + 0x28 ..][0..25]);
    }

    return .{
        .allocator = allocator,
        .version_major = version_major,
        .version_minor = version_minor,
        .tiles = tiles,
    };
}

const testing = std.testing;

test "parse town floor DT1 header + subtile flags" {
    const bytes = @embedFile("maps/Act1_Town_Floor.dt1");
    var d = try parse(testing.allocator, bytes);
    defer d.deinit();

    try testing.expectEqual(@as(i32, 7), d.version_major);
    try testing.expectEqual(@as(i32, 6), d.version_minor);
    try testing.expectEqual(@as(usize, 144), d.tiles.len);

    // Tile 0: plain floor (orient 0), fully walkable.
    try testing.expectEqual(@as(i32, 0), d.tiles[0].orientation);
    for (d.tiles[0].flags) |f| try testing.expectEqual(@as(u8, 0), f);

    // A blocking floor variant exists in this library.
    var any_block = false;
    for (d.tiles) |t| {
        for (t.flags) |f| {
            if (f & SubtileFlag.block_walk != 0) any_block = true;
        }
    }
    try testing.expect(any_block);
}
