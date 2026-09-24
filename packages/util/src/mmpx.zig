//! MMPX pixel-art magnification on 8-bit palette indices.
//!
//! MMPX is Morgan McGuire and Mara Gagiu, "MMPX Style-Preserving Pixel Art Magnification", JCGT
//! vol. 10 no. 2, 2021 (https://jcgt.org/published/0010/02/04/). It maps every source pixel to a
//! 2x2 block chosen from its neighbourhood by four rule families: 1:1 slopes, line intersections,
//! triangle tips and 2:1 slopes. It only ever copies existing pixels, so the output holds nothing
//! but input indices, and a constant 3x3 neighbourhood always becomes a plain 2x2 copy.
//!
//! The rules below are a port of the authors' reference (the `MMPXAlgorithm` class of
//! `cppPerf.cpp` and `runMMPX2X` of `js-demo.html` in the paper's supplement), which carries:
//!
//!   Copyright 2020 Morgan McGuire & Mara Gagiu.
//!   Available under the MIT license.
//!
//!   Permission is hereby granted, free of charge, to any person obtaining a copy of this
//!   software and associated documentation files (the "Software"), to deal in the Software
//!   without restriction, including without limitation the rights to use, copy, modify, merge,
//!   publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
//!   to whom the Software is furnished to do so, subject to the following conditions: The above
//!   copyright notice and this permission notice shall be included in all copies or substantial
//!   portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//!   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
//!   FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//!   HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
//!   CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//!   USE OR OTHER DEALINGS IN THE SOFTWARE.
//!
//! Index-space semantics:
//! - Two pixels are equal when their INDICES are equal. Two indices whose palette colours happen
//!   to coincide are still different pixels.
//! - Brightness comparisons use `luma(i)`, the reference's `(r + g + b + 1) * (256 - alpha)`:
//!   with a palette, an opaque index ranks at `r + g + b + 1` (1..766). Without a palette an
//!   opaque index ranks at its own value, so only index order drives the brightness rules.
//! - Index 0 is transparent (D2's convention; `Options.index0_transparent`). With a palette it
//!   gets the reference's alpha-0 luma, `(r + g + b + 1) * 256` of palette entry 0 - for D2's
//!   black entry 0 that is 256, which ranks ABOVE opaque colours with r+g+b < 255 and BELOW
//!   brighter ones, exactly as a transparent-black RGBA pixel ranks in the reference. Without a
//!   palette index 0 ranks above every other index.
//! - Pixels outside the image read per `EdgeMode`: `.clamp` repeats the nearest edge pixel (the
//!   reference's default), `.zero` reads index 0 (the reference's mode for sprites and fonts,
//!   whose outside is transparent).
//!
//! Scales: 1 is a copy, 2 is MMPX, 4 is MMPX applied to the 2x result, 3 is the 4x result
//! resampled at output pixel centres (see `resample4to3`). Every scale is deterministic and
//! allocation-free: 3x and 4x keep the intermediate 2x image in a fixed stack tile.

const std = @import("std");

pub const EdgeMode = enum {
    /// An outside read repeats the nearest edge pixel.
    clamp,
    /// An outside read is index 0.
    zero,
};

pub const Options = struct {
    /// 256 colour triples used only for brightness. The luma is `r + g + b`, which does not
    /// depend on channel order, so an RGB palette and D2's B,G,R `pal.dat` give identical
    /// results. Null ranks indices by value.
    palette: ?*const [768]u8 = null,
    edge: EdgeMode = .clamp,
    /// Rank index 0 as a transparent pixel (see the file comment). False treats it as an
    /// ordinary opaque colour.
    index0_transparent: bool = true,
};

pub const Error = error{
    /// The factor is not 1, 2, 3 or 4.
    UnsupportedScale,
    /// A pitch is smaller than the row it has to hold.
    BadPitch,
    /// The source slice is shorter than `h` rows of `src_pitch`.
    SrcTooSmall,
    /// The destination slice is shorter than `h * factor` rows of `dst_pitch`.
    DstTooSmall,
    /// A dimension exceeds `max_dim`, or the destination size overflows `usize`.
    TooLarge,
};

/// Largest accepted width or height, so every coordinate of the 4x image fits an i32.
pub const max_dim: u32 = 1 << 28;

pub fn isSupportedScale(factor: u32) bool {
    return factor >= 1 and factor <= 4;
}

/// Bytes a destination needs: `h * factor` rows of `dst_pitch`, the last one only `w * factor`
/// long. Null on overflow.
pub fn dstLen(w: u32, h: u32, factor: u32, dst_pitch: usize) ?usize {
    if (w == 0 or h == 0) return 0;
    const rows = std.math.mul(usize, h, factor) catch return null;
    const row = std.math.mul(usize, w, factor) catch return null;
    const body = std.math.mul(usize, rows - 1, dst_pitch) catch return null;
    return std.math.add(usize, body, row) catch null;
}

/// The brightness each index ranks at, per the file comment.
pub fn lumaTable(opts: Options) [256]u32 {
    var t: [256]u32 = undefined;
    for (&t, 0..) |*l, i| {
        l.* = if (opts.palette) |p|
            @as(u32, p[3 * i]) + p[3 * i + 1] + p[3 * i + 2] + 1
        else
            @intCast(i);
    }
    if (opts.index0_transparent) {
        t[0] = if (opts.palette != null) t[0] * 256 else 0x10000;
    }
    return t;
}

/// Magnify `w` x `h` indices by `factor` (1, 2, 3 or 4). `src` holds `h` rows of `src_pitch`
/// bytes; `dst` receives `h * factor` rows of `w * factor` indices at `dst_pitch`. `src` and
/// `dst` must not overlap. An empty image is a no-op.
pub fn scale(
    src: []const u8,
    w: u32,
    h: u32,
    src_pitch: usize,
    factor: u32,
    opts: Options,
    dst: []u8,
    dst_pitch: usize,
) Error!void {
    if (!isSupportedScale(factor)) return error.UnsupportedScale;
    if (w == 0 or h == 0) return;
    if (w > max_dim or h > max_dim) return error.TooLarge;
    if (src_pitch < w) return error.BadPitch;
    if (dst_pitch < @as(usize, w) * factor) return error.BadPitch;
    const src_len = std.math.add(usize, std.math.mul(usize, h - 1, src_pitch) catch return error.TooLarge, w) catch
        return error.TooLarge;
    if (src.len < src_len) return error.SrcTooSmall;
    const need = dstLen(w, h, factor, dst_pitch) orelse return error.TooLarge;
    if (dst.len < need) return error.DstTooSmall;

    const img: Checked = .{ .px = src, .w = @intCast(w), .h = @intCast(h), .pitch = src_pitch, .edge = opts.edge };
    const lt = lumaTable(opts);
    switch (factor) {
        1 => for (0..h) |y| @memcpy(dst[y * dst_pitch ..][0..w], src[y * src_pitch ..][0..w]),
        2 => scale2(img, &lt, dst, dst_pitch),
        3, 4 => scaleTiled(img, &lt, factor, dst, dst_pitch),
        else => unreachable,
    }
}

// --- sampling -----------------------------------------------------------------------------------

/// The source image with the edge policy applied to every read.
const Checked = struct {
    px: []const u8,
    w: i32,
    h: i32,
    pitch: usize,
    edge: EdgeMode,

    inline fn at(self: Checked, x0: i32, y0: i32) u8 {
        var x = x0;
        var y = y0;
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) {
            if (self.edge == .zero) return 0;
            x = std.math.clamp(x, 0, self.w - 1);
            y = std.math.clamp(y, 0, self.h - 1);
        }
        return self.px[@as(usize, @intCast(y)) * self.pitch + @as(usize, @intCast(x))];
    }

    /// True when every read of the 2x rules at (x, y) lands inside the image.
    inline fn interior(self: Checked, x: i32, y: i32) bool {
        return x >= reach and y >= reach and x < self.w - reach and y < self.h - reach;
    }
};

/// A buffer every read of which is known to be in bounds. `origin` is the index of (0, 0).
const Direct = struct {
    px: [*]const u8,
    origin: usize,
    pitch: usize,

    inline fn at(self: Direct, x: i32, y: i32) u8 {
        const off = @as(isize, y) * @as(isize, @intCast(self.pitch)) + x;
        return self.px[@intCast(@as(isize, @intCast(self.origin)) + off)];
    }
};

/// The farthest any rule reads from its centre pixel.
const reach = 3;

// --- the 2x rules -------------------------------------------------------------------------------

/// The 2x2 block `{J, K, L, M}` (top-left, top-right, bottom-left, bottom-right) that pixel
/// (x, y) of `s` becomes. The neighbourhood, named as in the paper:
///
///         P
///       A B C
///     Q D E F R
///       G H I
///         S
///
/// plus the distance-3 samples (x +- 3, y), (x, y +- 3) and the 2:1 corner samples
/// (x +- 2, y +- 1), (x +- 1, y +- 2). Later rules overwrite earlier ones, in the reference's order.
fn block(comptime S: type, s: S, x: i32, y: i32, lt: *const [256]u32) [4]u8 {
    const A = s.at(x - 1, y - 1);
    const B = s.at(x, y - 1);
    const C = s.at(x + 1, y - 1);
    const D = s.at(x - 1, y);
    const E = s.at(x, y);
    const F = s.at(x + 1, y);
    const G = s.at(x - 1, y + 1);
    const H = s.at(x, y + 1);
    const I = s.at(x + 1, y + 1);

    var J = E;
    var K = E;
    var L = E;
    var M = E;

    if (A == E and B == E and C == E and D == E and F == E and G == E and H == E and I == E)
        return .{ E, E, E, E };

    const P = s.at(x, y - 2);
    const Q = s.at(x - 2, y);
    const R = s.at(x + 2, y);
    const S_ = s.at(x, y + 2);
    const Bl = lt[B];
    const Dl = lt[D];
    const El = lt[E];
    const Fl = lt[F];
    const Hl = lt[H];

    // 1:1 slopes: round a corner onto a diagonal, but keep square corners, break the tie between
    // the two sides of a thick diagonal by brightness, and keep dark 1-pixel bumps on lines.
    if ((D == B and D != H and D != F) and (El >= Dl or E == A) and any3(E, A, C, G) and
        (El < Dl or A != D or E != P or E != Q)) J = D;
    if ((B == F and B != D and B != H) and (El >= Bl or E == C) and any3(E, A, C, I) and
        (El < Bl or C != B or E != P or E != R)) K = B;
    if ((H == D and H != F and H != B) and (El >= Hl or E == G) and any3(E, A, G, I) and
        (El < Hl or G != H or E != S_ or E != Q)) L = H;
    if ((F == H and F != B and F != D) and (El >= Fl or E == I) and any3(E, C, G, I) and
        (El < Fl or I != H or E != R or E != S_)) M = F;

    // Intersections: reconnect a line broken at a diagonal crossing, unless the pattern is the
    // notch of a checkerboard dither (the distance-3 sample).
    if ((E != F and all4(E, C, I, D, Q) and all2(F, B, H)) and F != s.at(x + 3, y)) {
        K = F;
        M = F;
    }
    if ((E != D and all4(E, A, G, F, R) and all2(D, B, H)) and D != s.at(x - 3, y)) {
        J = D;
        L = D;
    }
    if ((E != H and all4(E, G, I, B, P) and all2(H, D, F)) and H != s.at(x, y + 3)) {
        L = H;
        M = H;
    }
    if ((E != B and all4(E, A, C, H, S_) and all2(B, D, F)) and B != s.at(x, y - 3)) {
        J = B;
        K = B;
    }

    // Triangle tips: square off the tip of a bright triangle or diamond on a darker background.
    if (Bl < El and all4(E, G, H, I, S_) and none4(E, A, D, C, F)) {
        J = B;
        K = B;
    }
    if (Hl < El and all4(E, A, B, C, P) and none4(E, D, G, I, F)) {
        L = H;
        M = H;
    }
    if (Fl < El and all4(E, A, D, G, Q) and none4(E, B, C, I, H)) {
        K = F;
        M = F;
    }
    if (Dl < El and all4(E, C, F, I, R) and none4(E, B, A, G, H)) {
        J = D;
        L = D;
    }

    // 2:1 and 1:2 slopes of one colour: extend an already-assigned output along the slope.
    if (H != B) {
        if (H != A and H != E and H != C) {
            if (all3(H, G, F, R) and none2(H, D, s.at(x + 2, y - 1))) L = M;
            if (all3(H, I, D, Q) and none2(H, F, s.at(x - 2, y - 1))) M = L;
        }
        if (B != I and B != G and B != E) {
            if (all3(B, A, F, R) and none2(B, D, s.at(x + 2, y + 1))) J = K;
            if (all3(B, C, D, Q) and none2(B, F, s.at(x - 2, y + 1))) K = J;
        }
    }
    if (F != D) {
        if (D != I and D != E and D != C) {
            if (all3(D, A, H, S_) and none2(D, B, s.at(x + 1, y + 2))) J = L;
            if (all3(D, G, B, P) and none2(D, H, s.at(x + 1, y - 2))) L = J;
        }
        if (F != E and F != A and F != G) {
            if (all3(F, C, H, S_) and none2(F, B, s.at(x - 1, y + 2))) K = M;
            if (all3(F, I, B, P) and none2(F, H, s.at(x - 1, y - 2))) M = K;
        }
    }

    return .{ J, K, L, M };
}

inline fn all2(b: u8, a0: u8, a1: u8) bool {
    return b == a0 and b == a1;
}
inline fn all3(b: u8, a0: u8, a1: u8, a2: u8) bool {
    return b == a0 and b == a1 and b == a2;
}
inline fn all4(b: u8, a0: u8, a1: u8, a2: u8, a3: u8) bool {
    return b == a0 and b == a1 and b == a2 and b == a3;
}
inline fn any3(b: u8, a0: u8, a1: u8, a2: u8) bool {
    return b == a0 or b == a1 or b == a2;
}
inline fn none2(b: u8, a0: u8, a1: u8) bool {
    return b != a0 and b != a1;
}
inline fn none4(b: u8, a0: u8, a1: u8, a2: u8, a3: u8) bool {
    return b != a0 and b != a1 and b != a2 and b != a3;
}

/// The block of source pixel (x, y), skipping the edge policy where no read can leave the image.
inline fn srcBlock(img: Checked, x: i32, y: i32, lt: *const [256]u32) [4]u8 {
    if (img.interior(x, y)) {
        const d: Direct = .{ .px = img.px.ptr, .origin = 0, .pitch = img.pitch };
        return block(Direct, d, x, y, lt);
    }
    return block(Checked, img, x, y, lt);
}

fn scale2(img: Checked, lt: *const [256]u32, dst: []u8, dp: usize) void {
    var y: i32 = 0;
    while (y < img.h) : (y += 1) {
        const row0 = @as(usize, @intCast(y)) * 2 * dp;
        var x: i32 = 0;
        while (x < img.w) : (x += 1) {
            const b = srcBlock(img, x, y, lt);
            const o = row0 + @as(usize, @intCast(x)) * 2;
            dst[o] = b[0];
            dst[o + 1] = b[1];
            dst[o + dp] = b[2];
            dst[o + dp + 1] = b[3];
        }
    }
}

// --- 3x and 4x ----------------------------------------------------------------------------------

/// Side of the 2x-image square processed at a time. Even, so a tile starts on a source pixel;
/// the tile plus its halo and the luma table stay under one 4 KiB page of stack, which keeps
/// Windows targets free of stack-probe calls.
const tile = 40;
const tile_span = tile + 2 * reach;

/// Runs the second MMPX pass over the 2x image one tile at a time. Each tile is the 2x image over
/// the tile plus a `reach`-wide halo, recomputed from the source, with the edge policy applied at
/// the 2x image's own border - the same reads a full-size 2x buffer would give.
fn scaleTiled(img: Checked, lt: *const [256]u32, factor: u32, dst: []u8, dp: usize) void {
    const w2 = img.w * 2;
    const h2 = img.h * 2;
    var buf: [tile_span * tile_span]u8 = undefined;

    var ty: i32 = 0;
    while (ty < h2) : (ty += tile) {
        const th = @min(tile, h2 - ty);
        var tx: i32 = 0;
        while (tx < w2) : (tx += tile) {
            const tw = @min(tile, w2 - tx);
            fillTile(img, lt, &buf, tx, ty, tw, th);
            const t: Direct = .{ .px = &buf, .origin = reach * tile_span + reach, .pitch = tile_span };

            if (factor == 4) {
                var y: i32 = 0;
                while (y < th) : (y += 1) {
                    const row0 = @as(usize, @intCast(ty + y)) * 2 * dp;
                    var x: i32 = 0;
                    while (x < tw) : (x += 1) {
                        const b = block(Direct, t, x, y, lt);
                        const o = row0 + @as(usize, @intCast(tx + x)) * 2;
                        dst[o] = b[0];
                        dst[o + 1] = b[1];
                        dst[o + dp] = b[2];
                        dst[o + dp + 1] = b[3];
                    }
                }
            } else {
                // One source pixel is a 2x2 of the tile, i.e. a 4x4 of the 4x image.
                var y: i32 = 0;
                while (y < th) : (y += 2) {
                    var x: i32 = 0;
                    while (x < tw) : (x += 2) {
                        var q: [4][4]u8 = undefined;
                        for (0..2) |dy| for (0..2) |dx| {
                            const b = block(Direct, t, x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), lt);
                            q[2 * dy][2 * dx] = b[0];
                            q[2 * dy][2 * dx + 1] = b[1];
                            q[2 * dy + 1][2 * dx] = b[2];
                            q[2 * dy + 1][2 * dx + 1] = b[3];
                        };
                        const sx = @divExact(tx + x, 2);
                        const sy = @divExact(ty + y, 2);
                        const r = resample4to3(q, img.at(sx, sy));
                        const o = @as(usize, @intCast(sy)) * 3 * dp + @as(usize, @intCast(sx)) * 3;
                        for (0..3) |ry| @memcpy(dst[o + ry * dp ..][0..3], &r[ry]);
                    }
                }
            }
        }
    }
}

/// Fill `buf` with the 2x image over [tx - reach, tx + tw + reach) x [ty - reach, ty + th + reach).
fn fillTile(img: Checked, lt: *const [256]u32, buf: *[tile_span * tile_span]u8, tx: i32, ty: i32, tw: i32, th: i32) void {
    const w2 = img.w * 2;
    const h2 = img.h * 2;
    const x0 = tx - reach;
    const y0 = ty - reach;
    const x1 = tx + tw + reach;
    const y1 = ty + th + reach;
    // The part of the tile rectangle inside the 2x image.
    const ix0 = @max(x0, 0);
    const iy0 = @max(y0, 0);
    const ix1 = @min(x1, w2);
    const iy1 = @min(y1, h2);

    const put = struct {
        inline fn f(b: *[tile_span * tile_span]u8, bx: i32, by: i32, v: u8) void {
            b[@as(usize, @intCast(by)) * tile_span + @as(usize, @intCast(bx))] = v;
        }
    }.f;
    const get = struct {
        inline fn f(b: *const [tile_span * tile_span]u8, bx: i32, by: i32) u8 {
            return b[@as(usize, @intCast(by)) * tile_span + @as(usize, @intCast(bx))];
        }
    }.f;

    var sy = @divFloor(iy0, 2);
    while (sy * 2 < iy1) : (sy += 1) {
        var sx = @divFloor(ix0, 2);
        while (sx * 2 < ix1) : (sx += 1) {
            const b = srcBlock(img, sx, sy, lt);
            for (0..2) |dy| for (0..2) |dx| {
                const X = sx * 2 + @as(i32, @intCast(dx));
                const Y = sy * 2 + @as(i32, @intCast(dy));
                if (X >= ix0 and X < ix1 and Y >= iy0 and Y < iy1) put(buf, X - x0, Y - y0, b[dy * 2 + dx]);
            };
        }
    }

    // The halo outside the 2x image. A clamped coordinate always lies inside the filled part:
    // a tile only reaches past an edge when it touches that edge.
    var Y = y0;
    while (Y < y1) : (Y += 1) {
        const inside_row = Y >= 0 and Y < h2;
        var X = x0;
        while (X < x1) : (X += 1) {
            if (inside_row and X >= 0 and X < w2) continue;
            const v = switch (img.edge) {
                .zero => 0,
                .clamp => get(buf, std.math.clamp(X, 0, w2 - 1) - x0, std.math.clamp(Y, 0, h2 - 1) - y0),
            };
            put(buf, X - x0, Y - y0, v);
        }
    }
}

/// One source pixel's 4x4 block of the 4x image, reduced to its 3x3 block of the 3x image by
/// sampling at output pixel centres. Output column 0 of the block is centred 2/3 of the way into
/// 4x column 0, and column 2 inside 4x column 3; column 1's centre falls exactly on the edge
/// between 4x columns 1 and 2 (and the middle pixel on the corner of the central 2x2), so point
/// sampling there has no answer that survives mirroring. Those pixels take the most frequent of
/// the candidates they touch; a tie goes to `e`, the source pixel, when it is among the tied,
/// else to the lowest index. That choice depends only on which candidates there are, so the
/// result is exactly mirror- and transpose-symmetric, and it is always one of the candidates.
pub fn resample4to3(q: [4][4]u8, e: u8) [3][3]u8 {
    return .{
        .{ q[0][0], pick(&.{ q[0][1], q[0][2] }, e), q[0][3] },
        .{ pick(&.{ q[1][0], q[2][0] }, e), pick(&.{ q[1][1], q[1][2], q[2][1], q[2][2] }, e), pick(&.{ q[1][3], q[2][3] }, e) },
        .{ q[3][0], pick(&.{ q[3][1], q[3][2] }, e), q[3][3] },
    };
}

fn pick(c: []const u8, e: u8) u8 {
    var best = c[0];
    var best_n: usize = 0;
    for (c) |v| {
        var n: usize = 0;
        for (c) |u| n += @intFromBool(u == v);
        const better = n > best_n or (n == best_n and v != best and
            (v == e or (best != e and v < best)));
        if (better) {
            best = v;
            best_n = n;
        }
    }
    return best;
}
