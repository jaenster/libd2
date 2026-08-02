const std = @import("std");
const huffman = @import("huffman.zig");
const frame = @import("frame.zig");

const table = &huffman.default_table;

test "short packets take the one-byte header" {
    const packet = [_]u8{ 0x15, 0x01, 0x02, 0x03 };
    var buf: [1034]u8 = undefined;
    const framed = try frame.encode(&buf, table, &packet);

    try std.testing.expect(framed[0] < 0xf0);
    try std.testing.expectEqual(framed.len, @as(usize, framed[0]));

    const parsed = frame.decode(framed).?;
    try std.testing.expectEqual(framed.len, parsed.size);

    var out: [0x204]u8 = undefined;
    const n = frame.decodeInto(&out, table, parsed).?;
    try std.testing.expect(n >= packet.len);
    try std.testing.expectEqualSlices(u8, &packet, out[0..packet.len]);
}

test "packets past the one-byte limit take the two-byte header" {
    // Uniformly random bytes average well over 8 bits each, so a full-size packet is
    // guaranteed to land above 0xEF compressed.
    var prng = std.Random.DefaultPrng.init(7);
    var packet: [0x204]u8 = undefined;
    prng.random().bytes(&packet);

    var buf: [1034]u8 = undefined;
    const framed = try frame.encode(&buf, table, &packet);

    try std.testing.expectEqual(@as(u8, 0xf0), framed[0] & 0xf0);
    const total = (@as(usize, framed[0] & 0x0f) << 8) | framed[1];
    try std.testing.expectEqual(framed.len, total);

    const parsed = frame.decode(framed).?;
    try std.testing.expectEqual(framed.len, parsed.size);

    var out: [0x204 * 2]u8 = undefined;
    const n = frame.decodeInto(&out, table, parsed).?;
    try std.testing.expect(n >= packet.len);
    try std.testing.expectEqualSlices(u8, &packet, out[0..packet.len]);
}

test "a truncated stream yields no frame" {
    const packet = [_]u8{ 0x15, 0x01, 0x02, 0x03 };
    var buf: [1034]u8 = undefined;
    const framed = try frame.encode(&buf, table, &packet);

    for (0..framed.len) |partial| try std.testing.expectEqual(@as(?frame.Frame, null), frame.decode(framed[0..partial]));
    try std.testing.expect(frame.decode(framed) != null);
}

test "back-to-back frames split at the right offsets" {
    const packets = [_][]const u8{
        &.{ 0x15, 0x00 },
        &.{ 0x51, 0x01, 0x02 },
        &.{0x0c},
    };

    // encode() returns a slice inside its scratch that may start at dst[1] (the engine
    // backfills a one-byte header at pBuffer+1), so a stream is built by appending what
    // it returns, not by advancing over the scratch.
    var scratch: [1034]u8 = undefined;
    var stream: [4096]u8 = undefined;
    var used: usize = 0;
    for (packets) |packet| {
        const framed = try frame.encode(&scratch, table, packet);
        @memcpy(stream[used..][0..framed.len], framed);
        used += framed.len;
    }

    var offset: usize = 0;
    for (packets) |packet| {
        const parsed = frame.decode(stream[offset..used]).?;
        var out: [0x204]u8 = undefined;
        const n = frame.decodeInto(&out, table, parsed).?;
        try std.testing.expect(n >= packet.len);
        try std.testing.expectEqualSlices(u8, packet, out[0..packet.len]);
        offset += parsed.size;
    }
    try std.testing.expectEqual(used, offset);
}

test "oversized packets are refused like the engine's halt" {
    const packet = [_]u8{0} ** (frame.max_packet_size + 1);
    var buf: [1034]u8 = undefined;
    try std.testing.expectError(error.PacketTooLarge, frame.encode(&buf, table, &packet));
}

test "greeting flags" {
    try std.testing.expectEqual(
        frame.Greeting.uncompressed,
        frame.parseGreeting(&frame.greeting_uncompressed).?.greeting,
    );
    try std.testing.expectEqual(
        frame.Greeting.default_table,
        frame.parseGreeting(&frame.greeting_compressed).?.greeting,
    );
    try std.testing.expectEqual(@as(?frame.ParsedGreeting, null), frame.parseGreeting(&.{ 0x01, 0x00 }));
}

test "an AF 81 greeting carries its own table, flag byte included" {
    var greeting: [129]u8 = undefined;
    greeting[0] = frame.greeting_opcode;
    greeting[1] = 0x81;
    for (greeting[2..]) |*byte| byte.* = 0x77;

    try std.testing.expectEqual(@as(?frame.ParsedGreeting, null), frame.parseGreeting(greeting[0..64]));

    const parsed = frame.parseGreeting(&greeting).?;
    try std.testing.expectEqual(@as(usize, 129), parsed.size);

    // The flag byte is the first table byte: 0x81 gives symbol 0 a 2-bit code and
    // symbol 1 a 9-bit one, everything after it 8 bits.
    const lengths = huffman.decodeNibbles(parsed.greeting.custom_table);
    try std.testing.expectEqual(@as(u8, 2), lengths[0]);
    try std.testing.expectEqual(@as(u8, 9), lengths[1]);
    try std.testing.expectEqual(@as(u8, 8), lengths[2]);
}
