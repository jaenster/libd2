//! Room-tile teardown from recon/closure/RoomTile.cpp (D2Common::Drlg::RoomTile).
//! The tile-build / warp-cache / link layer this file used to carry is the
//! engine's render/runtime materialization step — not reached by DRLG generation
//! — and was excised. Only the RoomEx tile-array free path remains.
//! The decompiler overlaid `D2DrlgRoomTilesListStrc` (0x18) on the real
//! `D2DrlgTileGridStrc` (0x2c); resolved to the real fields here.

const s = @import("structs.zig");
const pool = @import("pool.zig");

/// RoomTile.cpp:1000 (1.14d 0066f050).
pub fn freeTileArrays(pLevelCtx: [*c]s.D2RoomExStrc, pPoolManagerStrc: ?*s.D2PoolManagerStrc) void {
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(pLevelCtx.*.pRoomTiles);
    // line 1002: `&pTileGrid->pWallTiles` is a field address (always non-null),
    // so the guard reduces to pTileGrid != null.
    if (pTileGrid == null) {
        return;
    }
    const pWallTiles = pTileGrid.*.pWallTiles; // recon names this pFloorTiles
    if (pWallTiles != null) {
        pool.FreeServerMemory(pPoolManagerStrc, pWallTiles, ".\\DRLG\\RoomTile.cpp", 0x592, 0);
    }
    if (pTileGrid.*.pFloorTiles != null) {
        pool.FreeServerMemory(pPoolManagerStrc, pTileGrid.*.pFloorTiles, ".\\DRLG\\RoomTile.cpp", 0x593, 0);
    }
    if (pTileGrid.*.pRoofTiles == null) {
        return;
    }
    pool.FreeServerMemory(pPoolManagerStrc, pTileGrid.*.pRoofTiles, ".\\DRLG\\RoomTile.cpp", 0x594, 0);
}

/// RoomTile.cpp:1022 (1.14d 0066f0b0). __fastcall.
pub fn freeRoomTilesAll(pRoomEx: [*c]s.D2RoomExStrc) void {
    const pMemory = pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool;
    freeTileArrays(pRoomEx, pMemory);
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(pRoomEx.*.pRoomTiles);
    if (pTileGrid == null) {
        return;
    }
    var pTileLink: ?*s.D2DrlgTileLinkStrc = pTileGrid.*.pMapLinks;
    while (pTileLink != null) {
        const pNextTileLink = pTileLink.?.pNext; // line 1033: ->nNext == pNext
        pool.FreeServerMemory(pMemory, pTileLink, ".\\DRLG\\RoomTile.cpp", 0x5ad, 0);
        pTileLink = pNextTileLink;
    }
    pTileGrid.*.pMapLinks = null;
    var pAnim: ?*s.D2DrlgAnimTileGridStrc = pTileGrid.*.pAnimTiles;
    while (pAnim != null) {
        const pNextAnim = pAnim.?.pNext;
        pool.FreeServerMemory(pMemory, @ptrCast(pAnim.?.ppTileData), ".\\DRLG\\RoomTile.cpp", 0x5b9, 0);
        pool.FreeServerMemory(pMemory, pAnim, ".\\DRLG\\RoomTile.cpp", 0x5ba, 0);
        pAnim = pNextAnim;
    }
    pool.FreeServerMemory(pMemory, pTileGrid, ".\\DRLG\\RoomTile.cpp", 0x5bd, 0);
    pRoomEx.*.pRoomTiles = null;
}
