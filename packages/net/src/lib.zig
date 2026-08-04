//! D2 1.14d game protocol — the server<->client packet layer.
//!
//! Faithful, pure-Zig port of the D2GS wire format (no C, no @cImport). Two opcode spaces:
//!   * `sc` — server -> client stream (client-incoming table `NET_D2GS_CLIENT_INCOMING @0x7114D0`,
//!            size table `@0x730AE8`). Opcode-framed; a few packets are variable / bit-packed.
//!   * `cs` — client -> server game commands (`D2GSPacketClt0xNN_*`, server-side Recv handlers).
//!
//! Every packet type exposes `encode(out) []u8` and `decode(buf) !T`, byte-exact and
//! little-endian. Provenance is cited per-struct; see the module headers. Ghidra session 62fbfe69.

pub const bitreader = @import("bitreader.zig");
pub const sc = @import("sc.zig");
pub const cs = @import("cs.zig");

pub const BitReader = bitreader.BitReader;
pub const BitWriter = bitreader.BitWriter;

test {
    _ = bitreader;
    _ = sc;
    _ = cs;
}
