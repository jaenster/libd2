//! libd2 — a clean-room Diablo II 1.14d in Zig, as one library.
//!
//! Everything lives under `packages/`, layered by what it is rather than by who wrote it first,
//! and this file is the door: one dependency, one import, every layer reachable by name.
//!
//!     const libd2 = @import("libd2");
//!     const level = try libd2.drlg.generate(...);
//!     const hash  = libd2.bnet.xsha1.passwordHash("secret");
//!
//! Naming a namespace here costs nothing until you use it. Zig analyses a declaration only when
//! something references it, so a consumer that touches `libd2.bnet` never compiles the DRLG, and
//! the excel tables are not embedded in a binary that never asks for them. That is what lets the
//! whole library be one module instead of fourteen names a consumer has to know in advance.
//!
//! The per-package modules (`d2-drlg`, `d2-core`, …) still exist and still work; each package
//! keeps its own build.zig so it can be built and tested alone. This is the surface, not the
//! structure.
//!
//! Layering, so a change lands in the right place — the test is "does it stand alone from the
//! game?": yes goes to `util`, no goes to the domain package. Dependencies point INWARD.
//!
//!   foundation   `util` (domain-free mechanics)   `data` (the excel tables)
//!   leaves       `formats` (on-disk parsers, zero-dep)
//!   domain       `core` (Seed, Stat, Unit, the Fog pool)  `item`  `save`
//!   world        `drlg` (map generation)  `world` (the live map)  `pathfinding`  `render`
//!   protocol     `bnet` (Battle.net: before a game exists)  `net` (D2GS: once it does)
//!   runtime      `game` (the simulation)  `client` (what a client has been told)

/// Domain-free mechanics that happen to be used by a game: bit reader/writer, the Huffman codec.
pub const util = @import("d2-util");

/// The real 1.14d Blizzard excel tables, parsed once and shared.
pub const data = @import("d2-data");

/// Self-contained parsers for the on-disk formats: ds1, dt1, dc6, dcc, cof, and the .d2s header.
pub const formats = @import("d2-formats");

/// D2 domain primitives: the seed LCG, Stat, Unit and its enums, the Fog memory pool.
pub const core = @import("d2-core");

/// Faithful item generation — the three seed streams, affixes, treasure classes.
pub const item = @import("d2-item");

/// The `.d2s` character save: the marker-delimited sections above the header.
pub const save = @import("d2-save");

/// Map generation: the clean-room port of the 1.14d DRLG, byte-exact against the engine.
pub const drlg = @import("d2-drlg");

/// The live map of a running game — every level loaded and everything standing on it.
pub const world = @import("d2-world");

/// Routing over those maps, walking and teleporting, across levels.
pub const pathfinding = @import("d2-pathfinding");

/// The automap and the DT1 tile-art render layer.
pub const render = @import("d2-render");

/// Battle.net, before a game exists: BNCS logon and chat, MCP, BNFTP, and the hashes they carry.
pub const bnet = @import("d2-bnet");

/// The D2GS game protocol, once a game does exist: the server<->client packet layer.
pub const net = @import("d2-net");

/// The game simulation itself.
pub const game = @import("d2-game");

/// The game as a client knows it: what the server has told you so far.
pub const client = @import("d2-client");

test {
    // Each package is tested by its own artifact (`zig build test` runs all of them); referencing
    // them here only proves the umbrella resolves every name it advertises.
    _ = util;
    _ = data;
    _ = formats;
    _ = core;
    _ = item;
    _ = save;
    _ = drlg;
    _ = world;
    _ = pathfinding;
    _ = render;
    _ = bnet;
    _ = net;
    _ = game;
    _ = client;
}
