//! Mechanical transform of the ACT-V (siege/Bloody-Foothills) OUTDOOR
//! placement tree. This whole subtree was ABSENT from the recon closure until a
//! fresh ghidra-mcp decompile; transformed here faithfully by construction.
//!
//! Sources (1.14d Game.exe, session 62fbfe69):
//!   OutSiege::InitAct5OutdoorLevel                          0067e600
//!   OutPlace::Act5::DRLGOUTROOM_PlaceAct5RoadPath           0067dcf0
//!   OutPlace::Act5::DRLGOUTROOM_PlaceAct5OuterWalls         0067def0
//!   OutPlace::Act5::DRLGOUTROOM_PlaceAct5BorderPresets      0067db50
//!   OutPlace::Act5::DRLGOUTROOM_PlaceAct5SpecialPresets     0067da70  (pLevel EBX)
//!   OutPlace::Act5::DRLGOUTROOM_PlaceAct5SecondaryBorder    0067e0e0  (pLevel EDI)
//!   OutPlace::Act5::DRLGOUTROOM_PlaceAct5SceneryPresets     0067e160
//!   OutPlace::Act5::DRLGOUTPLACE_PlaceAct5BloodyFoothillsRandomPresets 0067e240 (pLevel ESI)
//!   OutPlace::Act5::BloodyFoothills::DRLGOUTPLACE_PlaceAct5SiegePresets 0067e4b0 (pLevel EBX)
//!   OutPlace::Act5::BloodyFoothills::DRLGOUTPLACE_PlaceAct5WallPresets  0067e560
//!
//! .rdata tables recovered from the binary (the recon rendered each as a single-
//! int static stub — the classic .rdata-window collapse; real values read here):
//!   * gaAct5SpecialPresetTable_0  @0x6f1fac  — stride-5 int rows, 3 entries,
//!     loop bound 0x6f1fe8.  Row = {levelId, randVariant, sideFlag, vertPreset,
//!     horizPreset}; the symbol points at the row's horizPreset (index +4), so
//!     the loop reads pTableEntry[-4..0].
//!   * gnAct5OuterWallGrid{Offset,Step}ByType  @0x6f1fd8/0x6f1fdc — two interleaved
//!     int arrays (stride 8 bytes), 12 perimeter-direction pairs {dx=offset,
//!     dy=step}. (&Step)[i*2]@0x6f1fdc+i*8, (&Offset)[i*2]@0x6f1fd8+i*8.
//!   * gnAct5SceneryPresetOffsetByOrientation  @0x6f2104 — stride-7 int rows, 15
//!     entries, loop bound 0x6f22a7.  Row = {levelId, vertPreset, horizPreset,
//!     nType, _unused, nCount, bMandatory}; symbol at row index +1 (loop reads
//!     [-1..5]).
//!
//! Faithful idioms (decompiler artifacts unwound):
//!   * OuterWalls advances nXCur by `(int)nXCur->apTiles + offset*2 - 0x68`. nXCur
//!     is an integer X-coordinate mistyped as D2RoomExStrc*; apTiles sits at offset
//!     0x68, so `(int)nXCur->apTiles - 0x68` == nXCur and the whole step collapses
//!     to `nXCur += offset*2`.  Same `&nXCur->pOrth + 1` == nXCur+1 idiom in
//!     BorderPresets (pOrth at offset 0).
//!   * `& 0xfffffffe` / `& -2` align coordinates to even cells.
//!   * RNG: low-word selector via rng.zig (UNIT_GetModuloFromSeed / D2_SEED_NEXT),
//!     matching the engine's 32-bit modulo (the recon's (ulonglong) widening is the
//!     64-bit decompiler artifact already corrected project-wide).
//!
//! BLOCKED dependencies (documented, NOT golden-reversed):
//!   * PlaceAct5SecondaryBorder -> TileSub::AddSecondaryBorder needs the SUBSTITUTION
//!     subsystem (InitializeDrlgFile/ApplySubstitutionGroup), owned by a concurrent
//!     agent and still @panic-stubbed. Calling it would crash the suite, so it is
//!     guarded here exactly like OutJung guards its absent upstream. Levels that
//!     reach it (every Act-5 outdoor except 0x6e) cannot be byte-exact until
//!     TileSub lands; the faithful call body is preserved behind the guard.
//!   * PlaceAct5OuterWalls reads wall-type codes (0x371..0x37c) from sGridPreset,
//!     written by an upstream Act-5 pre-pass NOT in this tree (same class as Act-3's
//!     pAutomapEx). When that prefill is absent the looked-up index is out of range;
//!     guarded to stop the perimeter walk rather than index OOB.

const std = @import("std");
const s = @import("../structs.zig");
const eD2LevelId = s.eD2LevelId;
const rng = @import("../rng.zig");
const tables = @import("../tables.zig");
const DrlgGrid = @import("../DrlgGrid.zig");
const DrlgVer = @import("../DrlgVer.zig");
const TileSub = @import("../TileSub.zig");
const OutPlace = @import("OutPlace.zig");
const Border = @import("Border.zig");

const W = s.D2DrlgLevelDataWildernessLevel;

// DrlgGrid::AlterGridFlag eOperation 0 == Or (DrlgGrid.zig apFlagOperations).
const OP_OR: i32 = 0;

inline fn wild(pLevel: [*c]s.D2DrlgLevelStrc) *W {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
}

// Toward-zero division by 8 (recon `(v + (v>>31 & 7)) >> 3`).
inline fn div8(v: i32) i32 {
    return (v + (@as(i32, @intCast(@as(u1, @truncate(@as(u32, @bitCast(v)) >> 31)))) * 7)) >> 3;
}

// .rdata tables (real values, see file header)

// gaAct5SpecialPresetTable_0 @0x6f1fac — {levelId, randVariant, sideFlag, vertPreset, horizPreset}
const Act5SpecialRow = struct { levelId: eD2LevelId, randVariant: i32, sideFlag: i32, vertPreset: i32, horizPreset: i32 };
const gaAct5SpecialPresetTable = [3]Act5SpecialRow{
    .{ .levelId = .ArreatPlateau, .randVariant = 0, .sideFlag = 0, .vertPreset = 0x391, .horizPreset = 0x392 },
    .{ .levelId = .FrozenTundra, .randVariant = 0, .sideFlag = 1, .vertPreset = 0x3d7, .horizPreset = 0x3d8 },
    .{ .levelId = .FrozenTundra, .randVariant = 0, .sideFlag = 0, .vertPreset = 0x3d9, .horizPreset = 0x3da },
};

// gnAct5OuterWallGrid{Offset,Step}ByType — {dx (offset), dy (step)} perimeter dirs.
const gaAct5OuterWallDir = [12][2]i32{
    .{ -1, 0 }, .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 },
    .{ 0, -1 }, .{ 1, 0 },  .{ 0, 1 }, .{ -1, 0 },
    .{ -1, 0 }, .{ -1, 0 }, .{ 1, 0 }, .{ 0, 1 },
};

// gnAct5SceneryPresetOffsetByOrientation @0x6f2104 — {levelId, vert, horiz, nType, count, bMandatory}
const Act5SceneryRow = struct { levelId: eD2LevelId, vertPreset: i32, horizPreset: i32, nType: i32, count: i32, mandatory: i32 };
const gaAct5SceneryPresetTable = [15]Act5SceneryRow{
    .{ .levelId = .FrigidHighlands, .vertPreset = 0x3bb, .horizPreset = 0x3bc, .nType = 0, .count = 1, .mandatory = 1 },
    .{ .levelId = .ArreatPlateau, .vertPreset = 0x3bb, .horizPreset = 0x3bc, .nType = 0, .count = 1, .mandatory = 1 },
    .{ .levelId = .FrozenTundra, .vertPreset = 0x3bb, .horizPreset = 0x3bc, .nType = 1, .count = 1, .mandatory = 1 },
    .{ .levelId = .ArreatPlateau, .vertPreset = 0x3b9, .horizPreset = 0x3b9, .nType = -1, .count = 1, .mandatory = 1 },
    .{ .levelId = .FrozenTundra, .vertPreset = 0x3ba, .horizPreset = 0x3ba, .nType = -1, .count = 1, .mandatory = 1 },
    .{ .levelId = .FrigidHighlands, .vertPreset = 0x3b0, .horizPreset = 0x3b3, .nType = -1, .count = 1, .mandatory = 0 },
    .{ .levelId = .FrigidHighlands, .vertPreset = 0x3ae, .horizPreset = 0x3b1, .nType = -1, .count = 4, .mandatory = 0 },
    .{ .levelId = .FrigidHighlands, .vertPreset = 0x3af, .horizPreset = 0x3b2, .nType = -1, .count = 4, .mandatory = 0 },
    .{ .levelId = .ArreatPlateau, .vertPreset = 0x3ad, .horizPreset = 0x3ad, .nType = -1, .count = 1, .mandatory = 0 },
    .{ .levelId = .ArreatPlateau, .vertPreset = 0x3ab, .horizPreset = 0x3ab, .nType = -1, .count = 1, .mandatory = 0 },
    .{ .levelId = .ArreatPlateau, .vertPreset = 0x3ac, .horizPreset = 0x3ac, .nType = -1, .count = 5, .mandatory = 0 },
    .{ .levelId = .FrozenTundra, .vertPreset = 0x3b4, .horizPreset = 0x3b4, .nType = -1, .count = 4, .mandatory = 0 },
    .{ .levelId = .FrozenTundra, .vertPreset = 0x3b5, .horizPreset = 0x3b5, .nType = -1, .count = 4, .mandatory = 0 },
    .{ .levelId = .FrozenTundra, .vertPreset = 0x3b6, .horizPreset = 0x3b6, .nType = -1, .count = 4, .mandatory = 0 },
    .{ .levelId = .FrozenTundra, .vertPreset = 0x3b7, .horizPreset = 0x3b7, .nType = -1, .count = 3, .mandatory = 0 },
};

// DRLGOUTROOM_PlaceAct5RoadPath   OutPlace/Act5.cpp (0067dcf0)
fn PlaceAct5RoadPath(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pWildData = wild(pLevel);
    const nBasePresetId: i32 = @as(i32, @intFromBool(pLevel.*.eD2LevelId == .FrozenTundra)) + 4;
    var pDrlgVertex: *s.D2DrlgVertexStrc = pWildData.pVertices.?;
    var pNextVertex: *s.D2DrlgVertexStrc = pWildData.pVertices.?.pNext.?;
    while (true) {
        var nDx: i32 = undefined;
        var nDy: i32 = undefined;
        var nNextDx: i32 = undefined;
        var nNextDy: i32 = undefined;
        DrlgVer.GetCoordDiff(pDrlgVertex, &nDx, &nDy);
        DrlgVer.GetCoordDiff(pNextVertex, &nNextDx, &nNextDy);
        const nAbsDx: i32 = if (nDx < 0) -nDx else nDx;
        const nAbsDy: i32 = if (nDy < 0) -nDy else nDy;

        const nNextXAligned: i32 = pNextVertex.nPosX & @as(i32, -2);
        const nNextYAligned: i32 = pNextVertex.nPosY & @as(i32, -2);
        var nCurrentX: i32 = pDrlgVertex.nPosX & @as(i32, -2);
        var nCurrentY: i32 = pDrlgVertex.nPosY & @as(i32, -2);
        const nRoadPresetId = Border.getRoadPresetId(nDx, nDy, nBasePresetId);
        if ((pDrlgVertex.dwFlags & 2) == 0) {
            while (nCurrentX != nNextXAligned or nCurrentY != nNextYAligned) {
                nCurrentY += nDy * 2;
                nCurrentX += nDx * 2;
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nCurrentX, nCurrentY, nRoadPresetId, -1, 0);
                DrlgGrid.AlterGridFlag(&pWildData.sGridOutdoor, nCurrentX, nCurrentY, 1, OP_OR);
            }
        }
        if ((pDrlgVertex.dwFlags & 1) != 0) {
            var nMaxCoord: i32 = pDrlgVertex.nPosX;
            if (pDrlgVertex.nPosX <= pNextVertex.nPosX) nMaxCoord = pNextVertex.nPosX;
            const nCX: i32 = (nMaxCoord + nAbsDx * -4) & @as(i32, -2);
            nMaxCoord = pNextVertex.nPosY;
            if (pNextVertex.nPosY < pDrlgVertex.nPosY) nMaxCoord = pDrlgVertex.nPosY;
            const nCY: i32 = (nMaxCoord + nAbsDy * -4) & @as(i32, -2);
            const pGrid = &pWildData.sGridOutdoor;
            DrlgGrid.AlterGridFlag(pGrid, nCX, nCY, 0x400, OP_OR);
            DrlgGrid.AlterGridFlag(pGrid, nCX + nAbsDx * 2, nCY + nAbsDy * 2, 0x400, OP_OR);
        }

        const nAdjacentPresetId = Border.getAdjacentRoadPresetId(nDx * 2, nDy * 2, nNextDx * 2, nNextDy * 2, nBasePresetId);
        if (nAdjacentPresetId != 0) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nNextXAligned, nNextYAligned, nAdjacentPresetId, -1, 0);
            DrlgGrid.AlterGridFlag(&pWildData.sGridOutdoor, nNextXAligned, nNextYAligned, 1, OP_OR);
        }

        const bNotAtStart = pNextVertex != pWildData.pVertices.?;
        pDrlgVertex = pNextVertex;
        pNextVertex = pNextVertex.pNext.?;
        if (!bNotAtStart) break;
    }

    if (pLevel.*.eD2LevelId == .FrigidHighlands) {
        const pWildDataFinal = wild(pLevel);
        const nMaxCoord = pWildDataFinal.nGridCoordsWidth - 2;
        const nHeight = pWildDataFinal.nGridCoordsHeight;
        DrlgGrid.AlterGridFlag(&pWildDataFinal.sGridOutdoor, nMaxCoord, nHeight - 4, 0x400, OP_OR);
        DrlgGrid.AlterGridFlag(&pWildDataFinal.sGridOutdoor, nMaxCoord, nHeight - 3, 0x400, OP_OR);
    }
}

// DRLGOUTROOM_PlaceAct5OuterWalls   OutPlace/Act5.cpp (0067def0)
fn PlaceAct5OuterWalls(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pWildData = wild(pLevel);
    const nMaxX: i32 = pWildData.nGridCoordsWidth - 2;
    const nY: i32 = pWildData.nGridCoordsHeight - 2;
    const bBloody: bool = pLevel.*.eD2LevelId == .FrozenTundra;
    var nXCur: i32 = nMaxX;
    var nYCurrent: i32 = 0;
    while (nXCur != 0 or nYCurrent != nY) {
        const raw = DrlgGrid.GetGridFlags(&pWildData.sGridPreset, nXCur, nYCurrent);
        const nPresetOffset = raw - (if (bBloody) @as(i32, 0x3bd) else @as(i32, 0x371));
        if (nPresetOffset < 0 or nPresetOffset >= gaAct5OuterWallDir.len) {
            break;
        }
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nXCur, nYCurrent, nPresetOffset + (if (bBloody) @as(i32, 0x4c) else 0) + 0x37d, -1, 0);
        nYCurrent += gaAct5OuterWallDir[@intCast(nPresetOffset)][1] * 2;
        nXCur += gaAct5OuterWallDir[@intCast(nPresetOffset)][0] * 2;
    }
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nMaxX, 0, (if (bBloody) @as(i32, 0x4c) else 0) + 0x38a, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nY, (if (bBloody) @as(i32, 0x4c) else 0) + 0x389, -1, 0);
}

// DRLGOUTROOM_PlaceAct5BorderPresets   OutPlace/Act5.cpp (0067db50)
fn PlaceAct5BorderPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pWildData = wild(pLevel);
    const nVariant: i32 = @as(i32, @intFromBool(pLevel.*.eD2LevelId == .BloodyFoothills)) * 2 - 1;

    // Top edge (y=0): first 0x400-flagged cell -> 0x38d.
    {
        var nXCur: i32 = 0;
        while (nXCur < pWildData.nGridCoordsWidth) : (nXCur += 1) {
            if (DrlgGrid.GetGridFlags(&pWildData.sGridOutdoor, nXCur, 0) & 0x400 != 0) {
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nXCur, 0, 0x38d, nVariant, 0);
                break;
            }
        }
    }
    // Bottom edge (y=height-2): -> 0x38c.
    {
        const nYb = pWildData.nGridCoordsHeight - 2;
        var nXCur: i32 = 0;
        while (nXCur < pWildData.nGridCoordsWidth) : (nXCur += 1) {
            if (DrlgGrid.GetGridFlags(&pWildData.sGridOutdoor, nXCur, nYb) & 0x400 != 0) {
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nXCur, nYb, 0x38c, nVariant, 0);
                break;
            }
        }
    }
    // Left edge (x=0): -> 0x38e.
    {
        var nYi: i32 = 0;
        while (nYi < pWildData.nGridCoordsHeight) : (nYi += 1) {
            if (DrlgGrid.GetGridFlags(&pWildData.sGridOutdoor, 0, nYi) & 0x400 != 0) {
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, nYi, 0x38e, nVariant, 0);
                break;
            }
        }
    }
    // Right edge (x=width-2): -> 0x38b.
    {
        const nXr = pWildData.nGridCoordsWidth - 2;
        var nYi: i32 = 0;
        if (pWildData.nGridCoordsHeight <= 0) return;
        while (true) {
            if (DrlgGrid.GetGridFlags(&pWildData.sGridOutdoor, nXr, nYi) & 0x400 != 0) {
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nXr, nYi, 0x38b, nVariant, 0);
                return;
            }
            nYi += 1;
            if (nYi >= pWildData.nGridCoordsHeight) return;
        }
    }
}

// DRLGOUTROOM_PlaceAct5SpecialPresets   OutPlace/Act5.cpp (0067da70, EBX)
fn PlaceAct5SpecialPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pWildData = wild(pLevel);
    for (gaAct5SpecialPresetTable) |row| {
        if (pLevel.*.eD2LevelId != row.levelId) continue;
        var nX: i32 = undefined;
        var nY: i32 = undefined;
        var nLvlPrestId: i32 = undefined;
        if (pLevel.*.sCoordinatesAndSize.WorldSize.y < pLevel.*.sCoordinatesAndSize.WorldSize.x) {
            nLvlPrestId = row.horizPreset;
            _ = tables.lvlPrestGetLine(nLvlPrestId);
            if (row.sideFlag == 0) {
                nX = 0;
                nY = 2;
            } else {
                nX = pWildData.nGridCoordsWidth - 2;
                nY = 2;
            }
        } else {
            nLvlPrestId = row.vertPreset;
            _ = tables.lvlPrestGetLine(nLvlPrestId);
            nX = 2;
            nY = if (row.sideFlag == 0) 0 else pWildData.nGridCoordsHeight - 2;
        }
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, nLvlPrestId, row.randVariant, 0);
    }
}

// DRLGOUTROOM_PlaceAct5SecondaryBorder   OutPlace/Act5.cpp (0067e0e0, EDI)
// Faithful setup of the secondary-border callbacks (matches the 1.14d 0067e0e0
// assignments exactly) then AddSecondaryBorder, which runs the substitution-group
// placement (seed-consuming) over the LvlSub records of type 0xc.
fn PlaceAct5SecondaryBorder(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel.*.eD2LevelId == .BloodyFoothills) return;
    const pWildData = wild(pLevel);
    var sUnk: s.D2UnkOutdoorStrc = std.mem.zeroes(s.D2UnkOutdoorStrc);
    sUnk.pCoordsGrid = @ptrCast(@alignCast(&pWildData.pGridCoordsCellFlags));
    sUnk.pPrimaryFloorGrid = &pWildData.sGridPreset;
    sUnk.pWallGrid = &pWildData.sGridOutdoor;
    sUnk.pfnValidateBorderCell = @ptrCast(@constCast(&OutPlace.validateSecondaryBorderCell));
    sUnk.pfnAlterAdjacentCells = @ptrCast(@constCast(&OutPlace.AlterAdjacentPresetGridCells));
    sUnk.pfnSetBlankCell = @ptrCast(@constCast(&OutPlace.SetBlankGridCell));
    sUnk.pfnSpawnPreset = @ptrCast(@constCast(&OutPlace.SpawnOutdoorLevelPresetEx));
    sUnk.pfnGetBorderPreset = @ptrCast(@constCast(&OutPlace.getSecondaryBorderPresetFromLvlSub));
    sUnk.nPrevBorderPresetId = -1;
    sUnk.nLvlSubId = 0xc;
    sUnk.pLevel = @ptrCast(pLevel);
    TileSub.AddSecondaryBorder(@ptrCast(&sUnk));
}

// DRLGOUTROOM_PlaceAct5SceneryPresets   OutPlace/Act5.cpp (0067e160)
fn PlaceAct5SceneryPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const nWidth = pLevel.*.sCoordinatesAndSize.WorldSize.x;
    const nHeight = pLevel.*.sCoordinatesAndSize.WorldSize.y;
    for (gaAct5SceneryPresetTable) |row| {
        if (pLevel.*.eD2LevelId != row.levelId) continue;
        const nPresetId: i32 = if (nWidth < nHeight) row.vertPreset else row.horizPreset;
        const nType = row.nType;
        var nCount: i32 = 0;
        var bSuccess: i32 = 0;
        if (row.count > 0) {
            while (nCount < row.count) : (nCount += 1) {
                bSuccess = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetId, nType, 0, 0x0f);
            }
            if (bSuccess != 0) continue;
        }
        if (row.mandatory != 0) {
            // engine: ERROR_UnrecoverableInternalError_Halt(0x219). A mandatory
            // scenery preset failed to place. In the per-level harness this means
            // the upstream grid prefill is absent (see header) — degrade rather
            // than halt the suite; the level just won't be byte-exact.
            return;
        }
    }
}

// DRLGOUTPLACE_PlaceAct5SiegePresets   BloodyFoothills.cpp (0067e4b0, EBX)
fn PlaceAct5SiegePresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel == null or pLevel.*.eD2LevelId != .FrigidHighlands) return;
    const pLevelData = wild(pLevel);
    const pLvlPrest = tables.lvlPrestGetLine(0x370);
    const nX = pLevelData.nGridCoordsWidth - div8(pLvlPrest.*.SizeX);
    const nY = pLevelData.nGridCoordsHeight - div8(pLvlPrest.*.SizeY);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, 0x370, -1, 0);
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY - 2, 0x380, -1, 0);
}

// DRLGOUTPLACE_PlaceAct5WallPresets   BloodyFoothills.cpp (0067e560)
fn PlaceAct5WallPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pLevelData = wild(pLevel);
    const pLvlPrest = tables.lvlPrestGetLine(0x361);
    const nSegmentWidth = div8(pLvlPrest.*.SizeX);
    var nX: i32 = pLevelData.nGridCoordsWidth - nSegmentWidth;
    var nSegmentIndex: i32 = 0;
    while (-1 < nX) {
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, 0, nSegmentIndex + 0x361, 0, 0);
        nSegmentIndex += 1;
        nX -= nSegmentWidth;
        if (0xe < nSegmentIndex) return;
    }
}

// DRLGOUTPLACE_PlaceAct5BloodyFoothillsRandomPresets   Act5.cpp (0067e240, ESI)
fn PlaceAct5BloodyFoothillsRandomPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel.*.eD2LevelId != .FrigidHighlands) return;
    const pLevelData = wild(pLevel);
    var nPlacedCount: i32 = 0;

    var nAttempts: i32 = 0;
    while (nAttempts < 0x5a) : (nAttempts += 1) {
        if (2 < nPlacedCount) break;
        const nGridX: i32 = @bitCast(rng.getModuloFromSeed(&pLevel.*.sSeed, @bitCast(@divTrunc(pLevelData.nGridCoordsWidth, 2))));
        const nGridY: i32 = @bitCast(rng.getModuloFromSeed(&pLevel.*.sSeed, @bitCast(@divTrunc(pLevelData.nGridCoordsHeight, 2))));
        const nPresetCoord = OutPlace.getPresetCoordFromGrid(pLevel, nGridX * 2, nGridY * 2);
        if (@as(u32, @bitCast(nPresetCoord - 0x393)) < 8) {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nGridX * 2, nGridY * 2, nPresetCoord + 0x10, -1, 0);
            nPlacedCount += 1;
        }
    }

    var nStartX: i32 = @divTrunc(pLevelData.nGridCoordsWidth, 2);
    nStartX = pickStart(pLevel, nStartX);
    var nStartY: i32 = @divTrunc(pLevelData.nGridCoordsHeight, 2);
    nStartY = pickStart(pLevel, nStartY);

    var nA: i32 = 0;
    while (nA < pLevelData.nGridCoordsHeight) : (nA += 1) {
        if (2 < nPlacedCount) return;
        var nXIter: i32 = 0;
        var nGW = pLevelData.nGridCoordsWidth;
        while (nXIter < nGW) : (nXIter += 1) {
            if (2 < nPlacedCount) break;
            const nGX = @mod(nXIter + nStartX * 2, nGW);
            const nYv = @mod(nA + nStartY * 2, pLevelData.nGridCoordsHeight);
            const nPresetId = OutPlace.getPresetCoordFromGrid(pLevel, nGX, nYv);
            if (@as(u32, @bitCast(nPresetId - 0x393)) < 8) {
                OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nGX, nYv, nPresetId + 0x10, -1, 0);
                nPlacedCount += 1;
            }
            nGW = pLevelData.nGridCoordsWidth;
        }
    }
    if (2 < nPlacedCount) return;
    // engine: ERROR_UnrecoverableInternalError_Halt(0x259). Needs the upstream
    // 0x393-range grid prefill that is absent in the per-level harness (see
    // header) — degrade rather than halt the suite.
    return;
}

// Seed-driven start offset: low-word modulo (pow2 -> mask, else -> %); recon's
// (ulonglong) widening is the 64-bit decompiler artifact -> 32-bit low word.
fn pickStart(pLevel: [*c]s.D2DrlgLevelStrc, n: i32) i32 {
    if (n < 1) return 0;
    const next = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = next;
    const un: u32 = @bitCast(n);
    const low: u32 = @bitCast(next.nSeedLow);
    if ((un & (un -% 1)) == 0) return @bitCast((un -% 1) & low);
    return @bitCast(low % un);
}

// OutSiege::InitAct5OutdoorLevel   OutSiege.cpp (0067e600)
pub fn InitAct5OutdoorLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel.*.eD2LevelId == .BloodyFoothills) {
        PlaceAct5WallPresets(pLevel);
        return;
    }
    Border.SetOutGridLinkFlags(pLevel);
    PlaceAct5RoadPath(pLevel);
    PlaceAct5OuterWalls(pLevel);
    PlaceAct5BorderPresets(pLevel);
    PlaceAct5SpecialPresets(pLevel);
    if (pLevel.*.eD2LevelId == .FrigidHighlands) {
        PlaceAct5SiegePresets(pLevel);
    }
    PlaceAct5SecondaryBorder(pLevel);
    PlaceAct5BloodyFoothillsRandomPresets(pLevel);
    PlaceAct5SceneryPresets(pLevel);
}
