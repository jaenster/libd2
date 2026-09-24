//! Integer upscaling of palette indices. `mmpx` is d2-util's index-space MMPX; `nearest` repeats
//! each index k*k times. Both return only indices that were in the input, so a scaled frame
//! still draws through any palette, colour map or blend table the original could.

const std = @import("std");
const util = @import("d2-util");

pub const Filter = enum { mmpx, nearest };

pub const Edge = util.mmpx.EdgeMode;

/// What lies outside a frame for MMPX. `.zero` (index 0, a hole) is right for sprites, whose
/// surroundings are transparent; `.clamp` for blocks of a tiled image such as a UI panel.
pub var edge: Edge = .zero;

/// Scale `px` (w*h, top-down) by `k`. `rgb` is the palette the brightness rules read.
/// Caller owns the result, (w*k)*(h*k) long.
pub fn scale(gpa: std.mem.Allocator, px: []const u8, w: u32, h: u32, k: u32, filter: Filter, rgb: ?*const [768]u8) ![]u8 {
    const ow = w * k;
    const oh = h * k;
    const out = try gpa.alloc(u8, @as(usize, ow) * oh);
    errdefer gpa.free(out);
    if (k == 1 or w == 0 or h == 0) {
        @memcpy(out, px);
        return out;
    }
    switch (filter) {
        .nearest => {
            for (0..oh) |y| for (0..ow) |x| {
                out[y * ow + x] = px[(y / k) * w + x / k];
            };
        },
        .mmpx => try util.mmpx.scale(px, w, h, w, k, .{ .palette = rgb, .edge = edge }, out, ow),
    }
    return out;
}
