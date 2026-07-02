//! Faithful Zig transform of recon/closure/DrlgLogic.cpp
//! (D2Common::Drlg::DrlgLogic — DRLG coord-list / region builder).
//!
//! Conventions: structs by name from structs.zig, C pointers `[*c]T`, allocs ->
//! pool.zig, errors -> forward.zig, cross-module calls -> sibling .zig modules.
//! Flat fn names == the recon's. 32-bit struct-size alloc literals replaced with
//! @sizeOf for the 64-bit standalone.
//!
//! RESOLUTIONS (cited inline):
//!  * Tile-array walks `*(T*)((uintptr_t)&pTile->field + nIdx*0x30)` are the
//!    decompiler's byte form of `pTiles[nIdx].field` — resolved to true array
//!    indexing (Zig computes the 64-bit stride; the 0x30 32-bit stride is gone).
//!  * Grid CELLS (D2DrlgGridStrc.pCellsFlags, i32) store engine pointers
//!    (D2RoomCoordListStrc*) truncated to 32 bits, and D2RoomCoordListStrc.nIndex
//!    likewise holds a 32-bit-truncated orientation/grid value. This is the
//!    engine's own pointer-as-i32 packing (same as DrlgGrid.GetOffset). Helpers
//!    ptrAsCell / cellAsCoord / cellAsGrid round-trip it; storage is 32-bit-lossy
//!    on 64-bit (the one runtime caveat — readback of a truncated heap pointer in
//!    DRLG_ROOMEX_GetGridIndex et al. is only correct under a 32-bit address space).
//!  * `nGridFlags + X - nGridFlags` (FillTileGridFlags) cancels to X — resolved.
//!  * `!*(int*)pMapLink` reads the first dword (bFloor@0x00) — resolved to bFloor.
//!  * `(D2DrlgGridStrc*)a->bNode != (D2DrlgGridStrc*)b->bNode` is an i32 compare.
//!  * DRLGLOGIC_PopulateGridCoordIndices takes the address of a stack-frame
//!    context (`(int*)&pRoomExCtx`); the populate target lives in DrlgGrid.zig as
//!    a panic-stub, so the context is reconstructed best-effort (see note there).

const std = @import("std");
const s = @import("structs.zig");
const pool = @import("pool.zig");
const forward = @import("forward.zig");
const DrlgGrid = @import("DrlgGrid.zig");
const DrlgRoom = @import("DrlgRoom.zig");

const D2DrlgCoordListStrc = s.D2DrlgCoordListStrc;
const D2RoomCoordListStrc = s.D2RoomCoordListStrc;
const D2RoomExStrc = s.D2RoomExStrc;
const D2DrlgGridStrc = s.D2DrlgGridStrc;
const D2DrlgLevelStrc = s.D2DrlgLevelStrc;
const D2DrlgTileGridStrc = s.D2DrlgTileGridStrc;
const D2DrlgTileDataStrc = s.D2DrlgTileDataStrc;
const D2DrlgTileLinkStrc = s.D2DrlgTileLinkStrc;
const D2PoolManagerStrc = s.D2PoolManagerStrc;

// Pointer<->i32-cell packing (the engine stores pointers in i32 grid cells /
// nIndex fields, truncated to 32 bits). 32-bit-lossy on a 64-bit heap.

inline fn ptrAsCell(p: anytype) i32 {
    return @bitCast(@as(u32, @truncate(@intFromPtr(p))));
}
inline fn cellAsCoord(v: i32) [*c]D2RoomCoordListStrc {
    return @ptrFromInt(@as(usize, @as(u32, @bitCast(v))));
}
inline fn cellAsGrid(v: i32) [*c]D2DrlgGridStrc {
    return @ptrFromInt(@as(usize, @as(u32, @bitCast(v))));
}

/// DrlgLogic.cpp:40 (1.14d 0066c660)
pub fn AllocEmptyDrlgCoordList_Unused(pMemory: ?*D2PoolManagerStrc, pRoomEx: [*c]D2RoomExStrc) [*c]D2DrlgCoordListStrc {
    const pDst: [*c]D2DrlgCoordListStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(D2DrlgCoordListStrc), ".\\DRLG\\DrlgLogic.cpp", 0xdf)));
    @memset(@as([*]u8, @ptrCast(pDst))[0..@sizeOf(D2DrlgCoordListStrc)], 0);
    pRoomEx.*.pDrlgCoordList = pDst;
    return pDst;
}

/// DrlgLogic.cpp:49 (1.14d 0066c6a0)
pub fn AllocEmptyRoomCoordList_Unused(pMemory: ?*D2PoolManagerStrc, pDrlgCoordList: [*c]D2DrlgCoordListStrc, nSize: i32) void {
    pDrlgCoordList.*.nListSize = nSize;
    const pDst: [*c]D2RoomCoordListStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @as(usize, @intCast(nSize)) * @sizeOf(D2RoomCoordListStrc), ".\\DRLG\\DrlgLogic.cpp", 0xe9)));
    pDrlgCoordList.*.pCoord = pDst;
    @memset(@as([*]u8, @ptrCast(pDst))[0 .. @as(usize, @intCast(pDrlgCoordList.*.nListSize)) * @sizeOf(D2RoomCoordListStrc)], 0);
}

/// DrlgLogic.cpp:58 (1.14d win 0066c6e0 | mac 002f331c)
pub fn FreeDrlgCoordList(pRoomEx: [*c]D2RoomExStrc) void {
    const pDrlgCoordList = pRoomEx.*.pDrlgCoordList;
    const pMemory = pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool;
    if (pDrlgCoordList == null) {
        return;
    }
    if ((pDrlgCoordList.?.eFlags & 2) != 0) {
        DrlgGrid.freeGrid(pMemory, &pDrlgCoordList.?.sOrientationGrid);
        DrlgGrid.freeGrid(pMemory, &pDrlgCoordList.?.sCoordIndexGrid);
    }

    var pRoomCoordList: [*c]D2RoomCoordListStrc = pDrlgCoordList.?.pCoord;
    while (pRoomCoordList != null) {
        const pNextCoord = pRoomCoordList.*.pNext;
        pool.FreeServerMemory(pMemory, pRoomCoordList, ".\\DRLG\\DrlgLogic.cpp", 0x101, 0);
        pRoomCoordList = pNextCoord;
    }

    pool.FreeServerMemory(pMemory, pDrlgCoordList, ".\\DRLG\\DrlgLogic.cpp", 0x106, 0);
    pRoomEx.*.pDrlgCoordList = null;
}

/// DrlgLogic.cpp:83 (1.14d win 0066c770 | mac 0014f413)
pub fn InitializeDrlgCoordList(pRoomEx: [*c]D2RoomExStrc, pOrientationGrid: [*c]D2DrlgGridStrc, pFloorGrid: [*c]D2DrlgGridStrc, pWallGrid: [*c]D2DrlgGridStrc) void {
    const pDrlgCoordList = pRoomEx.*.pDrlgCoordList;
    if (!(pDrlgCoordList != null and (pDrlgCoordList.?.eFlags & 1) == 0)) {
        return;
    }

    var pRoomCoordList: [*c]D2RoomCoordListStrc = pDrlgCoordList.?.pCoord;
    var bFoundMatch = false;
    if (pRoomCoordList == null) {
        return;
    }

    while (true) {
        // line 96: nIndex holds a 32-bit-truncated grid pointer
        if (pRoomCoordList.*.nIndex == ptrAsCell(pOrientationGrid)) {
            bFoundMatch = true;
            pRoomCoordList.*.nIndex = ptrAsCell(pFloorGrid);
        }
        pRoomCoordList = pRoomCoordList.*.pNext;
        if (!(pRoomCoordList != null)) break;
    }

    if (!bFoundMatch) {
        return;
    }

    var iNearIdx: i32 = 0;
    if (0 >= pRoomEx.*.nDrlgRoomsExNearCount) {
        return;
    }

    while (true) {
        const pNearRoomEx: [*c]D2RoomExStrc = pRoomEx.*.ppDrlgRoomsExNear[@intCast(iNearIdx)];
        if (pNearRoomEx != pRoomEx and pNearRoomEx.*.pLevel.?.eD2LevelId == pRoomEx.*.pLevel.?.eD2LevelId) {
            InitializeDrlgCoordList(pNearRoomEx, pOrientationGrid, pFloorGrid, pWallGrid);
        }
        iNearIdx += 1;
        if (!(iNearIdx < pRoomEx.*.nDrlgRoomsExNearCount)) break;
    }
}

/// DrlgLogic.cpp:127 (1.14d 0066c7f0)
pub fn setGridDoorFlags(pGrid: [*c]D2DrlgGridStrc, pRoomEx: [*c]D2RoomExStrc) void {
    const pRoomTiles: [*c]D2DrlgTileGridStrc = pRoomEx.*.pRoomTiles;
    var nTileIndex: u32 = 0;
    if (pRoomTiles.*.nWallTilesMax == 0) {
        return;
    }

    const pWallTiles: [*c]D2DrlgTileDataStrc = @ptrCast(@alignCast(pRoomTiles.*.pWallTiles));
    while (true) {
        const i: usize = @intCast(nTileIndex);
        // lines 139-141: pWallTiles[i].{nFlags,nPosX,nPosY} (was byte-offset form)
        const nTileFlags: u32 = @bitCast(pWallTiles[i].nFlags);
        if ((nTileFlags & 4) != 0 and (nTileFlags & 0x1c000) == 0) {
            DrlgGrid.AlterGridFlag(pGrid, pWallTiles[i].nPosX, pWallTiles[i].nPosY, 8, 0);
        }
        nTileIndex += 1;
        if (!(nTileIndex < @as(u32, @bitCast(pRoomTiles.*.nWallTilesMax)))) break;
    }
}

/// DrlgLogic.cpp:151 (1.14d 0066c870)
pub fn setGridWallFlags(pRoomEx: [*c]D2RoomExStrc, pGrid: [*c]D2DrlgGridStrc) void {
    const pRoomTiles: [*c]D2DrlgTileGridStrc = pRoomEx.*.pRoomTiles;
    var nTileIndex: u32 = 0;
    if (pRoomTiles.*.nWallTilesMax != 0) {
        const pWallTiles: [*c]D2DrlgTileDataStrc = @ptrCast(@alignCast(pRoomTiles.*.pWallTiles));
        while (true) {
            const i: usize = @intCast(nTileIndex);
            // lines 164-166: pWallTiles[i].{nFlags,nTileType,nPosX,nPosY}
            const nWallFlags: u32 = @bitCast(pWallTiles[i].nFlags);
            if ((nWallFlags & 0x1c000) == 0x4000 and pWallTiles[i].nTileType != 0xf and (~(nWallFlags >> 0xb) & 1) != 0) {
                DrlgGrid.AlterGridFlag(pGrid, pWallTiles[i].nPosX, pWallTiles[i].nPosY, 1, 0);
            }
            nTileIndex += 1;
            if (!(nTileIndex < @as(u32, @bitCast(pRoomTiles.*.nWallTilesMax)))) break;
        }
    }

    var nNearIndex: u32 = 0;
    if (pRoomEx.*.nDrlgRoomsExNearCount == 0) {
        return;
    }

    while (true) {
        const pNearRoomEx: [*c]D2RoomExStrc = pRoomEx.*.ppDrlgRoomsExNear[@intCast(nNearIndex)];
        if (pNearRoomEx != pRoomEx and pNearRoomEx.*.pRoomTiles != null) {
            var pMapLink: [*c]D2DrlgTileLinkStrc = pNearRoomEx.*.pRoomTiles.?.pMapLinks;
            while (pMapLink != null) : (pMapLink = pMapLink.*.pNext) {
                // line 184: !*(int*)pMapLink == bFloor field (0 == wall link)
                if (!pMapLink.*.bFloor) {
                    var pTileEntry: [*c]D2DrlgTileDataStrc = pMapLink.*.pTileData;
                    while (pTileEntry != null) : (pTileEntry = pTileEntry.*.pNext) {
                        const nFlags: u32 = @bitCast(pTileEntry.*.nFlags);
                        if ((nFlags & 0x1c000) == 0x4000 and pTileEntry.*.nTileType != 0xf and (~(nFlags >> 0xb) & 1) != 0) {
                            const nWorldX = pNearRoomEx.*.sCoords.WorldPosition.x + pTileEntry.*.nPosX;
                            const nWorldY = pNearRoomEx.*.sCoords.WorldPosition.y + pTileEntry.*.nPosY;
                            const bIsInsideRoom = DrlgRoom.isPointInside(&pRoomEx.*.sCoords, nWorldX, nWorldY);
                            if (bIsInsideRoom != 0) {
                                DrlgGrid.AlterGridFlag(pGrid, nWorldX - pRoomEx.*.sCoords.WorldPosition.x, nWorldY - pRoomEx.*.sCoords.WorldPosition.y, 1, 0);
                            }
                        }
                    }
                }
            }
        }
        nNearIndex += 1;
        if (!(nNearIndex < @as(u32, @bitCast(pRoomEx.*.nDrlgRoomsExNearCount)))) break;
    }
}

/// DrlgLogic.cpp:205 (1.14d 0066c9c0)
pub fn fillTileGridFlags(pRoomEx: [*c]D2RoomExStrc) void {
    const pRoomTiles: [*c]D2DrlgTileGridStrc = pRoomEx.*.pRoomTiles;
    var nTileIndex: u32 = 0;
    if (pRoomTiles.*.nWallTilesMax == 0) {
        return;
    }

    const pWallTiles: [*c]D2DrlgTileDataStrc = @ptrCast(@alignCast(pRoomTiles.*.pWallTiles));
    while (true) {
        const i: usize = @intCast(nTileIndex);
        const pCoordList = pRoomEx.*.pDrlgCoordList;
        if (pCoordList == null) {
            pWallTiles[i].nGridFlags = 0;
        } else if ((pCoordList.?.eFlags & 1) == 0) {
            // line 223: `nPosX + nGridFlags - nGridFlags` cancels to nPosX
            const nGridFlags = DrlgGrid.GetGridFlags(&pCoordList.?.sCoordIndexGrid, pWallTiles[i].nPosX, pWallTiles[i].nPosY);
            pWallTiles[i].nGridFlags = nGridFlags;
        } else {
            pWallTiles[i].nGridFlags = 0;
        }
        nTileIndex += 1;
        if (!(nTileIndex < @as(u32, @bitCast(pRoomTiles.*.nWallTilesMax)))) break;
    }
}

/// DrlgLogic.cpp:236 (1.14d win 0066ca50 | mac 0014e858)
pub fn buildCoordRegions(pRoomEx: [*c]D2RoomExStrc, pCoordList: [*c]D2DrlgCoordListStrc) void {
    const pMemory = pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool;
    DrlgGrid.initGridCells(pMemory, &pCoordList.*.sCoordIndexGrid, pRoomEx.*.sCoords.WorldSize.x + 1, pRoomEx.*.sCoords.WorldSize.y + 1);
    const nGridHeight = pRoomEx.*.sCoords.WorldSize.y + 1;
    const nGridWidth = pRoomEx.*.sCoords.WorldSize.x + 1;
    var nCellY: i32 = 0;
    if (0 >= nGridHeight) {
        return;
    }

    while (true) {
        var iCellX: i32 = 0;
        if (0 < nGridWidth) {
            while (true) {
                var nOrientFlags: u32 = @bitCast(DrlgGrid.GetGridFlags(&pCoordList.*.sOrientationGrid, iCellX, nCellY));
                const nOrientFlagsLow: u32 = nOrientFlags & 0xfffffff;
                var nRowY: i32 = DrlgGrid.GetGridFlags(&pCoordList.*.sCoordIndexGrid, iCellX, nCellY);
                if (nRowY == 0) {
                    const pDst: [*c]D2RoomCoordListStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(D2RoomCoordListStrc), ".\\DRLG\\DrlgLogic.cpp", 0x201)));
                    @memset(@as([*]u8, @ptrCast(pDst))[0..@sizeOf(D2RoomCoordListStrc)], 0);
                    pDst.*.nIndex = @bitCast(nOrientFlagsLow);
                    pDst.*.bNode = @intFromBool((nOrientFlags & 0x20000000) == 0x20000000);
                    pDst.*.pNext = pCoordList.*.pCoord;
                    pCoordList.*.pCoord = pDst;
                    pDst.*.pBox.nPosX = iCellX;
                    pDst.*.pBox.nPosY = nCellY;

                    // line 272-288: nX is an i32 cell-x scanner (was D2RoomExStrc* int)
                    var nX: i32 = iCellX;
                    while (true) {
                        if (nX >= nGridWidth) break;
                        nOrientFlags = @bitCast(DrlgGrid.GetGridFlags(&pCoordList.*.sOrientationGrid, nX, nCellY));
                        if (nOrientFlagsLow != (nOrientFlags & 0xfffffff)) break;
                        nRowY = DrlgGrid.GetGridFlags(&pCoordList.*.sCoordIndexGrid, nX, nCellY);
                        if (nRowY != 0) break;
                        nX += 1;
                    }
                    pDst.*.pBox.nWidth = nX;

                    var bRowBreak = false;
                    nRowY = nCellY;
                    while (true) {
                        if (nGridHeight <= nRowY) break;
                        var iScanX: i32 = iCellX;
                        if (iCellX < pDst.*.pBox.nWidth) {
                            while (true) {
                                nOrientFlags = @bitCast(DrlgGrid.GetGridFlags(&pCoordList.*.sOrientationGrid, iScanX, nRowY));
                                var bBreakRow2 = false;
                                if (nOrientFlagsLow != (nOrientFlags & 0xfffffff)) {
                                    bBreakRow2 = true;
                                } else {
                                    const nColXTmp = DrlgGrid.GetGridFlags(&pCoordList.*.sCoordIndexGrid, iScanX, nRowY);
                                    if (nColXTmp != 0) bBreakRow2 = true;
                                }
                                if (bBreakRow2) {
                                    bRowBreak = true;
                                    nRowY -= 1;
                                    break;
                                }
                                iScanX += 1;
                                if (!(iScanX < pDst.*.pBox.nWidth)) break;
                            }
                        }
                        nRowY += 1;
                        if (bRowBreak) break;
                    }
                    pDst.*.pBox.nHeight = nRowY;

                    nRowY = pDst.*.pBox.nPosY;
                    while (nRowY < pDst.*.pBox.nHeight) {
                        var nColX: i32 = pDst.*.pBox.nPosX;
                        while (nColX < pDst.*.pBox.nWidth) {
                            // line 321: store the coord-entry pointer into the cell (i32)
                            DrlgGrid.AlterGridFlag(&pCoordList.*.sCoordIndexGrid, nColX, nRowY, ptrAsCell(pDst), 3);
                            nColX += 1;
                        }
                        nRowY += 1;
                    }

                    // lines 328-334: add world position to box fields
                    pDst.*.pBox.nPosY += pRoomEx.*.sCoords.WorldPosition.y;
                    pDst.*.pBox.nHeight += pRoomEx.*.sCoords.WorldPosition.y;
                    pDst.*.pBox.nPosX += pRoomEx.*.sCoords.WorldPosition.x;
                    pDst.*.pBox.nWidth += pRoomEx.*.sCoords.WorldPosition.x;

                    pDst.*.pRect.left = pDst.*.pBox.nPosX;
                    pDst.*.pRect.top = pDst.*.pBox.nPosY;
                    pDst.*.pRect.right = pDst.*.pBox.nWidth;
                    pDst.*.pRect.bottom = pDst.*.pBox.nHeight;

                    var nClamp = pRoomEx.*.sCoords.WorldPosition.x + pRoomEx.*.sCoords.WorldSize.x;
                    if (nClamp <= pDst.*.pRect.right) {
                        pDst.*.pRect.right = nClamp;
                    }
                    nClamp = pRoomEx.*.sCoords.WorldSize.y + pRoomEx.*.sCoords.WorldPosition.y;
                    if (nClamp <= pDst.*.pRect.bottom) {
                        pDst.*.pRect.bottom = nClamp;
                    }
                    if (pRoomEx.*.sCoords.WorldSize.x + pRoomEx.*.sCoords.WorldPosition.x <= pDst.*.pRect.left or pRoomEx.*.sCoords.WorldPosition.y + pRoomEx.*.sCoords.WorldSize.y <= pDst.*.pRect.top) {
                        pDst.*.pRect.left = 0;
                        pDst.*.pRect.top = 0;
                        pDst.*.pRect.right = 0;
                        pDst.*.pRect.bottom = 0;
                    }
                }

                iCellX += 1;
                if (!(iCellX < nGridWidth)) break;
            }
        }

        nCellY += 1;
        if (!(nCellY < nGridHeight)) break;
    }
}

/// DrlgLogic.cpp:369 (1.14d win 0066ccb0 | mac 0014f15b)
pub fn AllocDrlgCoordList(pRoomEx: [*c]D2RoomExStrc) void {
    const pLevel = pRoomEx.*.pLevel;
    const pMemory = pLevel.?.pDrlg.?.pMemoryPool;
    const pCoordList: [*c]D2DrlgCoordListStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(D2DrlgCoordListStrc), ".\\DRLG\\DrlgLogic.cpp", 0xdf)));
    @memset(@as([*]u8, @ptrCast(pCoordList))[0..@sizeOf(D2DrlgCoordListStrc)], 0);
    pRoomEx.*.pDrlgCoordList = pCoordList;
    pCoordList.*.eFlags |= 1;
    pLevel.?.nLastRoomExCoordsIndex = 1;
    pCoordList.*.nListSize = 1;
    const pCoord: [*c]D2RoomCoordListStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(D2RoomCoordListStrc), ".\\DRLG\\DrlgLogic.cpp", 0xe9)));
    pCoordList.*.pCoord = pCoord;
    @memset(@as([*]u8, @ptrCast(pCoord))[0 .. @as(usize, @intCast(pCoordList.*.nListSize)) * @sizeOf(D2RoomCoordListStrc)], 0);
    pCoordList.*.pCoord.*.nIndex = pLevel.?.nLastRoomExCoordsIndex;
    pCoordList.*.pCoord.*.pBox.nPosY = pRoomEx.*.sCoords.WorldPosition.y;
    pCoordList.*.pCoord.*.pBox.nHeight = pRoomEx.*.sCoords.WorldSize.y + pRoomEx.*.sCoords.WorldPosition.y;
    pCoordList.*.pCoord.*.pBox.nPosX = pRoomEx.*.sCoords.WorldPosition.x;
    pCoordList.*.pCoord.*.pBox.nWidth = pRoomEx.*.sCoords.WorldSize.x + pRoomEx.*.sCoords.WorldPosition.x;
    pCoordList.*.pCoord.*.pRect.top = pRoomEx.*.sCoords.WorldPosition.y;
    pCoordList.*.pCoord.*.pRect.bottom = pRoomEx.*.sCoords.WorldSize.y + pRoomEx.*.sCoords.WorldPosition.y;
    pCoordList.*.pCoord.*.pRect.left = pRoomEx.*.sCoords.WorldPosition.x;
    pCoordList.*.pCoord.*.pRect.right = pRoomEx.*.sCoords.WorldSize.x + pRoomEx.*.sCoords.WorldPosition.x;
}

/// DrlgLogic.cpp:395 (1.14d 0066ce30)
pub fn rOOMEXGetGridIndex(pRoomEx: [*c]D2RoomExStrc, nX: i32, nY: i32) i32 {
    const pCoordList = pRoomEx.*.pDrlgCoordList;
    if (pCoordList == null) {
        @panic("DRLGLOGIC: unrecoverable internal error (recon 0x29c)");
    }
    var pCoordEntry: [*c]D2RoomCoordListStrc = undefined;
    if ((pCoordList.?.eFlags & 1) == 0) {
        pCoordEntry = cellAsCoord(DrlgGrid.GetGridFlags(&pCoordList.?.sCoordIndexGrid, @divTrunc(nX, 5) - pRoomEx.*.sCoords.WorldPosition.x, @divTrunc(nY, 5) - pRoomEx.*.sCoords.WorldPosition.y));
    } else {
        pCoordEntry = pCoordList.?.pCoord;
    }
    if (pCoordEntry == null) {
        return -1;
    }

    return pCoordEntry.*.nIndex;
}

/// DrlgLogic.cpp:419 (1.14d 0066ceb0)
pub fn getCoordListFromSubtilePos(pRoomEx: [*c]D2RoomExStrc, nX: i32, nY: i32) [*c]D2RoomCoordListStrc {
    const pCoordList = pRoomEx.*.pDrlgCoordList;
    if (pCoordList == null) {
        @panic("DRLGLOGIC: unrecoverable internal error (recon 0x29c)");
    }
    if ((pCoordList.?.eFlags & 1) != 0) {
        return pCoordList.?.pCoord;
    }

    const pCoordEntry = cellAsCoord(DrlgGrid.GetGridFlags(&pCoordList.?.sCoordIndexGrid, @divTrunc(nX, 5) - pRoomEx.*.sCoords.WorldPosition.x, @divTrunc(nY, 5) - pRoomEx.*.sCoords.WorldPosition.y));
    return pCoordEntry;
}

/// DrlgLogic.cpp:438 (1.14d win 0066cf30 | mac 0014f340)
pub fn GetCoordList(pRoomEx: [*c]D2RoomExStrc) [*c]D2RoomCoordListStrc {
    if (pRoomEx.*.pDrlgCoordList != null) {
        return pRoomEx.*.pDrlgCoordList.?.pCoord;
    }

    @panic("DRLGLOGIC: unrecoverable internal error (recon 0x2cd)");
}

/// DrlgLogic.cpp:454 (1.14d 0066cf60)
pub fn linkCoordListEntry(nY: i32, nX: i32, pNeighborRoom: [*c]D2RoomExStrc, pSrcRoom: [*c]D2RoomExStrc) void {
    const bPointInside = DrlgRoom.isPointInside(&pSrcRoom.*.sCoords, nX, nY);
    if (bPointInside == 0) {
        return;
    }

    var pNeighborCoordList = pSrcRoom.*.pDrlgCoordList;
    if (pNeighborCoordList != null) {
        var nNeighborCoordIndex: [*c]D2RoomCoordListStrc = undefined;
        if ((pNeighborCoordList.?.eFlags & 1) == 0) {
            nNeighborCoordIndex = cellAsCoord(DrlgGrid.GetGridFlags(&pNeighborCoordList.?.sCoordIndexGrid, nX - pSrcRoom.*.sCoords.WorldPosition.x, nY - pSrcRoom.*.sCoords.WorldPosition.y));
        } else {
            nNeighborCoordIndex = pNeighborCoordList.?.pCoord;
        }

        pNeighborCoordList = pNeighborRoom.*.pDrlgCoordList;
        if (pNeighborCoordList != null) {
            var pCoordEntry: [*c]D2RoomCoordListStrc = undefined;
            if ((pNeighborCoordList.?.eFlags & 1) == 0) {
                pCoordEntry = cellAsCoord(DrlgGrid.GetGridFlags(&pNeighborCoordList.?.sCoordIndexGrid, nX - pNeighborRoom.*.sCoords.WorldPosition.x, nY - pNeighborRoom.*.sCoords.WorldPosition.y));
            } else {
                pCoordEntry = pNeighborCoordList.?.pCoord;
            }

            const pDestGrid = cellAsGrid(nNeighborCoordIndex.*.nIndex);
            if (pDestGrid == null) {
                return;
            }

            const pSrcGrid = cellAsGrid(pCoordEntry.*.nIndex);
            if (pSrcGrid == null) {
                return;
            }
            if (pSrcRoom.*.pLevel.?.eD2LevelId != pNeighborRoom.*.pLevel.?.eD2LevelId) {
                return;
            }
            if (pDestGrid == pSrcGrid) {
                return;
            }
            // line 495: bNode compare (the D2DrlgGridStrc* casts are noise)
            if (nNeighborCoordIndex.*.bNode != pCoordEntry.*.bNode) {
                return;
            }

            InitializeDrlgCoordList(pNeighborRoom, pSrcGrid, pDestGrid, cellAsGrid(nNeighborCoordIndex.*.bNode));
            return;
        }
    }

    @panic("DRLGLOGIC: unrecoverable internal error (recon 0x29c)");
}

/// DrlgLogic.cpp:511 (1.14d 0066d040)
pub fn linkBorderCoordLists(pRoomEx: [*c]D2RoomExStrc) void {
    var nNearIndex: i32 = 0;
    if (0 >= pRoomEx.*.nDrlgRoomsExNearCount) {
        return;
    }

    while (true) {
        const pSrcRoom: [*c]D2RoomExStrc = pRoomEx.*.ppDrlgRoomsExNear[@intCast(nNearIndex)];
        if (pSrcRoom != pRoomEx and pSrcRoom.*.pDrlgCoordList != null) {
            const nFreeResult = DrlgRoom.FreeRoomEx(&pRoomEx.*.sCoords, &pSrcRoom.*.sCoords, 1);
            if (nFreeResult == 0) {
                var nCoordValue: i32 = pRoomEx.*.sCoords.WorldPosition.x;
                if (nCoordValue <= pRoomEx.*.sCoords.WorldSize.x + nCoordValue) {
                    while (true) {
                        linkCoordListEntry(pRoomEx.*.sCoords.WorldPosition.y, nCoordValue, pRoomEx, pSrcRoom);
                        linkCoordListEntry(pRoomEx.*.sCoords.WorldPosition.y + pRoomEx.*.sCoords.WorldSize.y, nCoordValue, pRoomEx, pSrcRoom);
                        nCoordValue += 1;
                        if (!(nCoordValue <= pRoomEx.*.sCoords.WorldSize.x + pRoomEx.*.sCoords.WorldPosition.x)) break;
                    }
                }

                nCoordValue = pRoomEx.*.sCoords.WorldPosition.y;
                if (nCoordValue <= pRoomEx.*.sCoords.WorldSize.y + nCoordValue) {
                    while (true) {
                        linkCoordListEntry(nCoordValue, pRoomEx.*.sCoords.WorldPosition.x, pRoomEx, pSrcRoom);
                        linkCoordListEntry(nCoordValue, pRoomEx.*.sCoords.WorldSize.x + pRoomEx.*.sCoords.WorldPosition.x, pRoomEx, pSrcRoom);
                        nCoordValue += 1;
                        if (!(nCoordValue <= pRoomEx.*.sCoords.WorldPosition.y + pRoomEx.*.sCoords.WorldSize.y)) break;
                    }
                }
            }
        }

        nNearIndex += 1;
        if (!(nNearIndex < pRoomEx.*.nDrlgRoomsExNearCount)) break;
    }
}

/// DrlgLogic.cpp:550 (1.14d 0066d110). The recon takes `(int*)&pRoomExCtx` — the
/// address of a stack-frame context for DRLGLOGIC_PopulateGridCoordIndices (which
/// is a panic-stub in DrlgGrid.zig). The context is reconstructed best-effort as
/// an extern struct below; its true layout is a Ghidra-RE task for the populate fn.
pub fn buildRoomCoordList(pRoomEx: [*c]D2RoomExStrc, nOrientGridFlags: i32, nFloorGridFlags: i32, pGrid: [*c]D2DrlgGridStrc) void {
    const PopulateGridCtx = extern struct {
        pRoomEx: ?*D2RoomExStrc,
        pCoordOrientGrid: ?*D2DrlgGridStrc,
        nOrientGridFlags: i32,
        pLocalGrid: ?*D2DrlgGridStrc,
        pOrientGrid: ?*D2DrlgGridStrc,
        nFloorGridFlags: i32,
        nCoordIndexStart: i32,
        nCoordIndexEnd: i32,
        nReserved: u32,
    };

    var local_1448: [1024]i32 = undefined;
    var local_448: [256]i32 = undefined;
    var sLocalGrid: D2DrlgGridStrc = undefined;

    const pLevel = pRoomEx.*.pLevel;
    const pMemory = pLevel.?.pDrlg.?.pMemoryPool;
    const nOrientGridFlagsSave = nOrientGridFlags;
    const pCoordListStrc: [*c]D2DrlgCoordListStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(D2DrlgCoordListStrc), ".\\DRLG\\DrlgLogic.cpp", 0xdf)));
    @memset(@as([*]u8, @ptrCast(pCoordListStrc))[0..@sizeOf(D2DrlgCoordListStrc)], 0);
    pRoomEx.*.pDrlgCoordList = pCoordListStrc;
    setGridDoorFlags(pGrid, pRoomEx);
    pCoordListStrc.*.eFlags |= 2;
    DrlgGrid.initGridCells(pMemory, &pCoordListStrc.*.sOrientationGrid, pRoomEx.*.sCoords.WorldSize.x + 1, pRoomEx.*.sCoords.WorldSize.y + 1);
    if (pLevel.?.nLastRoomExCoordsIndex == 0) {
        pLevel.?.nLastRoomExCoordsIndex = 1;
    }

    var nCoordCount = pLevel.?.nLastRoomExCoordsIndex;
    DrlgGrid.FillGrid(&sLocalGrid, pRoomEx.*.sCoords.WorldSize.x + 1, pRoomEx.*.sCoords.WorldSize.y + 1, &local_1448, &local_448);
    setGridWallFlags(pRoomEx, &sLocalGrid);

    var sCtx: PopulateGridCtx = undefined;
    sCtx.nReserved = 0;
    sCtx.pCoordOrientGrid = &pCoordListStrc.*.sOrientationGrid;
    sCtx.nOrientGridFlags = nOrientGridFlagsSave;
    sCtx.pLocalGrid = &sLocalGrid;
    sCtx.pOrientGrid = pGrid;
    sCtx.nFloorGridFlags = nFloorGridFlags;
    sCtx.pRoomEx = pRoomEx;
    sCtx.nCoordIndexStart = nCoordCount;
    sCtx.nCoordIndexEnd = nCoordCount;
    DrlgGrid.populateGridCoordIndices(@ptrCast(&sCtx));
    DrlgGrid.ResetGrid(&sLocalGrid);
    nCoordCount = sCtx.nCoordIndexEnd - sCtx.nCoordIndexStart + 1;
    pCoordListStrc.*.nListSize = nCoordCount;
    const pAllocCoordArray: [*c]D2RoomCoordListStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @as(usize, @intCast(nCoordCount)) * @sizeOf(D2RoomCoordListStrc), ".\\DRLG\\DrlgLogic.cpp", 0xe9)));
    pCoordListStrc.*.pCoord = pAllocCoordArray;
    @memset(@as([*]u8, @ptrCast(pAllocCoordArray))[0 .. @as(usize, @intCast(pCoordListStrc.*.nListSize)) * @sizeOf(D2RoomCoordListStrc)], 0);
    pLevel.?.nLastRoomExCoordsIndex += pCoordListStrc.*.nListSize;
    buildCoordRegions(pRoomEx, pCoordListStrc);
    fillTileGridFlags(pRoomEx);
    linkBorderCoordLists(pRoomEx);
}
