//! d2-core public library API — the canonical Stat/Item model foundation.
//!
//! Shared by d2-sim (runtime simulation) and d2-items (drop generation): the
//! seed-RNG, the Stat enum + StatList, ItemStatCost metadata, and the wire
//! (save-file) item bit-decoder. Owning these here gives every consumer a single
//! source of truth instead of vendoring the same types twice. Pure Zig, libc-free
//! (wasm32-freestanding clean): @embedFile for data, no std.fs, no c_allocator.

const std = @import("std");

pub const rng = @import("rng.zig");
pub const stat = @import("stat.zig");
pub const unit = @import("unit.zig");
pub const skill = @import("skill.zig");
pub const itemstatcost = @import("wire/itemstatcost.zig");
pub const bitreader = @import("wire/bitreader.zig");
pub const itemtypes = @import("wire/itemtypes.zig");

// The save-file item bit-decoder namespace (parseSave / Item / ...). Named `wire`
// to match the item-package public API that re-exports it.
pub const wire = @import("wire/item.zig");

pub const Seed = rng.Seed;
pub const DoFunc = skill.DoFunc;
pub const Stat = stat.Stat;
pub const StatList = stat.StatList;
pub const Unit = unit.Unit;
pub const UnitType = unit.UnitType;
pub const Weapon = unit.Weapon;
pub const applyItemStats = unit.applyItemStats;
pub const WireItem = wire.Item;
pub const WireBitReader = bitreader.BitReader;

test {
    _ = rng;
    _ = stat;
    _ = itemstatcost;
    _ = bitreader;
    _ = itemtypes;
    _ = wire;
    _ = unit;
    _ = skill;
}
