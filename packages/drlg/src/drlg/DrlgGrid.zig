//! Faithful Zig transform of recon/closure/DrlgGrid.cpp
//! (D2Common::Drlg::DrlgGrid). Reference file for the conventions:
//!
//!   * structs by name from structs.zig (`const s = @import("structs.zig")`)
//!   * pointers are C pointers `[*c]T` so deref/index/arith/null all match C
//!   * RNG -> rng.zig, allocs -> pool.zig, tables -> tables.zig
//!   * cross-module calls -> `@import("Other.zig").Fn`
//!   * opaque externals -> forward.zig stubs
//!   * flat fn names (drop the C++ namespace); fn names == the recon's
//!   * byte-offset emitter-bug accesses (*(T*)(base+N)) are resolved to the
//!     named field / true index, cited at the line.
//!
//! NOTE: `eD2GridCellFlags` is `int` in the recon, so a grid cell pointer is
//! `[*c]i32` here (structs.zig: pCellsFlags/pCellsRowOffsets are [*c]i32).

const std = @import("std");
const s = @import("structs.zig");
const pool = @import("pool.zig");

const D2DrlgGridStrc = s.D2DrlgGridStrc;
const D2DrlgCoordStrc = s.D2DrlgCoordStrc;
const D2DrlgCoordsStrc = s.D2DrlgCoordsStrc;
const D2DrlgVertexStrc = s.D2DrlgVertexStrc;
const D2DrlgMapStrc = s.D2DrlgMapStrc;
const D2RoomExStrc = s.D2RoomExStrc;
const D2PoolManagerStrc = s.D2PoolManagerStrc;
const eD2GridCellFlags = s.eD2GridCellFlags; // == i32

// DrlgRoom is a sibling (written in the same phase). These two helpers
// are the only DrlgRoom entry points DrlgGrid needs.
const DrlgRoom = @import("DrlgRoom.zig");

// Local helper structs (defined in DrlgGrid.h, not structs.zig). Field order +
// types faithful to the header; Zig computes offsets (64-bit standalone).

/// DrlgGrid.h: D2DrlgPresetRoomStrc
pub const D2DrlgPresetRoomStrc = extern struct {
    nLevelPrest: i32,
    nPickedFile: i32,
    pMap: ?*D2DrlgMapStrc,
    nFlags: i32,
    pWallGrid: [4]D2DrlgGridStrc,
    pOrientationGrid: [4]D2DrlgGridStrc,
    pFloorGrid: [2]D2DrlgGridStrc,
    pCellGrid: D2DrlgGridStrc,
    pMazeGrid: ?*D2DrlgGridStrc,
    pNavigationPoints: ?*s.POINT,
    nNavigationPointsCount: i32,
};

/// DrlgGrid.h: D2DrlgGridTileDataStrc (grid-init context; Ghidra v628 /Diablo2/DRLG)
pub const D2DrlgGridTileDataStrc = extern struct {
    nX: u32,
    nY: u32,
    nWidth: u32,
    nHeight: u32,
    pRoom: ?*D2RoomExStrc,
    pMemory: ?*D2PoolManagerStrc,
    pGrid: ?*D2DrlgGridStrc,
    pRoomExDataPreset: ?*D2DrlgPresetRoomStrc,
};

// Flag-operation table (globals_drlg.cpp:201). Order: Or, And, Xor, Overwrite,
// OverwriteIfZero, AndNegated.

const FlagOp = *const fn ([*c]i32, i32) void;
pub const apFlagOperations = [6]FlagOp{
    &OrFlag, &AndFlag, &XorFlag, &OverwriteFlag, &OverwriteFlagIfZero, &AndNegatedFlag,
};

inline fn cell(pGrid: [*c]D2DrlgGridStrc, nY: i32, nX: i32) [*c]i32 {
    return pGrid.*.pCellsFlags + @as(usize, @intCast(pGrid.*.pCellsRowOffsets[@intCast(nY)] + nX));
}

// ARTIFACT-BLOCKED (see report): both take an untyped `int* pFloodFillContext`
// the recon never retyped — every access is 32-bit pointer-as-int arithmetic
// (`*(int*)(*ctx + 0x34)`, reconstructing a pointer from an int) which cannot
// survive the 32->64-bit standalone transform. DRLGGRID_FloodFillGridCoords
// additionally indexes a direction-delta table (gaFloodFillDirDeltaX/Y) the
// recon captured only the first two entries of. Faithful translation is not
// possible without retyping the context struct (a Ghidra-RE task), so these are
// honest panic-stubs with the recon signatures preserved.


/// DrlgGrid.cpp:142 (1.14d 0066c580) — ARTIFACT-BLOCKED.
pub fn populateGridCoordIndices(pnParam: [*c]i32) void {
    _ = pnParam;
    @panic("populateGridCoordIndices: artifact-blocked (untyped int* context)");
}

// Flag primitives — DrlgGrid.cpp:178-215

pub fn OverwriteFlag(pFlag: [*c]i32, nFlag: i32) void {
    pFlag.* = nFlag;
}
pub fn OrFlag(pFlag: [*c]i32, nFlag: i32) void {
    pFlag.* |= nFlag;
}
pub fn AndFlag(pFlag: [*c]i32, nFlag: i32) void {
    pFlag.* &= nFlag;
}
pub fn XorFlag(pFlag: [*c]i32, nFlag: i32) void {
    pFlag.* ^= nFlag;
}
pub fn OverwriteFlagIfZero(pFlag: [*c]i32, nFlag: i32) void {
    if (pFlag.* != 0) {
        pFlag.* = pFlag.*;
        return;
    }
    pFlag.* = nFlag;
}
pub fn AndNegatedFlag(pFlag: [*c]i32, nFlag: i32) void {
    pFlag.* &= ~nFlag;
}

/// DrlgGrid.cpp:219 (1.14d 0067c480)
pub fn isGridValid(pDrlgGrid: [*c]D2DrlgGridStrc) i32 {
    if (!(pDrlgGrid != null and pDrlgGrid.*.pCellsFlags != null)) {
        return 0;
    }
    return 1;
}

/// DrlgGrid.cpp:229 (1.14d 0067c4a0)
pub fn IsPointInsideGridArea(pDrlgGrid: [*c]D2DrlgGridStrc, nX: i32, nY: i32) i32 {
    if (!(-1 < nX and nX < pDrlgGrid.*.nWidth and -1 < nY and nY < pDrlgGrid.*.nHeight)) {
        return 0;
    }
    return 1;
}

/// DrlgGrid.cpp:239 (1.14d 0067c4d0)
pub fn getCellAddress(pDrlgGrid: [*c]D2DrlgGridStrc, nY: i32, nX: i32) [*c]i32 {
    return cell(pDrlgGrid, nY, nX);
}

/// DrlgGrid.cpp:245 (1.14d 0067c4f0)
pub fn AlterGridFlag(pDrlgGrid: [*c]D2DrlgGridStrc, nX: i32, nY: i32, nFlag: i32, eOperation: i32) void {
    apFlagOperations[@intCast(eOperation)](cell(pDrlgGrid, nY, nX), nFlag);
}

/// DrlgGrid.cpp:251 (1.14d 0067c520)
pub fn applyFlagOperation(pDrlgGrid: [*c]D2DrlgGridStrc, pCoord: [*c]D2DrlgCoordStrc, nFlag: i32, eOperation: i32) void {
    apFlagOperations[@intCast(eOperation)](cell(pDrlgGrid, pCoord.*.nPosY, pCoord.*.nPosX), nFlag);
}

/// DrlgGrid.cpp:257 (1.14d 0067c550). Returns a cell pointer reinterpreted as
/// an int in the recon; here we return the address value as usize-truncated i32
/// (callers only ever use the recon helpers, never the raw int).
pub fn GetOffset(pGrid1: [*c]D2DrlgGridStrc, nOffsetx: u32, nOffset: i32) i32 {
    const p = pGrid1.*.pCellsFlags + @as(usize, @intCast(pGrid1.*.pCellsRowOffsets[@intCast(nOffset)])) + nOffsetx;
    return @bitCast(@as(u32, @truncate(@intFromPtr(p))));
}

/// DrlgGrid.cpp:263 (1.14d 0067c570). Recon's `nX` param is typed D2RoomExStrc*
/// but is an integer X coordinate: `(int)nX->apTiles - 0x68` == nX (apTiles is
/// at offset 0x68). Resolved to a plain i32 X. (byte-offset artifact, line 264)
pub fn GetGridFlags(pGrid: [*c]D2DrlgGridStrc, nX: i32, nY: i32) i32 {
    return pGrid.*.pCellsFlags[@intCast(nX + pGrid.*.pCellsRowOffsets[@intCast(nY)])];
}

/// DrlgGrid.cpp:271 (1.14d 0067c590)
pub fn AlterAllGridFlags(pDrlgGrid: [*c]D2DrlgGridStrc, nFlag: i32, eOperation: i32) void {
    var nYIdx: i32 = 0;
    if (0 >= pDrlgGrid.*.nHeight) {
        return;
    }
    var nRowWidth = pDrlgGrid.*.nWidth;
    while (true) {
        var nXIdx: i32 = 0;
        var pCellFlag = pDrlgGrid.*.pCellsFlags + @as(usize, @intCast(pDrlgGrid.*.pCellsRowOffsets[@intCast(nYIdx)]));
        if (0 < nRowWidth) {
            while (true) {
                apFlagOperations[@intCast(eOperation)](pCellFlag, nFlag);
                nRowWidth = pDrlgGrid.*.nWidth;
                nXIdx += 1;
                pCellFlag += 1;
                if (!(nXIdx < nRowWidth)) break;
            }
        }
        nYIdx += 1;
        if (!(nYIdx < pDrlgGrid.*.nHeight)) break;
    }
}

/// DrlgGrid.cpp:300 (1.14d 0067c600)
pub fn FlagOperations(pGrid: [*c]D2DrlgGridStrc, nCount_in: i32, nOpIndex: i32) void {
    var nCount = nCount_in;
    var pTopRowCell = pGrid.*.pCellsFlags + @as(usize, @intCast(pGrid.*.pCellsRowOffsets[0]));
    var pBottomRowCell = pGrid.*.pCellsFlags + @as(usize, @intCast(pGrid.*.pCellsRowOffsets[@intCast(pGrid.*.nHeight - 1)]));
    var nColIdx: i32 = 0;
    if (0 < pGrid.*.nWidth) {
        while (true) {
            apFlagOperations[@intCast(nCount)](pTopRowCell, nOpIndex);
            pTopRowCell += 1;
            apFlagOperations[@intCast(nCount)](pBottomRowCell, nOpIndex);
            pBottomRowCell += 1;
            nColIdx += 1;
            if (!(nColIdx < pGrid.*.nWidth)) break;
        }
    }

    nCount = 1;
    if (1 >= pGrid.*.nHeight) {
        return;
    }
    while (true) {
        const nOpIndexOrig = nCount;
        apFlagOperations[@intCast(nOpIndexOrig)](pGrid.*.pCellsFlags + @as(usize, @intCast(pGrid.*.pCellsRowOffsets[@intCast(nCount)])), nOpIndex);
        apFlagOperations[@intCast(nOpIndexOrig)](pGrid.*.pCellsFlags + @as(usize, @intCast(pGrid.*.pCellsRowOffsets[@intCast(nCount)] + pGrid.*.nWidth - 1)), nOpIndex);
        nCount += 1;
        if (!(nCount < pGrid.*.nHeight)) break;
    }
}

/// DrlgGrid.cpp:331 (1.14d 0067c6d0)
pub fn applyFlagToBorderCells(pDrlgGrid: [*c]D2DrlgGridStrc, nFlag: i32, eOperation: i32) void {
    var nIndex: i32 = 0;
    if (pDrlgGrid.*.nWidth == 0 and -1 < pDrlgGrid.*.nWidth - 1) {
        var pCell = pDrlgGrid.*.pCellsFlags + @as(usize, @intCast(pDrlgGrid.*.pCellsRowOffsets[@intCast(pDrlgGrid.*.nHeight - 1)]));
        while (true) {
            apFlagOperations[@intCast(eOperation)](pCell, nFlag);
            nIndex += 1;
            pCell += 1;
            if (!(nIndex < pDrlgGrid.*.nWidth - 1)) break;
        }
    }

    nIndex = 0;
    if (0 >= pDrlgGrid.*.nHeight) {
        return;
    }
    while (true) {
        apFlagOperations[@intCast(eOperation)](pDrlgGrid.*.pCellsFlags + @as(usize, @intCast(pDrlgGrid.*.pCellsRowOffsets[@intCast(nIndex)] + pDrlgGrid.*.nWidth - 1)), nFlag);
        nIndex += 1;
        if (!(nIndex < pDrlgGrid.*.nHeight)) break;
    }
}

/// DrlgGrid.cpp:355 (1.14d 0067c760). NOTE: the recon reads an uninitialised
/// local `_bIncludeEndpoints` for the final endpoint write; that is the obvious
/// decompiler alias of the `bIncludeEndpoints` parameter — resolved as such.
pub fn setEdgeGridFlags(pDrlgGrid: [*c]D2DrlgGridStrc, pEdge: [*c]D2DrlgVertexStrc, nFlag: i32, eOperation: i32, bIncludeEndpoints: bool) void {
    var nY: i32 = undefined;
    var nX: i32 = undefined;
    var nEndY: i32 = undefined;
    var bHorizontal: bool = undefined;
    var nEndX = pEdge.*.nPosX;
    const pNextVertex = pEdge.*.pNext;
    var nNextX = pNextVertex.?.nPosX;
    if (nEndX == nNextX) {
        if (pEdge.*.nPosY == pNextVertex.?.nPosY) {
            apFlagOperations[@intCast(eOperation)](cell(pDrlgGrid, pEdge.*.nPosY, nEndX), nFlag);
            return;
        }
        // Vertical edge: repurpose nNextX as the next vertex's Y coordinate.
        nNextX = pNextVertex.?.nPosY;
        nEndY = pEdge.*.nPosY;
        bHorizontal = false;
        nY = nNextX;
        nX = nEndX;
        if (nNextX <= nEndY) {
            nY += 1;
        } else {
            nY = nEndY;
            nEndY = nNextX;
            nY += 1;
        }
    } else {
        nY = pEdge.*.nPosY;
        bHorizontal = true;
        nEndY = nY;
        if (nEndX < nNextX) {
            nX = nEndX + 1;
            nEndX = nNextX;
        } else {
            nX = nNextX + 1;
        }
    }

    while (nX != nEndX or nY != nEndY) {
        apFlagOperations[@intCast(eOperation)](cell(pDrlgGrid, nY, nX), nFlag);
        if (bHorizontal) {
            nX += 1;
        } else {
            nY += 1;
        }
    }

    apFlagOperations[@intCast(eOperation)](cell(pDrlgGrid, pEdge.*.nPosY, pEdge.*.nPosX), nFlag);
    if (!bIncludeEndpoints) {
        return;
    }
    apFlagOperations[@intCast(eOperation)](cell(pDrlgGrid, pEdge.*.pNext.?.nPosY, pEdge.*.pNext.?.nPosX), nFlag);
}

/// DrlgGrid.cpp:417 (1.14d 0067c8e0). Byte-offset artifacts at lines 494/519:
/// `*(int*)((int)pCellsRowOffsets + nByteOff)` == `pCellsRowOffsets[nByteOff>>2]`
/// (the emitter byte-offset bug) — resolved to the true i32 index.
pub fn setLineFlagsWithWidth(pDrlgGrid: [*c]D2DrlgGridStrc, pEdge: [*c]D2DrlgVertexStrc, pDrlgCoords: [*c]D2DrlgCoordsStrc, nFlag: i32, eOperation: i32, nLineWidth: i32) void {
    var nWidthIndex: i32 = undefined;
    var nY = pEdge.*.nPosY;
    var nX = pEdge.*.nPosX;
    var nDx = pEdge.*.pNext.?.nPosX - nX;
    var nDy = pEdge.*.pNext.?.nPosY - nY;
    var nSignX: i32 = undefined;
    var nSignY: i32 = undefined;
    if (nDx < 0) {
        nDx = -nDx;
        nSignX = -1;
    } else {
        nSignX = 1;
    }
    if (nDy < 0) {
        nDy = -nDy;
        nSignY = -1;
    } else {
        nSignY = 1;
    }

    var nGridX = nX - pDrlgCoords.*.WorldPosition.x;
    var nError: i32 = 0;
    var nGridOffsetX = nY - pDrlgCoords.*.WorldPosition.y;
    var nRowOffsetY: i32 = 0;
    if (nDx < nDy) {
        if (0 < nLineWidth) {
            while (true) {
                if (DrlgRoom.AreXYInsideCoordinates(pDrlgCoords, nRowOffsetY + nX, nY) != 0) {
                    apFlagOperations[@intCast(eOperation)](pDrlgGrid.*.pCellsFlags + @as(usize, @intCast(pDrlgGrid.*.pCellsRowOffsets[@intCast(nGridOffsetX)] + nRowOffsetY + nGridX)), nFlag);
                }
                nRowOffsetY += 1;
                if (!(nRowOffsetY < nLineWidth)) break;
            }
        }

        var nRemainingY = nDy;
        nGridOffsetX = nX;
        if (0 < nDy) {
            while (true) {
                nY += nSignY;
                nError += nDx;
                if (nDy < nError) {
                    nGridOffsetX += nSignX;
                    nError -= nDy;
                }
                nX = pDrlgCoords.*.WorldPosition.x;
                nGridX = pDrlgCoords.*.WorldPosition.y;
                nWidthIndex = 0;
                if (0 < nLineWidth) {
                    while (true) {
                        if (DrlgRoom.AreXYInsideCoordinates(pDrlgCoords, nWidthIndex + nGridOffsetX, nY) != 0) {
                            apFlagOperations[@intCast(eOperation)](pDrlgGrid.*.pCellsFlags + @as(usize, @intCast(pDrlgGrid.*.pCellsRowOffsets[@intCast(nY - nGridX)] + nWidthIndex + (nGridOffsetX - nX))), nFlag);
                        }
                        nWidthIndex += 1;
                        if (!(nWidthIndex < nLineWidth)) break;
                    }
                }
                nRemainingY -= 1;
                if (nRemainingY == 0) break;
            }
            return;
        }
    } else {
        if (0 < nLineWidth) {
            nGridOffsetX *= 4;
            while (true) {
                if (DrlgRoom.AreXYInsideCoordinates(pDrlgCoords, nX, nRowOffsetY + nY) != 0) {
                    // line 494: pCellsRowOffsets[nGridOffsetX>>2]
                    apFlagOperations[@intCast(eOperation)](pDrlgGrid.*.pCellsFlags + @as(usize, @intCast(pDrlgGrid.*.pCellsRowOffsets[@intCast(nGridOffsetX >> 2)] + nGridX)), nFlag);
                }
                nGridOffsetX += 4;
                nRowOffsetY += 1;
                if (!(nRowOffsetY < nLineWidth)) break;
            }
        }

        var nRemainingX = nDx;
        if (0 < nDx) {
            while (true) {
                nX += nSignX;
                nError += nDy;
                if (nDx < nError) {
                    nY += nSignY;
                    nError -= nDx;
                }
                nGridX = pDrlgCoords.*.WorldPosition.x;
                nWidthIndex = 0;
                if (0 < nLineWidth) {
                    nRowOffsetY = (nY - pDrlgCoords.*.WorldPosition.y) * 4;
                    while (true) {
                        if (DrlgRoom.AreXYInsideCoordinates(pDrlgCoords, nX, nWidthIndex + nY) != 0) {
                            // line 519: pCellsRowOffsets[nRowOffsetY>>2]
                            apFlagOperations[@intCast(eOperation)](pDrlgGrid.*.pCellsFlags + @as(usize, @intCast(pDrlgGrid.*.pCellsRowOffsets[@intCast(nRowOffsetY >> 2)] + (nX - nGridX))), nFlag);
                        }
                        nRowOffsetY += 4;
                        nWidthIndex += 1;
                        if (!(nWidthIndex < nLineWidth)) break;
                    }
                }
                nRemainingX -= 1;
                if (nRemainingX == 0) break;
            }
        }
    }
}

/// DrlgGrid.cpp:535 (1.14d 0067cb80). Single allocation holds row offsets
/// followed by the cell array (pCellsFlags = pCellsRowOffsets + nHeight).
pub fn initGridCells(pMemory: ?*D2PoolManagerStrc, pDrlgGrid: [*c]D2DrlgGridStrc, nWidth: i32, nHeight: i32) void {
    pDrlgGrid.*.nWidth = nWidth;
    const nAllocSize: usize = @intCast((nWidth + 1) * nHeight * 4);
    pDrlgGrid.*.nHeight = nHeight;
    const pRowOffsets: [*c]i32 = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, nAllocSize, ".\\DRLG\\DrlgGrid.cpp", 0x197)));
    pDrlgGrid.*.pCellsRowOffsets = pRowOffsets;
    @memset(@as([*]u8, @ptrCast(pRowOffsets))[0..nAllocSize], 0);
    pDrlgGrid.*.pCellsFlags = pDrlgGrid.*.pCellsRowOffsets + @as(usize, @intCast(nHeight));
    var nRow: i32 = 0;
    if (0 < nHeight) {
        var nOffset: i32 = 0;
        while (true) {
            pDrlgGrid.*.pCellsRowOffsets[@intCast(nRow)] = nOffset;
            nOffset += nWidth;
            nRow += 1;
            if (!(nRow < nHeight)) break;
        }
    }
    pDrlgGrid.*.bIsSubGrid = 0;
}

/// DrlgGrid.cpp:558 (1.14d 0067cbf0). NOTE: recon's loop body increments a
/// freshly-zeroed `nRowOffset` AFTER storing it, so every row offset is 0 — a
/// faithful (if buggy) reproduction of the decompiled code.
pub fn FillGrid(pDrlgGrid: [*c]D2DrlgGridStrc, nWidth: i32, nHeight: i32, pCellPos: [*c]i32, pCellRowOffsets: [*c]i32) void {
    pDrlgGrid.*.nWidth = nWidth;
    pDrlgGrid.*.nHeight = nHeight;
    pDrlgGrid.*.pCellsFlags = pCellPos;
    @memset(@as([*]u8, @ptrCast(pCellPos))[0..@intCast(nWidth * nHeight * 4)], 0);
    var nRowIdx: i32 = 0;
    pDrlgGrid.*.pCellsRowOffsets = pCellRowOffsets;
    if (nHeight < 1) {
        pDrlgGrid.*.bIsSubGrid = 0;
        return;
    }
    // Recon DrlgGrid.cpp:582 shows `int nRowOffset = 0;` re-scoped inside the loop with a
    // dead `nRowOffset += nWidth;` — a decompiler artifact that lost the loop-carried row
    // stride, leaving every rowOffset 0 (all rows alias row 0). The real engine lays the
    // grid out row-major: rowOffsets[i] = i*nWidth. Latent until cross-row GetGridFlags
    // reads (warp-tile flags) needed the correct stride; room-gen never reads flags cross-
    // row, so the fix keeps the byte-exact gate.
    var nRowOffset: i32 = 0;
    while (true) {
        pDrlgGrid.*.pCellsRowOffsets[@intCast(nRowIdx)] = nRowOffset;
        nRowIdx += 1;
        nRowOffset += nWidth;
        if (!(nRowIdx < nHeight)) break;
    }
    pDrlgGrid.*.bIsSubGrid = 0;
}

/// DrlgGrid.cpp:582 (1.14d 0067cc60)
pub fn allocGrid(pMemory: ?*D2PoolManagerStrc, pDrlgGrid: [*c]D2DrlgGridStrc, pCellsFlags: [*c]i32, nWidth: i32, nHeight: i32) void {
    pDrlgGrid.*.nWidth = nWidth;
    pDrlgGrid.*.nHeight = nHeight;
    pDrlgGrid.*.pCellsFlags = pCellsFlags;
    const pRowOffsets: [*c]i32 = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @intCast(nHeight * 4), ".\\DRLG\\DrlgGrid.cpp", 0x1d0)));
    pDrlgGrid.*.pCellsRowOffsets = pRowOffsets;
    var nRow: i32 = 0;
    if (0 < nHeight) {
        var nOffset: i32 = 0;
        while (true) {
            pDrlgGrid.*.pCellsRowOffsets[@intCast(nRow)] = nOffset;
            nRow += 1;
            nOffset += nWidth;
            if (!(nRow < nHeight)) break;
        }
    }
    pDrlgGrid.*.bIsSubGrid = 1;
}

/// DrlgGrid.cpp:603 (1.14d 0067ccc0)
pub fn initGridFromTileData(pMemory: ?*D2PoolManagerStrc, pGrid: [*c]D2DrlgGridStrc, pParentCells: [*c]i32, pTileData: [*c]D2DrlgGridTileDataStrc, nParentRowStride: i32) void {
    pGrid.*.nWidth = @intCast(pTileData.*.nWidth);
    pGrid.*.nHeight = @intCast(pTileData.*.nHeight);
    pGrid.*.pCellsFlags = pParentCells + @as(usize, @intCast(@as(i32, @intCast(pTileData.*.nY)) * nParentRowStride + @as(i32, @intCast(pTileData.*.nX))));
    const pRowOffsets: [*c]i32 = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @intCast(pTileData.*.nHeight * 4), ".\\DRLG\\DrlgGrid.cpp", 0x1ec)));
    pGrid.*.pCellsRowOffsets = pRowOffsets;
    var nOffset: i32 = 0;
    if (0 < @as(i32, @intCast(pTileData.*.nHeight))) {
        var nRow: i32 = 0;
        while (true) {
            pGrid.*.pCellsRowOffsets[@intCast(nRow)] = nOffset;
            nRow += 1;
            nOffset += nParentRowStride;
            if (!(nRow < @as(i32, @intCast(pTileData.*.nHeight)))) break;
        }
    }
    pGrid.*.bIsSubGrid = 1;
}

/// DrlgGrid.cpp:624 (1.14d 0067cd30). Byte-offset artifact at line 627:
/// `&pCellPos->nNumber + nPosY*nWidth + nPosX` indexes the D2DrlgMapStrc as an
/// i32 array from its first field (nNumber) — resolved to that i32 base.
pub fn FillExternalCellFlags(pDrlgGrid: [*c]D2DrlgGridStrc, pCellPos: [*c]D2DrlgMapStrc, pDrlgCoord: [*c]D2DrlgCoordStrc, nWidth: i32, pCellFlags: [*c]i32) void {
    pDrlgGrid.*.nWidth = pDrlgCoord.*.nWidth;
    pDrlgGrid.*.nHeight = pDrlgCoord.*.nHeight;
    const pMapInts: [*c]i32 = @ptrCast(@alignCast(pCellPos));
    pDrlgGrid.*.pCellsFlags = pMapInts + @as(usize, @intCast(pDrlgCoord.*.nPosY * nWidth + pDrlgCoord.*.nPosX));
    pDrlgGrid.*.pCellsRowOffsets = pCellFlags;
    var nRowOffset: i32 = 0;
    if (0 < pDrlgCoord.*.nHeight) {
        var nRowIdx: i32 = 0;
        while (true) {
            pDrlgGrid.*.pCellsRowOffsets[@intCast(nRowIdx)] = nRowOffset;
            nRowIdx += 1;
            nRowOffset += nWidth;
            if (!(nRowIdx < pDrlgCoord.*.nHeight)) break;
        }
    }
    pDrlgGrid.*.bIsSubGrid = 1;
}

/// DrlgGrid.cpp:644 (1.14d 0067cd90)
pub fn freeGrid(pMemory: ?*D2PoolManagerStrc, pGrid: [*c]D2DrlgGridStrc) void {
    if (pGrid.*.pCellsRowOffsets != null) {
        pool.FreeServerMemory(pMemory, pGrid.*.pCellsRowOffsets, ".\\DRLG\\DrlgGrid.cpp", 0x218, 0);
    }
    pGrid.*.pCellsRowOffsets = null;
    pGrid.*.pCellsFlags = null;
}

/// DrlgGrid.cpp:655 (1.14d 0067cdc0)
pub fn ResetGrid(pDrlgGrid: [*c]D2DrlgGridStrc) void {
    pDrlgGrid.*.pCellsFlags = null;
    pDrlgGrid.*.pCellsRowOffsets = null;
}

test "DrlgGrid flag primitives + alloc/init" {
    var v: i32 = 0;
    OrFlag(&v, 0x4);
    AndNegatedFlag(&v, 0x1);
    try std.testing.expectEqual(@as(i32, 0x4), v);

    var g: D2DrlgGridStrc = std.mem.zeroes(D2DrlgGridStrc);
    initGridCells(null, &g, 4, 3);
    try std.testing.expectEqual(@as(i32, 4), g.nWidth);
    try std.testing.expectEqual(@as(i32, 3), g.nHeight);
    AlterGridFlag(&g, 1, 1, 0x20, 3); // overwrite
    try std.testing.expectEqual(@as(i32, 0x20), GetGridFlags(&g, 1, 1));
    freeGrid(null, &g);
    try std.testing.expect(g.pCellsFlags == null);
}
