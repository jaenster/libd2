//! A CPU rasteriser for the renderer's draws: triangles with a colour and a texture coordinate per
//! vertex, a texture sampled nearest or linear, the texture unit's modulate (texel times colour,
//! times a scale), an alpha test, and the blend modes the world passes use. It follows what a GL
//! implementation does with these draws, closely enough for a block-by-block comparison against
//! the GL renderer's frames: pixel centres at half-integers, a pixel drawn when its centre is inside
//! the triangle (ties go to top and left edges), attributes interpolated linearly in screen space,
//! colours converted to 8 bits by rounding.
//!
//! The target is RGBA8, top row first; positions are in its pixels, y down.
const std = @import("std");

pub const Target = struct {
    w: u32,
    h: u32,
    px: []u8,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Target {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        for (0..@as(usize, w) * h) |i| px[i * 4 + 3] = 255;
        return .{ .w = w, .h = h, .px = px };
    }

    pub fn deinit(t: *Target, gpa: std.mem.Allocator) void {
        gpa.free(t.px);
    }
};

/// A texture: RGBA8 texels, top row first (the row a texture coordinate v of 0 reads).
pub const Texture = struct {
    w: u32,
    h: u32,
    texels: []const u8,
    filter: Filter = .nearest,
    /// GL_REPEAT; else the texel coordinate is clamped to the edge (a rectangle texture).
    repeat: bool = true,
};

pub const Filter = enum { nearest, linear };

pub const Vertex = struct {
    x: f32,
    y: f32,
    /// Texel units.
    u: f32 = 0,
    v: f32 = 0,
    /// 0..255.
    r: f32 = 255,
    g: f32 = 255,
    b: f32 = 255,
    a: f32 = 255,
};

pub const Blend = enum {
    /// The fragment replaces the target.
    off,
    /// src * a + dst * (1 - a).
    alpha,
    /// dst * src (the target multiplied by the fragment's colour).
    multiply,
};

pub const State = struct {
    texture: ?*const Texture = null,
    /// The texture unit's RGB scale (GL_RGB_SCALE): 1, 2 or 4.
    rgb_scale: f32 = 1,
    blend: Blend = .off,
    /// Discard a fragment whose alpha is 0 (glAlphaFunc(GL_NOTEQUAL, 0)).
    alpha_test: bool = true,
    /// Restrict drawing to this rectangle of the target (x0, y0 inclusive, x1, y1 exclusive).
    clip: [4]i32 = .{ std.math.minInt(i32), std.math.minInt(i32), std.math.maxInt(i32), std.math.maxInt(i32) },
};

/// A fragment program: given the interpolated attributes, the colour (0..1 each) to blend, or null
/// to discard. `fixed` is the texture unit's modulate; a custom one is passed for the light pass.
pub fn Program(comptime Ctx: type) type {
    return fn (ctx: Ctx, st: *const State, at: *const Vertex) ?[4]f32;
}

pub fn fixed(_: void, st: *const State, at: *const Vertex) ?[4]f32 {
    var c: [4]f32 = .{ at.r / 255.0, at.g / 255.0, at.b / 255.0, at.a / 255.0 };
    if (st.texture) |t| {
        const s = sample(t, at.u, at.v);
        c[0] = @min(1.0, s[0] * c[0] * st.rgb_scale);
        c[1] = @min(1.0, s[1] * c[1] * st.rgb_scale);
        c[2] = @min(1.0, s[2] * c[2] * st.rgb_scale);
        c[3] = s[3] * c[3];
    }
    return c;
}

fn texel(t: *const Texture, x: i32, y: i32) [4]f32 {
    const w: i32 = @intCast(t.w);
    const h: i32 = @intCast(t.h);
    const xx = if (t.repeat) @mod(x, w) else std.math.clamp(x, 0, w - 1);
    const yy = if (t.repeat) @mod(y, h) else std.math.clamp(y, 0, h - 1);
    const p = t.texels[(@as(usize, @intCast(yy)) * t.w + @as(usize, @intCast(xx))) * 4 ..][0..4];
    return .{ @as(f32, @floatFromInt(p[0])) / 255.0, @as(f32, @floatFromInt(p[1])) / 255.0, @as(f32, @floatFromInt(p[2])) / 255.0, @as(f32, @floatFromInt(p[3])) / 255.0 };
}

/// The texture at texel coordinate (u, v).
pub fn sample(t: *const Texture, u: f32, v: f32) [4]f32 {
    switch (t.filter) {
        .nearest => return texel(t, @intFromFloat(@floor(u)), @intFromFloat(@floor(v))),
        .linear => {
            const fu = u - 0.5;
            const fv = v - 0.5;
            const x0: i32 = @intFromFloat(@floor(fu));
            const y0: i32 = @intFromFloat(@floor(fv));
            // 8 bits of sub-texel weight, as GPUs keep
            const au = @round((fu - @floor(fu)) * 256.0) / 256.0;
            const av = @round((fv - @floor(fv)) * 256.0) / 256.0;
            const t00 = texel(t, x0, y0);
            const t10 = texel(t, x0 + 1, y0);
            const t01 = texel(t, x0, y0 + 1);
            const t11 = texel(t, x0 + 1, y0 + 1);
            var out: [4]f32 = undefined;
            for (0..4) |k| {
                const top = t00[k] * (1 - au) + t10[k] * au;
                const bot = t01[k] * (1 - au) + t11[k] * au;
                out[k] = top * (1 - av) + bot * av;
            }
            return out;
        },
    }
}

fn edge(a: *const Vertex, b: *const Vertex, px: f64, py: f64) f64 {
    return (@as(f64, b.x) - a.x) * (py - a.y) - (@as(f64, b.y) - a.y) * (px - a.x);
}

/// Whether an edge from a to b (in a triangle wound so that inside is positive) is a top or left
/// edge, the ones that own the pixels whose centres lie exactly on them.
fn topLeft(a: *const Vertex, b: *const Vertex) bool {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    // y down and wound so that edge() is positive inside, the triangle runs clockwise on the screen:
    // its top edge goes right, its left edges go up.
    return (dy == 0 and dx > 0) or dy < 0;
}

fn toByte(f: f32) u8 {
    const c = std.math.clamp(f, 0.0, 1.0);
    return @intFromFloat(@round(c * 255.0));
}

/// One triangle.
pub fn triangle(tg: *Target, st: *const State, comptime Ctx: type, ctx: Ctx, comptime prog: Program(Ctx), v0: Vertex, v1: Vertex, v2: Vertex) void {
    var a = v0;
    var b = v1;
    var c = v2;
    var area = edge(&a, &b, c.x, c.y);
    if (area == 0) return;
    if (area < 0) {
        std.mem.swap(Vertex, &b, &c);
        area = -area;
    }
    const minx = @max(@as(i32, @intFromFloat(@floor(@min(a.x, @min(b.x, c.x))))), @max(0, st.clip[0]));
    const maxx = @min(@as(i32, @intFromFloat(@ceil(@max(a.x, @max(b.x, c.x))))), @min(@as(i32, @intCast(tg.w)), st.clip[2]));
    const miny = @max(@as(i32, @intFromFloat(@floor(@min(a.y, @min(b.y, c.y))))), @max(0, st.clip[1]));
    const maxy = @min(@as(i32, @intFromFloat(@ceil(@max(a.y, @max(b.y, c.y))))), @min(@as(i32, @intCast(tg.h)), st.clip[3]));
    if (minx >= maxx or miny >= maxy) return;
    const tl0 = topLeft(&b, &c);
    const tl1 = topLeft(&c, &a);
    const tl2 = topLeft(&a, &b);
    var y = miny;
    while (y < maxy) : (y += 1) {
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        var x = minx;
        while (x < maxx) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const w0 = edge(&b, &c, px, py);
            const w1 = edge(&c, &a, px, py);
            const w2 = edge(&a, &b, px, py);
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;
            if ((w0 == 0 and !tl0) or (w1 == 0 and !tl1) or (w2 == 0 and !tl2)) continue;
            const l0: f32 = @floatCast(w0 / area);
            const l1: f32 = @floatCast(w1 / area);
            const l2: f32 = @floatCast(w2 / area);
            const at: Vertex = .{
                .x = @floatCast(px),
                .y = @floatCast(py),
                .u = a.u * l0 + b.u * l1 + c.u * l2,
                .v = a.v * l0 + b.v * l1 + c.v * l2,
                .r = a.r * l0 + b.r * l1 + c.r * l2,
                .g = a.g * l0 + b.g * l1 + c.g * l2,
                .b = a.b * l0 + b.b * l1 + c.b * l2,
                .a = a.a * l0 + b.a * l1 + c.a * l2,
            };
            const frag = prog(ctx, st, &at) orelse continue;
            if (st.alpha_test and toByte(frag[3]) == 0) continue;
            const d = tg.px[(@as(usize, @intCast(y)) * tg.w + @as(usize, @intCast(x))) * 4 ..][0..3];
            switch (st.blend) {
                .off => for (0..3) |k| {
                    d[k] = toByte(frag[k]);
                },
                .alpha => for (0..3) |k| {
                    const dst = @as(f32, @floatFromInt(d[k])) / 255.0;
                    d[k] = toByte(frag[k] * frag[3] + dst * (1 - frag[3]));
                },
                .multiply => for (0..3) |k| {
                    const dst = @as(f32, @floatFromInt(d[k])) / 255.0;
                    d[k] = toByte(dst * frag[k]);
                },
            }
        }
    }
}

/// A GL_TRIANGLE_STRIP.
pub fn strip(tg: *Target, st: *const State, comptime Ctx: type, ctx: Ctx, comptime prog: Program(Ctx), vs: []const Vertex) void {
    if (vs.len < 3) return;
    for (0..vs.len - 2) |i| triangle(tg, st, Ctx, ctx, prog, vs[i], vs[i + 1], vs[i + 2]);
}

/// A GL_TRIANGLE_FAN (and GL_QUADS of one quad).
pub fn fan(tg: *Target, st: *const State, comptime Ctx: type, ctx: Ctx, comptime prog: Program(Ctx), vs: []const Vertex) void {
    if (vs.len < 3) return;
    for (1..vs.len - 1) |i| triangle(tg, st, Ctx, ctx, prog, vs[0], vs[i], vs[i + 1]);
}

test "two triangles of a quad cover each pixel once" {
    const gpa = std.testing.allocator;
    var tg = try Target.init(gpa, 8, 8);
    defer tg.deinit(gpa);
    const st: State = .{ .blend = .alpha, .alpha_test = false };
    // half-transparent white twice over the same pixel would show as more than half
    const q = [_]Vertex{
        .{ .x = 1, .y = 1, .a = 128 }, .{ .x = 1, .y = 7, .a = 128 },
        .{ .x = 7, .y = 7, .a = 128 }, .{ .x = 7, .y = 1, .a = 128 },
    };
    fan(&tg, &st, void, {}, fixed, &q);
    var n: usize = 0;
    for (0..64) |i| {
        const r = tg.px[i * 4];
        try std.testing.expect(r == 0 or r == 128);
        if (r == 128) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 36), n);
}
