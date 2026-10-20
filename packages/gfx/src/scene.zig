//! The scene: what the client hands the renderer for one level, without the client. The DT1s by the
//! path the game loads them under, every tile placement in the client's drawing order, the screen
//! palette, the light map, and the units' layers. A host that lays a level out (libd2's own map
//! generation, or a mod's generator) writes one; `view.zig` draws it.
//!
//! The drawing order is ViewDraw2's (1.14d D2Client 0x476bc0): the Arcane Sanctuary's stars
//! (0x476290) or the Arreat Summit's backdrop (0x476460), the lower walls of orientations 16 to 19
//! under the floor (0x4df480), the floor (0x4ded10), the shadow tiles (0x4df510), the walls with the
//! units between them (0x4df1c0), the roofs (0x4dea70). Within a pass a tile is drawn by its row
//! (tx + ty), then its column (tx - ty), then the order the level placed it in.
//!
//! File layout ("D2PS", version 2), little endian:
//!   "D2PS" u32 version
//!   palette    768 bytes, pal.dat as the game ships it (B, G, R)
//!   u32 files, each: u16 name length, name (data\global\tiles\...), u32 length, the DT1's bytes
//!   u32 draws, each: u8 pass (Pass), u8 0, u16 file, u32 record, i32 tile x, i32 tile y
//!   light map: i32 x0, i32 y0 (subtile of its first cell), u32 w, u32 h, w * h cells of u8
//!       intensity, red, green, blue
//!   u32 palettes, each 256 bytes (a unit's colour table)
//!   u32 cels, each: i32 w, i32 h, i32 offset x, i32 offset y, u8 direction, u8 component, u16 0,
//!       w * h palette indices, top row first
//!   u32 units, each: i32 x, i32 y (its feet, eighths of a subtile), u16 name length, name,
//!       u32 layers, each: u32 cel, u16 palette (0xffff none), u8 draw mode, u8 flags (1: shadow too)
//!   world: u32 level, u32 map seed, u32 day ticks, u32 ticks a degree, i32 level width, i32 height
//!       (in tiles)
//! The scene borrows the bytes it was read from: they must outlive it.
const std = @import("std");

pub const magic = "D2PS";
pub const version: u32 = 2;

/// The tile passes as the file numbers them. `under` was added after the other four, so its number
/// is 4; `rank` is the drawing order.
pub const Pass = enum(u8) {
    floor = 0,
    shadow = 1,
    wall = 2,
    roof = 3,
    under = 4,

    pub fn rank(p: Pass) u8 {
        return switch (p) {
            .under => 0,
            .floor => 1,
            .shadow => 2,
            .wall => 3,
            .roof => 4,
        };
    }
};

pub const File = struct { name: []const u8, bytes: []const u8 };

pub const Draw = struct { pass: Pass, file: u16, rec: u32, tx: i32, ty: i32 };

/// The light of one subtile as the client's light map cell holds it.
pub const Cell = extern struct { i: u8 = 0, r: u8 = 0, g: u8 = 0, b: u8 = 0 };

pub const LightMap = struct {
    x0: i32,
    y0: i32,
    w: u32,
    h: u32,
    cells: []const Cell,

    /// The cell of subtile (sx, sy), clamped to the map's edge as the client clamps
    /// (DRAW_CoordIsInCoord 0x475aa0).
    pub fn at(m: *const LightMap, sx: i32, sy: i32) Cell {
        if (m.w == 0 or m.h == 0) return .{};
        const x = std.math.clamp(sx - m.x0, 0, @as(i32, @intCast(m.w)) - 1);
        const y = std.math.clamp(sy - m.y0, 0, @as(i32, @intCast(m.h)) - 1);
        return m.cells[@as(usize, @intCast(y)) * m.w + @as(usize, @intCast(x))];
    }
};

pub const Cel = struct { w: i32, h: i32, ox: i32, oy: i32, dir: u8, comp: u8, px: []const u8 };

pub const Layer = struct { cel: u32, pal: u16, mode: u8, flags: u8 };

pub const Unit = struct { x8: i32, y8: i32, name: []const u8, layers: []Layer };

pub const World = struct { level: u32 = 0, seed: u32 = 0, ticks: u32 = 0, rate: u32 = 0, w: i32 = 0, h: i32 = 0 };

pub const Scene = struct {
    /// pal.dat order: B, G, R.
    palette: *const [768]u8,
    files: []File,
    draws: []Draw,
    light: LightMap,
    palettes: []const [256]u8,
    cels: []Cel,
    units: []Unit,
    world: World,

    pub fn deinit(s: *Scene, gpa: std.mem.Allocator) void {
        for (s.units) |u| gpa.free(u.layers);
        gpa.free(s.units);
        gpa.free(s.cels);
        gpa.free(s.palettes);
        gpa.free(s.draws);
        gpa.free(s.files);
        gpa.free(s.light.cells);
    }

    /// The screen palette's colour of index i as R, G, B.
    pub fn rgb(s: *const Scene, i: u8) [3]u8 {
        const p = s.palette[@as(usize, i) * 3 ..][0..3];
        return .{ p[2], p[1], p[0] };
    }
};

pub const Error = error{ NotAScene, SceneVersion, ShortScene, BadPass } || std.mem.Allocator.Error;

const Reader = struct {
    b: []const u8,
    off: usize = 0,

    fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (r.b.len - r.off < n) return error.ShortScene;
        const s = r.b[r.off..][0..n];
        r.off += n;
        return s;
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        const s = try r.bytes(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
};

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Scene {
    var r: Reader = .{ .b = bytes };
    if (!std.mem.eql(u8, try r.bytes(4), magic)) return error.NotAScene;
    if (try r.int(u32) != version) return error.SceneVersion;
    const pal = (try r.bytes(768))[0..768];

    const nfiles = try r.int(u32);
    const files = try gpa.alloc(File, nfiles);
    errdefer gpa.free(files);
    for (files) |*f| {
        const nl = try r.int(u16);
        f.name = try r.bytes(nl);
        const n = try r.int(u32);
        f.bytes = try r.bytes(n);
    }

    const ndraws = try r.int(u32);
    const draws = try gpa.alloc(Draw, ndraws);
    errdefer gpa.free(draws);
    for (draws) |*d| {
        const p = try r.int(u8);
        if (p > 4) return error.BadPass;
        _ = try r.int(u8);
        d.* = .{ .pass = @enumFromInt(p), .file = try r.int(u16), .rec = try r.int(u32), .tx = try r.int(i32), .ty = try r.int(i32) };
    }

    const lx0 = try r.int(i32);
    const ly0 = try r.int(i32);
    const lw = try r.int(u32);
    const lh = try r.int(u32);
    const raw = try r.bytes(@as(usize, lw) * lh * 4);
    const cells = try gpa.alloc(Cell, @as(usize, lw) * lh);
    errdefer gpa.free(cells);
    for (cells, 0..) |*c, k| c.* = .{ .i = raw[k * 4], .r = raw[k * 4 + 1], .g = raw[k * 4 + 2], .b = raw[k * 4 + 3] };

    const npals = try r.int(u32);
    const pals = try gpa.alloc([256]u8, npals);
    errdefer gpa.free(pals);
    for (pals) |*p| p.* = (try r.bytes(256))[0..256].*;

    const ncels = try r.int(u32);
    const cels = try gpa.alloc(Cel, ncels);
    errdefer gpa.free(cels);
    for (cels) |*c| {
        c.w = try r.int(i32);
        c.h = try r.int(i32);
        c.ox = try r.int(i32);
        c.oy = try r.int(i32);
        c.dir = try r.int(u8);
        c.comp = try r.int(u8);
        _ = try r.int(u16);
        if (c.w < 0 or c.h < 0) return error.ShortScene;
        c.px = try r.bytes(@as(usize, @intCast(c.w)) * @as(usize, @intCast(c.h)));
    }

    const nunits = try r.int(u32);
    const units = try gpa.alloc(Unit, nunits);
    var made: usize = 0;
    errdefer {
        for (units[0..made]) |u| gpa.free(u.layers);
        gpa.free(units);
    }
    for (units) |*u| {
        u.x8 = try r.int(i32);
        u.y8 = try r.int(i32);
        const nl = try r.int(u16);
        u.name = try r.bytes(nl);
        const nlayers = try r.int(u32);
        if (nlayers > r.b.len) return error.ShortScene;
        u.layers = try gpa.alloc(Layer, nlayers);
        made += 1;
        for (u.layers) |*l| l.* = .{ .cel = try r.int(u32), .pal = try r.int(u16), .mode = try r.int(u8), .flags = try r.int(u8) };
    }

    var world: World = .{};
    if (r.b.len - r.off >= 24) world = .{
        .level = try r.int(u32),
        .seed = try r.int(u32),
        .ticks = try r.int(u32),
        .rate = try r.int(u32),
        .w = try r.int(i32),
        .h = try r.int(i32),
    };

    return .{
        .palette = pal,
        .files = files,
        .draws = draws,
        .light = .{ .x0 = lx0, .y0 = ly0, .w = lw, .h = lh, .cells = cells },
        .palettes = pals,
        .cels = cels,
        .units = units,
        .world = world,
    };
}

/// Whether draw a comes before draw b in the client's order (pass, row, column; the caller's
/// placement order breaks ties, so sort stably).
pub fn drawBefore(_: void, a: Draw, b: Draw) bool {
    if (a.pass != b.pass) return a.pass.rank() < b.pass.rank();
    if (a.tx + a.ty != b.tx + b.ty) return a.tx + a.ty < b.tx + b.ty;
    return a.tx - a.ty < b.tx - b.ty;
}

test "a scene reads back its sections" {
    const gpa = std.testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    const W = struct {
        fn int(o: *std.ArrayList(u8), g: std.mem.Allocator, comptime T: type, v: T) !void {
            var x: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &x, v, .little);
            try o.appendSlice(g, &x);
        }
    };
    try b.appendSlice(gpa, magic);
    try W.int(&b, gpa, u32, version);
    try b.appendNTimes(gpa, 7, 768);
    try W.int(&b, gpa, u32, 1);
    try W.int(&b, gpa, u16, 3);
    try b.appendSlice(gpa, "a.b");
    try W.int(&b, gpa, u32, 2);
    try b.appendSlice(gpa, "xy");
    try W.int(&b, gpa, u32, 1);
    try b.appendSlice(gpa, &.{ 4, 0 });
    try W.int(&b, gpa, u16, 0);
    try W.int(&b, gpa, u32, 9);
    try W.int(&b, gpa, i32, -3);
    try W.int(&b, gpa, i32, 5);
    try W.int(&b, gpa, i32, -1);
    try W.int(&b, gpa, i32, -2);
    try W.int(&b, gpa, u32, 2);
    try W.int(&b, gpa, u32, 1);
    try b.appendSlice(gpa, &.{ 10, 20, 30, 40, 50, 60, 70, 80 });
    for (0..3) |_| try W.int(&b, gpa, u32, 0);
    var s = try parse(gpa, b.items);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("a.b", s.files[0].name);
    try std.testing.expectEqual(Pass.under, s.draws[0].pass);
    try std.testing.expectEqual(@as(i32, -3), s.draws[0].tx);
    try std.testing.expectEqual(@as(u8, 50), s.light.at(0, -2).i);
    try std.testing.expectEqual(@as(u8, 50), s.light.at(9, 9).i);
    try std.testing.expectEqual(@as(u8, 10), s.light.at(-9, -9).i);
}
