//! A content key for an 8-bit index image, independent of where the image sits in its buffer.
//!
//! The key covers the bounding box of the non-zero indices: FNV-1a 64 over the box's width and
//! height (u16, little-endian) and then its indices, row by row from the top. Two copies of the
//! same art get the same key whatever transparent margin surrounds them, so a frame decoded by the
//! game into a padded texture buffer and the same frame read from a file agree. An image with no
//! non-zero index has no box and key 0.
//!
//! Allocation-free and libc-free.

const std = @import("std");

pub const fnv_offset: u64 = 0xcbf29ce484222325;
pub const fnv_prime: u64 = 0x100000001b3;

/// The bounding box of the non-zero indices, in the image's own coordinates, top-down.
pub const Box = struct {
    x0: u32 = 0,
    y0: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const Key = struct {
    /// 0 for an image with no non-zero index.
    key: u64 = 0,
    box: Box = .{},
};

/// The largest box side the key can describe (it is hashed as a u16).
pub const max_dim: u32 = 0xFFFF;

pub const Error = error{ BadDimensions, ShortBuffer };

/// The bounding box of the non-zero indices of the `w` x `h` image `px` (`pitch` bytes per row,
/// top row first). `null` when every index is 0.
pub fn bounds(px: []const u8, w: u32, h: u32, pitch: usize) ?Box {
    var x0: u32 = w;
    var x1: u32 = 0;
    var y0: u32 = h;
    var y1: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = px[@as(usize, y) * pitch ..][0..w];
        const first = std.mem.findNone(u8, row, &.{0}) orelse continue;
        const last = std.mem.findLastNone(u8, row, &.{0}).?;
        if (first < x0) x0 = @intCast(first);
        if (last + 1 > x1) x1 = @intCast(last + 1);
        if (y < y0) y0 = y;
        y1 = y + 1;
    }
    if (y1 == 0) return null;
    return .{ .x0 = x0, .y0 = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// The key of the `w` x `h` image `px`, `pitch` bytes per row, top row first.
pub fn compute(px: []const u8, w: u32, h: u32, pitch: usize) Error!Key {
    if (pitch < w) return error.BadDimensions;
    if (w == 0 or h == 0) return .{};
    if (px.len < (@as(usize, h) - 1) * pitch + w) return error.ShortBuffer;
    const box = bounds(px, w, h, pitch) orelse return .{};
    if (box.w > max_dim or box.h > max_dim) return error.BadDimensions;
    return .{ .key = hashBox(px, pitch, box), .box = box };
}

/// FNV-1a 64 over u16le `box.w`, u16le `box.h` and the box's indices, top row first.
pub fn hashBox(px: []const u8, pitch: usize, box: Box) u64 {
    var h: u64 = fnv_offset;
    const dims = [4]u8{ @truncate(box.w), @truncate(box.w >> 8), @truncate(box.h), @truncate(box.h >> 8) };
    h = feed(h, &dims);
    var y: u32 = 0;
    while (y < box.h) : (y += 1) {
        const off = @as(usize, box.y0 + y) * pitch + box.x0;
        h = feed(h, px[off..][0..box.w]);
    }
    return h;
}

/// FNV-1a 64 of `bytes` alone, from the standard offset basis.
pub fn fnv1a(bytes: []const u8) u64 {
    return feed(fnv_offset, bytes);
}

fn feed(start: u64, bytes: []const u8) u64 {
    var h = start;
    for (bytes) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    return h;
}

const testing = std.testing;

test "FNV-1a 64 matches the published vectors" {
    try testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a(""));
    try testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a("a"));
    try testing.expectEqual(@as(u64, 0x85944171f73967e8), fnv1a("foobar"));
}

test "empty and all-zero images have key 0" {
    const z = [_]u8{0} ** 12;
    try testing.expectEqual(Key{}, try compute(&z, 4, 3, 4));
    try testing.expectEqual(Key{}, try compute(&z, 0, 3, 4));
    try testing.expectEqual(Key{}, try compute(&z, 4, 0, 4));
}

test "the key is the box: width, height, then indices top-down" {
    // 5x4, pitch 6, art in a 2x2 box at (1, 1); the pitch byte is garbage the key must ignore.
    const px = [_]u8{
        0, 0, 0, 0, 0, 9,
        0, 3, 4, 0, 0, 9,
        0, 0, 5, 0, 0, 9,
        0, 0, 0, 0, 0, 9,
    };
    const k = try compute(&px, 5, 4, 6);
    try testing.expectEqual(Box{ .x0 = 1, .y0 = 1, .w = 2, .h = 2 }, k.box);
    try testing.expectEqual(fnv1a(&.{ 2, 0, 2, 0, 3, 4, 0, 5 }), k.key);
}

test "the same art in any margin has the same key; different art or shape does not" {
    const a = [_]u8{ 7, 0, 7, 1, 2, 1 }; // 3x2, no margin
    var b = [_]u8{0} ** (8 * 6);
    b[2 * 8 + 3 ..][0..3].* = .{ 7, 0, 7 };
    b[3 * 8 + 3 ..][0..3].* = .{ 1, 2, 1 };
    const ka = try compute(&a, 3, 2, 3);
    const kb = try compute(&b, 8, 6, 8);
    try testing.expectEqual(ka.key, kb.key);
    try testing.expectEqual(Box{ .x0 = 3, .y0 = 2, .w = 3, .h = 2 }, kb.box);

    // Same bytes, transposed shape (2x3): the dimensions in the hash tell them apart.
    const c = [_]u8{ 7, 0, 7, 1, 2, 1 };
    try testing.expect((try compute(&c, 2, 3, 2)).key != ka.key);
    // One index changed.
    const d = [_]u8{ 7, 0, 7, 1, 3, 1 };
    try testing.expect((try compute(&d, 3, 2, 3)).key != ka.key);
    // Flipped vertically: the key is defined top-down.
    const e = [_]u8{ 1, 2, 1, 7, 0, 7 };
    try testing.expect((try compute(&e, 3, 2, 3)).key != ka.key);
}

test "the box reaches single pixels in any corner" {
    var px = [_]u8{0} ** (7 * 5);
    px[0] = 1;
    px[4 * 7 + 6] = 2;
    const k = try compute(&px, 7, 5, 7);
    try testing.expectEqual(Box{ .x0 = 0, .y0 = 0, .w = 7, .h = 5 }, k.box);
    var q = [_]u8{0} ** (7 * 5);
    q[2 * 7 + 6] = 4;
    try testing.expectEqual(Box{ .x0 = 6, .y0 = 2, .w = 1, .h = 1 }, (try compute(&q, 7, 5, 7)).box);
}

test "argument errors" {
    const px = [_]u8{1} ** 8;
    try testing.expectError(error.BadDimensions, compute(&px, 4, 2, 3));
    try testing.expectError(error.ShortBuffer, compute(&px, 4, 3, 4));
}
