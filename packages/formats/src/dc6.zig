//! DC6 sprite decoder and encoder — Diablo II's frame-sheet format (little-endian).
//!
//! Decodes each frame's scanline-encoded run stream into a width*height buffer of
//! palette indices (0 = transparent). `frameToRgba` applies a 256-colour RGB
//! palette (768 bytes) to produce straight RGBA8888. Rows in the DC6 stream are
//! stored BOTTOM-UP unless the frame's `flip` is set, so the first decoded scanline
//! is the image's bottom row; `indices` is always top-down.
//!
//! `encode` is the inverse, and reproduces the game's files byte for byte: the same
//! run splitting (runs of at most 127, no transparent run before an end of line),
//! the same frame-pointer table and `next_block` links, and the header's
//! termination bytes repeated after every frame.
//!
//! File layout:
//!
//!     header      24 bytes: version=6, flags, encoding, termination[4], directions, framesPerDir
//!     pointers    directions*framesPerDir u32 file offsets, direction-major
//!     per frame   32-byte header: flip, width, height, offset_x, offset_y, unknown,
//!                 next_block (file offset just past this frame's terminator), length
//!                 then `length` bytes of runs and 3 termination bytes

const std = @import("std");

pub const Frame = struct {
    width: u32,
    height: u32,
    offset_x: i32,
    offset_y: i32,
    /// width*height palette indices, row-major top-down. 0 = transparent.
    indices: []u8,
    /// Non-zero when the run stream is stored top-down. Every retail file stores 0.
    flip: u32 = 0,
    /// The frame header's sixth field. Zero in every retail file; carried for round trips.
    unknown: u32 = 0,
    /// The three bytes after the run stream. Usually the termination bytes, but some retail files
    /// hold leftover buffer contents there; null writes the sheet's termination.
    tail: ?[3]u8 = null,
    /// The stored `next_block` when it is not the offset of the next frame, which some retail
    /// files carry; null writes the real offset.
    next_block: ?u32 = null,
};

pub const Dc6 = struct {
    frames: []Frame,
    allocator: std.mem.Allocator,
    /// Frames are stored direction-major: frame `f` of direction `d` is `frames[d*frames_per_dir + f]`.
    /// Zero means "not recorded" and reads as one direction holding every frame.
    directions: u32 = 0,
    frames_per_dir: u32 = 0,
    /// Header fields that carry no meaning the decoder needs, kept so `encode` gives back the file.
    version: i32 = 6,
    flags: u32 = 1,
    encoding: u32 = 0,
    /// Four bytes in the header and the three written after every frame: 0xEE or 0xCD.
    termination: [4]u8 = .{ 0xEE, 0xEE, 0xEE, 0xEE },

    pub fn dirCount(self: *const Dc6) u32 {
        return if (self.directions == 0) 1 else self.directions;
    }

    pub fn framesPerDir(self: *const Dc6) u32 {
        return if (self.frames_per_dir == 0) @intCast(self.frames.len) else self.frames_per_dir;
    }

    pub fn frame(self: *const Dc6, dir: u32, index: u32) *const Frame {
        return &self.frames[dir * self.framesPerDir() + index];
    }

    pub fn deinit(self: *Dc6) void {
        for (self.frames) |f| self.allocator.free(f.indices);
        self.allocator.free(self.frames);
    }
};

const HEADER_SIZE = 24;
const FRAME_HEADER_SIZE = 32;

fn rdU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}
fn rdI32(bytes: []const u8, off: usize) i32 {
    return std.mem.readInt(i32, bytes[off..][0..4], .little);
}

/// Parse every frame (directions*framesPerDir), decoding each to palette indices.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Dc6 {
    if (bytes.len < HEADER_SIZE) return error.InvalidDc6;
    const version = rdI32(bytes, 0);
    if (version != 6) return error.InvalidDc6;
    const directions = rdU32(bytes, 16);
    const frames_per_dir = rdU32(bytes, 20);

    const frame_count = std.math.mul(u32, directions, frames_per_dir) catch return error.InvalidDc6;
    if (frame_count == 0) return error.InvalidDc6;

    const offsets_end = HEADER_SIZE + @as(usize, frame_count) * 4;
    if (bytes.len < offsets_end) return error.InvalidDc6;

    var frames = try alloc.alloc(Frame, frame_count);
    var built: usize = 0;
    errdefer {
        for (frames[0..built]) |f| alloc.free(f.indices);
        alloc.free(frames);
    }

    var i: usize = 0;
    while (i < frame_count) : (i += 1) {
        const fo = rdU32(bytes, HEADER_SIZE + i * 4);
        if (fo + FRAME_HEADER_SIZE > bytes.len) return error.InvalidDc6;
        const fh: usize = fo;

        const flip = rdU32(bytes, fh);
        const unknown = rdU32(bytes, fh + 20);
        const width = rdI32(bytes, fh + 4);
        const height = rdI32(bytes, fh + 8);
        const offset_x = rdI32(bytes, fh + 12);
        const offset_y = rdI32(bytes, fh + 16);
        const length = rdU32(bytes, fh + 28);
        if (width <= 0 or height <= 0) return error.InvalidDc6;

        const data_start = fh + FRAME_HEADER_SIZE;
        if (data_start + length > bytes.len) return error.InvalidDc6;
        const data = bytes[data_start .. data_start + length];

        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        const indices = try alloc.alloc(u8, w * h);
        @memset(indices, 0);

        decodeScanlines(data, indices, w, h, flip != 0);

        frames[i] = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .offset_x = offset_x,
            .offset_y = offset_y,
            .indices = indices,
            .flip = flip,
            .unknown = unknown,
            .tail = if (data_start + length + 3 <= bytes.len) bytes[data_start + length ..][0..3].* else null,
            .next_block = if (rdU32(bytes, fh + 24) != data_start + length + 3) rdU32(bytes, fh + 24) else null,
        };
        built += 1;
    }

    return .{
        .frames = frames,
        .allocator = alloc,
        .directions = directions,
        .frames_per_dir = frames_per_dir,
        .version = version,
        .flags = rdU32(bytes, 4),
        .encoding = rdU32(bytes, 8),
        .termination = bytes[12..16].*,
    };
}

/// Serialise a sheet back into a DC6 file. Caller owns the result.
///
/// A frame with zero width or height is written with an empty run stream; one whose
/// `indices` is not width*height long is refused.
pub fn encode(alloc: std.mem.Allocator, sheet: *const Dc6) ![]u8 {
    const dirs = sheet.dirCount();
    const fpd = sheet.framesPerDir();
    if (@as(usize, dirs) * fpd != sheet.frames.len or sheet.frames.len == 0) return error.InvalidDc6;
    for (sheet.frames) |f| {
        if (f.indices.len != @as(usize, f.width) * f.height) return error.InvalidDc6;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var hdr: [HEADER_SIZE]u8 = undefined;
    std.mem.writeInt(i32, hdr[0..4], sheet.version, .little);
    std.mem.writeInt(u32, hdr[4..8], sheet.flags, .little);
    std.mem.writeInt(u32, hdr[8..12], sheet.encoding, .little);
    hdr[12..16].* = sheet.termination;
    std.mem.writeInt(u32, hdr[16..20], dirs, .little);
    std.mem.writeInt(u32, hdr[20..24], fpd, .little);
    try out.appendSlice(alloc, &hdr);

    const table_at = out.items.len;
    try out.appendNTimes(alloc, 0, sheet.frames.len * 4);

    for (sheet.frames, 0..) |*f, i| {
        const fh = out.items.len;
        std.mem.writeInt(u32, out.items[table_at + i * 4 ..][0..4], @intCast(fh), .little);
        try out.appendNTimes(alloc, 0, FRAME_HEADER_SIZE);

        const data_start = out.items.len;
        try encodeScanlines(alloc, &out, f);
        const length = out.items.len - data_start;
        try out.appendSlice(alloc, if (f.tail) |*t| t else sheet.termination[0..3]);

        const h = out.items[fh..][0..FRAME_HEADER_SIZE];
        std.mem.writeInt(u32, h[0..4], f.flip, .little);
        std.mem.writeInt(u32, h[4..8], f.width, .little);
        std.mem.writeInt(u32, h[8..12], f.height, .little);
        std.mem.writeInt(i32, h[12..16], f.offset_x, .little);
        std.mem.writeInt(i32, h[16..20], f.offset_y, .little);
        std.mem.writeInt(u32, h[20..24], f.unknown, .little);
        std.mem.writeInt(u32, h[24..28], f.next_block orelse @intCast(out.items.len), .little);
        std.mem.writeInt(u32, h[28..32], @intCast(length), .little);
    }
    return out.toOwnedSlice(alloc);
}

/// One frame's run stream. Each scanline is: transparent runs (0x80|n) and opaque runs
/// (n, then n indices), each at most 127 long, ended by 0x80. Transparency that reaches the end
/// of a row is not written — the end-of-line marker says it.
fn encodeScanlines(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), f: *const Frame) !void {
    const w: usize = f.width;
    const h: usize = f.height;
    var scanline: usize = 0;
    while (scanline < h) : (scanline += 1) {
        const y = if (f.flip != 0) scanline else h - 1 - scanline;
        const row = f.indices[y * w ..][0..w];
        var x: usize = 0;
        while (x < w) {
            var gap: usize = 0;
            while (x + gap < w and row[x + gap] == 0) gap += 1;
            if (x + gap == w) break;
            while (gap > 0) {
                const n = @min(gap, 0x7f);
                try out.append(alloc, 0x80 | @as(u8, @intCast(n)));
                gap -= n;
                x += n;
            }
            var run: usize = 0;
            while (x + run < w and row[x + run] != 0 and run < 0x7f) run += 1;
            try out.append(alloc, @intCast(run));
            try out.appendSlice(alloc, row[x .. x + run]);
            x += run;
        }
        try out.append(alloc, 0x80);
    }
}

/// Walk the run-encoded `data` into `indices` (already zeroed). Rows are bottom-up
/// unless `top_down`: scanline 0 then lands in the last image row, y = height-1 - scanline.
fn decodeScanlines(data: []const u8, indices: []u8, w: usize, h: usize, top_down: bool) void {
    var scanline: usize = 0;
    var x: usize = 0;
    var p: usize = 0;
    while (p < data.len) {
        const b = data[p];
        p += 1;
        if (b == 0x80) {
            // End of scanline: advance to next row, reset x.
            scanline += 1;
            x = 0;
        } else if (b & 0x80 != 0) {
            // Transparent run: skip (b & 0x7f) pixels (left 0).
            x += b & 0x7f;
        } else {
            // Opaque run: copy `b` palette indices.
            const run: usize = b;
            if (scanline < h) {
                const y = if (top_down) scanline else h - 1 - scanline;
                const row = y * w;
                var k: usize = 0;
                while (k < run and p < data.len) : (k += 1) {
                    if (x < w) indices[row + x] = data[p];
                    x += 1;
                    p += 1;
                }
            } else {
                // Past the last row (malformed) — still consume the bytes.
                p += run;
                x += run;
            }
        }
    }
}

/// Apply a 768-byte RGB palette to a frame -> RGBA8888 (`out` = width*height*4).
/// Index 0 is transparent (alpha 0); every other index takes its colour from
/// palette[idx*3..]. D2 palettes (pal.dat/PL2) store each entry as B,G,R — NOT
/// RGB — so the wall/line colour (high red) reads as blue unless swapped here;
/// with the swap it comes out the correct tan/yellow.
pub fn frameToRgba(frame: *const Frame, palette: []const u8, out: []u8) void {
    const n = @as(usize, frame.width) * @as(usize, frame.height);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = frame.indices[i];
        const o = i * 4;
        if (idx == 0) {
            out[o] = 0;
            out[o + 1] = 0;
            out[o + 2] = 0;
            out[o + 3] = 0;
        } else {
            const pi = @as(usize, idx) * 3;
            out[o] = palette[pi + 2]; // R (BGR -> RGB)
            out[o + 1] = palette[pi + 1]; // G
            out[o + 2] = palette[pi]; // B
            out[o + 3] = 255;
        }
    }
}

fn readAsset(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024)) catch null;
}

test "dc6: parse MaxiMap + palette apply" {
    const alloc = std.testing.allocator;

    const bytes = readAsset(alloc, "assets/automap/MaxiMap.dc6") orelse return; // clean skip if asset absent
    defer alloc.free(bytes);

    var dc6 = try parse(alloc, bytes);
    defer dc6.deinit();

    try std.testing.expect(dc6.frames.len > 0);

    // First frame dims must be plausible automap-sprite sizes.
    const f0 = &dc6.frames[0];
    try std.testing.expect(f0.width >= 1 and f0.width <= 256);
    try std.testing.expect(f0.height >= 1 and f0.height <= 256);

    // At least one frame must decode some opaque (non-zero) indices.
    var any_opaque = false;
    var opaque_frame: usize = 0;
    for (dc6.frames, 0..) |f, fi| {
        for (f.indices) |ix| {
            if (ix != 0) {
                any_opaque = true;
                opaque_frame = fi;
                break;
            }
        }
        if (any_opaque) break;
    }
    try std.testing.expect(any_opaque);

    // Palette -> RGBA: at least one pixel opaque (alpha 255).
    const pal = readAsset(alloc, "assets/automap/ACT1.pal") orelse return;
    defer alloc.free(pal);
    try std.testing.expectEqual(@as(usize, 768), pal.len);

    const f = &dc6.frames[opaque_frame];
    const out = try alloc.alloc(u8, @as(usize, f.width) * @as(usize, f.height) * 4);
    defer alloc.free(out);
    frameToRgba(f, pal, out);

    var any_visible = false;
    var px: usize = 3;
    while (px < out.len) : (px += 4) {
        if (out[px] == 255) {
            any_visible = true;
            break;
        }
    }
    try std.testing.expect(any_visible);
}

fn testSheet(alloc: std.mem.Allocator, frames: []Frame, dirs: u32) Dc6 {
    return .{ .frames = frames, .allocator = alloc, .directions = dirs, .frames_per_dir = @intCast(frames.len / dirs) };
}

test "dc6: encode writes the runs the game writes" {
    const alloc = std.testing.allocator;
    // 4x2, top row "0 5 5 0", bottom row "0 0 0 0".
    var px = [_]u8{ 0, 5, 5, 0, 0, 0, 0, 0 };
    var frames = [_]Frame{.{ .width = 4, .height = 2, .offset_x = -3, .offset_y = 7, .indices = &px }};
    const sheet = testSheet(alloc, &frames, 1);
    const bytes = try encode(alloc, &sheet);
    defer alloc.free(bytes);

    // Bottom row first: empty, so just the end-of-line. Then 0x81, a run of two, end of line.
    const runs = bytes[HEADER_SIZE + 4 + FRAME_HEADER_SIZE ..];
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x81, 0x02, 5, 5, 0x80, 0xEE, 0xEE, 0xEE }, runs);
    try std.testing.expectEqual(@as(u32, 6), rdU32(bytes, HEADER_SIZE + 4 + 28));
    try std.testing.expectEqual(@as(u32, @intCast(bytes.len)), rdU32(bytes, HEADER_SIZE + 4 + 24));
}

test "dc6: long runs split at 127 and decode back to the same pixels" {
    const alloc = std.testing.allocator;
    const w = 300;
    const h = 3;
    var a: [w * h]u8 = undefined;
    for (&a, 0..) |*p, i| {
        const x = i % w;
        const y = i / w;
        p.* = switch (y) {
            0 => if (x < 200) 0 else @intCast(1 + x % 250), // a 200-long hole then colour
            1 => @intCast(1 + x % 7), // 300 opaque
            else => if (x % 2 == 0) 0 else 9, // alternating
        };
    }
    var b = [_]u8{0} ** (2 * 2); // a fully transparent second frame
    var frames = [_]Frame{
        .{ .width = w, .height = h, .offset_x = 1, .offset_y = -2, .indices = &a },
        .{ .width = 2, .height = 2, .offset_x = 0, .offset_y = 0, .indices = &b, .flip = 1 },
    };
    var sheet = testSheet(alloc, &frames, 2);
    sheet.termination = .{ 0xCD, 0xCD, 0xCD, 0xCD };
    const bytes = try encode(alloc, &sheet);
    defer alloc.free(bytes);

    var back = try parse(alloc, bytes);
    defer back.deinit();
    try std.testing.expectEqual(@as(u32, 2), back.directions);
    try std.testing.expectEqual(@as(u32, 1), back.frames_per_dir);
    try std.testing.expectEqual([4]u8{ 0xCD, 0xCD, 0xCD, 0xCD }, back.termination);
    for (frames, back.frames) |want, got| {
        try std.testing.expectEqual(want.width, got.width);
        try std.testing.expectEqual(want.height, got.height);
        try std.testing.expectEqual(want.offset_x, got.offset_x);
        try std.testing.expectEqual(want.offset_y, got.offset_y);
        try std.testing.expectEqual(want.flip, got.flip);
        try std.testing.expectEqualSlices(u8, want.indices, got.indices);
    }
    // And encoding the decoded sheet gives the same bytes.
    const again = try encode(alloc, &back);
    defer alloc.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
}
