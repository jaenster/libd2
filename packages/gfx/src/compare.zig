//! Two frames of the same view compared block by block: the gate a second renderer of the same
//! scene has to pass against the first.
//!
//! Each 64 x 64 block (the last row and column of blocks may be smaller) gets the mean absolute
//! difference in linear light (sRGB decoded, as 0..255) and SSIM on luminance (8 x 8 windows at a
//! stride of 4, averaged). A block passes with a mean difference under `max_mean` and an SSIM over
//! `min_ssim`; a block with fewer than half its pixels unmasked is not judged. A mask, when given,
//! is true for each pixel to leave out (units that move between shots, say).
const std = @import("std");

pub const Limits = struct {
    max_mean: f64 = 2.0,
    min_ssim: f64 = 0.98,
    block: u32 = 64,
};

pub const Block = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Pixels judged.
    n: u32,
    mean: f64,
    ssim: f64,
    /// Pixels whose largest channel difference (8-bit, as stored) is over 8.
    far: u32,
    judged: bool,
    pass: bool,
};

pub const Report = struct {
    blocks: []Block,
    judged: u32,
    failed: u32,
    worst_mean: f64,
    worst_ssim: f64,
    /// Mean over every judged pixel.
    mean: f64,

    pub fn deinit(r: *Report, gpa: std.mem.Allocator) void {
        gpa.free(r.blocks);
    }

    pub fn pass(r: *const Report) bool {
        return r.failed == 0 and r.judged > 0;
    }
};

var lin_table: [256]f64 = undefined;
var lin_ready = false;

fn linear(c: u8) f64 {
    if (!lin_ready) {
        for (&lin_table, 0..) |*v, i| {
            const f = @as(f64, @floatFromInt(i)) / 255.0;
            v.* = 255.0 * (if (f <= 0.04045) f / 12.92 else std.math.pow(f64, (f + 0.055) / 1.055, 2.4));
        }
        lin_ready = true;
    }
    return lin_table[c];
}

fn luma(p: []const u8) f64 {
    return 0.2126 * @as(f64, @floatFromInt(p[0])) + 0.7152 * @as(f64, @floatFromInt(p[1])) + 0.0722 * @as(f64, @floatFromInt(p[2]));
}

/// `a` and `b` are RGBA8, w x h, top row first.
pub fn compare(gpa: std.mem.Allocator, a: []const u8, b: []const u8, w: u32, h: u32, mask: ?[]const bool, lim: Limits) !Report {
    std.debug.assert(a.len == @as(usize, w) * h * 4 and b.len == a.len);
    const bw = (w + lim.block - 1) / lim.block;
    const bh = (h + lim.block - 1) / lim.block;
    const blocks = try gpa.alloc(Block, bw * bh);
    var rep: Report = .{ .blocks = blocks, .judged = 0, .failed = 0, .worst_mean = 0, .worst_ssim = 1, .mean = 0 };
    var total: f64 = 0;
    var total_n: u64 = 0;
    for (0..bh) |by| for (0..bw) |bx| {
        const x0: u32 = @intCast(bx * lim.block);
        const y0: u32 = @intCast(by * lim.block);
        const cw = @min(lim.block, w - x0);
        const ch = @min(lim.block, h - y0);
        var sum: f64 = 0;
        var n: u32 = 0;
        var far: u32 = 0;
        for (y0..y0 + ch) |y| for (x0..x0 + cw) |x| {
            const i = y * w + x;
            if (mask) |m| if (m[i]) continue;
            var d: f64 = 0;
            var dmax: u32 = 0;
            for (0..3) |k| {
                d += @abs(linear(a[i * 4 + k]) - linear(b[i * 4 + k]));
                const e: i32 = @as(i32, a[i * 4 + k]) - b[i * 4 + k];
                dmax = @max(dmax, @abs(e));
            }
            sum += d / 3.0;
            if (dmax > 8) far += 1;
            n += 1;
        };
        const judged = n * 2 >= cw * ch;
        const mean = if (n > 0) sum / @as(f64, @floatFromInt(n)) else 0;
        const ssim = blockSsim(a, b, w, x0, y0, cw, ch, mask);
        const ok = !judged or (mean < lim.max_mean and ssim > lim.min_ssim);
        blocks[by * bw + bx] = .{ .x = x0, .y = y0, .w = cw, .h = ch, .n = n, .mean = mean, .ssim = ssim, .far = far, .judged = judged, .pass = ok };
        if (judged) {
            rep.judged += 1;
            if (!ok) rep.failed += 1;
            rep.worst_mean = @max(rep.worst_mean, mean);
            rep.worst_ssim = @min(rep.worst_ssim, ssim);
            total += sum;
            total_n += n;
        }
    };
    rep.mean = if (total_n > 0) total / @as(f64, @floatFromInt(total_n)) else 0;
    return rep;
}

fn blockSsim(a: []const u8, b: []const u8, w: u32, x0: u32, y0: u32, cw: u32, ch: u32, mask: ?[]const bool) f64 {
    const c1 = (0.01 * 255.0) * (0.01 * 255.0);
    const c2 = (0.03 * 255.0) * (0.03 * 255.0);
    const win = 8;
    if (cw < win or ch < win) return 1;
    var acc: f64 = 0;
    var nwin: u32 = 0;
    var wy: u32 = 0;
    while (wy + win <= ch) : (wy += 4) {
        var wx: u32 = 0;
        while (wx + win <= cw) : (wx += 4) {
            var sa: f64 = 0;
            var sb: f64 = 0;
            var saa: f64 = 0;
            var sbb: f64 = 0;
            var sab: f64 = 0;
            var n: f64 = 0;
            for (0..win) |dy| for (0..win) |dx| {
                const i = (y0 + wy + dy) * w + x0 + wx + dx;
                if (mask) |m| if (m[i]) continue;
                const la = luma(a[i * 4 ..][0..3]);
                const lb = luma(b[i * 4 ..][0..3]);
                sa += la;
                sb += lb;
                saa += la * la;
                sbb += lb * lb;
                sab += la * lb;
                n += 1;
            };
            if (n < win * win / 2) continue;
            const ma = sa / n;
            const mb = sb / n;
            const va = saa / n - ma * ma;
            const vb = sbb / n - mb * mb;
            const cov = sab / n - ma * mb;
            acc += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2));
            nwin += 1;
        }
    }
    return if (nwin > 0) acc / @as(f64, @floatFromInt(nwin)) else 1;
}

/// A picture of the comparison: a, b and their difference (amplified 8 times) side by side, each
/// failing block outlined in red on all three.
pub fn sideBySide(gpa: std.mem.Allocator, a: []const u8, b: []const u8, w: u32, h: u32, rep: *const Report) ![]u8 {
    const ow = w * 3;
    const out = try gpa.alloc(u8, @as(usize, ow) * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        for (0..3) |k| {
            out[(y * ow + x) * 4 + k] = a[i + k];
            out[(y * ow + w + x) * 4 + k] = b[i + k];
            const d: i32 = @as(i32, a[i + k]) - b[i + k];
            out[(y * ow + 2 * w + x) * 4 + k] = @intCast(@min(255, @abs(d) * 8));
        }
        for (0..3) |p| out[(y * ow + p * w + x) * 4 + 3] = 255;
    };
    for (rep.blocks) |bl| {
        if (bl.pass) continue;
        for (0..3) |p| {
            const ox: u32 = @intCast(p * w);
            for (0..bl.w) |dx| {
                paint(out, ow, ox + bl.x + @as(u32, @intCast(dx)), bl.y);
                paint(out, ow, ox + bl.x + @as(u32, @intCast(dx)), bl.y + bl.h - 1);
            }
            for (0..bl.h) |dy| {
                paint(out, ow, ox + bl.x, bl.y + @as(u32, @intCast(dy)));
                paint(out, ow, ox + bl.x + bl.w - 1, bl.y + @as(u32, @intCast(dy)));
            }
        }
    }
    return out;
}

fn paint(px: []u8, w: u32, x: u32, y: u32) void {
    const i = (@as(usize, y) * w + x) * 4;
    px[i] = 255;
    px[i + 1] = 0;
    px[i + 2] = 0;
}

test "a frame against itself passes, against a shifted copy it does not" {
    const gpa = std.testing.allocator;
    const w = 128;
    const h = 64;
    const a = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(b);
    for (0..w * h) |i| {
        const v: u8 = @intCast((i * 7 + (i / w) * 13) % 256);
        a[i * 4 ..][0..4].* = .{ v, v, v, 255 };
    }
    @memcpy(b, a);
    var same = try compare(gpa, a, b, w, h, null, .{});
    defer same.deinit(gpa);
    try std.testing.expect(same.pass());
    try std.testing.expectEqual(@as(u32, 2), same.judged);
    for (0..w * h) |i| b[i * 4] = a[((i + 1) % (w * h)) * 4];
    var moved = try compare(gpa, a, b, w, h, null, .{});
    defer moved.deinit(gpa);
    try std.testing.expect(!moved.pass());
}
