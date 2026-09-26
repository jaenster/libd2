//! `sprite tiles`: DT1 floor and wall art out to indexed PNGs, decoded the way the D2OpenGL
//! renderer decodes them for its textures, so a key computed here is the key the renderer computes.
//!
//! Which path a tile takes is its orientation (DT1 tile header +0x14):
//!   0  floor, 15 roof     the ground-tile path: every block with (format & 1) into one 256x128
//!                         buffer (OGL_BindFloorTileTexture / OGL_DecodeFloorTileBlocks). Game.exe
//!                         draws both through D2GFX_DrawGroundTile: floors from DrawFloorTile
//!                         0x4de410, roofs from dRoofDraw 0x4dea70.
//!   1..14 walls, 13 shadow  each block on its own into a 32x32 buffer (OGL_BindWallBlockTexture),
//!                         bound per block by OGL_DrawWallTileBlocks and OGL_DrawShadowTile.
//! The block formats agree: floors and roofs carry 0x0001 (isometric) and 0x2005 (15-row RLE)
//! blocks, walls and shadows only 0x1001 (32-row RLE).
//!
//! A block header is the renderer's D2TileLibraryBlockStrc as the file stores it: +0 x, +2 y,
//! +8 format (bit 0 draw, bit 2 RLE, else an isometric diamond), +0x10 the data offset, relative
//! to the tile's block headers, which D2CMP turns into the pointer.

const std = @import("std");
const formats = @import("d2-formats");
const util = @import("d2-util");
const main = @import("main.zig");

const dt1pix = formats.dt1pix;
const framekey = util.framekey;
const pngx = util.png;

/// The renderer's floor buffer (non-AGP path) and the part of it a tile covers.
pub const floor_pitch: usize = 256;
pub const floor_rows: usize = 128;
pub const floor_w: u32 = 160;
pub const floor_h: u32 = 80;
pub const block_side: u32 = 32;

pub const DecodeError = error{ OutOfBuffer, ShortData };

/// One block: its position in the tile, its format, and its pixel data from the block's start to
/// the end of the file (the renderer reads until the rows end, not to a length).
pub const Block = struct {
    x: i16,
    y: i16,
    format: u16,
    pix: []const u8,
};

pub const Path = enum { floor, wall };

pub fn pathOf(orientation: i32) Path {
    return if (orientation == 0 or orientation == 15) .floor else .wall;
}

/// OGL_DecodeFloorTileBlocks into `dst`, `pitch` bytes per row, zeroed first. Rows advance by
/// the pitch, so a row that ran past it would continue on the next row as in the renderer; only
/// leaving `dst` is an error.
pub fn decodeFloor(dst: []u8, pitch: usize, blocks: []const Block) DecodeError!void {
    @memset(dst, 0);
    const ipitch: isize = @intCast(pitch);
    for (blocks) |b| {
        if (b.format & 1 == 0) continue;
        const offset: isize = @as(isize, b.y) * ipitch + b.x;
        var src: usize = 0;
        if (b.format & 4 == 0) {
            var d: isize = offset + 14;
            var len: usize = 4;
            for (0..15) |row| {
                try copy(dst, d, b.pix, src, len);
                src += len;
                if (row < 7) {
                    d += ipitch - 2;
                    len += 4;
                } else {
                    d += ipitch + 2;
                    len -= 4;
                }
            }
        } else {
            var row_start: isize = offset;
            for (0..15) |_| {
                src = try rleRow(dst, row_start, b.pix, src);
                row_start += ipitch;
            }
        }
    }
}

/// OGL_BindWallBlockTexture's decode: 32 RLE rows into a zeroed 32x32 buffer.
pub fn decodeWallBlock(dst: *[block_side * block_side]u8, pix: []const u8) DecodeError!void {
    @memset(dst, 0);
    var src: usize = 0;
    var row_start: isize = 0;
    for (0..block_side) |_| {
        src = try rleRow(dst, row_start, pix, src);
        row_start += block_side;
    }
}

/// One RLE row: (skip, count) pairs, (0, 0) ends it. Returns the source position after it.
fn rleRow(dst: []u8, row_start: isize, pix: []const u8, from: usize) DecodeError!usize {
    var src = from;
    var d = row_start;
    while (true) {
        if (src + 2 > pix.len) return error.ShortData;
        const skip = pix[src];
        const count = pix[src + 1];
        src += 2;
        if (skip == 0 and count == 0) return src;
        d += skip;
        try copy(dst, d, pix, src, count);
        src += count;
        d += count;
    }
}

fn copy(dst: []u8, at: isize, pix: []const u8, src: usize, len: usize) DecodeError!void {
    if (src + len > pix.len) return error.ShortData;
    if (at < 0 or @as(usize, @intCast(at)) + len > dst.len) return error.OutOfBuffer;
    const a: usize = @intCast(at);
    @memcpy(dst[a..][0..len], pix[src..][0..len]);
}

/// A floor or roof tile as the 160x80 image: the renderer's 256x128 buffer cropped. Fails if any
/// index lies outside the crop, since the image would then key differently from the buffer.
pub fn floorImage(gpa: std.mem.Allocator, blocks: []const Block) ![]u8 {
    var buf: [floor_pitch * floor_rows]u8 = undefined;
    try decodeFloor(&buf, floor_pitch, blocks);
    for (0..floor_rows) |y| {
        const row = buf[y * floor_pitch ..][0..floor_pitch];
        const lim: usize = if (y < floor_h) floor_w else 0;
        if (std.mem.findNone(u8, row[lim..], &.{0}) != null) return error.OutsideFloorImage;
    }
    const out = try gpa.alloc(u8, floor_w * floor_h);
    for (0..floor_h) |y| @memcpy(out[y * floor_w ..][0..floor_w], buf[y * floor_pitch ..][0..floor_w]);
    return out;
}

pub const Rect = struct { x: u32, y: u32, w: u32 = block_side, h: u32 = block_side };

pub const Wall = struct {
    /// Tile-space position of the image's top-left.
    x0: i32,
    y0: i32,
    w: u32,
    h: u32,
    px: []u8,
    rects: []Rect,
    /// Each block's own 32x32 decode keyed, as the renderer keys it.
    keys: []framekey.Key,
};

/// A wall tile assembled from its blocks at their positions. Blocks must not overlap: a block's
/// rect in the image is then exactly its own decode, which is what lets hdpack cut it back out.
pub fn wallImage(gpa: std.mem.Allocator, blocks: []const Block) !Wall {
    if (blocks.len == 0) return error.NoBlocks;
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (blocks) |b| {
        x0 = @min(x0, b.x);
        y0 = @min(y0, b.y);
        x1 = @max(x1, @as(i32, b.x) + block_side);
        y1 = @max(y1, @as(i32, b.y) + block_side);
    }
    const w: u32 = @intCast(x1 - x0);
    const h: u32 = @intCast(y1 - y0);
    const px = try gpa.alloc(u8, @as(usize, w) * h);
    @memset(px, 0);
    const covered = try gpa.alloc(bool, px.len);
    defer gpa.free(covered);
    @memset(covered, false);
    const rects = try gpa.alloc(Rect, blocks.len);
    const keys = try gpa.alloc(framekey.Key, blocks.len);
    var one: [block_side * block_side]u8 = undefined;
    for (blocks, 0..) |b, i| {
        try decodeWallBlock(&one, b.pix);
        keys[i] = try framekey.compute(&one, block_side, block_side, block_side);
        const r: Rect = .{ .x = @intCast(@as(i32, b.x) - x0), .y = @intCast(@as(i32, b.y) - y0) };
        rects[i] = r;
        for (0..block_side) |y| {
            const at = (r.y + y) * w + r.x;
            for (covered[at..][0..block_side]) |*c| {
                if (c.*) return error.OverlappingBlocks;
                c.* = true;
            }
            @memcpy(px[at..][0..block_side], one[y * block_side ..][0..block_side]);
        }
    }
    return .{ .x0 = x0, .y0 = y0, .w = w, .h = h, .px = px, .rects = rects, .keys = keys };
}

/// A tile's blocks with their data, from `dt1pix`'s parse of `bytes`.
pub fn blocksOf(gpa: std.mem.Allocator, bytes: []const u8, t: *const dt1pix.PixTile) ![]Block {
    const out = try gpa.alloc(Block, t.blocks.len);
    for (t.blocks, out) |b, *o| {
        if (b.file_off < 0) return error.ShortData;
        const at = t.block_headers_ptr + @as(usize, @intCast(b.file_off));
        if (at > bytes.len) return error.ShortData;
        o.* = .{ .x = b.x, .y = b.y, .format = @bitCast(b.format), .pix = bytes[at..] };
    }
    return out;
}

// ---- manifest -------------------------------------------------------------------------------

pub const BlockDoc = struct {
    /// The block's rect in the wall image.
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// The block's own position in the tile (DT1 block header +0, +2).
    posX: i16,
    posY: i16,
    format: u16,
    /// framekey of the block's 32x32 decode, 16 hex digits; "" when it has no non-zero index.
    key: []const u8,
};

pub const TileDoc = struct {
    index: u32,
    /// "floor" (orientations 0 and 15) or "wall" (everything else).
    kind: []const u8,
    orientation: i32,
    main: i32,
    sub: i32,
    rarity: i32,
    /// Tile-space position of the image's top-left.
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    png: []const u8,
    /// Floors: framekey of the image; "" when it has no non-zero index.
    key: ?[]const u8 = null,
    /// Walls: every block, in file order.
    blocks: ?[]const BlockDoc = null,
};

pub const Dt1Doc = struct {
    name: []const u8,
    kind: []const u8 = "dt1",
    /// The factor the PNGs were written at; always 1.
    scale: u32 = 1,
    tiles: []const TileDoc,
};

pub fn keyHex(gpa: std.mem.Allocator, k: framekey.Key) ![]const u8 {
    if (k.key == 0 and k.box.w == 0) return "";
    return std.fmt.allocPrint(gpa, "{x:0>16}", .{k.key});
}

pub const Counts = struct {
    members: usize = 0,
    /// Members that are not DT1 v7.6 (1.14d still ships a few v4.1 leftovers the game never loads).
    skipped: usize = 0,
    failed_members: usize = 0,
    floors: usize = 0,
    walls: usize = 0,
    wall_blocks: usize = 0,
    /// Tiles with no blocks: nothing to draw.
    no_blocks: usize = 0,
    failed_tiles: usize = 0,
};

/// One DT1: its images under `dir`, its manifest entry returned (PNG paths relative to the root).
fn member(c: *main.Ctx, name: []const u8, root: []const u8, pal: *const main.Palette, n: *Counts) ![]u8 {
    const gpa = c.gpa;
    const bytes = try (try c.source_()).read(gpa, name);
    if (bytes.len < 8 or std.mem.readInt(i32, bytes[0..4], .little) != 7 or std.mem.readInt(i32, bytes[4..8], .little) != 6) return error.NotV76;
    var d = try dt1pix.parse(gpa, bytes);
    var docs: std.ArrayListUnmanaged(TileDoc) = .empty;
    for (d.tiles, 0..) |*t, i| {
        if (t.blocks.len == 0) {
            n.no_blocks += 1;
            continue;
        }
        const blocks = try blocksOf(gpa, bytes, t);
        var doc: TileDoc = .{
            .index = @intCast(i),
            .kind = @tagName(pathOf(t.orientation)),
            .orientation = t.orientation,
            .main = t.main,
            .sub = t.sub,
            .rarity = t.rarity,
            .x = 0,
            .y = 0,
            .w = 0,
            .h = 0,
            .png = "",
        };
        const png = switch (pathOf(t.orientation)) {
            .floor => blk: {
                const px = floorImage(gpa, blocks) catch |e| {
                    std.debug.print("sprite: {s} tile {d}: {s}\n", .{ name, i, @errorName(e) });
                    n.failed_tiles += 1;
                    continue;
                };
                doc.w = floor_w;
                doc.h = floor_h;
                doc.key = try keyHex(gpa, try framekey.compute(px, floor_w, floor_h, floor_w));
                doc.png = try std.fmt.allocPrint(gpa, "{s}/f{d:0>4}.png", .{ name, i });
                n.floors += 1;
                break :blk try pngx.encodeIndexed(gpa, px, floor_w, floor_h, &pal.rgb);
            },
            .wall => blk: {
                const wall = wallImage(gpa, blocks) catch |e| {
                    std.debug.print("sprite: {s} tile {d}: {s}\n", .{ name, i, @errorName(e) });
                    n.failed_tiles += 1;
                    continue;
                };
                const bd = try gpa.alloc(BlockDoc, blocks.len);
                for (blocks, wall.rects, wall.keys, bd) |b, r, k, *o| o.* = .{
                    .x = r.x,
                    .y = r.y,
                    .w = r.w,
                    .h = r.h,
                    .posX = b.x,
                    .posY = b.y,
                    .format = b.format,
                    .key = try keyHex(gpa, k),
                };
                doc.x = wall.x0;
                doc.y = wall.y0;
                doc.w = wall.w;
                doc.h = wall.h;
                doc.blocks = bd;
                doc.png = try std.fmt.allocPrint(gpa, "{s}/w{d:0>4}.png", .{ name, i });
                n.walls += 1;
                n.wall_blocks += blocks.len;
                break :blk try pngx.encodeIndexed(gpa, wall.px, wall.w, wall.h, &pal.rgb);
            },
        };
        try c.writeFile(try std.fs.path.join(gpa, &.{ root, doc.png }), png);
        try docs.append(gpa, doc);
    }
    d.deinit();
    const out: Dt1Doc = .{ .name = name, .tiles = docs.items };
    return std.json.Stringify.valueAlloc(gpa, out, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

/// `sprite tiles --match GLOB --out DIR [--palette P] [--manifest FILE]`.
pub fn cmd(c: *main.Ctx) !void {
    const root = try c.args.need("out");
    _ = try c.args.need("match");
    const names = try main.matching(c, "**");
    const pal = try main.loadPalette(c);
    const outer = c.gpa;

    var n: Counts = .{};
    var manifest: std.ArrayListUnmanaged(u8) = .empty;
    try manifest.appendSlice(outer, "[\n");
    var done: usize = 0;
    for (names) |name| {
        if (!std.ascii.endsWithIgnoreCase(name, ".dt1")) continue;
        n.members += 1;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        c.gpa = arena.allocator();
        defer c.gpa = outer;
        const json = member(c, name, root, &pal, &n) catch |e| switch (e) {
            error.NotV76 => {
                std.debug.print("sprite: {s}: not a v7.6 DT1, skipped\n", .{name});
                n.skipped += 1;
                continue;
            },
            else => {
                std.debug.print("sprite: {s}: {s}\n", .{ name, @errorName(e) });
                n.failed_members += 1;
                continue;
            },
        };
        if (done > 0) try manifest.appendSlice(outer, ",\n");
        try manifest.appendSlice(outer, json);
        done += 1;
    }
    try manifest.appendSlice(outer, "\n]\n");
    const mpath = c.args.get("manifest") orelse try std.fs.path.join(outer, &.{ root, "manifest.json" });
    try c.writeFile(mpath, manifest.items);
    std.debug.print(
        "sprite: {d} DT1s ({d} skipped, {d} failed): {d} floor images, {d} wall images, {d} wall blocks, {d} tiles without blocks, {d} tiles failed\n",
        .{ n.members, n.skipped, n.failed_members, n.floors, n.walls, n.wall_blocks, n.no_blocks, n.failed_tiles },
    );
    if (n.failed_members + n.failed_tiles > 0) return error.Failed;
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// RLE-encode a `w`-wide, `rows`-tall image the way DT1 stores it: per row, (skip, count) runs of
/// non-zero indices, then (0, 0).
pub fn encodeRle(gpa: std.mem.Allocator, px: []const u8, w: usize, rows: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (0..rows) |y| {
        const row = px[y * w ..][0..w];
        var x: usize = 0;
        var last: usize = 0;
        while (x < w) {
            if (row[x] == 0) {
                x += 1;
                continue;
            }
            var e = x;
            while (e < w and row[e] != 0) e += 1;
            try out.appendSlice(gpa, &.{ @intCast(x - last), @intCast(e - x) });
            try out.appendSlice(gpa, row[x..e]);
            last = e;
            x = e;
        }
        try out.appendSlice(gpa, &.{ 0, 0 });
    }
    return out.toOwnedSlice(gpa);
}

fn isoBlock() [256]u8 {
    var pix: [256]u8 = undefined;
    for (&pix, 0..) |*p, i| p.* = @intCast(1 + i % 255);
    return pix;
}

test "an isometric block lands on the diamond, row by row" {
    const pix = isoBlock();
    const blocks = [_]Block{.{ .x = 32, .y = 16, .format = 0x0001, .pix = &pix }};
    const img = try floorImage(testing.allocator, &blocks);
    defer testing.allocator.free(img);
    const xjump = [15]u32{ 14, 12, 10, 8, 6, 4, 2, 0, 2, 4, 6, 8, 10, 12, 14 };
    var src: usize = 0;
    var set: usize = 0;
    for (0..15) |r| {
        const n: usize = 32 - 2 * xjump[r];
        for (0..n) |col| {
            try testing.expectEqual(pix[src], img[(16 + r) * floor_w + 32 + xjump[r] + col]);
            src += 1;
        }
    }
    for (img) |p| set += @intFromBool(p != 0);
    try testing.expectEqual(@as(usize, 256), set);
}

test "RLE floor and wall blocks decode back to the image they were built from" {
    const gpa = testing.allocator;
    // A 32-wide, 15-row floor block and a 32x32 wall block with holes, runs at both edges and a
    // row that is all transparent.
    var floor: [32 * 15]u8 = undefined;
    for (&floor, 0..) |*p, i| p.* = if ((i / 3) % 4 == 1 or i % 32 == 0 or i % 32 == 31) 0 else @intCast(i % 200 + 7);
    @memset(floor[5 * 32 ..][0..32], 0);
    const enc_floor = try encodeRle(gpa, &floor, 32, 15);
    defer gpa.free(enc_floor);
    const fb = [_]Block{.{ .x = 64, .y = 48, .format = 0x2005, .pix = enc_floor }};
    const img = try floorImage(gpa, &fb);
    defer gpa.free(img);
    for (0..15) |y| try testing.expectEqualSlices(u8, floor[y * 32 ..][0..32], img[(48 + y) * floor_w + 64 ..][0..32]);

    var wall: [32 * 32]u8 = undefined;
    for (&wall, 0..) |*p, i| p.* = if ((i * 7) % 11 < 4) 0 else @intCast(i % 250 + 1);
    @memset(wall[31 * 32 ..][0..32], 0);
    const enc_wall = try encodeRle(gpa, &wall, 32, 32);
    defer gpa.free(enc_wall);
    var got: [32 * 32]u8 = undefined;
    try decodeWallBlock(&got, enc_wall);
    try testing.expectEqualSlices(u8, &wall, &got);
    // The renderer reads exactly the rows; a stream cut short is an error, not a guess.
    try testing.expectError(error.ShortData, decodeWallBlock(&got, enc_wall[0 .. enc_wall.len - 2]));
}

test "a floor's 160x80 image has the key of the renderer's 256x128 buffer" {
    const gpa = testing.allocator;
    const pix = isoBlock();
    var rle_src: [32 * 15]u8 = undefined;
    for (&rle_src, 0..) |*p, i| p.* = if (i % 5 == 0) 0 else @intCast(i % 97 + 3);
    const rle = try encodeRle(gpa, &rle_src, 32, 15);
    defer gpa.free(rle);
    const blocks = [_]Block{
        .{ .x = 0, .y = 32, .format = 0x0001, .pix = &pix },
        .{ .x = 128, .y = 32, .format = 0x0001, .pix = &pix },
        .{ .x = 64, .y = 0, .format = 0x2005, .pix = rle },
        .{ .x = 64, .y = 64, .format = 0x0001, .pix = &pix },
        // Not drawn (bit 0 clear): must not reach either buffer.
        .{ .x = 32, .y = 16, .format = 0x0000, .pix = &pix },
    };
    const img = try floorImage(gpa, &blocks);
    defer gpa.free(img);
    const offline = try framekey.compute(img, floor_w, floor_h, floor_w);

    const buf = try gpa.alloc(u8, floor_pitch * floor_rows);
    defer gpa.free(buf);
    @memset(buf, 0xAA); // the renderer zeroes it first; so must the decode
    try decodeFloor(buf, floor_pitch, &blocks);
    const renderer = try framekey.compute(buf, floor_pitch, floor_rows, floor_pitch);
    try testing.expect(offline.key != 0);
    try testing.expectEqual(renderer.key, offline.key);
    try testing.expectEqual(renderer.box, offline.box);
    try testing.expectEqual(framekey.Box{ .x0 = 0, .y0 = 0, .w = 160, .h = 79 }, offline.box);
}

test "a wall is its blocks at their positions, each block's key its own decode" {
    const gpa = testing.allocator;
    var a: [32 * 32]u8 = undefined;
    var b: [32 * 32]u8 = undefined;
    for (&a, &b, 0..) |*p, *q, i| {
        p.* = if (i % 3 == 0) 0 else 10;
        q.* = if (i % 32 < 16) 0 else 20;
    }
    const ea = try encodeRle(gpa, &a, 32, 32);
    defer gpa.free(ea);
    const eb = try encodeRle(gpa, &b, 32, 32);
    defer gpa.free(eb);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const blocks = [_]Block{
        .{ .x = 32, .y = -96, .format = 0x1001, .pix = ea },
        .{ .x = 64, .y = -32, .format = 0x1001, .pix = eb },
    };
    const w = try wallImage(arena.allocator(), &blocks);
    try testing.expectEqual(@as(i32, 32), w.x0);
    try testing.expectEqual(@as(i32, -96), w.y0);
    try testing.expectEqual(@as(u32, 64), w.w);
    try testing.expectEqual(@as(u32, 96), w.h);
    try testing.expectEqual(Rect{ .x = 0, .y = 0 }, w.rects[0]);
    try testing.expectEqual(Rect{ .x = 32, .y = 64 }, w.rects[1]);
    try testing.expectEqual(try framekey.compute(&b, 32, 32, 32), w.keys[1]);
    try testing.expectEqual(framekey.Box{ .x0 = 16, .y0 = 0, .w = 16, .h = 32 }, w.keys[1].box);
    for (0..32) |y| try testing.expectEqualSlices(u8, b[y * 32 ..][0..32], w.px[(64 + y) * 64 + 32 ..][0..32]);

    const overlap = [_]Block{ blocks[0], .{ .x = 48, .y = -96, .format = 0x1001, .pix = eb } };
    try testing.expectError(error.OverlappingBlocks, wallImage(arena.allocator(), &overlap));
}
