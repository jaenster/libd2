//! The room layer — which exists here for one reason: it is the SECOND of the two gates a
//! teleport has to clear.
//!
//! The first gate is a plain distance check, but it lives in the packet handler rather than in
//! the skill (`CheckIfCoordsAreInRange` 0x548ef0, Chebyshev 50 subtiles — see teleport.zig). This
//! file is about the other one, which is topological.
//!
//! The skill code itself has no distance check. `Skills_SrvDoFunc_027_Teleport`
//! (0x5ca360) reads the cursor position, checks the level allows teleport at all, and calls
//! `SUNIT_RelocateUnit` (0x554ea0) with a null room. That resolves the destination room by:
//!
//!     DRLGROOM_FindBetterNearbyRoom(NULL, x, y)        -> NULL immediately (null-room guard)
//!     DRLGROOM_FindBetterNearbyRoom(currentRoom, x, y) -> the current room if it contains (x,y),
//!                                                          else the first room in the current
//!                                                          room's ADJACENT LIST that contains it,
//!                                                          else NULL -> teleport fails.
//!
//! So this gate is topological: **you may land anywhere inside your own room or inside a room
//! adjacent to it.** On a standard 8x8-tile (40x40-subtile) outdoor room that is looser than the
//! 50-subtile distance gate and never binds. On small dungeon rooms it is the binding one — with
//! 2x2-tile rooms the reachable set can end barely 31 subtiles away — which is why this package
//! models the rooms instead of trusting distance alone.
//!
//! "Adjacent" is `DefineRoomsNear` (0x66bc20), which walks every OTHER ROOM OF THE SAME LEVEL and
//! keeps the ones whose bounding boxes are within 6 tiles on BOTH axes:
//!
//!     gapX = (self.x < other.x) ? other.x - self.w - self.x : self.x - other.w - other.x
//!     gapY = likewise
//!     near = gapX < 6 and gapY < 6
//!
//! The gap is signed, so overlapping/touching rooms come out negative and a room is near itself.
//!
//! Cross-level adjacency: `DefineRoomsNear` is same-level only, but it is not the whole story.
//! `DRLGROOMEX_InitNearRoomsAndVisTiles` (0x66c370) afterwards walks the room's set vis slots
//! (`eRoomExFlags & 0xff0`) and calls `DRLGROOMEX_LinkNearRoomsByVis` (0x66c220), which resolves
//! the destination LEVEL and appends rooms from THAT level's chain
//! (`DRLGROOMEX_LinkNearRoomByDirection` 0x66be80 ->
//! `DRLGROOMEX_ResizeArrayAndAddNewNearRoom` 0x66bda0). So a room CAN be adjacent to a room of
//! another level — but only across a warp/vis link, never by plain geometry.
//!
//! On top of that, the runtime list is activation-filtered: `DRLGROOM_UpdateRoomsNearAndCount`
//! (0x619800) builds `pRoom->ppRoomList` through `GetRealRoomsNearCount` (0x66bd00), which keeps
//! only near-RoomEx entries whose `->pRoom` is non-null — i.e. rooms currently allocated
//! server-side.
//!
//! Two consequences this package acts on:
//!   * Crossing a PURE SEAM border (two outdoor levels adjacent by geometry with no vis link
//!     between them — Blood Moor to Cold Plains, and every other overworld border) can never be
//!     teleported: those rooms are never in each other's lists. It is a walk, and `world.zig`
//!     routes it as one.
//!   * Crossing a WARP-LINKED border can be teleported, and `world.zig` will do it behind
//!     `Options.teleport_across_levels` (off by default, because it needs the destination room to
//!     be loaded — moot when the whole act is resident). `d2-drlg` supplies the actual link pairs;
//!     the distance gate is then applied in WORLD coordinates, which is what rules out the many
//!     linked-but-distant pairs.

const std = @import("std");

/// `DefineRoomsNear`'s threshold, in tiles.
pub const NEAR_GAP_TILES: i32 = 6;

/// A room's bounding box in LEVEL-LOCAL TILES. d2-drlg hands out world tiles; the loader rebases
/// them so a room, the collision grid and a position all live in one frame per level.
pub const Room = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub inline fn contains(self: Room, tx: i32, ty: i32) bool {
        return tx >= self.x and ty >= self.y and tx < self.x + self.w and ty < self.y + self.h;
    }
};

/// `DefineRoomsNear` (0x66bc20), verbatim: the signed per-axis box gap, near when both are < 6.
pub fn areNear(a: Room, b: Room) bool {
    const gap_x = if (a.x < b.x) b.x - a.w - a.x else a.x - b.w - b.x;
    const gap_y = if (a.y < b.y) b.y - a.h - a.y else a.y - b.h - b.y;
    return gap_x < NEAR_GAP_TILES and gap_y < NEAR_GAP_TILES;
}

pub const NO_ROOM: u16 = 0xFFFF;

/// One level's rooms plus the two lookups the teleport search hammers: tile -> room, and
/// room -> its near set. Both are built once at load and then read-only, so a teleport hop is
/// two array indexes and a small linear scan, not a geometry test against every room.
pub const RoomSet = struct {
    rooms: []Room = &.{},
    /// Level-local TILE grid (`tw` x `th`) of room ids; `NO_ROOM` where no room covers the tile.
    at: []u16 = &.{},
    tw: i32 = 0,
    th: i32 = 0,
    /// Flattened near lists: room `i` owns `near[near_start[i]..near_start[i + 1]]`. Includes the
    /// room itself, exactly as the engine's list does.
    near: []u16 = &.{},
    near_start: []u32 = &.{},

    pub fn deinit(self: *RoomSet, alloc: std.mem.Allocator) void {
        alloc.free(self.rooms);
        alloc.free(self.at);
        alloc.free(self.near);
        alloc.free(self.near_start);
        self.* = undefined;
    }

    /// Room covering a level-local SUBTILE position, or null in the gaps between rooms.
    pub fn atSubtile(self: *const RoomSet, sx: i32, sy: i32) ?u16 {
        return self.atTile(@divFloor(sx, 5), @divFloor(sy, 5));
    }

    pub fn atTile(self: *const RoomSet, tx: i32, ty: i32) ?u16 {
        if (tx < 0 or ty < 0 or tx >= self.tw or ty >= self.th) return null;
        const id = self.at[@intCast(ty * self.tw + tx)];
        return if (id == NO_ROOM) null else id;
    }

    pub fn nearOf(self: *const RoomSet, room: u16) []const u16 {
        return self.near[self.near_start[room]..self.near_start[room + 1]];
    }

    /// Is `to` reachable from `from` in one teleport cast? (`from == to` included, since the
    /// engine's near list contains the room itself.)
    pub fn canTeleportBetween(self: *const RoomSet, from: u16, to: u16) bool {
        for (self.nearOf(from)) |n| {
            if (n == to) return true;
        }
        return false;
    }
};

/// Build the room lookups for one level. `rooms` are level-local tile boxes; `tw`/`th` are the
/// level's tile dimensions. The near lists are O(n^2) to build, which is nothing — a level has
/// tens to a few hundred rooms, and it happens once per act load.
pub fn build(alloc: std.mem.Allocator, rooms_in: []const Room, tw: i32, th: i32) !RoomSet {
    const rooms = try alloc.dupe(Room, rooms_in);
    errdefer alloc.free(rooms);

    const at = try alloc.alloc(u16, @intCast(@max(tw, 0) * @max(th, 0)));
    errdefer alloc.free(at);
    @memset(at, NO_ROOM);
    for (rooms, 0..) |r, i| {
        var ty = @max(r.y, 0);
        const y_end = @min(r.y + r.h, th);
        while (ty < y_end) : (ty += 1) {
            var tx = @max(r.x, 0);
            const x_end = @min(r.x + r.w, tw);
            while (tx < x_end) : (tx += 1) at[@intCast(ty * tw + tx)] = @intCast(i);
        }
    }

    var near: std.ArrayListUnmanaged(u16) = .empty;
    errdefer near.deinit(alloc);
    const near_start = try alloc.alloc(u32, rooms.len + 1);
    errdefer alloc.free(near_start);

    for (rooms, 0..) |r, i| {
        near_start[i] = @intCast(near.items.len);
        for (rooms, 0..) |o, j| {
            if (areNear(r, o)) try near.append(alloc, @intCast(j));
        }
    }
    near_start[rooms.len] = @intCast(near.items.len);

    return .{
        .rooms = rooms,
        .at = at,
        .tw = tw,
        .th = th,
        .near = try near.toOwnedSlice(alloc),
        .near_start = near_start,
    };
}

test "the near rule matches DefineRoomsNear on the standard 8x8 outdoor grid" {
    // Three rooms in a row, 8 tiles each: A at 0, B at 8, C at 16.
    const a = Room{ .x = 0, .y = 0, .w = 8, .h = 8 };
    const b = Room{ .x = 8, .y = 0, .w = 8, .h = 8 };
    const c = Room{ .x = 16, .y = 0, .w = 8, .h = 8 };
    try std.testing.expect(areNear(a, a)); // a room is near itself
    try std.testing.expect(areNear(a, b)); // gap 0
    try std.testing.expect(!areNear(a, c)); // gap 8 -> two rooms over is out of reach
    try std.testing.expect(areNear(b, c));
    try std.testing.expect(areNear(c, a) == areNear(a, c)); // symmetric
}

test "40 is the largest universally safe teleport distance on 8x8 rooms" {
    // Standing at the far edge of room A (subtile 39), the nearest subtile that is NOT in A or a
    // room adjacent to A is the first subtile of room C, at 80 — distance 41. Every subtile
    // within 40 is still inside A or B. That is where the folklore number comes from.
    const a = Room{ .x = 0, .y = 0, .w = 8, .h = 8 };
    const c = Room{ .x = 16, .y = 0, .w = 8, .h = 8 };
    try std.testing.expect(!areNear(a, c));
    const stand_x: i32 = 39; // last subtile of A
    const first_unreachable_x: i32 = c.x * 5; // 80
    try std.testing.expectEqual(@as(i32, 41), first_unreachable_x - stand_x);
}

test "small rooms shrink the safe distance below 40" {
    // 2x2-tile rooms: A [0,2), and E at [8,10) is already out of reach (gap 6), so its first
    // subtile at 40 is unreachable from subtile 9 — only 31 away. A fixed 40-subtile rule would
    // have called that a legal cast.
    const a = Room{ .x = 0, .y = 0, .w = 2, .h = 2 };
    const e = Room{ .x = 8, .y = 0, .w = 2, .h = 2 };
    try std.testing.expect(!areNear(a, e));
    try std.testing.expectEqual(@as(i32, 31), e.x * 5 - 9);
}

test "RoomSet resolves tiles and near sets" {
    const alloc = std.testing.allocator;
    const rooms = [_]Room{
        .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .{ .x = 8, .y = 0, .w = 8, .h = 8 },
        .{ .x = 16, .y = 0, .w = 8, .h = 8 },
    };
    var rs = try build(alloc, &rooms, 24, 8);
    defer rs.deinit(alloc);

    try std.testing.expectEqual(@as(?u16, 0), rs.atSubtile(39, 0));
    try std.testing.expectEqual(@as(?u16, 1), rs.atSubtile(40, 0));
    try std.testing.expect(rs.canTeleportBetween(0, 1));
    try std.testing.expect(!rs.canTeleportBetween(0, 2));
    try std.testing.expect(rs.canTeleportBetween(0, 0));
}
