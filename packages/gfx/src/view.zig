//! A frame of a scene as the renderer draws it, on the CPU: one view of the game's screen, its upper
//! left at world screen point (vx, vy) (a floor tile of cell (tx, ty) has its box's upper left at
//! ((tx - ty) * 80 - 80, (tx + ty) * 40)), drawn in the order and with the draws D2OpenGL makes for
//! the client's tile calls at render scale 1 with the view flat (not in perspective):
//!
//!   floor and roof tiles: a 6 x 6 mesh over the tile's diamond, five triangle strips, each point's
//!     colour its light value modulated, the 160 x 80 texture of the tile's blocks sampled linear at
//!     texel coordinates that run with the screen but for a one-texel inset at the diamond's edge;
//!   walls, the lower walls and shadow tiles: one 32 x 32 quad per block, sampled nearest, a wall's
//!     left edge in the light of its column's sample and its right edge in the next one's, a shadow
//!     black at three quarters cover; blocks whose left edge is off the screen's width, or whose
//!     bottom is off the screen above or within 15 rows of its bottom, are not drawn;
//!   with the smooth light, the ground tiles are drawn white and the floor drawn so far is multiplied
//!     by the light lattice's spline before the next draw that is not a ground tile.
//!
//! What a host plugs in: the act palettes' stretches and any tile folders a mod adds (`Options`).
const std = @import("std");
const scene_mod = @import("scene.zig");
const tiles = @import("tiles.zig");
const light = @import("light.zig");
const raster = @import("raster.zig");
const tilepal = @import("tilepal.zig");

const Scene = scene_mod.Scene;

/// How the GL texture holds a palette colour: as 8 bits a channel, or as 5 (the renderer's ARGB1555
/// conversion, which drops the low three bits).
pub const TexelFormat = enum { rgba8, argb1555 };

pub const Options = struct {
    w: u32 = 800,
    h: u32 = 600,
    /// Lighting=smooth.
    smooth: bool = true,
    /// The renderer's client-storage textures: the floor a 160 x 80 rectangle texture, clamped at its
    /// edge (Apple's GL offers it, so does Wine on macOS); else 256 x 128, repeating.
    rect_textures: bool = true,
    texels: TexelFormat = .argb1555,
    /// Shadow tiles blended (D2gfx's blended-shadows setting), else drawn solid.
    blended_shadows: bool = true,
    /// Rows at the screen's bottom that walls and shadow tiles leave out (the classic interface's 15;
    /// 0 when the orbs sit at the view's edges).
    bottom_margin: i32 = 15,
    ramps: tilepal.Ramps = .{ null, null, null, null, null, null },
    folders: []const tilepal.Folder = &tilepal.stock_folders,
};

/// A floor footprint waiting for the light pass: corners on screen and on the lattice.
const Footprint = struct { x: [4]f32, y: [4]f32, a: [4]f32, b: [4]f32, a0: i32, b0: i32 };

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    scene: *const Scene,
    libs: []tiles.Library,
    opts: Options,
    /// The palette each library's tiles convert with, R, G, B.
    pals: [][256][3]u8,
    floors: std.AutoHashMapUnmanaged(u64, raster.Texture) = .empty,
    blocks: std.AutoHashMapUnmanaged(u64, raster.Texture) = .empty,
    grid: *light.Grid,
    tile_state: *[light.lattice_size][light.lattice_size]u8,
    footprints: std.ArrayListUnmanaged(Footprint) = .empty,
    origin: ?[2]i32 = null,

    pub fn init(gpa: std.mem.Allocator, s: *const Scene, opts: Options) !Renderer {
        const libs = try gpa.alloc(tiles.Library, s.files.len);
        var made: usize = 0;
        errdefer {
            for (libs[0..made]) |*l| l.deinit(gpa);
            gpa.free(libs);
        }
        for (s.files, 0..) |f, k| {
            libs[k] = try tiles.load(gpa, f.name, f.bytes);
            made += 1;
        }
        var screen: [256][3]u8 = undefined;
        for (0..256) |i| screen[i] = s.rgb(@intCast(i));
        const pals = try gpa.alloc([256][3]u8, s.files.len);
        errdefer gpa.free(pals);
        for (s.files, 0..) |f, k| tilepal.forLibrary(&screen, f.name, &opts.ramps, opts.folders, &pals[k]);
        const grid = try gpa.create(light.Grid);
        errdefer gpa.destroy(grid);
        const ts = try gpa.create([light.lattice_size][light.lattice_size]u8);
        return .{ .gpa = gpa, .scene = s, .libs = libs, .opts = opts, .pals = pals, .grid = grid, .tile_state = ts };
    }

    pub fn deinit(r: *Renderer) void {
        var it = r.floors.valueIterator();
        while (it.next()) |t| r.gpa.free(t.texels);
        r.floors.deinit(r.gpa);
        var it2 = r.blocks.valueIterator();
        while (it2.next()) |t| r.gpa.free(t.texels);
        r.blocks.deinit(r.gpa);
        for (r.libs) |*l| l.deinit(r.gpa);
        r.gpa.free(r.libs);
        r.gpa.free(r.pals);
        r.gpa.destroy(r.grid);
        r.gpa.destroy(r.tile_state);
        r.footprints.deinit(r.gpa);
    }

    /// A palette index as the texture holds it.
    fn texel(r: *const Renderer, file: usize, index: u8, out: []u8) void {
        const c = r.pals[file][index];
        if ((c[0] | c[1] | c[2]) == 0) {
            @memset(out[0..4], 0);
            return;
        }
        switch (r.opts.texels) {
            .rgba8 => {
                out[0] = c[0];
                out[1] = c[1];
                out[2] = c[2];
            },
            .argb1555 => for (0..3) |k| {
                const q: u32 = c[k] >> 3;
                out[k] = @intCast((q * 255 + 15) / 31);
            },
        }
        out[3] = 255;
    }

    fn floorTexture(r: *Renderer, file: u16, rec: u32) !*const raster.Texture {
        const key = (@as(u64, file) << 32) | rec;
        const gop = try r.floors.getOrPut(r.gpa, key);
        if (gop.found_existing) return gop.value_ptr;
        errdefer _ = r.floors.remove(key);
        var idx: [tiles.floor_pitch * tiles.floor_rows]u8 = undefined;
        tiles.decodeFloor(&r.libs[file].tiles[rec], &idx);
        const w: u32 = if (r.opts.rect_textures) 160 else 256;
        const h: u32 = if (r.opts.rect_textures) 80 else 128;
        const tx = try r.gpa.alloc(u8, w * h * 4);
        for (0..h) |y| for (0..w) |x| r.texel(file, idx[y * tiles.floor_pitch + x], tx[(y * w + x) * 4 ..][0..4]);
        gop.value_ptr.* = .{ .w = w, .h = h, .texels = tx, .filter = .linear, .repeat = !r.opts.rect_textures };
        return gop.value_ptr;
    }

    fn blockTexture(r: *Renderer, file: u16, rec: u32, block: usize) !*const raster.Texture {
        const key = (@as(u64, file) << 48) | (@as(u64, rec) << 16) | block;
        const gop = try r.blocks.getOrPut(r.gpa, key);
        if (gop.found_existing) return gop.value_ptr;
        errdefer _ = r.blocks.remove(key);
        var idx: [32 * 32]u8 = undefined;
        tiles.decodeBlock(&r.libs[file].tiles[rec].blocks[block], &idx);
        const tx = try r.gpa.alloc(u8, 32 * 32 * 4);
        for (0..32 * 32) |i| r.texel(file, idx[i], tx[i * 4 ..][0..4]);
        gop.value_ptr.* = .{ .w = 32, .h = 32, .texels = tx, .filter = .nearest, .repeat = !r.opts.rect_textures };
        return gop.value_ptr;
    }

    /// One frame into `tg` (which must be opts.w x opts.h).
    pub fn frame(r: *Renderer, tg: *raster.Target, vx: i32, vy: i32) !void {
        @memset(tg.px, 0);
        for (0..@as(usize, tg.w) * tg.h) |i| tg.px[i * 4 + 3] = 255;
        r.grid.clear();
        for (r.tile_state) |*row| @memset(row, 0);
        r.footprints.clearRetainingCapacity();
        r.origin = null;
        const W: i32 = @intCast(r.opts.w);
        const H: i32 = @intCast(r.opts.h);
        for (r.scene.draws) |d| {
            const x = (d.tx - d.ty) * 80 - 80;
            const y = (d.tx + d.ty) * 40;
            const sx = x - vx;
            const sy = y - vy;
            if (sx < -160 or sx > W + 160 or sy < -80 or sy > H + 560) continue;
            if (d.file >= r.libs.len or d.rec >= r.libs[d.file].tiles.len) continue;
            const t = &r.libs[d.file].tiles[d.rec];
            switch (d.pass) {
                .floor, .roof => {
                    const lift: i32 = if (d.pass == .roof) t.roof_height else 0;
                    var pts: [36]GroundPoint = undefined;
                    for (0..6) |row| for (0..6) |col| {
                        const c: i32 = @intCast(col);
                        const rr: i32 = @intCast(row);
                        pts[row * 6 + col] = .{
                            .light = if (t.fullLight()) .{ .i = 255, .r = 255, .g = 255, .b = 255 } else r.scene.light.at(d.tx * 5 + c, d.ty * 5 + rr),
                            .x = sx + 80 + (c - rr) * 16,
                            .y = sy - lift + (c + rr) * 8,
                        };
                    };
                    try r.groundTile(tg, d.file, d.rec, &pts);
                },
                .shadow => {
                    r.flush(tg);
                    try r.shadowTile(tg, d.file, d.rec, sx, sy + 80);
                },
                .wall, .under => {
                    r.flush(tg);
                    const lights = light.wallLights(&r.scene.light, t.direction, d.tx, d.ty);
                    try r.wallTile(tg, d.file, d.rec, sx, sy + 80, &lights);
                },
            }
        }
        r.flush(tg);
    }

    const GroundPoint = struct { light: light.Cell, x: i32, y: i32 };

    /// The smooth light's record of a ground tile: whether it is drawn white (lit later by the light
    /// pass) or with its own light values.
    fn smoothGround(r: *Renderer, t: *const tiles.Tile, pts: *const [36]GroundPoint) bool {
        if (!r.opts.smooth) return false;
        if (r.origin == null) r.origin = .{ pts[0].x, pts[0].y };
        const o = r.origin.?;
        const ab0 = light.screenToLattice(pts[0].x - o[0], pts[0].y - o[1]) orelse return false;
        const a0 = ab0[0] + light.lattice_origin;
        const b0 = ab0[1] + light.lattice_origin;
        if (a0 < 0 or b0 < 0 or a0 + 5 >= light.lattice_size or b0 + 5 >= light.lattice_size) return false;
        for (pts, 0..) |p, i| {
            const ab = light.screenToLattice(p.x - o[0], p.y - o[1]) orelse return false;
            if (ab[0] + light.lattice_origin != a0 + @as(i32, @intCast(i % 6)) or ab[1] + light.lattice_origin != b0 + @as(i32, @intCast(i / 6))) return false;
        }
        if (t.fullLight()) {
            for (0..36) |i| r.grid.setLava(a0 + @as(i32, @intCast(i % 6)), b0 + @as(i32, @intCast(i / 6)));
            return false;
        }
        const state = &r.tile_state[@intCast(b0)][@intCast(a0)];
        if (state.* == 2) return false;
        for (pts, 0..) |p, i| r.grid.set(a0 + @as(i32, @intCast(i % 6)), b0 + @as(i32, @intCast(i / 6)), p.light);
        if (t.blocks.len == 0) return false;
        if (state.* == 0) {
            const corner = [4]usize{ 0, 5, 35, 30 };
            var fp: Footprint = .{ .x = undefined, .y = undefined, .a = undefined, .b = undefined, .a0 = a0, .b0 = b0 };
            for (corner, 0..) |i, k| {
                fp.x[k] = @floatFromInt(pts[i].x);
                fp.y[k] = @floatFromInt(pts[i].y);
                fp.a[k] = @floatFromInt(a0 + @as(i32, @intCast(i % 6)));
                fp.b[k] = @floatFromInt(b0 + @as(i32, @intCast(i / 6)));
            }
            r.footprints.append(r.gpa, fp) catch return false;
            state.* = 1;
        }
        return true;
    }

    fn lightProgram(g: *const light.Grid, _: *const raster.State, at: *const raster.Vertex) ?[4]f32 {
        const s = g.sample(at.u, at.v);
        return .{ s[0] / 255.0, s[1] / 255.0, s[2] / 255.0, 1 };
    }

    /// The light pass over the ground tiles drawn since the last one.
    fn flush(r: *Renderer, tg: *raster.Target) void {
        if (r.footprints.items.len == 0) return;
        r.grid.growBorder();
        const st: raster.State = .{ .blend = .multiply, .alpha_test = false };
        for (r.footprints.items) |fp| {
            var q: [4]raster.Vertex = undefined;
            for (0..4) |k| q[k] = .{ .x = fp.x[k], .y = fp.y[k], .u = fp.a[k], .v = fp.b[k] };
            raster.fan(tg, &st, *const light.Grid, r.grid, lightProgram, &q);
            r.tile_state[@intCast(fp.b0)][@intCast(fp.a0)] = 2;
        }
        r.footprints.clearRetainingCapacity();
    }

    fn groundTile(r: *Renderer, tg: *raster.Target, file: u16, rec: u32, pts: *const [36]GroundPoint) !void {
        const t = &r.libs[file].tiles[rec];
        const white = r.smoothGround(t, pts);
        const tex = try r.floorTexture(file, rec);
        const st: raster.State = .{ .texture = tex };
        var mesh: [6][6]raster.Vertex = undefined;
        for (0..6) |row| for (0..6) |col| {
            // the one-texel inset at the diamond's edges
            var iv: i32 = if (col == 0) 1 else if (col == 5) -1 else 0;
            var iu: i32 = iv;
            if (row == 5) {
                iu = iv + 1;
                iv -= 1;
            } else if (row == 0) {
                iu = iv - 1;
                iv += 1;
            }
            const c: i32 = @intCast(col);
            const rr: i32 = @intCast(row);
            const p = pts[row * 6 + col];
            const lc = if (white) [3]u8{ 255, 255, 255 } else light.vertexColour(p.light);
            mesh[row][col] = .{
                .x = @floatFromInt(p.x),
                .y = @floatFromInt(p.y),
                .u = @floatFromInt(80 + iu + (c - rr) * 16),
                .v = @floatFromInt((rr + c) * 8 + iv),
                .r = @floatFromInt(lc[0]),
                .g = @floatFromInt(lc[1]),
                .b = @floatFromInt(lc[2]),
            };
        };
        for (0..5) |s| {
            var strip: [12]raster.Vertex = undefined;
            for (0..6) |col| {
                strip[col * 2] = mesh[s][col];
                strip[col * 2 + 1] = mesh[s + 1][col];
            }
            raster.strip(tg, &st, void, {}, raster.fixed, &strip);
        }
    }

    fn blockVisible(r: *const Renderer, bl: *const tiles.Block, nx: i32, ny: i32) bool {
        const left = @as(i32, bl.x) + nx;
        if (left < -32 or left >= @as(i32, @intCast(r.opts.w))) return false;
        const bottom = ny + 32 + bl.y;
        return bottom >= 0 and bottom < @as(i32, @intCast(r.opts.h)) - r.opts.bottom_margin;
    }

    fn blockQuad(bl: *const tiles.Block, nx: i32, ny: i32, left: [3]u8, right: [3]u8, alpha: f32) [4]raster.Vertex {
        const l: f32 = @floatFromInt(@as(i32, bl.x) + nx);
        const top: f32 = @floatFromInt(@as(i32, bl.y) + ny);
        const lf = [3]f32{ @floatFromInt(left[0]), @floatFromInt(left[1]), @floatFromInt(left[2]) };
        const rf = [3]f32{ @floatFromInt(right[0]), @floatFromInt(right[1]), @floatFromInt(right[2]) };
        // a fan whose second point keeps the first's colour and whose fourth the third's
        return .{
            .{ .x = l, .y = top, .u = 0, .v = 0, .r = lf[0], .g = lf[1], .b = lf[2], .a = alpha },
            .{ .x = l, .y = top + 32, .u = 0, .v = 32, .r = lf[0], .g = lf[1], .b = lf[2], .a = alpha },
            .{ .x = l + 32, .y = top + 32, .u = 32, .v = 32, .r = rf[0], .g = rf[1], .b = rf[2], .a = alpha },
            .{ .x = l + 32, .y = top, .u = 32, .v = 0, .r = rf[0], .g = rf[1], .b = rf[2], .a = alpha },
        };
    }

    fn wallTile(r: *Renderer, tg: *raster.Target, file: u16, rec: u32, nx: i32, ny: i32, lights: *const [8]light.Cell) !void {
        if (isInvisibleWall(r.libs[file].name)) return;
        const t = &r.libs[file].tiles[rec];
        for (t.blocks, 0..) |*bl, k| {
            if (!r.blockVisible(bl, nx, ny)) continue;
            const col: i32 = @as(i32, bl.x) >> 5;
            const li: usize = @intCast(std.math.clamp(col, 0, 7));
            const ri: usize = @intCast(std.math.clamp(col + 1, 0, 7));
            const st: raster.State = .{ .texture = try r.blockTexture(file, rec, k) };
            const q = blockQuad(bl, nx, ny, light.vertexColour(lights[li]), light.vertexColour(lights[ri]), 255);
            raster.fan(tg, &st, void, {}, raster.fixed, &q);
        }
    }

    fn shadowTile(r: *Renderer, tg: *raster.Target, file: u16, rec: u32, nx: i32, ny: i32) !void {
        const t = &r.libs[file].tiles[rec];
        const alpha: f32 = if (r.opts.blended_shadows) 192 else 255;
        for (t.blocks, 0..) |*bl, k| {
            if (!r.blockVisible(bl, nx, ny)) continue;
            const st: raster.State = .{ .texture = try r.blockTexture(file, rec, k), .blend = if (r.opts.blended_shadows) .alpha else .off };
            const q = blockQuad(bl, nx, ny, .{ 0, 0, 0 }, .{ 0, 0, 0 }, alpha);
            raster.fan(tg, &st, void, {}, raster.fixed, &q);
        }
    }
};

/// The stock invisible wall, InvisWal.dt1 in any folder: green and blue boxes that stand for a wall
/// which blocks and is not seen. The renderer draws none of them.
pub fn isInvisibleWall(path: []const u8) bool {
    const name = "inviswal.dt1";
    if (path.len < name.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[path.len - name.len ..], name)) return false;
    return path.len == name.len or path[path.len - name.len - 1] == '\\' or path[path.len - name.len - 1] == '/';
}
