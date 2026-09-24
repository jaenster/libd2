//! Frames out to indexed PNGs with a JSON description, and back into the game's formats.
//!
//! `unpack` writes `sprite.json` (or `cof.json`) plus one indexed PNG per frame. `pack` reads that
//! directory back. Frames may have been replaced by scaled copies in the meantime: when a PNG is
//! exactly k times the recorded size in both axes, the frame's placement is scaled by k with it,
//! so an upscaled pack keeps its registration against the pivot.
//!
//! Every frame is described by the SHA-256 of its original indices (see `sprite.hash`), so a
//! pipeline can file scaled art under the hash of the art it came from.

const std = @import("std");
const formats = @import("d2-formats");
const main = @import("main.zig");
const source = @import("source.zig");
const sprite = @import("sprite.zig");
const pngx = @import("d2-util").png;
const scale_mod = @import("scale.zig");
const compose = @import("compose.zig");

const Dir = std.Io.Dir;

pub const FrameDoc = struct {
    dir: u32,
    frame: u32,
    /// Original size and pivot-relative top-left, at 1x.
    w: u32,
    h: u32,
    x: i32,
    y: i32,
    /// SHA-256 of the original indices; see `sprite.hash`.
    hash: []const u8,
    /// The PNG, relative to the JSON file that names it.
    png: ?[]const u8 = null,
    /// DC6 frame header fields carried for a byte-exact write-back.
    flip: u32 = 0,
    unknown: u32 = 0,
    /// The three bytes after the frame's runs, when they are not the termination bytes.
    tail: ?[3]u16 = null,
    /// The stored next-frame offset when it is not the real one.
    nextBlock: ?u32 = null,
    /// DCC: the frame's own box inside its direction's box, pivot-relative.
    box: ?[4]i32 = null,
};

/// Byte fields are u16 in the JSON types so they serialise as arrays of numbers, not as strings.
pub const Dc6Header = struct { version: i32, flags: u32, encoding: u32, termination: [4]u16 };

pub const Doc = struct {
    name: []const u8,
    kind: []const u8,
    dirs: u32,
    framesPerDir: u32,
    /// The factor the PNGs were written at.
    scale: u32,
    dc6: ?Dc6Header = null,
    dcc: ?dcc_io.Header = null,
    frames: []FrameDoc,
};

const dcc_io = @import("dcc_io.zig");

/// Describe a sprite. `pngs[i]`, when given, names frame i's PNG.
pub fn describe(gpa: std.mem.Allocator, name: []const u8, sp: *const sprite.Sprite, k: u32, pngs: ?[]const []const u8, _: bool) !Doc {
    const frames = try gpa.alloc(FrameDoc, sp.frames.len);
    for (sp.frames, 0..) |*f, i| {
        const h = sprite.hash(f.w, f.h, f.px);
        frames[i] = .{
            .dir = @intCast(i / sp.fpd),
            .frame = @intCast(i % sp.fpd),
            .w = f.w,
            .h = f.h,
            .x = f.x,
            .y = f.y,
            .hash = try gpa.dupe(u8, &h),
            .png = if (pngs) |p| p[i] else null,
        };
        if (sp.dc6) |d| {
            frames[i].flip = d.frames[i].flip;
            frames[i].unknown = d.frames[i].unknown;
            frames[i].nextBlock = d.frames[i].next_block;
            if (d.frames[i].tail) |t| {
                if (!std.mem.eql(u8, &t, d.termination[0..3])) frames[i].tail = widenArr(3, t);
            }
        }
        if (sp.dcc) |*d| frames[i].box = dcc_io.frameBox(d, i / sp.fpd, i % sp.fpd);
    }
    return .{
        .name = name,
        .kind = @tagName(sp.kind),
        .dirs = sp.dirs,
        .framesPerDir = sp.fpd,
        .scale = k,
        .dc6 = if (sp.dc6) |d| .{ .version = d.version, .flags = d.flags, .encoding = d.encoding, .termination = widenArr(4, d.termination) } else null,
        .dcc = if (sp.dcc) |*d| dcc_io.header(d) else null,
        .frames = frames,
    };
}

// ---- COF as JSON ----------------------------------------------------------------------------

pub const LayerDoc = struct {
    component: []const u8,
    componentId: u8,
    shadow: u8,
    selectable: u8,
    transparent: u8,
    drawEffect: u8,
    weaponClass: []const u8,
    weaponClassRaw: [4]u16,
};

pub const CofDoc = struct {
    name: []const u8,
    kind: []const u8 = "cof",
    directions: u8,
    framesPerDir: u8,
    speed: u8,
    layers: []LayerDoc,
    animFrames: []const u16,
    /// Component ids back to front, `directions * framesPerDir * layers` long.
    priority: []const u16,
    reserved: [24]u16,
    trailer: []const u16,
};

/// Byte arrays go out as JSON arrays of numbers, not as strings.
fn bytesJson(gpa: std.mem.Allocator, doc: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, doc, .{ .whitespace = .indent_2 });
}

fn widen(gpa: std.mem.Allocator, b: []const u8) ![]u16 {
    const o = try gpa.alloc(u16, b.len);
    for (b, o) |x, *y| y.* = x;
    return o;
}

fn widenArr(comptime n: usize, b: [n]u8) [n]u16 {
    var o: [n]u16 = undefined;
    for (b, &o) |x, *y| y.* = x;
    return o;
}

fn narrow(gpa: std.mem.Allocator, b: []const u16) ![]u8 {
    const o = try gpa.alloc(u8, b.len);
    for (b, o) |x, *y| y.* = std.math.cast(u8, x) orelse return error.ByteOutOfRange;
    return o;
}

fn narrowArr(comptime n: usize, b: [n]u16) ![n]u8 {
    var o: [n]u8 = undefined;
    for (b, &o) |x, *y| y.* = std.math.cast(u8, x) orelse return error.ByteOutOfRange;
    return o;
}

pub fn cofDoc(gpa: std.mem.Allocator, name: []const u8, c: *const formats.cof.Cof) !CofDoc {
    const layers = try gpa.alloc(LayerDoc, c.layers.len);
    for (c.layers, layers) |*l, *d| d.* = .{
        .component = l.compCode(),
        .componentId = l.component,
        .shadow = l.shadow,
        .selectable = if ((l.flag_bytes[0] > 0) == l.selectable) l.flag_bytes[0] else @intFromBool(l.selectable),
        .transparent = if ((l.flag_bytes[1] > 0) == l.transparent) l.flag_bytes[1] else @intFromBool(l.transparent),
        .drawEffect = l.draw_effect,
        .weaponClass = l.wclass(),
        .weaponClassRaw = widenArr(4, l.weapon_class_raw),
    };
    return .{
        .name = name,
        .directions = c.num_directions,
        .framesPerDir = c.frames_per_dir,
        .speed = c.speed,
        .layers = layers,
        .animFrames = try widen(gpa, c.anim_frames),
        .priority = try widen(gpa, c.priority),
        .reserved = widenArr(24, c.reserved),
        .trailer = try widen(gpa, c.trailer),
    };
}

pub fn cofJson(gpa: std.mem.Allocator, name: []const u8, c: *const formats.cof.Cof) ![]u8 {
    const s = try bytesJson(gpa, try cofDoc(gpa, name, c));
    return std.mem.concat(gpa, u8, &.{ s, "\n" });
}

fn cofFromDoc(gpa: std.mem.Allocator, d: *const CofDoc) !formats.cof.Cof {
    const layers = try gpa.alloc(formats.cof.Layer, d.layers.len);
    for (d.layers, layers) |*ld, *l| {
        if (ld.weaponClass.len > 4) return error.InvalidCof;
        var wc: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(wc[0..ld.weaponClass.len], ld.weaponClass);
        l.* = .{
            .component = ld.componentId,
            .shadow = ld.shadow,
            .selectable = ld.selectable > 0,
            .transparent = ld.transparent > 0,
            .draw_effect = ld.drawEffect,
            .weapon_class = wc,
            .weapon_class_len = @intCast(ld.weaponClass.len),
            .weapon_class_raw = try narrowArr(4, ld.weaponClassRaw),
            .flag_bytes = .{ ld.selectable, ld.transparent },
        };
    }
    return .{
        .num_layers = @intCast(d.layers.len),
        .frames_per_dir = d.framesPerDir,
        .num_directions = d.directions,
        .speed = d.speed,
        .layers = layers,
        .priority = try narrow(gpa, d.priority),
        .allocator = gpa,
        .anim_frames = try narrow(gpa, d.animFrames),
        .reserved = try narrowArr(24, d.reserved),
        .trailer = try narrow(gpa, d.trailer),
    };
}

// ---- unpack ---------------------------------------------------------------------------------

const ByHash = struct { abs: []const u8, rel: []const u8 };

const Written = struct { json: []u8, failed: bool = false };

/// Unpack `name` into `dir`. PNG paths in the JSON are relative to `dir`; `frames_dir`, when set,
/// is where frames go instead, named by hash, and `frames_rel` is how `dir` reaches it.
fn unpackOne(c: *main.Ctx, name: []const u8, dir: []const u8, k: u32, filt: scale_mod.Filter, pal: *const main.Palette, rgba: bool, by_hash: ?ByHash) ![]u8 {
    const gpa = c.gpa;
    if (std.ascii.endsWithIgnoreCase(name, ".cof")) {
        const bytes = try (try c.source_()).read(gpa, name);
        const cof = try formats.cof.parse(gpa, bytes);
        const json = try cofJson(gpa, name, &cof);
        try c.writeFile(try std.fs.path.join(gpa, &.{ dir, "cof.json" }), json);
        return json;
    }
    const sp = try main.loadSprite(c, name);
    const pngs = try gpa.alloc([]const u8, sp.frames.len);
    for (sp.frames, 0..) |*f, i| {
        const h = sprite.hash(f.w, f.h, f.px);
        const px = try scale_mod.scale(gpa, f.px, f.w, f.h, k, filt, &pal.rgb);
        const w = f.w * k;
        const hh = f.h * k;
        const png = if (rgba) try rgbaPng(gpa, px, w, hh, pal) else try pngx.encodeIndexed(gpa, px, w, hh, &pal.rgb);
        if (by_hash) |bh| {
            const file = try std.fmt.allocPrint(gpa, "{s}.png", .{&h});
            pngs[i] = try std.fs.path.join(gpa, &.{ bh.rel, file });
            try c.writeFile(try std.fs.path.join(gpa, &.{ bh.abs, file }), png);
        } else {
            pngs[i] = try std.fmt.allocPrint(gpa, "d{d:0>2}f{d:0>3}.png", .{ i / sp.fpd, i % sp.fpd });
            try c.writeFile(try std.fs.path.join(gpa, &.{ dir, pngs[i] }), png);
        }
    }
    const doc = try describe(gpa, name, &sp, k, pngs, false);
    const json = try std.mem.concat(gpa, u8, &.{ try bytesJson(gpa, doc), "\n" });
    try c.writeFile(try std.fs.path.join(gpa, &.{ dir, "sprite.json" }), json);
    return json;
}

fn rgbaPng(gpa: std.mem.Allocator, px: []const u8, w: u32, h: u32, pal: *const main.Palette) ![]u8 {
    const rgba = try gpa.alloc(u8, px.len * 4);
    for (px, 0..) |idx, i| {
        if (idx == 0) {
            rgba[i * 4 ..][0..4].* = .{ 0, 0, 0, 0 };
        } else {
            const c3 = pal.rgb[@as(usize, idx) * 3 ..][0..3];
            rgba[i * 4 ..][0..4].* = .{ c3[0], c3[1], c3[2], 255 };
        }
    }
    return pngx.encodeRgbaDeflate(gpa, rgba, w, h);
}

pub fn unpackCmd(c: *main.Ctx) !void {
    const name = try c.args.arg(0, "NAME");
    const dir = try c.args.need("out");
    const pal = try main.loadPalette(c);
    const k = try c.scaleFactor();
    const filt = try c.filter();
    const by_hash: ?ByHash = if (c.args.flag("by-hash")) .{ .abs = dir, .rel = "." } else null;
    _ = unpackOne(c, name, dir, k, filt, &pal, c.args.flag("rgba"), by_hash) catch |e| {
        std.debug.print("sprite: {s}: {s}\n", .{ name, @errorName(e) });
        return error.Failed;
    };
}

// ---- pack -----------------------------------------------------------------------------------

/// Read a directory `unpack` wrote and encode it as `out`'s format.
fn packDir(c: *main.Ctx, dir: []const u8, out_kind: []const u8) ![]u8 {
    const gpa = c.gpa;
    if (std.mem.eql(u8, out_kind, "cof")) {
        const text = try source.readFile(gpa, c.io, try std.fs.path.join(gpa, &.{ dir, "cof.json" }));
        const doc = try std.json.parseFromSliceLeaky(CofDoc, gpa, text, .{ .ignore_unknown_fields = true });
        const cof = try cofFromDoc(gpa, &doc);
        return formats.cof.encode(gpa, &cof);
    }
    const text = try source.readFile(gpa, c.io, try std.fs.path.join(gpa, &.{ dir, "sprite.json" }));
    const doc = try std.json.parseFromSliceLeaky(Doc, gpa, text, .{ .ignore_unknown_fields = true });
    if (doc.frames.len != @as(usize, doc.dirs) * doc.framesPerDir) return error.FrameCountMismatch;

    // Every frame's scale must agree, or the sprite would come apart.
    var k: ?u32 = null;
    const images = try gpa.alloc(pngx.Indexed, doc.frames.len);
    for (doc.frames, images) |*f, *img| {
        const rel = f.png orelse return error.FrameHasNoPng;
        img.* = try pngx.decodeIndexed(gpa, try source.readFile(gpa, c.io, try std.fs.path.join(gpa, &.{ dir, rel })));
        if (img.w % f.w != 0 or img.h % f.h != 0 or img.w / f.w != img.h / f.h) {
            std.debug.print("sprite: {s} is {d}x{d}, not a whole multiple of {d}x{d}\n", .{ rel, img.w, img.h, f.w, f.h });
            return error.Failed;
        }
        const fk = img.w / f.w;
        if (k != null and k.? != fk) {
            std.debug.print("sprite: {s} is scaled {d}x where the others are {d}x\n", .{ rel, fk, k.? });
            return error.Failed;
        }
        k = fk;
    }
    const ki: i32 = @intCast(k orelse 1);

    if (std.mem.eql(u8, out_kind, "dc6")) {
        const frames = try gpa.alloc(formats.dc6.Frame, doc.frames.len);
        for (doc.frames, images, frames) |*f, *img, *o| o.* = .{
            .width = img.w,
            .height = img.h,
            .offset_x = f.x * ki,
            .offset_y = (f.y + @as(i32, @intCast(f.h))) * ki,
            .indices = img.px,
            .flip = f.flip,
            .unknown = f.unknown,
            .tail = if (f.tail) |t| try narrowArr(3, t) else null,
            .next_block = if (ki == 1) f.nextBlock else null,
        };
        var sheet: formats.dc6.Dc6 = .{ .frames = frames, .allocator = gpa, .directions = doc.dirs, .frames_per_dir = doc.framesPerDir };
        if (doc.dc6) |h| {
            sheet.version = h.version;
            sheet.flags = h.flags;
            sheet.encoding = h.encoding;
            sheet.termination = try narrowArr(4, h.termination);
        }
        return formats.dc6.encode(gpa, &sheet);
    }
    if (std.mem.eql(u8, out_kind, "dcc")) return dcc_io.encodeFromDoc(gpa, &doc, images, ki);
    return error.UnknownFormat;
}

fn outKind(path: []const u8) ![]const u8 {
    for ([_][]const u8{ "dc6", "dcc", "cof" }) |ext| {
        if (path.len > 4 and path[path.len - 4] == '.' and std.ascii.eqlIgnoreCase(path[path.len - 3 ..], ext)) return ext;
    }
    return main.fail("--out must end in .dc6, .dcc or .cof: {s}", .{path});
}

pub fn packCmd(c: *main.Ctx) !void {
    const dir = try c.args.arg(0, "DIR");
    const out = try c.args.need("out");
    const bytes = packDir(c, dir, try outKind(out)) catch |e| {
        if (e == error.Usage or e == error.Failed) return e;
        std.debug.print("sprite: {s}: {s}\n", .{ dir, @errorName(e) });
        return error.Failed;
    };
    try c.writeFile(out, bytes);
}

/// Decode, scale every frame in index space, and write the result as a game file (or, for a
/// .png, an indexed sheet of every frame).
pub fn upscaleCmd(c: *main.Ctx) !void {
    const name = try c.args.arg(0, "NAME");
    const out = try c.args.need("out");
    const k = try c.scaleFactor();
    const filt = try c.filter();
    const pal = try main.loadPalette(c);
    const sp = try main.loadSprite(c, name);

    if (std.ascii.endsWithIgnoreCase(out, ".png")) {
        var cells: std.ArrayListUnmanaged(compose.Cell) = .empty;
        for (sp.frames) |*f| try cells.append(c.gpa, try compose.single(c.gpa, f, k, filt, &pal, null));
        return c.writeFile(out, try compose.renderGrid(c.gpa, cells.items, sp.fpd, &pal, true));
    }
    const kind = try outKind(out);
    const ki: i32 = @intCast(k);
    const bytes: []u8 = if (std.mem.eql(u8, kind, "dc6")) blk: {
        const frames = try c.gpa.alloc(formats.dc6.Frame, sp.frames.len);
        for (sp.frames, frames, 0..) |*f, *o, i| o.* = .{
            .width = f.w * k,
            .height = f.h * k,
            .offset_x = f.x * ki,
            .offset_y = (f.y + @as(i32, @intCast(f.h))) * ki,
            .indices = try scale_mod.scale(c.gpa, f.px, f.w, f.h, k, filt, &pal.rgb),
            .flip = if (sp.dc6) |d| d.frames[i].flip else 0,
            .unknown = if (sp.dc6) |d| d.frames[i].unknown else 0,
        };
        var sheet: formats.dc6.Dc6 = .{ .frames = frames, .allocator = c.gpa, .directions = sp.dirs, .frames_per_dir = sp.fpd };
        if (sp.dc6) |d| {
            sheet.version = d.version;
            sheet.flags = d.flags;
            sheet.encoding = d.encoding;
            sheet.termination = d.termination;
        }
        break :blk try formats.dc6.encode(c.gpa, &sheet);
    } else if (std.mem.eql(u8, kind, "dcc")) blk: {
        break :blk dcc_io.encodeScaled(c.gpa, &sp, k, filt, &pal) catch |e| {
            std.debug.print("sprite: {s}: DCC encode failed: {s}\n", .{ name, @errorName(e) });
            return error.Failed;
        };
    } else return main.fail("upscale writes .dc6, .dcc or .png", .{});
    try c.writeFile(out, bytes);
}

// ---- batch ----------------------------------------------------------------------------------

fn isArt(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".dc6") or std.ascii.endsWithIgnoreCase(name, ".dcc") or std.ascii.endsWithIgnoreCase(name, ".cof");
}

/// Unpack every match into `--out`, one directory per member (`<out>/<member path>/`), and write a
/// manifest: a JSON array of every member's description with PNG paths relative to `--out`.
/// `--by-hash` stores each distinct frame once, as `<out>/frames/<hash>.png`.
pub fn batchCmd(c: *main.Ctx) !void {
    const root = try c.args.need("out");
    _ = try c.args.need("match");
    const names = try main.matching(c, "**");
    const pal = try main.loadPalette(c);
    const k = try c.scaleFactor();
    const filt = try c.filter();
    const rgba = c.args.flag("rgba");
    const by_hash = c.args.flag("by-hash");
    const outer = c.gpa;

    var manifest: std.ArrayListUnmanaged(u8) = .empty;
    try manifest.appendSlice(outer, "[\n");
    var failed: usize = 0;
    var done: usize = 0;
    for (names) |name| {
        if (!isArt(name)) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        c.gpa = arena.allocator();
        defer c.gpa = outer;

        const dir = try std.fs.path.join(c.gpa, &.{ root, name });
        const depth = std.mem.count(u8, name, "/") + 1;
        var rel: std.ArrayListUnmanaged(u8) = .empty;
        for (0..depth) |_| try rel.appendSlice(c.gpa, "../");
        try rel.appendSlice(c.gpa, "frames");
        const bh: ?ByHash = if (by_hash) .{ .abs = try std.fs.path.join(c.gpa, &.{ root, "frames" }), .rel = rel.items } else null;
        const json = unpackOne(c, name, dir, k, filt, &pal, rgba, bh) catch |e| {
            std.debug.print("sprite: {s}: {s}\n", .{ name, @errorName(e) });
            failed += 1;
            continue;
        };
        // In the manifest, paths are relative to the root rather than to the member's directory.
        const entry = try rebase(c.gpa, json, name, by_hash);
        if (done > 0) try manifest.appendSlice(outer, ",\n");
        try manifest.appendSlice(outer, std.mem.trimEnd(u8, entry, "\n"));
        done += 1;
    }
    try manifest.appendSlice(outer, "\n]\n");
    const mpath = c.args.get("manifest") orelse try std.fs.path.join(outer, &.{ root, "manifest.json" });
    try c.writeFile(mpath, manifest.items);
    std.debug.print("sprite: {d} unpacked, {d} failed\n", .{ done, failed });
    if (failed > 0) return error.Failed;
}

fn rebase(gpa: std.mem.Allocator, json: []const u8, name: []const u8, by_hash: bool) ![]u8 {
    if (std.mem.indexOf(u8, json, "\"kind\": \"cof\"") != null) return gpa.dupe(u8, json);
    const doc = try std.json.parseFromSliceLeaky(Doc, gpa, json, .{ .ignore_unknown_fields = true });
    for (doc.frames) |*f| {
        const p = f.png orelse continue;
        f.png = if (by_hash) try std.fs.path.join(gpa, &.{ "frames", std.fs.path.basename(p) }) else try std.fs.path.join(gpa, &.{ name, p });
    }
    return bytesJson(gpa, doc);
}

// ---- verify ---------------------------------------------------------------------------------

const Tally = struct { checked: usize = 0, failed: usize = 0, identical: usize = 0, skipped: usize = 0, undecodable: usize = 0 };

/// Decode and re-encode every matching member. DC6 and COF must come back byte for byte; a DCC
/// must decode to the same frames (its encoder is correct, not Blizzard's, so bytes can differ;
/// how many came back identical is reported too).
pub fn verifyCmd(c: *main.Ctx) !void {
    const names = try main.matching(c, "**");
    const outer = c.gpa;
    var t = [3]Tally{ .{}, .{}, .{} };
    for (names) |name| {
        const slot: usize = if (std.ascii.endsWithIgnoreCase(name, ".dc6")) 0 else if (std.ascii.endsWithIgnoreCase(name, ".cof")) 1 else if (std.ascii.endsWithIgnoreCase(name, ".dcc")) 2 else continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        const bytes = (try c.source_()).read(gpa, name) catch {
            t[slot].skipped += 1;
            continue;
        };
        t[slot].checked += 1;
        const r = roundTrip(gpa, slot, bytes) catch |e| {
            std.debug.print("FAIL {s}: {s}\n", .{ name, @errorName(e) });
            t[slot].failed += 1;
            continue;
        };
        switch (r) {
            .identical => t[slot].identical += 1,
            .equivalent => {},
            .undecodable => {
                std.debug.print("SKIP {s}: does not decode\n", .{name});
                t[slot].checked -= 1;
                t[slot].undecodable += 1;
            },
            .different => {
                std.debug.print("FAIL {s}: round trip differs\n", .{name});
                t[slot].failed += 1;
            },
        }
    }
    c.gpa = outer;
    const doc = .{ .dc6 = t[0], .cof = t[1], .dcc = t[2] };
    if (c.args.flag("json")) {
        try c.out(try std.json.Stringify.valueAlloc(outer, doc, .{ .whitespace = .indent_2 }));
        try c.out("\n");
    } else {
        var aw: std.Io.Writer.Allocating = .init(outer);
        for ([_][]const u8{ "dc6", "cof", "dcc" }, t) |label, x| {
            try aw.writer.print("{s}: {d} checked, {d} byte-identical, {d} failed, {d} undecodable, {d} unreadable\n", .{ label, x.checked, x.identical, x.failed, x.undecodable, x.skipped });
        }
        try c.out(aw.written());
    }
    if (t[0].failed + t[1].failed + t[2].failed > 0) return error.Failed;
}

/// `undecodable`: the decoder refuses the original, so there is nothing to round-trip. One retail
/// `.cof` is the encrypted CD-key blob stored under an animation's name.
pub const Outcome = enum { identical, equivalent, different, undecodable };

pub fn roundTrip(gpa: std.mem.Allocator, slot: usize, bytes: []const u8) !Outcome {
    switch (slot) {
        0 => {
            const d = formats.dc6.parse(gpa, bytes) catch return .undecodable;
            const again = try formats.dc6.encode(gpa, &d);
            return if (std.mem.eql(u8, bytes, again)) .identical else .different;
        },
        1 => {
            const cof = formats.cof.parse(gpa, bytes) catch return .undecodable;
            const again = try formats.cof.encode(gpa, &cof);
            return if (std.mem.eql(u8, bytes, again)) .identical else .different;
        },
        else => return dcc_io.roundTrip(gpa, bytes),
    }
}

// ---- tests over the real archives -----------------------------------------------------------

fn gameDir(gpa: std.mem.Allocator) ?[]const u8 {
    _ = gpa;
    return std.testing.environ.getPosix("D2_DIR");
}

test "real archives: DC6 and COF round-trip byte for byte, DCC decodes back to the same frames" {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const dir = gameDir(gpa) orelse return;
    const paths = source.defaultArchives(gpa, io, dir) catch return;
    if (paths.len == 0) return;
    var src = try source.Source.open(gpa, io, paths, &.{});

    const patterns = [_][]const u8{
        "data/global/ui/**.dc6",
        "data/global/items/*.dc6",
        "data/global/chars/*/cof/*.cof",
        "data/global/monsters/*/cof/*.cof",
        "data/global/monsters/zm/**.dcc",
        "data/global/chars/am/tr/*.dcc",
        "data/global/missiles/*.dcc",
    };
    for (patterns, 0..) |pat, pi| {
        var n: usize = 0;
        for (src.names.items) |name| {
            if (!source.globMatch(pat, name)) continue;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const bytes = try src.read(a, name);
            const slot: usize = if (pi < 2) 0 else if (pi < 4) 1 else 2;
            const r = try roundTrip(a, slot, bytes);
            if (r == .undecodable) continue;
            try std.testing.expect(r != .different);
            if (slot < 2) try std.testing.expectEqual(Outcome.identical, r);
            n += 1;
            if (slot == 2 and n >= 40) break;
        }
        try std.testing.expect(n > 0);
    }
}
