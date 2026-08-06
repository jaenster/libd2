//! d2-world — the map of a running game: every level you loaded, and everything standing on it.
//!
//! d2-drlg generates a world; this package IS one. It owns the collision grid, the rooms, the
//! exits between levels, and the units occupying subtiles right now, and it answers the questions
//! the engine answers against them — can this unit stand here, is there line of sight, where would
//! the server actually drop this, which levels connect to this one.
//!
//!     var world = w.World.init(gpa, 0x13572468, .normal);
//!     defer world.deinit();
//!     try world.loadAct(&ctx, 0);
//!
//!     const lv = world.level(2).?;
//!     try lv.addUnit(monster_guid, .{ .x = 120, .y = 90 }, .monster(2, false, .{}));
//!     lv.passable(120, 90, w.Colmask.player_path);   // false — someone is there
//!
//! Two kinds of change, deliberately not the same operation:
//!
//! **Units** come and go constantly. `addUnit`/`moveUnit`/`removeUnit` stamp and unstamp the grid
//! exactly as `AddCollision_Type`/`RemoveCollision_Type` do, and can only ever ADD blockage — so
//! anything a consumer caches about reachability stays valid.
//!
//! **Terrain** changes a handful of times per game: a door opens, a quest barrier drops.
//! `editTerrain` rewrites the grid itself and bumps `terrain_gen`, because unlike a unit it can
//! make a cell MORE passable and join two regions that were separate.
//!
//! Searching over all of this — A*, teleport reach, the level graph — is d2-pathfinding, which
//! sits on top and caches what it needs against `terrain_gen`.

const std = @import("std");

pub const level = @import("level.zig");
pub const rooms = @import("rooms.zig");
pub const portals = @import("portals.zig");
pub const occupancy = @import("occupancy.zig");
pub const world = @import("world.zig");

/// The collision bit/mask vocabulary and the per-unit-type collision rules, re-exported from
/// d2-core so a consumer needs one import.
pub const collision = @import("d2-core").collision;
pub const unit = @import("d2-core").unit;
pub const Colbit = collision.Colbit;
pub const Colmask = collision.Colmask;
pub const UnitCollision = unit.Collision;

pub const World = world.World;
pub const Level = level.Level;
pub const Exit = level.Exit;
pub const Door = level.Door;
pub const Pad = level.Pad;
pub const Point = level.Point;
pub const Trace = level.Trace;
pub const TeleportRule = level.TeleportRule;
pub const TerrainEdit = level.Level.TerrainEdit;
pub const Rect = level.Level.Rect;
pub const Occupancy = occupancy.Occupancy;
pub const Occupant = occupancy.Occupant;
pub const FreeCoordOptions = level.FreeCoordOptions;
pub const ringSearch = level.ringSearch;

/// Subtiles per DS1 tile. Positions in this package are subtiles; rooms are tiles.
pub const SUBTILES_PER_TILE = level.SUBTILES_PER_TILE;

test {
    std.testing.refAllDecls(@This());
    _ = level;
    _ = rooms;
    _ = portals;
    _ = occupancy;
    _ = world;
}
