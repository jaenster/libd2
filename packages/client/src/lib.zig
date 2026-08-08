//! d2-client — the game as a client knows it: what the server has told you so far.
//!
//! `d2-net` decodes one packet. This package remembers all of them: feed it the server->client
//! stream and it keeps the world that stream describes — which level you are on and its map seed,
//! where every player, monster, object, warp and dropped item is, and what your own character's
//! stats and life are.
//!
//!     var w = client.World.init(gpa);
//!     defer w.deinit();
//!     while (nextPacket()) |p| w.apply(p);
//!
//!     if (try w.waypoint()) |wp| {           // the waypoint on this level, by Objects.txt class
//!         std.debug.print("waypoint at ({d},{d})\n", .{ wp.x, wp.y });
//!     }
//!
//! No sockets, no threads, no rendering: a caller owns the connection and hands over bytes. That
//! is what makes the same model usable by a bot, a proxy, a capture analyser and a test.

const std = @import("std");

pub const world = @import("world.zig");
pub const objects = @import("objects.zig");
/// Acting on the world: range-gated movement and the command encoders that go with it.
pub const play = @import("play.zig");

pub const World = world.World;
pub const Unit = world.Unit;
pub const UnitType = world.UnitType;
pub const Item = world.Item;
pub const Actor = play.Actor;
pub const Point = play.Point;

test {
    _ = world;
    _ = objects;
    _ = play;
}
