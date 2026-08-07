//! Acting on the world: turning "go there" and "use that" into the bytes the server accepts.
//!
//! `world.zig` is what the server told you. This is the other direction — and it belongs here
//! rather than in each bot, because the rules it encodes are the server's, not any bot's:
//!
//! **A move command is range-gated.** `SCMD_0x01_WalkToLocation` and friends run the packet
//! through `CheckIfCoordsAreInRange(pUnit, 0x32, x, y)` @0x548ef0, which rejects the command when
//! either axis differs by more than 50 subtiles — a per-axis (Chebyshev) test, not a radius. The
//! gate measures from the SERVER's idea of where you are, which lags yours, so aiming at exactly
//! 50 is how a bot silently loses commands. `SAFE_STEP` leaves margin.
//!
//! Nothing here allocates, blocks or touches a socket: every call hands back bytes for the caller
//! to write. That keeps the same code usable from a bot, a test, and a scripting binding.

const std = @import("std");
const clt = @import("d2-net").clt;
const world_mod = @import("world.zig");
const World = world_mod.World;
const UnitType = world_mod.UnitType;

/// The engine's own limit: `CheckIfCoordsAreInRange(pUnit, 0x32, ...)`. Either axis beyond this
/// and the command is refused with SERVERSTATUS_BAD_TARGET.
pub const MAX_COMMAND_RANGE: i32 = 0x32;

/// What to actually aim for. Under the gate with room for the server's lagging view of you.
pub const SAFE_STEP: i32 = 40;

pub const Point = struct { x: u16, y: u16 };

/// Clamp `to` into a point at most `max` subtiles from `from` on either axis, along the line
/// between them. Chebyshev, because that is the test the server applies.
pub fn clampStep(from: Point, to: Point, max: i32) Point {
    var dx: i32 = @as(i32, to.x) - @as(i32, from.x);
    var dy: i32 = @as(i32, to.y) - @as(i32, from.y);
    const reach = @max(@abs(dx), @abs(dy));
    if (reach > max) {
        // Scale by the dominant axis so the step keeps its direction.
        dx = @divTrunc(dx * max, @as(i32, @intCast(reach)));
        dy = @divTrunc(dy * max, @as(i32, @intCast(reach)));
    }
    return .{
        .x = @intCast(@max(0, @as(i32, from.x) + dx)),
        .y = @intCast(@max(0, @as(i32, from.y) + dy)),
    };
}

/// Chebyshev distance — the metric the range gate uses.
pub fn distance(a: Point, b: Point) i32 {
    const dx = @abs(@as(i32, a.x) - @as(i32, b.x));
    const dy = @abs(@as(i32, a.y) - @as(i32, b.y));
    return @intCast(@max(dx, dy));
}

/// Acting on a world. Holds no state of its own: the world is the state.
pub const Actor = struct {
    world: *World,
    /// Aim this far per command. Lower it if the server is rejecting moves.
    step: i32 = SAFE_STEP,

    pub const Error = error{NoPlayerPosition};

    pub fn position(self: *const Actor) ?Point {
        const p = self.world.playerPos() orelse return null;
        return .{ .x = p.x, .y = p.y };
    }

    /// Are we within `tolerance` subtiles of `target`?
    pub fn arrived(self: *const Actor, target: Point, tolerance: i32) bool {
        const p = self.position() orelse return false;
        return distance(p, target) <= tolerance;
    }

    /// The next command to send to get closer to `target`, or null once we are within
    /// `tolerance`. `run` picks RunToLocation (0x03) over WalkToLocation (0x01).
    ///
    /// This is a STEP, not a path: it heads straight at the target, bounded by the range gate.
    /// It crosses open ground correctly and will happily walk into a wall — routing around
    /// terrain is d2-pathfinding's job, and a caller that has a route feeds its waypoints here
    /// one at a time.
    pub fn moveToward(self: *const Actor, target: Point, run: bool, out: []u8, tolerance: i32) Error!?[]u8 {
        const from = self.position() orelse return error.NoPlayerPosition;
        if (distance(from, target) <= tolerance) return null;
        const aim = clampStep(from, target, self.step);
        return if (run)
            clt.RunToLocation.encode(.{ .x = aim.x, .y = aim.y }, out)
        else
            clt.WalkToLocation.encode(.{ .x = aim.x, .y = aim.y }, out);
    }

    /// Interact with a unit — open a door, take a waypoint, talk to an NPC, enter a portal.
    pub fn interact(_: *const Actor, unit_type: UnitType, guid: u32, out: []u8) []u8 {
        return clt.InteractWithEntity.encode(
            .{ .unit_type = @intFromEnum(unit_type), .guid = guid },
            out,
        );
    }

    /// Attack a unit with the left-hand skill.
    pub fn attack(_: *const Actor, unit_type: UnitType, guid: u32, out: []u8) []u8 {
        return clt.LeftSkillOnEntity.encode(
            .{ .unit_type = @intFromEnum(unit_type), .unit_guid = guid },
            out,
        );
    }

    /// Cast the right-hand skill at a spot (Teleport is the interesting one).
    pub fn castAt(self: *const Actor, target: Point, out: []u8) Error![]u8 {
        const from = self.position() orelse return error.NoPlayerPosition;
        const aim = clampStep(from, target, self.step);
        return clt.RightSkillOnLocation.encode(.{ .x = aim.x, .y = aim.y }, out);
    }

    /// Pick an item up off the floor.
    pub fn pickUp(_: *const Actor, guid: u32, out: []u8) []u8 {
        return clt.InteractWithEntityEx.encode(
            .{ .unit_type = @intFromEnum(UnitType.item), .unit_guid = guid },
            out,
        );
    }

    /// The largest command buffer any of these needs.
    pub const MAX_COMMAND: usize = 16;
};

const testing = std.testing;

test "a step is clamped per-axis, the way the server's gate measures" {
    const from = Point{ .x = 1000, .y = 1000 };
    // Straight along one axis: clamped to exactly the step.
    const far = clampStep(from, .{ .x = 2000, .y = 1000 }, SAFE_STEP);
    try testing.expectEqual(@as(u16, 1000 + @as(u16, @intCast(SAFE_STEP))), far.x);
    try testing.expectEqual(@as(u16, 1000), far.y);
    try testing.expect(distance(from, far) <= MAX_COMMAND_RANGE);

    // Diagonal: direction preserved, still inside the gate.
    const diag = clampStep(from, .{ .x = 2000, .y = 2000 }, SAFE_STEP);
    try testing.expectEqual(diag.x - 1000, diag.y - 1000);
    try testing.expect(distance(from, diag) <= MAX_COMMAND_RANGE);

    // Already close: left alone.
    const near = clampStep(from, .{ .x = 1005, .y = 1003 }, SAFE_STEP);
    try testing.expectEqual(@as(u16, 1005), near.x);
    try testing.expectEqual(@as(u16, 1003), near.y);
}

test "moveToward emits a real command until it arrives, then stops" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    var mk = [_]u8{0} ** 26;
    mk[0] = 0x59;
    std.mem.writeInt(u32, mk[1..5], 0x10, .little);
    std.mem.writeInt(u16, mk[22..24], 1000, .little);
    std.mem.writeInt(u16, mk[24..26], 1000, .little);
    w.apply(&mk);

    const actor = Actor{ .world = &w };
    var buf: [Actor.MAX_COMMAND]u8 = undefined;

    const cmd = (try actor.moveToward(.{ .x = 1500, .y = 1000 }, false, &buf, 3)).?;
    try testing.expectEqual(clt.WalkToLocation.OPCODE, cmd[0]);
    const decoded = try clt.WalkToLocation.decode(cmd);
    try testing.expectEqual(@as(u16, 1000 + @as(u16, @intCast(SAFE_STEP))), decoded.x);

    // Running uses a different opcode, same geometry.
    const runcmd = (try actor.moveToward(.{ .x = 1500, .y = 1000 }, true, &buf, 3)).?;
    try testing.expectEqual(clt.RunToLocation.OPCODE, runcmd[0]);

    // Within tolerance there is nothing to send.
    try testing.expect((try actor.moveToward(.{ .x = 1002, .y = 1000 }, false, &buf, 3)) == null);
    try testing.expect(actor.arrived(.{ .x = 1002, .y = 1000 }, 3));
}

test "acting with no known player position is an error, not a bad command" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const actor = Actor{ .world = &w };
    var buf: [Actor.MAX_COMMAND]u8 = undefined;
    try testing.expectError(error.NoPlayerPosition, actor.moveToward(.{ .x = 5, .y = 5 }, false, &buf, 1));
}
