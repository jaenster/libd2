//! A straight RGBA8888 surface and the compositing D2's 2D art is made of.
//!
//! Every sprite in the game is palette indices with 0 meaning "hole". There is no alpha channel,
//! no filtering and no scaling in the source material, so there is none here either: anything
//! smarter stops matching the game the moment someone looks closely at an edge.
//!
//! This sits in d2-formats rather than a render package because it needs nothing but a decoded
//! frame and a palette, both of which are here — and because a decoder whose output you cannot
//! look at is a decoder nobody can check.
const std = @import("std");
const dc6 = @import("dc6.zig");
const palette = @import("palette.zig");

/// How a sprite combines with what is already on the surface. The names and numbers are the game's
/// own `DRAWMODE`, and the numbers are what its data tables store, so they are worth keeping.
///
/// The game resolves these through the blend tables in the palette's `.pl2`, not with arithmetic.
/// What is here is the arithmetic that matches them closely enough to look right — a fixed
/// percentage for the transparent modes and a straight lighten for `light_transparent`, which is
/// what the character-select glows use. Anything that has to be exact should go through the pl2.
pub const DrawMode = enum(u8) {
    very_transparent = 0,
    transparent = 1,
    less_transparent = 2,
    /// Additive. This is the blue glow around a selected necromancer or sorceress.
    light_transparent = 3,
    dark_transparent = 4,
    solid = 5,
    darker_solid = 6,
    lighter_solid = 7,
};

fn mix(dst: u8, src: u8, mode: DrawMode) u8 {
    const d: u16 = dst;
    const s: u16 = src;
    return switch (mode) {
        .very_transparent => @intCast((d * 3 + s) / 4),
        .transparent => @intCast((d + s) / 2),
        .less_transparent => @intCast((d + s * 3) / 4),
        .light_transparent, .lighter_solid => @intCast(@min(255, d + s)),
        .dark_transparent, .darker_solid => @intCast(if (d > s) d - s else 0),
        .solid => src,
    };
}

pub const Canvas = struct {
    w: u32,
    h: u32,
    /// w*h*4, row-major top-down, straight (non-premultiplied) RGBA.
    px: []u8,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn deinit(self: *Canvas, gpa: std.mem.Allocator) void {
        gpa.free(self.px);
        self.* = undefined;
    }

    pub fn clear(self: *Canvas, r: u8, g: u8, b: u8, a: u8) void {
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) {
            self.px[i] = r;
            self.px[i + 1] = g;
            self.px[i + 2] = b;
            self.px[i + 3] = a;
        }
    }

    /// Composite one DC6 frame with its top-left at (x, y), clipped to the surface.
    ///
    /// The frame's own `offset_x`/`offset_y` are NOT applied. For a background block they are
    /// zero; for a character animation they are an anchor whose meaning belongs to whatever is
    /// placing the character, not to a blitter.
    pub fn blit(self: *Canvas, frame: *const dc6.Frame, pal: *const palette.Palette, x: i32, y: i32) void {
        self.blitIndices(frame.indices, frame.width, frame.height, pal, x, y);
    }

    /// The same, combined with what is already there.
    pub fn blitMode(
        self: *Canvas,
        frame: *const dc6.Frame,
        pal: *const palette.Palette,
        x: i32,
        y: i32,
        mode: DrawMode,
    ) void {
        self.blitIndicesMode(frame.indices, frame.width, frame.height, pal, x, y, mode);
    }

    /// The same for bare indices, which is the shape a DCC direction decodes to.
    pub fn blitIndices(
        self: *Canvas,
        indices: []const u8,
        w: u32,
        h: u32,
        pal: *const palette.Palette,
        x: i32,
        y: i32,
    ) void {
        self.blitIndicesMode(indices, w, h, pal, x, y, .solid);
    }

    pub fn blitIndicesMode(
        self: *Canvas,
        indices: []const u8,
        w: u32,
        h: u32,
        pal: *const palette.Palette,
        x: i32,
        y: i32,
        mode: DrawMode,
    ) void {
        self.blitIndicesShifted(indices, w, h, pal, x, y, mode, null);
    }

    /// The same, with every index put through `shift` first — a 256-entry map from palette index
    /// to palette index. This is how Diablo II colours text: the glyphs are one set of images and
    /// a red string is the same images drawn through the red shift, not a tint applied afterwards.
    ///
    /// A shift maps 0 to 0, so transparency survives it.
    pub fn blitIndicesShifted(
        self: *Canvas,
        indices: []const u8,
        w: u32,
        h: u32,
        pal: *const palette.Palette,
        x: i32,
        y: i32,
        mode: DrawMode,
        shift: ?[]const u8,
    ) void {
        const cw: i32 = @intCast(self.w);
        const ch: i32 = @intCast(self.h);

        var row: u32 = 0;
        while (row < h) : (row += 1) {
            const dy = y + @as(i32, @intCast(row));
            if (dy < 0 or dy >= ch) continue;

            var col: u32 = 0;
            while (col < w) : (col += 1) {
                const raw = indices[@as(usize, row) * w + col];
                if (raw == 0) continue;
                const idx = if (shift) |s| s[raw] else raw;
                if (idx == 0) continue;

                const dx = x + @as(i32, @intCast(col));
                if (dx < 0 or dx >= cw) continue;

                const c = pal.rgb(idx);
                const o = (@as(usize, @intCast(dy)) * self.w + @as(usize, @intCast(dx))) * 4;
                if (mode == .solid) {
                    self.px[o] = c[0];
                    self.px[o + 1] = c[1];
                    self.px[o + 2] = c[2];
                } else {
                    self.px[o] = mix(self.px[o], c[0], mode);
                    self.px[o + 1] = mix(self.px[o + 1], c[1], mode);
                    self.px[o + 2] = mix(self.px[o + 2], c[2], mode);
                }
                self.px[o + 3] = 255;
            }
        }
    }

    /// Draw a full-screen DC6 — a background, a panel — starting at (x, y).
    ///
    /// The game does not store a screen as one image: it is a row-major grid of blocks, 256 wide
    /// until the last column, because the hardware it shipped on could not hold a whole surface per
    /// screen. Nothing in the file records the grid width, so it is recovered from the blocks: a
    /// new row starts as soon as the next block would overhang `width`.
    ///
    /// `width` is the screen's width, not the surface's — the caller may be drawing an 800-wide
    /// menu into a larger window.
    pub fn blitScreen(
        self: *Canvas,
        sheet: *const dc6.Dc6,
        pal: *const palette.Palette,
        x: i32,
        y: i32,
        width: u32,
    ) void {
        var cx: i32 = 0;
        var cy: i32 = 0;
        var row_h: u32 = 0;

        for (sheet.frames) |*f| {
            if (cx != 0 and cx + @as(i32, @intCast(f.width)) > @as(i32, @intCast(width))) {
                cx = 0;
                cy += @intCast(row_h);
                row_h = 0;
            }
            self.blit(f, pal, x + cx, y + cy);
            cx += @intCast(f.width);
            row_h = @max(row_h, f.height);
        }
    }

    /// The pixel size a `blitScreen` would cover, without drawing anything. Screens are stored at
    /// the resolution they were drawn for, and that resolution is only discoverable this way.
    pub fn screenSize(sheet: *const dc6.Dc6, width: u32) struct { w: u32, h: u32 } {
        var cx: u32 = 0;
        var cy: u32 = 0;
        var row_h: u32 = 0;
        var widest: u32 = 0;

        for (sheet.frames) |*f| {
            if (cx != 0 and cx + f.width > width) {
                cy += row_h;
                cx = 0;
                row_h = 0;
            }
            cx += f.width;
            row_h = @max(row_h, f.height);
            widest = @max(widest, cx);
        }
        return .{ .w = widest, .h = cy + row_h };
    }
};

const testing = std.testing;

fn solidFrame(gpa: std.mem.Allocator, w: u32, h: u32, index: u8) !dc6.Frame {
    const idx = try gpa.alloc(u8, w * h);
    @memset(idx, index);
    return .{ .width = w, .height = h, .offset_x = 0, .offset_y = 0, .indices = idx };
}

test "index 0 leaves the surface alone and everything else takes the palette" {
    const gpa = testing.allocator;

    var pal: palette.Palette = .{ .bgr = @splat(0) };
    pal.bgr[3 * 7 + 0] = 0x10; // B
    pal.bgr[3 * 7 + 1] = 0x20; // G
    pal.bgr[3 * 7 + 2] = 0x30; // R

    var c = try Canvas.init(gpa, 4, 2);
    defer c.deinit(gpa);

    var f = try solidFrame(gpa, 2, 2, 7);
    defer gpa.free(f.indices);
    f.indices[0] = 0;

    c.blit(&f, &pal, 1, 0);

    // The hole never got written.
    try testing.expectEqual(@as(u8, 0), c.px[(0 * 4 + 1) * 4 + 3]);
    // Its neighbour did, in RGB order.
    const o = (0 * 4 + 2) * 4;
    try testing.expectEqual([4]u8{ 0x30, 0x20, 0x10, 255 }, c.px[o..][0..4].*);
}

test "a blit clipped off every edge writes nothing and does not trap" {
    const gpa = testing.allocator;
    const pal: palette.Palette = .{ .bgr = @splat(0xff) };

    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit(gpa);

    var f = try solidFrame(gpa, 3, 3, 9);
    defer gpa.free(f.indices);

    c.blit(&f, &pal, -5, 0);
    c.blit(&f, &pal, 9, 0);
    c.blit(&f, &pal, 0, -5);
    c.blit(&f, &pal, 0, 9);

    for (c.px) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "a screen's grid is recovered from its blocks" {
    const gpa = testing.allocator;

    // The shape gameselectscreenEXP has: 256+256+256+32 across, 256+256+88 down.
    const widths = [_]u32{ 256, 256, 256, 32 };
    const heights = [_]u32{ 256, 256, 88 };

    var frames: [12]dc6.Frame = undefined;
    var made: usize = 0;
    defer for (frames[0..made]) |f| gpa.free(f.indices);

    for (heights) |fh| {
        for (widths) |fw| {
            frames[made] = try solidFrame(gpa, fw, fh, 1);
            made += 1;
        }
    }

    const sheet: dc6.Dc6 = .{ .frames = frames[0..], .allocator = gpa };
    const size = Canvas.screenSize(&sheet, 800);
    try testing.expectEqual(@as(u32, 800), size.w);
    try testing.expectEqual(@as(u32, 600), size.h);
}
