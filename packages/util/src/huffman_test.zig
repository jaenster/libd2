const std = @import("std");
const huffman = @import("huffman.zig");
const legacy = @import("testdata/legacy_huffman.zig");

test "stock code lengths form a complete prefix code" {
    // Kraft equality: a canonical Huffman table must fill the code space exactly.
    var total: u64 = 0;
    for (huffman.default_code_lengths) |len| total += @as(u64, 1) << @intCast(15 - len);
    try std.testing.expectEqual(@as(u64, 1) << 15, total);
}

test "every symbol survives a round trip" {
    for (0..256) |symbol| {
        const src = [_]u8{@intCast(symbol)};
        var packed_bytes: [4]u8 = undefined;
        const n = huffman.compress(&packed_bytes, &src).?;
        try std.testing.expect(n >= 1 and n <= 2);

        var out: [8]u8 = undefined;
        const m = huffman.decompress(&out, packed_bytes[0..n]).?;
        try std.testing.expect(m >= 1);
        try std.testing.expectEqual(src[0], out[0]);
    }
}

test "round trip over payload shapes the engine actually sends" {
    var prng = std.Random.DefaultPrng.init(0x1337);
    const rand = prng.random();

    var src: [0x204]u8 = undefined;
    var packed_bytes: [1032]u8 = undefined;
    var out: [0x204 * 2]u8 = undefined;

    for (0..512) |round| {
        const len = 1 + (round % src.len);
        for (src[0..len]) |*byte| {
            // Real packets are mostly small opcodes and zero padding, which is what the
            // table is tuned for; mix that with uniform bytes to exercise long codes too.
            byte.* = if (rand.boolean()) rand.uintLessThan(u8, 32) else rand.int(u8);
        }
        const n = huffman.compress(&packed_bytes, src[0..len]).?;
        const m = huffman.decompress(&out, packed_bytes[0..n]).?;
        try std.testing.expect(m >= len);
        try std.testing.expectEqualSlices(u8, src[0..len], out[0..len]);
    }
}

test "all-zero payloads compress eight to one" {
    const src = [_]u8{0} ** 64;
    var packed_bytes: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), huffman.compress(&packed_bytes, &src).?);
}

test "decoding agrees with the reference table over the whole code space" {
    // The longest stock code is 11 bits, so every reachable decode path is covered by
    // sweeping all 16-bit prefixes.
    var prefix: u32 = 0;
    while (prefix <= 0xffff) : (prefix += 1) {
        const src = [_]u8{ @truncate(prefix >> 8), @truncate(prefix), 0, 0 };

        var mine: [32]u8 = undefined;
        var theirs: [32]u8 = undefined;
        const n = huffman.decompress(&mine, &src).?;
        const m = legacy.decompress(&src, &theirs).?;

        try std.testing.expectEqual(m, n);
        try std.testing.expectEqualSlices(u8, theirs[0..m], mine[0..n]);
    }
}

test "compress reports overflow instead of running past dst" {
    const src = [_]u8{0xfe} ** 32; // 11 bits each, so 44 bytes are needed
    var small: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), huffman.compress(&small, &src));

    var exact: [44]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 44), huffman.compress(&exact, &src).?);
}

test "decompress reports overflow instead of running past dst" {
    const src = [_]u8{0xff} ** 16;
    var packed_bytes: [64]u8 = undefined;
    const n = huffman.compress(&packed_bytes, &src).?;

    var small: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), huffman.decompress(&small, packed_bytes[0..n]));
}

test "empty input" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), huffman.compress(&out, &.{}).?);
    try std.testing.expectEqual(@as(usize, 0), huffman.decompress(&out, &.{}).?);
}

test "a negotiated table round trips" {
    // A complete code that starts with the 0x81 flag byte the AF 81 greeting forces on
    // symbols 0 and 1 (2 and 9 bits), then 170 symbols at 8, two more at 9, 82 at 10.
    var nibbles: [128]u8 = undefined;
    nibbles[0] = 0x81;
    for (nibbles[1..86]) |*byte| byte.* = 0x77;
    nibbles[86] = 0x98;
    nibbles[87] = 0x98;
    for (nibbles[88..128]) |*byte| byte.* = 0x99;

    const lengths = huffman.decodeNibbles(&nibbles);
    var kraft: u64 = 0;
    for (lengths) |len| kraft += @as(u64, 1) << @intCast(15 - len);
    try std.testing.expectEqual(@as(u64, 1) << 15, kraft);

    const table = try huffman.Table.build(lengths);
    try std.testing.expectEqual(@as(u8, 2), table.lengths[0]);
    try std.testing.expectEqual(@as(u8, 9), table.lengths[1]);
    try std.testing.expectEqual(@as(u8, 8), table.lengths[2]);

    var src: [256]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @intCast(i);

    var packed_bytes: [1032]u8 = undefined;
    var out: [512]u8 = undefined;
    const n = table.compress(&packed_bytes, &src).?;
    const m = table.decompress(&out, packed_bytes[0..n]).?;
    try std.testing.expect(m >= src.len);
    try std.testing.expectEqualSlices(u8, &src, out[0..src.len]);
}

test "malformed tables are rejected, not written past" {
    var lengths = [_]u8{8} ** 256;
    lengths[0] = 0;
    try std.testing.expectError(error.InvalidCodeLengths, huffman.Table.build(lengths));

    lengths[0] = 16;
    try std.testing.expectError(error.InvalidCodeLengths, huffman.Table.build(lengths));
}

// ── evidence: a frame the game actually sent ─────────────────────────────────
//
// Everything above is a property of the codec — that it round-trips, that the table is a
// complete prefix code, that it refuses to run past a buffer. All of it would still pass if
// the static table were subtly wrong, because both directions would be wrong together.
//
// This is the one test that cannot: a real 0x01 GameFlags packet captured off a live 1.14d
// game server, four compressed bytes and the nine plaintext bytes they stand for. It pins the
// codec to the wire rather than to itself, in both directions.
const captured_compressed = [_]u8{ 0x7a, 0x09, 0xa5, 0xf0 };
const captured_plaintext = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0x10, 0x00, 0x01, 0x00, 0x00 };

test "a frame captured off a live 1.14d server decodes to its known plaintext" {
    var out: [64]u8 = undefined;
    const n = huffman.decompress(&out, &captured_compressed) orelse return error.DecodeFailed;
    try std.testing.expectEqualSlices(u8, &captured_plaintext, out[0..n]);
}

test "that same plaintext re-encodes to the bytes the server sent" {
    var out: [64]u8 = undefined;
    const n = huffman.compress(&out, &captured_plaintext) orelse return error.EncodeFailed;
    try std.testing.expectEqualSlices(u8, &captured_compressed, out[0..n]);
}
