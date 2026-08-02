//! d2-util public library API — cross-cutting primitives with no domain of their own.
//!
//! `huffman` is the D2GS server->client packet codec of 1.14d Game.exe (compress,
//! decompress, and the canonical table build that both sides negotiate), `frame` is
//! the length-prefix framing and the `AF` greeting that wraps it. Pure Zig, libc-free,
//! no allocator: a table is a value you can build at comptime.

const std = @import("std");

pub const huffman = @import("huffman.zig");
pub const frame = @import("frame.zig");

pub const HuffmanTable = huffman.Table;

test {
    _ = huffman;
    _ = frame;
    _ = @import("huffman_test.zig");
    _ = @import("frame_test.zig");
}
