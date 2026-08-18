//! PKWARE Data Compression Library "implode" decoder — the compression an MPQ member uses.
//!
//! An imploded stream is a two-byte header (literals coded or not; log2 of the dictionary size)
//! followed by an LSB-first bit stream of literals and (length, distance) pairs. The three
//! Huffman tables are static and built into the format, so there is nothing to read but the
//! header: `lit_len`, `len_len` and `dist_len` below ARE the format, stored as the compact
//! (repeat-1) << 4 | bits runs the reference decoder uses.

const std = @import("std");

pub const Error = error{ BadHeader, Truncated, BadCode, DistanceTooFar };

const max_bits = 13;

/// Bit lengths of the 256 literal codes, used only when the header says literals are coded.
const lit_len = [_]u8{
    11, 124, 8,   7,   28,  7,   188, 13, 76, 4,  10, 8,  12, 10, 12, 10,
    8,  23,  8,   9,   7,   6,   7,   8,  7,  6,  55, 8,  23, 24, 12, 11,
    7,  9,   11,  12,  6,   7,   22,  5,  7,  24, 6,  11, 9,  6,  7,  22,
    7,  11,  38,  7,   9,   8,   25,  11, 8,  11, 9,  12, 8,  12, 5,  38,
    5,  38,  5,   11,  7,   5,   6,   21, 6,  10, 53, 8,  7,  24, 10, 27,
    44, 253, 253, 253, 252, 252, 252, 13, 12, 45, 12, 45, 12, 61, 12, 45,
    44, 173,
};

/// Bit lengths of the 16 length codes.
const len_len = [_]u8{ 2, 35, 36, 53, 38, 23 };

/// Bit lengths of the 64 distance codes.
const dist_len = [_]u8{ 2, 20, 53, 230, 247, 151, 248 };

/// Base copy length per length code, and how many extra bits follow it. Code 15 with all its
/// extra bits set gives 519, which is the end-of-stream marker.
const len_base = [_]u16{ 3, 2, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24, 40, 72, 136, 264 };
const len_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 };

const Huffman = struct {
    /// How many codes have each bit length, indexed by length.
    count: [max_bits + 1]u16,
    /// Symbols ordered by code length then symbol value — canonical order.
    symbol: [256]u16,
};

/// Expand a compact bit-length run list into a canonical decoding table.
fn construct(comptime rep: []const u8) Huffman {
    @setEvalBranchQuota(20000);
    var lengths: [256]u8 = @splat(0);
    var n: usize = 0;
    for (rep) |b| {
        var left: usize = (b >> 4) + 1;
        while (left > 0) : (left -= 1) {
            lengths[n] = b & 15;
            n += 1;
        }
    }
    var h: Huffman = .{ .count = @splat(0), .symbol = @splat(0) };
    for (lengths[0..n]) |l| h.count[l] += 1;
    var offs: [max_bits + 2]u16 = @splat(0);
    for (1..max_bits + 1) |len| offs[len + 1] = offs[len] + h.count[len];
    for (lengths[0..n], 0..) |l, sym| {
        if (l == 0) continue;
        h.symbol[offs[l]] = @intCast(sym);
        offs[l] += 1;
    }
    return h;
}

const lit_code = construct(&lit_len);
const length_code = construct(&len_len);
const dist_code = construct(&dist_len);

comptime {
    // Each table has to expand to exactly its alphabet; a mistyped run byte would silently
    // shift every symbol after it instead of failing.
    var lit_n = 0;
    for (lit_len) |b| lit_n += (b >> 4) + 1;
    std.debug.assert(lit_n == 256);
    var len_n = 0;
    for (len_len) |b| len_n += (b >> 4) + 1;
    std.debug.assert(len_n == 16);
    var dist_n = 0;
    for (dist_len) |b| dist_n += (b >> 4) + 1;
    std.debug.assert(dist_n == 64);
}

const BitReader = struct {
    src: []const u8,
    pos: usize = 0,
    buf: u32 = 0,
    cnt: u5 = 0,

    fn bits(self: *BitReader, need: u5) Error!u32 {
        if (need == 0) return 0;
        while (self.cnt < need) {
            if (self.pos >= self.src.len) return error.Truncated;
            self.buf |= @as(u32, self.src[self.pos]) << self.cnt;
            self.pos += 1;
            self.cnt += 8;
        }
        const val = self.buf & ((@as(u32, 1) << need) - 1);
        self.buf >>= need;
        self.cnt -= need;
        return val;
    }
};

/// Codes are read one bit at a time, most significant first, and each bit is inverted before it
/// joins the code — that inversion is what makes this table layout decode.
fn decode(br: *BitReader, h: *const Huffman) Error!u16 {
    var code: u32 = 0;
    var first: u32 = 0;
    var index: u32 = 0;
    var len: usize = 1;
    while (len <= max_bits) : (len += 1) {
        code |= (try br.bits(1)) ^ 1;
        const count = h.count[len];
        if (code < first + count) return h.symbol[index + (code - first)];
        index += count;
        first = (first + count) << 1;
        code <<= 1;
    }
    return error.BadCode;
}

/// Decode `src` into `dst`, returning the number of bytes written. Stops at the end-of-stream
/// code or when `dst` is full, whichever comes first — an MPQ sector always knows its own
/// unpacked size, and some members are cut short of the end code.
pub fn explode(dst: []u8, src: []const u8) Error!usize {
    var br: BitReader = .{ .src = src };
    const coded_literals = try br.bits(8);
    if (coded_literals > 1) return error.BadHeader;
    const dict: u5 = @intCast(try br.bits(8));
    if (dict < 4 or dict > 6) return error.BadHeader;

    var n: usize = 0;
    while (n < dst.len) {
        if (try br.bits(1) != 0) {
            const sym = try decode(&br, &length_code);
            const len: u32 = @as(u32, len_base[sym]) + try br.bits(len_extra[sym]);
            if (len == 519) break;
            // A two-byte match always carries two distance bits; everything longer carries as
            // many as the dictionary is wide.
            const dbits: u5 = if (len == 2) 2 else dict;
            var dist: usize = @as(usize, try decode(&br, &dist_code)) << dbits;
            dist += try br.bits(dbits);
            dist += 1;
            if (dist > n) return error.DistanceTooFar;
            var copy = @min(@as(usize, len), dst.len - n);
            while (copy > 0) : (copy -= 1) {
                dst[n] = dst[n - dist];
                n += 1;
            }
        } else {
            const byte = if (coded_literals != 0) try decode(&br, &lit_code) else @as(u16, @intCast(try br.bits(8)));
            dst[n] = @intCast(byte);
            n += 1;
        }
    }
    return n;
}

const testing = std.testing;

test "explode: uncoded literals and a back reference" {
    // The reference stream from Mark Adler's blast: uncoded literals, 1024-byte dictionary,
    // 'A', 'I', then an 11-byte copy from two back.
    const src = [_]u8{ 0x00, 0x04, 0x82, 0x24, 0x25, 0x8f, 0x80, 0x7f };
    var dst: [13]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), try explode(&dst, &src));
    try testing.expectEqualStrings("AIAIAIAIAIAIA", &dst);
}

/// Emit an imploded stream that codes every byte of `data` as an uncoded literal. Valid PKWARE,
/// just the worst possible ratio — enough to drive the literal path over arbitrary bytes.
fn implodeLiterals(out: []u8, data: []const u8) []u8 {
    out[0] = 0; // literals not coded
    out[1] = 4; // 1024-byte dictionary
    var bit: usize = 0;
    const put = struct {
        fn f(buf: []u8, at: *usize, value: u32, n: u5) void {
            for (0..n) |i| {
                const b: u1 = @truncate(value >> @intCast(i));
                if (b != 0) buf[2 + at.* / 8] |= @as(u8, 1) << @intCast(at.* % 8);
                at.* += 1;
            }
        }
    }.f;
    @memset(out[2..], 0);
    for (data) |c| {
        put(out, &bit, 0, 1);
        put(out, &bit, c, 8);
    }
    // The end code: length symbol 15 is seven clear bits, and 264 + 255 extra is 519.
    put(out, &bit, 1, 1);
    put(out, &bit, 0, 7);
    put(out, &bit, 0xFF, 8);
    return out[0 .. 2 + (bit + 7) / 8];
}

test "explode: every literal byte round-trips" {
    const text = "Hello, Diablo II!";
    var packed_buf: [256]u8 = undefined;
    const src = implodeLiterals(&packed_buf, text);
    var dst: [text.len]u8 = undefined;
    try testing.expectEqual(@as(usize, text.len), try explode(&dst, src));
    try testing.expectEqualStrings(text, &dst);
}

test "explode: the end code stops short of a full destination" {
    const text = "abc";
    var packed_buf: [64]u8 = undefined;
    const src = implodeLiterals(&packed_buf, text);
    var dst: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try explode(&dst, src));
    try testing.expectEqualStrings("abc", dst[0..3]);
}

test "explode: rejects a header it cannot be" {
    var dst: [4]u8 = undefined;
    try testing.expectError(error.BadHeader, explode(&dst, &[_]u8{ 0x02, 0x04, 0x00 }));
    try testing.expectError(error.BadHeader, explode(&dst, &[_]u8{ 0x00, 0x07, 0x00 }));
    try testing.expectError(error.Truncated, explode(&dst, &[_]u8{0x00}));
}

test "static tables decode to their documented alphabets" {
    // Canonical order: the first symbol of each length, and the total per length.
    try testing.expectEqualSlices(u16, &.{ 0, 0, 1, 3, 3, 4, 3, 2, 0, 0, 0, 0, 0, 0 }, &length_code.count);
    const in_order = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try testing.expectEqualSlices(u16, &in_order, length_code.symbol[0..16]);
    try testing.expectEqualSlices(u16, &.{ 0, 0, 1, 0, 2, 4, 15, 26, 16, 0, 0, 0, 0, 0 }, &dist_code.count);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, dist_code.symbol[0..8]);
    try testing.expectEqualSlices(u16, &.{ 0, 0, 0, 0, 1, 11, 20, 21, 16, 7, 5, 10, 91, 74 }, &lit_code.count);
    // The shortest literal codes go to space and the commonest English letters, which is the
    // giveaway that this table was fitted to text.
    const shortest = [_]u16{ 32, 69, 97, 101, 105, 108, 110, 111, 114, 115, 116, 117 };
    try testing.expectEqualSlices(u16, &shortest, lit_code.symbol[0..12]);
}
