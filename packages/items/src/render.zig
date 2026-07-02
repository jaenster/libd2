//! Item-render: roll -> resolve invfile/quality -> decode DC6 -> composite icons
//! into one RGBA canvas (quality-coloured cell borders) -> PNG.
//!
//! Assets (item DC6s + palette) are the gitignored Blizzard art extracted by
//! tools/extract_assets.zig; this reads them from an assets dir at run time.

const std = @import("std");
const dc6 = @import("dc6.zig");
const png = @import("png.zig");
const graphic = @import("graphic.zig");
const tables = @import("tables.zig");
const model = @import("model.zig");

const CELL_W: u32 = 84;
const CELL_H: u32 = 108;
const PAD: u32 = 6;
const COLS: u32 = 5;
const BORDER: u32 = 3;

/// Simple top-down RGBA canvas.
pub const Canvas = struct {
    w: u32,
    h: u32,
    px: []u8,

    fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        return .{ .w = w, .h = h, .px = px };
    }

    /// Alpha-composite a w*h RGBA source at (dx,dy) (straight alpha, over).
    fn blit(self: *Canvas, src: []const u8, sw: u32, sh: u32, dx: i32, dy: i32) void {
        var y: u32 = 0;
        while (y < sh) : (y += 1) {
            const py = dy + @as(i32, @intCast(y));
            if (py < 0 or py >= self.h) continue;
            var x: u32 = 0;
            while (x < sw) : (x += 1) {
                const pxx = dx + @as(i32, @intCast(x));
                if (pxx < 0 or pxx >= self.w) continue;
                const so = (@as(usize, y) * sw + x) * 4;
                const a = src[so + 3];
                if (a == 0) continue;
                const doff = (@as(usize, @intCast(py)) * self.w + @as(usize, @intCast(pxx))) * 4;
                if (a == 255) {
                    @memcpy(self.px[doff .. doff + 4], src[so .. so + 4]);
                } else {
                    const inv = 255 - @as(u16, a);
                    inline for (0..3) |c| {
                        const s: u16 = src[so + c];
                        const d: u16 = self.px[doff + c];
                        self.px[doff + c] = @intCast((s * a + d * inv) / 255);
                    }
                    self.px[doff + 3] = 255;
                }
            }
        }
    }

    fn fillRect(self: *Canvas, x0: u32, y0: u32, w: u32, h: u32, col: graphic.Rgb) void {
        var y = y0;
        while (y < y0 + h and y < self.h) : (y += 1) {
            var x = x0;
            while (x < x0 + w and x < self.w) : (x += 1) {
                const o = (@as(usize, y) * self.w + x) * 4;
                self.px[o] = col.r;
                self.px[o + 1] = col.g;
                self.px[o + 2] = col.b;
                self.px[o + 3] = 255;
            }
        }
    }

    fn drawBorder(self: *Canvas, x0: u32, y0: u32, w: u32, h: u32, t: u32, col: graphic.Rgb) void {
        self.fillRect(x0, y0, w, t, col); // top
        self.fillRect(x0, y0 + h - t, w, t, col); // bottom
        self.fillRect(x0, y0, t, h, col); // left
        self.fillRect(x0 + w - t, y0, t, h, col); // right
    }
};

fn readAsset(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch null;
}

/// Render the item drops into a PNG grid. Only real base-item drops with a
/// resolvable invfile are drawn (gold / class-token residuals are skipped).
/// Returns PNG bytes (caller owns) or error.NoRenderableItems if nothing drew.
pub fn renderDropsToPng(
    gpa: std.mem.Allocator,
    t: *const tables.Tables,
    drops: []const model.Drop,
    assets_dir: []const u8,
) ![]u8 {
    const pal_path = try std.fmt.allocPrint(gpa, "{s}/palette/ACT1.pal", .{assets_dir});
    defer gpa.free(pal_path);
    const palette = readAsset(gpa, pal_path) orelse return error.NoPalette;
    defer gpa.free(palette);
    if (palette.len < 768) return error.BadPalette;

    // Resolve renderable drops first so we know the grid size.
    const Renderable = struct { g: graphic.Graphic };
    var list: std.ArrayListUnmanaged(Renderable) = .empty;
    defer list.deinit(gpa);
    for (drops) |*d| {
        if (graphic.resolve(t, d)) |g| try list.append(gpa, .{ .g = g });
    }
    if (list.items.len == 0) return error.NoRenderableItems;

    const n: u32 = @intCast(list.items.len);
    const cols = @min(n, COLS);
    const rows = (n + cols - 1) / cols;
    const cw = CELL_W + PAD;
    const ch = CELL_H + PAD;
    const width = cols * cw + PAD;
    const height = rows * ch + PAD;

    var canvas = try Canvas.init(gpa, width, height);
    defer gpa.free(canvas.px);

    for (list.items, 0..) |item, i| {
        const idx: u32 = @intCast(i);
        const cx = PAD + (idx % cols) * cw;
        const cy = PAD + (idx / cols) * ch;

        // Quality-coloured cell border.
        canvas.drawBorder(cx, cy, CELL_W, CELL_H, BORDER, item.g.color);

        // Load + decode the item sprite (frame 0 = inventory icon).
        const dc6_path = try std.fmt.allocPrint(gpa, "{s}/items/{s}.dc6", .{ assets_dir, item.g.invfile });
        defer gpa.free(dc6_path);
        const bytes = readAsset(gpa, dc6_path) orelse continue;
        defer gpa.free(bytes);
        var sprite = dc6.parse(gpa, bytes) catch continue;
        defer sprite.deinit();
        if (sprite.frames.len == 0) continue;
        const f = &sprite.frames[0];

        const rgba = try gpa.alloc(u8, @as(usize, f.width) * f.height * 4);
        defer gpa.free(rgba);
        dc6.frameToRgba(f, palette, rgba);

        // Centre the icon in the cell interior.
        const inner_x = cx + BORDER;
        const inner_y = cy + BORDER;
        const inner_w = CELL_W - 2 * BORDER;
        const inner_h = CELL_H - 2 * BORDER;
        const dxc = @as(i32, @intCast(inner_x)) + @divTrunc(@as(i32, @intCast(inner_w)) - @as(i32, @intCast(f.width)), 2);
        const dyc = @as(i32, @intCast(inner_y)) + @divTrunc(@as(i32, @intCast(inner_h)) - @as(i32, @intCast(f.height)), 2);
        canvas.blit(rgba, f.width, f.height, dxc, dyc);
    }

    return png.encodeRgba(gpa, canvas.px, width, height);
}

const testing = std.testing;

test "render: composite a rolled drop grid to PNG (skips if no assets)" {
    const gpa = testing.allocator;
    if (readAsset(gpa, "assets/palette/ACT1.pal")) |p| gpa.free(p) else return; // no assets -> skip

    var t = try tables.Tables.load(gpa);
    defer t.deinit();

    // Hand-build a couple of known base items so the test is deterministic.
    var drops = [_]model.Drop{
        .{ .kind = .item, .quality = .magic },
        .{ .kind = .item, .quality = .rare },
    };
    @memcpy(drops[0].item_code[0..3], "ssd"); // short sword
    @memcpy(drops[1].item_code[0..3], "buc"); // buckler

    const bytes = try renderDropsToPng(gpa, &t, &drops, "assets");
    defer gpa.free(bytes);
    try testing.expect(bytes.len > 100);
    try testing.expectEqual(@as(u8, 0x89), bytes[0]);
}
