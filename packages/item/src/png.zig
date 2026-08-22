//! Minimal pure-Zig PNG writer for RGBA8888 images. Emits a valid PNG using
//! uncompressed ("stored") DEFLATE blocks wrapped in a zlib stream — no external
//! codec, no C. Enough to dump the item-render grid to a file any viewer opens.

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
