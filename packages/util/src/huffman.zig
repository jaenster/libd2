//! The D2GS wire Huffman codec — the compression the 1.14d engine puts on every
//! server->client game packet. Ported 1:1 from Game.exe:
//!
//!   COMPRESS_BuildHuffmanDecodeTable  @0x0040adb0   canonical table from 256 code lengths
//!   NET_D2GS_SERVER_CompressPacket    @0x0040b1b0   __fastcall (dst, dstLen, src, srcLen)
//!   NET_D2GS_CLIENT_DecompressPacket  @0x0040b260   same signature
//!   gabHuffmanCodeLengths             @0x007076c0   the stock 256-byte length table
//!   gadwHuffmanBitMasks               @0x007077c0
//!   gaHuffmanDecodeBuffer             @0x0075b3a0   0x300 bytes of decode scratch
//!
//! Only the server->client direction is ever compressed: CompressPacket is called
//! from NET_D2GS_SERVER_SendPacketToClient alone, and the client's uplink is raw.
//!
//! The alphabet is the 256 byte values, codes are canonical and assigned from the
//! longest length down (`code[next] = (code[prev] + 1) >> (len[prev] - len[next])`),
//! which puts the long codes at the bottom of the code space. With the stock table
//! (lengths 1..11) no code value exceeds 255, which is why the engine stores them in
//! a byte array — that is faithful here, custom tables truncate exactly as it does.

const std = @import("std");

/// The engine's static decode scratch is gaHuffmanDecodeBuffer @0x0075b3a0, 0x300
/// bytes up to gabHuffmanNextTable. A table that would not fit is rejected instead
/// of scribbling past it the way Game.exe would.
pub const decode_buffer_size = 0x300;

pub const BuildError = error{ InvalidCodeLengths, DecodeBufferOverflow };

/// gadwHuffmanBitMasks @0x007077c0 — low-n-bits masks.
const bit_masks = [16]u32{
    0x0000, 0x0001, 0x0003, 0x0007, 0x000f, 0x001f, 0x003f, 0x007f,
    0x00ff, 0x01ff, 0x03ff, 0x07ff, 0x0fff, 0x1fff, 0x3fff, 0x7fff,
};

/// gabHuffmanCodeLengths @0x007076c0 as shipped in the image: the code length of
/// every byte value. Symbol 0x00 costs a single bit, the longest codes are 11 bits.
pub const default_code_lengths = [256]u8{
    0x01, 0x04, 0x06, 0x07, 0x07, 0x06, 0x07, 0x07, 0x07, 0x08, 0x07, 0x08, 0x08, 0x07, 0x09, 0x08,
    0x08, 0x08, 0x07, 0x06, 0x06, 0x07, 0x08, 0x08, 0x08, 0x09, 0x09, 0x0a, 0x0a, 0x08, 0x07, 0x08,
    0x08, 0x0a, 0x0a, 0x0a, 0x0a, 0x09, 0x0a, 0x0a, 0x09, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0b,
    0x09, 0x09, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x09, 0x0a, 0x0a, 0x0a, 0x0a,
    0x09, 0x0a, 0x0a, 0x09, 0x0a, 0x09, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x09, 0x09, 0x0a, 0x0b,
    0x09, 0x08, 0x09, 0x0a, 0x0b, 0x09, 0x09, 0x0a, 0x09, 0x0a, 0x0a, 0x0a, 0x0b, 0x0a, 0x0a, 0x0a,
    0x0a, 0x0a, 0x09, 0x09, 0x09, 0x0a, 0x0a, 0x07, 0x07, 0x07, 0x0a, 0x09, 0x08, 0x07, 0x0a, 0x0a,
    0x0a, 0x0b, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0b, 0x0a, 0x0a, 0x0a, 0x0a,
    0x07, 0x0a, 0x0a, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a,
    0x09, 0x0b, 0x0b, 0x0a, 0x0b, 0x09, 0x09, 0x09, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
    0x0a, 0x0b, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
    0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
    0x0a, 0x0b, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0b,
    0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
    0x0a, 0x0b, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
    0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x06,
};

/// A built codec table: the encoder side (`lengths` + `codes`) and the decoder side
/// (`fast`, indexed by the top 8 bits of the bit buffer, pointing at `buf` records
/// laid out as `[extra_bits][symbol × 2^extra_bits]`).
pub const Table = struct {
    lengths: [256]u8,
    codes: [256]u8,
    fast: [256]u16,
    buf: [decode_buffer_size]u8,

    /// COMPRESS_BuildHuffmanDecodeTable @0x0040adb0.
    pub fn build(lengths: [256]u8) BuildError!Table {
        for (lengths) |len| {
            if (len == 0 or len > 15) return error.InvalidCodeLengths;
        }

        // Counting sort by DESCENDING code length, stable in symbol order. The engine
        // keeps both halves in one char[512]: lengths at [0..256), symbols at [256..512).
        // The bucket fill below indexes past the length half on purpose, so keep the
        // same single array rather than two.
        var sorted = [_]u8{0} ** 512;
        var offsets = [_]u16{0} ** 16;
        for (lengths) |len| offsets[len] += 1;
        var len_index: usize = 15;
        while (len_index >= 1) : (len_index -= 1) {
            const count = offsets[len_index];
            offsets[len_index] = offsets[0];
            offsets[0] += count;
        }
        for (lengths, 0..) |len, symbol| {
            const pos = offsets[len];
            sorted[256 + pos] = @intCast(symbol);
            offsets[len] = pos + 1;
        }
        for (0..256) |k| sorted[k] = lengths[sorted[256 + k]];

        var table: Table = .{
            .lengths = lengths,
            .codes = [_]u8{0} ** 256,
            .fast = [_]u16{0} ** 256,
            .buf = [_]u8{0} ** decode_buffer_size,
        };

        // Canonical codes, longest first: the first (longest) symbol gets 0 and every
        // step to a shorter length shifts the running code right.
        for (0..255) |k| {
            const prev: u32 = table.codes[sorted[256 + k]];
            const shift: u5 = @intCast(sorted[k] - sorted[k + 1]);
            table.codes[sorted[256 + k + 1]] = @truncate((prev + 1) >> shift);
        }

        // Walk shortest code first (the sort is descending, so from the back).
        var write: usize = 0;
        var k: usize = 256;
        while (k > 0) {
            k -= 1;
            const len = sorted[k];
            const symbol = sorted[256 + k];
            if (len < 9) {
                // Fits in the fast table: one 2-byte record, replicated over every
                // top-8-bit value that starts with this code.
                const shift: u5 = @intCast(8 - len);
                if (write + 2 > table.buf.len) return error.DecodeBufferOverflow;
                table.buf[write] = 0;
                table.buf[write + 1] = symbol;
                const first = @as(usize, table.codes[symbol]) << shift;
                const count = @as(usize, 1) << shift;
                if (first + count > table.fast.len) return error.InvalidCodeLengths;
                for (first..first + count) |slot| table.fast[slot] = @intCast(write);
                write += 2;
                continue;
            }

            // Long code: the fast table entry becomes a bucket resolved by the next
            // (len - 8) bits. Only the symbol sitting at the bottom of the bucket
            // creates it; the rest are filled in by that pass.
            const extra: u5 = @intCast(len - 8);
            const span = @as(usize, 1) << extra;
            const code = table.codes[symbol];
            if (code & @as(u8, @intCast(span - 1)) != 0) continue;
            if (write + 1 + span > table.buf.len) return error.DecodeBufferOverflow;
            table.fast[@as(usize, code) >> extra] = @intCast(write);
            table.buf[write] = extra;
            const record = write;
            write += 1;

            // Faithful quirk: the engine advances the symbol cursor by one per symbol
            // but looks the code length up at `sorted[k + slot]` — indexed by slots
            // filled, which for a mixed-length bucket runs ahead and can read into the
            // symbol half of the array (MOVZX @0x0040b043, so unsigned). It lands on
            // equal lengths for the stock table.
            var slot: usize = 0;
            var cursor: usize = k;
            while (slot < span) : (cursor += 1) {
                if (cursor > 255) return error.InvalidCodeLengths;
                const raw: i32 = sorted[k + slot];
                // SUB then `1 << CL` masks the count to 5 bits, so a length that runs
                // past `len` wraps into an absurd span instead of underflowing.
                const count = @as(usize, 1) << @truncate(@as(u32, @bitCast(@as(i32, len) - raw)));
                if (write + count > table.buf.len or slot + count > span) return error.DecodeBufferOverflow;
                const fill = sorted[256 + cursor];
                write += count;
                for (0..count) |_| {
                    table.buf[record + 1 + slot] = fill;
                    slot += 1;
                }
            }
        }

        return table;
    }

    /// Build from the 128-byte nibble-packed length table the engine accepts in an
    /// `AF 81` greeting.
    pub fn fromNibbles(packed_lengths: *const [128]u8) BuildError!Table {
        return build(decodeNibbles(packed_lengths));
    }

    /// NET_D2GS_SERVER_CompressPacket @0x0040b1b0. Returns the number of bytes written,
    /// or null when `dst` is too small (the engine returns 0 and its caller halts).
    pub fn compress(self: *const Table, dst: []u8, src: []const u8) ?usize {
        if (src.len == 0) return 0;
        var pending: u32 = 0;
        var free: u32 = 8;
        var written: usize = 0;
        for (src) |symbol| {
            var bits: u32 = self.lengths[symbol];
            const code: u32 = self.codes[symbol];
            while (free <= bits) {
                bits -= free;
                if (written == dst.len) return null;
                dst[written] = @truncate((code >> @truncate(bits & 0x1f)) | pending);
                written += 1;
                pending = 0;
                free = 8;
            }
            if (bits != 0) {
                free -= bits;
                pending |= code << @truncate(free);
            }
        }
        if (free < 8) {
            if (written == dst.len) return null;
            dst[written] = @truncate(pending);
            written += 1;
        }
        return written;
    }

    /// NET_D2GS_CLIENT_DecompressPacket @0x0040b260. Returns the number of bytes
    /// decoded — the stream ends when the bit buffer runs past the real input — or
    /// null when `dst` is too small.
    pub fn decompress(self: *const Table, dst: []u8, src: []const u8) ?usize {
        var bits: u32 = 0;
        var available: u32 = 32;
        var read: usize = 0;
        var written: usize = 0;
        while (true) {
            while (available > 7 and read < src.len) {
                available -= 8;
                bits |= @as(u32, src[read]) << @truncate(available);
                read += 1;
            }
            const record: usize = self.fast[bits >> 24];
            const extra = self.buf[record];
            const slot: usize = (bits >> @truncate(24 - @as(u32, extra))) & bit_masks[extra];
            const symbol = self.buf[record + 1 + slot];
            const code_len = self.lengths[symbol];
            available += code_len;
            if (available > 32) return written;
            if (written == dst.len) return null;
            dst[written] = symbol;
            written += 1;
            bits <<= @truncate(code_len);
        }
    }
};

/// Unpack the nibble-packed length table of an `AF 81` greeting
/// (NET_D2GS_CLIENT_ParseRecvBufferIntoPacketQueues @0x0052a9a5): low nibble + 1 is
/// the code length of symbol 2i, high nibble + 1 that of symbol 2i+1.
pub fn decodeNibbles(packed_lengths: *const [128]u8) [256]u8 {
    var lengths: [256]u8 = undefined;
    for (packed_lengths, 0..) |byte, i| {
        lengths[2 * i] = (byte & 0x0f) + 1;
        lengths[2 * i + 1] = (byte >> 4) + 1;
    }
    return lengths;
}

/// The table every stock 1.14d client and server uses unless the greeting negotiates
/// another one. Built at compile time from `default_code_lengths`.
pub const default_table: Table = blk: {
    @setEvalBranchQuota(200_000);
    break :blk Table.build(default_code_lengths) catch unreachable;
};

/// Convenience wrappers over `default_table`.
pub fn compress(dst: []u8, src: []const u8) ?usize {
    return default_table.compress(dst, src);
}

pub fn decompress(dst: []u8, src: []const u8) ?usize {
    return default_table.decompress(dst, src);
}
