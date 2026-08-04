//! One loaded level: the collision grid, its rooms, and the per-mask views built on demand.
//!
//! A `Level` is the unit of "already loaded" the caller asked for. Loading an act materialises
//! every level's grid and room index once; after that a query is pure search, and the only work
//! a first-time mask does is one linear pass to build its bitset. Masks are cached, so the second
//! player query and the first missile query on the same level share everything except one bitset.

const std = @import("std");
const drlg = @import("d2-drlg");
const grid = @import("grid.zig");
const rooms = @import("rooms.zig");
const collision = @import("d2-core").collision;

pub const Point = grid.Point;

/// How a level connects to another one, in level-local subtiles on THIS level's grid.
pub const Exit = struct {
    to_level: i32,
    x: i32,
    y: i32,
    kind: Kind,

    pub const Kind = enum {
        /// A warp door / staircase: the room's warp slot resolved to a destination level.
        warp,
        /// An outdoor border bridge between two edge-to-edge levels — you walk across it.
        seam,
        /// A portal that map generation cannot see, because a quest creates it at runtime.
        /// See portals.zig.
        portal,
        /// A single teleport cast straight into the next level. Legal only where the engine's own
        /// cross-level near-room link exists AND the two cells are within the cast gate — see
        /// `World.crossLevelCast`.
        ///
        /// Like every other kind, `x`/`y` are where the transition happens ON THIS LEVEL — the cell
        /// you cast FROM, which is also this leg's last move. Where you land is the next leg's
        /// first move, in that level's own frame; convert both through `toWorld` to get the cast
        /// as the server sees it.
        teleport,
    };
};

/// A door placed on a level, in level-local subtiles.
pub const Door = struct {
    class_id: i32,
    x: i32,
    y: i32,
    /// Objects.txt `OperateFn`, which is a function INDEX rather than a name. 8 is the ordinary
    /// openable door (23 of the rows); 18 is a secret door, 29 the Act 3 slime doors, and 0 means
    /// the object has no operate function at all — Tyrael's door, which a quest opens, not you.
    /// A mover that has to decide whether it can open something needs this, not just the position.
    operate_fn: i16,

    /// True for the ordinary door a character opens by walking into it.
    pub fn isOrdinary(self: Door) bool {
        return self.operate_fn == 8;
    }
};

/// A one-way hop between two points of the SAME level: step on `at`, arrive at `to`.
///
/// The Arcane Sanctuary is the case that forces this to exist — its walkable ground is 17
/// disconnected islands and only the one holding the entry portal is reachable on foot, so
/// without the pads a router cannot leave the landing platform.
///
/// Pairing is `OBJOP_RevealAutomapArea` (0x581bf0, the Objects.txt `OperateFn` 27 handler): take
/// the pad stepped on, scan its own room's unit list for another OBJECT of the SAME class id that
/// is not itself, and failing that scan every adjacent room via `DRLGROOM_GetAdjacentRoomsList`.
/// First match wins. Each pad of a pair is its own object, so both directions exist as separate
/// entries here.
pub const Pad = struct {
    at: grid.Point,
    to: grid.Point,
    /// The Objects.txt id shared by both ends — the key the engine pairs on.
    class_id: i32,
};

pub const Level = struct {
    id: i32,
    /// World TILE origin. Levels of one act share a world frame; add `origin * 5` to a
    /// level-local subtile to get the world subtile a game client would report.
    origin_x: i32,
    origin_y: i32,
    /// Grid dimensions in SUBTILES.
    w: i32,
    h: i32,
    /// Level-local subtile collision, row-major, raw `u16` COLBIT. `collision.VOID` where no
    /// room covers. Owned.
    cells: []u16,
    rooms: rooms.RoomSet,
    /// The engine's CROSS-LEVEL near-room links for this level's rooms (`drlg.RoomLink`,
    /// harvested from `ppDrlgRoomsExNear`). `from_room` indexes `rooms.rooms`. Same-level
    /// adjacency is not in here — `RoomSet` derives that geometrically.
    links: []drlg.RoomLink,
    /// Preset units placed by the DS1s of this level, in LEVEL-LOCAL subtiles — the same frame as
    /// everything else here. `etype` 2 is an object, and then `txt_file_no` is its Objects.txt id,
    /// which is how a caller finds a waypoint, a seal or a chest to path to.
    presets: []drlg.PresetUnit,
    exits: []Exit,
    /// Paired teleporters WITHIN this level (the Arcane Sanctuary pads). Owned.
    pads: []Pad,
    /// Levels.txt `Teleport`: 0 refuses teleport outright, 1 allows it, 2 gates the destination.
    teleport: TeleportRule,

    alloc: std.mem.Allocator,
    /// Small enough that a linear scan beats a hash map — a caller uses one or two masks. Held
    /// BY POINTER, not by value: `passMap` hands the pointer out and callers keep it across other
    /// calls on the level, so growing the list must not move what they are holding.
    maps: std.ArrayListUnmanaged(*grid.PassMap) = .empty,
    /// Per-TILE representative passable subtile for the teleport search, one entry per mask in
    /// `maps` (same index). `-1` where the tile has no passable subtile. Built on demand.
    tile_reps: std.ArrayListUnmanaged([]i32) = .empty,

    pub fn deinit(self: *Level) void {
        for (self.maps.items) |m| {
            m.deinit(self.alloc);
            self.alloc.destroy(m);
        }
        self.maps.deinit(self.alloc);
        for (self.tile_reps.items) |r| if (r.len != 0) self.alloc.free(r);
        self.tile_reps.deinit(self.alloc);
        self.alloc.free(self.cells);
        self.alloc.free(self.exits);
        self.alloc.free(self.links);
        self.alloc.free(self.presets);
        self.alloc.free(self.pads);
        self.rooms.deinit(self.alloc);
        self.* = undefined;
    }

    pub inline fn tileW(self: *const Level) i32 {
        return @divTrunc(self.w, grid.SUBTILES_PER_TILE);
    }

    pub inline fn tileH(self: *const Level) i32 {
        return @divTrunc(self.h, grid.SUBTILES_PER_TILE);
    }

    /// The passability view for `mask` as a point-sized unit, built and cached on first use.
    pub fn passMap(self: *Level, mask: u16) !*grid.PassMap {
        return self.passMapFor(mask, .point);
    }

    /// The passability view for `mask` as a unit of `footprint`. A big monster is blocked by gaps
    /// a small one walks through, so the two are separate maps and separate cache entries.
    pub fn passMapFor(self: *Level, mask: u16, footprint: grid.Footprint) !*grid.PassMap {
        for (self.maps.items) |m| {
            if (m.mask == mask and m.footprint == footprint) return m;
        }
        const pm = try self.alloc.create(grid.PassMap);
        errdefer self.alloc.destroy(pm);
        pm.* = try grid.buildPassMap(self.alloc, self.cells, self.w, self.h, mask, footprint);
        errdefer pm.deinit(self.alloc);
        try self.maps.append(self.alloc, pm);
        try self.tile_reps.append(self.alloc, &.{});
        return pm;
    }

    fn maskIndex(self: *Level, mask: u16) ?usize {
        for (self.maps.items, 0..) |m, i| {
            if (m.mask == mask and m.footprint == .point) return i;
        }
        return null;
    }

    /// Per-tile landing cells for `mask`: for each level tile, the passable subtile nearest its
    /// centre, or -1. This is what makes the teleport search cheap — it searches 25x fewer nodes
    /// than the subtile grid, and every node already knows a legal place to land.
    pub fn tileReps(self: *Level, mask: u16) ![]const i32 {
        const pm = try self.passMap(mask);
        const idx = self.maskIndex(mask).?;
        if (self.tile_reps.items[idx].len != 0) return self.tile_reps.items[idx];

        const tw = self.tileW();
        const th = self.tileH();
        const reps = try self.alloc.alloc(i32, @intCast(@max(tw * th, 0)));
        errdefer self.alloc.free(reps);
        var ty: i32 = 0;
        while (ty < th) : (ty += 1) {
            var tx: i32 = 0;
            while (tx < tw) : (tx += 1) {
                const cx = tx * grid.SUBTILES_PER_TILE + 2;
                const cy = ty * grid.SUBTILES_PER_TILE + 2;
                // Radius 2 keeps the landing inside its own tile, so the tile a hop targets is
                // the tile it actually lands in and the room check stays honest.
                const p = grid.nearestPassable(pm, cx, cy, 2);
                reps[@intCast(ty * tw + tx)] = if (p) |q| @intCast(pm.index(q.x, q.y)) else -1;
            }
        }
        self.tile_reps.items[idx] = reps;
        return reps;
    }

    pub inline fn inBounds(self: *const Level, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.w and y < self.h;
    }

    /// Raw collision value at a level-local subtile, `VOID` outside the grid.
    pub fn at(self: *const Level, x: i32, y: i32) u16 {
        if (!self.inBounds(x, y)) return collision.VOID;
        return self.cells[@intCast(y * self.w + x)];
    }

    pub fn toWorld(self: *const Level, p: Point) Point {
        return .{
            .x = p.x + self.origin_x * grid.SUBTILES_PER_TILE,
            .y = p.y + self.origin_y * grid.SUBTILES_PER_TILE,
        };
    }

    /// Every preset OBJECT with this Objects.txt id, appended to `out`.
    pub fn findObjects(self: *const Level, class_id: i32, out: *std.ArrayListUnmanaged(Point), alloc: std.mem.Allocator) !void {
        for (self.presets) |u| {
            if (u.etype == 2 and u.txt_file_no == class_id) try out.append(alloc, .{ .x = u.x, .y = u.y });
        }
    }

    pub fn fromWorld(self: *const Level, p: Point) Point {
        return .{
            .x = p.x - self.origin_x * grid.SUBTILES_PER_TILE,
            .y = p.y - self.origin_y * grid.SUBTILES_PER_TILE,
        };
    }
};

/// Levels.txt `Teleport`, as `Skills_SrvDoFunc_027_Teleport` (0x5ca360) reads it:
///
///     if (!pLevelTxt->Teleport) return 0;                                    // .forbidden
///     if (pLevelTxt->Teleport == 2 &&
///         TestCollisionByCoordinates(pUnit, x, y, 0x804)) return 0;          // .gated
///     return SUNIT_RelocateUnit(...);                                        // .allowed
///
/// In 1.14d only level 0 (Null) is 0 and only Duriel's Lair (73) is 2 — everything else is 1.
pub const TeleportRule = enum(u8) {
    forbidden = 0,
    allowed = 1,
    gated = 2,

    /// The extra mask a `.gated` level applies to the destination. Read off the instruction
    /// itself: `PUSH 0x804` at 0x5ca3a6 feeds `TestCollisionByCoordinates`, and 0x804 is
    /// `COLMASK_PLAYER_FLYING` — door | missile_barrier. A cell carrying either refuses the cast.
    pub fn destinationMask(self: TeleportRule, base: u16) u16 {
        return switch (self) {
            .forbidden, .allowed => base,
            .gated => base | collision.Colmask.player_flying,
        };
    }
};
