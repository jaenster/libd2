//! Light as the tiles receive it, and the smooth floor light.
//!
//! The client gives each draw light values from its light map (one cell per subtile: intensity and
//! colour). A floor or roof tile gets 36, the points (tile.x * 5 + c, tile.y * 5 + r) for c, r in
//! 0..5, drawn at screen points (X + (c - r) * 16, Y + (c + r) * 8) (DRAW_CalcRoofLightOrtho
//! 0x4de070). A wall gets six, at fixed subtile offsets from its tile's first subtile by its
//! direction (the wall passes 0x4dedf0 and 0x4def80 read them from a table). A tile's vertex
//! colour is intensity * channel / 255 per channel (Glide's lighting table, and the Mac OpenGL
//! renderer's modulate table).
//!
//! The smooth light (D2OpenGL's Lighting=smooth) draws the floor with white vertices and then
//! multiplies it by a spline through the light values: the ground tiles' 36 points are a lattice
//! (one point per subtile corner, a = (x + 2y) / 32, b = (2y - x) / 32 in screen pixels from the
//! first tile's first point), each point the modulated colour; the points beside the filled ones are
//! grown two rings out from their neighbours so the spline has support at the edge; a point is
//! sampled by a Catmull-Rom spline over the 4 x 4 lattice points about it, held within the four
//! nearest values.
const std = @import("std");
const scene = @import("scene.zig");

pub const Cell = scene.Cell;

/// One channel's vertex colour for a light value.
pub fn modulate(intensity: u8, channel: u8) u8 {
    return @intCast(@as(u32, intensity) * channel / 255);
}

pub fn vertexColour(c: Cell) [3]u8 {
    return .{ modulate(c.i, c.r), modulate(c.i, c.g), modulate(c.i, c.b) };
}

/// A wall's six light samples in subtiles from its tile's first subtile, by the tile's direction
/// (1.14d D2Client's wall intensity table, read by the wall passes 0x4dedf0 and 0x4def80).
/// Directions 0 and 5 take none.
pub const wall_samples = [10][6][2]i8{
    .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
    .{ .{ 2, 5 }, .{ 2, 3 }, .{ 2, 1 }, .{ 2, -1 }, .{ 2, -3 }, .{ 2, -5 } },
    .{ .{ -5, 2 }, .{ -3, 2 }, .{ -1, 2 }, .{ 1, 2 }, .{ 3, 2 }, .{ 5, 2 } },
    .{ .{ 2, 5 }, .{ 2, 3 }, .{ 2, 2 }, .{ 2, 2 }, .{ 3, 2 }, .{ 5, 2 } },
    .{ .{ -5, 2 }, .{ -3, 2 }, .{ -1, 2 }, .{ 2, -1 }, .{ 2, -3 }, .{ 2, -5 } },
    .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
    .{ .{ 2, 5 }, .{ 2, 3 }, .{ 2, 1 }, .{ 2, -1 }, .{ 2, -3 }, .{ 2, -5 } },
    .{ .{ -5, 2 }, .{ -3, 2 }, .{ -1, 2 }, .{ 1, 2 }, .{ 3, 2 }, .{ 5, 2 } },
    .{ .{ 2, 5 }, .{ 2, 3 }, .{ 2, 2 }, .{ 2, 2 }, .{ 3, 2 }, .{ 5, 2 } },
    .{ .{ -5, 2 }, .{ -3, 2 }, .{ -1, 2 }, .{ 2, -1 }, .{ 2, -3 }, .{ 2, -5 } },
};
pub const wall_sample_count = [10]u8{ 0, 6, 6, 6, 6, 6, 6, 6, 6, 6 };

/// The light values a wall tile at (tx, ty) gets, 8 of them as the client's array holds (those past
/// the direction's count are zero).
pub fn wallLights(m: *const scene.LightMap, direction: i32, tx: i32, ty: i32) [8]Cell {
    var out = [_]Cell{.{}} ** 8;
    const d: usize = if (direction >= 0 and direction < 10) @intCast(direction) else 0;
    for (0..wall_sample_count[d]) |k| out[k] = m.at(tx * 5 + wall_samples[d][k][0], ty * 5 + wall_samples[d][k][1]);
    return out;
}

pub const lattice_size = 256;
pub const lattice_origin = lattice_size / 2;

/// The screen offset (x, y) of a point as lattice (a, b), when it falls on a point exactly.
pub fn screenToLattice(x: i32, y: i32) ?[2]i32 {
    const a = x + 2 * y;
    const b = 2 * y - x;
    if ((a & 31) != 0 or (b & 31) != 0) return null;
    return .{ @divExact(a, 32), @divExact(b, 32) };
}

const State = enum(u8) { empty, filled, grown, growing };

const Point = struct {
    lit: [3]u8 = .{ 0, 0, 0 },
    state: State = .empty,
    lava: bool = false,
};

pub const Grid = struct {
    points: [lattice_size][lattice_size]Point = undefined,
    min_a: i32 = lattice_size,
    min_b: i32 = lattice_size,
    max_a: i32 = -1,
    max_b: i32 = -1,

    pub fn clear(g: *Grid) void {
        for (&g.points) |*row| @memset(row, .{});
        g.min_a = lattice_size;
        g.min_b = lattice_size;
        g.max_a = -1;
        g.max_b = -1;
    }

    fn inside(a: i32, b: i32) bool {
        return a >= 0 and b >= 0 and a < lattice_size and b < lattice_size;
    }

    fn p(g: *Grid, a: i32, b: i32) *Point {
        return &g.points[@intCast(b)][@intCast(a)];
    }

    fn pc(g: *const Grid, a: i32, b: i32) *const Point {
        return &g.points[@intCast(b)][@intCast(a)];
    }

    fn isSource(g: *const Grid, a: i32, b: i32) bool {
        if (!inside(a, b)) return false;
        const s = g.pc(a, b).state;
        return s == .filled or s == .grown;
    }

    fn grow(g: *Grid, a: i32, b: i32) void {
        g.min_a = @min(g.min_a, a);
        g.min_b = @min(g.min_b, b);
        g.max_a = @max(g.max_a, a);
        g.max_b = @max(g.max_b, b);
    }

    pub fn set(g: *Grid, a: i32, b: i32, c: Cell) void {
        const pt = g.p(a, b);
        if (pt.lava) return;
        pt.lit = vertexColour(c);
        pt.state = .filled;
        g.grow(a, b);
    }

    pub fn setLava(g: *Grid, a: i32, b: i32) void {
        g.set(a, b, .{ .i = 255, .r = 255, .g = 255, .b = 255 });
        g.p(a, b).lava = true;
    }

    /// The two rings about the filled points, each from its filled or grown neighbours, continuing
    /// the slope where a neighbour has one behind it. Earlier rings are dropped first.
    pub fn growBorder(g: *Grid) void {
        if (g.max_a < 0) return;
        {
            var b = g.min_b;
            while (b <= g.max_b) : (b += 1) {
                var a = g.min_a;
                while (a <= g.max_a) : (a += 1) {
                    if (g.p(a, b).state == .grown) g.p(a, b).state = .empty;
                }
            }
        }
        const steps = [4][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
        for (0..2) |_| {
            const lo_a = if (g.min_a > 0) g.min_a - 1 else 0;
            const lo_b = if (g.min_b > 0) g.min_b - 1 else 0;
            const hi_a = if (g.max_a < lattice_size - 1) g.max_a + 1 else lattice_size - 1;
            const hi_b = if (g.max_b < lattice_size - 1) g.max_b + 1 else lattice_size - 1;
            var b = lo_b;
            while (b <= hi_b) : (b += 1) {
                var a = lo_a;
                while (a <= hi_a) : (a += 1) {
                    const pt = g.p(a, b);
                    if (pt.state != .empty) continue;
                    var sum = [3]i32{ 0, 0, 0 };
                    var n: i32 = 0;
                    for (steps) |s| {
                        const na = a + s[0];
                        const nb = b + s[1];
                        if (!g.isSource(na, nb)) continue;
                        const src = g.pc(na, nb);
                        const slope = g.isSource(na + s[0], nb + s[1]);
                        for (0..3) |k| {
                            var v: i32 = src.lit[k];
                            if (slope) v = 2 * v - g.pc(na + s[0], nb + s[1]).lit[k];
                            sum[k] += std.math.clamp(v, 0, 255);
                        }
                        n += 1;
                    }
                    if (n == 0) continue;
                    for (0..3) |k| pt.lit[k] = @intCast(@divTrunc(sum[k] + @divTrunc(n, 2), n));
                    pt.state = .growing;
                }
            }
            b = lo_b;
            while (b <= hi_b) : (b += 1) {
                var a = lo_a;
                while (a <= hi_a) : (a += 1) {
                    if (g.p(a, b).state == .growing) {
                        g.p(a, b).state = .grown;
                        g.grow(a, b);
                    }
                }
            }
        }
    }

    /// A point's value as the light pass reads it: black where nothing was set or grown.
    pub fn lit(g: *const Grid, a: i32, b: i32) [3]u8 {
        if (!inside(a, b) or g.pc(a, b).state == .empty) return .{ 0, 0, 0 };
        return g.pc(a, b).lit;
    }

    /// The spline at lattice point (a, b), 0..255 per channel.
    pub fn sample(g: *const Grid, fa: f32, fb: f32) [3]f32 {
        const ia: i32 = @intFromFloat(@floor(fa));
        const ib: i32 = @intFromFloat(@floor(fb));
        const wa = catmullRom(fa - @floor(fa));
        const wb = catmullRom(fb - @floor(fb));
        var sum = [3]f32{ 0, 0, 0 };
        var lo = [3]f32{ 255, 255, 255 };
        var hi = [3]f32{ 0, 0, 0 };
        for (0..4) |j| for (0..4) |i| {
            const v = g.lit(ia - 1 + @as(i32, @intCast(i)), ib - 1 + @as(i32, @intCast(j)));
            const w = wa[i] * wb[j];
            for (0..3) |k| {
                const f: f32 = @floatFromInt(v[k]);
                sum[k] += w * f;
                if ((i == 1 or i == 2) and (j == 1 or j == 2)) {
                    lo[k] = @min(lo[k], f);
                    hi[k] = @max(hi[k], f);
                }
            }
        };
        for (0..3) |k| sum[k] = std.math.clamp(sum[k], lo[k], hi[k]);
        return sum;
    }
};

pub fn catmullRom(t: f32) [4]f32 {
    const t2 = t * t;
    const t3 = t2 * t;
    return .{
        0.5 * (-t3 + 2 * t2 - t),
        0.5 * (3 * t3 - 5 * t2 + 2),
        0.5 * (-3 * t3 + 4 * t2 + t),
        0.5 * (t3 - t2),
    };
}

test "the spline through a constant lattice is the constant" {
    const g = try std.testing.allocator.create(Grid);
    defer std.testing.allocator.destroy(g);
    g.clear();
    var b: i32 = 100;
    while (b < 110) : (b += 1) {
        var a: i32 = 100;
        while (a < 110) : (a += 1) g.set(a, b, .{ .i = 200, .r = 255, .g = 128, .b = 0 });
    }
    g.growBorder();
    const s = g.sample(104.3, 106.8);
    try std.testing.expectApproxEqAbs(@as(f32, 200), s[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), s[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s[2], 0.001);
    // the grown ring continues the edge
    try std.testing.expectEqual([3]u8{ 200, 100, 0 }, g.lit(98, 104));
}

test "a lattice point is where a subtile corner is" {
    try std.testing.expectEqual([2]i32{ 1, 0 }, screenToLattice(16, 8).?);
    try std.testing.expectEqual([2]i32{ 0, 1 }, screenToLattice(-16, 8).?);
    try std.testing.expect(screenToLattice(3, 8) == null);
}
