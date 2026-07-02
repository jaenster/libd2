//! DT1 pixel decoder — the companion to dt1.zig (which keeps only identity +
//! collision flags). This one reads the tile PIXEL blocks so we can materialize
//! the real game tile art. Two block encodings exist:
//!
//!   format == 1  "3D isometric" floor/roof block: exactly 256 raw palette
//!                bytes laid out as 15 scanlines of widths 4,8,12,16,20,24,28,
//!                32,28,24,20,16,12,8,4 (left-padded per xjump). No transparency
//!                inside the diamond; index 0 is still treated as transparent.
//!   format == 0  RLE block (walls & everything else), 32x32 max: a stream of
//!                {xjump, run, run raw bytes}; a (0,0) pair ends the current
//!                scanline. Index 0 = transparent.
//!
//! Layout facts (DT1 v7.6, Paul Siramy / d2mods.info KB):
//!   tile header (96 bytes): +0x00 direction, +0x04 i16 roofY, +0x08 i32 height
//!     (negative), +0x0C i32 width, +0x14 orientation, +0x18 main, +0x1C sub,
//!     +0x20 rarity, +0x48 i32 blockHeadersPointer (file offset), +0x50 i32
//!     numBlocks.
//!   block header (20 bytes): +0x00 i16 x, +0x02 i16 y, +0x06 u8 gridX,
//!     +0x07 u8 gridY, +0x08 i16 format, +0x0A i32 length, +0x10 i32 fileOffset
//!     (relative to the tile's blockHeadersPointer).

const std = @import("std");

const ISO_XJUMP = [15]u8{ 14, 12, 10, 8, 6, 4, 2, 0, 2, 4, 6, 8, 10, 12, 14 };
const ISO_NBPIX = [15]u8{ 4, 8, 12, 16, 20, 24, 28, 32, 28, 24, 20, 16, 12, 8, 4 };

pub const Block = struct {
    x: i16,
    y: i16,
    format: i16,
    length: i32,
    file_off: i32,
};

pub const PixTile = struct {
    orientation: i32,
    main: i32,
    sub: i32,
    rarity: i32,
    width: i32,
    height: i32, // stored raw (negative in file for floors/walls)
    /// DT1 tile header +0x04 (i16): the roof/dome vertical lift in pixels. The
    /// engine (DRAW_WORLD_Roofs 0x4dea70) draws roof tiles at nScreenY - roofY,
    /// so an orientation-15 roof/dome — whose block pixels are authored at FLOOR
    /// level (block.y ~ 0..96, NOT elevated) — is raised onto the building by
    /// this term. Zero for floors and walls (walls rise via their own negative
    /// block.y instead). This is the per-tile vertical-Z term.
    roof_y: i32,
    block_headers_ptr: usize,
    blocks: []Block,
};

pub const Dt1Pix = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8, // borrowed: the raw DT1 file
    tiles: []PixTile,

    pub fn deinit(self: *Dt1Pix) void {
        for (self.tiles) |t| self.allocator.free(t.blocks);
        self.allocator.free(self.tiles);
    }

    /// First tile matching (orientation, main, sub). Rarity variants share
    /// identity; the first is fine for a debug render.
    pub fn find(self: *const Dt1Pix, orientation: i32, main: i32, sub: i32) ?*const PixTile {
        for (self.tiles) |*t| {
            if (t.orientation == orientation and t.main == main and t.sub == sub) return t;
        }
        return null;
    }
};

const HEADER_NUMTILES_OFFSET = 0x10C;
const TILE_HEADER_SIZE = 96;
const BLOCK_HEADER_SIZE = 20;

fn readI32(bytes: []const u8, off: usize) !i32 {
    if (off + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(i32, bytes[off..][0..4], .little);
}
fn readI16(bytes: []const u8, off: usize) !i16 {
    if (off + 2 > bytes.len) return error.Truncated;
    return std.mem.readInt(i16, bytes[off..][0..2], .little);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Dt1Pix {
    const num_tiles = try readI32(bytes, HEADER_NUMTILES_OFFSET);
    const headers_off = try readI32(bytes, HEADER_NUMTILES_OFFSET + 4);
    if (num_tiles < 0 or headers_off < 0) return error.Corrupt;

    const count: usize = @intCast(num_tiles);
    const base: usize = @intCast(headers_off);
    if (base + count * TILE_HEADER_SIZE > bytes.len) return error.Truncated;

    const tiles = try allocator.alloc(PixTile, count);
    errdefer allocator.free(tiles);

    var built: usize = 0;
    errdefer for (tiles[0..built]) |t| allocator.free(t.blocks);

    for (tiles, 0..) |*t, i| {
        const o = base + i * TILE_HEADER_SIZE;
        t.orientation = try readI32(bytes, o + 0x14);
        t.main = try readI32(bytes, o + 0x18);
        t.sub = try readI32(bytes, o + 0x1C);
        t.rarity = try readI32(bytes, o + 0x20);
        t.height = try readI32(bytes, o + 0x08);
        t.width = try readI32(bytes, o + 0x0C);
        t.roof_y = try readI16(bytes, o + 0x04);
        const bhp: i32 = try readI32(bytes, o + 0x48);
        const nblk: i32 = try readI32(bytes, o + 0x50);
        t.block_headers_ptr = @intCast(@max(bhp, 0));
        const nb: usize = if (nblk > 0) @intCast(nblk) else 0;
        t.blocks = try allocator.alloc(Block, nb);
        built += 1;
        for (t.blocks, 0..) |*b, bi| {
            const bo = t.block_headers_ptr + bi * BLOCK_HEADER_SIZE;
            b.x = try readI16(bytes, bo + 0x00);
            b.y = try readI16(bytes, bo + 0x02);
            b.format = try readI16(bytes, bo + 0x08);
            b.length = try readI32(bytes, bo + 0x0A);
            b.file_off = try readI32(bytes, bo + 0x10);
        }
    }

    return .{ .allocator = allocator, .bytes = bytes, .tiles = tiles };
}

/// Tight pixel bounding box of a tile in tile-space (blocks are 32 wide; iso
/// blocks 15 tall, RLE blocks up to 32 tall).
pub const Bbox = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

pub fn tileBbox(t: *const PixTile) Bbox {
    var bb = Bbox{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    var any = false;
    for (t.blocks) |b| {
        const h: i32 = if (b.format == 1) 15 else 32;
        const bx0: i32 = b.x;
        const by0: i32 = b.y;
        const bx1: i32 = b.x + 32;
        const by1: i32 = b.y + h;
        if (!any) {
            bb = .{ .x0 = bx0, .y0 = by0, .x1 = bx1, .y1 = by1 };
            any = true;
        } else {
            bb.x0 = @min(bb.x0, bx0);
            bb.y0 = @min(bb.y0, by0);
            bb.x1 = @max(bb.x1, bx1);
            bb.y1 = @max(bb.y1, by1);
        }
    }
    if (!any) bb = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
    return bb;
}

pub const Rendered = struct {
    rgba: []u8,
    w: u32,
    h: u32,
    /// tile-space coord of the bitmap's top-left pixel (for screen anchoring).
    ox: i32,
    oy: i32,
};

/// Decode a tile into an RGBA bitmap tight to its block bounding box. `pal` is
/// the 768-byte act palette in B,G,R order (index 0 transparent).
pub fn renderTileAlloc(
    allocator: std.mem.Allocator,
    d: *const Dt1Pix,
    t: *const PixTile,
    pal: []const u8,
) !Rendered {
    const bb = tileBbox(t);
    const w: usize = @intCast(bb.x1 - bb.x0);
    const h: usize = @intCast(bb.y1 - bb.y0);
    const rgba = try allocator.alloc(u8, w * h * 4);
    @memset(rgba, 0);

    const put = struct {
        fn f(buf: []u8, bw: usize, bh: usize, px: i32, py: i32, idx: u8, palette: []const u8) void {
            if (idx == 0) return;
            if (px < 0 or py < 0) return;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            if (ux >= bw or uy >= bh) return;
            const pi = @as(usize, idx) * 3;
            if (pi + 2 >= palette.len) return;
            const off = (uy * bw + ux) * 4;
            buf[off + 0] = palette[pi + 2]; // R
            buf[off + 1] = palette[pi + 1]; // G
            buf[off + 2] = palette[pi + 0]; // B
            buf[off + 3] = 255;
        }
    }.f;

    for (t.blocks) |b| {
        const data_off: usize = t.block_headers_ptr + @as(usize, @intCast(@max(b.file_off, 0)));
        const len: usize = if (b.length > 0) @intCast(b.length) else 0;
        if (data_off + len > d.bytes.len) continue;
        const data = d.bytes[data_off .. data_off + len];
        const base_x = b.x - bb.x0;
        const base_y = b.y - bb.y0;

        if (b.format == 1) {
            // Isometric: 256 raw bytes, fixed diamond scanlines.
            if (data.len < 256) continue;
            var p: usize = 0;
            var row: usize = 0;
            while (row < 15) : (row += 1) {
                const xj: i32 = ISO_XJUMP[row];
                const n: usize = ISO_NBPIX[row];
                var col: usize = 0;
                while (col < n) : (col += 1) {
                    put(rgba, w, h, base_x + xj + @as(i32, @intCast(col)), base_y + @as(i32, @intCast(row)), data[p], pal);
                    p += 1;
                }
            }
        } else {
            // RLE scanline.
            var p: usize = 0;
            var x: i32 = 0;
            var y: i32 = 0;
            while (p + 1 < data.len) {
                const xjump = data[p];
                const run = data[p + 1];
                p += 2;
                if (xjump == 0 and run == 0) {
                    y += 1;
                    x = 0;
                    continue;
                }
                x += xjump;
                var k: usize = 0;
                while (k < run and p < data.len) : (k += 1) {
                    put(rgba, w, h, base_x + x, base_y + y, data[p], pal);
                    x += 1;
                    p += 1;
                }
            }
        }
    }

    return .{ .rgba = rgba, .w = @intCast(w), .h = @intCast(h), .ox = bb.x0, .oy = bb.y0 };
}

const testing = std.testing;

// Build a minimal in-memory DT1 with one iso block and one RLE block so the
// decoders are exercised deterministically (the checked-in src/maps DT1 fixtures
// are header-only — no pixel blocks — so a real DT1 is needed for a live test,
// and @embedFile can't read assets/tiles/ from here).
fn synthDt1(a: std.mem.Allocator, iso: bool) ![]u8 {
    const hdr_off: usize = 0x114;
    const tile_hdr = hdr_off; // one tile header at 0x114
    const bhp = tile_hdr + TILE_HEADER_SIZE; // block headers right after
    const pix_off_rel: usize = BLOCK_HEADER_SIZE; // pixel data after the 1 block header
    const pix_len: usize = if (iso) 256 else 6; // iso: 256 raw; rle: {0,4,a,b,c,d}
    const total = bhp + BLOCK_HEADER_SIZE + pix_len;
    const buf = try a.alloc(u8, total);
    @memset(buf, 0);
    std.mem.writeInt(i32, buf[HEADER_NUMTILES_OFFSET..][0..4], 1, .little);
    std.mem.writeInt(i32, buf[HEADER_NUMTILES_OFFSET + 4 ..][0..4], @intCast(hdr_off), .little);
    // tile header fields
    std.mem.writeInt(i32, buf[tile_hdr + 0x08 ..][0..4], -32, .little); // height
    std.mem.writeInt(i32, buf[tile_hdr + 0x0C ..][0..4], 64, .little); // width
    std.mem.writeInt(i32, buf[tile_hdr + 0x14 ..][0..4], 0, .little); // orientation
    std.mem.writeInt(i32, buf[tile_hdr + 0x18 ..][0..4], 3, .little); // main
    std.mem.writeInt(i32, buf[tile_hdr + 0x1C ..][0..4], 7, .little); // sub
    std.mem.writeInt(i32, buf[tile_hdr + 0x48 ..][0..4], @intCast(bhp), .little); // blockHeadersPointer
    std.mem.writeInt(i32, buf[tile_hdr + 0x50 ..][0..4], 1, .little); // numBlocks
    // block header
    std.mem.writeInt(i16, buf[bhp + 0x00 ..][0..2], 0, .little); // x
    std.mem.writeInt(i16, buf[bhp + 0x02 ..][0..2], 0, .little); // y
    std.mem.writeInt(i16, buf[bhp + 0x08 ..][0..2], if (iso) 1 else 0, .little); // format
    std.mem.writeInt(i32, buf[bhp + 0x0A ..][0..4], @intCast(pix_len), .little); // length
    std.mem.writeInt(i32, buf[bhp + 0x10 ..][0..4], @intCast(pix_off_rel), .little); // fileOffset
    const pix = buf[bhp + BLOCK_HEADER_SIZE ..];
    if (iso) {
        for (pix[0..256]) |*b| b.* = 1; // all index 1 -> opaque
    } else {
        // one scanline: xjump 0, run 4, then 4 index-1 pixels
        pix[0] = 0;
        pix[1] = 4;
        pix[2] = 1;
        pix[3] = 1;
        pix[4] = 1;
        pix[5] = 1;
    }
    return buf;
}

fn grayPal() [768]u8 {
    var pal: [768]u8 = undefined;
    for (0..256) |i| {
        pal[i * 3 + 0] = @intCast(i);
        pal[i * 3 + 1] = @intCast(i);
        pal[i * 3 + 2] = @intCast(i);
    }
    return pal;
}

fn opaqueCount(rgba: []const u8) usize {
    var n: usize = 0;
    var i: usize = 3;
    while (i < rgba.len) : (i += 4) {
        if (rgba[i] != 0) n += 1;
    }
    return n;
}

test "iso block decodes to 256 opaque pixels" {
    const bytes = try synthDt1(testing.allocator, true);
    defer testing.allocator.free(bytes);
    var d = try parse(testing.allocator, bytes);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 1), d.tiles.len);
    const t = d.find(0, 3, 7).?;
    const pal = grayPal();
    const r = try renderTileAlloc(testing.allocator, &d, t, &pal);
    defer testing.allocator.free(r.rgba);
    try testing.expectEqual(@as(usize, 256), opaqueCount(r.rgba));
}

test "RLE block decodes a 4-pixel run" {
    const bytes = try synthDt1(testing.allocator, false);
    defer testing.allocator.free(bytes);
    var d = try parse(testing.allocator, bytes);
    defer d.deinit();
    const t = d.find(0, 3, 7).?;
    const pal = grayPal();
    const r = try renderTileAlloc(testing.allocator, &d, t, &pal);
    defer testing.allocator.free(r.rgba);
    try testing.expectEqual(@as(usize, 4), opaqueCount(r.rgba));
}

test "parse a real-shaped header-only fixture without pixels" {
    const bytes = @embedFile("maps/Act1_Town_Floor.dt1");
    var d = try parse(testing.allocator, bytes);
    defer d.deinit();
    try testing.expect(d.tiles.len > 0);
    // Fixture is header-only: rendering a no-block tile yields a 1x1 empty bitmap.
    const pal = grayPal();
    const r = try renderTileAlloc(testing.allocator, &d, &d.tiles[0], &pal);
    defer testing.allocator.free(r.rgba);
    try testing.expect(r.w >= 1 and r.h >= 1);
}
