//! objgfx — turn a Diablo II object (Objects.txt row) into a composited RGBA sprite.
//!
//! Pipeline: Objects.txt gives a 2-char `Token`; the object's graphics live under
//!   data/global/objects/<TOKEN>/  (extracted to <assets>/objects/<TOKEN>/ by
//!   tools/extract_objects.zig). For a mode (NU/OP/...) + weaponclass (HTH):
//!     COF  = <TOKEN>/COF/<TOKEN><MODE><WCLASS>.cof         (cof.zig)
//!     layer= <TOKEN>/<COMP>/<token><comp><gfx><mode><wclass>.dcc  (dcc.zig, or .dc6)
//! Each COF layer names a component (HD/TR/.. via cof.COMPONENT_CODES); the 3-char
//! `<gfx>` class (lit/med/hvy/..) is not in the COF, so we resolve the file by
//! scanning the component dir for the one matching <token><comp>*<mode><wclass>.
//!
//! For a static tile-view marker we composite mode NU (fallback OP), direction 0,
//! frame 0, all layers in the COF priority (back-to-front) draw order. Index 0 is
//! transparent; the act palette (768-byte B,G,R) maps indices to RGBA.

const std = @import("std");
const dcc = @import("d2-formats").dcc;
const cof = @import("d2-formats").cof;
const dc6 = @import("d2-formats").dc6;

/// Object animation modes, indexed 0..7 to match Objects.txt FrameCnt0..7.
pub const MODES = [8][]const u8{ "NU", "OP", "ON", "S1", "S2", "S3", "S4", "S5" };

pub const ObjectRow = struct {
    id: u32,
    name: []u8,
    token: []u8, // e.g. "wp", "L1"
    frame_cnt: [8]u32, // per-mode frame count (0 = mode absent)
    size_x: i32,
    size_y: i32,
};

pub const Objects = struct {
    rows: []ObjectRow,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Objects) void {
        for (self.rows) |r| {
            self.allocator.free(r.name);
            self.allocator.free(r.token);
        }
        self.allocator.free(self.rows);
    }

    pub fn byId(self: *const Objects, id: u32) ?*const ObjectRow {
        for (self.rows) |*r| if (r.id == id) return r;
        return null;
    }
};

/// Parse Objects.txt (tab-separated). Columns: Name=0, Id=2, Token=3,
/// FrameCnt0..7 = 20..27, SizeX=14, SizeY=15.
pub fn loadObjects(alloc: std.mem.Allocator, txt: []const u8) !Objects {
    var rows: std.ArrayList(ObjectRow) = .empty;
    errdefer {
        for (rows.items) |r| {
            alloc.free(r.name);
            alloc.free(r.token);
        }
        rows.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, txt, '\n');
    _ = lines.next(); // header
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;

        var cols: [40][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |c| : (n += 1) {
            if (n >= cols.len) break;
            cols[n] = c;
        }
        if (n < 28) continue;

        const token = std.mem.trim(u8, cols[3], " \t");
        if (token.len == 0) continue;
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, cols[2], " \t"), 10) catch continue;

        var fc: [8]u32 = .{0} ** 8;
        for (0..8) |m| fc[m] = std.fmt.parseInt(u32, std.mem.trim(u8, cols[20 + m], " \t"), 10) catch 0;

        try rows.append(alloc, .{
            .id = id,
            .name = try alloc.dupe(u8, std.mem.trim(u8, cols[0], " \t")),
            .token = try alloc.dupe(u8, token),
            .frame_cnt = fc,
            .size_x = std.fmt.parseInt(i32, std.mem.trim(u8, cols[14], " \t"), 10) catch 0,
            .size_y = std.fmt.parseInt(i32, std.mem.trim(u8, cols[15], " \t"), 10) catch 0,
        });
    }

    return .{ .rows = try rows.toOwnedSlice(alloc), .allocator = alloc };
}

pub const Sprite = struct {
    width: u32,
    height: u32,
    /// Sprite-local pixel offset of the top-left corner (object pivot at 0,0).
    offset_x: i32,
    offset_y: i32,
    /// width*height*4 straight RGBA8888. Index-0 pixels are fully transparent.
    rgba: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Sprite) void {
        self.allocator.free(self.rgba);
    }
};

/// One decoded layer, positioned in sprite-local coords via its DCC/DC6 box.
const LayerImg = struct {
    left: i32,
    top: i32,
    w: i32,
    h: i32,
    indices: []u8, // w*h, index 0 = transparent
};

/// Composite an object sprite: token+mode+dir+frame -> RGBA. `assets_dir` is the
/// root that contains `objects/<TOKEN>/...`. `wclass` is usually "HTH".
pub fn composite(
    alloc: std.mem.Allocator,
    assets_dir: []const u8,
    token: []const u8,
    mode: []const u8,
    wclass: []const u8,
    dir: usize,
    frame: usize,
    palette: []const u8,
) !Sprite {
    var upper: [16]u8 = undefined;
    const tok_up = upperInto(&upper, token);

    // COF: objects/<TOK>/COF/<TOK><MODE><WCLASS>.cof
    const cof_path = try std.fmt.allocPrint(alloc, "{s}/objects/{s}/COF/{s}{s}{s}.cof", .{ assets_dir, tok_up, tok_up, mode, wclass });
    defer alloc.free(cof_path);
    const cof_bytes = readFile(alloc, cof_path) catch return error.CofNotFound;
    defer alloc.free(cof_bytes);
    var c = try cof.parse(alloc, cof_bytes);
    defer c.deinit();

    const use_dir = @min(dir, @as(usize, c.num_directions) - 1);
    const use_frame = @min(frame, @as(usize, c.frames_per_dir) - 1);

    // Decode each layer in the COF's back-to-front draw order.
    var imgs: std.ArrayList(LayerImg) = .empty;
    defer {
        for (imgs.items) |im| alloc.free(im.indices);
        imgs.deinit(alloc);
    }

    const order = c.drawOrder(use_dir, use_frame);
    for (order) |comp_type| {
        // Find the COF layer whose component matches this draw-order slot.
        const layer = findLayer(&c, comp_type) orelse continue;
        const comp = layer.compCode();
        const lwc = layer.wclass();

        const img = decodeLayer(alloc, assets_dir, tok_up, token, comp, mode, lwc, use_dir, use_frame) catch |e| {
            if (e == error.LayerFileNotFound) continue; // some layers may be absent for a mode
            return e;
        } orelse continue;
        try imgs.append(alloc, img);
    }

    if (imgs.items.len == 0) return error.NoLayers;

    // Union bounding box across all layers.
    var minl: i32 = std.math.maxInt(i32);
    var mint: i32 = std.math.maxInt(i32);
    var maxr: i32 = std.math.minInt(i32);
    var maxb: i32 = std.math.minInt(i32);
    for (imgs.items) |im| {
        minl = @min(minl, im.left);
        mint = @min(mint, im.top);
        maxr = @max(maxr, im.left + im.w);
        maxb = @max(maxb, im.top + im.h);
    }
    const cw: usize = @intCast(maxr - minl);
    const ch: usize = @intCast(maxb - mint);

    // Composite indices, then map to RGBA.
    const canvas = try alloc.alloc(u8, cw * ch);
    defer alloc.free(canvas);
    @memset(canvas, 0);
    for (imgs.items) |im| {
        const ox: usize = @intCast(im.left - minl);
        const oy: usize = @intCast(im.top - mint);
        const lw: usize = @intCast(im.w);
        const lh: usize = @intCast(im.h);
        var y: usize = 0;
        while (y < lh) : (y += 1) {
            var x: usize = 0;
            while (x < lw) : (x += 1) {
                const idx = im.indices[y * lw + x];
                if (idx != 0) canvas[(oy + y) * cw + (ox + x)] = idx;
            }
        }
    }

    const rgba = try alloc.alloc(u8, cw * ch * 4);
    for (canvas, 0..) |idx, i| {
        const o = i * 4;
        if (idx == 0) {
            rgba[o] = 0;
            rgba[o + 1] = 0;
            rgba[o + 2] = 0;
            rgba[o + 3] = 0;
        } else {
            const pi = @as(usize, idx) * 3;
            rgba[o] = palette[pi + 2]; // R (palette is B,G,R)
            rgba[o + 1] = palette[pi + 1]; // G
            rgba[o + 2] = palette[pi]; // B
            rgba[o + 3] = 255;
        }
    }

    return .{
        .width = @intCast(cw),
        .height = @intCast(ch),
        .offset_x = minl,
        .offset_y = mint,
        .rgba = rgba,
        .allocator = alloc,
    };
}

fn findLayer(c: *const cof.Cof, comp_type: u8) ?*const cof.Layer {
    for (c.layers) |*l| if (l.component == comp_type) return l;
    return null;
}

/// Locate + decode one layer's frame. The gfx class is unknown, so scan
/// objects/<TOK>/<COMP>/ for a file matching <token><comp>*<mode><wclass>.(dcc|dc6).
fn decodeLayer(
    alloc: std.mem.Allocator,
    assets_dir: []const u8,
    tok_up: []const u8,
    token: []const u8,
    comp: []const u8,
    mode: []const u8,
    wclass: []const u8,
    dir: usize,
    frame: usize,
) !?LayerImg {
    const comp_dir = try std.fmt.allocPrint(alloc, "{s}/objects/{s}/{s}", .{ assets_dir, tok_up, comp });
    defer alloc.free(comp_dir);

    // Match <token><comp>*<mode><wclass> case-insensitively, e.g. "wptr" + ... + "nuhth".
    var pfx_src: [32]u8 = undefined;
    var pfx_buf: [32]u8 = undefined;
    var sfx_src: [32]u8 = undefined;
    var sfx_buf: [32]u8 = undefined;
    const pfx = lowerInto(&pfx_buf, try std.fmt.bufPrint(&pfx_src, "{s}{s}", .{ token, comp }));
    const sfx = lowerInto(&sfx_buf, try std.fmt.bufPrint(&sfx_src, "{s}{s}", .{ mode, wclass }));

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var d = std.Io.Dir.cwd().openDir(io, comp_dir, .{ .iterate = true }) catch return error.LayerFileNotFound;
    defer d.close(io);
    var it = d.iterate();
    var chosen: ?[]u8 = null;
    var is_dc6 = false;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var nbuf: [64]u8 = undefined;
        if (entry.name.len >= nbuf.len) continue;
        const lname = lowerInto(&nbuf, entry.name);
        const ext_dcc = std.mem.endsWith(u8, lname, ".dcc");
        const ext_dc6 = std.mem.endsWith(u8, lname, ".dc6");
        if (!ext_dcc and !ext_dc6) continue;
        const stem = lname[0 .. lname.len - 4];
        if (!std.mem.startsWith(u8, stem, pfx)) continue;
        if (!std.mem.endsWith(u8, stem, sfx)) continue;
        chosen = try alloc.dupe(u8, entry.name);
        is_dc6 = ext_dc6;
        break;
    }
    const cname = chosen orelse return error.LayerFileNotFound;
    defer alloc.free(cname);

    const fpath = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ comp_dir, cname });
    defer alloc.free(fpath);
    const bytes = try readFile(alloc, fpath);
    defer alloc.free(bytes);

    if (is_dc6) {
        var sheet = try dc6.parse(alloc, bytes);
        defer sheet.deinit();
        // DC6 frame index: dir * framesPerDir + frame (framesPerDir inferred by /dirs unknown;
        // objects DC6 are typically single-direction, so use frame directly, clamped).
        const fi = @min(frame, sheet.frames.len - 1);
        const f = &sheet.frames[fi];
        const w: usize = @intCast(f.width);
        const h: usize = @intCast(f.height);
        const idx = try alloc.dupe(u8, f.indices);
        return LayerImg{
            .left = f.offset_x,
            .top = f.offset_y - @as(i32, @intCast(h)) + 1,
            .w = @intCast(w),
            .h = @intCast(h),
            .indices = idx,
        };
    }

    var sprite = try dcc.parse(alloc, bytes);
    defer sprite.deinit();
    const use_dir = @min(dir, sprite.directions.len - 1);
    const d0 = sprite.directions[use_dir];
    const use_frame = @min(frame, d0.frames.len - 1);
    const idx = try alloc.dupe(u8, d0.frames[use_frame]);
    return LayerImg{
        .left = d0.box.left,
        .top = d0.box.top,
        .w = d0.box.width,
        .h = d0.box.height,
        .indices = idx,
    };
}

fn upperInto(buf: []u8, s: []const u8) []u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..n];
}
fn lowerInto(buf: []u8, s: []const u8) []u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024));
}
