//! DCC write-back: from a decoded (and possibly rescaled) sprite to `dcc.encode`'s input.
//!
//! A DCC frame is its direction's box of pixels plus the frame's own box inside it, and the
//! encoder needs both. Scaling multiplies both boxes by k; MMPX may then carry a frame's pixels a
//! little past its scaled box (a slope rule copies a neighbour into the block of an empty pixel),
//! so each frame box is grown to cover its non-zero pixels. That keeps every box inside the
//! direction box and their union equal to it, which is what the encoder checks.

const std = @import("std");
const formats = @import("d2-formats");
const dcc = formats.dcc;
const sprite = @import("sprite.zig");
const scale_mod = @import("scale.zig");
const main = @import("main.zig");
const pack = @import("pack.zig");
const Indexed = @import("d2-util").png.Indexed;

pub const Header = struct { version: u8 };

pub fn frameBox(d: *const dcc.Dcc, dir: usize, f: usize) ?[4]i32 {
    const boxes = d.directions[dir].frame_boxes;
    if (boxes.len == 0) return null;
    const b = boxes[f];
    return .{ b.left, b.top, b.width, b.height };
}

pub fn header(d: *const dcc.Dcc) ?Header {
    return .{ .version = d.version };
}

/// `box` scaled by k and grown to cover every non-zero pixel of `px` (a `dbox`-sized frame).
fn grownBox(box: dcc.Rect, k: i32, dbox: dcc.Rect, px: []const u8) dcc.Rect {
    var x0 = box.left * k;
    var y0 = box.top * k;
    var x1 = x0 + box.width * k;
    var y1 = y0 + box.height * k;
    const w: usize = @intCast(dbox.width);
    for (px, 0..) |v, i| {
        if (v == 0) continue;
        const x = dbox.left + @as(i32, @intCast(i % w));
        const y = dbox.top + @as(i32, @intCast(i / w));
        x0 = @min(x0, x);
        y0 = @min(y0, y);
        x1 = @max(x1, x + 1);
        y1 = @max(y1, y + 1);
    }
    return .{ .left = x0, .top = y0, .width = x1 - x0, .height = y1 - y0 };
}

fn build(gpa: std.mem.Allocator, dirs: u32, fpd: u32, version: u8, k: i32, dboxes: []const dcc.Rect, boxes: []const ?dcc.Rect, pixels: []const []u8) !dcc.Dcc {
    const directions = try gpa.alloc(dcc.Direction, dirs);
    for (directions, 0..) |*d, di| {
        const src = dboxes[di];
        const dbox: dcc.Rect = .{ .left = src.left * k, .top = src.top * k, .width = src.width * k, .height = src.height * k };
        const frames = try gpa.alloc([]u8, fpd);
        const fb = try gpa.alloc(dcc.Rect, fpd);
        for (0..fpd) |f| {
            const i = di * fpd + f;
            frames[f] = pixels[i];
            const b = boxes[i] orelse src;
            fb[f] = if (k == 1) b else grownBox(b, k, dbox, pixels[i]);
        }
        d.* = .{ .box = dbox, .frames = frames, .frame_boxes = fb };
    }
    return .{ .directions = directions, .frames_per_dir = fpd, .allocator = gpa, .version = version };
}

/// Encode what `pack` read back: `images[i]` is frame i at `k` times the recorded size.
pub fn encodeFromDoc(gpa: std.mem.Allocator, doc: *const pack.Doc, images: []const Indexed, k: i32) ![]u8 {
    const n = doc.frames.len;
    const dboxes = try gpa.alloc(dcc.Rect, doc.dirs);
    const boxes = try gpa.alloc(?dcc.Rect, n);
    const pixels = try gpa.alloc([]u8, n);
    for (doc.frames, 0..) |f, i| {
        if (f.frame == 0) dboxes[f.dir] = .{ .left = f.x, .top = f.y, .width = @intCast(f.w), .height = @intCast(f.h) };
        boxes[i] = if (f.box) |b| .{ .left = b[0], .top = b[1], .width = b[2], .height = b[3] } else null;
        pixels[i] = images[i].px;
    }
    const version: u8 = if (doc.dcc) |h| h.version else 6;
    const d = try build(gpa, doc.dirs, doc.framesPerDir, version, k, dboxes, boxes, pixels);
    return dcc.encode(gpa, &d);
}

/// Scale every frame of a decoded DCC and encode the result.
pub fn encodeScaled(gpa: std.mem.Allocator, sp: *const sprite.Sprite, k: u32, filt: scale_mod.Filter, pal: *const main.Palette) ![]u8 {
    const src = sp.dcc orelse return error.NotADcc;
    const n = sp.frames.len;
    const dboxes = try gpa.alloc(dcc.Rect, sp.dirs);
    const boxes = try gpa.alloc(?dcc.Rect, n);
    const pixels = try gpa.alloc([]u8, n);
    for (src.directions, 0..) |d, di| dboxes[di] = d.box;
    for (sp.frames, 0..) |*f, i| {
        const d = src.directions[i / sp.fpd];
        boxes[i] = if (d.frame_boxes.len > 0) d.frame_boxes[i % sp.fpd] else null;
        pixels[i] = try scale_mod.scale(gpa, f.px, f.w, f.h, k, filt, &pal.rgb);
    }
    const d = try build(gpa, sp.dirs, sp.fpd, src.version, @intCast(k), dboxes, boxes, pixels);
    return dcc.encode(gpa, &d);
}

/// Decode, encode, decode again: the frames, direction boxes and frame boxes must agree.
pub fn roundTrip(gpa: std.mem.Allocator, bytes: []const u8) !pack.Outcome {
    const a = dcc.parse(gpa, bytes) catch return .undecodable;
    const again = try dcc.encode(gpa, &a);
    const b = try dcc.parse(gpa, again);
    if (a.directions.len != b.directions.len or a.frames_per_dir != b.frames_per_dir) return .different;
    for (a.directions, b.directions) |da, db| {
        if (!std.meta.eql(da.box, db.box)) return .different;
        if (da.frame_boxes.len != db.frame_boxes.len) return .different;
        for (da.frame_boxes, db.frame_boxes) |x, y| if (!std.meta.eql(x, y)) return .different;
        for (da.frames, db.frames) |x, y| if (!std.mem.eql(u8, x, y)) return .different;
    }
    return if (std.mem.eql(u8, bytes, again)) .identical else .equivalent;
}
