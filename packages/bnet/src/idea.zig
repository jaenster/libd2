//! IDEA, the block cipher Blizzard wrapped the stored CD key in.
//!
//! Stock IDEA — 64-bit block, 128-bit key, eight rounds and an output transform — with one
//! deviation that matters and will silently produce garbage if missed: **every 16-bit word is
//! read and written little-endian**, both the data and the key. The published cipher is
//! big-endian, so the usual test vectors do not apply and are not used here; the round trip
//! against the real schedule is the test instead.
//!
//! Reversed from Bnclient 1.09b: the block function @0x6ff0b320, the key schedule @0x6ff0b5c0
//! and the decryption-subkey inversion @0x6ff0ae30, all reached from `D2BNClient/grid.cpp`.
//! Nothing here is Diablo-specific; `keystore` is what makes it a key store.

const std = @import("std");

/// Eight rounds of six subkeys, plus four for the output transform.
pub const Subkeys = [52]u16;

/// Multiplication modulo 2^16+1, where a stored zero means 2^16. The three-way shape below is
/// exactly what the disassembly does, and it is worth keeping literal: the identity
/// `0 -> 65536` is the whole reason IDEA has no weak zero key.
fn mul(a: u16, b: u16) u16 {
    if (a == 0) return @truncate(1 -% @as(u32, b));
    if (b == 0) return @truncate(1 -% @as(u32, a));
    const p: u32 = @as(u32, a) * @as(u32, b);
    const lo: u32 = p & 0xFFFF;
    const hi: u32 = p >> 16;
    return @truncate(lo -% hi +% @intFromBool(lo < hi));
}

fn add(a: u16, b: u16) u16 {
    return a +% b;
}

/// The multiplicative inverse mod 2^16+1, by the extended Euclid the binary spells out inline.
fn mulInv(x: u16) u16 {
    if (x <= 1) return x;
    var t1: u32 = 0x10001 / @as(u32, x);
    var y: u32 = 0x10001 % @as(u32, x);
    if (y == 1) return @truncate(1 -% t1);
    var t0: u32 = 1;
    var v: u32 = x;
    while (y != 1) {
        const q = v / y;
        v %= y;
        t0 +%= q * t1;
        if (v == 1) return @truncate(t0);
        const q2 = y / v;
        y %= v;
        t1 +%= q2 * t0;
    }
    return @truncate(1 -% t1);
}

fn addInv(x: u16) u16 {
    return 0 -% x;
}

/// The 25-bit rotation schedule: the first eight subkeys are the key itself, and each later
/// group of eight is the previous group rotated left 25 bits.
///
/// The indices are worth being careful about. Both sources come from the base of the PREVIOUS
/// group of eight, wrapping within it — not from a window sliding one place per subkey. Getting
/// that wrong still produces a schedule that decrypts whatever it encrypted, so a round trip
/// against itself proves nothing here; it took the real Bnclient refusing a blob to catch it.
pub fn encryptSchedule(key: [16]u8) Subkeys {
    var k: Subkeys = undefined;
    for (0..8) |i| k[i] = std.mem.readInt(u16, key[i * 2 ..][0..2], .little);
    for (8..52) |i| {
        const base = (i / 8 - 1) * 8;
        const a = k[base + ((i + 1) % 8)];
        const b = k[base + ((i + 2) % 8)];
        k[i] = (a << 9) | (b >> 7);
    }
    return k;
}

/// The decryption subkeys: the encryption ones inverted and reversed. The two additive inverses
/// of a middle round come out swapped relative to the round's own order — that transposition is
/// the classic place to get IDEA wrong, so it is spelled out rather than looped over blindly.
pub fn decryptSchedule(key: [16]u8) Subkeys {
    const e = encryptSchedule(key);
    var d: Subkeys = undefined;
    var p: usize = 0;
    var q: usize = 52;

    d[p] = mulInv(e[q - 4]);
    d[p + 1] = addInv(e[q - 3]);
    d[p + 2] = addInv(e[q - 2]);
    d[p + 3] = mulInv(e[q - 1]);
    p += 4;
    q -= 4;

    for (0..7) |_| {
        d[p] = e[q - 2];
        d[p + 1] = e[q - 1];
        p += 2;
        q -= 2;
        d[p] = mulInv(e[q - 4]);
        d[p + 1] = addInv(e[q - 2]); // swapped with the next, on purpose
        d[p + 2] = addInv(e[q - 3]);
        d[p + 3] = mulInv(e[q - 1]);
        p += 4;
        q -= 4;
    }

    d[p] = e[q - 2];
    d[p + 1] = e[q - 1];
    p += 2;
    q -= 2;
    d[p] = mulInv(e[q - 4]);
    d[p + 1] = addInv(e[q - 3]);
    d[p + 2] = addInv(e[q - 2]);
    d[p + 3] = mulInv(e[q - 1]);
    return d;
}

/// One 64-bit block. Which direction this runs is decided entirely by which schedule is handed
/// in — the transform itself is the same either way, which is why IDEA needs no separate
/// decrypt routine.
pub fn block(k: Subkeys, in: [8]u8) [8]u8 {
    var x0 = std.mem.readInt(u16, in[0..2], .little);
    var x1 = std.mem.readInt(u16, in[2..4], .little);
    var x2 = std.mem.readInt(u16, in[4..6], .little);
    var x3 = std.mem.readInt(u16, in[6..8], .little);

    var at: usize = 0;
    for (0..8) |_| {
        x0 = mul(x0, k[at]);
        x1 = add(x1, k[at + 1]);
        x2 = add(x2, k[at + 2]);
        x3 = mul(x3, k[at + 3]);
        const t0 = mul(x0 ^ x2, k[at + 4]);
        const t1 = mul(add(t0, x1 ^ x3), k[at + 5]);
        const t2 = add(t0, t1);
        at += 6;

        x0 ^= t1;
        x3 ^= t2;
        const swap = x1 ^ t2;
        x1 = x2 ^ t1;
        x2 = swap;
    }

    // The output transform undoes the last round's swap of the middle two words.
    var out: [8]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], mul(x0, k[48]), .little);
    std.mem.writeInt(u16, out[2..4], add(x2, k[49]), .little);
    std.mem.writeInt(u16, out[4..6], add(x1, k[50]), .little);
    std.mem.writeInt(u16, out[6..8], mul(x3, k[51]), .little);
    return out;
}

// ── tests ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "multiplication treats a stored zero as 2^16" {
    // 0 stands for 65536, so 0 * 0 = 65536*65536 mod 65537 = 1.
    try testing.expectEqual(@as(u16, 1), mul(0, 0));
    // 65536 * x = -x mod 65537.
    try testing.expectEqual(@as(u16, 0x10001 - 5), mul(0, 5));
    try testing.expectEqual(@as(u16, 7), mul(1, 7));
}

test "every value has a multiplicative inverse" {
    var x: u32 = 0;
    while (x <= 0xFFFF) : (x += 1) {
        const a: u16 = @truncate(x);
        try testing.expectEqual(@as(u16, 1), mul(a, mulInv(a)));
    }
}

test "the schedule keeps the key in its first eight subkeys, little-endian" {
    var key: [16]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    const k = encryptSchedule(key);
    try testing.expectEqual(@as(u16, 0x0100), k[0]);
    try testing.expectEqual(@as(u16, 0x0302), k[1]);
    try testing.expectEqual(@as(u16, 0x0F0E), k[7]);
    // The ninth is built from the second and third by the 25-bit rotation.
    try testing.expectEqual(@as(u16, (k[1] << 9) | (k[2] >> 7)), k[8]);
}

test "decrypting undoes encrypting" {
    var key: [16]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
    const enc = encryptSchedule(key);
    const dec = decryptSchedule(key);

    var data: [8]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x23, 0x45, 0x67 };
    const cipher = block(enc, data);
    try testing.expect(!std.mem.eql(u8, &data, &cipher));
    try testing.expectEqualSlices(u8, &data, &block(dec, cipher));

    // And for a key with zero words, which is where the 0 -> 2^16 rule earns its place.
    const zero = encryptSchedule([_]u8{0} ** 16);
    const zero_d = decryptSchedule([_]u8{0} ** 16);
    data = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expectEqualSlices(u8, &data, &block(zero_d, block(zero, data)));
}
