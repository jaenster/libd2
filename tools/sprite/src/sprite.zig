//! One shape for DC6 and DCC frames: a grid of directions x frames, each frame a block of palette
//! indices placed relative to the unit's pivot. Everything the CLI does — render, scale, hash,
//! write back — works on this, and only loading and saving know which format it came from.

const std = @import("std");
const formats = @import("d2-formats");
const dc6 = formats.dc6;
const dcc = formats.dcc;

pub const Kind = enum {
    dc6,
    dcc,

    pub fn fromName(name: []const u8) ?Kind {
        if (std.ascii.endsWithIgnoreCase(name, ".dc6")) return .dc6;
        if (std.ascii.endsWithIgnoreCase(name, ".dcc")) return .dcc;
        return null;
    }
};

pub const Frame = struct {
    w: u32,
    h: u32,
    /// Top-left corner relative to the pivot the game draws the sprite at.
    x: i32,
    y: i32,
    /// w*h indices, top-down. 0 is a hole.
    px: []u8,
};

pub const Sprite = struct {
    kind: Kind,
    dirs: u32,
    fpd: u32,
    /// Direction-major: frame `f` of direction `d` is `frames[d*fpd + f]`.
    frames: []Frame,
    /// The decoded file, for the header fields a write-back carries over.
    dc6: ?dc6.Dc6 = null,
    dcc: ?dcc.Dcc = null,

    pub fn at(self: *const Sprite, d: u32, f: u32) *const Frame {
        return &self.frames[d * self.fpd + f];
    }
};

/// Decode a DC6 or DCC. The frames borrow nothing from `bytes`.
///
/// A DC6 frame's offset is its bottom-left corner, so its top is `offset_y - height`. A DCC frame
/// covers its direction's box, which already is pivot-relative.
pub fn load(gpa: std.mem.Allocator, kind: Kind, bytes: []const u8) !Sprite {
    switch (kind) {
        .dc6 => {
            const d = try dc6.parse(gpa, bytes);
            const frames = try gpa.alloc(Frame, d.frames.len);
            for (d.frames, frames) |src, *dst| dst.* = .{
                .w = src.width,
                .h = src.height,
                .x = src.offset_x,
                .y = src.offset_y - @as(i32, @intCast(src.height)),
                .px = src.indices,
            };
            return .{ .kind = .dc6, .dirs = d.dirCount(), .fpd = d.framesPerDir(), .frames = frames, .dc6 = d };
        },
        .dcc => {
            const d = try dcc.parse(gpa, bytes);
            const n = d.directions.len * d.frames_per_dir;
            const frames = try gpa.alloc(Frame, n);
            for (d.directions, 0..) |dir, di| {
                for (dir.frames, 0..) |px, fi| frames[di * d.frames_per_dir + fi] = .{
                    .w = @intCast(dir.box.width),
                    .h = @intCast(dir.box.height),
                    .x = dir.box.left,
                    .y = dir.box.top,
                    .px = px,
                };
            }
            return .{ .kind = .dcc, .dirs = @intCast(d.directions.len), .fpd = d.frames_per_dir, .frames = frames, .dcc = d };
        },
    }
}

/// SHA-256 over width and height (little-endian u32) and then the indices, as lowercase hex.
/// This is the key an upscaled pack is filed under: it names the art, not the file it came from,
/// so the same frame shipped in two files gets one entry.
pub fn hash(w: u32, h: u32, px: []const u8) [64]u8 {
    var s = std.crypto.hash.sha2.Sha256.init(.{});
    var dims: [8]u8 = undefined;
    std.mem.writeInt(u32, dims[0..4], w, .little);
    std.mem.writeInt(u32, dims[4..8], h, .little);
    s.update(&dims);
    s.update(px);
    var digest: [32]u8 = undefined;
    s.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// The tight box of non-zero indices in a frame, or null when it is all holes.
pub fn opaqueBox(f: *const Frame) ?struct { x0: u32, y0: u32, x1: u32, y1: u32 } {
    var x0: u32 = f.w;
    var y0: u32 = f.h;
    var x1: u32 = 0;
    var y1: u32 = 0;
    for (0..f.h) |y| for (0..f.w) |x| {
        if (f.px[y * f.w + x] == 0) continue;
        x0 = @min(x0, @as(u32, @intCast(x)));
        y0 = @min(y0, @as(u32, @intCast(y)));
        x1 = @max(x1, @as(u32, @intCast(x + 1)));
        y1 = @max(y1, @as(u32, @intCast(y + 1)));
    };
    if (x1 == 0) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

test "hash covers the dimensions, not only the bytes" {
    const px = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expect(!std.mem.eql(u8, &hash(2, 3, &px), &hash(3, 2, &px)));
    try std.testing.expectEqualStrings(&hash(2, 3, &px), &hash(2, 3, &px));
}
