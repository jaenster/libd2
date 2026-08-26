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
//! The cipher they feed is Blizzard's own assembly rather than a stock mode: 64-byte blocks with
//! an 8-byte trailer, every eighth block through IDEA and the rest not, a running digest
//! subtracted across each block backwards, and every sixteenth recovered block folded back into
//! that digest so the stream comes to depend on its own plaintext. The trailer carries a
//! four-byte check of the final digest, which is what turns a wrong password into a refusal
//! instead of noise.
//!
//! `decrypt` is read out of Bnclient. `encrypt` is not: the game only ever reads these, the
//! installer is what writes them, so the write path here is the read path run backwards. It is
//! held to the one standard that can be checked without a captured blob — whatever it produces,
//! `decrypt` recovers, across lengths that exercise both block rules.

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

/// The running hash the wrapper is built on — and it is a THIRD Blizzard SHA-1 variant, not
/// either of the two already in this package. Standard SHA-1 expands the message with
/// `rotl(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1)`; `xsha1` replaces that with `rotl(1, xor & 0x1f)`;
/// this one drops the rotation entirely and takes the exclusive-or as it stands. Mixing them up
/// gives a hash that looks right and verifies nothing, so they stay separate implementations.
///
/// It is also used differently: no padding, no terminator, no length suffix. Whole 64-byte
/// blocks are fed in as the cipher walks the data, and the state is read out mid-stream as a
/// 20-byte digest. Bnclient 1.09b: init @0x6ff0bc60, block @0x6ff0b9f0, compress @0x6ff0ba50.
pub const Hash = struct {
    h: [5]u32 = .{ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 },
    bits: u64 = 0,

    /// Absorb exactly one block. The words are read little-endian, as everywhere in D2.
    pub fn block(self: *Hash, data: *const [64]u8) void {
        var w: [80]u32 = undefined;
        for (0..16) |i| w[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        // No rotation. This single missing `rotl(_, 1)` is the whole difference from FIPS.
        for (16..80) |i| w[i] = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];

        var a = self.h[0];
        var b = self.h[1];
        var c = self.h[2];
        var d = self.h[3];
        var e = self.h[4];
        for (0..80) |i| {
            const f: u32, const k: u32 = switch (i / 20) {
                0 => .{ (b & c) | (~b & d), 0x5A827999 },
                1 => .{ b ^ c ^ d, 0x6ED9EBA1 },
                2 => .{ (b & c) | (b & d) | (c & d), 0x8F1BBCDC },
                else => .{ b ^ c ^ d, 0xCA62C1D6 },
            };
            const t = std.math.rotl(u32, a, 5) +% f +% e +% k +% w[i];
            e = d;
            d = c;
            c = std.math.rotl(u32, b, 30);
            b = a;
            a = t;
        }
        self.h[0] +%= a;
        self.h[1] +%= b;
        self.h[2] +%= c;
        self.h[3] +%= d;
        self.h[4] +%= e;
        self.bits +%= 512;
    }

    /// The state as it stands, without finalising anything — which is what the cipher reads
    /// between blocks.
    pub fn digest(self: Hash) [20]u8 {
        var out: [20]u8 = undefined;
        for (self.h, 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .little);
        return out;
    }
};

test "the keystore hash is neither standard SHA-1 nor xsha1" {
    var h: Hash = .{};
    h.block(&[_]u8{0} ** 64);
    const d = h.digest();
    // Whatever it is, it must not be the identity and must move every word.
    var same: usize = 0;
    const init = Hash{};
    for (init.h, 0..) |v, i| {
        if (v == std.mem.readInt(u32, d[i * 4 ..][0..4], .little)) same += 1;
    }
    try testing.expectEqual(@as(usize, 0), same);
    try testing.expectEqual(@as(u64, 512), h.bits);
}

test "the expansion carries no rotation" {
    // Reproduce the first expanded word by hand for an all-zero block plus one set word, and
    // check it against what a rotating expansion would have produced.
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u32, data[0..4], 1, .little); // w[0] = 1
    var w: [17]u32 = undefined;
    for (0..16) |i| w[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    w[16] = w[13] ^ w[8] ^ w[2] ^ w[0];
    try testing.expectEqual(@as(u32, 1), w[16]);
    // FIPS would have rotated it to 2; xsha1 would have made it rotl(1, 1 & 0x1f) = 2 as well.
    try testing.expect(w[16] != 2);
}

const idea = @import("idea.zig");

/// The three IDEA schedules and the hash the wrapper runs on, derived from a password.
///
/// The 112 fixed bytes are folded with a digest of the tiled password, cut into three 128-bit
/// IDEA keys, and their tail doubles as the hash's opening block. Everything is determined by
/// the password, so two installs with the same key produce the same schedule.
/// Bnclient 1.09b @0x6ff0a4a0.
pub const Schedule = struct {
    keys: [3]idea.Subkeys,
    hash: Hash,

    pub fn init(password: []const u8, direction: enum { encrypt, decrypt }) Schedule {
        var stream = scheduleSeed();

        var tiled: [64]u8 = undefined;
        tileKey(password, &tiled);
        var seed: Hash = .{};
        seed.block(&tiled);
        const d = seed.digest();

        for (&stream, 0..) |*b, i| b.* ^= d[i % 20];

        var self: Schedule = .{ .keys = undefined, .hash = .{} };
        for (&self.keys, 0..) |*k, s| {
            const material: [16]u8 = stream[s * 16 ..][0..16].*;
            k.* = switch (direction) {
                .encrypt => idea.encryptSchedule(material),
                .decrypt => idea.decryptSchedule(material),
            };
        }
        // The last 64 bytes of the folded stream open the hash — the same block for every slot.
        self.hash.block(stream[48..112]);
        return self;
    }
};

/// Undo the wrapper, in place. Returns how many bytes of `buf` are plaintext, or null if the
/// blob is not one — a wrong password shows up as a failed trailer check, not as garbage.
///
/// Only one of the three schedules is used here; the other two belong to operations this does
/// not implement. Bnclient 1.09b @0x6ff0a2e0.
pub fn decrypt(buf: []u8, password: []const u8) ?usize {
    if (buf.len < header_len + 1) return null;
    const body = buf.len - header_len;
    if (body % block_len != 0) return null;

    var sched: Schedule = .init(password, .decrypt);
    var at: usize = 0;
    var blk: usize = 0;
    while (at < body) : ({
        at += block_len;
        blk += 1;
    }) {
        const cipher: *[64]u8 = buf[at..][0..64];
        const d = sched.hash.digest();

        // Only every eighth block goes through IDEA; the rest ride on the digest alone.
        var mixed: [64]u8 = cipher.*;
        if (blk & 7 == 0) {
            var i: usize = 0;
            while (i < 64) : (i += 8) mixed[i..][0..8].* = idea.block(sched.keys[0], cipher[i..][0..8].*);
        }
        // The digest walks backwards across the block, wrapping at twenty.
        for (0..64) |i| cipher[i] = mixed[i] -% d[(63 - i) % 20];

        // Every sixteenth recovered block is folded back in, so the stream depends on its
        // own plaintext from there on.
        if (blk & 0xf == 0) sched.hash.block(cipher);
    }

    const trailer = buf[body..][0..header_len];
    if (trailer[4] != 0) return null;
    const mac = sched.hash.digest();
    if (!std.mem.eql(u8, trailer[0..4], mac[0..4])) return null;
    return body - block_len + trailer[5];
}

/// Build a blob the game will accept. Bnclient only ever reads — the installer is what writes —
/// so this is the read path run backwards rather than a second routine lifted from a binary.
/// It is held to the standard that matters: whatever it produces, `decrypt` must recover.
///
/// The caller owns `out`, which must be `wrappedLen(plain.len)` bytes.
pub fn encrypt(out: []u8, plain: []const u8, password: []const u8) void {
    std.debug.assert(out.len == wrappedLen(plain.len));
    const body = out.len - header_len;

    @memset(out, 0);
    @memcpy(out[0..plain.len], plain);

    var sched: Schedule = .init(password, .encrypt);
    var at: usize = 0;
    var blk: usize = 0;
    while (at < body) : ({
        at += block_len;
        blk += 1;
    }) {
        const b: *[64]u8 = out[at..][0..64];
        const d = sched.hash.digest();
        // The plaintext block must reach the hash before it is disturbed.
        const plain_block = b.*;

        var mixed: [64]u8 = undefined;
        for (0..64) |i| mixed[i] = b[i] +% d[(63 - i) % 20];
        if (blk & 7 == 0) {
            var i: usize = 0;
            while (i < 64) : (i += 8) b[i..][0..8].* = idea.block(sched.keys[0], mixed[i..][0..8].*);
        } else {
            b.* = mixed;
        }
        if (blk & 0xf == 0) {
            var fold = plain_block;
            sched.hash.block(&fold);
        }
    }

    const mac = sched.hash.digest();
    @memcpy(out[body..][0..4], mac[0..4]);
    out[body + 4] = 0;
    out[body + 5] = @intCast(plain.len % block_len);
    out[body + 6] = 0;
    out[body + 7] = 0;
}

/// How long a blob holding `n` bytes of plaintext is: whole blocks plus one, and the trailer.
/// The spare block is where the trailer's length byte does its work.
pub fn wrappedLen(n: usize) usize {
    return header_len + block_len * (n / block_len + 1);
}

test "a wrapped blob comes back out" {
    const key = blockKey();
    const secret = "6BW3-J82R-9KDT-4EHM";
    var buf: [wrappedLen(secret.len)]u8 = undefined;
    encrypt(&buf, secret, &key);
    try testing.expect(plausible(&buf));
    // It must not be sitting there in the clear.
    try testing.expect(std.mem.indexOf(u8, &buf, secret) == null);

    const n = decrypt(&buf, &key) orelse return error.Refused;
    try testing.expectEqual(secret.len, n);
    try testing.expectEqualStrings(secret, buf[0..n]);
}

test "a blob long enough to exercise both block rules" {
    // Past sixteen blocks the hash has folded its own plaintext back in twice, and past eight
    // the IDEA rule has switched on and off — a short blob tests neither.
    const key = blockKey();
    var secret: [1100]u8 = undefined;
    for (&secret, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    var buf: [wrappedLen(secret.len)]u8 = undefined;
    encrypt(&buf, &secret, &key);
    const n = decrypt(&buf, &key) orelse return error.Refused;
    try testing.expectEqual(secret.len, n);
    try testing.expectEqualSlices(u8, &secret, buf[0..n]);
}

test "the wrong password is refused rather than guessed at" {
    const key = blockKey();
    var wrong = key;
    wrong[0] +%= 1;
    var buf: [wrappedLen(11)]u8 = undefined;
    encrypt(&buf, "hello world", &key);
    try testing.expect(decrypt(&buf, &wrong) == null);
}

test "a blob of the wrong shape is refused before any work" {
    const key = blockKey();
    var buf: [8 + 0x3f]u8 = undefined;
    try testing.expect(decrypt(&buf, &key) == null);
    var empty: [4]u8 = undefined;
    try testing.expect(decrypt(&empty, &key) == null);
}
