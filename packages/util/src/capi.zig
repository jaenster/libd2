//! C-ABI shim for the d2-util package: MMPX index-space magnification (`lib.mmpx`), the frame key
//! (`lib.framekey`) and HD pack lookup and decoding (`lib.hdpack`), for C/C++ and for a mingw i686 DLL that
//! links the static library. Only C primitives cross the boundary. Nothing is allocated and there
//! is no state: every export is a pure function over caller memory, so the static library needs
//! neither an allocator nor libc from its host.

const std = @import("std");
const builtin = @import("builtin");
// Imported as a MODULE, not as a relative file, so this shim can be linked beside the other
// packages' shims in one artifact; a file may belong to only one module.
const lib = @import("d2-util");
const mmpx = lib.mmpx;
const framekey = lib.framekey;
const hdpack = lib.hdpack;

/// On Windows a failed safety check traps. The default handler prints a stack trace, which pulls
/// std's PDB reader and some sixty ntdll imports into the archive, and a Debug or ReleaseSafe
/// build would then no longer link into a mingw DLL. Release builds have no safety checks.
pub const panic = if (builtin.os.tag == .windows) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);

/// Bumped on any incompatible change to d2util.h.
const ABI_VERSION: i32 = 1;

/// Error codes, mirrored in d2util.h as D2UTIL_ERR_*.
const ERR_ARGS: i32 = -1; // null pointer, negative or oversized dimension, pitch too small, unknown flag
const ERR_SCALE: i32 = -2; // scale is not 1, 2, 3 or 4
const ERR_PACK: i32 = -3; // not an HD pack, an unknown version, or a damaged one
const ERR_DATA: i32 = -4; // an HD pack entry's stored bytes are not a sound zlib stream
const ERR_SIZE: i32 = -5; // an HD pack entry decodes to more or fewer bytes than the buffer holds

/// Flags for d2_upscale_indices_ex, mirrored in d2util.h as D2UTIL_*.
const EDGE_ZERO: i32 = 1 << 0;
const INDEX0_OPAQUE: i32 = 1 << 1;
const KNOWN_FLAGS: i32 = EDGE_ZERO | INDEX0_OPAQUE;

export fn d2util_abi_version() i32 {
    return ABI_VERSION;
}

/// MMPX-magnify `w` x `h` palette indices by `scale` (1, 2, 3 or 4), clamping at the image edge
/// and ranking index 0 as transparent. See d2_upscale_indices_ex.
export fn d2_upscale_indices(
    src: ?[*]const u8,
    w: i32,
    h: i32,
    src_pitch: i32,
    scale: i32,
    palette_rgb: ?[*]const u8,
    dst: ?[*]u8,
    dst_pitch: i32,
) i32 {
    return d2_upscale_indices_ex(src, w, h, src_pitch, scale, palette_rgb, dst, dst_pitch, 0);
}

/// As d2_upscale_indices, with `flags`: D2UTIL_EDGE_ZERO reads index 0 outside the image instead
/// of the nearest edge pixel; D2UTIL_INDEX0_OPAQUE ranks index 0 as an ordinary colour.
/// `dst` must hold `h * scale` rows of `dst_pitch` bytes (the last row needs only `w * scale`);
/// that size is the caller's contract and cannot be checked here.
export fn d2_upscale_indices_ex(
    src: ?[*]const u8,
    w: i32,
    h: i32,
    src_pitch: i32,
    scale: i32,
    palette_rgb: ?[*]const u8,
    dst: ?[*]u8,
    dst_pitch: i32,
    flags: i32,
) i32 {
    if (scale < 1 or scale > 4) return ERR_SCALE;
    if (flags & ~KNOWN_FLAGS != 0) return ERR_ARGS;
    if (w < 0 or h < 0 or src_pitch < 0 or dst_pitch < 0) return ERR_ARGS;
    if (w == 0 or h == 0) return 0;
    const s = src orelse return ERR_ARGS;
    const d = dst orelse return ERR_ARGS;

    const wu: u32 = @intCast(w);
    const hu: u32 = @intCast(h);
    const f: u32 = @intCast(scale);
    const sp: usize = @intCast(src_pitch);
    const dp: usize = @intCast(dst_pitch);
    if (wu > mmpx.max_dim or hu > mmpx.max_dim) return ERR_ARGS;
    if (sp < wu or dp < @as(usize, wu) * f) return ERR_ARGS;
    const src_len = std.math.add(usize, std.math.mul(usize, hu - 1, sp) catch return ERR_ARGS, wu) catch
        return ERR_ARGS;
    const dst_len = mmpx.dstLen(wu, hu, f, dp) orelse return ERR_ARGS;

    const opts: mmpx.Options = .{
        .palette = if (palette_rgb) |p| p[0..768] else null,
        .edge = if (flags & EDGE_ZERO != 0) .zero else .clamp,
        .index0_transparent = flags & INDEX0_OPAQUE == 0,
    };
    mmpx.scale(s[0..src_len], wu, hu, sp, f, opts, d[0..dst_len], dp) catch |e| return switch (e) {
        error.UnsupportedScale => ERR_SCALE,
        else => ERR_ARGS,
    };
    return 0;
}

/// The key of a `w` x `h` index image (`pitch` bytes per row, top row first): FNV-1a 64 over the
/// bounding box of its non-zero indices. Writes the key to `key_out` (0 when every index is 0) and
/// the box as x0, y0, width, height to `box_out` (all 0 then). Returns 0 or ERR_ARGS.
export fn d2_frame_key(src: ?[*]const u8, w: i32, h: i32, pitch: i32, key_out: ?*u64, box_out: ?*[4]i32) i32 {
    const ko = key_out orelse return ERR_ARGS;
    const bo = box_out orelse return ERR_ARGS;
    ko.* = 0;
    bo.* = @splat(0);
    if (w < 0 or h < 0 or pitch < w) return ERR_ARGS;
    if (w == 0 or h == 0) return 0;
    const s = src orelse return ERR_ARGS;
    const wu: u32 = @intCast(w);
    const hu: u32 = @intCast(h);
    const pu: usize = @intCast(pitch);
    const len = std.math.add(usize, std.math.mul(usize, hu - 1, pu) catch return ERR_ARGS, wu) catch return ERR_ARGS;
    const k = framekey.compute(s[0..len], wu, hu, pu) catch return ERR_ARGS;
    ko.* = k.key;
    bo.* = .{ @intCast(k.box.x0), @intCast(k.box.y0), @intCast(k.box.w), @intCast(k.box.h) };
    return 0;
}

/// Checks a whole HD pack of `len` bytes (header, table order, every entry in bounds) and reports
/// its scale and entry count. Linear in the entry count: call it once when the pack is loaded.
/// Accepts both versions; d2_hdpack_info2 also reports which. Returns 0, ERR_ARGS or ERR_PACK.
export fn d2_hdpack_info(pack: ?[*]const u8, len: usize, scale_out: ?*u32, count_out: ?*u32) i32 {
    return d2_hdpack_info2(pack, len, null, scale_out, count_out);
}

/// As d2_hdpack_info, also reporting the pack's version (1 or 2).
export fn d2_hdpack_info2(pack: ?[*]const u8, len: usize, version_out: ?*u32, scale_out: ?*u32, count_out: ?*u32) i32 {
    const p = pack orelse return ERR_ARGS;
    const h = hdpack.validate(p[0..len]) catch return ERR_PACK;
    if (version_out) |o| o.* = h.version;
    if (scale_out) |o| o.* = h.scale;
    if (count_out) |o| o.* = h.count;
    return 0;
}

/// Looks up the image filed under (`key`, `bw`, `bh`) in the HD pack of `len` bytes: a binary
/// search. On a hit, stores a pointer into the pack at `pixels` (`bw*scale` x `bh*scale` indices,
/// top row first) and returns the pack's scale; otherwise returns 0 and stores NULL. A version 2
/// entry is a hit only when it is stored raw; d2_hdpack_find answers for every entry. Never reads
/// outside the pack, even a damaged one.
export fn d2_hdpack_lookup(pack: ?[*]const u8, len: usize, key: u64, bw: u16, bh: u16, pixels: ?*?[*]const u8) i32 {
    if (pixels) |o| o.* = null;
    const p = pack orelse return 0;
    const hit = hdpack.lookup(p[0..len], key, bw, bh) orelse return 0;
    if (pixels) |o| o.* = hit.pixels.ptr;
    return @intCast(hit.scale);
}

/// Looks up the entry filed under (`key`, `bw`, `bh`) in an HD pack of either version held whole
/// in memory. On a hit, stores a pointer to its stored bytes and their count and returns the
/// pack's scale; d2_hdpack_inflate turns them into the image. Otherwise returns 0 and stores NULL
/// and 0. Never reads outside the pack, even a damaged one.
export fn d2_hdpack_find(pack: ?[*]const u8, len: usize, key: u64, bw: u16, bh: u16, stored: ?*?[*]const u8, stored_len: ?*usize) i32 {
    if (stored) |o| o.* = null;
    if (stored_len) |o| o.* = 0;
    const p = pack orelse return 0;
    const f = hdpack.find(p[0..len], key, bw, bh) orelse return 0;
    if (stored) |o| o.* = f.stored.ptr;
    if (stored_len) |o| o.* = f.stored.len;
    return @intCast(f.scale);
}

/// Decodes one HD pack entry's stored bytes into `out`, which must be the image's size
/// (`bw*scale * bh*scale`): a copy when `stored_len == out_len` (the raw form), otherwise zlib
/// inflation with the header, Adler-32, size and end of the stream all checked. Needs only the
/// entry's bytes, not the pack. Returns 0, ERR_ARGS, ERR_DATA or ERR_SIZE.
export fn d2_hdpack_inflate(stored: ?[*]const u8, stored_len: usize, out: ?[*]u8, out_len: usize) i32 {
    const s: []const u8 = if (stored) |p| p[0..stored_len] else if (stored_len == 0) &.{} else return ERR_ARGS;
    const o: []u8 = if (out) |p| p[0..out_len] else if (out_len == 0) &.{} else return ERR_ARGS;
    hdpack.decode(s, o) catch |e| return switch (e) {
        error.Corrupt => ERR_DATA,
        error.WrongSize => ERR_SIZE,
    };
    return 0;
}

test "the C entry points agree with lib.mmpx" {
    var src: [6 * 5]u8 = undefined;
    for (&src, 0..) |*p, i| p.* = @intCast((i * 7 + i / 6) % 3);
    var want: [24 * 20]u8 = undefined;
    var got: [24 * 20]u8 = undefined;
    for (1..5) |f| {
        const fu: u32 = @intCast(f);
        try mmpx.scale(&src, 6, 5, 6, fu, .{ .edge = .zero }, &want, 6 * fu);
        try std.testing.expectEqual(@as(i32, 0), d2_upscale_indices_ex(&src, 6, 5, 6, @intCast(f), null, &got, @intCast(6 * f), EDGE_ZERO));
        try std.testing.expectEqualSlices(u8, want[0 .. 30 * fu * fu], got[0 .. 30 * fu * fu]);
        try mmpx.scale(&src, 6, 5, 6, fu, .{}, &want, 6 * fu);
        try std.testing.expectEqual(@as(i32, 0), d2_upscale_indices(&src, 6, 5, 6, @intCast(f), null, &got, @intCast(6 * f)));
        try std.testing.expectEqualSlices(u8, want[0 .. 30 * fu * fu], got[0 .. 30 * fu * fu]);
    }
}

test "argument errors" {
    var src: [16]u8 = @splat(0);
    var dst: [256]u8 = undefined;
    try std.testing.expectEqual(ERR_SCALE, d2_upscale_indices(&src, 4, 4, 4, 5, null, &dst, 20));
    try std.testing.expectEqual(ERR_SCALE, d2_upscale_indices(&src, 4, 4, 4, 0, null, &dst, 20));
    try std.testing.expectEqual(ERR_ARGS, d2_upscale_indices(null, 4, 4, 4, 2, null, &dst, 8));
    try std.testing.expectEqual(ERR_ARGS, d2_upscale_indices(&src, 4, 4, 4, 2, null, null, 8));
    try std.testing.expectEqual(ERR_ARGS, d2_upscale_indices(&src, -1, 4, 4, 2, null, &dst, 8));
    try std.testing.expectEqual(ERR_ARGS, d2_upscale_indices(&src, 4, 4, 3, 2, null, &dst, 8));
    try std.testing.expectEqual(ERR_ARGS, d2_upscale_indices(&src, 4, 4, 4, 2, null, &dst, 7));
    try std.testing.expectEqual(ERR_ARGS, d2_upscale_indices_ex(&src, 4, 4, 4, 2, null, &dst, 8, 4));
    try std.testing.expectEqual(@as(i32, 0), d2_upscale_indices(&src, 0, 0, 0, 2, null, null, 0));
    try std.testing.expectEqual(ABI_VERSION, d2util_abi_version());
}

test "d2_frame_key agrees with lib.framekey" {
    var px = [_]u8{0} ** (6 * 5);
    px[1 * 6 + 2] = 5;
    px[3 * 6 + 4] = 6;
    var key: u64 = 1;
    var box: [4]i32 = .{ 9, 9, 9, 9 };
    try std.testing.expectEqual(@as(i32, 0), d2_frame_key(&px, 5, 5, 6, &key, &box));
    const want = try framekey.compute(&px, 5, 5, 6);
    try std.testing.expectEqual(want.key, key);
    try std.testing.expectEqual([4]i32{ 2, 1, 3, 3 }, box);

    const z = [_]u8{0} ** 4;
    try std.testing.expectEqual(@as(i32, 0), d2_frame_key(&z, 2, 2, 2, &key, &box));
    try std.testing.expectEqual(@as(u64, 0), key);
    try std.testing.expectEqual([4]i32{ 0, 0, 0, 0 }, box);

    try std.testing.expectEqual(ERR_ARGS, d2_frame_key(&px, 5, 5, 4, &key, &box));
    try std.testing.expectEqual(ERR_ARGS, d2_frame_key(null, 5, 5, 6, &key, &box));
    try std.testing.expectEqual(ERR_ARGS, d2_frame_key(&px, 5, 5, 6, null, &box));
    try std.testing.expectEqual(@as(i32, 0), d2_frame_key(null, 0, 0, 0, &key, &box));
}

test "d2_hdpack_info and d2_hdpack_lookup agree with lib.hdpack" {
    const gpa = std.testing.allocator;
    const a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const pack = try hdpack.encode(gpa, 3, &.{.{ .key = 0x1234_5678_9abc_def0, .bw = 1, .bh = 1, .pixels = &a }}, .{ .version = 1 });
    defer gpa.free(pack);

    var scale: u32 = 0;
    var count: u32 = 0;
    var version: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_info(pack.ptr, pack.len, &scale, &count));
    try std.testing.expectEqual(@as(u32, 3), scale);
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_info2(pack.ptr, pack.len, &version, null, null));
    try std.testing.expectEqual(@as(u32, 1), version);
    try std.testing.expectEqual(ERR_PACK, d2_hdpack_info(pack.ptr, pack.len - 1, &scale, &count));
    try std.testing.expectEqual(ERR_ARGS, d2_hdpack_info(null, 0, &scale, &count));

    var px: ?[*]const u8 = null;
    try std.testing.expectEqual(@as(i32, 3), d2_hdpack_lookup(pack.ptr, pack.len, 0x1234_5678_9abc_def0, 1, 1, &px));
    try std.testing.expectEqualSlices(u8, &a, px.?[0..9]);
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_lookup(pack.ptr, pack.len, 0x1234_5678_9abc_def0, 1, 2, &px));
    try std.testing.expectEqual(@as(?[*]const u8, null), px);
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_lookup(pack.ptr, pack.len - 1, 0x1234_5678_9abc_def0, 1, 1, &px));
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_lookup(null, 0, 1, 1, 1, &px));
}

test "a version 2 pack through the C entry points" {
    const gpa = std.testing.allocator;
    var big: [16 * 16 * 4]u8 = undefined; // 16x16 at 2x, compresses
    for (&big, 0..) |*p, i| p.* = @intCast(i / 50);
    const small = [_]u8{ 1, 2, 3, 4 }; // 1x1 at 2x, stored raw
    const pack = try hdpack.encode(gpa, 2, &.{
        .{ .key = 5, .bw = 16, .bh = 16, .pixels = &big },
        .{ .key = 6, .bw = 1, .bh = 1, .pixels = &small },
    }, .{});
    defer gpa.free(pack);

    var version: u32 = 0;
    var scale: u32 = 0;
    var count: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_info2(pack.ptr, pack.len, &version, &scale, &count));
    try std.testing.expectEqual([3]u32{ 2, 2, 2 }, [3]u32{ version, scale, count });
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_info(pack.ptr, pack.len, &scale, &count));

    var stored: ?[*]const u8 = null;
    var stored_len: usize = 0;
    var out: [big.len + 1]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 2), d2_hdpack_find(pack.ptr, pack.len, 5, 16, 16, &stored, &stored_len));
    try std.testing.expect(stored_len < big.len);
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_inflate(stored, stored_len, &out, big.len));
    try std.testing.expectEqualSlices(u8, &big, out[0..big.len]);
    try std.testing.expectEqual(ERR_SIZE, d2_hdpack_inflate(stored, stored_len, &out, big.len - 1));
    try std.testing.expectEqual(ERR_SIZE, d2_hdpack_inflate(stored, stored_len, &out, big.len + 1));
    try std.testing.expectEqual(ERR_DATA, d2_hdpack_inflate(stored, stored_len - 1, &out, big.len));
    var bad: [big.len]u8 = undefined;
    @memcpy(bad[0..stored_len], stored.?[0..stored_len]);
    bad[stored_len - 2] ^= 0x40; // inside the Adler-32
    try std.testing.expectEqual(ERR_DATA, d2_hdpack_inflate(&bad, stored_len, &out, big.len));
    try std.testing.expectEqual(ERR_ARGS, d2_hdpack_inflate(null, 4, &out, big.len));
    try std.testing.expectEqual(ERR_ARGS, d2_hdpack_inflate(stored, stored_len, null, big.len));
    // A compressed entry has no image in the pack to point at.
    var px: ?[*]const u8 = null;
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_lookup(pack.ptr, pack.len, 5, 16, 16, &px));

    // The raw entry: lookup points at it, and inflate copies it.
    try std.testing.expectEqual(@as(i32, 2), d2_hdpack_find(pack.ptr, pack.len, 6, 1, 1, &stored, &stored_len));
    try std.testing.expectEqual(@as(usize, 4), stored_len);
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_inflate(stored, stored_len, &out, 4));
    try std.testing.expectEqualSlices(u8, &small, out[0..4]);
    try std.testing.expectEqual(@as(i32, 2), d2_hdpack_lookup(pack.ptr, pack.len, 6, 1, 1, &px));
    try std.testing.expectEqualSlices(u8, &small, px.?[0..4]);

    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_find(pack.ptr, pack.len, 6, 1, 2, &stored, &stored_len));
    try std.testing.expectEqual(@as(?[*]const u8, null), stored);
    try std.testing.expectEqual(@as(usize, 0), stored_len);
    try std.testing.expectEqual(@as(i32, 0), d2_hdpack_find(null, 0, 6, 1, 1, &stored, &stored_len));
}
