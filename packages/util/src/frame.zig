//! D2GS server->client packet framing, from NET_D2GS_SERVER_SendPacketToClient
//! @0x0052b330: every compressed packet is prefixed with its total length, one byte
//! below 0xF0 and two bytes above it. The length counts the prefix itself.
//!
//! Two kinds of traffic skip all of this and go out raw: the `AF` connection
//! greeting, and anything the engine sends with mode 2.

const std = @import("std");
const huffman = @import("huffman.zig");

/// The engine halts (ERROR_UnrecoverableInternalError) on a raw packet above this.
pub const max_packet_size = 0x204;

/// Size of the engine's compression output window (`CompressPacket(pBuffer + 2, 1032, …)`).
pub const max_compressed_size = 1032;

/// Largest frame a two-byte header can describe: the high nibble is the 0xF0 marker.
pub const max_frame_size = 0x0fff;

pub const EncodeError = error{ PacketTooLarge, BufferTooSmall };

/// Compress `packet` and write the complete framed bytes into `dst`, returning the
/// slice to put on the wire. `dst` needs `max_compressed_size + 2` bytes worst case.
pub fn encode(dst: []u8, table: *const huffman.Table, packet: []const u8) EncodeError![]u8 {
    if (packet.len > max_packet_size) return error.PacketTooLarge;
    if (dst.len < 3) return error.BufferTooSmall;

    const window = @min(dst.len - 2, max_compressed_size);
    const compressed = table.compress(dst[2..][0..window], packet) orelse return error.BufferTooSmall;

    const short_total = compressed + 1;
    if (short_total < 0xf0) {
        dst[1] = @intCast(short_total);
        return dst[1..][0..short_total];
    }
    const total = compressed + 2;
    if (total > max_frame_size) return error.PacketTooLarge;
    dst[0] = @intCast((total >> 8) | 0xf0);
    dst[1] = @truncate(total);
    return dst[0..total];
}

pub const Frame = struct {
    /// The compressed bytes, header stripped.
    payload: []const u8,
    /// Bytes consumed from the input — the framed length, header included.
    size: usize,
};

/// Split the first frame off a server->client byte stream. Returns null when `buf`
/// does not hold a complete frame yet.
pub fn decode(buf: []const u8) ?Frame {
    if (buf.len < 1) return null;
    if (buf[0] < 0xf0) {
        const total: usize = buf[0];
        if (total < 1 or buf.len < total) return null;
        return .{ .payload = buf[1..total], .size = total };
    }
    if (buf.len < 2) return null;
    const total: usize = (@as(usize, buf[0] & 0x0f) << 8) | buf[1];
    if (total < 2 or buf.len < total) return null;
    return .{ .payload = buf[2..total], .size = total };
}

/// Decompress one frame's payload with `table`.
pub fn decodeInto(dst: []u8, table: *const huffman.Table, frame: Frame) ?usize {
    return table.decompress(dst, frame.payload);
}

pub const greeting_opcode = 0xaf;

/// What the `AF` greeting tells the client about the rest of the stream, as read by
/// NET_D2GS_CLIENT_ParseRecvBufferIntoPacketQueues @0x0052a988.
pub const Greeting = union(enum) {
    /// `AF 00` — no compression and no framing; raw opcodes follow.
    uncompressed,
    /// Any other non-zero flag: compressed with the stock table.
    default_table,
    /// `AF 81` — compressed with a table sent inline, nibble-packed.
    custom_table: *const [128]u8,
};

pub const ParsedGreeting = struct {
    greeting: Greeting,
    /// Bytes the engine consumes for the greeting.
    size: usize,
};

/// Parse an `AF` greeting. Note the engine reads the 128 custom-table bytes starting
/// at the FLAG byte, not after it, so `0x81` doubles as the lengths of symbols 0 and 1
/// (2 and 9). A server offering a custom table has to live with that.
pub fn parseGreeting(buf: []const u8) ?ParsedGreeting {
    if (buf.len < 2 or buf[0] != greeting_opcode) return null;
    return switch (buf[1]) {
        0x00 => .{ .greeting = .uncompressed, .size = 2 },
        0x81 => if (buf.len < 129) null else .{
            .greeting = .{ .custom_table = buf[1..129] },
            .size = 129,
        },
        else => .{ .greeting = .default_table, .size = 2 },
    };
}

pub const greeting_uncompressed = [2]u8{ greeting_opcode, 0x00 };
pub const greeting_compressed = [2]u8{ greeting_opcode, 0x01 };
