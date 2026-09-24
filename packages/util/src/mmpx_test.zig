const std = @import("std");
const mmpx = @import("mmpx.zig");

const testing = std.testing;
const Options = mmpx.Options;

const max_side = 80;
const max_out = (max_side * 4) * (max_side * 4);

fn run(src: []const u8, w: u32, h: u32, factor: u32, opts: Options, out: []u8) !void {
    try mmpx.scale(src, w, h, w, factor, opts, out[0 .. w * factor * h * factor], w * factor);
}

fn nearest(src: []const u8, w: u32, h: u32, factor: u32, out: []u8) void {
    const ow = w * factor;
    for (0..h * factor) |y| for (0..ow) |x| {
        out[y * ow + x] = src[(y / factor) * w + x / factor];
    };
}

const all_modes = [_]Options{
    .{},
    .{ .edge = .zero },
    .{ .index0_transparent = false },
    .{ .edge = .zero, .palette = &test_palette },
    .{ .palette = &test_palette },
};

const test_palette: [768]u8 = blk: {
    var p: [768]u8 = undefined;
    for (0..256) |i| {
        p[3 * i] = @truncate(i *% 97);
        p[3 * i + 1] = @truncate(i *% 31 +% 7);
        p[3 * i + 2] = @truncate(i *% 13 +% 101);
    }
    break :blk p;
};

test "a constant image stays constant at every scale" {
    var src: [7 * 5]u8 = @splat(42);
    var out: [max_out]u8 = undefined;
    for (all_modes) |o| for (1..5) |f| {
        const fu: u32 = @intCast(f);
        try run(&src, 7, 5, fu, o, &out);
        for (out[0 .. 7 * 5 * fu * fu]) |v| try testing.expectEqual(@as(u8, 42), v);
    };
    // Index 0 everywhere, with .zero edges reading the same index.
    src = @splat(0);
    for (all_modes) |o| for (1..5) |f| {
        const fu: u32 = @intCast(f);
        try run(&src, 7, 5, fu, o, &out);
        for (out[0 .. 7 * 5 * fu * fu]) |v| try testing.expectEqual(@as(u8, 0), v);
    };
}

test "a solid block on a background stays a nearest-neighbour block" {
    const w = 10;
    const h = 9;
    var src: [w * h]u8 = @splat(1);
    for (2..6) |y| for (3..8) |x| {
        src[y * w + x] = 9;
    };
    var out: [max_out]u8 = undefined;
    var want: [max_out]u8 = undefined;
    for (all_modes) |o| for (2..5) |f| {
        const fu: u32 = @intCast(f);
        try run(&src, w, h, fu, o, &out);
        nearest(&src, w, h, fu, &want);
        try testing.expectEqualSlices(u8, want[0 .. w * h * fu * fu], out[0 .. w * h * fu * fu]);
    };
}

test "horizontal and vertical lines stay straight" {
    const w = 9;
    const h = 8;
    var src: [w * h]u8 = @splat(3);
    for (0..w) |x| src[3 * w + x] = 200;
    for (0..h) |y| src[y * w + 6] = 17;
    var out: [max_out]u8 = undefined;
    var want: [max_out]u8 = undefined;
    for (all_modes) |o| {
        if (o.edge == .zero) continue; // a line running into a zero border is a T-junction
        for (2..5) |f| {
            const fu: u32 = @intCast(f);
            try run(&src, w, h, fu, o, &out);
            nearest(&src, w, h, fu, &want);
            try testing.expectEqualSlices(u8, want[0 .. w * h * fu * fu], out[0 .. w * h * fu * fu]);
        }
    }
}

test "an isolated pixel is kept as a full factor x factor block" {
    const w = 9;
    const h = 9;
    var src: [w * h]u8 = @splat(1);
    src[4 * w + 4] = 77;
    var out: [max_out]u8 = undefined;
    var want: [max_out]u8 = undefined;
    for (all_modes) |o| for (2..5) |f| {
        const fu: u32 = @intCast(f);
        try run(&src, w, h, fu, o, &out);
        nearest(&src, w, h, fu, &want);
        try testing.expectEqualSlices(u8, want[0 .. w * h * fu * fu], out[0 .. w * h * fu * fu]);
    };
    // A dark pixel on a bright background, and a transparent hole in an opaque sprite.
    src = @splat(250);
    src[4 * w + 4] = 2;
    for (all_modes) |o| {
        try run(&src, w, h, 2, o, &out);
        nearest(&src, w, h, 2, &want);
        try testing.expectEqualSlices(u8, want[0 .. w * h * 4], out[0 .. w * h * 4]);
    }
    src[4 * w + 4] = 0;
    for (all_modes) |o| {
        try run(&src, w, h, 2, o, &out);
        nearest(&src, w, h, 2, &want);
        // .zero reads index 0 outside, which is the hole's own index - still no pixel of the hole
        // may move, so only the hole's block is checked there.
        for (8..10) |y| try testing.expectEqualSlices(u8, want[y * 18 + 8 ..][0..2], out[y * 18 + 8 ..][0..2]);
        if (o.edge == .clamp) try testing.expectEqualSlices(u8, want[0 .. w * h * 4], out[0 .. w * h * 4]);
    }
}

test "a checkerboard magnifies to nearest neighbour at 2x" {
    const w = 8;
    const h = 8;
    var src: [w * h]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        src[y * w + x] = if ((x + y) % 2 == 0) 5 else 60;
    };
    var out: [max_out]u8 = undefined;
    var want: [max_out]u8 = undefined;
    for (all_modes) |o| {
        if (o.edge == .zero) continue;
        try run(&src, w, h, 2, o, &out);
        nearest(&src, w, h, 2, &want);
        // Clamping repeats the edge column, which breaks the pattern at the two corners where the
        // repeat meets a diagonal; everything off the border ring is untouched.
        for (2..2 * h - 2) |y| try testing.expectEqualSlices(u8, want[y * 2 * w + 2 ..][0 .. 2 * w - 4], out[y * 2 * w + 2 ..][0 .. 2 * w - 4]);
    }
}

test "1:1 diagonal: the background fills the inner corners (hand-derived)" {
    // Index 5 on the main diagonal of index 1. No palette, so 5 ranks brighter than 1.
    // Derivation, for a line pixel (k, k): every rule needs a neighbour equal to E, or a constant
    // side, and there is neither, so it stays {5,5,5,5}. For the background pixel to its right,
    // (k+1, k): D = H = 5, F = B = 1, E = G = 1, so the 1:1 rule for L fires (E == G admits it
    // even though E is darker, and El < Hl passes the last clause) and nothing later touches it:
    // {1,1,5,1}. Its transpose (k, k+1) gets {1,5,1,1}. Everything else stays 1.
    const w = 10;
    var src: [w * w]u8 = @splat(1);
    for (0..w) |k| src[k * w + k] = 5;
    var out: [max_out]u8 = undefined;
    try run(&src, w, w, 2, .{}, &out);
    // The 2x rows 6..13, columns 6..13: source pixels 3..6.
    const want = [8][8]u8{
        .{ 5, 5, 1, 1, 1, 1, 1, 1 },
        .{ 5, 5, 5, 1, 1, 1, 1, 1 },
        .{ 1, 5, 5, 5, 1, 1, 1, 1 },
        .{ 1, 1, 5, 5, 5, 1, 1, 1 },
        .{ 1, 1, 1, 5, 5, 5, 1, 1 },
        .{ 1, 1, 1, 1, 5, 5, 5, 1 },
        .{ 1, 1, 1, 1, 1, 5, 5, 5 },
        .{ 1, 1, 1, 1, 1, 1, 5, 5 },
    };
    for (0..8) |r| try testing.expectEqualSlices(u8, &want[r], out[(6 + r) * 20 + 6 ..][0..8]);
}

test "2:1 slope: runs of 2 stepping by 1 become runs of 6 stepping by 2 (hand-derived)" {
    // Row k holds index 5 at columns 2k and 2k+1, on index 1.
    // Right of a run, (2k+2, k): the 1:1 rule sets L = H = 5 (E == G), then the second 2:1 rule
    // (H == I == D == Q, H differs from F and from (x-2, y-1)) sets M = L: {1,1,5,5}.
    // Below a run's end, (2k+1, k+1): the 1:1 rule sets K = B = 5 (E == C), then the 2:1 rule
    // (B == A == F == R, B differs from D and from (x+2, y+1)) sets J = K: {5,5,1,1}.
    // Run pixels stay {5,5,5,5}. So 2x row r holds 5 at columns 2r-2 .. 2r+3.
    const w = 16;
    const h = 8;
    var src: [w * h]u8 = @splat(1);
    for (0..h) |k| {
        src[k * w + 2 * k] = 5;
        src[k * w + 2 * k + 1] = 5;
    }
    var out: [max_out]u8 = undefined;
    try run(&src, w, h, 2, .{}, &out);
    for (4..12) |r| {
        for (4..28) |c| {
            const on = c + 2 >= 2 * r and c <= 2 * r + 3;
            try testing.expectEqual(@as(u8, if (on) 5 else 1), out[r * 32 + c]);
        }
    }
}

test "the intersection rule reconnects a line across a diagonal crossing" {
    // The '>' rule's neighbourhood, B = F = H = 7 around E = 2:
    //       P            2
    //     A B C        2 7 2
    //   Q D E F R    2 2 2 7 2
    //     G H I        2 7 2
    //       S            2
    // E == C == I == D == Q, F == B == H, and (x+3, y) = 2 differs from F, so K = M = F = 7.
    // Nothing else fires: B == H blocks the 1:1 rules for K and M, D differs from B and H.
    const w = 9;
    const h = 9;
    var src: [w * h]u8 = @splat(2);
    src[3 * w + 4] = 7; // B
    src[4 * w + 5] = 7; // F
    src[5 * w + 4] = 7; // H
    var out: [max_out]u8 = undefined;
    try run(&src, w, h, 2, .{}, &out);
    // E = (4, 4): its block is at 2x (8, 8).
    try testing.expectEqualSlices(u8, &.{ 2, 7 }, out[8 * 18 + 8 ..][0..2]);
    try testing.expectEqualSlices(u8, &.{ 2, 7 }, out[9 * 18 + 8 ..][0..2]);
}

test "the triangle-tip rule squares off a bright tip on a darker background" {
    // E = (4,4) = 9 with G = H = I = S = 9 below and A = D = C = F = 1: the tip of an upward
    // triangle. B = 1 is darker (no palette: index order), so J = K = B.
    const w = 9;
    const h = 9;
    var src: [w * h]u8 = @splat(1);
    src[4 * w + 4] = 9;
    for (3..6) |x| src[5 * w + x] = 9;
    src[6 * w + 4] = 9;
    var out: [max_out]u8 = undefined;
    try run(&src, w, h, 2, .{}, &out);
    try testing.expectEqualSlices(u8, &.{ 1, 1 }, out[8 * 18 + 8 ..][0..2]);
    try testing.expectEqualSlices(u8, &.{ 9, 9 }, out[9 * 18 + 8 ..][0..2]);
}

test "palette channel order does not change the result" {
    var bgr: [768]u8 = undefined;
    for (0..256) |i| {
        bgr[3 * i] = test_palette[3 * i + 2];
        bgr[3 * i + 1] = test_palette[3 * i + 1];
        bgr[3 * i + 2] = test_palette[3 * i];
    }
    try testing.expectEqual(mmpx.lumaTable(.{ .palette = &test_palette }), mmpx.lumaTable(.{ .palette = &bgr }));
}

test "index 0 ranks as the reference's transparent pixel" {
    var pal: [768]u8 = @splat(0);
    pal[3] = 255;
    pal[4] = 255;
    pal[5] = 255;
    const t = mmpx.lumaTable(.{ .palette = &pal });
    try testing.expectEqual(@as(u32, 256), t[0]); // transparent black: (0 + 1) * 256
    try testing.expectEqual(@as(u32, 766), t[1]); // opaque white: 765 + 1
    try testing.expectEqual(@as(u32, 1), t[2]); // opaque black
    try testing.expectEqual(@as(u32, 1), mmpx.lumaTable(.{ .palette = &pal, .index0_transparent = false })[0]);
    const n = mmpx.lumaTable(.{});
    for (1..256) |i| try testing.expect(n[0] > n[i]);
    try testing.expectEqual(@as(u32, 0), mmpx.lumaTable(.{ .index0_transparent = false })[0]);
}

test "resample4to3 is mirror- and transpose-symmetric and picks a candidate" {
    var prng = std.Random.DefaultPrng.init(0x3a3a);
    const r = prng.random();
    for (0..2000) |_| {
        var q: [4][4]u8 = undefined;
        for (&q) |*row| for (row) |*v| {
            v.* = r.uintLessThan(u8, 4);
        };
        const e = r.uintLessThan(u8, 5);
        const out = mmpx.resample4to3(q, e);
        var mq: [4][4]u8 = undefined;
        var tq: [4][4]u8 = undefined;
        for (0..4) |y| for (0..4) |x| {
            mq[y][x] = q[y][3 - x];
            tq[y][x] = q[x][y];
        };
        const mo = mmpx.resample4to3(mq, e);
        const to = mmpx.resample4to3(tq, e);
        for (0..3) |y| for (0..3) |x| {
            try testing.expectEqual(out[y][2 - x], mo[y][x]);
            try testing.expectEqual(out[x][y], to[y][x]);
        };
        // The corners are exact point samples; the rest come from the 4x pixels they straddle.
        try testing.expectEqual(q[0][0], out[0][0]);
        try testing.expectEqual(q[3][3], out[2][2]);
        const c = out[1][1];
        try testing.expect(c == q[1][1] or c == q[1][2] or c == q[2][1] or c == q[2][2]);
    }
}

/// The 2x pass run twice over whole buffers, the definition the tiled 4x path must reproduce.
fn scale4Reference(src: []const u8, w: u32, h: u32, opts: Options, tmp: []u8, out: []u8) !void {
    try mmpx.scale(src, w, h, w, 2, opts, tmp[0 .. 4 * w * h], 2 * w);
    try mmpx.scale(tmp[0 .. 4 * w * h], 2 * w, 2 * h, 2 * w, 2, opts, out[0 .. 16 * w * h], 4 * w);
}

test "random images: only input indices come out, and 4x/3x equal their definitions" {
    var prng = std.Random.DefaultPrng.init(0x4d4d5058);
    const r = prng.random();
    var src: [max_side * max_side]u8 = undefined;
    var out: [max_out]u8 = undefined;
    var tmp: [max_out / 4]u8 = undefined;
    var ref: [max_out]u8 = undefined;

    for (0..300) |iter| {
        // Mostly small, some large enough to span several of the 40-pixel tiles the 2x image is processed in.
        const big = iter % 10 == 0;
        const w: u32 = if (big) r.intRangeAtMost(u32, 30, max_side) else r.intRangeAtMost(u32, 1, 20);
        const h: u32 = if (big) r.intRangeAtMost(u32, 30, max_side) else r.intRangeAtMost(u32, 1, 20);
        // Few distinct indices, so the rules actually fire.
        const colours = r.intRangeAtMost(u8, 1, 5);
        var set: [5]u8 = undefined;
        for (&set) |*c| c.* = r.int(u8);
        for (src[0 .. w * h]) |*p| p.* = set[r.uintLessThan(u8, colours)];

        var present: [256]bool = @splat(false);
        for (src[0 .. w * h]) |p| present[p] = true;

        var opts: Options = .{
            .edge = if (r.boolean()) .clamp else .zero,
            .index0_transparent = r.boolean(),
        };
        if (r.boolean()) opts.palette = &test_palette;

        for (1..5) |f| {
            const fu: u32 = @intCast(f);
            const n = w * h * fu * fu;
            try run(src[0 .. w * h], w, h, fu, opts, &out);
            for (out[0..n]) |v| {
                // A .zero border reads index 0, which the rules may copy in at the edge.
                try testing.expect(present[v] or (v == 0 and opts.edge == .zero));
            }
        }

        try scale4Reference(src[0 .. w * h], w, h, opts, &tmp, &ref);
        try run(src[0 .. w * h], w, h, 4, opts, &out);
        try testing.expectEqualSlices(u8, ref[0 .. 16 * w * h], out[0 .. 16 * w * h]);

        try run(src[0 .. w * h], w, h, 3, opts, &out);
        for (0..h) |sy| for (0..w) |sx| {
            var q: [4][4]u8 = undefined;
            for (0..4) |y| for (0..4) |x| {
                q[y][x] = ref[(sy * 4 + y) * 4 * w + sx * 4 + x];
            };
            const b = mmpx.resample4to3(q, src[sy * w + sx]);
            for (0..3) |y| try testing.expectEqualSlices(u8, &b[y], out[(sy * 3 + y) * 3 * w + sx * 3 ..][0..3]);
        };
    }
}

test "pitches wider than the row are honoured and the padding is left alone" {
    const w = 5;
    const h = 4;
    const sp = 11;
    var src: [sp * h]u8 = @splat(0xEE);
    var prng = std.Random.DefaultPrng.init(7);
    for (0..h) |y| for (0..w) |x| {
        src[y * sp + x] = prng.random().uintLessThan(u8, 3);
    };
    var packed_src: [w * h]u8 = undefined;
    for (0..h) |y| @memcpy(packed_src[y * w ..][0..w], src[y * sp ..][0..w]);

    for (1..5) |f| {
        const fu: u32 = @intCast(f);
        const dp = w * fu + 3;
        var dst: [(w * 4 + 3) * h * 4]u8 = @splat(0xAB);
        try mmpx.scale(&src, w, h, sp, fu, .{}, &dst, dp);
        var want: [max_out]u8 = undefined;
        try run(&packed_src, w, h, fu, .{}, &want);
        for (0..h * fu) |y| {
            try testing.expectEqualSlices(u8, want[y * w * fu ..][0 .. w * fu], dst[y * dp ..][0 .. w * fu]);
            try testing.expectEqualSlices(u8, &.{ 0xAB, 0xAB, 0xAB }, dst[y * dp + w * fu ..][0..3]);
        }
    }
}

test "argument errors" {
    var src: [16]u8 = @splat(1);
    var dst: [256]u8 = undefined;
    try testing.expectError(error.UnsupportedScale, mmpx.scale(&src, 4, 4, 4, 5, .{}, &dst, 20));
    try testing.expectError(error.UnsupportedScale, mmpx.scale(&src, 4, 4, 4, 0, .{}, &dst, 20));
    try testing.expectError(error.BadPitch, mmpx.scale(&src, 4, 4, 3, 2, .{}, &dst, 8));
    try testing.expectError(error.BadPitch, mmpx.scale(&src, 4, 4, 4, 2, .{}, &dst, 7));
    try testing.expectError(error.SrcTooSmall, mmpx.scale(src[0..15], 4, 4, 4, 2, .{}, &dst, 8));
    try testing.expectError(error.DstTooSmall, mmpx.scale(&src, 4, 4, 4, 2, .{}, dst[0..63], 8));
    try mmpx.scale(&src, 4, 4, 4, 2, .{}, dst[0..64], 8);
    try mmpx.scale(&src, 0, 4, 4, 2, .{}, dst[0..0], 8);
    try testing.expectError(error.TooLarge, mmpx.scale(&src, mmpx.max_dim + 1, 1, mmpx.max_dim + 1, 2, .{}, &dst, 8));
}
