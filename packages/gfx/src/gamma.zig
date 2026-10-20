//! The Options' gamma and contrast as the picture shows them. The game builds a display ramp from
//! the two sliders (1.14d's table builder, Game.exe 0x6be190): entry i of n, x = i / (n - 1),
//!
//!   linear = min(x * gamma / 100 * max, max)
//!   power  = x ^ (100 / gamma) * max
//!   entry  = trunc((linear * contrast + power * (100 - contrast)) / 100)
//!
//! with gamma the slider's value (55..255, 100 no change) and contrast 0..100. D2OpenGL applies the
//! 8-bit table of that ramp to the finished frame rather than to the display.
const std = @import("std");

pub fn clampLevel(g: i32) i32 {
    return std.math.clamp(g, 55, 255);
}

/// The 8-bit table for a gamma and contrast.
pub fn table(gamma: i32, contrast: i32) [256]u8 {
    const g: f64 = @floatFromInt(clampLevel(gamma));
    const c: f64 = @floatFromInt(contrast);
    const max: f64 = 0xffff;
    var out: [256]u8 = undefined;
    for (0..256) |i| {
        const fi: f64 = @floatFromInt(i);
        const lin = @min(fi * (g / 100.0) * max / 255.0, max);
        const pow = std.math.pow(f64, fi / 255.0, 100.0 / g);
        const v: f64 = (lin * c + pow * max * (100.0 - c)) / 100.0;
        const ramp: u32 = @intFromFloat(@trunc(v));
        out[i] = @intCast((ramp * 255 + 0x7fff) / 0xffff);
    }
    return out;
}

/// The table over an RGBA8 frame's colour channels.
pub fn apply(px: []u8, t: *const [256]u8) void {
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        px[i] = t[px[i]];
        px[i + 1] = t[px[i + 1]];
        px[i + 2] = t[px[i + 2]];
    }
}

test "gamma 100 with no contrast leaves the picture alone" {
    const t = table(100, 0);
    for (t, 0..) |v, i| try std.testing.expectEqual(@as(u8, @intCast(i)), v);
}
