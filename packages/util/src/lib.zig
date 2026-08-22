//! d2-util public library API — cross-cutting primitives with no domain of their own.
//!
//! `huffman` is the D2GS server->client packet codec of 1.14d Game.exe (compress,
//! decompress, and the canonical table build that both sides negotiate), `frame` is
//! the length-prefix framing and the `AF` greeting that wraps it. Both are libc-free and
//! allocator-free: a table is a value you can build at comptime.
//!
//! `png` writes RGBA8888 out as a file any viewer opens. It is here rather than next to a
//! renderer because everything in this library that produces pixels — item sprites, the automap,
//! a launcher drawing the game's own menus — needs the same twenty lines to show them to a human,
//! and three copies of a PNG writer is three chances to write a subtly invalid one. It takes an
//! allocator; the rest of this package does not.

const std = @import("std");

pub const huffman = @import("huffman.zig");
pub const frame = @import("frame.zig");
pub const png = @import("png.zig");

pub const HuffmanTable = huffman.Table;

test {
    _ = huffman;
    _ = frame;
    _ = png;
    _ = @import("huffman_test.zig");
    _ = @import("frame_test.zig");
}
