//! C-ABI shim for the d2-util package: MMPX index-space magnification (`lib.mmpx`) for C/C++ and
//! for a mingw i686 DLL that links the static library. Only C primitives cross the boundary.
//! Nothing is allocated and there is no state: every export is a pure function over caller
//! memory, so the static library needs neither an allocator nor libc from its host.

const std = @import("std");
const builtin = @import("builtin");
// Imported as a MODULE, not as a relative file, so this shim can be linked beside the other
// packages' shims in one artifact; a file may belong to only one module.
const lib = @import("d2-util");
const mmpx = lib.mmpx;

/// On Windows a failed safety check traps. The default handler prints a stack trace, which pulls
/// std's PDB reader and some sixty ntdll imports into the archive, and a Debug or ReleaseSafe
/// build would then no longer link into a mingw DLL. Release builds have no safety checks.
pub const panic = if (builtin.os.tag == .windows) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);

/// Bumped on any incompatible change to d2util.h.
const ABI_VERSION: i32 = 1;

/// Error codes, mirrored in d2util.h as D2UTIL_ERR_*.
const ERR_ARGS: i32 = -1; // null pointer, negative or oversized dimension, pitch too small, unknown flag
const ERR_SCALE: i32 = -2; // scale is not 1, 2, 3 or 4

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
