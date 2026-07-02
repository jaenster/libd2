//! Mechanical transform of the shared Act-1/2/4/5 OUTDOOR BORDER
//! placement core from recon/closure/OutPlace.cpp (+ the road .rdata tables and
//! the DRLGOUTROOM_MarkBorderJunctions helper from recon/closure/Drlg.cpp).
//!
//! Faithful by construction:
//!   * grid field access by NAME: the recon's `(int)pLevelData + 0x18 / 0x2c`
//!     raw byte reaches map to D2DrlgLevelDataWildernessLevel.sGridLink /
//!     .sGridOutdoor (the 32-bit offsets do not survive 64-bit pointers).
//!   * the pointer-as-int coordinate idiom in SetBlankBorderGridCells
//!     (`(int)nScanX->apTiles + nStepX - 0x68` == nScanX + nStepX since apTiles
//!     is at offset 0x68) -> plain i32 arithmetic.
//!   * RNG only via OutPlace.SpawnOutdoorLevelPresetEx (-1 file index) which
//!     routes through the VERIFIED rng selector; this function adds no extra
//!     draws of its own.
//!   * the .rdata lookup tables are reproduced EXACTLY from Ghidra Game.exe
//!     1.14d (session 62fbfe69), each cited with its address. Several are
//!     indexed by negative offsets because the engine's symbol sits mid-array
//!     (the decompiler captured only the forward half); the full ranges are
//!     recovered here.
//!
//! Transformed here (cite recon OutPlace.cpp unless noted):
//!   GetActNoFromLevelNumber                  Drlg.cpp (moved from Outdoors.zig)
//!   DRLGOUTPLACE_GetRoadPresetId             OutPlace.cpp:161
//!   DRLGOUTPLACE_GetAdjacentRoadPresetId     OutPlace.cpp:171
//!   SetBlankBorderGridCells                  OutPlace.cpp:196 (1.14d 00675670)
//!   DRLGOUTDOOR_GetAdjacentLevelVisMask      Outdoors.cpp:360
//!   GetOutLinkVisFlag                        Outdoors.cpp:380
//!   SetOutGridLinkFlags                      OutPlace.cpp:268 (1.14d 00675770)
//!   PlaceAct1245OutdoorBorders               OutPlace.cpp:291 (1.14d 00675850)
//!   DRLGOUTROOM_MarkBorderJunctions          Drlg.cpp:6160
//!   DRLGOUTROOM_GetGridDivisionSize          OutSiege.cpp (trivial getter)

const std = @import("std");
const s = @import("../structs.zig");
const eD2LevelId = s.eD2LevelId;
const rng = @import("../rng.zig");
const tables = @import("../tables.zig");
const DrlgGrid = @import("../DrlgGrid.zig");
const DrlgVer = @import("../DrlgVer.zig");
const DrlgRoom = @import("../DrlgRoom.zig");
const OutPlace = @import("OutPlace.zig");

const W = s.D2DrlgLevelDataWildernessLevel;

// DrlgGrid::AlterGridFlag eOperation indices (DrlgGrid.zig apFlagOperations):
const OP_OR: i32 = 0;
const OP_ANDNEG: i32 = 5;

// eAct values (Drlg.cpp eAct enum) — matches Outdoors.zig ACT_* constants.
const ACT_I: i32 = 0;
const ACT_II: i32 = 1;
const ACT_III: i32 = 2;
const ACT_IV: i32 = 3;
const ACT_V: i32 = 4;

// eDrlgDirection members (used by GetOutLinkVisFlag).
const DIRECTION_NORTHEAST: i32 = 1;
const DIRECTION_SOUTHWEST: i32 = 2;
const DIRECTION_NORTHWEST: i32 = 3;

inline fn wild(pLevel: [*c]s.D2DrlgLevelStrc) *W {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
}

// .rdata road lookup tables (Ghidra Game.exe 1.14d, session 62fbfe69)
//
// gaRoadPresetDirectionLookup @0x6f0fd0 — indexed by (nDx + nDy*3) over -4..+4;
// the engine symbol is logical index 0, so we store 9 entries and add +4.
const DIR_LOOKUP_BIAS: i32 = 4;
const gaRoadPresetDirectionLookup = [9]i32{ -1, 1, -1, 0, -1, 2, -1, 3, -1 };
inline fn dirLookup(nDx: i32, nDy: i32) i32 {
    return gaRoadPresetDirectionLookup[@intCast(nDx + nDy * 3 + DIR_LOOKUP_BIAS)];
}

// gaOutPlaceRoadPresetLookup0 @0x6f0620 (4 ints) is the head of the SAME
// contiguous table as gaOutPlaceRoadPresetLookup1 @0x6f0630 (48 ints) — Ghidra
// split it. Together = 13 rows x 4 cols of corner/road preset ids. lookup0 is
// indexed [roadType + tableIndex*4] from row 0; lookup1 is indexed
// [roadType + dir*4] from row 1 (= +4 ints).
const gaRoadCornerTable = [52]i32{
    0x2000, 0x4000, 0x8000, 0x0, // row 0  (lookup0)
    0x0,    0x4,    0x16c,  0x31f, // row 1  (lookup1[0])
    0x10,   0x5,    0x16d,  0x320,
    0x11,   0x6,    0x16e,  0x321,
    0x0,    0x7,    0x16f,  0x322,
    0x12,   0x8,    0x170,  0x323,
    0x13,   0x9,    0x171,  0x324,
    0x16,   0xa,    0x172,  0x325,
    0x0,    0xb,    0x173,  0x326,
    0x0,    0xc,    0x174,  0x327,
    0x17,   0xd,    0x175,  0x328,
    0x0,    0xe,    0x176,  0x329,
    0x0,    0xf,    0x177,  0x32a,
};
inline fn lookup0(i: i32) i32 {
    return gaRoadCornerTable[@intCast(i)];
}
inline fn lookup1(i: i32) i32 {
    return gaRoadCornerTable[@intCast(i + 4)];
}

// gRoadPresetIdLookupTable @0x6f06f0 (24 ints) — indexed (roadType-4 + dir*2) or
// (roadType-6 + cornerType*2), which can reach -2; the two ints before the
// symbol (0x6f06e8 = 0x177, 0x6f06ec = 0x32a) are the tail of gaRoadCornerTable.
// Stored from index -2 with +2 bias.
const ROADID_BIAS: i32 = 2;
const gRoadPresetIdLookupTable = [26]i32{
    0x177, 0x32a, // idx -2, -1
    0x371, 0x3bd, 0x372, 0x3be, 0x373, 0x3bf, 0x374, 0x3c0,
    0x375, 0x3c1, 0x376, 0x3c2, 0x377, 0x3c3, 0x378, 0x3c4,
    0x379, 0x3c5, 0x37a, 0x3c6, 0x37b, 0x3c7, 0x37c, 0x3c8,
};
inline fn roadId(i: i32) i32 {
    return gRoadPresetIdLookupTable[@intCast(i + ROADID_BIAS)];
}

// gnOutPlaceMax @0x6f1088 — direction-pair corner table indexed -40..+40; the
// engine symbol is logical index 0 (the decompiler captured only the forward
// [41]). Full 81-entry range recovered from 0x6f0fe8, stored with +40 bias.
const OUTPLACEMAX_BIAS: i32 = 40;
const gnOutPlaceMax = [81]i32{
    1,  9,  9,  -1, -1, 1,  8,  -1, -1, 12, -1, -1, -1, -1, 12, 4,  -1, -1, 5,  2,
    2,  10, -1, -1, -1, -1, 10, 1,  9,  9,  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, // idx 0 (= bias 40)
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 11, 11, 3,  12, -1, -1, -1, -1, 12, 4,
    4,  7,  -1, -1, 2,  10, -1, -1, -1, -1, 10, -1, -1, 6,  3,  -1, -1, 11, 11, 3,
};
inline fn outPlaceMax(i: i32) i32 {
    return gnOutPlaceMax[@intCast(i + OUTPLACEMAX_BIAS)];
}

// gnOutPlaceGridHeightByAct @0x6f112c interleaved with gnOutPlaceGridWidthByAct
// @0x6f1130: the engine reads `(&height)[nIdx*2]` and `width[nIdx*2]`, i.e. the
// pair (height, width) at index nIdx. 6 pairs from 0x6f112c.
const gaOutPlaceGridSizeByAct = [12]i32{
    0x175, 0x174, // pair 0
    0x174, 0x177, // pair 1
    0x0,   0x0, // pair 2
    0x175, 0x176, // pair 3
    0x176, 0x177, // pair 4
    0x0,   0x1, // pair 5
};
inline fn gridHeight(nIdx: i32) i32 {
    return gaOutPlaceGridSizeByAct[@intCast(nIdx * 2)];
}
inline fn gridWidth(nIdx: i32) i32 {
    return gaOutPlaceGridSizeByAct[@intCast(nIdx * 2 + 1)];
}

// GetActNoFromLevelNumber   Drlg.cpp (moved from Outdoors.zig)
// aActTownLevelId[5] is read at index 1..5 (OOB at [5]); the engine's table has
// a 6th sentinel so Act-V levels fall through to ACT_V.
pub fn GetActNoFromLevelNumber(eLevel: eD2LevelId) i32 {
    const aActTownLevelId = [_]i32{ 1, 40, 75, 103, 109, std.math.maxInt(i32) };
    var i: usize = 1;
    while (i < 6) : (i += 1) {
        if (@intFromEnum(eLevel) < aActTownLevelId[i]) return @as(i32, @intCast(i)) - ACT_II;
    }
    return ACT_I;
}

// DRLGOUTROOM_GetGridDivisionSize   OutSiege.cpp
inline fn getGridDivisionSize(pLevel: [*c]s.D2DrlgLevelStrc) i32 {
    return @as(i32, @intFromBool(pLevel.*.eD2LevelId == .FrozenTundra)) + 4;
}

// DRLGOUTPLACE_GetRoadPresetId   OutPlace.cpp:161
pub fn getRoadPresetId(nDirX: i32, nDirY: i32, nRoadType: i32) i32 {
    const dir = dirLookup(nDirX, nDirY);
    if (nRoadType <= 3) {
        return lookup1(nRoadType + dir * 4);
    }
    return roadId(nRoadType - 4 + dir * 2);
}

// DRLGOUTPLACE_GetAdjacentRoadPresetId   OutPlace.cpp:171
pub fn getAdjacentRoadPresetId(nDirX_in: i32, nDirY: i32, nPrevDirX_in: i32, nPrevDirY: i32, nRoadType: i32) i32 {
    var nDirX = nDirX_in;
    var nPrevDirX = nPrevDirX_in;
    if (nDirX < 0) {
        nDirX += -2;
    } else if (nDirX > 0) {
        nDirX += 2;
    }
    if (nPrevDirX < 0) {
        nPrevDirX += -2;
    } else if (nPrevDirX > 0) {
        nPrevDirX += 2;
    }
    const nTableIndex = outPlaceMax(nDirX + (nPrevDirX + nPrevDirY) * 9 + nDirY);
    if (nTableIndex == -1) return 0;
    if (nRoadType <= 3) {
        return lookup0(nRoadType + nTableIndex * 4);
    }
    return roadId(nRoadType - 6 + nTableIndex * 2);
}

// DRLGOUTROOM_GetGridDivisionSize used by the road switch
fn rollRoadType(pLevel: [*c]s.D2DrlgLevelStrc, nDirection: i32) ?i32 {
    return switch (@intFromEnum(pLevel.*.nLevelType)) {
        2 => @as(i32, @intFromBool(nDirection == 0)), // !nDirection
        0x10 => 2,
        0x1b => 3,
        0x1f => getGridDivisionSize(pLevel),
        else => null, // default -> goto caseD_3 (exit, no border work)
    };
}

inline fn iabs(v: i32) i32 {
    return if (v < 0) -v else v;
}
inline fn imin(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}

// SetBlankBorderGridCells   OutPlace.cpp:196 (1.14d 00675670)
// Marks the outer blank-border cells of sGridOutdoor with 0x100 (so they are
// skipped during the grid->RoomEx conversion). The recon rendered the 4x4
// (useMaxX, useMaxY, stepX, stepY) direction table as adjacent stack locals
// with nDir3StepY dropped; recovered from the disassembly @0x675692:
//   dir0(0,0,1,1) dir1(1,0,-1,1) dir2(0,1,1,-1) dir3(1,1,-1,-1)
const BlankBorderDir = struct { useMaxX: i32, useMaxY: i32, stepX: i32, stepY: i32 };
const gaBlankBorderDirs = [4]BlankBorderDir{
    .{ .useMaxX = 0, .useMaxY = 0, .stepX = 1, .stepY = 1 },
    .{ .useMaxX = 1, .useMaxY = 0, .stepX = -1, .stepY = 1 },
    .{ .useMaxX = 0, .useMaxY = 1, .stepX = 1, .stepY = -1 },
    .{ .useMaxX = 1, .useMaxY = 1, .stepX = -1, .stepY = -1 },
};
pub fn SetBlankBorderGridCells(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    const pGrid = &pData.sGridOutdoor;
    for (gaBlankBorderDirs) |d| {
        var nGridX: i32 = if (d.useMaxX != 0) pData.nGridCoordsWidth - 1 else 0;
        var nBorderX: i32 = nGridX;
        var nY: i32 = if (d.useMaxY != 0) pData.nGridCoordsHeight - 1 else 0;
        var nGridFlags = DrlgGrid.GetGridFlags(pGrid, nGridX, nY);
        while ((nGridFlags & 1) == 0) {
            nGridFlags = DrlgGrid.GetGridFlags(pGrid, nBorderX, nY);
            var nScanX = nGridX;
            nGridX = nBorderX;
            while (true) {
                nBorderX = nGridX;
                if (nGridFlags & 1 != 0) break;
                DrlgGrid.AlterGridFlag(pGrid, nScanX, nY, 0x100, OP_OR);
                nScanX = nScanX + d.stepX;
                nGridFlags = DrlgGrid.GetGridFlags(pGrid, nScanX, nY);
                nGridX = nBorderX;
            }
            nY += d.stepY;
            nGridFlags = DrlgGrid.GetGridFlags(pGrid, nGridX, nY);
        }
    }
}

// DRLGOUTDOOR_GetAdjacentLevelVisMask   Outdoors.cpp:360
// pOrthLevel is the orth's linked D2DrlgLevelStrc (nType==0); +0x1d0 = eD2LevelId.
fn getAdjacentLevelVisMask(pLevel: [*c]s.D2DrlgLevelStrc, pOrthLevel: [*c]s.D2DrlgLevelStrc) i32 {
    var nIndex: i32 = 0;
    while (nIndex < 8) : (nIndex += 1) {
        const pVisArray = DrlgRoom.getVisArrayFromLevelId(pLevel.*.pDrlg, pLevel.*.eD2LevelId);
        if (pVisArray[@intCast(nIndex)] == pOrthLevel.*.eD2LevelId) break;
    }
    if (nIndex != 8) {
        const sh: u5 = @intCast((nIndex + 4) & 0x1f);
        return @as(i32, 1) << sh;
    }
    return 0;
}

// GetOutLinkVisFlag   Outdoors.cpp:380
// gnOutdoorsGridHeightByLevel @0x6f05d8 (-4) is contiguous with
// gnOutdoorsPresetOffsetByLevel @0x6f05dc; the engine reads `(&height)[eDir*2]`
// and `presetOffset[eDir*2]` = the interleaved pair (M[eDir*2], M[eDir*2+1]).
// Full 8-int block from 0x6f05d8 (Ghidra 1.14d session 62fbfe69).
const gaOutdoorsLinkOffsets = [8]i32{ -4, 4, 4, -4, 12, 4, 4, 12 };
fn GetOutLinkVisFlag(pLevel: [*c]s.D2DrlgLevelStrc, pDrlgVertex: [*c]s.D2DrlgVertexStrc) i32 {
    const pData = wild(pLevel);
    const nPosY = pDrlgVertex.*.nPosY;
    const nPosX = pDrlgVertex.*.nPosX;
    var eEdgeDir: i32 = undefined;
    if (nPosX == 0) {
        eEdgeDir = @intFromBool(nPosY == 0);
    } else {
        const nGridWidth = pData.nGridCoordsWidth - 1;
        if (nPosY == 0) {
            eEdgeDir = @as(i32, @intFromBool(nPosX == nGridWidth)) + DIRECTION_NORTHEAST;
        } else if (nPosX == nGridWidth) {
            eEdgeDir = @as(i32, @intFromBool(nPosY == pData.nGridCoordsHeight - 1)) + DIRECTION_SOUTHWEST;
        } else {
            if (nPosY != pData.nGridCoordsHeight - 1) return 0;
            eEdgeDir = DIRECTION_NORTHWEST;
        }
    }

    const nGridHeight = gaOutdoorsLinkOffsets[@intCast(eEdgeDir * 2)];
    const nOrthMatchOffset = gaOutdoorsLinkOffsets[@intCast(eEdgeDir * 2 + 1)];
    const nPresetOffsetX = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    const nWorldPosY = pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    var pOrthIter = pData.pOrthData;
    while (pOrthIter) |orth| {
        const bInBounds = DrlgRoom.AreXYInsideCoordinates(
            orth.psCoordinatesAndSize,
            nGridHeight + nPosX * 8 + nPresetOffsetX,
            nOrthMatchOffset + nPosY * 8 + nWorldPosY,
        );
        if (orth.neDrlgDirection == eEdgeDir and bInBounds != 0) {
            if (orth.nType != 0) return 0;
            return getAdjacentLevelVisMask(pLevel, @ptrCast(@alignCast(orth.pRoomEx)));
        }
        pOrthIter = orth.pNext;
    }
    return 0;
}

// SetOutGridLinkFlags   OutPlace.cpp:268 (1.14d 00675770)
// No RNG. For each vertex with dwFlags&1, writes vis flags into sGridLink and a
// direction code into sGridOutdoor along the vertex edge.
pub fn SetOutGridLinkFlags(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    const pHead = pData.pVertices orelse return;
    var pVertex: *s.D2DrlgVertexStrc = pHead;
    var pNext: *s.D2DrlgVertexStrc = pHead.pNext.?;
    while (true) {
        if (pVertex.dwFlags & 1 != 0) {
            const nLinkVisFlag = GetOutLinkVisFlag(pLevel, pVertex);
            const byDirection: i32 = pVertex.nDirection;
            DrlgGrid.setEdgeGridFlags(&pData.sGridLink, pVertex, nLinkVisFlag, 0, true);
            DrlgGrid.setEdgeGridFlags(&pData.sGridOutdoor, pVertex, byDirection * 2 + 1, 0, true);
        }
        const bHasNext = pNext != pHead;
        pVertex = pNext;
        pNext = pNext.pNext.?;
        if (!bHasNext) break;
    }
}

// DRLGOUTROOM_MarkBorderJunctions   Drlg.cpp:6160
// No RNG. Marks runs of border vertices forming a convex junction by setting
// nDirection=1 on them (consumed by PlaceAct1245OutdoorBorders' nBorderFlags).
pub fn markBorderJunctions(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    var pCurrent: *s.D2DrlgVertexStrc = pData.pVertices.?;
    var bComplete = false;
    // pPrevious = the vertex whose pNext is pCurrent (i.e. last in the ring).
    var pPrevious: *s.D2DrlgVertexStrc = pCurrent;
    {
        var p = pCurrent.pNext.?;
        while (p != pCurrent) : (p = p.pNext.?) {
            pPrevious = p;
        }
    }
    var pNext: *s.D2DrlgVertexStrc = pCurrent;
    while (true) {
        const pStart = pCurrent;
        const cond1 = pCurrent.nPosX < pCurrent.pNext.?.nPosX and pCurrent.nPosY < pPrevious.nPosY and (pCurrent.dwFlags & 1) == 0 and (pPrevious.dwFlags & 1) == 0;
        const cond2 = pCurrent.pNext.?.nPosY < pCurrent.nPosY and pCurrent.nPosX < pPrevious.nPosX and (pCurrent.dwFlags & 1) == 0 and (pPrevious.dwFlags & 1) == 0;
        pNext = pCurrent;
        if (cond1 or cond2) {
            var pLast: ?*s.D2DrlgVertexStrc = null;
            pNext = pCurrent;
            while (true) {
                if (pNext == pStart) bComplete = true;
                const pN = pNext.pNext.?;
                if (pNext.nPosY < pN.nPosY or pN.nPosX < pNext.nPosX or (pNext.dwFlags & 1) != 0 or (pN.dwFlags & 1) != 0) break;
                const a = pNext.nPosX < pN.nPosX and pN.nPosY < pN.pNext.?.nPosY and (pN.dwFlags & 1) == 0;
                const b = pN.nPosY < pNext.nPosY and pN.nPosX < pN.pNext.?.nPosX and (pN.dwFlags & 1) == 0;
                if (a or b) pLast = pNext;
                pNext = pN;
                if (pN == pCurrent) break;
            }
            if (pLast) |last| {
                while (pCurrent != last) : (pCurrent = pCurrent.pNext.?) {
                    pCurrent.nDirection = 1;
                }
                pCurrent.nDirection = 1;
                pData.dwFlags |= 0x20;
            }
        }
        pCurrent = pNext.pNext.?;
        if (bComplete) return;
        pPrevious = pNext;
        if (pCurrent == pData.pVertices.?) return;
    }
}

// PlaceAct1245OutdoorBorders   OutPlace.cpp:291 (1.14d 00675850)
// Walks the boundary vertex ring; for each edge places the road/border presets
// (SpawnOutdoorLevelPresetEx -1, the RNG consumer) and at junction vertices the
// corner presets, then marks the blank border. Acts 1/2/4/5; Act 3 has its own.
pub fn PlaceAct1245OutdoorBorders(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    const eActNo = GetActNoFromLevelNumber(pLevel.*.eD2LevelId);
    const pHead = pData.pVertices.?;
    var pCurVertex: *s.D2DrlgVertexStrc = pHead;
    var pNextVertex: *s.D2DrlgVertexStrc = pHead.pNext.?;
    const pGrid = &pData.sGridOutdoor;

    while (true) {
        var nDx: i32 = undefined;
        var nDy: i32 = undefined;
        var nNextDx: i32 = undefined;
        var nNextDy: i32 = undefined;
        DrlgVer.GetCoordDiff(pCurVertex, &nDx, &nDy);
        DrlgVer.GetCoordDiff(pNextVertex, &nNextDx, &nNextDy);
        const nAbsDx = iabs(nDx);
        const nAbsDy = iabs(nDy);

        const curX = pCurVertex.nPosX;
        const curY = pCurVertex.nPosY;
        const nX = pNextVertex.nPosX;
        const nY = pNextVertex.nPosY;
        const nEdgeLen = if (nAbsDx == 0) iabs(curY - nY) else iabs(curX - nX);

        const nDirection: i32 = pCurVertex.nDirection;
        var nBorderFlags: i32 = nDirection * 2 + 1;

        // First road switch — default exits the whole function.
        const nRoadType = rollRoadType(pLevel, nDirection) orelse return;

        const nPresetId: i32 = if (nRoadType < 4)
            lookup1(nRoadType + dirLookup(nDx, nDy) * 4)
        else
            roadId(nRoadType - 4 + dirLookup(nDx, nDy) * 2);

        // Place the road segment along the edge.
        if (pCurVertex.dwFlags & 2 == 0) {
            var runX = curX;
            var runY = curY;
            while (runX != nX or runY != nY) {
                runY += nDy;
                runX += nDx;
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, runX, runY, nPresetId, -1, 0);
                DrlgGrid.AlterGridFlag(pGrid, runX, runY, nBorderFlags, OP_OR);
            }
        }

        // Junction corner handling.
        if ((pCurVertex.dwFlags & 1) != 0 and (pCurVertex.dwFlags & 2) == 0) {
            const cx = imin(pCurVertex.nPosX, pNextVertex.nPosX) + @divTrunc(nEdgeLen * nAbsDx, 2);
            const cy = imin(pCurVertex.nPosY, pNextVertex.nPosY) + @divTrunc(nEdgeLen * nAbsDy, 2);
            switch (eActNo) {
                ACT_I, ACT_V => {
                    DrlgGrid.AlterGridFlag(pGrid, cx, cy, 0xf0000, OP_ANDNEG);
                    const flag: i32 = if (pLevel.*.eD2LevelId == .BurialGrounds) 0x40400 else 0x30400;
                    DrlgGrid.AlterGridFlag(pGrid, cx, cy, flag, OP_OR);
                },
                ACT_II => {
                    const nIdx = nDx + 2 + nDy * 2;
                    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, cx, cy, gridHeight(nIdx), -1, 0);
                    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, cx + nAbsDx, cy + nAbsDy, gridWidth(nIdx), -1, 0);
                },
                ACT_IV => {
                    DrlgGrid.AlterGridFlag(pGrid, cx, cy, 0xf0000, OP_ANDNEG);
                    DrlgGrid.AlterGridFlag(pGrid, cx, cy, 0x30400, OP_OR);
                },
                else => {},
            }
        }

        // Junction border flag bit 2.
        var nDirJunction = nDirection;
        if (nDirJunction == 0) nDirJunction = pNextVertex.nDirection;
        if (nDirJunction != 0) nBorderFlags |= 2;

        // Second road switch (road type B) — default exits.
        const nRoadTypeB = rollRoadType(pLevel, nDirJunction) orelse return;

        // Corner road preset (between this edge and the next).
        var nCornerPresetId: i32 = undefined;
        var nValid = false;
        if (pCurVertex.dwFlags & 2 == 0) {
            var idxA: i32 = undefined;
            var idxB: i32 = undefined; // idxA = the "*9" multiplied component
            if (pNextVertex.dwFlags & 2 == 0) {
                idxA = nNextDx * 2;
                if (idxA < 0) idxA += -2 else if (idxA > 0) idxA += 2;
                idxA += nNextDy * 2;
                idxB = nDx * 2;
                if (idxB < 0) idxB += -2 else if (idxB > 0) idxB += 2;
            } else {
                idxB = nDx * 2;
                if (idxB < 0) idxB += -2 else if (idxB > 0) idxB += 2;
                if (nNextDx < 0) {
                    idxA = nNextDx - 2 + nNextDy;
                } else {
                    idxA = nNextDx;
                    if (nNextDx > 0) idxA = nNextDx + 2;
                    idxA += nNextDy;
                }
            }
            const lk = outPlaceMax(idxB + idxA * 9 + nDy * 2);
            if (lk != -1) {
                nCornerPresetId = if (nRoadTypeB < 4) lookup0(nRoadTypeB + lk * 4) else roadId(nRoadTypeB - 6 + lk * 2);
                nValid = true;
            }
        } else {
            var idxA: i32 = nDx; // the non-*9 component here
            var idxB: i32 = undefined; // the "*9" component
            if (pNextVertex.dwFlags & 2 == 0) {
                idxB = nNextDx * 2;
                if (nDx < 0) idxA = nDx - 2 else if (nDx > 0) idxA = nDx + 2;
                if (idxB < 0) idxB += -2 else if (idxB > 0) idxB += 2;
                idxB += nNextDy * 2;
            } else {
                if (nDx < 0) idxA = nDx - 2 else if (nDx > 0) idxA = nDx + 2;
                if (nNextDx < 0) {
                    idxB = nNextDx - 2 + nNextDy;
                } else {
                    idxB = nNextDx;
                    if (nNextDx > 0) idxB = nNextDx + 2;
                    idxB += nNextDy;
                }
            }
            const lk = outPlaceMax(idxA + idxB * 9 + nDy);
            if (lk != -1) {
                nCornerPresetId = if (nRoadTypeB < 4) lookup0(nRoadTypeB + lk * 4) else roadId(nRoadTypeB - 6 + lk * 2);
                nValid = true;
            }
        }

        if (nValid) {
            var doSpawn = true;
            if (nCornerPresetId == 0x13) {
                if (pCurVertex.nDirection != 0) {
                    nCornerPresetId = @as(i32, @intFromBool(pNextVertex.nDirection == 0)) + 0x13;
                } else {
                    nCornerPresetId = 0x15;
                }
            } else if (nCornerPresetId == 0) {
                doSpawn = false;
            }
            if (doSpawn) {
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, nCornerPresetId, -1, 0);
                DrlgGrid.AlterGridFlag(pGrid, nX, nY, nBorderFlags, OP_OR);
            }
        }

        const bIsLast = pNextVertex == pHead;
        pCurVertex = pNextVertex;
        pNextVertex = pNextVertex.pNext.?;
        if (bIsLast) {
            SetBlankBorderGridCells(pLevel);
            return;
        }
    }
}
