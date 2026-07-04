//! Subtile collision grid — the walkable / line-of-sight mask a headless server
//! needs for movement, pathfinding and LOS. It is built from a level's placed
//! DS1 tiles plus the DT1 tile library: every DS1 cell resolves to a DT1 tile,
//! whose 5x5 block of per-subtile flags is OR'd into a level-wide subtile grid.
//!
//! This is difficulty-invariant: the flags come straight from the tile art, so
//! N/NM/Hell share the same collision once the layout is fixed. The only thing
//! difficulty can move is the layout feeding in here (level size / room counts).
//!
//! DS1-cell -> DT1 identity (derived empirically against real town DS1/DT1 pairs,
//! since the engine's getTileLibraryEntry body lives in un-transformed Drlg.cpp):
//!   floor cell: orientation 0, main = (raw>>20)&0x3f, sub = (raw>>8)&0xff
//!   wall cell:  main/sub as above, orientation = paired orient-cell's prop1 byte
//! A town wall layer resolves 386/389 this way (the residual are tree/object
//! tiles in DT1 files not part of the base set).

const std = @import("std");
const ds1 = @import("d2-formats").ds1;
const dt1 = @import("d2-formats").dt1;

/// Each DS1 tile is a 5x5 block of subtiles.
pub const SUBTILES_PER_TILE = 5;

/// 1.14d collision-map bit names, matching how the in-game botting layer (d2bs
/// `LevelMap::CollisionFlag`) reads the runtime CollMap (Room1.pColl.pMapStart, one
/// u16 per subtile). The low static-terrain bits (BlockWalk/BlockLoS/Wall/BlockPlayer/
/// AlternateTile) come straight from each covering DT1 tile's per-subtile flag byte;
/// the higher bits are runtime unit occupancy set during play, never at room init.
/// The VALUES are unchanged from the DBM-verified grid — only the names now carry the
/// d2bs walkability semantics (BlockWalk 0x01, Wall 0x04) instead of the old inverted
/// labels. `walkable()` below is the exact mask a pather applies.
pub const Colbit = struct {
    pub const block_walk: u16 = 0x01;
    pub const block_los: u16 = 0x02;
    pub const wall: u16 = 0x04;
    pub const block_player: u16 = 0x08;
    pub const alternate_tile: u16 = 0x10;
    /// Also used as a synthetic render marker: a subtile whose tile has no floor tile is
    /// stamped `blank` so the collision view draws it void; the raw-composite pass then
    /// promotes it to solid rock. NOT set by the engine at room init for real terrain.
    pub const blank: u16 = 0x20;
    pub const missile: u16 = 0x40;
    pub const player: u16 = 0x80;
    pub const npc_loc: u16 = 0x100;
    pub const item: u16 = 0x200;
    pub const object: u16 = 0x400;
    pub const closed_door: u16 = 0x800;
    pub const npc_coll: u16 = 0x1000;
    pub const friendly_npc: u16 = 0x2000;
    pub const dead_body: u16 = 0x8000;
};

/// Walkable per d2bs `LevelMap` semantics: a subtile is walkable unless BlockWalk (0x01),
/// BlockPlayer (0x08) or Object (0x400) is set — and the all-bits OOB sentinel 0xFFFF is
/// never walkable. This is exactly the mask path consumers apply to the raw u16 CollMap.
pub inline fn walkable(v: u16) bool {
    return (v & (Colbit.block_walk | Colbit.block_player | Colbit.object)) == 0 and v != 0xFFFF;
}

/// Collision bit combinations the engine names as masks.
pub const Colmask = struct {
    pub const monster_missile: u16 = 0x101;
    pub const misplaymoster: u16 = 0x1c0;
    pub const monster_path: u16 = 0x3c01;
    pub const player_flying: u16 = 0x804;
    pub const radial_barrier: u16 = 0x805;
    pub const player_path: u16 = 0x1c09;
    pub const spawn: u16 = 0x3e01;
    pub const placement: u16 = 0x3f11;
    pub const blocks_door: u16 = 0x8180;
    pub const any: u16 = 0xffff;
};

/// A borrowed set of parsed DT1 files, indexed by (orientation, main, sub) for
/// O(1) tile resolution. Does not own the DT1s.
pub const DtLibrary = struct {
    map: std.AutoHashMapUnmanaged(u64, *const dt1.Tile) = .{},
    allocator: std.mem.Allocator,

    fn key(orientation: i32, main: i32, sub: i32) u64 {
        return (@as(u64, @bitCast(@as(i64, orientation))) << 40) |
            (@as(u64, @intCast(main & 0x3f)) << 20) |
            @as(u64, @intCast(sub & 0xff));
    }

    pub fn init(allocator: std.mem.Allocator) DtLibrary {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DtLibrary) void {
        self.map.deinit(self.allocator);
    }

    /// Add every tile in a parsed DT1. First writer for an identity wins — the
    /// collision block is identical across rarity variants of the same tile.
    pub fn add(self: *DtLibrary, d: *const dt1.Dt1) !void {
        for (d.tiles) |*t| {
            const gop = try self.map.getOrPut(self.allocator, key(t.orientation, t.main, t.sub));
            if (!gop.found_existing) gop.value_ptr.* = t;
        }
    }

    pub fn find(self: *const DtLibrary, orientation: i32, main: i32, sub: i32) ?*const dt1.Tile {
        return self.map.get(key(orientation, main, sub));
    }
};

pub const CollisionGrid = struct {
    allocator: std.mem.Allocator,
    /// Dimensions in SUBTILES (tile count * 5).
    width: usize,
    height: usize,
    /// Row-major subtile flags: `cells[y*width + x]`, OR of every contributing
    /// tile's subtile flag byte (see dt1.SubtileFlag for bit meanings).
    cells: []u8,
    /// Tiles whose DS1 identity did not resolve in the library (missing DT1).
    /// A high count means the caller supplied an incomplete tile set.
    unresolved: usize,

    pub fn deinit(self: *CollisionGrid) void {
        self.allocator.free(self.cells);
    }

    inline fn at(self: *const CollisionGrid, x: usize, y: usize) u8 {
        if (x >= self.width or y >= self.height) return dt1.SubtileFlag.block_walk;
        return self.cells[y * self.width + x];
    }

    /// True when a unit may stand on subtile (x, y). Out-of-bounds blocks.
    pub fn walkable(self: *const CollisionGrid, x: usize, y: usize) bool {
        return self.at(x, y) & dt1.SubtileFlag.block_walk == 0;
    }

    /// True when subtile (x, y) blocks line of sight / light.
    pub fn blocksLos(self: *const CollisionGrid, x: usize, y: usize) bool {
        return self.at(x, y) & dt1.SubtileFlag.block_los != 0;
    }
};

/// Blit one tile's 5x5 subtile flags into the grid at tile (tx, ty). Flags are
/// OR'd so overlapping layers (floor then wall) accumulate blocking.
fn blit(grid: *CollisionGrid, t: *const dt1.Tile, tx: usize, ty: usize) void {
    var sy: usize = 0;
    while (sy < SUBTILES_PER_TILE) : (sy += 1) {
        const gy = ty * SUBTILES_PER_TILE + sy;
        if (gy >= grid.height) break;
        var sx: usize = 0;
        while (sx < SUBTILES_PER_TILE) : (sx += 1) {
            const gx = tx * SUBTILES_PER_TILE + sx;
            if (gx >= grid.width) continue;
            // The engine's TileLibrary_AddCollision (0x64c4c0) reads the DT1 25-byte
            // subtile block with the row (Y) axis flipped: grid cell (dx,dy) takes
            // byte[(4-dy)*5+dx]. Mirror that so this rasterizer matches the runtime
            // CollMap (and the materialize.zig path).
            grid.cells[gy * grid.width + gx] |= t.subtile(sx, SUBTILES_PER_TILE - 1 - sy);
        }
    }
}

/// Stamp uniform solid rock (0x05 = block_walk|wall) across a tile's 5x5 footprint —
/// the engine's orientation-10 "special/opaque" fallback tile for the main=30 uncarved-
/// rock fill, which some level DT1 sets don't ship (so `lib.find` misses it).
fn blitSolid(grid: *CollisionGrid, tx: usize, ty: usize) void {
    var sy: usize = 0;
    while (sy < SUBTILES_PER_TILE) : (sy += 1) {
        const gy = ty * SUBTILES_PER_TILE + sy;
        if (gy >= grid.height) break;
        var sx: usize = 0;
        while (sx < SUBTILES_PER_TILE) : (sx += 1) {
            const gx = tx * SUBTILES_PER_TILE + sx;
            if (gx >= grid.width) continue;
            grid.cells[gy * grid.width + gx] |= 0x05;
        }
    }
}

/// Build the subtile collision grid for a single parsed DS1 using the tiles in
/// `lib`. Floor layers contribute their base walkability; wall layers OR their
/// blocking on top. Caller owns and must `deinit` the result.
pub fn rasterize(allocator: std.mem.Allocator, d: *const ds1.Ds1, lib: *const DtLibrary) !CollisionGrid {
    const w: usize = @intCast(d.width);
    const h: usize = @intCast(d.height);
    var grid = CollisionGrid{
        .allocator = allocator,
        .width = w * SUBTILES_PER_TILE,
        .height = h * SUBTILES_PER_TILE,
        .cells = try allocator.alloc(u8, w * h * SUBTILES_PER_TILE * SUBTILES_PER_TILE),
        .unresolved = 0,
    };
    errdefer grid.deinit();
    @memset(grid.cells, 0);

    for (d.floor_layers) |fl| {
        for (fl, 0..) |c, i| {
            if (c.raw & 0x00ff_ffff == 0) continue;
            const main = @as(i32, @intCast((c.raw >> 20) & 0x3f));
            const sub = @as(i32, @intCast((c.raw >> 8) & 0xff));
            if (lib.find(0, main, sub)) |t| {
                blit(&grid, t, i % w, i / w);
            } else if (main == 30) {
                blitSolid(&grid, i % w, i / w); // uncarved-rock fill (engine type-10 fallback -> 0x05)
            } else grid.unresolved += 1;
        }
    }

    for (d.wall_layers) |wl| {
        const n = @min(wl.wall.len, wl.orient.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const wc = wl.wall[i];
            if (wc.raw & 0x00ff_ffff == 0) continue;
            const main = @as(i32, @intCast((wc.raw >> 20) & 0x3f));
            const sub = @as(i32, @intCast((wc.raw >> 8) & 0xff));
            const orient: i32 = wl.orient[i].prop1;
            if (lib.find(orient, main, sub)) |t| {
                blit(&grid, t, i % w, i / w);
            } else if (main == 30) {
                blitSolid(&grid, i % w, i / w);
            } else grid.unresolved += 1;
        }
    }

    return grid;
}

/// ASCII dump of a collision grid: '#' blocks walk, ':' blocks LOS only, '.'
/// walkable. One char per subtile, row-major. Caller frees.
pub fn asciiMap(grid: *const CollisionGrid, allocator: std.mem.Allocator) ![]u8 {
    var out = try allocator.alloc(u8, (grid.width + 1) * grid.height);
    var p: usize = 0;
    var y: usize = 0;
    while (y < grid.height) : (y += 1) {
        var x: usize = 0;
        while (x < grid.width) : (x += 1) {
            out[p] = if (!grid.walkable(x, y)) '#' else if (grid.blocksLos(x, y)) ':' else '.';
            p += 1;
        }
        out[p] = '\n';
        p += 1;
    }
    return out;
}

const testing = std.testing;

test "walkable(): d2bs LevelMap mask over the raw u16 CollMap" {
    // Blocking bits: BlockWalk (0x01), BlockPlayer (0x08), Object (0x400) each block.
    try testing.expect(!walkable(Colbit.block_walk));
    try testing.expect(!walkable(Colbit.block_player));
    try testing.expect(!walkable(Colbit.object));
    try testing.expect(!walkable(Colbit.block_walk | Colbit.wall)); // solid rock 0x05
    // Non-blocking bits stay walkable: LoS, the wall (missile-barrier) bit alone,
    // alternate_tile, blank, missile, and unit-occupancy bits do NOT block walking.
    try testing.expect(walkable(0));
    try testing.expect(walkable(Colbit.block_los));
    try testing.expect(walkable(Colbit.wall)); // 0x04 alone: blocks missiles, not walk
    try testing.expect(walkable(Colbit.alternate_tile));
    try testing.expect(walkable(Colbit.blank));
    try testing.expect(walkable(Colbit.missile));
    try testing.expect(walkable(Colbit.player));
    // The all-bits OOB sentinel is never walkable, even though it carries no "clean" state.
    try testing.expect(!walkable(0xFFFF));
    // Bit values are the DBM-verified layout (unchanged): confirm the load-bearing few.
    try testing.expectEqual(@as(u16, 0x01), Colbit.block_walk);
    try testing.expectEqual(@as(u16, 0x04), Colbit.wall);
    try testing.expectEqual(@as(u16, 0x08), Colbit.block_player);
    try testing.expectEqual(@as(u16, 0x20), Colbit.blank);
    try testing.expectEqual(@as(u16, 0x400), Colbit.object);
}

test "rasterize town DS1 into a subtile collision grid" {
    const a = testing.allocator;

    // Assemble the Act 1 base DT1 set we have vendored.
    const dt1_files = [_][]const u8{
        @embedFile("maps/Act1_Town_Floor.dt1"),
        @embedFile("maps/Act1_Town_trees.dt1"),
        @embedFile("maps/Act1_Town_Fence.dt1"),
        @embedFile("maps/Act1_Town_Objects.dt1"),
        @embedFile("maps/Act1_Outdoors_stonewall.dt1"),
    };
    var dts: [dt1_files.len]dt1.Dt1 = undefined;
    var lib = DtLibrary.init(a);
    defer lib.deinit();
    for (dt1_files, 0..) |bytes, i| {
        dts[i] = try dt1.parse(a, bytes);
        try lib.add(&dts[i]);
    }
    defer for (&dts) |*d| d.deinit();

    const ds_bytes = @embedFile("maps/Act1_Town_TownN1.ds1");
    var d = try ds1.parse(a, ds_bytes);
    defer d.deinit();

    var grid = try rasterize(a, &d, &lib);
    defer grid.deinit();

    try testing.expectEqual(@as(usize, @intCast(d.width)) * SUBTILES_PER_TILE, grid.width);
    try testing.expectEqual(@as(usize, @intCast(d.height)) * SUBTILES_PER_TILE, grid.height);

    // A town has both walkable ground and blocking walls/fences.
    var walk: usize = 0;
    var block: usize = 0;
    for (grid.cells) |c| {
        if (c & dt1.SubtileFlag.block_walk != 0) block += 1 else walk += 1;
    }
    try testing.expect(walk > 0);
    try testing.expect(block > 0);
}

test "collision grid: walkable / blocksLos / out-of-bounds semantics" {
    const a = testing.allocator;
    var g = CollisionGrid{ .allocator = a, .width = 3, .height = 2, .cells = try a.alloc(u8, 6), .unresolved = 0 };
    defer g.deinit();
    @memset(g.cells, 0);

    // All-zero grid: every in-bounds subtile is walkable and clear of LOS.
    try testing.expect(g.walkable(0, 0));
    try testing.expect(g.walkable(2, 1));
    try testing.expect(!g.blocksLos(1, 1));

    // A wall subtile blocks walk.
    g.cells[0 * 3 + 1] = dt1.SubtileFlag.block_walk;
    try testing.expect(!g.walkable(1, 0));

    // A LOS-only subtile stays walkable but blocks sight.
    g.cells[1 * 3 + 2] = dt1.SubtileFlag.block_los;
    try testing.expect(g.walkable(2, 1));
    try testing.expect(g.blocksLos(2, 1));

    // Out-of-bounds is always blocking (the .at() guard returns block_walk).
    try testing.expect(!g.walkable(3, 0)); // x == width
    try testing.expect(!g.walkable(0, 2)); // y == height
    try testing.expect(!g.walkable(999, 999));
}

test "collision asciiMap: '#' blocks walk, ':' LOS-only, '.' walkable" {
    const a = testing.allocator;
    var g = CollisionGrid{ .allocator = a, .width = 3, .height = 1, .cells = try a.alloc(u8, 3), .unresolved = 0 };
    defer g.deinit();
    g.cells[0] = 0;
    g.cells[1] = dt1.SubtileFlag.block_walk;
    g.cells[2] = dt1.SubtileFlag.block_los;
    const s = try asciiMap(&g, a);
    defer a.free(s);
    try testing.expectEqualStrings(".#:\n", s);
}

// Loads the vendored Act-1 town DT1 set + TownN1 DS1 for the rasterize tests.
// Caller owns everything; free via freeTownFixture.
const TownFixture = struct {
    lib: DtLibrary,
    dts: [5]dt1.Dt1,
    ds: ds1.Ds1,
    fn load(a: std.mem.Allocator) !TownFixture {
        const files = [_][]const u8{
            @embedFile("maps/Act1_Town_Floor.dt1"),
            @embedFile("maps/Act1_Town_trees.dt1"),
            @embedFile("maps/Act1_Town_Fence.dt1"),
            @embedFile("maps/Act1_Town_Objects.dt1"),
            @embedFile("maps/Act1_Outdoors_stonewall.dt1"),
        };
        var f: TownFixture = .{ .lib = DtLibrary.init(a), .dts = undefined, .ds = undefined };
        for (files, 0..) |bytes, i| {
            f.dts[i] = try dt1.parse(a, bytes);
            try f.lib.add(&f.dts[i]);
        }
        f.ds = try ds1.parse(a, @embedFile("maps/Act1_Town_TownN1.ds1"));
        return f;
    }
    fn deinit(self: *TownFixture) void {
        self.ds.deinit();
        for (&self.dts) |*d| d.deinit();
        self.lib.deinit();
    }
};

test "rasterize is deterministic: same DS1 + DT1 set -> byte-identical grid" {
    const a = testing.allocator;
    var f = try TownFixture.load(a);
    defer f.deinit();

    var g1 = try rasterize(a, &f.ds, &f.lib);
    defer g1.deinit();
    var g2 = try rasterize(a, &f.ds, &f.lib);
    defer g2.deinit();

    try testing.expectEqual(g1.width, g2.width);
    try testing.expectEqual(g1.height, g2.height);
    try testing.expectEqual(g1.unresolved, g2.unresolved);
    try testing.expectEqualSlices(u8, g1.cells, g2.cells);
}

test "rasterize with empty DT1 library: all tiles unresolved, nothing blocked" {
    const a = testing.allocator;
    var lib = DtLibrary.init(a);
    defer lib.deinit();
    var d = try ds1.parse(a, @embedFile("maps/Act1_Town_TownN1.ds1"));
    defer d.deinit();

    var g = try rasterize(a, &d, &lib);
    defer g.deinit();

    // Nothing resolves via the DT1 art, so ordinary tiles are counted unresolved and
    // leave no collision. The ONE exception is the main=30 "uncarved rock" fill: it is
    // definitionally solid (the engine's orient-10 fallback tile, 0x05), so it blocks
    // even with no art loaded — one tile's 5x5 = 25 blocked subtiles.
    try testing.expect(g.unresolved > 0);
    var blocked: usize = 0;
    for (g.cells) |c| {
        if (c & dt1.SubtileFlag.block_walk != 0) blocked += 1;
    }
    try testing.expectEqual(@as(usize, 25), blocked);
}
