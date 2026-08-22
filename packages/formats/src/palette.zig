//! D2 palettes — `pal.dat`, the 256-entry colour table every DC6 and DCC index refers to.
//!
//! An entry is three bytes stored **B, G, R**. Getting that backwards does not produce an obviously
//! broken picture: it produces a picture whose browns are blue, which reads as "wrong palette"
//! rather than "wrong byte order" and costs an afternoon.
//!
//! The `.pl2` sitting next to each `.dat` is the light/blend index table the in-game renderer
//! needs; it is a different file with a different job and is not parsed here.
const std = @import("std");

pub const Error = error{ShortPalette};

pub const entries = 256;
pub const bytes_len = entries * 3;

pub const Palette = struct {
    /// 256 entries of B,G,R, exactly as the file stores them.
    bgr: [bytes_len]u8,

    /// The RGB triple for an index, in the order everything outside D2 expects.
    pub fn rgb(self: *const Palette, index: u8) [3]u8 {
        const i = @as(usize, index) * 3;
        return .{ self.bgr[i + 2], self.bgr[i + 1], self.bgr[i] };
    }

    /// The raw table, for the decoders that take a palette as a byte slice.
    pub fn slice(self: *const Palette) []const u8 {
        return &self.bgr;
    }
};

pub fn parseDat(data: []const u8) Error!Palette {
    if (data.len < bytes_len) return Error.ShortPalette;
    var pal: Palette = undefined;
    @memcpy(&pal.bgr, data[0..bytes_len]);
    return pal;
}

/// The palette directories the game ships, as the names they have on disk.
///
/// `units` is the one the expansion's front-end screens are painted in, which is worth stating
/// because `fechar` — "front-end character" — reads like the obvious candidate and is not it.
/// The backgrounds are dithered, so the wrong palette does not tint a screen, it speckles it.
pub const dir_units = "units";
pub const dir_frontend_char = "fechar";
pub const dir_sky = "sky";
pub const dir_loading = "loading";
pub const dir_static = "static";
pub const dir_trademark = "trademark";
pub const dir_endgame = "endgame";

/// `data/global/palette/<dir>/pal.dat`, written into `buf`.
pub fn datPath(buf: []u8, dir: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "data/global/palette/{s}/pal.dat", .{dir});
}

const testing = std.testing;

test "an entry comes back as RGB from a BGR file" {
    var raw: [bytes_len]u8 = @splat(0);
    // Index 1 = a mid brown: R 0x8c, G 0x48, B 0x10, stored B first.
    raw[3] = 0x10;
    raw[4] = 0x48;
    raw[5] = 0x8c;

    const pal = try parseDat(&raw);
    try testing.expectEqual([3]u8{ 0x8c, 0x48, 0x10 }, pal.rgb(1));
}

test "a short file is refused rather than read past" {
    var raw: [bytes_len - 1]u8 = @splat(0);
    try testing.expectError(Error.ShortPalette, parseDat(&raw));
}

test "the path is the one the game builds" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "data/global/palette/units/pal.dat",
        try datPath(&buf, dir_units),
    );
}
