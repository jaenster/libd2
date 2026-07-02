//! LSB-first bit reader/writer — a faithful stand-in for D2 1.14d Fog::BitBuffer (read side).
//!
//! Bytes are consumed in order; within each byte the least-significant bit is read first. This
//! is the same bit packing D2 uses for the item stream (0x9C payloads), the life packets
//! (0x18/0x95) and .d2s saves. A byte-aligned read of N*8 bits equals a little-endian integer.
//!
//! Ported verbatim from the sibling clientless world-decoder (src/game/bitreader.zig); that
//! module is capture-verified against a live 1.14d server stream.

const std = @import("std");

pub const BitReader = struct {
    bytes: []const u8,
    bit_pos: usize = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    pub fn bitsLeft(self: *const BitReader) usize {
        const total = self.bytes.len * 8;
        return if (self.bit_pos >= total) 0 else total - self.bit_pos;
    }

    /// Read `n` bits (0..=32), LSB-first, zero-extended. Reads past the end yield 0 bits but
    /// still advance bit_pos (mirrors the engine reading a truncated/short buffer).
    pub fn read(self: *BitReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        var result: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const abs = self.bit_pos + i;
            const byte_idx = abs >> 3;
            if (byte_idx < self.bytes.len) {
                const bit_idx: u3 = @intCast(abs & 7);
                const bit: u32 = (self.bytes[byte_idx] >> bit_idx) & 1;
                result |= bit << @intCast(i);
            }
        }
        self.bit_pos += n;
        return result;
    }

    /// Read `n` bits as a two's-complement signed value of that width.
    pub fn readSigned(self: *BitReader, n: u6) i32 {
        const raw = self.read(n);
        if (n == 0 or n >= 32) return @bitCast(raw);
        const sign_bit = @as(u32, 1) << @intCast(n - 1);
        if (raw & sign_bit != 0) {
            const ext = ~((@as(u32, 1) << @intCast(n)) - 1);
            return @bitCast(raw | ext);
        }
        return @intCast(raw);
    }

    pub fn readBool(self: *BitReader) bool {
        return self.read(1) != 0;
    }
};

/// LSB-first bit writer — inverse of BitReader. Writes into a caller-provided buffer that must
/// be pre-zeroed for the length that will be written (writes OR bits in).
pub const BitWriter = struct {
    bytes: []u8,
    bit_pos: usize = 0,

    pub fn init(bytes: []u8) BitWriter {
        return .{ .bytes = bytes };
    }

    pub fn write(self: *BitWriter, value: u32, n: u6) void {
        std.debug.assert(n <= 32);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const bit: u8 = @intCast((value >> @intCast(i)) & 1);
            const abs = self.bit_pos + i;
            const byte_idx = abs >> 3;
            if (byte_idx < self.bytes.len) self.bytes[byte_idx] |= bit << @intCast(abs & 7);
        }
        self.bit_pos += n;
    }

    pub fn byteLen(self: *const BitWriter) usize {
        return (self.bit_pos + 7) >> 3;
    }
};

test "BitWriter round-trips through BitReader" {
    var buf = [_]u8{0} ** 8;
    var w = BitWriter.init(&buf);
    w.write(0x95, 8);
    w.write(100, 15);
    w.write(5000, 16);
    var r = BitReader.init(&buf);
    try std.testing.expectEqual(@as(u32, 0x95), r.read(8));
    try std.testing.expectEqual(@as(u32, 100), r.read(15));
    try std.testing.expectEqual(@as(u32, 5000), r.read(16));
}

test "byte-aligned multi-byte read equals little-endian int" {
    var r = BitReader.init(&[_]u8{ 0x34, 0x12 });
    try std.testing.expectEqual(@as(u32, 0x1234), r.read(16));
    var r2 = BitReader.init(&[_]u8{ 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u32, 0x12345678), r2.read(32));
}
