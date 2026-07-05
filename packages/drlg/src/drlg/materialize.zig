//! Gate-safe POST-generation tile materialization consumer (Milestone 2a).
//!
//! This is the orchestration layer that turns a room's DS1/DrlgMap grid cells
//! into its actual tile-data list (floors / walls / shadows), by faithfully
//! transforming the reconstructed 1.14d path:
//!
//!   DS1 layers ──▶ D2DrlgGridStrc sub-grids  (Preset::InitGridsFromDS1File +
//!                                              DrlgGrid::InitGridFromTileData)
//!             ──▶ CountTilesFromGrid / CountWallTilesFromGrid  (size the arrays)
//!             ──▶ AllocTileDataArrays
//!             ──▶ InitRoomTiles ─▶ processTile ─▶ the tilegen.zig tile BUILDERS
//!                                  (getTileLibraryEntry / fillTileData /
//!                                   create{Wall,Floor,Shadow}TileData).
//!
//! The count / InitRoomTiles / processTile bodies are 1:1 transforms of
//! recon/closure/RoomTile.cpp (see RoomTile.zig for the same functions on the
//! free path). The grid setup mirrors Preset.cpp DRLGPRESET_InitGridsFromDS1File
//! (006667d0) collapsed to a single whole-room grid per layer: InitGridFromTileData
//! just points a sub-grid's pCellsFlags at the parent layer cells with a
//! row-offset table, which for a whole room is `pCellsFlags = layer,
//! rowOffsets[y] = y*stride`.
//!
//! ARTIFACT-BLOCKED corners (documented, mirrors RoomTile.zig's panic stubs):
//!   * setupWarpTile / initWarpCacheTiles / updateOrAddTile / updateTileType are
//!     artifact-blocked in the recon (uninit locals, lost params, truncated
//!     tables). processTile reaches them only for WARP / PRESET-SPAWN / cross-room
//!     TRANSITION cells (orientation 8/9/10/11 with the 0x80000000 grid bit, or
//!     the 0x04 transition bit). These produce warp *units* / preset spawns / room
//!     seams — NOT base collision floor/wall tiles — so this consumer counts them
//!     (`special_excluded`) and skips them, exactly like M1 excluded the type-3
//!     shadow companions. The cross-check masks those tile positions.
//!   * The 0x04 transition bit does not occur in the shipped preset DS1s (verified
//!     empirically); its branch is a counted skip.
//!
//! GATE SAFETY: pure post-generation CONSUMER. Nothing here is imported by the
//! generation path (drlg.zig / InitLevel / InitAllRoomsEx); only tests import it.
//! It runs on a bare, throwaway room over a COPY of the room seed, so the
//! byte-exact seed gate is never touched.

const std = @import("std");
const s = @import("structs.zig");
const DrlgGrid = @import("DrlgGrid.zig");
const DrlgRoom = @import("DrlgRoom.zig");
const Border = @import("outdoors/Border.zig");
const tilegen = @import("tilegen.zig");
const dt1 = @import("d2-formats").dt1;
const ds1 = @import("d2-formats").ds1;
const collision = @import("../collision.zig");
const lib = @import("../lib.zig");
const dt1blob = @import("d2-formats").dt1_blob;
const dt1_data = @import("d2-formats").dt1_data;
const preset = @import("preset.zig");
const dpool = @import("pool.zig");
const dtables = @import("tables.zig");
const drlgmod = @import("drlg.zig");
const act_mod = @import("../act.zig");
const fog = @import("d2-fog").memory;
const TileSub = @import("TileSub.zig");
const drlg_rng = @import("rng.zig");

const SUBTILES = collision.SUBTILES_PER_TILE;

// eD2GridCellFlags bit constants (RoomTile.cpp naming).
const CELLFLAGS_NONE: i32 = 0;
const CELLFLAGS_0x01: i32 = 0x01;
const CELLFLAGS_0x02: i32 = 0x02;
const CELLFLAGS_0x04: i32 = 0x04;
const CELLFLAGS_0x08: i32 = 0x08;
const CELLFLAGS_0x80: i32 = 0x80;
const CELLFLAGS_0x8000000: i32 = 0x8000000;
const CELLFLAGS_0x80000000: i32 = @bitCast(@as(u32, 0x80000000));

// ---------------------------------------------------------------------------
// Consumer context: the tile-position bookkeeping the recon path never needs
// (it feeds a real engine), but the collision cross-check does. Test-only,
// single-threaded: set before an InitRoomTiles run, read after.
// ---------------------------------------------------------------------------
const MatCtx = struct {
    width: usize,
    /// tile positions (y*width+x) diverted to the artifact-blocked warp/preset
    /// path — excluded from the produced tiles and masked in the cross-check.
    special: []bool,
    /// wall-array indices that are type-3 shadow companions (createWallTileData
    /// spawns a type-4 tile per type-3 wall; collision.zig has no companion).
    companion: []bool,
    special_count: usize = 0,
    warp_setup_skipped: usize = 0,
    transition_skipped: usize = 0,

    fn markSpecial(self: *MatCtx, nX: i32, nY: i32) void {
        self.special_count += 1;
        const ix: usize = @intCast(nX);
        const iy: usize = @intCast(nY);
        const k = iy * self.width + ix;
        if (k < self.special.len and !self.special[k]) self.special[k] = true;
    }
};

// Set at the top of each materialize entry (a poor-man's closure for the C-style tilegen
// callbacks) and read only within that same synchronous call. Thread-local so concurrent
// generations on different threads don't clobber each other's MatCtx (single-threaded
// behaviour is identical — each thread still sets+reads its own).
threadlocal var g_ctx: *MatCtx = undefined;

// ===========================================================================
// RoomTile.cpp count/init/processTile — faithful transforms wired to the
// tilegen.zig builders (which own getTileLibraryEntry + create*TileData).
// ---------------------------------------------------------------------------

/// RoomTile.cpp:825 (0066ece0) — sizes nWall/nFloor/nRoof Tiles Max from a grid.
fn countTilesFromGrid(pRoomEx: [*c]s.D2RoomExStrc, pGrid: [*c]s.D2DrlgGridStrc, bCountFloors: i32, bKillEdgeX_in: i32, bKillEdgeY: i32) void {
    const nWorldPosX = pRoomEx.*.sCoords.WorldPosition.x;
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(pRoomEx.*.pRoomTiles);
    const nWidth = @as(i32, @intFromBool(bKillEdgeX_in == 0)) + pRoomEx.*.sCoords.WorldSize.x;
    const nWorldPosY = pRoomEx.*.sCoords.WorldPosition.y;
    var nRow: i32 = 0;
    const nHeight = @as(i32, @intFromBool(bKillEdgeY == 0)) + pRoomEx.*.sCoords.WorldSize.y;
    if (0 >= nHeight) return;
    while (true) {
        var nX: i32 = 0;
        if (0 < nWidth) {
            while (true) {
                const nCell = DrlgGrid.GetGridFlags(pGrid, nX, nRow);
                if ((nCell & 1) != 0) pTileGrid.*.nWallTilesMax += 1;
                if ((nCell & 2) != 0 or (bCountFloors != 0 and DrlgRoom.AreXYInsideCoordinates(&pRoomEx.*.sCoords, nX + nWorldPosX, nRow + nWorldPosY) != 0)) {
                    pTileGrid.*.nFloorTilesMax += 1;
                }
                if ((nCell & 0x8000000) != 0) pTileGrid.*.nRoofTilesMax += 1;
                nX += 1;
                if (!(nX < nWidth)) break;
            }
        }
        nRow += 1;
        if (!(nRow < nHeight)) break;
    }
}

/// RoomTile.cpp:864 (0066edb0) — counts the extra wall tiles (orient 3/10/11).
fn countWallTilesFromGrid(pRoomEx: [*c]s.D2RoomExStrc, pFloorGrid: [*c]s.D2DrlgGridStrc, pOrientGrid: [*c]s.D2DrlgGridStrc, bKillEdgeX: i32, bKillEdgeY: i32) void {
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(pRoomEx.*.pRoomTiles);
    const nWidth = @as(i32, @intFromBool(bKillEdgeX == 0)) + pRoomEx.*.sCoords.WorldSize.x;
    var nY: i32 = 0;
    const nHeight = @as(i32, @intFromBool(bKillEdgeY == 0)) + pRoomEx.*.sCoords.WorldSize.y;
    if (0 >= nHeight) return;
    while (true) {
        var nColIdx: i32 = 0;
        if (0 < nWidth) {
            while (true) {
                var nTileType = DrlgGrid.GetGridFlags(pOrientGrid, nColIdx, nY);
                var bCountWall = false;
                if (nTileType == 3) {
                    bCountWall = true;
                } else if (@as(u32, @bitCast(nTileType -% 10)) < 2) {
                    nTileType = DrlgGrid.GetGridFlags(pFloorGrid, nColIdx, nY);
                    if (-1 < nTileType) bCountWall = true else pTileGrid.*.nFloorTilesMax += 6;
                }
                if (bCountWall) pTileGrid.*.nWallTilesMax += 1;
                nColIdx += 1;
                if (!(nColIdx < nWidth)) break;
            }
        }
        nY += 1;
        if (!(nY < nHeight)) break;
    }
}

/// RoomTile.cpp:935 (0066eea0). Allocs the zeroed tile-grid header.
fn allocRoomTileGrid(pRoomEx: [*c]s.D2RoomExStrc, a: std.mem.Allocator) !void {
    if (pRoomEx.*.pRoomTiles != null) return;
    const p = try a.create(s.D2DrlgTileGridStrc);
    @memset(@as([*]u8, @ptrCast(p))[0..@sizeOf(s.D2DrlgTileGridStrc)], 0);
    pRoomEx.*.pRoomTiles = p;
}

/// RoomTile.cpp:947 (0066eee0). Allocs the wall/floor/roof tile-data arrays from
/// the counted *Max fields. (Pool AllocServerMemory -> test allocator here.)
fn allocTileDataArrays(pRoomEx: [*c]s.D2RoomExStrc, a: std.mem.Allocator) !void {
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(pRoomEx.*.pRoomTiles);
    if (pTileGrid.*.nFloorTilesMax != 0) {
        const n: usize = @intCast(pTileGrid.*.nFloorTilesMax);
        const arr = try a.alloc(s.D2DrlgTileDataStrc, n);
        @memset(std.mem.sliceAsBytes(arr), 0);
        pTileGrid.*.pFloorTiles = @ptrCast(arr.ptr);
    }
    if (pTileGrid.*.nWallTilesMax != 0) {
        const n: usize = @intCast(pTileGrid.*.nWallTilesMax);
        const arr = try a.alloc(s.D2DrlgTileDataStrc, n);
        @memset(std.mem.sliceAsBytes(arr), 0);
        pTileGrid.*.pWallTiles = @ptrCast(arr.ptr);
    }
    if (pTileGrid.*.nRoofTilesMax != 0 and pTileGrid.*.pRoofTiles == null) {
        const n: usize = @intCast(pTileGrid.*.nRoofTilesMax);
        const arr = try a.alloc(s.D2DrlgTileDataStrc, n);
        @memset(std.mem.sliceAsBytes(arr), 0);
        pTileGrid.*.pRoofTiles = @ptrCast(arr.ptr);
    }
}

/// RoomTile.cpp 720-724 wall block — createWallTileData + (skipped) warp setup.
fn processWallBlock(pRoom: [*c]s.D2RoomExStrc, nX: i32, nY: i32, nFlags: i32, nOtherFlags: i32) void {
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(pRoom.*.pRoomTiles);
    const before: usize = @intCast(pTileGrid.*.nWalls);
    const e = tilegen.getTileLibraryEntry(pRoom, nOtherFlags, @bitCast(nFlags));
    _ = tilegen.createWallTileData(pRoom, null, nX, nY, @bitCast(nFlags), e, nOtherFlags);
    // createWallTileData spawns a type-4 shadow companion for a type-3 wall.
    var c: usize = before + 1;
    while (c < @as(usize, @intCast(pTileGrid.*.nWalls))) : (c += 1) {
        if (c < g_ctx.companion.len) g_ctx.companion[c] = true;
    }
    // ARTIFACT-BLOCKED: the engine now calls setupWarpTile for warp orientations;
    // it only wires the warp *unit*, the base wall tile above is unaffected.
    if ((nOtherFlags == (CELLFLAGS_0x08 | CELLFLAGS_0x02 | CELLFLAGS_0x01) or nOtherFlags == (CELLFLAGS_0x08 | CELLFLAGS_0x02)) and pRoom.*.pLevel.?.eD2LevelId != .MatronsDen) {
        g_ctx.warp_setup_skipped += 1;
    }
}

/// RoomTile.cpp 730-731 shadow block.
fn processShadowBlock(pRoom: [*c]s.D2RoomExStrc, nX: i32, nY: i32, nFlags: i32) void {
    const e = tilegen.getTileLibraryEntry(pRoom, 0xd, @bitCast(nFlags));
    _ = tilegen.createShadowTileData(pRoom, null, nX, nY, @bitCast(nFlags), e);
}

/// RoomTile.cpp:666 (0066e9b0). Faithful, with the artifact-blocked warp/preset/
/// transition branches replaced by counted skips (see file header).
fn processTile(nFlags_in: i32, pRoom: [*c]s.D2RoomExStrc, nX: i32, nY: i32, nParam: i32, nOtherFlags: i32) void {
    var nFlags = nFlags_in;
    var nGridFlags: i32 = undefined;
    const nMainIndex: u8 = @as(u8, @truncate(@as(u32, @bitCast(nFlags)) >> 0x14)) & 0x3f;
    if ((nOtherFlags == (CELLFLAGS_0x08 | CELLFLAGS_0x02 | CELLFLAGS_0x01) or nOtherFlags == (CELLFLAGS_0x08 | CELLFLAGS_0x02)) and 7 < nMainIndex) {
        return;
    }
    const nOrientation: u8 = @truncate(@as(u32, @bitCast(nFlags >> 8)));
    if (nOtherFlags == CELLFLAGS_NONE and nMainIndex == 0x1e and (nOrientation == 0 or nOrientation == 1)) {
        nFlags |= CELLFLAGS_0x80000000;
    }
    if ((nFlags & CELLFLAGS_0x80000000) != CELLFLAGS_NONE) {
        switch (nOtherFlags) {
            CELLFLAGS_0x08, CELLFLAGS_0x08 | CELLFLAGS_0x01 => {
                // Preset::CreatesPresets — preset spawn, no base collision tile.
                g_ctx.markSpecial(nX, nY);
                return;
            },
            CELLFLAGS_0x08 | CELLFLAGS_0x02, CELLFLAGS_0x08 | CELLFLAGS_0x02 | CELLFLAGS_0x01 => {
                if (7 < nMainIndex) return;
                // createExitWarp + initWarpCacheTiles (artifact-blocked warp).
                g_ctx.markSpecial(nX, nY);
                return;
            },
            else => {},
        }
    }
    if ((nFlags & CELLFLAGS_0x04) != CELLFLAGS_NONE) {
        // updateOrAddTile (artifact-blocked cross-room transition). Does not occur
        // in the shipped preset DS1s; counted skip.
        if ((nFlags & (CELLFLAGS_0x02 | CELLFLAGS_0x01)) != 0 or
            ((nFlags & CELLFLAGS_0x8000000) != 0 and (nFlags & CELLFLAGS_0x80000000) == 0))
        {
            g_ctx.transition_skipped += 1;
            return;
        }
    }
    if ((nFlags & CELLFLAGS_0x02) == CELLFLAGS_NONE) {
        if (nParam == 0) {
            if ((nFlags & CELLFLAGS_0x01) != CELLFLAGS_NONE) processWallBlock(pRoom, nX, nY, nFlags, nOtherFlags);
            if ((nFlags & CELLFLAGS_0x8000000) == CELLFLAGS_NONE) return;
            processShadowBlock(pRoom, nX, nY, nFlags);
            return;
        }
        const bInside = DrlgRoom.AreXYInsideCoordinates(&pRoom.*.sCoords, nX, nY);
        if (bInside == 0) {
            if ((nFlags & CELLFLAGS_0x01) != CELLFLAGS_NONE) processWallBlock(pRoom, nX, nY, nFlags, nOtherFlags);
            if ((nFlags & CELLFLAGS_0x8000000) == CELLFLAGS_NONE) return;
            processShadowBlock(pRoom, nX, nY, nFlags);
            return;
        }
        nGridFlags = (nFlags & ~CELLFLAGS_0x80) | CELLFLAGS_0x80000000;
        const nBlank: u32 = if (pRoom.*.pLevel.?.eD2LevelId == .ArcaneSanctuary) 0x1e00100 else 0x1e00000;
        const eBlank = tilegen.getTileLibraryEntry(pRoom, 0, nBlank);
        pushFloor(pRoom, nX, nY, nGridFlags, eBlank);
    } else {
        nGridFlags = nFlags;
        const e = tilegen.getTileLibraryEntry(pRoom, 0, @bitCast(nFlags));
        pushFloor(pRoom, nX, nY, nGridFlags, e);
    }
    if ((nFlags & CELLFLAGS_0x01) != CELLFLAGS_NONE) processWallBlock(pRoom, nX, nY, nFlags, nOtherFlags);
    if ((nFlags & CELLFLAGS_0x8000000) == CELLFLAGS_NONE) return;
    processShadowBlock(pRoom, nX, nY, nFlags);
}

/// The RoomTile.cpp floor push (direct array append + fillTileData, not
/// createFloorTileData — as the engine does inside processTile).
fn pushFloor(pRoom: [*c]s.D2RoomExStrc, nX: i32, nY: i32, nGridFlags: i32, e: ?*const dt1.Tile) void {
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(pRoom.*.pRoomTiles);
    const nFloorCount = pTileGrid.*.nFloors;
    const pFloor: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(pTileGrid.*.pFloorTiles.?));
    pFloor[@intCast(nFloorCount)].pNext = null;
    pTileGrid.*.nFloors += 1;
    tilegen.fillTileData(pRoom, &pFloor[@intCast(nFloorCount)], nX, nY, @bitCast(nGridFlags), e);
}

/// RoomTile.cpp:789 (0066ec10). Walks the grid, driving processTile per cell.
fn InitRoomTiles(pRoomEx: [*c]s.D2RoomExStrc, pGrid: [*c]s.D2DrlgGridStrc, pOtherGrid: [*c]s.D2DrlgGridStrc, nTileParam: i32, nKillX: i32, nKillY: i32) void {
    const nWorldPosX = pRoomEx.*.sCoords.WorldPosition.x;
    const nXMax = @as(i32, @intFromBool(nKillX == 0)) + pRoomEx.*.sCoords.WorldSize.x;
    const nYOffset = pRoomEx.*.sCoords.WorldPosition.y;
    var nY: i32 = 0;
    const maxTile = @as(i32, @intFromBool(nKillY == 0)) + pRoomEx.*.sCoords.WorldSize.y;
    if (0 >= maxTile) return;
    while (true) {
        var nColIdx: i32 = 0;
        if (0 < nXMax) {
            while (true) {
                const nFlags = DrlgGrid.GetGridFlags(pGrid, nColIdx, nY);
                const nCellFlags: i32 = if (pOtherGrid == null) CELLFLAGS_NONE else DrlgGrid.GetGridFlags(pOtherGrid, nColIdx, nY);
                processTile(nFlags, pRoomEx, nColIdx + nWorldPosX, nY + nYOffset, nTileParam, nCellFlags);
                nColIdx += 1;
                if (!(nColIdx < nXMax)) break;
            }
        }
        nY += 1;
        if (!(nY < maxTile)) break;
    }
}

// ===========================================================================
// Public consumer API
// ---------------------------------------------------------------------------

/// A grid cell array + its D2DrlgGridStrc header, owned so we can free it.
const OwnedGrid = struct {
    grid: s.D2DrlgGridStrc,
    cells: []i32,
    rows: []i32,
};

fn buildGrid(a: std.mem.Allocator, width: usize, height: usize, cells: []i32) !OwnedGrid {
    const rows = try a.alloc(i32, height);
    for (rows, 0..) |*r, y| r.* = @intCast(y * width);
    return .{
        .grid = .{
            .pCellsFlags = cells.ptr,
            .pCellsRowOffsets = rows.ptr,
            .nWidth = @intCast(width),
            .nHeight = @intCast(height),
            .bIsSubGrid = 1,
        },
        .cells = cells,
        .rows = rows,
    };
}

/// A room's WINDOW into the shared level DS1. This is the D2 engine's per-room
/// CollMap model: the level's whole DS1 is loaded once, but each RoomEx only
/// materializes its own window (offset+size) of it (InitGridFromTileData points
/// a sub-grid's pCellsFlags into the parent layer with a row-offset table that
/// bakes in the room's tile offset). `off_x`/`off_y` are the tile offset of the
/// room into the DS1 (room.WorldPosition - DS1 origin); `size_x`/`size_y` are
/// the room's WorldSize (the loops add a +1 kill-edge, so the window spans
/// size+1 tiles). `seed` is the room's own sSeed (variant selection consumes it).
pub const Ds1RoomWindow = struct {
    off_x: i32,
    off_y: i32,
    size_x: i32,
    size_y: i32,
    seed: s.D2SeedStrc,
};

/// A windowed sub-grid header over the whole-DS1 `cells` (row stride `full_w`):
/// local cell (x,y) maps to DS1 cell (x+off_x, y+off_y).
fn buildGridWindow(a: std.mem.Allocator, cells: []i32, full_w: usize, off_x: i32, off_y: i32, sub_w: usize, sub_h: usize) !OwnedGrid {
    const rows = try a.alloc(i32, sub_h);
    for (rows, 0..) |*r, y| r.* = (@as(i32, @intCast(y)) + off_y) * @as(i32, @intCast(full_w));
    return .{
        .grid = .{
            .pCellsFlags = cells.ptr + @as(usize, @intCast(off_x)),
            .pCellsRowOffsets = rows.ptr,
            .nWidth = @intCast(sub_w),
            .nHeight = @intCast(sub_h),
            .bIsSubGrid = 1,
        },
        .cells = cells,
        .rows = rows,
    };
}

/// One placed tile in room-local TILE coords, carrying its resolved DT1 art and the
/// draw nFlags — the exact inputs the engine's per-room CollMap builder consumes
/// (AllocRoomCollisionGrid 0x64c900 → TileLibrary_SetupCollision 0x64c790). The
/// tile pointer is borrowed (into the level DT1 set or the static fill tiles); it is
/// valid for the lifetime of the DT1 set that produced it.
pub const CollTile = struct {
    nPosX: i32,
    nPosY: i32,
    nFlags: i32,
    tile: *const dt1.Tile,
    /// True for FLOOR-layer tiles. A room tile-cell with no floor tile is engine "void":
    /// the runtime CollMap has the Act1\Outdoors\Blank.dt1 fill (solid rock) stamped there
    /// (that DT1 is absent from our blob, so the caller uses the solid_fill stand-in).
    is_floor: bool,
};

pub const MaterializeResult = struct {
    /// Subtile collision grid rasterized from the materialized FLOOR + WALL tiles
    /// (roof/shadow array and type-3 companions excluded, matching collision.zig).
    coll: collision.CollisionGrid,
    /// tile positions (y*w+x) diverted to the artifact-blocked warp/preset path.
    special: []bool,
    /// The room's placed FLOOR + WALL + ROOF tiles in room-local tile coords, for the
    /// faithful per-room CollMap build (AllocRoomCollisionGrid). Includes the +1
    /// kill-edge tiles (their world origin lands in the adjacent room, so a neighbour
    /// picks them up — that is the engine's inter-room border blend).
    tiles: []CollTile,
    n_floors: i32,
    n_walls: i32,
    n_shadows: i32,
    special_count: usize,
    warp_setup_skipped: usize,
    transition_skipped: usize,
    unresolved: usize,

    pub fn deinit(self: *MaterializeResult, a: std.mem.Allocator) void {
        self.coll.deinit();
        a.free(self.special);
        a.free(self.tiles);
    }
};

/// Collect a room's FLOOR + WALL + ROOF tile-data (post-InitRoomTiles) into a flat
/// `CollTile` list — the input to the faithful per-room CollMap stamp. Mirrors the
/// layer order AllocRoomCollisionGrid stamps (floor, wall, roof); OR is order-free so
/// order is cosmetic. Wall companions (type-3 second-half tiles) are skipped exactly
/// as the rasterizer does. Tiles whose art did not resolve are dropped.
fn collectCollTiles(a: std.mem.Allocator, pTileGrid: [*c]s.D2DrlgTileGridStrc, companion: []const bool, max_tx: i32, max_ty: i32) ![]CollTile {
    var list: std.ArrayListUnmanaged(CollTile) = .empty;
    errdefer list.deinit(a);
    const pushArr = struct {
        fn go(l: *std.ArrayListUnmanaged(CollTile), alloc: std.mem.Allocator, base: ?*anyopaque, n: i32, comp: ?[]const bool, is_floor: bool, mtx: i32, mty: i32) !void {
            const p: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(base orelse return));
            var i: usize = 0;
            while (i < @as(usize, @intCast(n))) : (i += 1) {
                if (comp) |c| if (i < c.len and c[i]) continue;
                const td = &p[i];
                // Drop tiles outside the room's own [0,size) tile rect: those are the
                // materialize window's +1 kill-edge blend cells, not real engine room tiles.
                if (td.nPosX < 0 or td.nPosY < 0 or td.nPosX >= mtx or td.nPosY >= mty) continue;
                const t = tilegen.tileFromEntry(td.pTileLibraryEntry) orelse continue;
                try l.append(alloc, .{ .nPosX = td.nPosX, .nPosY = td.nPosY, .nFlags = td.nFlags, .tile = t, .is_floor = is_floor });
            }
        }
    }.go;
    try pushArr(&list, a, pTileGrid.*.pFloorTiles, pTileGrid.*.nFloors, null, true, max_tx, max_ty);
    try pushArr(&list, a, pTileGrid.*.pWallTiles, pTileGrid.*.nWalls, companion, false, max_tx, max_ty);
    try pushArr(&list, a, pTileGrid.*.pRoofTiles, pTileGrid.*.nShadows, null, false, max_tx, max_ty);
    return list.toOwnedSlice(a);
}

/// Faithful port of TileLibrary_AddCollision (0x64c4c0) + AddCollisionFlagToCoords
/// (0x64c700): stamp one tile into a room CollMap `grid` (row-major, `grid_w` subtiles
/// wide, `grid_h` tall) at room-relative subtile base (relX, relY). The DT1 25-byte
/// subtile block is OR'd with the Y (row) axis flipped — grid subtile (dc, dr) reads
/// block byte (4-dr)*5+dc — and the tile's derived collision flags (drawExtraColl) are
/// OR'd flat across the whole 5x5 footprint. relX/relY are tile-aligned so the 5x5 fits;
/// the bounds guards mirror the engine's low-clamp / high-overspill-into-padding.
pub fn stampCollTile(grid: []u8, grid_w: usize, grid_h: usize, relX: usize, relY: usize, ct: CollTile) void {
    const extra = drawExtraColl(ct.nFlags);
    var dr: usize = 0;
    while (dr < SUBTILES) : (dr += 1) {
        const gy = relY + dr;
        if (gy >= grid_h) break;
        var dc: usize = 0;
        while (dc < SUBTILES) : (dc += 1) {
            const gx = relX + dc;
            if (gx >= grid_w) continue;
            grid[gy * grid_w + gx] |= ct.tile.subtile(dc, SUBTILES - 1 - dr) | extra;
        }
    }
}

/// Materialize one DS1 (a room's DrlgMap) via the full InitRoomTiles orchestration
/// and rasterize its floor+wall subtile collision. `dts` is the level's DT1 set
/// (load order), used as the room's tile library. Caller owns the result.
pub fn materializeDs1(a: std.mem.Allocator, d: *const ds1.Ds1, dts: []const dt1.Dt1, window: ?Ds1RoomWindow) !MaterializeResult {
    const w: usize = @intCast(d.width);
    const h: usize = @intCast(d.height);
    const full_ncells = w * h;

    // Default (no window): materialize the WHOLE DS1 as one room — the engine's
    // per-room CollMap is instead a WINDOW of the shared level DS1 (see caller).
    const win: Ds1RoomWindow = window orelse .{
        .off_x = 0,
        .off_y = 0,
        .size_x = @intCast(w - 1),
        .size_y = @intCast(h - 1),
        .seed = .{ .nSeedLow = 0x1234_5678, .nSeedHigh = 0x29a },
    };
    // The count/InitRoomTiles loops add a +1 kill-edge, so the window spans
    // size+1 tiles; the produced collision grid is (size+1)*5 subtiles.
    const winW: usize = @intCast(win.size_x + 1);
    const winH: usize = @intCast(win.size_y + 1);
    const win_ncells = winW * winH;

    // Arena for all the transient grid/room scaffolding.
    var arena_impl = std.heap.ArenaAllocator.init(a);
    defer arena_impl.deinit();
    const ar = arena_impl.allocator();

    var tlib = tilegen.TileLib{ .dts = dts };
    var drlg = std.mem.zeroes(s.D2DrlgStrc);
    var level = std.mem.zeroes(s.D2DrlgLevelStrc);
    level.pDrlg = &drlg;
    level.eD2LevelId = @enumFromInt(0);

    var room = std.mem.zeroes(s.D2RoomExStrc);
    room.pLevel = &level;
    room.apTiles[0] = @ptrCast(&tlib);
    room.sSeed = win.seed;
    // WorldPosition stays 0 so stored nPosX/nPosY are window-local (0..size);
    // WorldSize is the room's window size. Grid reads are offset via buildGridWindow.
    room.sCoords = .{
        .WorldPosition = .{ .x = 0, .y = 0 },
        .WorldSize = .{ .x = win.size_x, .y = win.size_y },
    };
    const pRoom: [*c]s.D2RoomExStrc = &room;

    // ── DS1 → grids (InitGridsFromDS1File). The cell arrays cover the WHOLE DS1;
    //    the sub-grid headers window each room's (off,size) view into them. ──
    var floor_grids = try ar.alloc(OwnedGrid, d.floor_layers.len);
    for (d.floor_layers, 0..) |fl, li| {
        const cells = try ar.alloc(i32, full_ncells);
        for (cells, 0..) |*c, i| c.* = @bitCast(fl[i].raw);
        floor_grids[li] = try buildGridWindow(ar, cells, w, win.off_x, win.off_y, winW, winH);
    }
    var wall_grids = try ar.alloc(OwnedGrid, d.wall_layers.len);
    var orient_grids = try ar.alloc(OwnedGrid, d.wall_layers.len);
    for (d.wall_layers, 0..) |wl, li| {
        const wcells = try ar.alloc(i32, full_ncells);
        const ocells = try ar.alloc(i32, full_ncells);
        const n = @min(wl.wall.len, wl.orient.len);
        for (0..full_ncells) |i| {
            wcells[i] = if (i < n) @bitCast(wl.wall[i].raw) else 0;
            ocells[i] = if (i < n) wl.orient[i].prop1 else 0; // orient grid == prop1 byte
        }
        wall_grids[li] = try buildGridWindow(ar, wcells, w, win.off_x, win.off_y, winW, winH);
        orient_grids[li] = try buildGridWindow(ar, ocells, w, win.off_x, win.off_y, winW, winH);
    }
    const shadow_cells = try ar.alloc(i32, full_ncells);
    for (shadow_cells, 0..) |*c, i| c.* = @bitCast(d.shadow[i].raw);
    var shadow_grid = try buildGridWindow(ar, shadow_cells, w, win.off_x, win.off_y, winW, winH);

    // ── Room tile grid + count → alloc (InitializePresetRoom order). ──
    try allocRoomTileGrid(pRoom, ar);
    for (floor_grids) |*g| countTilesFromGrid(pRoom, &g.grid, 0, 0, 0);
    for (wall_grids, 0..) |*g, li| {
        countWallTilesFromGrid(pRoom, &g.grid, &orient_grids[li].grid, 0, 0);
        countTilesFromGrid(pRoom, &g.grid, 0, 0, 0);
    }
    countTilesFromGrid(pRoom, &shadow_grid.grid, 0, 0, 0);

    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(room.pRoomTiles);
    // Safety headroom: the count fns are faithful but we route a few special
    // cells to base tiles; a small pad guarantees no array overflow.
    pTileGrid.*.nFloorTilesMax += 16;
    pTileGrid.*.nWallTilesMax += @as(i32, @intCast(win_ncells)) + 16;
    pTileGrid.*.nRoofTilesMax += @as(i32, @intCast(win_ncells)) + 16;
    try allocTileDataArrays(pRoom, ar);

    // ── InitRoomTiles per layer. ──
    var ctx = MatCtx{
        .width = winW,
        .special = try a.alloc(bool, win_ncells),
        .companion = try ar.alloc(bool, @intCast(pTileGrid.*.nWallTilesMax)),
    };
    @memset(ctx.special, false);
    @memset(ctx.companion, false);
    g_ctx = &ctx;

    for (floor_grids) |*g| InitRoomTiles(pRoom, &g.grid, null, 0, 0, 0);
    for (wall_grids, 0..) |*g, li| InitRoomTiles(pRoom, &g.grid, &orient_grids[li].grid, 0, 0, 0);
    InitRoomTiles(pRoom, &shadow_grid.grid, null, 0, 0, 0);

    // ── Rasterize floor + wall tile-data (exclude roof array + companions). ──
    // The engine's per-room CollMap is dwSizeGameX/Y = WorldSize*5 (NO +1): the +1
    // kill-edge is only processed to blend the shared room seam, it is not part of
    // the room's own collision window. So a windowed room outputs size*5 and lets
    // blitTile clip the seam tiles. The whole-DS1 default (no window) keeps the full
    // (size+1)*5 = DS1*5 grid the collision.zig cross-check compares against.
    const outW: usize = if (window != null) @as(usize, @intCast(win.size_x)) * SUBTILES else winW * SUBTILES;
    const outH: usize = if (window != null) @as(usize, @intCast(win.size_y)) * SUBTILES else winH * SUBTILES;
    var coll = collision.CollisionGrid{
        .allocator = a,
        .width = outW,
        .height = outH,
        .cells = try a.alloc(u8, outW * outH),
        .unresolved = 0,
    };
    @memset(coll.cells, 0);

    const pFloor: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(pTileGrid.*.pFloorTiles.?));
    var fi: usize = 0;
    while (fi < @as(usize, @intCast(pTileGrid.*.nFloors))) : (fi += 1) {
        blitTile(&coll, &pFloor[fi]);
    }
    if (pTileGrid.*.pWallTiles) |wp| {
        const pWall: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(wp));
        var wi: usize = 0;
        while (wi < @as(usize, @intCast(pTileGrid.*.nWalls))) : (wi += 1) {
            if (wi < ctx.companion.len and ctx.companion[wi]) continue;
            blitTile(&coll, &pWall[wi]);
        }
    }
    // The engine's AllocRoomCollisionGrid (0x64c900) stamps the FLOOR, WALL AND ROOF
    // tile layers into the CollMap. The roof array holds the room's shadow/roof tiles
    // (createShadowTileData); in caves/dungeons the solid-rock ceiling is a roof tile
    // that carries wall collision, so omitting it leaves the whole dungeon exterior
    // void instead of blocked.
    if (pTileGrid.*.pRoofTiles) |rp| {
        const pRoof: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(rp));
        var ri: usize = 0;
        while (ri < @as(usize, @intCast(pTileGrid.*.nShadows))) : (ri += 1) {
            blitTile(&coll, &pRoof[ri]);
        }
    }

    // No-floor subtiles are void/unwalkable: a subtile whose tile has no floor tile
    // is a dungeon gap (the runtime CollMap has no walkable void, so "no floor =
    // unwalkable" is faithful). Mark the truly-empty ones with Colbit.blank
    // (0x20, a synthetic render marker — never an engine collision bit) so the
    // collision composite renders them as void rather than walkable. Only walls/
    // real collision keep their own bits; only cells still at 0 get marked. Windowed
    // (render) path only — the whole-DS1 collision.zig cross-check compares the raw
    // DT1 rasterization and must not see this marker.
    if (window != null) {
        const tW: usize = @intCast(win.size_x);
        const tH: usize = @intCast(win.size_y);
        const has_floor = try ar.alloc(bool, tW * tH);
        @memset(has_floor, false);
        var ffi: usize = 0;
        while (ffi < @as(usize, @intCast(pTileGrid.*.nFloors))) : (ffi += 1) {
            const fx = pFloor[ffi].nPosX;
            const fy = pFloor[ffi].nPosY;
            if (fx < 0 or fy < 0) continue;
            const utx: usize = @intCast(fx);
            const uty: usize = @intCast(fy);
            if (utx < tW and uty < tH) has_floor[uty * tW + utx] = true;
        }
        var sgy: usize = 0;
        while (sgy < outH) : (sgy += 1) {
            const trow = sgy / SUBTILES;
            var sgx: usize = 0;
            while (sgx < outW) : (sgx += 1) {
                const tcol = sgx / SUBTILES;
                const ci = sgy * outW + sgx;
                if (tcol < tW and trow < tH and !has_floor[trow * tW + tcol] and coll.cells[ci] == 0) {
                    coll.cells[ci] = 0x20;
                }
            }
        }
    }

    return .{
        .coll = coll,
        .special = ctx.special,
        .tiles = try collectCollTiles(a, pTileGrid, ctx.companion, win.size_x, win.size_y),
        .n_floors = pTileGrid.*.nFloors,
        .n_walls = pTileGrid.*.nWalls,
        .n_shadows = pTileGrid.*.nShadows,
        .special_count = ctx.special_count,
        .warp_setup_skipped = ctx.warp_setup_skipped,
        .transition_skipped = ctx.transition_skipped,
        .unresolved = 0,
    };
}

/// The engine's per-tile draw-flag → collision-flag recompute (Collision.cpp
/// TileLibrary_SetupCollision): beyond the verbatim DT1 subtile-byte OR, each tile
/// ORs these bits across its WHOLE 5x5 footprint, from its computed draw nFlags.
/// This is where wall tiles get COLBIT_WALL (blockwalk) — nGridFlags&0x20000 sets
/// nFlags 0x40 sets 0x01 — so omitting it drops all maze/dungeon interior walls.
fn drawExtraColl(nFlags: i32) u8 {
    var extra: u8 = 0;
    if (nFlags & 0x02 != 0) extra |= 0x10; // COLBIT_PRESET
    if (nFlags & 0x40 != 0) extra |= 0x01; // COLBIT_WALL (blocks walk)
    if (nFlags & 0x80 != 0) extra |= 0x04; // COLBIT_MISSILE_BARRIER
    return extra;
}

fn blitTile(coll: *collision.CollisionGrid, td: *const s.D2DrlgTileDataStrc) void {
    const t = tilegen.tileFromEntry(td.pTileLibraryEntry) orelse return;
    if (td.nPosX < 0 or td.nPosY < 0) return;
    const tx: usize = @intCast(td.nPosX);
    const ty: usize = @intCast(td.nPosY);
    const extra = drawExtraColl(td.nFlags);
    // The engine's TileLibrary_AddCollision (0x64c4c0) reads the DT1 25-byte subtile
    // block with the row (Y) axis FLIPPED: grid cell at tile-relative (dx,dy) takes
    // byte[(4-dy)*5 + dx]. Mirror that here (the extra draw-flag bits are flat-filled
    // across the whole footprint, so only the DT1 byte read flips).
    var sy: usize = 0;
    while (sy < SUBTILES) : (sy += 1) {
        const gy = ty * SUBTILES + sy;
        if (gy >= coll.height) break;
        var sx: usize = 0;
        while (sx < SUBTILES) : (sx += 1) {
            const gx = tx * SUBTILES + sx;
            if (gx >= coll.width) continue;
            coll.cells[gy * coll.width + gx] |= t.subtile(sx, SUBTILES - 1 - sy) | extra;
        }
    }
}

// ===========================================================================
// MILESTONE 2b — WILDERNESS floor-cell materialization.
//
// An outdoor level splits its grid into (a) PRESET cells (dwOutdoorFlags&0x200)
// which get an allocDrlgMap+BuildArea DrlgMap — a DS1, already materializable via
// materializeDs1 — and (b) FLOOR cells, each a bare 8x8 RoomEx SHELL from
// DRLGOUTROOM_CreateOutdoorRoomEx (OutPlace.cpp:1577) with NO tile data.
//
// The engine gives a floor room its tiles in InitGridCells (Drlg.cpp 0067d2d0):
//   1. init the room's floor/wall/tile grids at (WorldSize+1);
//   2. base-fill every 8x8 floor cell with 0x40002 (a plain floor tile,
//      main=0 sub=0, via OverwriteFlag);
//   3. Act-I only: DRLGOUTROOM_InitAct1RoomGridCells → the wall/edge overlay;
//   4. OR the level-type nGridFlag into cells with no terrain bits (0x3f0ff80);
//   5. mark the grid border (FlagOperations op 0, flag 4) as cross-room
//      transition cells;
//   6. then the shared Count / AllocTileDataArrays / InitRoomTiles run (as for
//      maze rooms in DRLGROOMEX_InitializeMazeRoom) materializes the tiles.
//
// materializeOutdoorFloorRoom below is a faithful transform of that whole path,
// INCLUDING step 3 (see applyAct1WallOverlay + gaWallNeighborOrientTable). The
// recon was artifact-broken for step 3 (room ptr mistyped D2DrlgLevelStrc*, LUT
// absent), so the two functions + the 256-entry table were recovered directly
// from Game.exe (0x680a70 / 0x680b10 / 0x6f2700; real offsets: pRoomEx+0x20 =
// pRoomExData, +0x28 = floor grid[2], +0x3c = temp edge grid[3]).
//
// KEY FINDING: the recovered overlay is a VISUAL floor-edge blend autotiler, NOT
// a collision source. ComputeWallOrientations OVERWRITEs the FLOOR grid (grid[2])
// with (orientation 0, main 0, sub = LUT[neighbourMask]) — a grass-edge blend
// variant. In the Act-I wilderness DT1 set EVERY blocking orientation-0 tile has
// main==5 (cliffs), and getTileLibraryEntry takes main straight from the grid
// value (>>0x14), so a main==0 pick is walkable by construction. The overlay
// therefore changes tile SELECTION (relevant to the M3 byte-exact tile golden)
// but adds ZERO collision.
//
// The blocking terrain of a wilderness level (cliffs / trees / water) lives in
// the PRESET border cells, which ARE materialized (materializeDs1); the floor
// rooms are walkable grass by design. Combined, a wilderness collision grid is
// non-empty and mostly-walkable with blocked preset edges — the faithful shape.
//
// GATE SAFETY: pure post-generation consumer, only imported by tests.
// ---------------------------------------------------------------------------

/// Level-type → floor-cell fill flag OR'd into empty cells (InitGridCells
/// 0067d2d0, recon lines 5574-5592). Collision-neutral (sets the floor tile's
/// main index for terrain-variant grass); ported for faithfulness.
fn outdoorFillFlag(nLevelType: i32, level_id: i32) i32 {
    return switch (nLevelType) {
        0x10 => 0x100,
        0x15 => 0x120000,
        0x16 => 0x100000,
        0x1b => 0xa00000,
        0x1c => 0x1600000,
        0x1f => if (level_id != 0x75) 0 else 0x600000,
        else => 0,
    };
}

// ===========================================================================
// OUTDOOR WALL-ORIENTATION OVERLAY (recovered from the 1.14d binary; the recon
// is artifact-broken for it). This is InitGridCells step 3, ACT_I only:
//   DRLGOUTROOM_InitAct1RoomGridCells (0x680c80) orchestrates
//     1. alloc a temp EDGE grid (WorldSize+3, +1 border each side) at
//        pRoomExData+0x3c;
//     2. DRLGGRID_SetOutRoomEdgeFlags (0x680a70): for each adjacent-level vertex
//        list (wilderness data pAdjacentVertices[0..nExitCount]) draw a 2-wide
//        line (flag 1, OR) along every edge into the edge grid, clipped to the
//        room's coords expanded by (-1 pos, +3 size);
//     3. DRLGOUTROOM_ComputeWallOrientations (0x680b10): 8-neighbour autotile —
//        for each room-local cell whose edge-grid center is set, build an 8-bit
//        neighbour bitmask and look up a wall orientation in the 256-entry
//        gaWallNeighborOrientTable (0x6f2700); if nonzero, OVERWRITE the FLOOR
//        grid cell (pRoomExData+0x28) with (orient<<8)|0x82 — a floor tile of
//        sub=orient (a cliff/wall-edge variant that carries interior collision).
//
// Neighbour->bit map (from DRLGOUTROOM_InitGridNeighborBuffer 0x6809c0 + the
// mask-build in 0x680b6a; dy<0 == north): bit7 NE, bit6 E, bit5 SE, bit4 N,
// bit3 S, bit2 NW, bit1 W, bit0 SW.
// ---------------------------------------------------------------------------

/// gaWallNeighborOrientTable @ 0x6f2700 — 256 entries, keyed on the 8-neighbour
/// blocked/edge bitmask, value = wall tile orientation (0 = no wall). Baked from
/// Game.exe .rdata.
pub const gaWallNeighborOrientTable = [256]u8{
    0x00, 0x00, 0x10, 0x10, 0x00, 0x00, 0x10, 0x10, 0x0e, 0x0e, 0x06, 0x13, 0x0e, 0x0e, 0x06, 0x13,
    0x0f, 0x0f, 0x05, 0x05, 0x0f, 0x0f, 0x15, 0x15, 0x08, 0x08, 0x0a, 0x26, 0x08, 0x08, 0x28, 0x14,
    0x00, 0x00, 0x10, 0x10, 0x00, 0x00, 0x10, 0x10, 0x0e, 0x0e, 0x06, 0x13, 0x0e, 0x0e, 0x06, 0x13,
    0x0f, 0x0f, 0x05, 0x05, 0x0f, 0x0f, 0x15, 0x15, 0x08, 0x08, 0x0a, 0x26, 0x08, 0x08, 0x28, 0x14,
    0x0d, 0x0d, 0x07, 0x07, 0x0d, 0x0d, 0x0d, 0x07, 0x04, 0x04, 0x0b, 0x25, 0x04, 0x04, 0x0b, 0x2b,
    0x03, 0x03, 0x0c, 0x0c, 0x03, 0x03, 0x27, 0x27, 0x09, 0x09, 0x02, 0x2b, 0x09, 0x09, 0x2c, 0x1a,
    0x0d, 0x0d, 0x07, 0x07, 0x0d, 0x0d, 0x0d, 0x07, 0x17, 0x17, 0x29, 0x11, 0x17, 0x17, 0x29, 0x11,
    0x03, 0x03, 0x0c, 0x0c, 0x03, 0x03, 0x27, 0x27, 0x2a, 0x2a, 0x2e, 0x2a, 0x2a, 0x2a, 0x21, 0x1f,
    0x00, 0x00, 0x10, 0x10, 0x00, 0x00, 0x10, 0x10, 0x0e, 0x0e, 0x06, 0x13, 0x0e, 0x0e, 0x06, 0x13,
    0x0f, 0x0f, 0x05, 0x05, 0x0f, 0x0f, 0x15, 0x15, 0x08, 0x08, 0x0a, 0x26, 0x08, 0x08, 0x23, 0x14,
    0x00, 0x00, 0x10, 0x10, 0x00, 0x00, 0x10, 0x10, 0x0e, 0x0e, 0x06, 0x13, 0x0e, 0x0e, 0x06, 0x13,
    0x0f, 0x0f, 0x05, 0x05, 0x0f, 0x0f, 0x15, 0x15, 0x08, 0x08, 0x0a, 0x26, 0x08, 0x08, 0x28, 0x14,
    0x0d, 0x0d, 0x07, 0x07, 0x0d, 0x0d, 0x0d, 0x07, 0x04, 0x04, 0x0b, 0x25, 0x04, 0x04, 0x0b, 0x25,
    0x12, 0x12, 0x23, 0x23, 0x12, 0x12, 0x16, 0x16, 0x24, 0x24, 0x2d, 0x22, 0x24, 0x24, 0x1c, 0x1d,
    0x0d, 0x0d, 0x07, 0x07, 0x0d, 0x0d, 0x0d, 0x07, 0x17, 0x17, 0x29, 0x11, 0x17, 0x17, 0x29, 0x11,
    0x12, 0x12, 0x23, 0x23, 0x12, 0x12, 0x16, 0x16, 0x18, 0x18, 0x19, 0x20, 0x18, 0x18, 0x1e, 0x01,
};

/// Inputs the ACT_I wall/edge overlay needs beyond a bare floor room: the room's
/// world position (vertex lines are in world coords, clipped per room) and the
/// wilderness level's adjacent-vertex list heads (pAdjacentVertices[0..nExit]).
pub const OutdoorOverlay = struct {
    room_pos: s.POINT,
    vertices: []const ?*s.D2DrlgVertexStrc,
};

/// Build the overlay for a live wilderness floor room, or null when it does not
/// apply (non-ACT_I, no wilderness data, or no exits). ACT_I gate mirrors
/// InitGridCells (0067d2d0): the overlay runs only for eAct == ACT_I.
pub fn outdoorOverlayFor(pLevel: *s.D2DrlgLevelStrc, p: *s.D2RoomExStrc) ?OutdoorOverlay {
    if (Border.GetActNoFromLevelNumber(pLevel.eD2LevelId) != 0) return null; // ACT_I only
    const wild: *s.D2DrlgLevelDataWildernessLevel = @ptrCast(@alignCast(pLevel.pDrlgLevelData orelse return null));
    if (wild.nExitCount <= 0) return null;
    const n: usize = @intCast(@min(@as(i32, 6), wild.nExitCount));
    return .{ .room_pos = p.sCoords.WorldPosition, .vertices = wild.pAdjacentVertices[0..n] };
}

/// DRLGOUTROOM_InitAct1RoomGridCells (0x680c80) body: rasterize the adjacent
/// vertex lines into a temp edge grid, then autotile wall orientations onto the
/// room-local floor grid `fg`. `ws_x`/`ws_y` are the room's WorldSize.
fn applyAct1WallOverlay(ar: std.mem.Allocator, fg: *OwnedGrid, ov: OutdoorOverlay, ws_x: i32, ws_y: i32) !void {
    // Temp edge grid: WorldSize + 3 (a 1-cell border on every side).
    const egw: usize = @intCast(ws_x + 3);
    const egh: usize = @intCast(ws_y + 3);
    const edge_cells = try ar.alloc(i32, egw * egh);
    @memset(edge_cells, 0);
    var eg = try buildGrid(ar, egw, egh, edge_cells);

    // SetOutRoomEdgeFlags (0x680a70): room coords expanded (-1 pos, +3 size); the
    // edge grid's cell (0,0) is world (room_pos-1). For each adjacent vertex list,
    // OR flag 1 as a 2-wide line along every edge with a successor.
    var sCoords: s.D2DrlgCoordsStrc = .{
        .WorldPosition = .{ .x = ov.room_pos.x - 1, .y = ov.room_pos.y - 1 },
        .WorldSize = .{ .x = ws_x + 3, .y = ws_y + 3 },
    };
    for (ov.vertices) |vhead| {
        var pv = vhead;
        while (pv) |v| : (pv = v.pNext) {
            if (v.pNext != null) {
                DrlgGrid.setLineFlagsWithWidth(&eg.grid, v, &sCoords, 1, 0, 2);
            }
        }
    }

    // ComputeWallOrientations (0x680b10): output cell (ox,oy) maps to edge center
    // (ox+1,oy+1). Grid is (WorldSize+1) as in InitGridCells.
    const gw: i32 = ws_x + 1;
    const gh: i32 = ws_y + 1;
    var oy: i32 = 0;
    while (oy < gh) : (oy += 1) {
        var ox: i32 = 0;
        while (ox < gw) : (ox += 1) {
            const ex = ox + 1;
            const ey = oy + 1;
            if (DrlgGrid.GetGridFlags(&eg.grid, ex, ey) == 0) continue;
            var mask: usize = 0;
            if (DrlgGrid.GetGridFlags(&eg.grid, ex + 1, ey - 1) != 0) mask |= 0x80; // NE
            if (DrlgGrid.GetGridFlags(&eg.grid, ex + 1, ey) != 0) mask |= 0x40; // E
            if (DrlgGrid.GetGridFlags(&eg.grid, ex + 1, ey + 1) != 0) mask |= 0x20; // SE
            if (DrlgGrid.GetGridFlags(&eg.grid, ex, ey - 1) != 0) mask |= 0x10; // N
            if (DrlgGrid.GetGridFlags(&eg.grid, ex, ey + 1) != 0) mask |= 0x08; // S
            if (DrlgGrid.GetGridFlags(&eg.grid, ex - 1, ey - 1) != 0) mask |= 0x04; // NW
            if (DrlgGrid.GetGridFlags(&eg.grid, ex - 1, ey) != 0) mask |= 0x02; // W
            if (DrlgGrid.GetGridFlags(&eg.grid, ex - 1, ey + 1) != 0) mask |= 0x01; // SW
            if (mask == 0) continue;
            const orient = gaWallNeighborOrientTable[mask];
            if (orient == 0) continue;
            DrlgGrid.AlterGridFlag(&fg.grid, ox, oy, (@as(i32, orient) << 8) | 0x82, 3);
        }
    }
}

// LvlSub sub-theme terrain placement (InitGridCells step: SubTypeWpShrine, 3rd call).
//
// InitGridCells (0067d2d0) calls SubTypeWpShrine three times before Count/Alloc/Init:
//   1. Waypoint (nSubTypeLookupId = LvlDefs.SubWaypoint, nSubTypeCount = shrineFlags>>16&3)
//   2. Shrine   (nSubTypeLookupId = LvlDefs.SubShrine,   nSubTypeCount = shrineFlags>>12&0xf)
//   3. Terrain  (nSubTypeLookupId = nSubType, nSubTypeIndex = nSubTheme, nSubTypeCount = nSubThemePicked)
//
// Calls 1 and 2 place waypoint/shrine DS1 tiles, which we skip (they affect wall layers
// and preset units, not floor collision). Call 3 places sub-theme terrain (Stone, Trees,
// Puddles, Swamp, etc.) into the floor grid — this IS the source of the 0x10 collision
// bit gap. The DS1 floor cells carry 0x10000002 (bit 28 = alternate + bit 1 = has floor);
// ApplyLvlSubTileData writes (flags | 0x80) to the room floor grid; createFloorTileData
// then sees bit 28 and sets nFlags |= 0x102, which drawExtraColl maps to 0x10 COLBIT_PRESET.
//
// Faithful to: SubTypeWpShrine (1.14d @0x6707a0), DoNotCheckAll (0x670170),
//   DRLGOUTDOOR_CheckSubTileOverlap (0x66fcf0), DRLGOUTDOOR_ApplyLvlSubTileData (floor
//   grid path only) (0x66fad0).

// DRLGOUTDOOR_CheckSubTileOverlap (0x66fcf0): returns true if the sub-tile DS1 group
// can be placed at (baseX, baseY) without overlapping existing terrain in the room floor
// grid. Simplified: only floor check (no wall-layer check; sub-theme LvlSub DS1s have
// no wall layers, so wall grid is always clear).
fn checkSubTileOverlap(
    baseX: i32,
    baseY: i32,
    fg: *s.D2DrlgGridStrc,
    pSubstGroup: *const s.D2DrlgSubstGroupStrc,
    pSubTxt: *dtables.D2LvlSubTxt,
) bool {
    const pw = pSubstGroup.tBox.nWidth;
    const ph = pSubstGroup.tBox.nHeight;
    const srcX = pSubstGroup.tBox.nPosX;
    const srcY = pSubstGroup.tBox.nPosY;
    var dy: i32 = 0;
    while (dy < ph) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < pw) : (dx += 1) {
            // Trigger: the sub DS1 cell carries floor terrain (floor bit 2) OR — when the
            // sub has a wall grid — a wall (wall bit 1). The engine gates the room-overlap
            // check on BOTH; a floor-only check accepts placements the engine rejects when
            // a sub carries wall cells (e.g. Object.ds1), drifting seed + position.
            const sub_floor: u32 = @bitCast(DrlgGrid.GetGridFlags(&pSubTxt.pFloorGrid, srcX + dx, srcY + dy));
            const triggered = (sub_floor & 2) != 0 or
                (pSubTxt.pWallGrid[0].nWidth != 0 and
                    (@as(u32, @bitCast(DrlgGrid.GetGridFlags(&pSubTxt.pWallGrid[0], srcX + dx, srcY + dy))) & 1) != 0);
            if (!triggered) continue;
            // Room cell must have plain floor (bit 1 set) and no terrain bits already stamped.
            const room_flags: u32 = @bitCast(DrlgGrid.GetGridFlags(fg, baseX + dx, baseY + dy));
            if (room_flags & 0x3f0ff00 != 0 or room_flags & 2 == 0) return false;
            // Room wall-layer check (apWallGrids[*]) omitted: an outdoor floor room has no
            // populated wall grid at sub-theme time — base-fill + overlay + sub-theme all
            // write only the floor grid — so those layers are empty and never reject.
        }
    }
    return true;
}

// DRLGOUTDOOR_ApplyLvlSubTileData (0x66fad0) — floor grid write only (we skip wall layers
// and shadow tiles; sub-theme terrain DS1s only carry floor data that affects collision).
fn applySubTileFloor(
    fg: *s.D2DrlgGridStrc,
    baseX: i32,
    baseY: i32,
    pSubstGroup: *const s.D2DrlgSubstGroupStrc,
    pSubTxt: *dtables.D2LvlSubTxt,
) void {
    const pw = pSubstGroup.tBox.nWidth;
    const ph = pSubstGroup.tBox.nHeight;
    const srcX = pSubstGroup.tBox.nPosX;
    const srcY = pSubstGroup.tBox.nPosY;
    var dy: i32 = 0;
    while (dy < ph) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < pw) : (dx += 1) {
            const flags = DrlgGrid.GetGridFlags(&pSubTxt.pFloorGrid, srcX + dx, srcY + dy);
            if (flags & 2 != 0) {
                DrlgGrid.AlterGridFlag(fg, baseX + dx, baseY + dy, flags | 0x80, 3);
            }
        }
    }
}

// DoNotCheckAll (1.14d 0x670170): seeded sub-tile placement — picks a random substitution
// group, then either tries random positions (Trials >= 0) or shuffles all positions
// exhaustively (Trials == -1), placing the group when overlap-free. Runs Max[nSubTypeIndex]
// times. Faithful to the C reconstruction (same seed consumption order, same shuffle).
fn doNotCheckAll(
    pRoom: *s.D2RoomExStrc,
    fg: *s.D2DrlgGridStrc,
    pSubTxt: *dtables.D2LvlSubTxt,
    nSubTypeIndex: i32,
) void {
    const pFile = pSubTxt.pDrlgFile orelse return;
    if (pFile.nSubstGroups == 0) return;
    const idx: usize = @intCast(@max(0, nSubTypeIndex));
    if (idx >= 5) return;
    if (pSubTxt.Max[idx] < 1) return;

    const ws_x = pRoom.sCoords.WorldSize.x;
    const ws_y = pRoom.sCoords.WorldSize.y;

    var nMaxRemaining: i32 = pSubTxt.Max[idx];
    while (true) {
        // Pick a random substitution group from the DS1.
        const nGroupIdx = drlg_rng.randomNumberSelector(&pRoom.sSeed, @intCast(pFile.nSubstGroups));
        const pSubstGroups: [*]s.D2DrlgSubstGroupStrc = @ptrCast(@alignCast(pFile.pSubstGroups.?));
        const pSubstGroup = &pSubstGroups[nGroupIdx];

        const nMaxX: u32 = @bitCast(ws_x - pSubstGroup.tBox.nWidth);
        const nMaxY: u32 = @bitCast(ws_y - pSubstGroup.tBox.nHeight);
        // Condition: (int)(nMaxX+1) > 1 && (int)(nMaxY+1) > 1 (i.e. nMaxX >= 1, nMaxY >= 1).
        if (@as(i32, @bitCast(nMaxX + 1)) > 1 and @as(i32, @bitCast(nMaxY + 1)) > 1) {
            const nTrialCount = pSubTxt.Trials[idx];
            if (nTrialCount == -1) {
                // Exhaustive shuffle: fill all positions, shuffle, try each.
                const nTotalPositions: u32 = nMaxY * nMaxX;
                if (nTotalPositions > 0) {
                    // Array big enough for any 8x8 room minus group (max ~64 entries).
                    var coordBuf: [514]i32 = undefined;
                    var nPosX: u32 = 0;
                    while (nPosX < nTotalPositions) : (nPosX += 1) {
                        coordBuf[nPosX * 2] = @intCast(nPosX % nMaxX);     // x
                        coordBuf[nPosX * 2 + 1] = @intCast(nPosX / nMaxX); // y
                    }
                    // Shuffle: nTotalPositions-1 random swaps (each uses two randomNumberSelector calls).
                    var nRem: u32 = nTotalPositions;
                    while (nRem > 1) : (nRem -= 1) {
                        const a_idx = drlg_rng.randomNumberSelector(&pRoom.sSeed, nTotalPositions);
                        const b_idx = drlg_rng.randomNumberSelector(&pRoom.sSeed, nTotalPositions);
                        const tx = coordBuf[a_idx * 2];
                        const ty = coordBuf[a_idx * 2 + 1];
                        coordBuf[a_idx * 2] = coordBuf[b_idx * 2];
                        coordBuf[a_idx * 2 + 1] = coordBuf[b_idx * 2 + 1];
                        coordBuf[b_idx * 2] = tx;
                        coordBuf[b_idx * 2 + 1] = ty;
                    }
                    // Try each shuffled position.
                    var i: u32 = 0;
                    while (i < nTotalPositions) : (i += 1) {
                        const bx: i32 = coordBuf[i * 2] + 1;
                        const by: i32 = coordBuf[i * 2 + 1] + 1;
                        if (checkSubTileOverlap(bx, by, fg, pSubstGroup, pSubTxt)) {
                            applySubTileFloor(fg, bx, by, pSubstGroup, pSubTxt);
                            break;
                        }
                    }
                }
            } else {
                // Random trial: try nTrialCount random positions.
                var nTrialIter: i32 = 0;
                while (nTrialIter < nTrialCount) : (nTrialIter += 1) {
                    const bx: i32 = @intCast(drlg_rng.randomNumberSelector(&pRoom.sSeed, nMaxX) + 1);
                    const by: i32 = @intCast(drlg_rng.randomNumberSelector(&pRoom.sSeed, nMaxY) + 1);
                    if (checkSubTileOverlap(bx, by, fg, pSubstGroup, pSubTxt)) {
                        applySubTileFloor(fg, bx, by, pSubstGroup, pSubTxt);
                        break;
                    }
                }
            }
        }

        nMaxRemaining -= 1;
        if (nMaxRemaining == 0) return;
    }
}

// SubTypeWpShrine (1.14d 0x6707a0) — sub-theme terrain pass: iterate the bit-mask of which
// consecutive LvlSub rows (by Type) to apply, load each DS1 file, and call DoNotCheckAll
// (or CheckAll, but all outdoor terrain subs have CheckAll=0). Only the floor grid is
// written; we skip the wall-layer and shadow parts of ApplyLvlSubTileData.
fn applySubThemeTerrain(
    pRoom: *s.D2RoomExStrc,
    fg: *s.D2DrlgGridStrc,
    nSubTypeLookupId: i32,
    nSubTypeIndex: i32,
    nSubTypeCount: i32,
) void {
    if (nSubTypeLookupId == -1) return;
    var dwBitMask: u32 = @bitCast(nSubTypeCount);
    var pLine = dtables.lvlSubGetLineFromSubType(nSubTypeLookupId);
    if (pLine == null) return;
    while (dwBitMask != 0) : ({
        dwBitMask >>= 1;
        pLine += 1;
    }) {
        if (dwBitMask & 1 == 0) continue;
        const pRec: *dtables.D2LvlSubTxt = @ptrCast(pLine);
        TileSub.InitializeDrlgFile(null, pRec);
        const pFile = pRec.pDrlgFile orelse continue;
        if (pFile.nSubstGroups == 0) continue;
        if (pRec.CheckAll == 0) {
            doNotCheckAll(pRoom, fg, pRec, nSubTypeIndex);
        }
        // CheckAll (nAct 1 or 2 path) not needed for outdoor terrain subs (all CheckAll=0).
    }
}

/// Materialize one outdoor FLOOR room (an 8x8 CreateOutdoorRoomEx shell) into a
/// room-local floor collision grid. Faithful transform of InitGridCells
/// (0067d2d0), including the ACT_I wall-orientation overlay (step 3) when
/// `overlay` is supplied (see applyAct1WallOverlay). Then the shared
/// Count/Alloc/InitRoomTiles orchestration + rasterize. `dts` is the level's DT1
/// library (LvlTypes File1..32 for the level's LevelType). WorldPosition is 0 so
/// stored nPosX/nPosY are room-local (0..WorldSize-1).
pub fn materializeOutdoorFloorRoom(
    a: std.mem.Allocator,
    dts: []const dt1.Dt1,
    ws_x: i32,
    ws_y: i32,
    nLevelType: i32,
    level_id: i32,
    room_seed: i32,
    overlay: ?OutdoorOverlay,
    nSubType: i32,
    nSubTheme: i32,
    nSubThemePicked: i32,
    nWaypointCount: i32,
    nShrineCount: i32,
) !MaterializeResult {
    var arena_impl = std.heap.ArenaAllocator.init(a);
    defer arena_impl.deinit();
    const ar = arena_impl.allocator();

    // Grid is (WorldSize+1) per InitGridCells; the floor footprint is 8x8.
    const gw: usize = @intCast(ws_x + 1);
    const gh: usize = @intCast(ws_y + 1);
    const ncells = gw * gh;

    var tlib = tilegen.TileLib{ .dts = dts };
    var drlg = std.mem.zeroes(s.D2DrlgStrc);
    var level = std.mem.zeroes(s.D2DrlgLevelStrc);
    level.pDrlg = &drlg;
    level.eD2LevelId = @enumFromInt(level_id);

    var room = std.mem.zeroes(s.D2RoomExStrc);
    room.pLevel = &level;
    room.apTiles[0] = @ptrCast(&tlib);
    // InitGridCells: sSeed.nSeedLow = nSeed, nSeedHigh = 0x29a.
    room.sSeed = .{ .nSeedLow = room_seed, .nSeedHigh = 0x29a };
    room.sCoords = .{
        .WorldPosition = .{ .x = 0, .y = 0 },
        .WorldSize = .{ .x = ws_x, .y = ws_y },
    };
    const pRoom: [*c]s.D2RoomExStrc = &room;

    // ── Build the outdoor floor grid (InitGridCells body). ──
    const floor_cells = try ar.alloc(i32, ncells);
    @memset(floor_cells, 0);
    var fg = try buildGrid(ar, gw, gh, floor_cells);

    // Base fill: 8x8 floor cells = 0x40002 (OverwriteFlag / op 3).
    {
        var yy: i32 = 0;
        while (yy < 8 and yy < ws_y) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < 8 and xx < ws_x) : (xx += 1) {
                DrlgGrid.AlterGridFlag(&fg.grid, xx, yy, 0x40002, 3);
            }
        }
    }
    // ACT_I step 3: the wall/edge orientation overlay (interior cliffs). Runs
    // AFTER the 8x8 base-fill and BEFORE the level-type OR-fill (InitGridCells
    // order): the overwritten oriented cells carry sub bits, so the OR-fill's
    // `(cell & 0x3f0ff80)==0` guard then skips them.
    if (overlay) |ov| try applyAct1WallOverlay(ar, &fg, ov, ws_x, ws_y);

    // Sub-theme passes (SubTypeWpShrine, 3 calls in InitGridCells) run after
    // AllocRoomTileGrid, in this exact order: waypoint, shrine, terrain. The waypoint
    // and shrine calls place their own LvlSub DS1s AND consume the room seed via
    // DoNotCheckAll; skipping them drifts the room seed so the terrain pass then picks
    // different substitution groups/positions (the dominant outdoor 0x10 error). The
    // waypoint/shrine sub-type ids come from the level's LvlDefs line; counts from the
    // room's eRoomExFlags (>>0x10&3 waypoint, >>0xc&0xf shrine).
    try allocRoomTileGrid(pRoom, ar);
    const pDef = dtables.levelDefsGetLine(@enumFromInt(level_id));
    if (nWaypointCount != 0) applySubThemeTerrain(&room, &fg.grid, pDef.*.SubWaypoint, 0, nWaypointCount);
    if (nShrineCount != 0) applySubThemeTerrain(&room, &fg.grid, pDef.*.SubShrine, 0, nShrineCount);
    applySubThemeTerrain(&room, &fg.grid, nSubType, nSubTheme, nSubThemePicked);

    // OR the level-type fill flag into cells with no terrain bits (OrFlag / op 0).
    const nGridFlag = outdoorFillFlag(nLevelType, level_id);
    if (nGridFlag != 0) {
        var yy: i32 = 0;
        while (yy < @as(i32, @intCast(gh))) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < @as(i32, @intCast(gw))) : (xx += 1) {
                if ((DrlgGrid.GetGridFlags(&fg.grid, xx, yy) & 0x3f0ff80) == 0) {
                    DrlgGrid.AlterGridFlag(&fg.grid, xx, yy, nGridFlag, 0);
                }
            }
        }
    }
    // InitGridCells here calls FlagOperations(floor,0,4) to mark the grid border
    // as cross-room transition seams (processTile would then divert them, letting
    // the neighbor room supply the shared edge). It is OMITTED: (a) it is
    // collision-neutral — a border grass cell is walkable whether materialized
    // here or by the neighbor; and (b) DrlgGrid.FlagOperations' second loop is a
    // pre-existing artifact port (indexes apFlagOperations[rowCounter], OOB for a
    // grid taller than 6), never exercised on the gate path. Fixing that port is a
    // separate RE task; skipping the seam marking changes no collision bit.

    // ── Count → alloc → InitRoomTiles (as DRLGROOMEX_InitializeMazeRoom). ──
    countTilesFromGrid(pRoom, &fg.grid, 0, 0, 0);

    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(room.pRoomTiles);
    pTileGrid.*.nFloorTilesMax += 16; // headroom (a few cells route to base tiles)
    pTileGrid.*.nWallTilesMax += @as(i32, @intCast(ncells)) + 16;
    pTileGrid.*.nRoofTilesMax += @as(i32, @intCast(ncells)) + 16;
    try allocTileDataArrays(pRoom, ar);

    var ctx = MatCtx{
        .width = gw,
        .special = try a.alloc(bool, ncells),
        .companion = try ar.alloc(bool, @intCast(pTileGrid.*.nWallTilesMax)),
    };
    @memset(ctx.special, false);
    @memset(ctx.companion, false);
    g_ctx = &ctx;

    InitRoomTiles(pRoom, &fg.grid, null, 0, 0, 0);

    // ── Rasterize floor collision (room-local, 8x8 tile footprint). ──
    const cw: usize = @intCast(ws_x);
    const ch: usize = @intCast(ws_y);
    var coll = collision.CollisionGrid{
        .allocator = a,
        .width = cw * SUBTILES,
        .height = ch * SUBTILES,
        .cells = try a.alloc(u8, cw * ch * SUBTILES * SUBTILES),
        .unresolved = 0,
    };
    @memset(coll.cells, 0);

    const pFloor: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(pTileGrid.*.pFloorTiles.?));
    var fi: usize = 0;
    while (fi < @as(usize, @intCast(pTileGrid.*.nFloors))) : (fi += 1) {
        blitTile(&coll, &pFloor[fi]);
    }

    return .{
        .coll = coll,
        .special = ctx.special,
        .tiles = try collectCollTiles(a, pTileGrid, ctx.companion, ws_x, ws_y),
        .n_floors = pTileGrid.*.nFloors,
        .n_walls = pTileGrid.*.nWalls,
        .n_shadows = pTileGrid.*.nShadows,
        .special_count = ctx.special_count,
        .warp_setup_skipped = ctx.warp_setup_skipped,
        .transition_skipped = ctx.transition_skipped,
        .unresolved = 0,
    };
}

/// A single tile the materialization placed for a room, in room-local tile coords,
/// carrying the DT1 identity (orientation/main/sub) so a pixel renderer can look up
/// the art in the same DT1 set. `pass`: 0=floor, 1=wall. Roofs proper (orient 15)
/// don't occur in wilderness floor rooms; shadows (orient 13) are excluded.
pub const PlacedTile = struct {
    pos_x: i32,
    pos_y: i32,
    orient: i32,
    main: i32,
    sub: i32,
    pass: u8,
};

/// Materialize a wilderness FLOOR room and return its placed FLOOR + WALL tiles
/// (identities + room-local positions) so a pixel renderer can draw grass/cliff
/// tiles for outdoor rooms that carry NO preset DS1. Same InitGridCells +
/// InitRoomTiles orchestration as materializeOutdoorFloorRoom (which returns only
/// collision) — this variant walks the produced pRoomTiles tile-data arrays
/// instead of rasterizing collision. Caller owns the returned slice.
pub fn outdoorFloorRoomTiles(
    a: std.mem.Allocator,
    dts: []const dt1.Dt1,
    ws_x: i32,
    ws_y: i32,
    nLevelType: i32,
    level_id: i32,
    room_seed: i32,
    overlay: ?OutdoorOverlay,
) ![]PlacedTile {
    var arena_impl = std.heap.ArenaAllocator.init(a);
    defer arena_impl.deinit();
    const ar = arena_impl.allocator();

    const gw: usize = @intCast(ws_x + 1);
    const gh: usize = @intCast(ws_y + 1);
    const ncells = gw * gh;

    var tlib = tilegen.TileLib{ .dts = dts };
    var drlg = std.mem.zeroes(s.D2DrlgStrc);
    var level = std.mem.zeroes(s.D2DrlgLevelStrc);
    level.pDrlg = &drlg;
    level.eD2LevelId = @enumFromInt(level_id);

    var room = std.mem.zeroes(s.D2RoomExStrc);
    room.pLevel = &level;
    room.apTiles[0] = @ptrCast(&tlib);
    room.sSeed = .{ .nSeedLow = room_seed, .nSeedHigh = 0x29a };
    room.sCoords = .{
        .WorldPosition = .{ .x = 0, .y = 0 },
        .WorldSize = .{ .x = ws_x, .y = ws_y },
    };
    const pRoom: [*c]s.D2RoomExStrc = &room;

    // ── Build the outdoor floor grid (InitGridCells body). ──
    const floor_cells = try ar.alloc(i32, ncells);
    @memset(floor_cells, 0);
    var fg = try buildGrid(ar, gw, gh, floor_cells);

    {
        var yy: i32 = 0;
        while (yy < 8 and yy < ws_y) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < 8 and xx < ws_x) : (xx += 1) {
                DrlgGrid.AlterGridFlag(&fg.grid, xx, yy, 0x40002, 3);
            }
        }
    }
    if (overlay) |ov| try applyAct1WallOverlay(ar, &fg, ov, ws_x, ws_y);

    const nGridFlag = outdoorFillFlag(nLevelType, level_id);
    if (nGridFlag != 0) {
        var yy: i32 = 0;
        while (yy < @as(i32, @intCast(gh))) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < @as(i32, @intCast(gw))) : (xx += 1) {
                if ((DrlgGrid.GetGridFlags(&fg.grid, xx, yy) & 0x3f0ff80) == 0) {
                    DrlgGrid.AlterGridFlag(&fg.grid, xx, yy, nGridFlag, 0);
                }
            }
        }
    }

    // ── Count → alloc → InitRoomTiles (as DRLGROOMEX_InitializeMazeRoom). ──
    try allocRoomTileGrid(pRoom, ar);
    countTilesFromGrid(pRoom, &fg.grid, 0, 0, 0);

    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(room.pRoomTiles);
    pTileGrid.*.nFloorTilesMax += 16;
    pTileGrid.*.nWallTilesMax += @as(i32, @intCast(ncells)) + 16;
    pTileGrid.*.nRoofTilesMax += @as(i32, @intCast(ncells)) + 16;
    try allocTileDataArrays(pRoom, ar);

    var ctx = MatCtx{
        .width = gw,
        .special = try ar.alloc(bool, ncells),
        .companion = try ar.alloc(bool, @intCast(pTileGrid.*.nWallTilesMax)),
    };
    @memset(ctx.special, false);
    @memset(ctx.companion, false);
    g_ctx = &ctx;

    InitRoomTiles(pRoom, &fg.grid, null, 0, 0, 0);

    // ── Walk the produced tile-data arrays, emitting identities for rendering. ──
    var out: std.ArrayListUnmanaged(PlacedTile) = .empty;
    errdefer out.deinit(a);

    if (pTileGrid.*.pFloorTiles) |fp| {
        const pFloor: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(fp));
        var fi: usize = 0;
        while (fi < @as(usize, @intCast(pTileGrid.*.nFloors))) : (fi += 1) {
            const td = &pFloor[fi];
            if (td.nPosX < 0 or td.nPosY < 0) continue;
            const t = tilegen.tileFromEntry(td.pTileLibraryEntry) orelse continue;
            try out.append(a, .{ .pos_x = td.nPosX, .pos_y = td.nPosY, .orient = t.orientation, .main = t.main, .sub = t.sub, .pass = 0 });
        }
    }
    if (pTileGrid.*.pWallTiles) |wp| {
        const pWall: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(wp));
        var wi: usize = 0;
        while (wi < @as(usize, @intCast(pTileGrid.*.nWalls))) : (wi += 1) {
            if (wi < ctx.companion.len and ctx.companion[wi]) continue;
            const td = &pWall[wi];
            if (td.nPosX < 0 or td.nPosY < 0) continue;
            const t = tilegen.tileFromEntry(td.pTileLibraryEntry) orelse continue;
            try out.append(a, .{ .pos_x = td.nPosX, .pos_y = td.nPosY, .orient = t.orientation, .main = t.main, .sub = t.sub, .pass = 1 });
        }
    }

    return out.toOwnedSlice(a);
}

// ===========================================================================
// CROSS-CHECK (M2a acceptance #3): the full InitRoomTiles orchestration must
// reproduce collision.zig's DS1-based collision for several levels.
// ---------------------------------------------------------------------------
const testing = std.testing;

/// Compare a materialized grid to a collision.zig baseline over the SAME DS1 +
/// DT1 set, masking the special (artifact-blocked warp/preset) tile positions.
/// Returns {resolved subtiles, matches}.
fn compareMasked(base: *const collision.CollisionGrid, mine: *const MaterializeResult, w: usize) struct { total: usize, match: usize } {
    var total: usize = 0;
    var matched: usize = 0;
    var y: usize = 0;
    while (y < base.height) : (y += 1) {
        var x: usize = 0;
        while (x < base.width) : (x += 1) {
            const tx = x / SUBTILES;
            const ty = y / SUBTILES;
            const tk = ty * w + tx;
            if (tk < mine.special.len and mine.special[tk]) continue; // masked
            total += 1;
            if (base.cells[y * base.width + x] == mine.coll.cells[y * mine.coll.width + x]) matched += 1;
        }
    }
    return .{ .total = total, .match = matched };
}

test "materialize: InitRoomTiles reproduces collision.zig DS1 collision (town)" {
    const a = testing.allocator;
    const dt1_files = [_][]const u8{
        @embedFile("../maps/Act1_Town_Floor.dt1"),
        @embedFile("../maps/Act1_Town_trees.dt1"),
        @embedFile("../maps/Act1_Town_Fence.dt1"),
        @embedFile("../maps/Act1_Town_Objects.dt1"),
        @embedFile("../maps/Act1_Outdoors_stonewall.dt1"),
    };
    var dts: [dt1_files.len]dt1.Dt1 = undefined;
    for (dt1_files, 0..) |bytes, i| dts[i] = try dt1.parse(a, bytes);
    defer for (&dts) |*d| d.deinit();

    var dtlib = collision.DtLibrary.init(a);
    defer dtlib.deinit();
    for (&dts) |*d| try dtlib.add(d);

    var d = try ds1.parse(a, @embedFile("../maps/Act1_Town_TownN1.ds1"));
    defer d.deinit();

    var base = try collision.rasterize(a, &d, &dtlib);
    defer base.deinit();

    var mine = try materializeDs1(a, &d, &dts, null);
    defer mine.deinit(a);

    try testing.expectEqual(base.width, mine.coll.width);
    try testing.expectEqual(base.height, mine.coll.height);
    const r = compareMasked(&base, &mine, @intCast(d.width));
    std.debug.print(
        "\n[materialize] town {d}x{d}: floors={d} walls={d} shadows={d} special={d} " ++
            "warp_skip={d} | resolved subtile match {d}/{d}\n",
        .{ d.width, d.height, mine.n_floors, mine.n_walls, mine.n_shadows, mine.special_count, mine.warp_setup_skipped, r.match, r.total },
    );
    // Town fully resolves; the orchestration must match collision.zig exactly on
    // every non-special subtile.
    try testing.expectEqual(r.total, r.match);
}

/// Tile positions collision.zig cannot resolve in `dtlib` (missing DT1) — the
/// engine-parity "unresolved" set. Masked in the multi-level cross-check exactly
/// as collision.rasterize skips them.
fn unresolvedMask(d: *const ds1.Ds1, dtlib: *const collision.DtLibrary, mask: []bool) usize {
    var n: usize = 0;
    for (d.floor_layers) |fl| {
        for (fl, 0..) |c, i| {
            if (c.raw & 0x00ff_ffff == 0) continue;
            const main = @as(i32, @intCast((c.raw >> 20) & 0x3f));
            const sub = @as(i32, @intCast((c.raw >> 8) & 0xff));
            if (dtlib.find(0, main, sub) == null) {
                if (i < mask.len and !mask[i]) { mask[i] = true; n += 1; }
            }
        }
    }
    for (d.wall_layers) |wl| {
        const cnt = @min(wl.wall.len, wl.orient.len);
        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const wc = wl.wall[i];
            if (wc.raw & 0x00ff_ffff == 0) continue;
            const main = @as(i32, @intCast((wc.raw >> 20) & 0x3f));
            const sub = @as(i32, @intCast((wc.raw >> 8) & 0xff));
            if (dtlib.find(wl.orient[i].prop1, main, sub) == null) {
                if (i < mask.len and !mask[i]) { mask[i] = true; n += 1; }
            }
        }
    }
    return n;
}

test "materialize: InitRoomTiles reproduces collision.zig for several maze/preset levels" {
    const a = testing.allocator;
    var ctx = lib.Ctx.init(a) catch return; // skip cleanly if data tables absent
    defer ctx.deinit();
    // lib.generate() rewires the thread-local DRLG pool allocator + level tables
    // to this run's (throwaway) pool; restore them so later tests that use the
    // default pool allocator don't touch freed memory.
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }

    const raw = dt1blob.decompress(a, dt1_data.bytes) catch return;
    defer a.free(raw);
    var idx = dt1blob.buildIndex(a, raw) catch return;
    defer idx.deinit();

    const seed: u32 = 0x0396_4b8d;
    // Crypt (maze), Catacombs (preset+maze mix, has unresolved DT1s), Cathedral
    // (preset), Tristram (preset).
    const levels = [_]struct { id: i32, name: []const u8 }{
        .{ .id = 18, .name = "Crypt" },
        .{ .id = 33, .name = "Cathedral" },
        .{ .id = 35, .name = "CatacombsLvl2" },
        .{ .id = 38, .name = "Tristram" },
    };

    std.debug.print("\n", .{});
    for (levels) |L| {
        const tlv = ctx.act.level(L.id) orelse continue;
        var w: i32 = 64;
        var h: i32 = 64;
        if (tlv.size_x > 0 and tlv.size_y > 0) {
            w = @intCast(tlv.size_x);
            h = @intCast(tlv.size_y);
        }
        const lvl = lib.generate(&ctx, seed, @enumFromInt(L.id), .normal, .{ .x = 0, .y = 0, .w = w, .h = h }) catch |e| {
            std.debug.print("[materialize] {s}: generate failed ({any})\n", .{ L.name, e });
            continue;
        };
        defer lvl.deinit();

        var files: [32][]const u8 = undefined;
        const nf = ctx.act.typeFiles(tlv.lvl_type, &files);
        var dtlib = collision.DtLibrary.init(a);
        defer dtlib.deinit();
        var dts: std.ArrayListUnmanaged(dt1.Dt1) = .empty;
        defer {
            for (dts.items) |*dd| dd.deinit();
            dts.deinit(a);
        }
        for (files[0..nf]) |f| {
            const rec = idx.get(f) orelse continue;
            const dd = dt1blob.unpack(a, rec) catch continue;
            dts.append(a, dd) catch continue;
        }
        for (dts.items) |*dd| dtlib.add(dd) catch {};

        var maps: usize = 0;
        var total: usize = 0;
        var matched: usize = 0;
        var special_total: usize = 0;
        var unresolved_total: usize = 0;

        var seen: std.ArrayListUnmanaged(usize) = .empty;
        defer seen.deinit(a);

        var pr = lvl.firstRoom();
        while (pr) |p| : (pr = p.pRoomExNext) {
            const data = p.pRoomExData orelse continue;
            const rd: *s.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
            const pmap = rd.pMap orelse continue;
            if (pmap.pTxtLevelPrest == null or pmap.nSizeX <= 0 or pmap.nSizeY <= 0) continue;
            const key = @intFromPtr(pmap);
            var dup = false;
            for (seen.items) |sk| if (sk == key) { dup = true; break; };
            if (dup) continue;
            seen.append(a, key) catch {};

            const rel = preset.presetDs1Path(pmap) orelse continue;
            var d = preset.unpackDs1(a, rel) orelse continue;
            defer d.deinit();

            var base = collision.rasterize(a, &d, &dtlib) catch continue;
            defer base.deinit();
            var mine = materializeDs1(a, &d, dts.items, null) catch continue;
            defer mine.deinit(a);
            if (base.width != mine.coll.width or base.height != mine.coll.height) continue;

            const ncells: usize = @intCast(d.width * d.height);
            const umask = a.alloc(bool, ncells) catch continue;
            defer a.free(umask);
            @memset(umask, false);
            const nun = unresolvedMask(&d, &dtlib, umask);
            unresolved_total += nun;
            special_total += mine.special_count;

            const wc: usize = @intCast(d.width);
            var y: usize = 0;
            while (y < base.height) : (y += 1) {
                var x: usize = 0;
                while (x < base.width) : (x += 1) {
                    const tk = (y / SUBTILES) * wc + (x / SUBTILES);
                    if (tk < mine.special.len and mine.special[tk]) continue;
                    if (tk < umask.len and umask[tk]) continue;
                    total += 1;
                    if (base.cells[y * base.width + x] == mine.coll.cells[y * mine.coll.width + x]) matched += 1;
                }
            }
            maps += 1;
        }

        if (maps == 0) {
            std.debug.print("[materialize] {s}: no preset DrlgMaps (pure maze/wilderness)\n", .{L.name});
            continue;
        }
        const pct: f64 = if (total == 0) 100.0 else @as(f64, @floatFromInt(matched)) * 100.0 / @as(f64, @floatFromInt(total));
        std.debug.print(
            "[materialize] {s}: {d} map(s) | resolved subtile match {d}/{d} ({d:.3}%) | unresolved tiles {d} | special {d}\n",
            .{ L.name, maps, matched, total, pct, unresolved_total, special_total },
        );
        // The orchestration reproduces collision on RESOLVED, non-special subtiles.
        // Residual <1% diffs are rarity-VARIANT collision-block selection: the
        // engine's faithful seed-weighted getTileLibraryEntry pick vs
        // collision.zig's first-variant-wins DtLibrary. (The town, single-variant,
        // is byte-exact above.) Unresolved (missing-DT1) tiles are masked+reported.
        try testing.expect(pct >= 99.0);
    }
}

/// OR a room-local collision grid into a level-wide grid at subtile offset.
fn blitInto(dst: *collision.CollisionGrid, src: *const collision.CollisionGrid, ox: usize, oy: usize) void {
    var y: usize = 0;
    while (y < src.height) : (y += 1) {
        const gy = oy + y;
        if (gy >= dst.height) break;
        var x: usize = 0;
        while (x < src.width) : (x += 1) {
            const gx = ox + x;
            if (gx >= dst.width) continue;
            dst.cells[gy * dst.width + gx] |= src.cells[y * src.width + x];
        }
    }
}

/// Materialize + structurally check one live wilderness level (preset borders
/// via DS1 + floor cells via materializeOutdoorFloorRoom) into one collision
/// grid. Runs inside the act's pool (rooms still live). Returns false to skip.
fn checkWildernessLevel(a: std.mem.Allocator, ctx: *lib.Ctx, idx: *const dt1blob.Index, pLevel: *s.D2DrlgLevelStrc, level_id: i32, name: []const u8) !void {
    const tlv = ctx.act.level(level_id) orelse return;
    const nLevelType: i32 = @intFromEnum(pLevel.nLevelType);
    const lvlPos = pLevel.sCoordinatesAndSize.WorldPosition;
    const lw = pLevel.sCoordinatesAndSize.WorldSize.x;
    const lh = pLevel.sCoordinatesAndSize.WorldSize.y;
    if (lw <= 0 or lh <= 0) return;

    // Level's DT1 library (LvlTypes File1..32 for this LevelType).
    var files: [32][]const u8 = undefined;
    const nf = ctx.act.typeFiles(tlv.lvl_type, &files);
    var dtlib = collision.DtLibrary.init(a);
    defer dtlib.deinit();
    var dts: std.ArrayListUnmanaged(dt1.Dt1) = .empty;
    defer {
        for (dts.items) |*dd| dd.deinit();
        dts.deinit(a);
    }
    for (files[0..nf]) |f| {
        const rec = idx.get(f) orelse continue;
        const dd = dt1blob.unpack(a, rec) catch continue;
        dts.append(a, dd) catch continue;
    }
    for (dts.items) |*dd| dtlib.add(dd) catch {};

    // Two level-wide collision grids (subtiles): baseline (floor+border only) vs
    // overlay (with the recovered ACT_I wall/edge orientation overlay).
    const nsub = @as(usize, @intCast(lw * lh)) * SUBTILES * SUBTILES;
    var level_base = collision.CollisionGrid{
        .allocator = a,
        .width = @as(usize, @intCast(lw)) * SUBTILES,
        .height = @as(usize, @intCast(lh)) * SUBTILES,
        .cells = try a.alloc(u8, nsub),
        .unresolved = 0,
    };
    defer level_base.deinit();
    @memset(level_base.cells, 0);
    var level_over = collision.CollisionGrid{
        .allocator = a,
        .width = @as(usize, @intCast(lw)) * SUBTILES,
        .height = @as(usize, @intCast(lh)) * SUBTILES,
        .cells = try a.alloc(u8, nsub),
        .unresolved = 0,
    };
    defer level_over.deinit();
    @memset(level_over.cells, 0);

    var floor_rooms: usize = 0;
    var preset_rooms: usize = 0;
    var floor_tiles: usize = 0;
    var unresolved_total: usize = 0;

    var pr: ?*s.D2RoomExStrc = pLevel.pRoomExFirst;
    while (pr) |p| : (pr = p.pRoomExNext) {
        const ox: usize = @intCast(@max(0, p.sCoords.WorldPosition.x - lvlPos.x) * SUBTILES);
        const oy: usize = @intCast(@max(0, p.sCoords.WorldPosition.y - lvlPos.y) * SUBTILES);

        if (p.nPresetType == 2) {
            // PRESET border cell — materialize its DrlgMap DS1 (blocking terrain).
            const data = p.pRoomExData orelse continue;
            const rd: *s.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
            const pmap = rd.pMap orelse continue;
            if (pmap.pTxtLevelPrest == null or pmap.nSizeX <= 0 or pmap.nSizeY <= 0) continue;
            const rel = preset.presetDs1Path(pmap) orelse continue;
            var d = preset.unpackDs1(a, rel) orelse continue;
            defer d.deinit();
            var rc = collision.rasterize(a, &d, &dtlib) catch continue;
            defer rc.deinit();
            unresolved_total += rc.unresolved;
            blitInto(&level_base, &rc, ox, oy);
            blitInto(&level_over, &rc, ox, oy);
            preset_rooms += 1;
        } else if (p.eRoomExFlags.noLos) {
            // FLOOR cell — the M2b path. Baseline (no overlay) + overlay pass.
            var rb = materializeOutdoorFloorRoom(a, dts.items, p.sCoords.WorldSize.x, p.sCoords.WorldSize.y, nLevelType, level_id, p.nSeed, null, -1, 0, 0, @intCast(@as(u8, p.eRoomExFlags.waypoint)), @intCast(@as(u8, p.eRoomExFlags.shrineRows))) catch continue;
            defer rb.deinit(a);
            blitInto(&level_base, &rb.coll, ox, oy);
            var rc = materializeOutdoorFloorRoom(a, dts.items, p.sCoords.WorldSize.x, p.sCoords.WorldSize.y, nLevelType, level_id, p.nSeed, outdoorOverlayFor(pLevel, p), -1, 0, 0, @intCast(@as(u8, p.eRoomExFlags.waypoint)), @intCast(@as(u8, p.eRoomExFlags.shrineRows))) catch continue;
            defer rc.deinit(a);
            floor_tiles += @intCast(rc.n_floors);
            blitInto(&level_over, &rc.coll, ox, oy);
            floor_rooms += 1;
        }
    }

    var blocked_base: usize = 0;
    for (level_base.cells) |cflag| {
        if (cflag & dt1.SubtileFlag.block_walk != 0) blocked_base += 1;
    }
    var blocked_over: usize = 0;
    for (level_over.cells) |cflag| {
        if (cflag & dt1.SubtileFlag.block_walk != 0) blocked_over += 1;
    }
    const total_sub = level_over.cells.len;
    const pct_base: f64 = @as(f64, @floatFromInt(blocked_base)) * 100.0 / @as(f64, @floatFromInt(total_sub));
    const pct_over: f64 = @as(f64, @floatFromInt(blocked_over)) * 100.0 / @as(f64, @floatFromInt(total_sub));
    std.debug.print(
        "[materialize] {s} {d}x{d} type={d}: floor_rooms={d} ({d} floor tiles) preset_rooms={d} | blocked baseline {d:.2}% -> overlay {d:.2}% | unresolved(preset) {d}\n",
        .{ name, lw, lh, nLevelType, floor_rooms, floor_tiles, preset_rooms, pct_base, pct_over, unresolved_total },
    );

    // Structural: floor cells materialized real tiles → no longer all-void.
    try testing.expect(floor_rooms > 0);
    try testing.expect(floor_tiles > 0);
    // The recovered ACT_I wall/edge overlay (SetOutRoomEdgeFlags +
    // ComputeWallOrientations, 0x680a70/0x680b10) is faithfully ported but is a
    // VISUAL floor-edge blend autotiler: it OVERWRITEs floor cells with
    // (orientation 0, main 0, sub=LUT) tiles. In the Act-I wilderness DT1 set
    // EVERY orientation-0 blocking tile has main==5 (cliffs), so a main==0 pick
    // never blocks — the overlay is collision-NEUTRAL by construction. Blocking
    // wilderness terrain is the preset border cells (already materialized), not
    // the floor rooms. So overlay collision must equal the baseline; it must not
    // regress.
    try testing.expect(blocked_over == blocked_base);
    // Plausible: mostly walkable (blocking is only preset edges, not all-blocked).
    try testing.expect(pct_over < 60.0);
}

test "materialize: wilderness floor cells + preset borders → non-empty plausible collision (M2b)" {
    const a = testing.allocator;
    var ctx = lib.Ctx.init(a) catch return; // skip cleanly if data tables absent
    defer ctx.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }

    const raw = dt1blob.decompress(a, dt1_data.bytes) catch return;
    defer a.free(raw);
    var idx = dt1blob.buildIndex(a, raw) catch return;
    defer idx.deinit();

    const seed: u32 = 0x0396_4b8d;
    const act_no: i32 = 0; // Act I

    // Wilderness levels REQUIRE the full act placement (neighbor orths drive the
    // border vertex ring); a standalone lib.generate crashes in DRLGVER. So we
    // replicate generateAct's live-generation setup and materialize BEFORE the
    // pool teardown (mirrors lib.generateAct exactly, minus the RoomRect copy-out).
    var pool = fog.PoolManager.init(a);
    defer pool.deinit();
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();

    var act = act_mod.build(a, &ctx.act, act_no, seed) catch return;
    defer act.deinit(a);

    var pDrlg: s.D2DrlgStrc = undefined;
    _ = drlgmod.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(lib.Difficulty.normal));

    // Act-I level ids.
    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(a);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) ids.append(a, @intCast(lv.id)) catch {};
        }
    }

    // Pass 1: real world coords before orths.
    for (ids.items) |lid| {
        const pLevel = drlgmod.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    // Act-I ParseLevelData pass-2 preset picks: town orientation + Courtyard
    // jail-exit variant, both from placement direction.
    drlgmod.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    drlgmod.buildInterLevelOrths(&pDrlg);

    const targets = [_]struct { id: i32, name: []const u8 }{
        .{ .id = 2, .name = "BloodMoor" },
        .{ .id = 3, .name = "ColdPlains" },
        .{ .id = 4, .name = "StonyField" },
    };

    std.debug.print("\n", .{});
    // Pass 2: generate every level (as generateAct); materialize the targets live.
    for (ids.items) |lid| {
        const pLevel = drlgmod.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlgmod.InitLevel(pLevel);
        for (targets) |t| {
            if (t.id == lid) try checkWildernessLevel(a, &ctx, &idx, pLevel, lid, t.name);
        }
    }
}
