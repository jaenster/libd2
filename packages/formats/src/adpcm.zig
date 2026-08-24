//! Storm's IMA-ADPCM decoder — the `0x40` (mono) and `0x80` (stereo) bits of an MPQ sector's
//! compression mask. It is always the last stage: what it writes is 16-bit PCM.
//!
//! Unlike textbook IMA, Storm spends a whole byte per sample rather than a nibble, and reserves
//! the top bit for commands that retune the step index without emitting anything. A chunk opens
//! with a padding byte, a bit shift, and one starting sample per channel; the rest is one code
//! per sample, alternating channels in stereo.

const std = @import("std");

pub const Error = error{Truncated};

const initial_step_index: i32 = 0x2c;
const max_step_index: i32 = 0x58;

pub const Channels = enum(u8) { mono = 1, stereo = 2 };

/// Expand one ADPCM chunk into `dst` and return how much was written — up to `dst.len`, less if
/// the input runs out first.
pub fn decompress(dst: []u8, src: []const u8, channels: Channels) Error!usize {
    const count: usize = @intFromEnum(channels);
    if (src.len < 2) return Error.Truncated;
    const shift: u5 = @intCast(src[1] & 0x1f);

    var sample = [2]i32{ 0, 0 };
    var index = [2]i32{ initial_step_index, initial_step_index };
    var at: usize = 2;
    var out: usize = 0;

    for (0..count) |c| {
        if (at + 2 > src.len) return out;
        sample[c] = std.mem.readInt(i16, src[at..][0..2], .little);
        at += 2;
        if (out + 2 > dst.len) return out;
        std.mem.writeInt(i16, dst[out..][0..2], @intCast(sample[c]), .little);
        out += 2;
    }

    var ch: usize = count - 1;
    while (at < src.len and out < dst.len) {
        if (count == 2) ch = 1 - ch;
        const code = src[at];
        at += 1;

        if (code & 0x80 != 0) {
            switch (code & 0x7f) {
                // Repeat the last sample and ease the step down.
                0 => {
                    if (index[ch] != 0) index[ch] -= 1;
                    if (out + 2 > dst.len) break;
                    std.mem.writeInt(i16, dst[out..][0..2], @intCast(sample[ch]), .little);
                    out += 2;
                },
                // Retune this channel's step without emitting; the channel does not advance,
                // so the flip at the top of the loop is undone.
                1 => {
                    index[ch] = @min(index[ch] + 8, max_step_index);
                    if (count == 2) ch = 1 - ch;
                },
                // Skip a channel. The flip above already did it.
                2 => {},
                else => {
                    index[ch] = @max(index[ch] - 8, 0);
                    if (count == 2) ch = 1 - ch;
                },
            }
            continue;
        }

        const step = step_size[@intCast(index[ch])];
        var delta = step >> shift;
        inline for (0..6) |b| {
            if (code & (@as(u8, 1) << b) != 0) delta += step >> b;
        }
        if (code & 0x40 != 0) {
            sample[ch] -= delta;
            if (sample[ch] < -0x7fff) sample[ch] = -0x8000;
        } else {
            sample[ch] += delta;
            if (sample[ch] > 0x7ffe) sample[ch] = 0x7fff;
        }
        if (out + 2 > dst.len) break;
        std.mem.writeInt(i16, dst[out..][0..2], @intCast(sample[ch]), .little);
        out += 2;
        index[ch] = std.math.clamp(index[ch] + next_step[code & 0x1f], 0, max_step_index);
    }
    return out;
}

/// The IMA step ladder, and how far a code moves along it.
const step_size = [89]i32{
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

const next_step = [32]i32{
    -1, 0, -1, 4, -1, 2, -1, 6,
    -1, 1, -1, 5, -1, 3, -1, 7,
    -1, 1, -1, 5, -1, 3, -1, 7,
    -1, 2, -1, 4, -1, 6, -1, 8,
};

const testing = std.testing;

test "adpcm: the header seeds one sample per channel" {
    var dst: [8]u8 = undefined;
    const mono = [_]u8{ 0x00, 0x05, 0x34, 0x12 };
    try testing.expectEqual(@as(usize, 2), try decompress(&dst, &mono, .mono));
    try testing.expectEqual(@as(i16, 0x1234), std.mem.readInt(i16, dst[0..2], .little));

    const stereo = [_]u8{ 0x00, 0x05, 0x34, 0x12, 0xCD, 0xAB };
    try testing.expectEqual(@as(usize, 4), try decompress(&dst, &stereo, .stereo));
    try testing.expectEqual(@as(i16, 0x1234), std.mem.readInt(i16, dst[0..2], .little));
    try testing.expectEqual(@as(i16, -0x5433), std.mem.readInt(i16, dst[2..4], .little));
}

test "adpcm: 0x80 repeats the sample, 0x81 and 0x83 only retune" {
    var dst: [16]u8 = undefined;
    const src = [_]u8{ 0x00, 0x05, 0x00, 0x10, 0x80, 0x81, 0x83, 0x80 };
    const n = try decompress(&dst, &src, .mono);
    // Two repeats emit; the two retune codes emit nothing.
    try testing.expectEqual(@as(usize, 6), n);
    for (0..3) |i| {
        try testing.expectEqual(@as(i16, 0x1000), std.mem.readInt(i16, dst[i * 2 ..][0..2], .little));
    }
}

test "adpcm: a plain code moves the sample by the step ladder" {
    var dst: [16]u8 = undefined;
    // Step index starts at 0x2c, so the step is step_size[0x2c]; shift 4 with bit 0 set means
    // the sample moves by step>>4 + step.
    const step = step_size[0x2c];
    const src = [_]u8{ 0x00, 0x04, 0x00, 0x00, 0x01 };
    try testing.expectEqual(@as(usize, 4), try decompress(&dst, &src, .mono));
    try testing.expectEqual(@as(i16, @intCast((step >> 4) + step)), std.mem.readInt(i16, dst[2..4], .little));

    // The same code with 0x40 set moves the other way.
    const down = [_]u8{ 0x00, 0x04, 0x00, 0x00, 0x41 };
    try testing.expectEqual(@as(usize, 4), try decompress(&dst, &down, .mono));
    try testing.expectEqual(@as(i16, @intCast(-((step >> 4) + step))), std.mem.readInt(i16, dst[2..4], .little));
}

test "adpcm: output stops at the end of dst" {
    var dst: [2]u8 = undefined;
    const src = [_]u8{ 0x00, 0x05, 0x00, 0x10, 0x80, 0x80, 0x80 };
    try testing.expectEqual(@as(usize, 2), try decompress(&dst, &src, .mono));
}

test "adpcm: a chunk with no header is rejected" {
    var dst: [8]u8 = undefined;
    try testing.expectError(Error.Truncated, decompress(&dst, &[_]u8{0x00}, .mono));
}
