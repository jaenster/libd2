//! Mechanical transform of the OUTDOOR preset/border PLACEMENT core
//! from recon/closure/Outdoors.cpp (the spawn machinery shared by every act's
//! InitAct{1..5}OutdoorLevel tree) + recon/closure/OutPlace.cpp.
//!
//! Faithful by construction:
//!   * grid field access by NAME (recon's `(int)pDrlgLevelData + 0x04/0x2c` raw
//!     byte reaches -> the named D2DrlgLevelDataWildernessLevel.sGrid{Preset,
//!     Outdoor} fields; the 32-bit offsets do not survive 64-bit pointers).
//!   * the pointer-as-integer coordinate idiom in TestOutdoorLevelPreset
//!     (`(int)nX0->apTiles - 0x68` == nX since apTiles is at offset 0x68;
//!     `&nXIter->pOrth + 1` == nXIter+1 since pOrth is at offset 0) -> plain i32.
//!   * RNG -> the VERIFIED rng.RANDOM_RandomNumberSelector primitive. The recon
//!     inlines that selector for the Fisher-Yates index draws; Ghidra rendered
//!     the non-pow2 branch inconsistently — full64 % n at Outdoors.cpp:776 but
//!     low-word % n at :794 / :653 / :667. The selector (cross-checked against
//!     src/rng.zig) is the ground truth, so all inline draws route through it.
//!   * AllocPresetFileTracker RETURNS the file index. The recon shows the caller
//!     (SpawnOutdoorLevelPresetEx, OutPlace lines 591-595) reading an
//!     uninitialised `nFileIndexTracked` after a void call — a lost return value;
//!     the function's last statement computes (dwData2+1)%dwData1, which is the
//!     index the caller consumes.
//!
//! Transformed here (cite recon Outdoors.cpp unless noted):
//!   DRLGOUTDOOR_GetPresetCoordFromGrid       :435
//!   AlterAdjacentPresetGridCells             :448
//!   SetBlankGridCell                         :456
//!   DRLGOUTDOOR_IsGridCellPresetFree         :468
//!   DRLGOUTDOOR_IsGridCellEmpty              :475
//!   TestOutdoorLevelPreset                   :482
//!   DRLGOUTDOOR_AllocPresetFileTracker       :550
//!   SpawnOutdoorLevelPresetEx                :583
//!   SpawnPresetFarAway                       :626
//!   SpawnOutdoorLevelPreset                  :730

const std = @import("std");
const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const pool = @import("../pool.zig");
const tables = @import("../tables.zig");
const DrlgGrid = @import("../DrlgGrid.zig");

const W = s.D2DrlgLevelDataWildernessLevel;

// DrlgGrid::AlterGridFlag eOperation indices (DrlgGrid.zig apFlagOperations):
//   0=Or 1=And 2=Xor 3=Overwrite 4=OverwriteIfZero 5=AndNegated
const OP_OR: i32 = 0;
const OP_OVERWRITE: i32 = 3;
const OP_ANDNEG: i32 = 5;

// Toward-zero division by 8 (recon `(v + (v>>31 & 7)) >> 3`).
inline fn div8(v: i32) i32 {
    return (v + (@as(i32, @intCast(@as(u1, @truncate(@as(u32, @bitCast(v)) >> 31)))) * 7)) >> 3;
}

inline fn wild(pLevel: [*c]s.D2DrlgLevelStrc) *W {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
}

// Preset::GetSizeX / GetSizeY   Preset.cpp:1261/1268
fn presetSizeX(nPresetId: i32) i32 {
    return tables.lvlPrestGetLine(nPresetId).*.SizeX;
}
fn presetSizeY(nPresetId: i32) i32 {
    return tables.lvlPrestGetLine(nPresetId).*.SizeY;
}

// DRLGOUTDOOR_GetPresetCoordFromGrid   Outdoors.cpp:435
pub fn getPresetCoordFromGrid(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, nY: i32) i32 {
    const pData = wild(pLevel);
    const uFlags = DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nX, nY);
    if ((uFlags & 0x200) == 0) return 0;
    return DrlgGrid.GetGridFlags(&pData.sGridPreset, nX, nY);
}

// AlterAdjacentPresetGridCells   Outdoors.cpp:448
pub fn AlterAdjacentPresetGridCells(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, nY: i32) void {
    const pData = wild(pLevel);
    DrlgGrid.AlterGridFlag(&pData.sGridPreset, nX, nY, 0, OP_OVERWRITE);
    DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, nX, nY, 0, OP_OVERWRITE);
}

// SetBlankGridCell   Outdoors.cpp:456
pub fn SetBlankGridCell(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, nY: i32) void {
    const pData = wild(pLevel);
    DrlgGrid.AlterGridFlag(&pData.sGridPreset, nX, nY, 0, OP_OVERWRITE);
    DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, nX, nY, 0x100, OP_OVERWRITE);
}

// DRLGOUTDOOR_IsGridCellPresetFree   Outdoors.cpp:468
pub fn isGridCellPresetFree(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, nY: i32) i32 {
    const uFlags: u32 = @bitCast(DrlgGrid.GetGridFlags(&wild(pLevel).sGridOutdoor, nX, nY));
    return @bitCast(~(uFlags >> 10) & 1);
}

// gaAct5BorderPresetTable   Game.exe .rdata 0x006f2038 (10 rows, 5 i32)
// Each row: { eType, nMinIdx, nMaxIdx, nPresetNormal, nPresetHarrogath }. Looked
// up by DRLGOUTDOOR_GetSecondaryBorderPresetFromLvlSub (0067e000).
const Act5BorderPresetRow = struct { eType: i32, nMinIdx: i32, nMaxIdx: i32, nPresetNormal: i32, nPresetHarrogath: i32 };
const gaAct5BorderPresetTable = [10]Act5BorderPresetRow{
    .{ .eType = 0x31, .nMinIdx = 0x01, .nMaxIdx = 0x10, .nPresetNormal = 0x393, .nPresetHarrogath = 0x3db },
    .{ .eType = 0x31, .nMinIdx = 0x1f, .nMaxIdx = 0x2e, .nPresetNormal = 0x393, .nPresetHarrogath = 0x3db },
    .{ .eType = 0x30, .nMinIdx = 0x01, .nMaxIdx = 0x01, .nPresetNormal = 0x373, .nPresetHarrogath = 0x3bf },
    .{ .eType = 0x30, .nMinIdx = 0x02, .nMaxIdx = 0x03, .nPresetNormal = 0x371, .nPresetHarrogath = 0x3bd },
    .{ .eType = 0x30, .nMinIdx = 0x04, .nMaxIdx = 0x04, .nPresetNormal = 0x374, .nPresetHarrogath = 0x3c0 },
    .{ .eType = 0x30, .nMinIdx = 0x05, .nMaxIdx = 0x05, .nPresetNormal = 0x37f, .nPresetHarrogath = 0x3cb },
    .{ .eType = 0x30, .nMinIdx = 0x06, .nMaxIdx = 0x07, .nPresetNormal = 0x37d, .nPresetHarrogath = 0x3c9 },
    .{ .eType = 0x30, .nMinIdx = 0x08, .nMaxIdx = 0x08, .nPresetNormal = 0x380, .nPresetHarrogath = 0x3cc },
    .{ .eType = 0x30, .nMinIdx = 0x1e, .nMaxIdx = 0x1e, .nPresetNormal = 0x000, .nPresetHarrogath = 0x000 },
    .{ .eType = 0x30, .nMinIdx = 0x1f, .nMaxIdx = 0x1f, .nPresetNormal = -5, .nPresetHarrogath = -5 },
};

// DRLGOUTDOOR_GetSecondaryBorderPresetFromLvlSub   1.14d 0067e000 (__fastcall)
// Maps an Act-5 secondary-border (borderType, presetIndex) to a LvlPrest id via
// gaAct5BorderPresetTable, choosing the Harrogath (0x75) column when applicable.
pub fn getSecondaryBorderPresetFromLvlSub(pLevel: [*c]s.D2DrlgLevelStrc, nBorderType: i32, nPresetIndex: i32) i32 {
    if (nBorderType == 0x30 or nBorderType == 0x31) {
        for (gaAct5BorderPresetTable) |row| {
            if (nBorderType == row.eType and row.nMinIdx <= nPresetIndex and nPresetIndex <= row.nMaxIdx) {
                if (pLevel.*.eD2LevelId != .FrozenTundra) {
                    return (row.nPresetNormal - row.nMinIdx) + nPresetIndex;
                }
                return (row.nPresetHarrogath - row.nMinIdx) + nPresetIndex;
            }
        }
    }
    // recon: Fog::ErrorManager::ERROR_UnrecoverableInternalError_Halt (code 0x1a5)
    @panic("GetSecondaryBorderPresetFromLvlSub: no matching border-preset row");
}

// DRLGOUTDOOR_ValidateSecondaryBorderCell   1.14d 0067e080 (__fastcall)
// pfnValidateBorderCell callback used by AddSecondaryBorder/ValidateSubTilePlace.
// Resolves the cell's wall-grid preset and accepts iff it is the special -5 row,
// or it matches the expected primary-floor preset and the cell is preset-free.
pub fn validateSecondaryBorderCell(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, nY: i32, nExpectedPreset: i32, nUnused: i32, nGridFlags: u32) i32 {
    _ = nUnused;
    const nResolvedPreset = getSecondaryBorderPresetFromLvlSub(
        pLevel,
        @bitCast((nGridFlags >> 0x14) & 0x3f),
        @bitCast((nGridFlags >> 8) & 0xff),
    );
    if (nResolvedPreset == -5) return 1;
    if (nResolvedPreset != nExpectedPreset) return 0;
    return @intFromBool(isGridCellPresetFree(pLevel, nX, nY) != 0);
}

// DRLGOUTDOOR_IsGridCellEmpty   Outdoors.cpp:475
pub fn isGridCellEmpty(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, nY: i32) i32 {
    const uFlags = DrlgGrid.GetGridFlags(&wild(pLevel).sGridOutdoor, nX, nY);
    return @intFromBool((uFlags & 0x1b81) == 0);
}

// TestOutdoorLevelPreset   Outdoors.cpp:482
// Rectangle-fits a preset at (nX,nY): all covered sGridOutdoor cells must be
// in-grid and free of the 0x1b81 occupancy mask. nFlags/nOffset grow the test
// rect on selected edges (border-overhang allowance).
pub fn TestOutdoorLevelPreset(
    pLevel: [*c]s.D2DrlgLevelStrc,
    nX: i32,
    nY_in: i32,
    nLevelPrestId: i32,
    nOffset: i32,
    nFlags: i32,
) i32 {
    const pData = wild(pLevel);
    var nY = nY_in;
    var xExtent: i32 = 1; // recon nSizeY = ceil(SizeX/8)
    var yExtent: i32 = 1; // recon nSizeX = ceil(SizeY/8)
    if (nLevelPrestId != 0) {
        const pPrest = tables.lvlPrestGetLine(nLevelPrestId);
        xExtent = div8(pPrest.*.SizeX);
        yExtent = div8(pPrest.*.SizeY);
    }

    var xStart = nX;
    if (nOffset != 0) {
        if (nFlags & 1 != 0) {
            nY -= nOffset;
            yExtent += nOffset;
        }
        if (nFlags & 2 != 0) xExtent += nOffset;
        if (nFlags & 4 != 0) yExtent += nOffset;
        if (nFlags & 8 != 0) {
            xStart = nX - nOffset;
            xExtent += nOffset;
        }
    }

    const yEnd = nY + yExtent;
    if (nY >= yEnd) return 1;
    const xEnd = xStart + xExtent;

    while (nY < yEnd) : (nY += 1) {
        if (xStart < xEnd) {
            var x = xStart;
            while (x < xEnd) : (x += 1) {
                if (DrlgGrid.IsPointInsideGridArea(&pData.sGridOutdoor, x, nY) == 0) return 0;
                if (DrlgGrid.GetGridFlags(&pData.sGridOutdoor, x, nY) & 0x1b81 != 0) return 0;
            }
        }
    }
    return 1;
}

// DRLGOUTDOOR_AllocPresetFileTracker   Outdoors.cpp:550
// Per-(preset) round-robin file index across one level. Returns the index the
// caller uses (the recovered void-return; see file header).
pub fn allocPresetFileTracker(nLevelPrestId: i32, pLevel: [*c]s.D2DrlgLevelStrc) i32 {
    const pMemory = pLevel.*.pDrlg.?.pMemoryPool;
    var pNode: ?*s.D2DrlgLevelLinkNodeStrc = pLevel.*.pLevelLinkNodeFirst;
    while (pNode) |n| : (pNode = n.pNext) {
        if (n.dwData0 == nLevelPrestId) break;
    }

    if (pNode == null) {
        const pLvlPrest = tables.lvlPrestGetLine(nLevelPrestId);
        // 0x10 in the 32-bit engine; @sizeOf in the 64-bit transform (8-byte pNext).
        const node: *s.D2DrlgLevelLinkNodeStrc = @ptrCast(@alignCast(pool.AllocServerMemory(
            pMemory,
            @sizeOf(s.D2DrlgLevelLinkNodeStrc),
            ".\\DRLG\\Outdoors.cpp",
            0xf9,
        )));
        node.dwData0 = pLvlPrest.*.Def;
        node.dwData1 = pLvlPrest.*.Files;
        node.dwData2 = @bitCast(rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(pLvlPrest.*.Files)));
        node.pNext = pLevel.*.pLevelLinkNodeFirst;
        pLevel.*.pLevelLinkNodeFirst = node;
        pNode = node;
    }

    const n = pNode.?;
    n.dwData2 = @rem(n.dwData2 + 1, n.dwData1);
    return n.dwData2;
}

// SpawnOutdoorLevelPresetEx   Outdoors.cpp:583
// Stamps a preset's grid cells: marks the covered sGridOutdoor cells as preset
// (0x200 | fileIndex<<16) and writes nPresetId into the anchor sGridPreset cell.
pub fn SpawnOutdoorLevelPresetEx(
    pLevel: [*c]s.D2DrlgLevelStrc,
    nX: i32,
    nY: i32,
    nPresetId: i32,
    nFileIndex_in: i32,
    bFlag: i32,
) void {
    const pData = wild(pLevel);
    const nPresetSizeX = presetSizeX(nPresetId);
    const nPresetSizeY = presetSizeY(nPresetId);
    var nFileIndex = nFileIndex_in;
    if (nFileIndex == -1) {
        nFileIndex = allocPresetFileTracker(nPresetId, pLevel);
    }

    const nGridEndY = div8(nPresetSizeY) + nY;
    if (nY < nGridEndY) {
        const nGridEndX = div8(nPresetSizeX) + nX;
        var y = nY;
        while (y < nGridEndY) : (y += 1) {
            if (nX < nGridEndX) {
                var x = nX;
                while (x < nGridEndX) : (x += 1) {
                    DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, x, y, 0xf0000, OP_ANDNEG);
                    DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, x, y, (nFileIndex << 0x10) | 0x200, OP_OR);
                    if (bFlag != 0 and ((3 < nPresetId and nPresetId < 0x10) or (@as(u32, @bitCast(nPresetId -% 0x16c)) < 0xc))) {
                        DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, x, y, 1, OP_OR);
                    }
                    DrlgGrid.AlterGridFlag(&pData.sGridPreset, x, y, 0, OP_OVERWRITE);
                }
            }
        }
    }

    DrlgGrid.AlterGridFlag(&pData.sGridPreset, nX, nY, nPresetId, OP_OVERWRITE);
}

// SpawnPresetFarAway   Outdoors.cpp:626
// Scans the interior grid for the placeable cell maximally distant (weighted
// metric) from pDrlgCoord's centre, then stamps the preset there.
pub fn SpawnPresetFarAway(
    pLevel: [*c]s.D2DrlgLevelStrc,
    pDrlgCoord: [*c]s.D2DrlgCoordStrc,
    nLvlPrestId: i32,
    nRand: i32,
    nOffset: i32,
    nFlags: i32,
) i32 {
    const pData = wild(pLevel);
    const nWorldX = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    const nWorldY = pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    // recon's nGridWidth = nGridCoordsHeight, nGridHeight = nGridCoordsWidth (swapped)
    const nRangeX: i32 = pData.nGridCoordsWidth - 2; // used with X loop
    const nRangeY: i32 = pData.nGridCoordsHeight - 2; // used with Y loop

    const nRandOffsetY: i32 = if (nRangeX < 1) 0 else @bitCast(rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nRangeX)));
    const nRandOffsetX: i32 = if (nRangeY < 1) 0 else @bitCast(rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nRangeY)));

    const nCoordWidth = pDrlgCoord.*.nWidth;
    const nCoordPosX = pDrlgCoord.*.nPosX;
    const nCoordHeight = pDrlgCoord.*.nHeight;
    const nCoordPosY = pDrlgCoord.*.nPosY;
    var nBestDist: i32 = 0;
    var nBestX: i32 = -1;
    var nBestY: i32 = -1;
    if (-1 >= nRangeY) return 0;

    var nLoopY: i32 = 0;
    while (nLoopY <= nRangeY) : (nLoopY += 1) {
        if (-1 < nRangeX) {
            const nY = @rem(nLoopY + nRandOffsetX, nRangeY) + 1;
            var nLoopX: i32 = 0;
            while (nLoopX <= nRangeX) : (nLoopX += 1) {
                const nX = @rem(nRandOffsetY + nLoopX, nRangeX) + 1;
                if (TestOutdoorLevelPreset(pLevel, nX, nY, nLvlPrestId, nOffset, nFlags) != 0) {
                    var nDistX = nX * 8 - (@divTrunc(nCoordWidth, 2) + nCoordPosX) + 4 + nWorldX;
                    if (nDistX < 0) nDistX = -nDistX;
                    var nDistY = nY * 8 - (@divTrunc(nCoordHeight, 2) + nCoordPosY) + 4 + nWorldY;
                    if (nDistY < 0) nDistY = -nDistY;
                    if (nDistY < nDistX) {
                        nDistY += nDistX * 2;
                    } else {
                        nDistY = nDistX + nDistY * 2;
                    }
                    if (nBestDist < @divTrunc(nDistY, 2)) {
                        nBestY = nY;
                        nBestX = nX;
                        nBestDist = @divTrunc(nDistY, 2);
                    }
                }
            }
        }
    }

    if (!(nBestX != -1 and nBestY != -1)) return 0;
    SpawnOutdoorLevelPresetEx(pLevel, nBestX, nBestY, nLvlPrestId, nRand, 0);
    return 1;
}

// SpawnOutdoorLevelPreset   Outdoors.cpp:730
// Fisher-Yates shuffles all interior cells off pLevel->sSeed, then stamps the
// preset at the first shuffled cell that fits.
pub fn SpawnOutdoorLevelPreset(
    pLevel: [*c]s.D2DrlgLevelStrc,
    nLevelPrestId: i32,
    nRand: i32,
    nOffset: i32,
    nFlags: i32,
) i32 {
    const pData = wild(pLevel);
    const nGridWidth = pData.nGridCoordsWidth - 2;
    const nTotalCells: i32 = (pData.nGridCoordsHeight - 2) * nGridWidth;
    if (nTotalCells == 0) return 0;

    var aCellX: [513]i32 = undefined;
    var aCellY: [513]i32 = undefined;
    {
        var i: i32 = 0;
        while (i < nTotalCells) : (i += 1) {
            aCellX[@intCast(i)] = @rem(i, nGridWidth);
            aCellY[@intCast(i)] = @divTrunc(i, nGridWidth);
        }
    }

    // Fisher-Yates: two index draws per step, both via the verified selector.
    var nShuffleCount: u32 = @bitCast(nTotalCells);
    while (nShuffleCount != 0) {
        const a: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        const b: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        nShuffleCount -= 1;
        const tx = aCellX[a];
        const ty = aCellY[a];
        aCellX[a] = aCellX[b];
        aCellY[a] = aCellY[b];
        aCellX[b] = tx;
        aCellY[b] = ty;
    }

    var i: i32 = 0;
    while (i < nTotalCells) : (i += 1) {
        const cx = aCellX[@intCast(i)];
        const cy = aCellY[@intCast(i)] + 1;
        if (TestOutdoorLevelPreset(pLevel, cx + 1, cy, nLevelPrestId, nOffset, nFlags) != 0) {
            SpawnOutdoorLevelPresetEx(pLevel, cx + 1, cy, nLevelPrestId, nRand, 0);
            return 1;
        }
    }
    return 0;
}
