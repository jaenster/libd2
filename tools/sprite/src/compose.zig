//! Drawing frames out: one frame, or a unit composed from its COF's layers, onto an indexed or
//! RGBA image, optionally a grid of every direction and frame.
//!
//! Scaling happens per layer, before composition, because that is what a renderer that upscales
//! each sprite draw does: a layer's edge is scaled against its own holes, not against whatever
//! another layer happened to put behind it. Colour shifts are applied after scaling, at draw time,
//! for the same reason.

const std = @import("std");
const formats = @import("d2-formats");
const main = @import("main.zig");
const sprite = @import("sprite.zig");
const pngx = @import("d2-util").png;
const scale_mod = @import("scale.zig");

const DrawMode = formats.canvas.DrawMode;

/// One layer placed relative to the pivot.
pub const Draw = struct {
    px: []const u8,
    w: u32,
    h: u32,
    x: i32,
    y: i32,
    mode: DrawMode = .solid,
    shift: ?*const [256]u8 = null,
};

/// Everything drawn for one direction+frame, back to front.
pub const Cell = []const Draw;

fn scaled(gpa: std.mem.Allocator, f: *const sprite.Frame, k: u32, filt: scale_mod.Filter, pal: *const main.Palette) !Draw {
    const px = try scale_mod.scale(gpa, f.px, f.w, f.h, k, filt, &pal.rgb);
    const ki: i32 = @intCast(k);
    return .{ .px = px, .w = f.w * k, .h = f.h * k, .x = f.x * ki, .y = f.y * ki };
}

pub fn single(gpa: std.mem.Allocator, f: *const sprite.Frame, k: u32, filt: scale_mod.Filter, pal: *const main.Palette, shift: ?*const [256]u8) !Cell {
    const d = try gpa.alloc(Draw, 1);
    d[0] = try scaled(gpa, f, k, filt, pal);
    d[0].shift = shift;
    return d;
}

const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// Lay `cells` out `cols` to a row, each in a box that is the union of all of them in pivot
/// space, so the frames of an animation stay registered. Returns PNG bytes.
///
/// Indexed output draws every layer solid: a blended layer has no single index to write without
/// the game's blend tables. RGBA output blends through `canvas`'s approximation of the draw mode.
pub fn renderGrid(gpa: std.mem.Allocator, cells: []const Cell, cols: u32, pal: *const main.Palette, indexed: bool) ![]u8 {
    var b: Box = .{ .x0 = std.math.maxInt(i32), .y0 = std.math.maxInt(i32), .x1 = std.math.minInt(i32), .y1 = std.math.minInt(i32) };
    for (cells) |cell| for (cell) |d| {
        b.x0 = @min(b.x0, d.x);
        b.y0 = @min(b.y0, d.y);
        b.x1 = @max(b.x1, d.x + @as(i32, @intCast(d.w)));
        b.y1 = @max(b.y1, d.y + @as(i32, @intCast(d.h)));
    };
    if (b.x1 <= b.x0) b = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
    const cw: u32 = @intCast(b.x1 - b.x0);
    const ch: u32 = @intCast(b.y1 - b.y0);
    const rows: u32 = @intCast((cells.len + cols - 1) / cols);
    const W = cw * cols;
    const H = ch * @max(rows, 1);

    if (indexed) {
        const img = try gpa.alloc(u8, @as(usize, W) * H);
        @memset(img, 0);
        for (cells, 0..) |cell, i| {
            const ox: i32 = @as(i32, @intCast((i % cols) * cw)) - b.x0;
            const oy: i32 = @as(i32, @intCast((i / cols) * ch)) - b.y0;
            for (cell) |d| drawIndexed(img, W, H, d, ox, oy);
        }
        return pngx.encodeIndexed(gpa, img, W, H, &pal.rgb);
    }

    var canvas = try formats.canvas.Canvas.init(gpa, W, H);
    for (cells, 0..) |cell, i| {
        const ox: i32 = @as(i32, @intCast((i % cols) * cw)) - b.x0;
        const oy: i32 = @as(i32, @intCast((i / cols) * ch)) - b.y0;
        for (cell) |d| {
            const s: ?[]const u8 = if (d.shift) |t| t[0..] else null;
            canvas.blitIndicesShifted(d.px, d.w, d.h, &pal.bgr, ox + d.x, oy + d.y, d.mode, s);
        }
    }
    return pngx.encodeRgbaDeflate(gpa, canvas.px, W, H);
}

fn drawIndexed(img: []u8, W: u32, H: u32, d: Draw, ox: i32, oy: i32) void {
    for (0..d.h) |row| {
        const y = oy + d.y + @as(i32, @intCast(row));
        if (y < 0 or y >= H) continue;
        for (0..d.w) |col| {
            const raw = d.px[row * d.w + col];
            if (raw == 0) continue;
            const idx = if (d.shift) |t| t[raw] else raw;
            if (idx == 0) continue;
            const x = ox + d.x + @as(i32, @intCast(col));
            if (x < 0 or x >= W) continue;
            img[@as(usize, @intCast(y)) * W + @as(usize, @intCast(x))] = idx;
        }
    }
}

const char_tokens = [_][]const u8{ "am", "so", "ne", "pa", "ba", "dz", "ai" };

fn isCharToken(tok: []const u8) bool {
    for (char_tokens) |t| if (std.ascii.eqlIgnoreCase(t, tok)) return true;
    return false;
}

fn lower(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const o = try gpa.dupe(u8, s);
    for (o) |*ch| ch.* = std.ascii.toLower(ch.*);
    return o;
}

/// What a COF layer resolved to on disk, for `--json`.
const Resolved = struct { component: []const u8, file: ?[]const u8, weaponClass: []const u8, mode: []const u8 };

/// `sprite compose`: the unit `--token` in `--mode` with `--wclass`, every COF layer drawn from
/// `data/global/<class>/<tok>/<comp>/<tok><comp><var><mode><layer wclass>.dcc` (or .dc6). The
/// variant is `--var COMP=VAR`, default `lit`; when that file does not exist the first listed
/// variant of the same component, mode and class is taken instead, except for the held-item
/// layers (rh, lh, sh), which are left out unless a `--var` names them.
pub fn run(c: *main.Ctx) !void {
    const gpa = c.gpa;
    const tok = try lower(gpa, try c.args.need("token"));
    const mode = try lower(gpa, try c.args.need("mode"));
    const wclass = try lower(gpa, try c.args.need("wclass"));
    const out_path = try c.args.need("out");
    const class = if (c.args.get("class")) |cl| cl else if (isCharToken(tok)) "chars" else "monsters";
    const k = try c.scaleFactor();
    const filt = try c.filter();
    const pal = try main.loadPalette(c);
    const src = try c.source_();

    const cof_name = try std.fmt.allocPrint(gpa, "data/global/{s}/{s}/cof/{s}{s}{s}.cof", .{ class, tok, tok, mode, wclass });
    const cof_bytes = src.read(gpa, cof_name) catch return main.fail("no COF {s}", .{cof_name});
    const cof = formats.cof.parse(gpa, cof_bytes) catch {
        std.debug.print("sprite: {s}: not a valid COF\n", .{cof_name});
        return error.Failed;
    };

    var layers: [16]?sprite.Sprite = @splat(null);
    var shifts: [16]?*const [256]u8 = @splat(null);
    var modes: [16]DrawMode = @splat(.solid);
    var resolved: std.ArrayListUnmanaged(Resolved) = .empty;
    for (cof.layers) |*l| {
        if (l.component >= 16) continue;
        const comp = try lower(gpa, l.compCode());
        const lwc = try lower(gpa, l.wclass());
        const explicit = variantFor(c, comp);
        // Held items are equipment: without a --var they are not drawn from a guessed variant.
        const held = std.mem.eql(u8, comp, "rh") or std.mem.eql(u8, comp, "lh") or std.mem.eql(u8, comp, "sh");
        const file = try findLayerFile(c, class, tok, comp, explicit orelse "lit", mode, lwc, explicit == null and !held);
        try resolved.append(gpa, .{ .component = comp, .file = file, .weaponClass = lwc, .mode = mode });
        if (file) |f| layers[l.component] = try main.loadSprite(c, f);
        for (c.args.all("layer-shift")) |spec| {
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return main.fail("--layer-shift is COMP=SPEC", .{});
            if (std.ascii.eqlIgnoreCase(spec[0..eq], comp)) shifts[l.component] = try main.loadShift(c, &pal, spec[eq + 1 ..]);
        }
        if (l.transparent) modes[l.component] = if (l.draw_effect < 8) @enumFromInt(l.draw_effect) else .transparent;
    }

    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    var cols: u32 = 1;
    if (c.args.flag("all")) {
        cols = cof.frames_per_dir;
        for (0..cof.num_directions) |d| for (0..cof.frames_per_dir) |f| {
            try cells.append(gpa, try composeCell(c, &cof, &layers, &shifts, &modes, d, f, k, filt, &pal));
        };
    } else {
        const d = try c.args.int("dir", 0);
        const f = try c.args.int("frame", 0);
        if (d >= cof.num_directions or f >= cof.frames_per_dir)
            return main.fail("{s} has {d} dirs x {d} frames", .{ cof_name, cof.num_directions, cof.frames_per_dir });
        try cells.append(gpa, try composeCell(c, &cof, &layers, &shifts, &modes, d, f, k, filt, &pal));
    }
    try c.writeFile(out_path, try renderGrid(gpa, cells.items, cols, &pal, c.args.flag("indexed")));

    if (c.args.flag("json")) {
        const doc = .{ .cof = cof_name, .directions = cof.num_directions, .framesPerDir = cof.frames_per_dir, .layers = resolved.items };
        try c.out(try std.json.Stringify.valueAlloc(gpa, doc, .{ .whitespace = .indent_2 }));
        try c.out("\n");
    }
}

fn variantFor(c: *main.Ctx, comp: []const u8) ?[]const u8 {
    for (c.args.all("var")) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(spec[0..eq], comp)) return spec[eq + 1 ..];
    }
    return null;
}

fn findLayerFile(c: *main.Ctx, class: []const u8, tok: []const u8, comp: []const u8, variant: []const u8, mode: []const u8, wc: []const u8, any_variant: bool) !?[]const u8 {
    const src = try c.source_();
    const v = try lower(c.gpa, variant);
    for ([_][]const u8{ "dcc", "dc6" }) |ext| {
        const name = try std.fmt.allocPrint(c.gpa, "data/global/{s}/{s}/{s}/{s}{s}{s}{s}{s}.{s}", .{ class, tok, comp, tok, comp, v, mode, wc, ext });
        if (src.has(name)) return name;
    }
    if (!any_variant) return null;
    const prefix = try std.fmt.allocPrint(c.gpa, "data/global/{s}/{s}/{s}/{s}{s}", .{ class, tok, comp, tok, comp });
    for ([_][]const u8{ "dcc", "dc6" }) |ext| {
        const suffix = try std.fmt.allocPrint(c.gpa, "{s}{s}.{s}", .{ mode, wc, ext });
        for (src.names.items) |n| {
            if (std.mem.startsWith(u8, n, prefix) and std.mem.endsWith(u8, n, suffix) and n.len == prefix.len + 3 + suffix.len) return n;
        }
    }
    return null;
}

fn composeCell(
    c: *main.Ctx,
    cof: *const formats.cof.Cof,
    layers: *const [16]?sprite.Sprite,
    shifts: *const [16]?*const [256]u8,
    modes: *const [16]DrawMode,
    d: usize,
    f: usize,
    k: u32,
    filt: scale_mod.Filter,
    pal: *const main.Palette,
) !Cell {
    var draws: std.ArrayListUnmanaged(Draw) = .empty;
    for (cof.drawOrder(d, f)) |comp| {
        if (comp >= 16) continue;
        const sp = layers[comp] orelse continue;
        // A layer file may carry a different number of directions than its COF.
        const ld: u32 = @intCast(d * sp.dirs / cof.num_directions);
        const lf: u32 = @intCast(f % sp.fpd);
        var dr = try scaled(c.gpa, sp.at(ld, lf), k, filt, pal);
        dr.shift = shifts[comp];
        dr.mode = modes[comp];
        try draws.append(c.gpa, dr);
    }
    return draws.items;
}
