//! d2-bncs public library API — the Battle.net side of Diablo II, as opposed to the game side.
//!
//! `d2-net` models the in-game D2GS protocol: what a client and a game server say to each other
//! once a game exists. Everything *before* that — logging in, proving the client is a real
//! unmodified 1.14d, proving it owns a CD key, and the chat/realm messages that carry it — is
//! this package. The two never overlap and neither depends on the other.
//!
//! Three distinct hashes live here and mixing them up is the classic way to get a logon that
//! almost works, so they are named for their role rather than their maths:
//!
//!   * `xsha1`    — Blizzard's BROKEN SHA-1, and only ever the OLS password hash. Little-endian
//!                  words, a mangled expansion, no padding terminator. NOT standard SHA-1.
//!   * `checkrev` — the version check, which uses STANDARD SHA-1 over the hashed MPQ.
//!   * `cdkey`    — the CD-key decode, whose hash is standard SHA-1 as well.
//!
//! `protocol` is the message-level vocabulary those hashes are carried in: chat flags, event
//! ids, the D2GS accept sequence.
//!
//! Reverse-engineered from 1.14d `Game.exe` and verified against a real client login; the
//! vectors in each file are captures, not invented. No real CD keys are committed. Pure Zig,
//! libc-free, no allocator — so this compiles for freestanding wasm like everything else here,
//! and into a 32-bit Windows DLL for the client-side version check.

const std = @import("std");

pub const xsha1 = @import("xsha1.zig");
pub const checkrev = @import("checkrev.zig");
pub const cdkey = @import("cdkey.zig");
pub const protocol = @import("protocol.zig");

test {
    _ = xsha1;
    _ = checkrev;
    _ = cdkey;
    _ = protocol;
}
