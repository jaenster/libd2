//! Where Diablo II keeps the CD key on disk, and the fixed material that wraps it.
//!
//! Not the registry. The key is a member of a game MPQ wearing the name of an ordinary asset, so
//! a directory listing shows nothing and a casual look inside the archive shows a cursor sound.
//! The installer says so itself, in `InstallerFileList.xml`:
//!
//!     <encrypt object="cdkey26" into="data\global\sfx\cursor\wavindx.wav"    product_id="24" />
//!     <encrypt object="cdkey26" into="data\global\chars\am\cof\amblxbow.cof" product_id="25" />
//!     <encrypt object="user"    into="data\global\sfx\cursor\curindx.wav" />
//!
//! The code that reads them back is `Diablo2\Source\D2BNClient\grid.cpp` — an equally innocuous
//! name — with globals `sgpCDKey` and `sgpOwner`, still legible in the 1.09b `Bnclient.dll`
//! assert `!sgpCDKey && !sgpOwner`. Addresses below are from that build, image base 0x6ff00000.
//!
//! Two pieces of key material are generated rather than stored, and both come from the C runtime
//! random number generator seeded with a constant — so they are identical on every install that
//! has ever existed, and are compiled in here rather than derived at runtime.
//!
//! What is NOT here yet is the cipher those feed. It is Blizzard's own construction, not a
//! stock one: an 8-byte header then 64-byte blocks, a 20-byte SHA-1 digest subtracted cyclically
//! across each block, and an 8-byte block function applied eight bytes at a time. Until that is
//! ported, this module can find and describe a key blob but not read one.

const std = @import("std");

/// The C runtime generator, reproduced because the values it produced are part of the format.
/// Microsoft's: a 32-bit LCG whose output is bits 16..30 of the state.
pub const Rand = struct {
    state: u32,

    pub fn seeded(seed: u32) Rand {
        return .{ .state = seed };
    }

    pub fn next(self: *Rand) u16 {
        self.state = self.state *% 214013 +% 2531011;
        return @truncate((self.state >> 16) & 0x7FFF);
    }

    /// The low byte, which is all either caller keeps.
    pub fn nextByte(self: *Rand) u8 {
        return @truncate(self.next());
    }
};

/// The 19 bytes handed to the cipher as its key, from `srand(0x150B)`. A zero result is thrown
/// away and drawn again rather than stored, so the key never contains a NUL — which matters,
/// because the schedule below treats the key as a C string.
///
/// Bnclient 1.09b @0x6ff0ac44. The game restores the generator with `srand(time(NULL))`
/// immediately afterwards, so nothing downstream sees the fixed seed.
pub fn blockKey() [19]u8 {
    var r: Rand = .seeded(0x150B);
    var out: [19]u8 = undefined;
    var n: usize = 0;
    while (n < out.len) {
        const b = r.nextByte();
        if (b != 0) {
            out[n] = b;
            n += 1;
        }
    }
    return out;
}

/// The 112 bytes the key schedule starts from, from `srand(0x4FA7)`. No values are skipped here,
/// so this one is a straight 112 draws. Bnclient 1.09b @0x6ff0a4cd.
pub fn scheduleSeed() [112]u8 {
    var r: Rand = .seeded(0x4FA7);
    var out: [112]u8 = undefined;
    for (&out) |*b| b.* = r.nextByte();
    return out;
}

/// The schedule tiles the key across 64 bytes, restarting at the first NUL rather than at the
/// end — so a key shorter than it looks repeats early. Bnclient 1.09b @0x6ff0a502.
pub fn tileKey(key: []const u8, out: *[64]u8) void {
    var at: usize = 0;
    for (out) |*b| {
        if (at >= key.len or key[at] == 0) at = 0;
        b.* = key[at];
        at += 1;
    }
}

/// Which key a blob holds, and the identifier Battle.net knows it by.
pub const Product = enum(u8) {
    classic = 24,
    expansion = 25,

    /// The member name the key hides under. Backslashes: these are MPQ paths, not host paths.
    pub fn member(self: Product) []const u8 {
        return switch (self) {
            .classic => "data\\global\\sfx\\cursor\\wavindx.wav",
            .expansion => "data\\global\\chars\\am\\cof\\amblxbow.cof",
        };
    }
};

/// The owner name is stored the same way, under its own alias, and belongs to no product.
pub const owner_member = "data\\global\\sfx\\cursor\\curindx.wav";

/// Archives to look in, highest priority first. This is the order Bnclient 1.09b carries as
/// literals; `d2char.mpq` is where the expansion key goes and is searched for it alone.
///
/// The container is not stable across releases — a 2001 install put the classic key in
/// `d2sfx.mpq`, while the 1.14b installer writes it to `d2data.mpq` — so a reader has to try all
/// of them rather than assume one.
pub const search_order = [_][]const u8{
    "patch_d2.mpq",
    "d2exp.mpq",
    "d2data.mpq",
    "d2sfx.mpq",
    "d2char.mpq",
};

/// A blob is refused outright unless it is a header plus whole blocks, which makes a cheap test
/// for "is this member a key at all" before any decryption is attempted. Bnclient 1.09b
/// @0x6ff0a33f and @0x6ff0a355.
pub const header_len = 8;
pub const block_len = 0x40;

pub fn plausible(blob: []const u8) bool {
    return blob.len > header_len and (blob.len - header_len) % block_len == 0;
}

// ── tests ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the block key is the same on every install" {
    const want = [19]u8{
        0xde, 0x88, 0x2a, 0x14, 0xdb, 0x23, 0xe3, 0x8f, 0xb3, 0xfb,
        0x7b, 0xa4, 0x22, 0xeb, 0x34, 0x18, 0x22, 0x15, 0x7a,
    };
    try testing.expectEqualSlices(u8, &want, &blockKey());
    // The skip is what guarantees this, and the schedule relies on it.
    for (blockKey()) |b| try testing.expect(b != 0);
}

test "the schedule seed is 112 unfiltered draws" {
    const s = scheduleSeed();
    try testing.expectEqualSlices(u8, &.{ 0x43, 0xea, 0x16, 0xdb, 0x9e, 0x52, 0xb2, 0xcf }, s[0..8]);
    try testing.expectEqualSlices(u8, &.{ 0x75, 0x5d, 0x20, 0x13, 0x71, 0xe3, 0x5c, 0x39 }, s[104..112]);
}

test "tiling restarts at a NUL, not at the end" {
    var out: [64]u8 = undefined;
    tileKey("abc", &out);
    try testing.expectEqualStrings("abcabcab", out[0..8]);
    // A key carrying a NUL is shorter than its length claims.
    tileKey("ab\x00zzzz", &out);
    try testing.expectEqualStrings("ababab", out[0..6]);
}

test "a blob is a header plus whole blocks" {
    try testing.expect(plausible(&[_]u8{0} ** (8 + 0x40)));
    try testing.expect(plausible(&[_]u8{0} ** (8 + 0x80)));
    try testing.expect(!plausible(&[_]u8{0} ** 8));
    try testing.expect(!plausible(&[_]u8{0} ** (8 + 0x3f)));
}

test "products name the members the installer writes" {
    try testing.expectEqual(@as(u8, 24), @intFromEnum(Product.classic));
    try testing.expectEqual(@as(u8, 25), @intFromEnum(Product.expansion));
    try testing.expect(std.mem.endsWith(u8, Product.classic.member(), "wavindx.wav"));
    try testing.expect(std.mem.endsWith(u8, Product.expansion.member(), "amblxbow.cof"));
}
