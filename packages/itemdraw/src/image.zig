//! A straight-alpha RGBA picture and the few ways the game puts paletted art on one.
//!
//! The game blends into whatever is already on screen through its draw modes. An item picture has no
//! screen under it, so a translucent draw mode becomes alpha: solid is 255, mode 2 (less transparent)
//! 0xC0, mode 1 (transparent) 0x80, mode 0 (very transparent) 0x40, the constants the Glide and Direct3D
//! renderers use for those modes. Composited over a background, that is the game's blend.

const std = @import("std");
const formats = @import("d2-formats");
const png_codec = @import("d2-util").png;

pub const alpha_solid: u8 = 0xff;
pub const alpha_less_transparent: u8 = 0xc0;
pub const alpha_transparent: u8 = 0x80;
pub const alpha_very_transparent: u8 = 0x40;

pub const Image = struct {
    w: u32,
    h: u32,
    /// w*h*4, rows top-down, straight (not premultiplied) alpha.
    px: []u8,
    /// Where the item's top-left grid cell corner sits in the picture (icons and cards), or the box's
    /// top-left (tooltips).
    origin_x: i32 = 0,
    origin_y: i32 = 0,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Image {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.px);
        self.* = undefined;
    }

    pub fn png(self: *const Image, gpa: std.mem.Allocator) ![]u8 {
        return png_codec.encodeRgba(gpa, self.px, self.w, self.h);
    }

    /// One pixel `c` at alpha `a` over what is there.
    pub fn put(self: *Image, x: i32, y: i32, c: [3]u8, a: u8) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h or a == 0) return;
        const o = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4;
        const da: u32 = self.px[o + 3];
        if (a == 255 or da == 0) {
            self.px[o] = c[0];
            self.px[o + 1] = c[1];
            self.px[o + 2] = c[2];
            self.px[o + 3] = if (da == 0) a else @intCast(a + da * (255 - @as(u32, a)) / 255);
            if (da == 0 or a == 255) return;
        }
        const sa: u32 = a;
        const out_a = sa * 255 + da * (255 - sa); // scaled by 255
        inline for (0..3) |i| {
            const sc: u32 = c[i];
            const dc: u32 = self.px[o + i];
            self.px[o + i] = @intCast((sc * sa * 255 + dc * da * (255 - sa) + out_a / 2) / out_a);
        }
        self.px[o + 3] = @intCast((out_a + 127) / 255);
    }

    /// A rectangle of one colour, end exclusive.
    pub fn fill(self: *Image, x: i32, y: i32, w: i32, h: i32, c: [3]u8, a: u8) void {
        var yy = y;
        while (yy < y + h) : (yy += 1) {
            var xx = x;
            while (xx < x + w) : (xx += 1) self.put(xx, yy, c, a);
        }
    }

    /// A paletted frame with its top-left at (x, y). Index 0 is a hole; `remap` (256 entries) is applied
    /// to every index before the palette, as the game's colour maps and text colours are.
    pub fn blit(self: *Image, f: *const formats.dc6.Frame, pal: *const formats.palette.Palette, x: i32, y: i32, remap: ?[]const u8, a: u8) void {
        var row: u32 = 0;
        while (row < f.height) : (row += 1) {
            var col: u32 = 0;
            while (col < f.width) : (col += 1) {
                const raw = f.indices[@as(usize, row) * f.width + col];
                if (raw == 0) continue;
                const idx = if (remap) |m| m[raw] else raw;
                self.put(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), pal.rgb(idx), a);
            }
        }
    }

    /// A DC6 frame the way the game's image draw places one: (x, y) is the baseline point, the frame's
    /// bottom row sits just above it and its stored offset moves it from there.
    pub fn blitBaseline(self: *Image, f: *const formats.dc6.Frame, pal: *const formats.palette.Palette, x: i32, y: i32, remap: ?[]const u8, a: u8) void {
        self.blit(f, pal, x + f.offset_x, y + f.offset_y - @as(i32, @intCast(f.height)), remap, a);
    }

    /// Paste `src` with its pixel (0, 0) at (x, y), alpha over.
    pub fn paste(self: *Image, src: *const Image, x: i32, y: i32) void {
        var row: u32 = 0;
        while (row < src.h) : (row += 1) {
            var col: u32 = 0;
            while (col < src.w) : (col += 1) {
                const o = (@as(usize, row) * src.w + col) * 4;
                self.put(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), src.px[o..][0..3].*, src.px[o + 3]);
            }
        }
    }
};

/// The palette index nearest to an RGB colour by squared distance, the first minimum winning
/// (D2GFX_GetColorWithAlphaFromPallete 0x00605210).
pub fn nearest(pal: *const formats.palette.Palette, c: [3]u8) u8 {
    var best: u8 = 0;
    var best_d: u32 = std.math.maxInt(u32);
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const p = pal.rgb(@intCast(i));
        var d: u32 = 0;
        inline for (0..3) |k| {
            const diff: i32 = @as(i32, p[k]) - @as(i32, c[k]);
            d += @intCast(diff * diff);
        }
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

test "a half-transparent pixel over nothing keeps its colour and takes the alpha" {
    var img = try Image.init(std.testing.allocator, 2, 1);
    defer img.deinit(std.testing.allocator);
    img.put(0, 0, .{ 10, 20, 30 }, 0x80);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 0x80 }, img.px[0..4]);
    img.put(0, 0, .{ 0, 0, 0 }, 255);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, img.px[0..4]);
}
