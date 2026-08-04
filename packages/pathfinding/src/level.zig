//! One loaded level: the collision grid, its rooms, and the per-mask views built on demand.
//!
//! A `Level` is the unit of "already loaded" the caller asked for. Loading an act materialises
//! every level's grid and room index once; after that a query is pure search, and the only work
//! a first-time mask does is one linear pass to build its bitset. Masks are cached, so the second
//! player query and the first missile query on the same level share everything except one bitset.

const std = @import("std");
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
    };
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
    exits: []Exit,
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
        self.rooms.deinit(self.alloc);
        self.* = undefined;
    }

    pub inline fn tileW(self: *const Level) i32 {
        return @divTrunc(self.w, grid.SUBTILES_PER_TILE);
    }

    pub inline fn tileH(self: *const Level) i32 {
        return @divTrunc(self.h, grid.SUBTILES_PER_TILE);
    }

    /// The passability view for `mask`, built and cached on first use.
    pub fn passMap(self: *Level, mask: u16) !*grid.PassMap {
        for (self.maps.items) |m| {
            if (m.mask == mask) return m;
        }
        const pm = try self.alloc.create(grid.PassMap);
        errdefer self.alloc.destroy(pm);
        pm.* = try grid.buildPassMap(self.alloc, self.cells, self.w, self.h, mask);
        errdefer pm.deinit(self.alloc);
        try self.maps.append(self.alloc, pm);
        try self.tile_reps.append(self.alloc, &.{});
        return pm;
    }

    fn maskIndex(self: *Level, mask: u16) ?usize {
        for (self.maps.items, 0..) |m, i| {
            if (m.mask == mask) return i;
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

    pub fn fromWorld(self: *const Level, p: Point) Point {
        return .{
            .x = p.x - self.origin_x * grid.SUBTILES_PER_TILE,
            .y = p.y - self.origin_y * grid.SUBTILES_PER_TILE,
        };
    }
};

/// Levels.txt `Teleport`, as `Skills_SrvDoFunc_027_Teleport` (0x5ca360) reads it:
///
///     if (!pLevelTxt->Teleport) return 0;                              // .forbidden
///     if (pLevelTxt->Teleport == 2 && TestCollisionByCoordinates(...))  // .los_gated
///         return 0;
///     return SUNIT_RelocateUnit(...);                                   // .allowed
///
/// In 1.14d only level 0 (Null) is 0 and only Duriel's Lair (73) is 2 — everything else is 1.
pub const TeleportRule = enum(u8) {
    forbidden = 0,
    allowed = 1,
    los_gated = 2,

    /// The extra mask a `.los_gated` level applies to the destination. `TestCollisionByCoordinates`
    /// is called with the line-of-sight flags, so a cell carrying them refuses the cast.
    pub fn destinationMask(self: TeleportRule, base: u16) u16 {
        return switch (self) {
            .forbidden, .allowed => base,
            .los_gated => base | collision.Colmask.line_of_sight,
        };
    }
};
