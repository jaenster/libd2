//! `sprite hdpack`: build an HD pack (`d2-util` `hdpack`) from 1x `batch` or `tiles` output and
//! folders of upscaled copies of their PNGs.
//!
//! For every frame the manifest lists, the 1x PNG gives the frame's key and box (`framekey`); the
//! PNG at the same relative path under `--up` must be the same frame `--scale` times larger, in the
//! same palette's indices. The box is cropped out of it, scaled, and filed under the key. Frames
//! with no upscaled PNG, or one of the wrong size or not indexed, are counted and skipped. The pack
//! depends only on the inputs: entries are sorted, and a frame that occurs in several files is
//! stored once, from the first file in manifest order. The pack is format 2 (each image
//! zlib-compressed) unless `--format 1` asks for the old raw form.
//!
//! Tile manifests (`sprite tiles`, entries of kind "dt1"): a floor is one entry, keyed and cut like
//! a sprite frame. A wall is one entry per block, keyed on the block's 32x32 rect of the 1x wall
//! image (which is the block's own decode, the key the renderer computes) and cut from the upscaled
//! wall image at the rect times the scale. The manifest's recorded keys must agree with the PNGs.
//!
//! Several sources go into one pack as repeated `--src DIR --up DIR` pairs, in order; `--manifest`,
//! when given, is repeated once per `--src`. A key found in more than one source is taken from the
//! first.

const std = @import("std");
const util = @import("d2-util");
const main = @import("main.zig");
const source = @import("source.zig");
const pack_mod = @import("pack.zig");
const tiles = @import("tiles.zig");

const framekey = util.framekey;
const hdpack = util.hdpack;
const pngx = util.png;

pub const Tally = struct {
    /// Every keyed unit: sprite frames, floor tiles and wall blocks.
    frames: usize = 0,
    floors: usize = 0,
    wall_blocks: usize = 0,
    /// Frames with no non-zero index: nothing to key or replace.
    empty: usize = 0,
    /// No PNG under --up at the frame's path.
    missing: usize = 0,
    /// A PNG under --up that is not `scale` times the frame, or not indexed.
    wrong_size: usize = 0,
    /// The 1x PNG disagrees with the manifest or will not decode.
    bad_source: usize = 0,
    /// Frames put in the pack, before identical frames are merged.
    packed_frames: usize = 0,
};

pub fn cmd(c: *main.Ctx) !void {
    const srcs = c.args.all("src");
    const ups = c.args.all("up");
    if (srcs.len == 0) return main.fail("--src is required", .{});
    if (ups.len != srcs.len) return main.fail("give one --up per --src ({d} --src, {d} --up)", .{ srcs.len, ups.len });
    const manifests = c.args.all("manifest");
    if (manifests.len != 0 and manifests.len != srcs.len) return main.fail("give one --manifest per --src, or none", .{});
    const out = try c.args.need("out");
    const scale = try c.args.int("scale", 0);
    if (scale < 1 or scale > hdpack.max_scale) return main.fail("--scale is 1 to {d}", .{hdpack.max_scale});
    const format = try c.args.int("format", hdpack.version);
    if (format != 1 and format != 2) return main.fail("--format is 1 (raw) or 2 (zlib), got {d}", .{format});

    var tally: Tally = .{};
    var images: std.ArrayListUnmanaged(hdpack.Image) = .empty;
    for (srcs, ups, 0..) |src_dir, up_dir, i| {
        const manifest_path = if (manifests.len != 0) manifests[i] else try std.fs.path.join(c.gpa, &.{ src_dir, "manifest.json" });
        const text = source.readFile(c.gpa, c.io, manifest_path) catch |e| return main.fail("{s}: {s}", .{ manifest_path, @errorName(e) });
        try build(c, text, src_dir, up_dir, scale, &tally, &images);
    }
    // The compression threads allocate at once, which the command's arena is not built for.
    const bytes = hdpack.encode(std.heap.smp_allocator, scale, images.items, .{ .version = format }) catch |e| switch (e) {
        error.PackTooLarge => return main.fail("{d} frames do not fit one pack: its offsets are 32-bit, so a pack stops short of 4 GiB. Split the --src sets over several packs", .{images.items.len}),
        else => return e,
    };
    const h = try hdpack.validate(bytes);
    try c.writeFile(out, bytes);
    var raw: u64 = 0;
    for (0..h.count) |i| {
        const e = hdpack.entryAt(bytes, h, i);
        raw += hdpack.imageLen(h.scale, e.bw, e.bh);
    }
    const stored = bytes.len - hdpack.header_len - h.count * hdpack.entryLen(h.version);
    std.debug.print(
        "sprite: {d} frames ({d} floor tiles, {d} wall blocks): {d} packed ({d} distinct), {d} empty, {d} missing, {d} wrong size, {d} bad source; images {d} bytes raw, {d} stored ({d:.1}x); {d} bytes, v{d}, scale {d}\n",
        .{ tally.frames, tally.floors, tally.wall_blocks, tally.packed_frames, h.count, tally.empty, tally.missing, tally.wrong_size, tally.bad_source, raw, stored, @as(f64, @floatFromInt(raw)) / @as(f64, @floatFromInt(@max(stored, 1))), bytes.len, h.version, scale },
    );
    if (tally.bad_source > 0) return error.Failed;
}

/// Append the pack's images, in manifest order, for every frame that has a usable upscaled PNG.
pub fn build(c: *main.Ctx, manifest: []const u8, src_dir: []const u8, up_dir: []const u8, scale: u32, tally: *Tally, images: *std.ArrayListUnmanaged(hdpack.Image)) !void {
    const gpa = c.gpa;
    const root = std.json.parseFromSliceLeaky(std.json.Value, gpa, manifest, .{}) catch return main.fail("the manifest is not JSON", .{});
    if (root != .array) return main.fail("the manifest is not a JSON array", .{});

    for (root.array.items) |member| {
        if (member != .object) continue;
        const kind = member.object.get("kind") orelse continue;
        if (kind != .string or std.mem.eql(u8, kind.string, "cof")) continue;
        if (std.mem.eql(u8, kind.string, "dt1")) {
            const doc = std.json.parseFromValueLeaky(tiles.Dt1Doc, gpa, member, .{ .ignore_unknown_fields = true }) catch
                return main.fail("a manifest entry is not a tile description", .{});
            if (doc.scale != 1) return main.fail("{s}: --src must be written at 1x (this one is {d}x)", .{ doc.name, doc.scale });
            for (doc.tiles) |t| try tileImages(c, src_dir, up_dir, &t, scale, tally, images);
            continue;
        }
        const doc = std.json.parseFromValueLeaky(pack_mod.Doc, gpa, member, .{ .ignore_unknown_fields = true }) catch
            return main.fail("a manifest entry is not a sprite description", .{});
        if (doc.scale != 1) return main.fail("{s}: --src must be a batch written at 1x (this one is {d}x)", .{ doc.name, doc.scale });
        for (doc.frames) |f| {
            tally.frames += 1;
            const rel = f.png orelse {
                tally.bad_source += 1;
                continue;
            };
            if (try frameImage(c, src_dir, up_dir, rel, f.w, f.h, scale, tally)) |im| {
                try images.append(gpa, im);
                tally.packed_frames += 1;
            }
        }
    }
}

/// A tile's entries: the floor image whole, or each wall block on its own.
fn tileImages(c: *main.Ctx, src_dir: []const u8, up_dir: []const u8, t: *const tiles.TileDoc, scale: u32, tally: *Tally, images: *std.ArrayListUnmanaged(hdpack.Image)) !void {
    const gpa = c.gpa;
    if (std.mem.eql(u8, t.kind, "floor")) {
        tally.frames += 1;
        tally.floors += 1;
        const im = try frameImage(c, src_dir, up_dir, t.png, t.w, t.h, scale, tally) orelse return;
        if (t.key) |want| if (!try keyAgrees(gpa, want, im.key, t.png)) {
            tally.bad_source += 1;
            return;
        };
        try images.append(gpa, im);
        tally.packed_frames += 1;
        return;
    }
    const blocks = t.blocks orelse return;
    tally.frames += blocks.len;
    tally.wall_blocks += blocks.len;
    const src_path = try std.fs.path.join(gpa, &.{ src_dir, t.png });
    const one = readIndexed(gpa, c.io, src_path) catch {
        tally.bad_source += blocks.len;
        return;
    };
    if (one.w != t.w or one.h != t.h) {
        std.debug.print("sprite: {s}: {d}x{d}, the manifest says {d}x{d}\n", .{ src_path, one.w, one.h, t.w, t.h });
        tally.bad_source += blocks.len;
        return;
    }
    const up_path = try std.fs.path.join(gpa, &.{ up_dir, t.png });
    const up_png = source.readFile(gpa, c.io, up_path) catch |e| switch (e) {
        error.FileNotFound => {
            tally.missing += blocks.len;
            return;
        },
        else => return e,
    };
    const up = pngx.decodeIndexed(gpa, up_png) catch {
        tally.wrong_size += blocks.len;
        return;
    };
    if (up.w != t.w * scale or up.h != t.h * scale) {
        tally.wrong_size += blocks.len;
        return;
    }
    for (blocks) |b| {
        const r: tiles.Rect = .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
        const im = blockImage(gpa, one.px, one.w, one.h, up.px, r, scale) catch {
            tally.bad_source += 1;
            continue;
        } orelse {
            tally.empty += 1;
            continue;
        };
        if (!try keyAgrees(gpa, b.key, im.key, t.png)) {
            tally.bad_source += 1;
            continue;
        }
        try images.append(gpa, im);
        tally.packed_frames += 1;
    }
}

fn readIndexed(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !pngx.Indexed {
    const bytes = source.readFile(gpa, io, path) catch |e| {
        std.debug.print("sprite: {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
    return pngx.decodeIndexed(gpa, bytes) catch |e| {
        std.debug.print("sprite: {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
}

/// The manifest's key (hex, "" for none) against the one the PNG gives.
fn keyAgrees(gpa: std.mem.Allocator, want: []const u8, got: u64, png: []const u8) !bool {
    const have = if (got == 0) "" else try std.fmt.allocPrint(gpa, "{x:0>16}", .{got});
    if (std.mem.eql(u8, want, have)) return true;
    std.debug.print("sprite: {s}: key {s}, the manifest says {s}\n", .{ png, have, want });
    return false;
}

/// One wall block's entry: the key and box of `r` in the 1x image (`w` x `h`), and the box, scaled,
/// cut from the upscaled image at the rect times `scale`. `null` for a block with nothing in it.
pub fn blockImage(gpa: std.mem.Allocator, one: []const u8, w: u32, h: u32, up: []const u8, r: tiles.Rect, scale: u32) !?hdpack.Image {
    if (r.w == 0 or r.h == 0 or r.x + r.w > w or r.y + r.h > h) return error.BadRect;
    const k = try framekey.compute(one[@as(usize, r.y) * w + r.x ..], r.w, r.h, w);
    if (k.key == 0 and k.box.w == 0) return null;
    const abs: framekey.Box = .{ .x0 = r.x + k.box.x0, .y0 = r.y + k.box.y0, .w = k.box.w, .h = k.box.h };
    return .{
        .key = k.key,
        .bw = @intCast(k.box.w),
        .bh = @intCast(k.box.h),
        .pixels = try crop(gpa, up, w * scale, abs, scale),
    };
}

fn frameImage(c: *main.Ctx, src_dir: []const u8, up_dir: []const u8, rel: []const u8, w: u32, h: u32, scale: u32, tally: *Tally) !?hdpack.Image {
    const gpa = c.gpa;
    if (w == 0 or h == 0) {
        tally.empty += 1;
        return null;
    }
    const src_path = try std.fs.path.join(gpa, &.{ src_dir, rel });
    const src_png = source.readFile(gpa, c.io, src_path) catch |e| {
        std.debug.print("sprite: {s}: {s}\n", .{ src_path, @errorName(e) });
        tally.bad_source += 1;
        return null;
    };
    const one = pngx.decodeIndexed(gpa, src_png) catch |e| {
        std.debug.print("sprite: {s}: {s}\n", .{ src_path, @errorName(e) });
        tally.bad_source += 1;
        return null;
    };
    if (one.w != w or one.h != h) {
        std.debug.print("sprite: {s}: {d}x{d}, the manifest says {d}x{d}\n", .{ src_path, one.w, one.h, w, h });
        tally.bad_source += 1;
        return null;
    }
    const k = framekey.compute(one.px, w, h, w) catch {
        tally.bad_source += 1;
        return null;
    };
    if (k.key == 0 and k.box.w == 0) {
        tally.empty += 1;
        return null;
    }

    const up_path = try std.fs.path.join(gpa, &.{ up_dir, rel });
    const up_png = source.readFile(gpa, c.io, up_path) catch |e| switch (e) {
        error.FileNotFound => {
            tally.missing += 1;
            return null;
        },
        else => return e,
    };
    const up = pngx.decodeIndexed(gpa, up_png) catch {
        tally.wrong_size += 1;
        return null;
    };
    if (up.w != w * scale or up.h != h * scale) {
        tally.wrong_size += 1;
        return null;
    }
    return .{
        .key = k.key,
        .bw = @intCast(k.box.w),
        .bh = @intCast(k.box.h),
        .pixels = try crop(gpa, up.px, up.w, k.box, scale),
    };
}

/// The box, scaled, cut out of an image `pitch` indices wide.
pub fn crop(gpa: std.mem.Allocator, px: []const u8, pitch: u32, box: framekey.Box, scale: u32) ![]u8 {
    const bw = box.w * scale;
    const bh = box.h * scale;
    const out = try gpa.alloc(u8, @as(usize, bw) * bh);
    for (0..bh) |y| {
        const from = (@as(usize, box.y0) * scale + y) * pitch + @as(usize, box.x0) * scale;
        @memcpy(out[y * bw ..][0..bw], px[from..][0..bw]);
    }
    return out;
}

test "crop takes the scaled box" {
    // 4x3 at 2x = 8x6; the box (1, 1, 2, 1) at 2x is columns 2..5 of rows 2..3.
    var px: [8 * 6]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i);
    const got = try crop(std.testing.allocator, &px, 8, .{ .x0 = 1, .y0 = 1, .w = 2, .h = 1 }, 2);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, &.{ 18, 19, 20, 21, 26, 27, 28, 29 }, got);
}

test "a wall block cut from a 2x wall image is the block's own box, scaled" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Two blocks; the second has art only in its right half, rows 4..27.
    var b0: [32 * 32]u8 = undefined;
    var b1 = [_]u8{0} ** (32 * 32);
    for (&b0, 0..) |*p, i| p.* = @intCast(i % 31 + 1);
    for (4..28) |y| for (16..32) |x| {
        b1[y * 32 + x] = @intCast((x * 3 + y) % 200 + 40);
    };
    const blocks = [_]tiles.Block{
        .{ .x = 0, .y = -64, .format = 0x1001, .pix = try tiles.encodeRle(a, &b0, 32, 32) },
        .{ .x = 32, .y = -32, .format = 0x1001, .pix = try tiles.encodeRle(a, &b1, 32, 32) },
    };
    const wall = try tiles.wallImage(a, &blocks);
    // A 2x "upscale" that is not nearest: each 2x2 cell holds four distinct values, so a cut
    // off by one texel in either axis cannot match.
    const s: u32 = 2;
    const uw = wall.w * s;
    const up = try a.alloc(u8, @as(usize, uw) * wall.h * s);
    for (0..wall.h * s) |y| for (0..uw) |x| {
        const v = wall.px[(y / s) * wall.w + x / s];
        up[y * uw + x] = if (v == 0) 0 else v +% @as(u8, @intCast((y % s) * 2 + x % s));
    };
    const im = (try blockImage(a, wall.px, wall.w, wall.h, up, wall.rects[1], s)).?;
    try std.testing.expectEqual(wall.keys[1].key, im.key);
    try std.testing.expectEqual(@as(u16, 16), im.bw);
    try std.testing.expectEqual(@as(u16, 24), im.bh);
    // Block 1 sits at (32, 32) in the 64x64 wall; its box at (16, 4) inside it; so at 2x the cut
    // starts at (96, 72) in the 128x128 image.
    for (0..im.bh * s) |y| for (0..im.bw * s) |x| {
        try std.testing.expectEqual(up[(72 + y) * uw + 96 + x], im.pixels[y * im.bw * s + x]);
        const v = b1[(4 + y / s) * 32 + 16 + x / s];
        try std.testing.expectEqual(v +% @as(u8, @intCast((y % s) * 2 + x % s)), im.pixels[y * im.bw * s + x]);
    };
    // An empty block has no entry.
    var empty = [_]u8{0} ** (64 * 32);
    try std.testing.expect(try blockImage(a, &empty, 64, 32, &empty, .{ .x = 32, .y = 0 }, 1) == null);
}
