//! d2-core public library API — the canonical Stat/Item model foundation.
//!
//! Shared by d2-game (runtime simulation), d2-item (drop generation) and d2-drlg
//! (map generation): the seed-RNG, the Stat enum + StatList, ItemStatCost metadata,
//! the wire (save-file) item bit-decoder, and the Fog::Memory pool allocator.
//! Owning these here gives every consumer a single source of truth instead of
//! vendoring the same types twice. Pure Zig, libc-free (wasm32-freestanding
//! clean): @embedFile for data, no std.fs, no c_allocator.

const std = @import("std");

pub const rng = @import("rng.zig");
pub const collision = @import("collision.zig");
pub const stat = @import("stat.zig");
pub const unit = @import("unit.zig");
pub const skill = @import("skill.zig");
pub const object = @import("object.zig");
pub const itemstatcost = @import("wire/itemstatcost.zig");
pub const bitreader = @import("wire/bitreader.zig");
pub const itemtypes = @import("wire/itemtypes.zig");

// The save-file item bit-decoder namespace (parseSave / Item / ...). Named `wire`
// to match the item-package public API that re-exports it.
pub const wire = @import("wire/item.zig");

// A faithful replica of the engine's `Fog::Memory` segregated-slab pool allocator
// (fixed size-classes, bitmap slot reuse, wholesale teardown). Engine-agnostic; the
// DRLG runs every level's generation on one of these so `Level.deinit` is a bulk free.
pub const memory = @import("memory.zig");

pub const Seed = rng.Seed;
pub const DoFunc = skill.DoFunc;
pub const OperateFn = object.OperateFn;
pub const Colbit = collision.Colbit;
pub const Colmask = collision.Colmask;
pub const CollisionShape = collision.Shape;
pub const CollisionSize = collision.Size;
pub const CollisionStamp = collision.Stamp;
pub const UnitCollision = unit.Collision;
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
    _ = collision;
    _ = stat;
    _ = memory;
    _ = itemstatcost;
    _ = bitreader;
    _ = itemtypes;
    _ = wire;
    _ = unit;
    _ = skill;
    _ = object;
}
