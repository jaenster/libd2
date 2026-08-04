//! d2-pathfinding — fast routing over Diablo II 1.14d maps.
//!
//! Give it a seed and an act, and ask for a route from anywhere to anywhere:
//!
//!     var ctx = try drlg.Ctx.init(gpa);
//!     defer ctx.deinit();
//!
//!     var world = pf.World.init(gpa, 0x13572468, .normal);
//!     defer world.deinit();
//!     try world.loadAct(&ctx, 0);                       // act 1, generated once
//!
//!     var r = try world.route(
//!         .{ .level = 3, .x = 100, .y = 100 },          // Cold Plains
//!         .{ .level = 4, .x = 200, .y = 200 },          // Stony Field
//!         .{ .teleport = true },
//!     );
//!     defer r.deinit();
//!
//! Three things it gets right that a generic grid A* does not:
//!
//! **Levels are a graph, not a grid.** Cold Plains to Stony Field crosses an area border, and
//! Stony Field to the Arcane Sanctuary crosses six areas and two portals. `route` searches the
//! level graph first, then paths inside each level, and returns one leg per level with the exit
//! you take out of it.
//!
//! **Teleport is bounded by rooms, not by distance.** The server never checks how far you
//! teleported — `SUNIT_RelocateUnit` resolves the destination room and fails if it is not your
//! room or one adjacent to it. The famous "39 is safe" number is what that rule works out to on
//! standard 8x8-tile rooms; on smaller dungeon rooms the real reach is shorter. This package
//! models the rooms, so it is right in both cases. See rooms.zig and teleport.zig.
//!
//! **Collision is a mask, not a boolean.** Every search is `cell & mask == 0`, so a walking
//! player, a walking monster and a missile in flight are the same code with three different
//! masks — missiles pass objects and doors that stop a player, and stop at missile barriers a
//! player walks straight through. The vocabulary lives in `d2-core` (`collision.Colmask`) so the
//! producer of a grid and its consumers cannot drift apart.
//!
//! Speed comes from loading once and then never allocating in the hot path: per-mask passability
//! bitsets, connected-component labels that reject an unreachable goal without searching, and A*
//! scratch that is generation-stamped instead of cleared.

const std = @import("std");

pub const grid = @import("grid.zig");
pub const rooms = @import("rooms.zig");
pub const astar = @import("astar.zig");
pub const teleport = @import("teleport.zig");
pub const portals = @import("portals.zig");
pub const level = @import("level.zig");
pub const world = @import("world.zig");

/// The collision bit/mask vocabulary, re-exported from d2-core so a consumer needs one import.
pub const collision = @import("d2-core").collision;
pub const Colbit = collision.Colbit;
pub const Colmask = collision.Colmask;

pub const World = world.World;
pub const Route = world.Route;
pub const Leg = world.Leg;
pub const Move = world.Move;
pub const Pos = world.Pos;
pub const Options = world.Options;
pub const Level = level.Level;
pub const Exit = level.Exit;
pub const TeleportRule = level.TeleportRule;
pub const Point = grid.Point;
pub const Pather = astar.Pather;
pub const WallAversion = astar.WallAversion;
pub const PassMap = grid.PassMap;

/// Subtiles per DS1 tile. Positions in this package are subtiles; rooms are tiles.
pub const SUBTILES_PER_TILE = grid.SUBTILES_PER_TILE;

/// The furthest a single movement command may target — walk, run or cast alike. See grid.zig.
pub const ENGINE_MAX_COMMAND_RANGE = grid.ENGINE_MAX_COMMAND_RANGE;
/// What a mover should actually cap steps at: under the gate, with margin for the server's lagging
/// view of your position. See grid.zig.
pub const SAFE_COMMAND_STEP = grid.SAFE_COMMAND_STEP;

test {
    _ = @import("tests.zig");
    _ = grid;
    _ = rooms;
    _ = astar;
    _ = teleport;
    _ = portals;
    _ = level;
    _ = world;
}
