//! d2-bnet public library API — the Battle.net side of Diablo II, as opposed to the game side.
//!
//! `d2-net` models the in-game D2GS protocol: what a client and a game server say to each other
//! once a game exists. Everything *before* that is this package. The two never overlap and
//! neither depends on the other, which is the useful part: a bot that joins by token needs
//! d2-net and none of this, and a realm server needs this and none of d2-net.
//!
//! "Before a game exists" is three protocols multiplexed over one connection to port 6112, and
//! the name is deliberately the family rather than any one of them:
//!
//!   * BNCS  — logon and chat. The `SID_*` opcode space.
//!   * MCP   — the realm: character list, create/delete, and the game create/join that hands
//!             out the token d2-net then uses.
//!   * BNFTP — file transfer on the same port, which is how the client fetches the MPQ the
//!             version check is computed over.
//!
//! Today only the hashes and the BNCS message vocabulary live here; the packet layouts and the
//! session drivers for all three are still spread across the consumers and belong here.
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
//! ids, the D2GS accept sequence. `bnftp` is the file transfer that delivers the version-check
//! MPQ — encode and decode only, both directions, so a client, a server and a probe share one
//! definition of the wire instead of three.
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
pub const bnftp = @import("bnftp.zig");
pub const mcp = @import("mcp.zig");
pub const realm = @import("realm.zig");
pub const keystore = @import("keystore.zig");

test {
    _ = xsha1;
    _ = checkrev;
    _ = cdkey;
    _ = protocol;
    _ = bnftp;
    _ = mcp;
    _ = realm;
    _ = keystore;
}
