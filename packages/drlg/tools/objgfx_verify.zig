//! objgfx_verify — standalone pipeline check: decode a waypoint (token wp) and a
//! chest (token L1) object sprite (mode NU, dir 0, frame 0) via the DCC/COF/objgfx
//! stack and write each to a PNG. Also decodes the OP mode to prove animation
//! frames work. Requires assets/objects/<TOK>/ (run tools/extract_objects) and
//! assets/automap/ACT1.pal.
//!
//! Build/run:
//!   zig build objgfx-verify   (from the d2-drlg worktree)
//! or standalone:
//!   zig build-exe tools/objgfx_verify.zig -femit-bin=/tmp/objgfx_verify && .//tmp/objgfx_verify

const std = @import("std");
const objgfx = @import("objgfx");

fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024));
}

// -------- minimal PNG writer (RGBA8888, stored/uncompressed zlib) --------

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (data) |b| {
        crc ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = @bitCast(-@as(i32, @intCast(crc & 1)));
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return ~crc;
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writePng(alloc: std.mem.Allocator, path: []const u8, w: u32, h: u32, rgba: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(alloc, &out, "IHDR", &ihdr);

    // Raw scanlines: filter byte 0 + row RGBA.
    const raw_len = (@as(usize, w) * 4 + 1) * h;
    const raw = try alloc.alloc(u8, raw_len);
    defer alloc.free(raw);
    {
        var y: usize = 0;
        var o: usize = 0;
        while (y < h) : (y += 1) {
            raw[o] = 0;
            o += 1;
            const src = rgba[y * w * 4 .. (y + 1) * w * 4];
            @memcpy(raw[o .. o + w * 4], src);
            o += w * 4;
        }
    }

    // zlib stream: header + stored deflate blocks + adler32.
    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(alloc);
    try zlib.appendSlice(alloc, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.len) {
        const chunk = @min(raw.len - off, 65535);
        const final: u8 = if (off + chunk >= raw.len) 1 else 0;
        try zlib.append(alloc, final); // BFINAL, BTYPE=00
        var lenb: [2]u8 = undefined;
        std.mem.writeInt(u16, &lenb, @intCast(chunk), .little);
        try zlib.appendSlice(alloc, &lenb);
        const nlen = ~@as(u16, @intCast(chunk));
        std.mem.writeInt(u16, &lenb, nlen, .little);
        try zlib.appendSlice(alloc, &lenb);
        try zlib.appendSlice(alloc, raw[off .. off + chunk]);
        off += chunk;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(raw), .big);
    try zlib.appendSlice(alloc, &adler);

    try writeChunk(alloc, &out, "IDAT", zlib.items);
    try writeChunk(alloc, &out, "IEND", &.{});

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn writeChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, data: []const u8) !void {
    var lenb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenb, @intCast(data.len), .big);
    try out.appendSlice(alloc, &lenb);
    try out.appendSlice(alloc, tag);
    try out.appendSlice(alloc, data);
    const crc_input = try alloc.alloc(u8, tag.len + data.len);
    defer alloc.free(crc_input);
    @memcpy(crc_input[0..tag.len], tag);
    @memcpy(crc_input[tag.len..], data);
    var crcb: [4]u8 = undefined;
    std.mem.writeInt(u32, &crcb, crc32(crc_input), .big);
    try out.appendSlice(alloc, &crcb);
}

// ------------------------------------------------------------------------

fn decodeAndSave(
    io: std.Io,
    alloc: std.mem.Allocator,
    palette: []const u8,
    token: []const u8,
    mode: []const u8,
    out_path: []const u8,
) !void {
    var sprite = objgfx.composite(alloc, "assets", token, mode, "HTH", 0, 0, palette) catch |e| {
        std.debug.print("  FAIL {s} {s}: {s}\n", .{ token, mode, @errorName(e) });
        return e;
    };
    defer sprite.deinit();

    // Count opaque pixels as a sanity signal.
    var opaque_px: usize = 0;
    var i: usize = 3;
    while (i < sprite.rgba.len) : (i += 4) {
        if (sprite.rgba[i] != 0) opaque_px += 1;
    }
    _ = io;
    try writePng(alloc, out_path, sprite.width, sprite.height, sprite.rgba);
    std.debug.print("  OK  {s} {s}: {d}x{d} off=({d},{d}) opaque={d} -> {s}\n", .{
        token, mode, sprite.width, sprite.height, sprite.offset_x, sprite.offset_y, opaque_px, out_path,
    });
    if (opaque_px == 0) return error.EmptySprite;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const palette = try readFile(io, alloc, "assets/automap/ACT1.pal");
    if (palette.len != 768) {
        std.debug.print("bad palette len {d}\n", .{palette.len});
        return error.BadPalette;
    }

    // Also exercise the Objects.txt loader.
    const objtxt = try readFile(io, alloc, "src/excel/Objects.txt");
    var objs = try objgfx.loadObjects(alloc, objtxt);
    defer objs.deinit();
    if (objs.byId(119)) |wp| std.debug.print("Objects.txt: id119 name='{s}' token='{s}' NU_frames={d}\n", .{ wp.name, wp.token, wp.frame_cnt[0] });

    std.Io.Dir.cwd().createDirPath(io, "out") catch {};

    std.debug.print("decoding object sprites:\n", .{});
    try decodeAndSave(io, alloc, palette, "wp", "NU", "out/waypoint_nu.png");
    try decodeAndSave(io, alloc, palette, "wp", "OP", "out/waypoint_op.png");
    try decodeAndSave(io, alloc, palette, "L1", "NU", "out/chest_nu.png");
    try decodeAndSave(io, alloc, palette, "L1", "OP", "out/chest_op.png");
    std.debug.print("done.\n", .{});
}
