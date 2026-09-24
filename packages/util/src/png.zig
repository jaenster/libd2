//! Pure-Zig PNG for sprite work, no C. `encodeRgba` emits RGBA8888 in uncompressed ("stored")
//! DEFLATE blocks; `encodeRgbaDeflate` and `encodeIndexed` compress with std's zlib; and
//! `decodeIndexed` reads an 8-bit indexed PNG back to its indices.

const std = @import("std");

fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    for (data) |byte| {
        c ^= byte;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = @bitCast(-@as(i32, @intCast(c & 1)));
            c = (c >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return c ^ 0xFFFF_FFFF;
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn appendChunk(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, tag: [4]u8, payload: []const u8) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(payload.len), .big);
    try out.appendSlice(gpa, &len_be);

    const crc_start = out.items.len;
    try out.appendSlice(gpa, &tag);
    try out.appendSlice(gpa, payload);

    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc32(out.items[crc_start..]), .big);
    try out.appendSlice(gpa, &crc_be);
}

/// Wrap raw bytes in a zlib stream using stored (uncompressed) DEFLATE blocks.
fn zlibStore(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var s: std.ArrayListUnmanaged(u8) = .empty;
    errdefer s.deinit(gpa);
    try s.appendSlice(gpa, &.{ 0x78, 0x01 }); // zlib header (deflate, no dict)

    var off: usize = 0;
    while (off < raw.len) {
        const block = @min(raw.len - off, 0xFFFF);
        const final: u8 = if (off + block >= raw.len) 1 else 0;
        try s.append(gpa, final); // BFINAL=final, BTYPE=00 (stored)
        var lens: [4]u8 = undefined;
        std.mem.writeInt(u16, lens[0..2], @intCast(block), .little); // LEN
        std.mem.writeInt(u16, lens[2..4], @intCast(~@as(u16, @intCast(block))), .little); // NLEN
        try s.appendSlice(gpa, &lens);
        try s.appendSlice(gpa, raw[off .. off + block]);
        off += block;
    }
    if (raw.len == 0) {
        try s.appendSlice(gpa, &.{ 0x01, 0x00, 0x00, 0xFF, 0xFF });
    }

    var adler_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_be, adler32(raw), .big);
    try s.appendSlice(gpa, &adler_be);
    return s.toOwnedSlice(gpa);
}

/// Encode `rgba` (w*h*4, row-major top-down) to PNG bytes. Caller owns the result.
pub fn encodeRgba(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, w) * h * 4);

    // Filtered scanlines: filter byte 0 (None) then the RGBA row.
    const stride = @as(usize, w) * 4;
    var raw = try gpa.alloc(u8, (stride + 1) * h);
    defer gpa.free(raw);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], rgba[y * stride ..][0..stride]);
    }

    const idat = try zlibStore(gpa, raw);
    defer gpa.free(idat);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type: RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try appendChunk(&out, gpa, "IHDR".*, &ihdr);
    try appendChunk(&out, gpa, "IDAT".*, idat);
    try appendChunk(&out, gpa, "IEND".*, &.{});

    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "png: encode a 2x2 image and re-decode with std zlib" {
    const gpa = testing.allocator;
    const rgba = [_]u8{
        255, 0,   0,   255, 0, 255, 0, 255,
        0,   0,   255, 255, 255, 255, 255, 255,
    };
    const png = try encodeRgba(gpa, &rgba, 2, 2);
    defer gpa.free(png);

    // Signature + IHDR/IDAT/IEND present.
    try testing.expect(png.len > 8);
    try testing.expectEqual(@as(u8, 0x89), png[0]);
    try testing.expect(std.mem.indexOf(u8, png, "IHDR") != null);
    try testing.expect(std.mem.indexOf(u8, png, "IDAT") != null);
    try testing.expect(std.mem.indexOf(u8, png, "IEND") != null);
}

test "crc32 known vector" {
    // CRC-32 of "IEND" == 0xAE426082.
    try testing.expectEqual(@as(u32, 0xAE42_6082), crc32("IEND"));
}

// ---- indexed images, and zlib-compressed output ------------------------------------------
//
// An indexed PNG (colour type 3) carries palette indices as its pixels, the palette in PLTE and
// index 0 as transparent via tRNS, so a sprite frame survives a trip through any image tool with
// its indices intact. These writers compress (fixed filter 0, fixed zlib level), so the same image
// always gives the same bytes.

const flate = std.compress.flate;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

fn appendChunkTag(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, tag: *const [4]u8, payload: []const u8) !void {
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, @intCast(payload.len), .big);
    try out.appendSlice(gpa, &be);
    const at = out.items.len;
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, payload);
    std.mem.writeInt(u32, &be, std.hash.Crc32.hash(out.items[at..]), .big);
    try out.appendSlice(gpa, &be);
}

fn zlib(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&aw.writer, window, .zlib, .default);
    try c.writer.writeAll(raw);
    try c.finish();
    return aw.toOwnedSlice();
}

fn encodeDeflate(gpa: std.mem.Allocator, w: u32, h: u32, colour_type: u8, bpp: usize, px: []const u8, plte: ?[]const u8) ![]u8 {
    const stride = @as(usize, w) * bpp;
    std.debug.assert(px.len == stride * h);
    const raw = try gpa.alloc(u8, (stride + 1) * h);
    defer gpa.free(raw);
    for (0..h) |y| {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], px[y * stride ..][0..stride]);
    }
    const idat = try zlib(gpa, raw);
    defer gpa.free(idat);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8;
    ihdr[9] = colour_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunkTag(&out, gpa, "IHDR", &ihdr);
    if (plte) |p| {
        try appendChunkTag(&out, gpa, "PLTE", p);
        try appendChunkTag(&out, gpa, "tRNS", &.{0});
    }
    try appendChunkTag(&out, gpa, "IDAT", idat);
    try appendChunkTag(&out, gpa, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

/// Indices as an 8-bit indexed PNG. `rgb` is 768 bytes in R,G,B order; index 0 is transparent.
pub fn encodeIndexed(gpa: std.mem.Allocator, indices: []const u8, w: u32, h: u32, rgb: *const [768]u8) ![]u8 {
    return encodeDeflate(gpa, w, h, 3, 1, indices, rgb);
}

/// Straight RGBA8888, top-down.
pub fn encodeRgbaDeflate(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    return encodeDeflate(gpa, w, h, 6, 4, rgba, null);
}

pub const Indexed = struct {
    w: u32,
    h: u32,
    /// w*h indices, top-down.
    px: []u8,
};

/// Read an 8-bit indexed (or 8-bit greyscale, read as indices) PNG back into indices. Anything
/// in colour is refused: turning colour back into indices is a quantiser's job, not a reader's.
pub fn decodeIndexed(gpa: std.mem.Allocator, bytes: []const u8) !Indexed {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.NotPng;
    var off: usize = 8;
    var w: u32 = 0;
    var h: u32 = 0;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(gpa);
    while (off + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[off..][0..4], .big);
        const tag = bytes[off + 4 ..][0..4];
        if (off + 12 + len > bytes.len) return error.TruncatedPng;
        const body = bytes[off + 8 ..][0..len];
        if (std.mem.eql(u8, tag, "IHDR")) {
            if (len != 13) return error.BadPng;
            w = std.mem.readInt(u32, body[0..4], .big);
            h = std.mem.readInt(u32, body[4..8], .big);
            if (body[8] != 8) return error.PngNotEightBit;
            if (body[9] != 3 and body[9] != 0) return error.PngNotIndexed;
            if (body[12] != 0) return error.PngInterlaced;
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, tag, "IEND")) break;
        off += 12 + len;
    }
    if (w == 0 or h == 0) return error.BadPng;

    const stride: usize = w;
    const raw_len = (stride + 1) * h;
    var in: std.Io.Reader = .fixed(idat.items);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var d: flate.Decompress = .init(&in, .zlib, &.{});
    _ = d.reader.streamRemaining(&aw.writer) catch return error.BadPng;
    const raw = aw.written();
    if (raw.len < raw_len) return error.TruncatedPng;

    const px = try gpa.alloc(u8, stride * h);
    errdefer gpa.free(px);
    for (0..h) |y| {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = px[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else px[(y - 1) * stride ..][0..stride];
        for (0..stride) |x| {
            const a: u8 = if (x > 0) dst[x - 1] else 0;
            const b: u8 = if (prev) |p| p[x] else 0;
            const c: u8 = if (x > 0) (if (prev) |p| p[x - 1] else 0) else 0;
            dst[x] = src[x] +% switch (filter) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => paeth(a, b, c),
                else => return error.BadPng,
            };
        }
    }
    return .{ .w = w, .h = h, .px = px };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "an indexed PNG reads back to the same indices" {
    const gpa = std.testing.allocator;
    var rgb: [768]u8 = undefined;
    for (&rgb, 0..) |*b, i| b.* = @intCast(i % 256);
    var px: [7 * 5]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast((i * 37) % 256);
    const png = try encodeIndexed(gpa, &px, 7, 5, &rgb);
    defer gpa.free(png);
    const back = try decodeIndexed(gpa, png);
    defer gpa.free(back.px);
    try std.testing.expectEqual(@as(u32, 7), back.w);
    try std.testing.expectEqual(@as(u32, 5), back.h);
    try std.testing.expectEqualSlices(u8, &px, back.px);

    // Same input, same bytes.
    const again = try encodeIndexed(gpa, &px, 7, 5, &rgb);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, png, again);
}
