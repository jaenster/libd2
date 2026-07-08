//! Faithful Zig transform of the DRLGROOMTILE_* tile-builders whose bodies live
//! in ghidra-reconstruct/output/D2Common/Drlg/Drlg.cpp (namespace D2Common::Drlg)
//! plus the D2Common::Dungeon tile-project lookup they bottom out in
//! (Dungeon.cpp TILEPROJECT_LookupTilesInAllProjects -> D2CMP FINDTILE_Lookup).
//!
//! These resolve a room's grid cells (main/sub/orientation) against the LEVEL's
//! loaded DT1 tile library into D2DrlgTileDataStrc entries. The "tile library
//! entry" the engine stores (D2TileLibraryEntryStrc*) is, for us, a parsed
//! `dt1.Tile*` — it carries exactly the identity + 5x5 subtile collision block
//! the entry does, which is all the collision consumer needs.
//!
//! Recon addresses (1.14d win):
//!   GetTileLibraryEntry    0066d820   Drlg.cpp:1366
//!   SetWallTileFlags       0066db20   Drlg.cpp:1451
//!   CreateWallTileData     0066dc50   Drlg.cpp:1523
//!   FillTileData           0066dde0   Drlg.cpp:1601
//!   CreateFloorTileData    0066def0   Drlg.cpp:1663
//!   CreateShadowTileData   0066df40   Drlg.cpp:1680
//!   LookupTilesInAllProjects 00604ae0 Dungeon.cpp:149
//!   FINDTILE_Lookup        0060d040   FindTiles.cpp:191
//!
//! Match key (FINDTILE_Lookup): a tile matches when its
//!   orientation == nTileType, mainIndex == nMainIndex, subIndex == nSub
//! — identical to collision.zig's `lib.find(orientation, main, sub)`, which is
//! why the cross-check (tests below) reproduces the known-good DS1 collision.
//!
//! GATE SAFETY: pure post-generation CONSUMER. Nothing here is called from
//! InitLevel/InitAllRoomsEx; the byte-exact seed gate never touches it.

const std = @import("std");
const s = @import("structs.zig");
const rng = @import("rng.zig");
const Transform = @import("Transform.zig");
const dt1 = @import("d2-formats").dt1;

/// Diagnostic counters (single-threaded, test/tooling only): how often
/// getTileLibraryEntry falls back to a type-10 tile or fails to resolve at all.
/// A miss means a DS1 tile identity isn't in the level's loaded DT1 set, so its
/// real collision is lost. Reset before a materialize run, read after.
pub var g_lookup_fallback: usize = 0;
pub var g_lookup_null: usize = 0;

/// The engine's Act1\Outdoors\Blank.dt1 "blank fill" tiles, returned when neither the
/// primary identity nor the type-10 fallback resolve in the loaded DT1 set (that DT1 isn't
/// in our baked blob). Values verified against the real Blank.dt1 subtile blocks:
///   main=30 sub=0 -> 0x05 (block_walk|wall)  — uncarved solid rock
///   main=30 sub=1 -> 0x01 (block_walk only)  — the Arcane-Sanctuary/void fill (0x1e00100)
const solid_fill_tile: dt1.Tile = .{ .orientation = 10, .main = 0, .sub = 0, .rarity = 1, .flags = [_]u8{0x05} ** 25 };
const blank_fill_tile: dt1.Tile = .{ .orientation = 10, .main = 0, .sub = 1, .rarity = 1, .flags = [_]u8{0x01} ** 25 };

/// The solid-rock Blank.dt1 stand-in (0x05 across its 5x5), for stamping engine "void"
/// (room cells with no floor tile) into a CollMap the way the runtime does.
pub fn solidFillTile() *const dt1.Tile {
    return &solid_fill_tile;
}

/// The room's loaded tile library: the engine's `apTiles[32]` array of tile
/// projects, modelled here as the set of parsed DT1 files (in load order). A
/// `*const TileLib` is stashed in `pRoomEx.apTiles[0]`.
pub const TileLib = struct {
    dts: []const dt1.Dt1,
};

inline fn libFromRoom(pRoomEx: [*c]s.D2RoomExStrc) *const TileLib {
    const arr = pRoomEx.*.apTiles;
    return @ptrCast(@alignCast(arr[0].?));
}

/// A `dt1.Tile*` reinterpreted as the engine's `D2TileLibraryEntryStrc*`. Only
/// the stored pointer identity round-trips (address preserved via an integer
/// hop — dt1.Tile is 4-aligned, the entry field is 8-aligned on 64-bit); the
/// consumer casts it back with tileFromEntry.
inline fn asLibEntry(t: *const dt1.Tile) *s.D2TileLibraryEntryStrc {
    @setRuntimeSafety(false); // address-only round-trip; never deref'd as this type
    return @ptrFromInt(@intFromPtr(t));
}
pub inline fn tileFromEntry(p: ?*s.D2TileLibraryEntryStrc) ?*const dt1.Tile {
    @setRuntimeSafety(false);
    return @ptrFromInt(@intFromPtr(p orelse return null));
}

/// TILEPROJECT_GetAnimatedTileDataPtr (Dungeon.cpp:235) reads the entry's rarity
/// (`*(u32*)(entry+0x20)`), which is dt1.Tile.rarity.
inline fn tileRarity(t: *const dt1.Tile) i32 {
    return t.rarity;
}

/// TILEPROJECT_LookupTilesInAllProjects (Dungeon.cpp:149) -> FINDTILE_Lookup
/// (FindTiles.cpp:191), collapsed: walk every tile project in load order and
/// append entries matching (orientation==nTileType, main==nMain, sub==nSub) up
/// to nMax. Returns the number written. Enumeration order matters for the
/// rarity pick and the (10,0,0) fallback: the engine walks apTiles slots in
/// file order (TILEPROJECT_LookupTilesInAllProjects 0x604ae0), but within one
/// DT1 the FINDTILE hash chains are push-front (AllocHashEntry 0x60cf00 /
/// AddTileToChain 0x60cea0 over records 0..N-1), so same-identity tiles come
/// out in REVERSE file order — the last matching record in a file wins index 0.
fn lookupTilesInAllProjects(
    pRoomEx: [*c]s.D2RoomExStrc,
    nTileType: i32,
    nMain: i32,
    nSub: i32,
    results: []?*const dt1.Tile,
    nMax: usize,
) usize {
    const lib = libFromRoom(pRoomEx);
    var n: usize = 0;
    for (lib.dts) |*d| {
        var i: usize = d.tiles.len;
        while (i > 0) {
            i -= 1;
            const t = &d.tiles[i];
            if (n >= nMax) return n;
            if (t.orientation == nTileType and t.main == nMain and t.sub == nSub) {
                results[n] = t;
                n += 1;
            }
        }
    }
    return n;
}

/// DRLGROOMTILE_GetTileLibraryEntry (Drlg.cpp:1366, 1.14d 0066d820).
/// Resolves (nTileType, nGridFlags) to a tile-library entry, consuming the room
/// seed for the rarity-weighted pick. nGridFlags decode: main=(f>>0x14)&0x3f,
/// sub=(f>>8)&0xff (== collision.zig's floor/wall decode).
pub fn getTileLibraryEntry(pRoomEx: [*c]s.D2RoomExStrc, nTileType: i32, nGridFlags: u32) ?*const dt1.Tile {
    var aTileResults: [40]?*const dt1.Tile = undefined;

    var nMainIndex: i32 = 0;
    var nSub: i32 = 0;
    if (nGridFlags != 0) {
        nMainIndex = @intCast((nGridFlags >> 0x14) & 0x3f);
        nSub = @intCast((nGridFlags >> 8) & 0xff);
    }

    const nCount = lookupTilesInAllProjects(pRoomEx, nTileType, nMainIndex, nSub, &aTileResults, 0x28);
    if (nCount == 0) {
        // Engine (0x66d820 line 1385): retry as the special orientation-10 (main=0,
        // sub=0) tile and return the FIRST match — no rarity roll, no seed advance.
        // Every room library ends with the always-appended warp.dt1, whose last tile
        // is a zero-collision (10,0,0), so in-engine this fallback essentially never
        // fails; a double miss is ERROR_UnrecoverableInternalError (line 0x73).
        const nFallback = lookupTilesInAllProjects(pRoomEx, 10, 0, 0, &aTileResults, 0x28);
        if (nFallback != 0) {
            g_lookup_fallback += 1;
            return aTileResults[0];
        }
        g_lookup_null += 1;
        // blank.dt1 is baked so main=30 resolves normally above; keep the solid/blank
        // stand-in as a defensive last resort for asset-stripped builds.
        if (nMainIndex == 30) return if (nSub == 1) &blank_fill_tile else &solid_fill_tile;
        return null; // engine: ERROR_UnrecoverableInternalError_Halt(line 0x73)
    }

    // Rarity sum over the matches (recon 1396-1409).
    var nRaritySum: u32 = 0;
    {
        var i: usize = 0;
        while (i < nCount) : (i += 1) {
            nRaritySum +%= @bitCast(tileRarity(aTileResults[i].?));
        }
    }

    // Weighted index into [0, nRaritySum) advancing the room seed (recon 1410-1424).
    var nRandom: u32 = 0;
    if (@as(i32, @bitCast(nRaritySum)) >= 1) {
        const next = rng.sEEDNEXT(pRoomEx.*.sSeed);
        pRoomEx.*.sSeed = next;
        if (nRaritySum & (nRaritySum -% 1) == 0) {
            nRandom = (nRaritySum -% 1) & @as(u32, @bitCast(next.nSeedLow));
        } else {
            // recon: ((uint64_t)sNewSeed & -1) % nRaritySum  (full 64-bit state).
            const lo: u64 = @as(u32, @bitCast(next.nSeedLow));
            const hi: u64 = @as(u32, @bitCast(next.nSeedHigh));
            nRandom = @intCast(((hi << 32) | lo) % @as(u64, nRaritySum));
        }
    }

    // Walk the rarity ladder to the selected entry (recon 1426-1442).
    var nSelectedIndex: usize = 0;
    var nRarityEntry: i64 = @as(i64, nRandom) + 1;
    if (nRaritySum == 0) return aTileResults[0];
    while (nCount > 1 and nRarityEntry > 0) {
        nRarityEntry -= tileRarity(aTileResults[nSelectedIndex].?);
        nSelectedIndex += 1;
        if (nSelectedIndex >= nCount) break;
    }
    if (nSelectedIndex == 0) return aTileResults[0];
    nSelectedIndex -= 1;
    return aTileResults[nSelectedIndex];
}

/// The nGridFlags->nFlags draw-bit block shared verbatim by FillTileData /
/// SetWallTileFlags / CreateShadowTileData (Drlg.cpp). Collision-neutral (these
/// are tile draw flags, not subtile collision), ported for faithfulness.
fn applyGridFlagBits(pTileData: *s.D2DrlgTileDataStrc, nGridFlags: u32, comptime seedFlags: bool) void {
    if (seedFlags) {
        pTileData.nFlags |= @as(i32, @intCast((nGridFlags >> 0x12) & 3)) * 0x4000 + 0x4000;
    }
    if (@as(i8, @bitCast(@as(u8, @truncate(nGridFlags)))) < 0) pTileData.nFlags |= 1;
    if (nGridFlags & 0x10000000 != 0) pTileData.nFlags |= 0x102;
    if (nGridFlags & 0x20000 != 0) pTileData.nFlags |= 0x40;
    if (nGridFlags & 0x10000 != 0) pTileData.nFlags |= 0x80;
    if (nGridFlags & 8 != 0) pTileData.nFlags |= 4;
    if (@as(i32, @bitCast(nGridFlags)) < 0) pTileData.nFlags |= 8 else pTileData.nFlags &= -9;
    if (nGridFlags & 0x4000000 != 0) pTileData.nFlags |= 0x20c;
    if (nGridFlags & 0x20000000 != 0) pTileData.nFlags |= 0x800;
    if (nGridFlags & 4 != 0) pTileData.nFlags |= 0x2000;
    // GetTileCount(entry) draw bits (recon): entry tile-flags -> nFlags 4/0x800.
    // Not modelled (dt1.Tile carries subtile flags, not the entry tile-flags);
    // collision reads the subtile block, unaffected.
}

/// DRLGROOMTILE_FillTileData (Drlg.cpp:1601, 1.14d 0066dde0). __fastcall.
pub fn fillTileData(pRoomEx: [*c]s.D2RoomExStrc, pTileData: *s.D2DrlgTileDataStrc, nPosX: i32, nPosY: i32, nGridFlags: u32, pTileLibEntry: ?*const dt1.Tile) void {
    pTileData.pTileLibraryEntry = if (pTileLibEntry) |t| asLibEntry(t) else null;
    pTileData.nTileType = 0;
    pTileData.nFlags = 0;
    pTileData.nTransitionFlags = 0;
    pTileData.nGreen = 0xff;
    pTileData.nBlue = 0xff;
    pTileData.nRed = 0xff;
    if (pRoomEx != null) {
        pTileData.nPosX = nPosX - pRoomEx.*.sCoords.WorldPosition.x;
        pTileData.nPosY = nPosY - pRoomEx.*.sCoords.WorldPosition.y;
        var sx = nPosX;
        var sy = nPosY + 1;
        Transform.CoordsMiniMapToScreen(&sx, &sy);
        pTileData.nScreenX = sx;
        pTileData.nScreenY = sy + 0x28;
    }
    applyGridFlagBits(pTileData, nGridFlags, true);
}

/// DRLGROOMTILE_SetWallTileFlags (Drlg.cpp:1451, 1.14d 0066db20).
fn setWallTileFlags(pTileData: *s.D2DrlgTileDataStrc, nTileType: i32, nGridFlags: u32) void {
    if (nTileType != 0xd) {
        pTileData.nFlags |= @as(i32, @intCast((nGridFlags >> 0x12) & 3)) * 0x4000 + 0x4000;
    }
    if (nTileType == 0xe) {
        pTileData.nFlags |= 4;
    } else if (nTileType == 0xb or nTileType == 10 or nTileType == 9 or nTileType == 8) {
        pTileData.nFlags |= 2;
    }
    if (@as(i8, @bitCast(@as(u8, @truncate(nGridFlags)))) < 0) pTileData.nFlags |= 1;
    if (nGridFlags & 0x10000000 != 0) pTileData.nFlags |= 0x102;
    if (nGridFlags & 0x20000 != 0) pTileData.nFlags |= 0x40;
    if (nGridFlags & 0x10000 != 0) pTileData.nFlags |= 0x80;
    if (nGridFlags & 8 != 0) pTileData.nFlags |= 4;
    if (@as(i32, @bitCast(nGridFlags)) < 0) pTileData.nFlags |= 8 else pTileData.nFlags &= -9;
    if (nGridFlags & 0x4000000 != 0) pTileData.nFlags |= 0x20c;
    if (nGridFlags & 0x20000000 != 0) pTileData.nFlags |= 0x800;
    if (nGridFlags & 4 != 0) pTileData.nFlags |= 0x2000;
    // GetTileCount(entry) draw bits omitted (see applyGridFlagBits note).
}

/// DRLGROOMTILE_CreateWallTileData (Drlg.cpp:1523, 1.14d 0066dc50). __fastcall.
pub fn createWallTileData(pRoomEx: [*c]s.D2RoomExStrc, ppTileHead: ?*?*s.D2DrlgTileDataStrc, nPosX: i32, nPosY: i32, nGridFlags: u32, pTileLibEntry: ?*const dt1.Tile, nTileType: i32) *s.D2DrlgTileDataStrc {
    const pTileGrid: *s.D2DrlgTileGridStrc = @ptrCast(pRoomEx.*.pRoomTiles.?);
    const pWall: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(pTileGrid.pWallTiles.?));
    const pTileData: *s.D2DrlgTileDataStrc = &pWall[@intCast(pTileGrid.nWalls)];
    if (ppTileHead) |head| {
        pTileData.pNext = head.*;
        head.* = pTileData;
    } else {
        pTileData.pNext = null;
    }
    pTileGrid.nWalls += 1;

    pTileData.nPosX = nPosX - pRoomEx.*.sCoords.WorldPosition.x;
    pTileData.nPosY = nPosY - pRoomEx.*.sCoords.WorldPosition.y;
    var sx = nPosX;
    var sy = nPosY + 1;
    Transform.CoordsMiniMapToScreen(&sx, &sy);
    pTileData.nScreenY = sy + 0x28;
    pTileData.nScreenX = sx;
    pTileData.pTileLibraryEntry = if (pTileLibEntry) |t| asLibEntry(t) else null;
    pTileData.nFlags = 0;
    pTileData.nTransitionFlags = 0;
    pTileData.nGreen = 0xff;
    pTileData.nBlue = 0xff;
    pTileData.nRed = 0xff;
    pTileData.nTileType = nTileType;
    setWallTileFlags(pTileData, nTileType, nGridFlags);
    if (nTileType != 3) return pTileData;

    // type-3 wall spawns its type-4 shadow companion (recon 1554-1595).
    const nShadowEntry = getTileLibraryEntry(pRoomEx, 4, nGridFlags);
    const pShadow = createWallTileData(pRoomEx, ppTileHead, nPosX, nPosY, nGridFlags, nShadowEntry, 4);
    _ = pShadow;
    return pTileData;
}

/// DRLGROOMTILE_CreateFloorTileData (Drlg.cpp:1663, 1.14d 0066def0). __fastcall.
pub fn createFloorTileData(pRoomEx: [*c]s.D2RoomExStrc, ppTileHead: ?*?*s.D2DrlgTileDataStrc, nPosX: i32, nPosY: i32, nGridFlags: u32, pTileLibEntry: ?*const dt1.Tile) *s.D2DrlgTileDataStrc {
    const pTileGrid: *s.D2DrlgTileGridStrc = @ptrCast(pRoomEx.*.pRoomTiles.?);
    const pFloor: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(pTileGrid.pFloorTiles.?));
    const pTileData: *s.D2DrlgTileDataStrc = &pFloor[@intCast(pTileGrid.nFloors)];
    if (ppTileHead) |head| {
        pTileData.pNext = head.*;
        head.* = pTileData;
    } else {
        pTileData.pNext = null;
    }
    pTileGrid.nFloors += 1;
    fillTileData(pRoomEx, pTileData, nPosX, nPosY, nGridFlags, pTileLibEntry);
    return pTileData;
}

/// DRLGROOMTILE_CreateShadowTileData (Drlg.cpp:1680, 1.14d 0066df40). __fastcall.
pub fn createShadowTileData(pRoomEx: [*c]s.D2RoomExStrc, ppTileHead: ?*?*s.D2DrlgTileDataStrc, nPosX: i32, nPosY: i32, nGridFlags: u32, pTileLibEntry: ?*const dt1.Tile) *s.D2DrlgTileDataStrc {
    const pTileGrid: *s.D2DrlgTileGridStrc = @ptrCast(pRoomEx.*.pRoomTiles.?);
    const pRoof: [*]s.D2DrlgTileDataStrc = @ptrCast(@alignCast(pTileGrid.pRoofTiles.?));
    const pTileData: *s.D2DrlgTileDataStrc = &pRoof[@intCast(pTileGrid.nShadows)];
    if (ppTileHead) |head| {
        pTileData.pNext = head.*;
        head.* = pTileData;
    } else {
        pTileData.pNext = null;
    }
    pTileGrid.nShadows += 1;

    pTileData.nPosX = nPosX - pRoomEx.*.sCoords.WorldPosition.x;
    pTileData.nPosY = nPosY - pRoomEx.*.sCoords.WorldPosition.y;
    var sx = nPosX;
    var sy = nPosY + 1;
    Transform.CoordsMiniMapToScreen(&sx, &sy);
    pTileData.nScreenY = sy + 0x28;
    pTileData.nGreen = 0xff;
    pTileData.nBlue = 0xff;
    pTileData.nRed = 0xff;
    pTileData.nScreenX = sx;
    pTileData.pTileLibraryEntry = if (pTileLibEntry) |t| asLibEntry(t) else null;
    pTileData.nTileType = 0xd;
    pTileData.nFlags = 0;
    pTileData.nTransitionFlags = 0;
    if (@as(i8, @bitCast(@as(u8, @truncate(nGridFlags)))) < 0) pTileData.nFlags = 1;
    if (nGridFlags & 0x10000000 != 0) pTileData.nFlags |= 0x102;
    if (nGridFlags & 0x20000 != 0) pTileData.nFlags |= 0x40;
    if (nGridFlags & 0x10000 != 0) pTileData.nFlags |= 0x80;
    if (nGridFlags & 8 != 0) pTileData.nFlags |= 4;
    if (@as(i32, @bitCast(nGridFlags)) < 0) pTileData.nFlags |= 8 else pTileData.nFlags &= -9;
    if (nGridFlags & 0x4000000 != 0) pTileData.nFlags |= 0x20c;
    if (nGridFlags & 0x20000000 != 0) pTileData.nFlags |= 0x800;
    if (nGridFlags & 4 != 0) pTileData.nFlags |= 0x2000;
    return pTileData;
}

// ===========================================================================
// CROSS-CHECK (M1 acceptance #3): materialize a real DS1's tiles through the
// new pipeline (getTileLibraryEntry + create{Floor,Wall}TileData) and prove the
// resulting subtile collision matches collision.zig's known-good DS1 path.
// ---------------------------------------------------------------------------

const testing = std.testing;
const ds1 = @import("d2-formats").ds1;
const collision = @import("../collision.zig");

const SUBTILES = collision.SUBTILES_PER_TILE;

fn blitEntry(cells: []u8, w: usize, h: usize, t: *const dt1.Tile, tx: i32, ty: i32) void {
    if (tx < 0 or ty < 0) return;
    const utx: usize = @intCast(tx);
    const uty: usize = @intCast(ty);
    var sy: usize = 0;
    while (sy < SUBTILES) : (sy += 1) {
        const gy = uty * SUBTILES + sy;
        if (gy >= h) break;
        var sx: usize = 0;
        while (sx < SUBTILES) : (sx += 1) {
            const gx = utx * SUBTILES + sx;
            if (gx >= w) continue;
            // Engine reads the DT1 subtile block Y-flipped (TileLibrary_AddCollision
            // 0x64c4c0): grid cell (dx,dy) <- byte[(4-dy)*5+dx]. Match it here.
            cells[gy * w + gx] |= t.subtile(sx, SUBTILES - 1 - sy);
        }
    }
}

test "tile pipeline reproduces collision.zig DS1 collision (preset town room)" {
    const a = testing.allocator;

    // Same Act 1 base DT1 set + town DS1 as collision.zig's test.
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

    // Baseline: collision.zig over the DS1 + a DtLibrary.
    var lib = collision.DtLibrary.init(a);
    defer lib.deinit();
    for (&dts) |*d| try lib.add(d);

    const ds_bytes = @embedFile("../maps/Act1_Town_TownN1.ds1");
    var d = try ds1.parse(a, ds_bytes);
    defer d.deinit();

    var baseline = try collision.rasterize(a, &d, &lib);
    defer baseline.deinit();

    // Pipeline: build a bare pRoomEx whose apTiles points at our TileLib, with
    // floor/wall tile arrays sized to the cell count, then run every DS1 cell
    // through getTileLibraryEntry + create*TileData (WorldPosition = 0 so the
    // stored nPosX/nPosY equal the cell coords).
    const w: usize = @intCast(d.width);
    const h: usize = @intCast(d.height);
    const ncells = w * h;

    var tlib = TileLib{ .dts = &dts };

    const floor_arr = try a.alloc(s.D2DrlgTileDataStrc, ncells);
    defer a.free(floor_arr);
    // walls: floor+wall count, plus headroom for type-3 shadow companions.
    const wall_arr = try a.alloc(s.D2DrlgTileDataStrc, ncells * 4 + 16);
    defer a.free(wall_arr);
    @memset(std.mem.sliceAsBytes(floor_arr), 0);
    @memset(std.mem.sliceAsBytes(wall_arr), 0);

    var grid = std.mem.zeroes(s.D2DrlgTileGridStrc);
    grid.pFloorTiles = @ptrCast(floor_arr.ptr);
    grid.nFloorTilesMax = @intCast(floor_arr.len);
    grid.pWallTiles = @ptrCast(wall_arr.ptr);
    grid.nWallTilesMax = @intCast(wall_arr.len);

    var room = std.mem.zeroes(s.D2RoomExStrc);
    room.pRoomTiles = &grid;
    room.apTiles[0] = @ptrCast(&tlib);
    room.sSeed = .{ .nSeedLow = 0x1234_5678, .nSeedHigh = 0x29a };
    room.sCoords = .{ .WorldPosition = .{ .x = 0, .y = 0 }, .WorldSize = .{ .x = @intCast(w), .y = @intCast(h) } };
    const pRoom: [*c]s.D2RoomExStrc = &room;

    // Floor layers first, then wall layers (collision.zig order).
    for (d.floor_layers) |fl| {
        for (fl, 0..) |c, i| {
            if (c.raw & 0x00ff_ffff == 0) continue;
            const entry = getTileLibraryEntry(pRoom, 0, c.raw) orelse continue;
            _ = createFloorTileData(pRoom, null, @intCast(i % w), @intCast(i / w), c.raw, entry);
        }
    }
    // Track the synthetic type-3 -> type-4 shadow companions createWallTileData
    // spawns: they are visual roof/shadow tiles, NOT part of collision.zig's
    // one-tile-per-DS1-cell known-good model, so they are excluded from the
    // collision rasterization below (they carry block flags in the DT1 art but
    // the engine does not feed shadow companions into the walk/LOS grid).
    const is_companion = try a.alloc(bool, wall_arr.len);
    defer a.free(is_companion);
    @memset(is_companion, false);
    for (d.wall_layers) |wl| {
        const n = @min(wl.wall.len, wl.orient.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const wc = wl.wall[i];
            if (wc.raw & 0x00ff_ffff == 0) continue;
            const orient: i32 = wl.orient[i].prop1;
            const entry = getTileLibraryEntry(pRoom, orient, wc.raw) orelse continue;
            const before: usize = @intCast(grid.nWalls);
            _ = createWallTileData(pRoom, null, @intCast(i % w), @intCast(i / w), wc.raw, entry, orient);
            // parent is at `before`; anything appended after it is a companion.
            var c: usize = before + 1;
            while (c < @as(usize, @intCast(grid.nWalls))) : (c += 1) is_companion[c] = true;
        }
    }

    // Rasterize collision straight off the materialized tile-data arrays.
    const cells = try a.alloc(u8, ncells * SUBTILES * SUBTILES);
    defer a.free(cells);
    @memset(cells, 0);
    const gw = w * SUBTILES;
    const gh = h * SUBTILES;

    var fi: usize = 0;
    while (fi < @as(usize, @intCast(grid.nFloors))) : (fi += 1) {
        const td = floor_arr[fi];
        const t = tileFromEntry(td.pTileLibraryEntry) orelse continue;
        blitEntry(cells, gw, gh, t, td.nPosX, td.nPosY);
    }
    var companions: usize = 0;
    var wi: usize = 0;
    while (wi < @as(usize, @intCast(grid.nWalls))) : (wi += 1) {
        if (is_companion[wi]) {
            companions += 1;
            continue;
        }
        const td = wall_arr[wi];
        const t = tileFromEntry(td.pTileLibraryEntry) orelse continue;
        blitEntry(cells, gw, gh, t, td.nPosX, td.nPosY);
    }

    // Compare subtile-for-subtile against the baseline.
    try testing.expectEqual(baseline.width, gw);
    try testing.expectEqual(baseline.height, gh);
    var match: usize = 0;
    var mismatch: usize = 0;
    for (baseline.cells, cells) |b, m| {
        if (b == m) match += 1 else mismatch += 1;
    }
    std.debug.print(
        "\n[tilegen cross-check] town DS1 {d}x{d} tiles -> {d} floor + {d} wall " ++
            "({d} shadow companions excluded); subtile collision match {d}/{d} ({d} mismatch)\n",
        .{ w, h, grid.nFloors, grid.nWalls, companions, match, baseline.cells.len, mismatch },
    );
    try testing.expectEqual(@as(usize, 0), mismatch);
}
