//! DRLG seed RNG — mechanical transform of the reconstructed 1.14d closure.
//!
//! Faithful to recon/closure/Archive.cpp and the macro in
//! ghidra-reconstruct/output/d2_platform.h:380
//!     #define D2_SEED_NEXT(seed) ((D2SeedStrc)((uint64_t)(uint32_t)(seed).nSeedLow \
//!                                  * 0x6ac690c5u + (uint64_t)(uint32_t)(seed).nSeedHigh))
//! i.e. the 64-bit LCG state advance:  state64 = low*0x6ac690c5 + high,
//! then the D2SeedStrc is reinterpreted from that u64 (low = bits 0..31,
//! high = bits 32..63).
//!
//! Transformed functions (cite recon Archive.cpp):
//!   RollRandomSeed                (1.14d 0045c370)  Archive.cpp:528
//!   UNIT_GetModuloFromSeed        (1.14d 0045c390)  Archive.cpp:536
//!   RANDOM_RandomNumberSelector   (1.14d 0045c3e0)  Archive.cpp:556
//!
//! CROSS-CHECK: this MUST produce identical results to the repo's verified
//! src/rng.zig. The test at the bottom proves it over a wide seed/modulo grid.

const structs = @import("structs.zig");
const D2SeedStrc = structs.D2SeedStrc;

/// The LCG multiplier (d2_platform.h: 0x6ac690c5u).
const MUL: u64 = 0x6ac690c5;

/// The raw 64-bit LCG state of a seed: high << 32 | low (the value a
/// `(uint64_t)DVar1` reinterpret of a D2SeedStrc yields).
inline fn toU64(seed: D2SeedStrc) u64 {
    const lo: u64 = @as(u32, @bitCast(seed.nSeedLow));
    const hi: u64 = @as(u32, @bitCast(seed.nSeedHigh));
    return (hi << 32) | lo;
}

/// Reinterpret a 64-bit value back into a D2SeedStrc (low = low word).
inline fn fromU64(v: u64) D2SeedStrc {
    return .{
        .nSeedLow = @bitCast(@as(u32, @truncate(v))),
        .nSeedHigh = @bitCast(@as(u32, @truncate(v >> 32))),
    };
}

/// D2_SEED_NEXT(seed): state64 = low*0x6ac690c5 + high, reinterpreted as a seed.
/// (d2_platform.h:380)
pub inline fn sEEDNEXT(seed: D2SeedStrc) D2SeedStrc {
    const lo: u64 = @as(u32, @bitCast(seed.nSeedLow));
    const hi: u64 = @as(u32, @bitCast(seed.nSeedHigh));
    return fromU64(lo *% MUL +% hi);
}

/// RollRandomSeed (Archive.cpp:528 / 0045c370):
///   DVar1 = D2_SEED_NEXT(*pSeed); *pSeed = DVar1; return DVar1.nSeedLow;
pub fn RollRandomSeed(pSeed: *D2SeedStrc) i32 {
    const next = sEEDNEXT(pSeed.*);
    pSeed.* = next;
    return next.nSeedLow;
}

/// RANDOM_RandomNumberSelector (Archive.cpp:556 / 0045c3e0): uniform in [0,nModulo).
///   if ((int)nModulo < 1) return 0;
///   if (nModulo & nModulo-1) { advance; return (newSeedLow % nModulo); } // not pow2
///   advance; return (nModulo-1) & DVar1.nSeedLow;                        // pow2: mask
/// The engine modulos the LOW WORD, not the full 64-bit state: at 0045c40b-0d it
/// runs `XOR EDX,EDX; DIV ESI` on EDX:EAX = 0:newSeedLow (verified disasm). The
/// prior full64 form was a decompiler artifact; it broke Act-III shrine/file-
/// tracker draws (non-pow2 moduli with newSeedHigh != 0).
pub fn randomNumberSelector(pSeed: *D2SeedStrc, nModulo: u32) u32 {
    if (@as(i32, @bitCast(nModulo)) < 1) return 0;
    const next = sEEDNEXT(pSeed.*);
    pSeed.* = next;
    if (nModulo & (nModulo -% 1) != 0) {
        return @as(u32, @bitCast(next.nSeedLow)) % nModulo;
    }
    return (nModulo -% 1) & @as(u32, @bitCast(next.nSeedLow));
}

/// UNIT_GetModuloFromSeed (Archive.cpp:536 / 0045c390): identical result to
/// RANDOM_RandomNumberSelector; kept as a faithful separate entry point. The
/// recon hoists `low*0x6ac690c5` before the pow2 branch but the math is the same.
pub fn getModuloFromSeed(pSeed: *D2SeedStrc, nModulo: u32) u32 {
    if (@as(i32, @bitCast(nModulo)) < 1) return 0;
    const lo: u64 = @as(u32, @bitCast(pSeed.nSeedLow));
    const hi: u64 = @as(u32, @bitCast(pSeed.nSeedHigh));
    const next = fromU64(lo *% MUL +% hi);
    pSeed.* = next;
    if (nModulo & (nModulo -% 1) != 0) {
        return @as(u32, @bitCast(next.nSeedLow)) % nModulo;
    }
    return (nModulo -% 1) & @as(u32, @bitCast(next.nSeedLow));
}

// CROSS-CHECK vs the repo's VERIFIED seed RNG (src/rng.zig).
// If this primitive is wrong, the whole DRLG transform is wrong — so prove it.
const std = @import("std");
const ref = @import("../rng.zig");

fn refSeed(s: D2SeedStrc) ref.Seed {
    return .{ .low = @bitCast(s.nSeedLow), .high = @bitCast(s.nSeedHigh) };
}

test "randomNumberSelector matches src/rng.zig pick over a seed/modulo grid" {
    const lows = [_]u32{ 0, 1, 2, 7, 12345, 0x29a, 0xdeadbeef, 0xffffffff, 0x80000000, 0x6ac690c5 };
    const highs = [_]u32{ 0, 0x29a, 1, 666, 0xffffffff, 0x12345678 };
    // pow2 moduli, non-pow2 moduli, plus the signed-<1 cases (0, top-bit set).
    const mods = [_]u32{ 0, 1, 2, 3, 4, 5, 8, 16, 100, 1000, 1024, 0x10000, 7, 13, 0x80000000, 0xffffffff };

    var count: usize = 0;
    for (lows) |lo| {
        for (highs) |hi| {
            for (mods) |m| {
                var a = D2SeedStrc{ .nSeedLow = @bitCast(lo), .nSeedHigh = @bitCast(hi) };
                var b = refSeed(.{ .nSeedLow = @bitCast(lo), .nSeedHigh = @bitCast(hi) });
                const ra = randomNumberSelector(&a, m);
                const rb = b.pick(m);
                try std.testing.expectEqual(rb, ra);
                // state must advance identically too
                try std.testing.expectEqual(b.low, @as(u32, @bitCast(a.nSeedLow)));
                try std.testing.expectEqual(b.high, @as(u32, @bitCast(a.nSeedHigh)));
                count += 1;
            }
        }
    }
    try std.testing.expect(count == lows.len * highs.len * mods.len);
}

test "RANDOM long chain stays in lockstep with src/rng.zig across many steps" {
    // 256 distinct start seeds, each rolled 200 times against a rotating modulo set.
    const mods = [_]u32{ 4, 5, 16, 100, 1024, 7, 0x10000, 13 };
    var seed: u32 = 1;
    var s: usize = 0;
    while (s < 256) : (s += 1) {
        seed = seed *% 1103515245 +% 12345; // host-side seed spread (not the D2 RNG)
        var a = D2SeedStrc{ .nSeedLow = @bitCast(seed), .nSeedHigh = @bitCast(@as(u32, 0x29a)) };
        var b = ref.Seed.init(seed, 0x29a);
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const m = mods[i % mods.len];
            try std.testing.expectEqual(b.pick(m), randomNumberSelector(&a, m));
            try std.testing.expectEqual(b.low, @as(u32, @bitCast(a.nSeedLow)));
            try std.testing.expectEqual(b.high, @as(u32, @bitCast(a.nSeedHigh)));
        }
    }
}

test "RollRandomSeed matches src/rng.zig rollRandomSeed" {
    const lows = [_]u32{ 0, 1, 7, 12345, 0xdeadbeef, 0xffffffff };
    const highs = [_]u32{ 0, 0x29a, 666, 0xffffffff };
    for (lows) |lo| {
        for (highs) |hi| {
            var a = D2SeedStrc{ .nSeedLow = @bitCast(lo), .nSeedHigh = @bitCast(hi) };
            var b = ref.Seed.init(lo, hi);
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                const ra: u32 = @bitCast(RollRandomSeed(&a));
                try std.testing.expectEqual(b.rollRandomSeed(), ra);
            }
        }
    }
}

test "getModuloFromSeed equals randomNumberSelector" {
    const mods = [_]u32{ 0, 1, 4, 5, 16, 100, 1024, 7, 0x80000000 };
    for (mods) |m| {
        var a = D2SeedStrc{ .nSeedLow = 12345, .nSeedHigh = 0x29a };
        var b = D2SeedStrc{ .nSeedLow = 12345, .nSeedHigh = 0x29a };
        try std.testing.expectEqual(randomNumberSelector(&a, m), getModuloFromSeed(&b, m));
        try std.testing.expectEqual(a.nSeedLow, b.nSeedLow);
        try std.testing.expectEqual(a.nSeedHigh, b.nSeedHigh);
    }
}
