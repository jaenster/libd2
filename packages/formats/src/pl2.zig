//! `pal.pl2` — the blend and colour-shift tables that sit beside every `pal.dat`.
//!
//! A PL2 is one enormous fixed-layout blob: the base palette, then light levels, blend matrices,
//! hue variations, and at the very end the tables that colour text. Only that tail is parsed here,
//! because it is the only part with no substitute — everything else has an arithmetic
//! approximation and this does not.
//!
//! ## Layout
//!
//! Sizes in bytes, in file order. A "transform" is 256 bytes: a map from palette index to palette
//! index.
//!
//!     base palette          256 * 4     1024
//!     light level           32 transforms
//!     inv colour            16 transforms
//!     selected unit shift    1 transform
//!     alpha blend            3 * 256 transforms
//!     additive blend       256 transforms
//!     multiply blend       256 transforms
//!     hue variations       111 transforms
//!     red / green / blue     1 transform each
//!     unknown               14 transforms
//!     max component blend  256 transforms
//!     darkened colour shift  1 transform
//!     text colours          13 * 3       39
//!     text colour shifts    13 transforms
//!
//! That totals exactly 443175, which is what a 1.14d `pal.pl2` measures — and it is how the
//! "max component blend" block was settled, since one transform there instead of 256 leaves the
//! file 65280 bytes short.
//!
//! The tail is located from the END of the file rather than by summing that list. The sum is a
//! statement about a format nobody documented; the file's own length is a fact.
const std = @import("std");

pub const Error = error{ShortPl2};

pub const transform_len = 256;

/// The palette ids `GLOBALPALLETE` names, which is also what a `ÿc<digit>` colour code selects.
/// Zero is not a table: it means "do not shift", which is why the file's table 0 is all zeros and
/// would otherwise make every glyph transparent.
pub const TextColor = enum(u8) {
    white = 0,
    red = 1,
    green = 2,
    blue = 3,
    gold = 4,
    dark_grey = 5,
    black = 6,
    light_gold = 7,
    orange = 8,
    light_yellow = 9,
    dark_green = 10,
    purple = 11,
    green2 = 12,
};

pub const text_color_count = 13;
const shifts_len = text_color_count * transform_len;
const colors_len = text_color_count * 3;

fn shiftsStart(bytes: []const u8) Error!usize {
    if (bytes.len < shifts_len + colors_len) return Error.ShortPl2;
    return bytes.len - shifts_len;
}

/// The RGB a text colour nominally is. Not used for drawing — the shift table is — but it is what
/// makes a palette id legible to a person, and it is how the tail was verified: index 6 is black,
/// index 7 is the light gold the front-end titles are drawn in.
pub fn textColor(bytes: []const u8, index: TextColor) Error![3]u8 {
    const at = try shiftsStart(bytes);
    const off = at - colors_len + @as(usize, @intFromEnum(index)) * 3;
    return .{ bytes[off], bytes[off + 1], bytes[off + 2] };
}

/// The one transform the file calls a darkened colour shift, which sits immediately before the
/// text colours.
///
/// This is what `DRAW_DARKTRANSPARENT` draws with — draw mode 4, the mode every button caption in
/// the front end uses. `Create_D2WinButton` memsets its button and never sets a font or a text
/// colour, so a caption is font 0 and palette 0, which is "do not shift"; the darkness is this
/// transform and nothing else. Flattening the glyphs to one black index instead loses their
/// shading and the letters come out thick and closed up.
pub fn darkShift(bytes: []const u8) Error![]const u8 {
    const at = try shiftsStart(bytes);
    if (at < colors_len + transform_len) return Error.ShortPl2;
    return bytes[at - colors_len - transform_len ..][0..transform_len];
}

/// The index remap for a text colour: `new = table[old]`.
///
/// Index 0 maps to 0 in every table, so a sprite's holes stay holes. Returns null for `white`,
/// which has no table — drawing unshifted is what it means.
pub fn textShift(bytes: []const u8, index: TextColor) Error!?[]const u8 {
    if (index == .white) return null;
    const at = try shiftsStart(bytes);
    const off = at + @as(usize, @intFromEnum(index)) * transform_len;
    return bytes[off..][0..transform_len];
}

const testing = std.testing;

/// Enough of a PL2 to exercise the tail: the front is filler, the tail is real.
fn stubPl2(gpa: std.mem.Allocator) ![]u8 {
    const buf = try gpa.alloc(u8, 443175);
    @memset(buf, 0xAA);

    const shifts = buf.len - shifts_len;
    const colors = shifts - colors_len;

    // Index 6 is black and index 7 the light gold, exactly as a real file has them.
    @memset(buf[colors..shifts], 0);
    buf[colors + 6 * 3 + 0] = 0x00;
    buf[colors + 6 * 3 + 1] = 0x00;
    buf[colors + 6 * 3 + 2] = 0x00;
    buf[colors + 7 * 3 + 0] = 0xd0;
    buf[colors + 7 * 3 + 1] = 0xc2;
    buf[colors + 7 * 3 + 2] = 0x7d;

    @memset(buf[shifts..], 0);
    // A recognisable shift for red: 0 stays 0, everything else lands on 0x2b.
    var i: usize = 1;
    while (i < transform_len) : (i += 1) buf[shifts + 1 * transform_len + i] = 0x2b;
    return buf;
}

test "a text colour comes out of the tail, located from the end of the file" {
    const gpa = testing.allocator;
    const buf = try stubPl2(gpa);
    defer gpa.free(buf);

    try testing.expectEqual([3]u8{ 0xd0, 0xc2, 0x7d }, try textColor(buf, .light_gold));
    try testing.expectEqual([3]u8{ 0, 0, 0 }, try textColor(buf, .black));
}

test "white has no shift table because it means do not shift" {
    const gpa = testing.allocator;
    const buf = try stubPl2(gpa);
    defer gpa.free(buf);

    try testing.expect(try textShift(buf, .white) == null);
}

test "a shift maps index 0 to 0 so holes stay holes" {
    const gpa = testing.allocator;
    const buf = try stubPl2(gpa);
    defer gpa.free(buf);

    const t = (try textShift(buf, .red)).?;
    try testing.expectEqual(@as(usize, transform_len), t.len);
    try testing.expectEqual(@as(u8, 0), t[0]);
    try testing.expectEqual(@as(u8, 0x2b), t[1]);
}

test "a file too short to hold the tail is refused" {
    var tiny: [16]u8 = @splat(0);
    try testing.expectError(Error.ShortPl2, textColor(&tiny, .red));
}

test "the darkened shift is the transform right before the text colours" {
    const gpa = testing.allocator;
    const buf = try stubPl2(gpa);
    defer gpa.free(buf);

    const shifts = buf.len - shifts_len;
    const dark = shifts - colors_len - transform_len;
    // Something recognisable, and 0 left alone the way every transform here leaves it.
    @memset(buf[dark..][0..transform_len], 0x5c);
    buf[dark] = 0;

    const t = try darkShift(buf);
    try testing.expectEqual(@as(usize, transform_len), t.len);
    try testing.expectEqual(@as(u8, 0), t[0]);
    try testing.expectEqual(@as(u8, 0x5c), t[1]);
    try testing.expectEqual(@as(u8, 0x5c), t[255]);

    // And it does not overlap the text colours that follow it.
    const c = try textColor(buf, .black);
    try testing.expectEqual([3]u8{ 0, 0, 0 }, c);
}
