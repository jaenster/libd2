//! Mechanical transform of the wilderness (type-3) generator from
//! recon/closure/Outdoors.cpp (+ OutPlace.cpp DRLGOUTROOM_CreateOutdoorRoomEx,
//! Drlg.cpp DRLGROOMEX_RollLevelSubstitutionMask / GetActNoFromLevelNumber).
//! Faithful by construction: field access by NAME (the recon's RAW byte-offset
//! grid reaches +4/+0x18/+0x2c/+0x40 are rewritten to the named D2DrlgLevelData-
//! WildernessLevel fields — the 32-bit offsets do not survive 64-bit pointers),
//! RNG -> rng.zig (low-word modulo), allocs -> pool.zig, tables -> tables.zig,
//! the preset cells -> the verified preset.zig pipeline.
//!
//! Transformed here:
//!   DRLGLEVEL_InitializeWithWildernessLevel       Outdoors.cpp:1371
//!   DRLGOUTDOOR_GenerateLevel                     Outdoors.cpp:1379
//!   DRLGOUTDOOR_SimplifyOutdoorPoints             Outdoors.cpp:1245
//!   DRLGOUTDOOR_CreateOutdoorRoomExGrid           Outdoors.cpp:1273
//!   DRLGOUTROOM_CreateOutdoorRoomEx               OutPlace.cpp:1562
//!   DRLGROOMEX_RollLevelSubstitutionMask          Drlg.cpp:2422
//!   GetActNoFromLevelNumber                       Drlg.cpp (GetActNoFromLevelNumber)
//!
//! Per-act border/preset placement (the OutPlace/OutDesr/OutJung act-init tree)
//! is IMPLEMENTED and dispatched below via InitAct1..5 (ActInit/OutDesr/OutJung/
//! Act5); these arms run for the golden wilderness levels and are byte-exact
//! (wild 31/31). InitAct*OutdoorLevel:
//!   InitAct1OutdoorLevel / InitAct2OutdoorLevel / InitAct3OutdoorLevel /
//!   InitAct4OutdoorLevel / InitAct5OutdoorLevel

const std = @import("std");
const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const pool = @import("../pool.zig");
const tables = @import("../tables.zig");
const DrlgGrid = @import("../DrlgGrid.zig");
const DrlgVer = @import("../DrlgVer.zig");
const DrlgRoom = @import("../DrlgRoom.zig");
const TileSub = @import("../TileSub.zig");
const preset = @import("../preset.zig");
pub const OutPlace = @import("OutPlace.zig");
pub const ActInit = @import("ActInit.zig");
pub const Border = @import("Border.zig");
pub const OutJung = @import("OutJung.zig");
pub const Act5 = @import("Act5.zig");

// Force semantic analysis of the placement core even before every act is wired.
comptime {
    std.testing.refAllDecls(OutPlace);
}

const W = s.D2DrlgLevelDataWildernessLevel;

const ACT_I: i32 = 0;
const ACT_II: i32 = 1;
const ACT_III: i32 = 2;
const ACT_IV: i32 = 3;
const ACT_V: i32 = 4;

// GetActNoFromLevelNumber   Drlg.cpp (defined in Border.zig)
pub const GetActNoFromLevelNumber = Border.GetActNoFromLevelNumber;

// DRLGROOMEX_RollLevelSubstitutionMask   Drlg.cpp:2422 (006406..)
// 64-bit artifact: recon line 2435 takes `% 100` on the FULL (uint64_t)sNewSeed;
// the engine modulos the 32-bit LOW word (same widening class as the maze rolls).
pub fn rollLevelSubstitutionMask(pRoomEx: [*c]s.D2RoomExStrc, nSubType: i32, nSubTheme: i32) u32 {
    if (!(nSubType != -1 and nSubTheme != -1)) return 0;
    var pLine = tables.lvlSubGetLineFromSubType(nSubType);
    var nCurrentType = pLine.*.Type;
    var dwSubMask: u32 = 0;
    var nSubIndex: u5 = 0;
    while (nCurrentType == nSubType) {
        const sNewSeed = rng.sEEDNEXT(pRoomEx.*.sSeed);
        pRoomEx.*.sSeed = sNewSeed;
        const lowMod: i32 = @bitCast(@as(u32, @bitCast(sNewSeed.nSeedLow)) % 100);
        const probRow: [5]i32 = pLine.*.Prob;
        const prob: i32 = probRow[@as(usize, @intCast(nSubTheme))];
        if (lowMod < prob) {
            dwSubMask |= @as(u32, 1) << nSubIndex;
            pRoomEx.*.nDT1Mask |= pLine.*.Dt1Mask;
        }
        nSubIndex +%= 1;
        pLine += 1;
        nCurrentType = pLine.*.Type;
    }
    return dwSubMask;
}

// DRLGOUTROOM_CreateOutdoorRoomEx   OutPlace.cpp:1562 (0067eef0)
pub fn createOutdoorRoomEx(
    pLevel: [*c]s.D2DrlgLevelStrc,
    nX: i32,
    nY: i32,
    nWidth: i32,
    nHeight: i32,
    dwRoomFlags: i32,
    dwOutdoorFlags: i32,
    dwOutdoorFlagsEx: i32,
    dwDT1Mask: i32,
) [*c]s.D2RoomExStrc {
    const pRoomEx = DrlgRoom.allocRoomEx(pLevel, 1);
    pRoomEx.*.sCoords.WorldSize.x = nWidth;
    pRoomEx.*.sCoords.WorldSize.y = nHeight;
    pRoomEx.*.sCoords.WorldPosition.x = nX;
    pRoomEx.*.sCoords.WorldPosition.y = nY;
    _ = DrlgRoom.AddRoomExToLevel(pLevel, pRoomEx);
    const pOut: *s.D2DrlgRoomExDataMazeStrc = @ptrCast(@alignCast(pRoomEx.*.pRoomExData));
    pRoomEx.*.eRoomExFlags.orRaw(dwRoomFlags);
    pRoomEx.*.eRoomExFlags.noLos = true;
    pRoomEx.*.nDT1Mask = dwDT1Mask;
    pOut.dwFlags = dwOutdoorFlags;
    pOut.dwFlagsEx = dwOutdoorFlagsEx;
    const pTxt = tables.levelDefsGetLine(pLevel.*.eD2LevelId);
    pOut.nSubType = pTxt.*.SubType;
    pOut.nSubTheme = pTxt.*.SubTheme;
    pOut.nSubThemePicked = @bitCast(rollLevelSubstitutionMask(pRoomEx, pTxt.*.SubType, pTxt.*.SubTheme));
    return pRoomEx;
}

// DRLGLEVEL_InitializeWithWildernessLevel   Outdoors.cpp:1371 (00642ae0 arm)
pub fn initializeWithWildernessLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData: *W = @ptrCast(@alignCast(pool.AllocServerMemory(
        pLevel.*.pDrlg.?.pMemoryPool,
        @sizeOf(W),
        ".\\DRLG\\Outdoors.cpp",
        0x34c,
    )));
    @memset(@as([*]u8, @ptrCast(pData))[0..@sizeOf(W)], 0);
    pLevel.*.pDrlgLevelData = pData;
}

// DRLGOUTDOOR_SimplifyOutdoorPoints   Outdoors.cpp:1245 (00674f30)
// Vertex coords /= 8, then collapse consecutive duplicate vertices (OR flags,
// copy direction). Named-field transform of the int*-indexed recon (pPoint[4]=
// pNext, [3]=dwFlags, char[8]=nDirection). Unused by the plain-grid path.
fn floorDiv8(v: i32) i32 {
    return (v + (@as(i32, @intCast(@as(u1, @truncate(@as(u32, @bitCast(v)) >> 31)))) * 7)) >> 3;
}
pub fn simplifyOutdoorPoints(pMemory: ?*s.D2PoolManagerStrc, ppHead: *?*s.D2DrlgVertexStrc) void {
    var p = ppHead.*;
    while (true) {
        p.?.nPosX = floorDiv8(p.?.nPosX);
        p.?.nPosY = floorDiv8(p.?.nPosY);
        p = p.?.pNext;
        if (p == ppHead.*) break;
    }
    p = ppHead.*;
    while (true) {
        const pNext = p.?.pNext;
        if (p.?.nPosX == pNext.?.nPosX and p.?.nPosY == pNext.?.nPosY) {
            if (pNext == ppHead.*) ppHead.* = p;
            p.?.pNext = pNext.?.pNext;
            p.?.dwFlags |= pNext.?.dwFlags;
            p.?.nDirection = pNext.?.nDirection;
            pool.FreeServerMemory(pMemory, pNext, ".\\DRLG\\Outdoors.cpp", 0x2cb, 0);
        }
        p = p.?.pNext;
        if (p == ppHead.*) break;
    }
}

// DRLGOUTDOOR_CreateOutdoorRoomExGrid   Outdoors.cpp:1273 (006750f0)
pub fn createOutdoorRoomExGrid(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData: *W = @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
    var outdoorRoomStyle: i32 = 0;
    switch (@intFromEnum(pLevel.*.nLevelType)) {
        2 => outdoorRoomStyle = 0x44103,
        0x10, 0x16, 0x1b, 0x1c => outdoorRoomStyle = 1,
        0x15 => outdoorRoomStyle = 4,
        0x1e, 0x1f => outdoorRoomStyle = 0x11,
        else => {},
    }

    var worldY = pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    if (pData.nGridCoordsHeight <= 0) return;
    var gridY: i32 = 0;
    while (gridY < pData.nGridCoordsHeight) : (gridY += 1) {
        var worldX = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
        var nGridX: i32 = 0;
        while (nGridX < pData.nGridCoordsWidth) : (nGridX += 1) {
            const floorFlags = DrlgGrid.GetGridFlags(&pData.sGridLink, nGridX, gridY);
            const dwOutdoorFlags = DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nGridX, gridY);
            if ((dwOutdoorFlags & 0x200) == 0) {
                if ((dwOutdoorFlags & 0x100) == 0) {
                    const tileTypeFlags = DrlgGrid.GetGridFlags(&pData.sGridMisc, nGridX, gridY);
                    _ = createOutdoorRoomEx(pLevel, worldX, worldY, 8, 8, floorFlags, dwOutdoorFlags, tileTypeFlags, outdoorRoomStyle);
                }
            } else {
                const tileTypeFlags = DrlgGrid.GetGridFlags(&pData.sGridPreset, nGridX, gridY);
                if (tileTypeFlags != 0) {
                    var mapCoords: s.D2DrlgCoordStrc = .{ .nPosX = worldX, .nPosY = worldY, .nWidth = 0, .nHeight = 0 };
                    const pDrlgMap = preset.allocDrlgMap(pLevel, tileTypeFlags, &mapCoords, &pLevel.*.sSeed);
                    pDrlgMap.*.nRandomMapFileSelector = (dwOutdoorFlags >> 0x10) & 0xf;
                    _ = preset.BuildArea(pLevel, pDrlgMap, floorFlags, 0);
                }
            }
            worldX += 8;
        }
        worldY += 8;
    }
}

// DRLGOUTDOOR_GenerateLevel   Outdoors.cpp:1379 (00675360)
// Builds the four placement grids + the boundary vertex ring, then dispatches the
// per-act border/preset placement (STUBBED), then converts the grids to RoomEx.
pub fn generateLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pMemory = pLevel.*.pDrlg.?.pMemoryPool;
    const pData: *W = @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
    pData.pGridCoordsCellFlags = null;
    pData.pGridCoordsRowOffsets = null;
    const wx = pLevel.*.sCoordinatesAndSize.WorldSize.x;
    pData.nGridCoordsWidth = floorDiv8(wx);
    const wy = pLevel.*.sCoordinatesAndSize.WorldSize.y;
    const nWidth = pData.nGridCoordsWidth;
    const nHeight = floorDiv8(wy);
    pData.nGridCoordsHeight = nHeight;
    DrlgGrid.initGridCells(pMemory, &pData.sGridPreset, nWidth, nHeight);
    DrlgGrid.initGridCells(pMemory, &pData.sGridLink, nWidth, nHeight);
    DrlgGrid.initGridCells(pMemory, &pData.sGridOutdoor, nWidth, nHeight);
    DrlgGrid.initGridCells(pMemory, &pData.sGridMisc, nWidth, nHeight);
    DrlgVer.createRoomVertices(pMemory, @ptrCast(&pData.pVertices), @ptrCast(&pLevel.*.sCoordinatesAndSize), 0, pData.pOrthData);
    simplifyOutdoorPoints(pMemory, &pData.pVertices);

    var eActNo: i32 = ACT_II;
    if (pLevel.*.eD2LevelId != .ForgottenSands) {
        eActNo = GetActNoFromLevelNumber(pLevel.*.eD2LevelId);
    }
    switch (eActNo) {
        // Per-act border/preset placement (Outdoors.cpp:1402 switch).
        ACT_I => ActInit.InitAct1OutdoorLevel(pLevel),
        ACT_II => ActInit.InitAct2OutdoorLevel(pLevel),
        ACT_III => OutJung.InitAct3OutdoorLevel(pLevel),
        ACT_IV => ActInit.InitAct4OutdoorLevel(pLevel),
        ACT_V => Act5.InitAct5OutdoorLevel(pLevel),
        else => {},
    }
    createOutdoorRoomExGrid(pLevel);
}

// AddAct124SecondaryBorder   Outdoors.cpp:1350 (1.14d 00675290 area)
// Sets up the substitution-placement context (D2UnkOutdoorStrc) for an Act-1/2/4
// secondary border and runs the (already-live) substitution placement via
// TileSub.AddSecondaryBorder. Grids map to the named wilderness fields:
// pCoordsGrid = pLevelData+0x54 (pGridCoordsCellFlags), pPrimaryFloorGrid =
// pLevelData+0x04 (sGridPreset), pWallGrid = pLevelData+0x2c (sGridOutdoor). The
// non-callback Validate path (pfnIsPresetFree/pfnTestPreset, no ValidateBorderCell
// or GetBorderPreset) is the Act-1/2/4 variant — OutSub.ValidateSubTilePlacement
// supports it. Consumes seed inside the substitution shuffle.
pub fn AddAct124SecondaryBorder(pLevel: [*c]s.D2DrlgLevelStrc, nLvlSubId: i32, nLevelPrestId: i32) void {
    const pData: *W = @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
    var sUnk: s.D2UnkOutdoorStrc = std.mem.zeroes(s.D2UnkOutdoorStrc);
    sUnk.pCoordsGrid = @ptrCast(@alignCast(&pData.pGridCoordsCellFlags));
    sUnk.pPrimaryFloorGrid = &pData.sGridPreset;
    sUnk.pWallGrid = &pData.sGridOutdoor;
    sUnk.nLevelPrestId = nLevelPrestId;
    sUnk.nPrevBorderPresetId = -1;
    sUnk.pfnIsPresetFree = @ptrCast(@constCast(&OutPlace.isGridCellPresetFree));
    sUnk.pfnTestPreset = @ptrCast(@constCast(&OutPlace.TestOutdoorLevelPreset));
    sUnk.pfnAlterAdjacentCells = @ptrCast(@constCast(&OutPlace.AlterAdjacentPresetGridCells));
    sUnk.pfnSetBlankCell = @ptrCast(@constCast(&OutPlace.SetBlankGridCell));
    sUnk.pfnSpawnPreset = @ptrCast(@constCast(&OutPlace.SpawnOutdoorLevelPresetEx));
    sUnk.pLevel = @ptrCast(pLevel);
    sUnk.nLvlSubId = nLvlSubId;
    TileSub.AddSecondaryBorder(@ptrCast(&sUnk));
}

// AddAct124SecondaryBorderSubId213   Outdoors.cpp:1546 (1.14d 0067f630)
// Act-2 secondary borders: LvlSub ids 2,1,3 against the shared 0x16c preset.
pub fn AddAct124SecondaryBorderSubId213(pLevel: [*c]s.D2DrlgLevelStrc) void {
    AddAct124SecondaryBorder(pLevel, 2, 0x16c);
    AddAct124SecondaryBorder(pLevel, 1, 0x16c);
    AddAct124SecondaryBorder(pLevel, 3, 0x16c);
}

// SpawnAct12Shrines   Outdoors.cpp:1128 (1.14d 00674e40)
// Rolls a shrine style, builds the interior-cell list, Fisher-Yates-shuffles it
// (two RNG draws per step, both via RANDOM_RandomNumberSelector), then walks the
// shuffled cells placing up to nShrines shrines on cells clear of the 0x1b81 mask.
// gaShrineStyleFlags[styleIdx] OR'd into sGridLink; 0x1000 OR'd into sGridOutdoor.
pub fn SpawnAct12Shrines(pLevel: [*c]s.D2DrlgLevelStrc, nShrines: i32) void {
    const pData: *W = @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
    var nShrinesLeft = nShrines;
    const nSeedRoll = rng.RollRandomSeed(&pLevel.*.sSeed);
    const nGridWidth = pData.nGridCoordsWidth - 2;
    const nTotalCells: i32 = (pData.nGridCoordsHeight - 2) * nGridWidth;
    var nShrineStyleIdx: u32 = @as(u32, @bitCast(nSeedRoll)) & 3;
    if (nTotalCells == 0) return;

    var aCellX: [513]i32 = undefined;
    var aCellY: [513]i32 = undefined;
    {
        var i: i32 = 0;
        while (i < nTotalCells) : (i += 1) {
            aCellX[@intCast(i)] = @rem(i, nGridWidth);
            aCellY[@intCast(i)] = @divTrunc(i, nGridWidth);
        }
    }
    var nShuffleCount: i32 = nTotalCells;
    while (nShuffleCount > 0) : (nShuffleCount -= 1) {
        const a: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        const b: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        const tx = aCellX[a];
        const ty = aCellY[a];
        aCellX[a] = aCellX[b];
        aCellY[a] = aCellY[b];
        aCellX[b] = tx;
        aCellY[b] = ty;
    }

    var nShuffleIdx: i32 = 0;
    while (nShuffleIdx < nTotalCells) : (nShuffleIdx += 1) {
        if (nShrinesLeft < 1) return;
        const nGridY = aCellY[@intCast(nShuffleIdx)] + 1;
        const nGridX = aCellX[@intCast(nShuffleIdx)] + 1;
        const flags = DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nGridX, nGridY);
        if (flags & 0x1b81 == 0) {
            DrlgGrid.AlterGridFlag(&pData.sGridLink, nGridX, nGridY, gaShrineStyleFlags[nShrineStyleIdx], 0);
            DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, nGridX, nGridY, 0x1000, 0);
            // recon: (idx+1) & 0x80000003 with sign-fixup == signed (idx+1) % 4.
            nShrineStyleIdx = (nShrineStyleIdx + 1) & 3;
            nShrinesLeft -= 1;
        }
    }
}

// SpawnAct12Waypoint   Outdoors.cpp:959 (1.14d 006752a0)
// Cold Plains (level 3) places the waypoint on the first cell facing the Act-1
// town vis-direction; every other Act-1/2 level Fisher-Yates-shuffles the interior
// cells (two RNG draws per step) and places at the first cell clear of 0x1b81.
pub fn SpawnAct12Waypoint(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData: *W = @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
    if (pLevel.*.eD2LevelId == .ColdPlains) {
        const pVisArray = DrlgRoom.getVisArrayFromLevelId(pLevel.*.pDrlg, .ColdPlains);
        var nVisIdx: i32 = 0;
        while (nVisIdx < 8) : (nVisIdx += 1) {
            if (pVisArray[@intCast(nVisIdx)] == .BloodMoor) break;
        }
        const dwWaypointDirMask: u32 = @as(u32, 1) << @intCast(@as(u32, @bitCast(nVisIdx + 4)) & 0x1f);
        const nGridWidth = pData.nGridCoordsWidth;
        const nGridHeight = pData.nGridCoordsHeight;
        var nGridY: i32 = 0;
        while (nGridY < nGridHeight) : (nGridY += 1) {
            var nGridX: i32 = 0;
            while (nGridX < nGridWidth) : (nGridX += 1) {
                const dwLink: u32 = @bitCast(DrlgGrid.GetGridFlags(&pData.sGridLink, nGridX, nGridY));
                const dwOut: u32 = @bitCast(DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nGridX, nGridY));
                if ((dwLink & dwWaypointDirMask) != 0 and (dwOut & 0x400) != 0) {
                    var wx = nGridX;
                    var wy = nGridY;
                    if (wx == 0) wx = 1;
                    if (wy == 0) wy = 1;
                    if (wx == nGridWidth - 1) wx -= 1;
                    if (wy == nGridHeight - 1) wy -= 1;
                    DrlgGrid.AlterGridFlag(&pData.sGridLink, wx, wy, 0x20000, 0);
                    DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, wx, wy, 0x800, 0);
                    return;
                }
            }
        }
    }

    const nGridWidth = pData.nGridCoordsWidth - 2;
    const nTotalCells: i32 = (pData.nGridCoordsHeight - 2) * nGridWidth;
    if (nTotalCells == 0) return;

    var aCellX: [513]i32 = undefined;
    var aCellY: [513]i32 = undefined;
    {
        var i: i32 = 0;
        while (i < nTotalCells) : (i += 1) {
            aCellX[@intCast(i)] = @rem(i, nGridWidth);
            aCellY[@intCast(i)] = @divTrunc(i, nGridWidth);
        }
    }
    var nShuffleCount: i32 = nTotalCells;
    while (nShuffleCount > 0) : (nShuffleCount -= 1) {
        const a: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        const b: usize = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nTotalCells));
        const tx = aCellX[a];
        const ty = aCellY[a];
        aCellX[a] = aCellX[b];
        aCellY[a] = aCellY[b];
        aCellX[b] = tx;
        aCellY[b] = ty;
    }

    var nIdx: i32 = 0;
    while (nIdx < nTotalCells) : (nIdx += 1) {
        const nGridY = aCellY[@intCast(nIdx)] + 1;
        const nGridX = aCellX[@intCast(nIdx)] + 1;
        const flags: u32 = @bitCast(DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nGridX, nGridY));
        if ((flags & 0x1b81) == 0) {
            DrlgGrid.AlterGridFlag(&pData.sGridLink, nGridX, nGridY, 0x10000, 0);
            DrlgGrid.AlterGridFlag(&pData.sGridOutdoor, nGridX, nGridY, 0x800, 0);
            return;
        }
    }
}

// gaShrineStyleFlags — gnOutdoorsGridWidthByLevel .rdata @0x006f061c (4 int32,
// recovered from Ghidra 1.14d, accessed `[ECX*4+0x6f061c]` @0x0067500c). The four
// shrine-style grid flags OR'd into sGridLink as the style cycles 0->1->2->3.
const gaShrineStyleFlags = [4]i32{ 0x1000, 0x2000, 0x4000, 0x8000 };
