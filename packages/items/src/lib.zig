//! d2-items public library API — faithful D2 1.14d item-generation port.
//!
//! Scope: seed-driven DROP GENERATION — treasure-class resolution, drop-time
//! quality (with magic find), magic/rare affix selection, sockets. All roll-exact
//! to the reconstructed 1.14d Game.exe (Ghidra session 62fbfe69); every ported
//! function cites its address in its module doc-comment.
//!
//! Follow-ups (stubbed with TODOs): set / unique / crafted / runeword affixes,
//! and the item-type-token class roll (ITEMDROP_RollItemClassByLevel, which needs
//! the engine's compiled unified Items array).

const std = @import("std");

pub const rng = @import("rng.zig");
pub const txt = @import("txt.zig");
pub const tables = @import("tables.zig");
pub const model = @import("model.zig");
pub const itemtype = @import("itemtype.zig");
pub const quality = @import("quality.zig");
pub const treasure = @import("treasure.zig");
pub const affix = @import("affix.zig");
pub const sockets = @import("sockets.zig");
pub const item = @import("item.zig");
pub const dc6 = @import("dc6.zig");
pub const png = @import("png.zig");
pub const graphic = @import("graphic.zig");
pub const render = @import("render.zig");

pub const Seed = rng.Seed;
pub const Tables = tables.Tables;
pub const TCSet = treasure.TCSet;
pub const Quality = model.Quality;
pub const Drop = model.Drop;
pub const rollDrop = item.rollDrop;

test {
    _ = rng;
    _ = txt;
    _ = tables;
    _ = model;
    _ = itemtype;
    _ = quality;
    _ = treasure;
    _ = affix;
    _ = sockets;
    _ = item;
    _ = dc6;
    _ = png;
    _ = graphic;
    _ = render;
}
