//! The per-level search caches: everything d2-pathfinding derives from a `world.Level` and keeps.
//!
//! A `Level` answers collision questions directly, against terrain and occupants, with nothing in
//! the way — that is the right shape for a game asking "can this unit stand here". It is the wrong
//! shape for A*, which asks the same question millions of times per query. So the search keeps its
//! own views: a passability bitset per (mask, footprint), the connected-component labels that
//! reject an unreachable goal without searching, a distance transform for wall aversion, and the
//! per-tile landing cells the teleport search hops over.
//!
//! All of it is derived from `Level.cells` and therefore invalid the moment terrain changes, which
//! is what `Level.terrain_gen` is for: one compare on the way in, and a door opening somewhere
//! rebuilds what it has to. UNITS never invalidate any of it — occupancy only adds blockage, and
//! `PassMap.passableAt` consults the level's occupants live. That asymmetry is the whole reason the
//! two kinds of change are different operations on `Level`.

const std = @import("std");
const wd = @import("d2-world");
const grid = @import("grid.zig");

pub const Point = grid.Point;

/// One level's cached views. Held by pointer by the `Router`, because a `PassMap` handed out here
/// stays valid across other calls on the same level.
pub const Nav = struct {
    alloc: std.mem.Allocator,
    lv: *wd.Level,
    /// Small enough that a linear scan beats a hash map — a caller uses one or two masks. By
    /// pointer, so growing the list does not move what a caller is already holding.
    maps: std.ArrayListUnmanaged(*grid.PassMap) = .empty,
    /// Per-TILE representative passable subtile for the teleport search, one entry per mask in
    /// `maps` (same index). `-1` where the tile has no passable subtile. Built on demand.
    tile_reps: std.ArrayListUnmanaged([]i32) = .empty,

    pub fn init(alloc: std.mem.Allocator, lv: *wd.Level) Nav {
        return .{ .alloc = alloc, .lv = lv };
    }

    pub fn deinit(self: *Nav) void {
        for (self.maps.items) |m| {
            m.deinit(self.alloc);
            self.alloc.destroy(m);
        }
        self.maps.deinit(self.alloc);
        self.dropTileReps();
        self.tile_reps.deinit(self.alloc);
        self.* = undefined;
    }

    fn dropTileReps(self: *Nav) void {
        for (self.tile_reps.items) |*r| {
            if (r.len == 0) continue;
            self.alloc.free(r.*);
            r.* = &.{};
        }
    }

    /// The passability view for `mask` as a point-sized unit, built and cached on first use.
    pub fn passMap(self: *Nav, mask: u16) !*grid.PassMap {
        return self.passMapFor(mask, .point);
    }

    /// The passability view for `mask` as a unit of `footprint`. A big monster is blocked by gaps a
    /// small one walks through, so the two are separate maps and separate cache entries.
    pub fn passMapFor(self: *Nav, mask: u16, footprint: grid.Footprint) !*grid.PassMap {
        const gen = self.lv.terrain_gen;
        for (self.maps.items) |m| {
            if (m.mask != mask or m.footprint != footprint) continue;
            if (m.terrain_gen != gen) {
                // The whole grid rather than the changed rectangle: a `Nav` is not told WHERE the
                // edit was, only that there was one. Terrain changes a handful of times per game,
                // so one pass is the right trade against threading a dirty rect through everything.
                m.repatch(0, 0, self.lv.w - 1, self.lv.h - 1);
                m.terrain_gen = gen;
                self.dropTileReps();
            }
            return m;
        }
        const pm = try self.alloc.create(grid.PassMap);
        errdefer self.alloc.destroy(pm);
        pm.* = try grid.buildPassMap(self.alloc, self.lv, mask, footprint);
        errdefer pm.deinit(self.alloc);
        try self.maps.append(self.alloc, pm);
        try self.tile_reps.append(self.alloc, &.{});
        return pm;
    }

    fn maskIndex(self: *Nav, mask: u16) ?usize {
        for (self.maps.items, 0..) |m, i| {
            if (m.mask == mask and m.footprint == .point) return i;
        }
        return null;
    }

    /// Per-tile landing cells for `mask`: for each level tile, the passable subtile nearest its
    /// centre, or -1. This is what makes the teleport search cheap — it searches 25x fewer nodes
    /// than the subtile grid, and every node already knows a legal place to land.
    pub fn tileReps(self: *Nav, mask: u16) ![]const i32 {
        const pm = try self.passMap(mask);
        const idx = self.maskIndex(mask).?;
        if (self.tile_reps.items[idx].len != 0) return self.tile_reps.items[idx];

        const tw = self.lv.tileW();
        const th = self.lv.tileH();
        const reps = try self.alloc.alloc(i32, @intCast(@max(tw * th, 0)));
        errdefer self.alloc.free(reps);
        var ty: i32 = 0;
        while (ty < th) : (ty += 1) {
            var tx: i32 = 0;
            while (tx < tw) : (tx += 1) {
                const cx = tx * wd.SUBTILES_PER_TILE + 2;
                const cy = ty * wd.SUBTILES_PER_TILE + 2;
                // Radius 2 keeps the landing inside its own tile, so the tile a hop targets is the
                // tile it actually lands in and the room check stays honest. Terrain only — this is
                // cached for the level's lifetime, so it must not bake in who happened to be
                // standing there when it was first asked for.
                const p = grid.nearestStaticPassable(pm, cx, cy, 2);
                reps[@intCast(ty * tw + tx)] = if (p) |q| @intCast(pm.index(q.x, q.y)) else -1;
            }
        }
        self.tile_reps.items[idx] = reps;
        return reps;
    }
};
