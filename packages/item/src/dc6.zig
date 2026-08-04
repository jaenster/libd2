//! DC6 sprite decoder — Diablo II's frame-sheet format (little-endian).
//! Adapted from the faithful d2-drlg automap decoder (same byte layout / RLE).
//!
//! Decodes each frame's scanline-encoded run stream into a width*height buffer of
//! palette indices (0 = transparent). `frameToRgba` applies a 256-colour palette
//! (768 bytes, stored B,G,R per entry — same convention as D2 pal.dat / the DT1
//! pixel path in d2-drlg) to produce straight RGBA8888. Rows in the DC6 stream are
//! stored BOTTOM-UP, so the first decoded scanline is the image's bottom row; we
//! flip on decode (row y = height-1 - scanline) so `indices` is top-down.

const std = @import("std");

pub const Frame = struct {
    width: u32,
    height: u32,
    offset_x: i32,
    offset_y: i32,
    /// width*height palette indices, row-major top-down. 0 = transparent.
    indices: []u8,
};

pub const Dc6 = struct {
    frames: []Frame,
    allocator: std.mem.Allocator,

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

        decodeScanlines(data, indices, w, h);

        frames[i] = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .offset_x = offset_x,
            .offset_y = offset_y,
            .indices = indices,
        };
        built += 1;
    }

    return .{ .frames = frames, .allocator = alloc };
}

/// Walk the run-encoded `data` into `indices` (already zeroed). Rows are bottom-up:
/// scanline 0 lands in the last image row, so y = height-1 - scanline.
fn decodeScanlines(data: []const u8, indices: []u8, w: usize, h: usize) void {
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
                const y = h - 1 - scanline;
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

/// Apply a 768-byte palette to a frame -> RGBA8888 (`out` = width*height*4).
/// Index 0 is transparent (alpha 0); every other index takes its colour from
/// palette[idx*3..]. D2 palettes (pal.dat) store each entry as B,G,R — NOT RGB —
/// so we swap here so the colours come out right.
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

const testing = std.testing;

fn readAsset(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024)) catch null;
}

test "dc6: parse an extracted item sprite + palette apply" {
    const alloc = testing.allocator;

    // invswrd (short sword) — a small, always-present base item icon.
    const bytes = readAsset(alloc, "assets/items/invswrd.dc6") orelse return; // clean skip if not extracted
    defer alloc.free(bytes);

    var dc6 = try parse(alloc, bytes);
    defer dc6.deinit();
    try testing.expect(dc6.frames.len > 0);

    const f0 = &dc6.frames[0];
    try testing.expect(f0.width >= 1 and f0.width <= 256);
    try testing.expect(f0.height >= 1 and f0.height <= 256);

    // At least one opaque index.
    var any_opaque = false;
    for (f0.indices) |ix| {
        if (ix != 0) {
            any_opaque = true;
            break;
        }
    }
    try testing.expect(any_opaque);

    const pal = readAsset(alloc, "assets/palette/ACT1.pal") orelse return;
    defer alloc.free(pal);
    try testing.expectEqual(@as(usize, 768), pal.len);

    const out = try alloc.alloc(u8, @as(usize, f0.width) * @as(usize, f0.height) * 4);
    defer alloc.free(out);
    frameToRgba(f0, pal, out);

    var any_visible = false;
    var px: usize = 3;
    while (px < out.len) : (px += 4) {
        if (out[px] == 255) {
            any_visible = true;
            break;
        }
    }
    try testing.expect(any_visible);
}
