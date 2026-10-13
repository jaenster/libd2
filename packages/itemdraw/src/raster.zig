//! Drawing a display list through providers.
//!
//! The rasterizer owns the composition: the canvas (the layout's size times `scale`), the fills, where
//! each sprite and glyph goes and the alpha its draw mode gives it. A provider only paints one tile: a
//! zeroed RGBA buffer the size of the cell (or the sprite's rectangle) times the scale. It paints what it
//! likes into it and says whether it did; a tile it declines goes to the fallback provider. The pixels a
//! tile leaves at alpha 0 are holes.
//!
//! libd2's own providers (draw.zig) paint the 1.14d DC6 glyphs and inventory frames from the caller's
//! archives, which at scale 1 gives exactly the game's pixels. Other art (HD sprites, a vector face drawn
//! into the glyph cell) plugs in here without changing the layout.

const std = @import("std");
const layout = @import("layout.zig");
const Image = @import("d2-formats").canvas.Canvas;

/// A buffer to paint: `w*h*4` bytes of straight-alpha RGBA, rows top-down, zeroed.
pub const Tile = struct { w: u32, h: u32, rgba: []u8 };

pub const GlyphProvider = struct {
    ctx: *anyopaque,
    /// Paint `glyph` of font `font` in its colour into `tile` (the glyph cell at `scale`).
    draw: *const fn (ctx: *anyopaque, font: []const u8, glyph: *const layout.Glyph, scale: u32, tile: Tile) bool,
};

pub const SpriteProvider = struct {
    ctx: *anyopaque,
    /// Paint the frame `sprite.ref` into `tile` (the sprite's rectangle at `scale`). The draw-mode alpha
    /// (`sprite.alpha`) is the rasterizer's; paint the frame opaque.
    draw: *const fn (ctx: *anyopaque, sprite: *const layout.Sprite, scale: u32, tile: Tile) bool,
};

pub const Providers = struct {
    glyph: ?GlyphProvider = null,
    sprite: ?SpriteProvider = null,
};

/// Draw `l` at `scale` (1 is the game's own size) through `primary`, falling back to `fallback` for
/// what the primary declines or lacks.
pub fn rasterize(gpa: std.mem.Allocator, l: *const layout.Layout, primary: Providers, fallback: Providers, scale_in: u32) !Image {
    const scale: u32 = @max(scale_in, 1);
    const s: i32 = @intCast(scale);
    var img = try Image.init(gpa, @intCast(@max(l.width, 1) * s), @intCast(@max(l.height, 1) * s));
    errdefer img.deinit(gpa);
    img.origin_x = l.origin_x * s;
    img.origin_y = l.origin_y * s;
    var tile_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer tile_buf.deinit(gpa);

    for (l.cells) |f| fillScaled(&img, f, s);
    if (l.icon) |*sp| try sprite(gpa, &img, &tile_buf, sp, primary, fallback, scale);
    for (l.sockets) |*sp| try sprite(gpa, &img, &tile_buf, sp, primary, fallback, scale);
    if (l.box) |b| fillScaled(&img, b, s);
    // the description's buffer order is bottom to top; glyph cells of different lines do not overlap
    var li = l.lines.len;
    while (li > 0) {
        li -= 1;
        for (l.lines[li].spans) |sp| for (sp.glyphs) |*g| {
            const t = try tile(gpa, &tile_buf, g.rect, scale);
            const drawn = blk: {
                if (primary.glyph) |p| if (p.draw(p.ctx, layout.font_name, g, scale, t)) break :blk true;
                if (fallback.glyph) |p| if (p.draw(p.ctx, layout.font_name, g, scale, t)) break :blk true;
                break :blk false;
            };
            if (drawn) img.composite(&Image{ .w = t.w, .h = t.h, .px = t.rgba }, g.rect.x * s, g.rect.y * s, 255);
        };
    }
    return img;
}

fn fillScaled(img: *Image, f: layout.Fill, s: i32) void {
    img.fill(f.rect.x * s, f.rect.y * s, f.rect.w * s, f.rect.h * s, f.rgb, f.alpha);
}

fn tile(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), r: layout.Rect, scale: u32) !Tile {
    const w: u32 = @intCast(@max(r.w, 0) * @as(i32, @intCast(scale)));
    const h: u32 = @intCast(@max(r.h, 0) * @as(i32, @intCast(scale)));
    try buf.resize(gpa, @as(usize, w) * h * 4);
    @memset(buf.items, 0);
    return .{ .w = w, .h = h, .rgba = buf.items };
}

fn sprite(gpa: std.mem.Allocator, img: *Image, buf: *std.ArrayListUnmanaged(u8), sp: *const layout.Sprite, primary: Providers, fallback: Providers, scale: u32) !void {
    const t = try tile(gpa, buf, sp.rect, scale);
    const drawn = blk: {
        if (primary.sprite) |p| if (p.draw(p.ctx, sp, scale, t)) break :blk true;
        if (fallback.sprite) |p| if (p.draw(p.ctx, sp, scale, t)) break :blk true;
        break :blk false;
    };
    const s: i32 = @intCast(scale);
    if (drawn) img.composite(&Image{ .w = t.w, .h = t.h, .px = t.rgba }, sp.rect.x * s, sp.rect.y * s, sp.alpha);
}
