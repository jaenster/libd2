//! Faithful transform of the Act-1 outdoor room/exit/corner machinery from
//! recon/closure/Drlg.cpp and recon/closure/OutWild.cpp.
//!
//! Transformed here:
//!   DRLGOUTROOM_IsGridColumnEmpty          Drlg.cpp:6007  (1.14d 0067fc70)
//!   DRLGOUTROOM_SpawnVerticalBorderPresets Drlg.cpp:6117  (1.14d 0067fe90)
//!   DRLGOUTROOM_PlaceRiverCrossingPreset   Drlg.cpp:6053  (1.14d 0067fd20)
//!   DRLGOUTROOM_SpawnCornerFillPreset      Drlg.cpp:6219  (1.14d 006801a0)
//!   DRLGOUTROOM_FillBorderCornersAndPresets Drlg.cpp:6239 (1.14d 00680200)
//!   SpawnTownTransitionsAndCaves           OutWild.cpp:41 (1.14d 006803d0)
//!   DRLGOUTROOM_SpawnRandomOutdoorDecorations Drlg.cpp:6346 (1.14d 006804e0)
//!   SpawnRandomOutdoorDS1                  Outdoors.cpp:833 (1.14d 006745e0)
//!   DRLGOUTROOM_SpawnAct1LevelPresets      Drlg.cpp:6371  (1.14d 00680580)
//!   DRLGOUTROOM_BuildExitPointArray        Drlg.cpp:6614  (1.14d 00680d70)
//!   DRLGOUTROOM_BuildVertexPathsWithJitter Drlg.cpp:6873  (1.14d 00681240)
//!   DRLGOUTROOM_LinkOutdoorRoomExits       Drlg.cpp:6942  (1.14d 00681420)
//!
//! FindPathBetweenExits (the A* pathfinder, Drlg.cpp:7184) is not yet ported.
//! For levels 3-7 (nExitCount==0) this is correct: the exit loop never runs,
//! 0 seeds are consumed. Level 2 (nExitCount==1) loses exactly 39 seed draws:
//! BuildVertexPathsWithJitter draws 1+2×19=39 for the A* path; room seeds will
//! be off for level 2 until A* lands.
//!
//! Road/transition dwFlags bits (0x4/0x8/0x10/0x80/0x100/0x200/0x400) are set
//! by DRLG_ApplyAct1WildRoadFlags (drlg.zig) from the binary table @0x6f1258.

const std = @import("std");
const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const DrlgGrid = @import("../DrlgGrid.zig");
const DrlgVer = @import("../DrlgVer.zig");
const pool = @import("../pool.zig");
const tables = @import("../tables.zig");
const OutPlace = @import("OutPlace.zig");
const drlg = @import("../drlg.zig");

const W = s.D2DrlgLevelDataWildernessLevel;

inline fn wild(pLevel: [*c]s.D2DrlgLevelStrc) *W {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
}

// Variant lookup tables for SpawnVerticalBorderPresets
// Interleaved pairs [left_variant, right_variant] indexed by sGridPreset value.
// Binary-verified 1.14d: the 16-entry pair table @ 0x6f2680..0x6f2700 (the labels
// gnDrlgLevelActId/gaPresetVariantLookup are the interleaved left/right columns,
// read as base[nVariant*2] / base[nVariant*2+1] with NO index clamp — the engine
// indexes the full table directly). Layout: [nVariant][0]=left(0x1a preset),
// [nVariant][1]=right(0x1b preset). Entry 0 is never read (nVariant==0 uses the
// special formula below); kept at its binary values for fidelity.
const gaVerticalBorderVariants = [16][2]i32{
    .{ 385, 2 }, // 0:  unused (special-cased)
    .{ 0, 6 },   // 1
    .{ 386, 0 }, // 2:  386 = 0x182
    .{ 0, 8 },   // 3
    .{ 2, 2 },   // 4
    .{ 0, 3 },   // 5
    .{ 1, 1 },   // 6
    .{ 3, 0 },   // 7
    .{ 0, 2 },   // 8
    .{ 0, 1 },   // 9
    .{ 1, 0 },   // 10
    .{ 2, 0 },   // 11
    .{ 2, 3 },   // 12 (0xc): river preset → right=3 (keeps 0x30000 flow)
    .{ 1, 3 },   // 13 (0xd): river preset → right=3
    .{ 3, 1 },   // 14
    .{ 3, 2 },   // 15
};

// gaOutdoorsGridWidthByLevel_0 (X offsets) @ 0x6f0614 and
// gaOutdoorsGridWidthByLevel_2 (Y offsets) @ 0x6f060c — signed i8.
    const gaOutdoorsGridOffsetX = [8]i8{ -1, 0, 0, 1, -1, 1, 1, -1 };
const gaOutdoorsGridOffsetY = [8]i8{ 0, -1, 1, 0, -1, 1, -1, 1 };

// Road A* pathfinder tables (binary-verified 1.14d)
// gaOutRoomPathDirectionDelta @ 0x6f2840 (24 signed bytes). First 16 = four
// 4-entry direction-cycle groups; [0x10..0x14] = Y step deltas; [0x14..0x18] =
// X step deltas (cardinal moves indexed by the node's direction byte 0..3).
const gaOutRoomPathDirectionDelta = [24]i8{
    0, 1, 2,  3, // group 0
    0, 1, 1,  1, // group 1
    3, 2, 1,  2, // group 2
    0, 3, 2,  1, // group 3
    0, 1, 0, -1, // Y deltas (offset 0x10)
    1, 0, -1, 0, // X deltas (offset 0x14)
};

// gPathDirectionTable @ 0x6f1518 (75 int32, 3 per 5x5-grid index). Only the
// first element of each triple is read by DRLGPATH_GetPathDirection, so this
// holds the pre-extracted [idx*3] value for index 0..24.
const gaPathDirectionPrimary = [25]i32{
    5, 4, 4, 4, 3, 6, 5, 4, 3, 2, 6, 6, 6, 2, 2, 6, 7, 0, 1, 2, 7, 0, 0, 0, 1,
};

// gaSpiralOffsetY @ 0x6f2800, gaSpiralOffsetX @ 0x6f2810 — center-cell search.
const gaSpiralOffsetY = [4]i32{ 0, 1, -1, 0 };
const gaSpiralOffsetX = [4]i32{ -1, 0, 0, 1 };

// DRLGOUTROOM_IsGridColumnEmpty   Drlg.cpp:6007 (1.14d 0067fc70)
// Returns true if no cell in column nX or nX+1 has sGridOutdoor bit 1 set.
pub fn isGridColumnEmpty(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32) bool {
    const pData = wild(pLevel);
    var nY: i32 = 0;
    while (nY < pData.nGridCoordsHeight) : (nY += 1) {
        if (DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nX, nY) & 2 != 0) return false;
        if (DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nX + 1, nY) & 2 != 0) return false;
    }
    return true;
}

// DRLGOUTROOM_PlaceRiverCrossingPreset   Drlg.cpp:6053 (1.14d 0067fd20)
// Tries to place a river crossing preset (0x1c) at a valid pair of cells that
// both have sGridOutdoor bits 0x30000 set (river flow markers). Draws 1 seed to
// select a random start row.
// nColumn is the mid-split column passed by the caller (SpawnVerticalBorderPresets);
// the recon decompiles it as the phantom stack param in_stack_00000004. Disasm
// 0x67fdc0-0x67fe3c: empty-check at nColumn-1 (and additionally nColumn+2 when
// dwRoadFlags==0); the river pair is placed at nColumn / nColumn+1 where both have
// outdoor flow 0x30000; second variant = (dwRoadFlags!=0)+2.
fn placeRiverCrossingPreset(pLevel: [*c]s.D2DrlgLevelStrc, nColumn: i32) void {
    const pData = wild(pLevel);
    const nUsableRows: i32 = pData.nGridCoordsHeight - 2;
    if (nUsableRows < 1) return;

    const nStartYOffset: i32 = @bitCast(rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nUsableRows)));
    const dwRoadFlags: u32 = pData.dwFlags & 4;

    var nYIter: i32 = 0;
    while (nYIter < nUsableRows) : (nYIter += 1) {
        const nY: i32 = @rem(nYIter + nStartYOffset, nUsableRows) + 1;

        if (OutPlace.isGridCellEmpty(pLevel, nColumn - 1, nY) == 0) continue;
        if (dwRoadFlags == 0 and OutPlace.isGridCellEmpty(pLevel, nColumn + 2, nY) == 0) continue;

        if ((DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nColumn, nY) & 0xf0000) != 0x30000) continue;
        if ((DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nColumn + 1, nY) & 0xf0000) != 0x30000) continue;

        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nColumn, nY, 0x1c, 1, 0);
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nColumn + 1, nY, 0x1c, @as(i32, @intFromBool(dwRoadFlags != 0)) + 2, 0);
        return;
    }
}

// DRLGOUTROOM_SpawnVerticalBorderPresets   Drlg.cpp:6117 (1.14d 0067fe90)
// Stamps 0x1a/0x1b presets along left (nColumn) and right (nColumn+1) of the
// split column, using variant tables keyed on sGridPreset value.
pub fn spawnVerticalBorderPresets(pLevel: [*c]s.D2DrlgLevelStrc, nColumn: i32) void {
    const pData = wild(pLevel);
    var nY: i32 = 0;
    while (nY < pData.nGridCoordsHeight) : (nY += 1) {
        const nGridFlagsLeft = DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nColumn, nY);
        var nVariantLeft = DrlgGrid.GetGridFlags(&pData.sGridPreset, nColumn, nY);
        if (nVariantLeft == 0) {
            nVariantLeft = if (nGridFlagsLeft & 0x100 != 0) @as(i32, 0) else @as(i32, 3);
        } else if (nVariantLeft == 7 and (nGridFlagsLeft & 0xf0000) == 0x30000) {
            nVariantLeft = 3;
        } else {
            nVariantLeft = gaVerticalBorderVariants[@intCast(nVariantLeft)][0];
        }
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nColumn, nY, 0x1a, nVariantLeft, 0);

        const nGridFlagsRight = DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nColumn + 1, nY);
        var nVariantRight = DrlgGrid.GetGridFlags(&pData.sGridPreset, nColumn + 1, nY);
        if (nVariantRight == 0) {
            nVariantRight = if (nGridFlagsRight & 0x100 != 0) @as(i32, 0) else @as(i32, 3);
        } else if (nVariantRight == 7 and (nGridFlagsRight & 0xf0000) == 0x30000) {
            nVariantRight = 3;
        } else {
            nVariantRight = gaVerticalBorderVariants[@intCast(nVariantRight)][1];
        }
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nColumn + 1, nY, 0x1b, nVariantRight, 0);
    }

    if (pData.dwFlags & 0x14 != 0) {
        placeRiverCrossingPreset(pLevel, nColumn);
    }
}

// DRLGOUTROOM_SpawnCornerFillPreset   Drlg.cpp:6219 (1.14d 006801a0)
// If sGridPreset at (nX,nY) is 0x10→place 0x19, or 0x11→place 0x18. Sets 0x40.
// Returns true on placement (pWildData->dwFlags |= 0x40 signals completion).
fn spawnCornerFillPreset(pLevel: [*c]s.D2DrlgLevelStrc, nY: i32, nX: i32) bool {
    const pData = wild(pLevel);
    const nGridFlags = DrlgGrid.GetGridFlags(&pData.sGridPreset, nX, nY);
    if (nGridFlags == 0x10) {
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, 0x19, -1, 0);
        pData.dwFlags |= 0x40;
        return true;
    } else if (nGridFlags == 0x11) {
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, 0x18, -1, 0);
        pData.dwFlags |= 0x40;
        return true;
    }
    return false;
}

// DRLGOUTROOM_FillBorderCornersAndPresets   Drlg.cpp:6239 (1.14d 00680200)
// For non-0x27 levels: optionally spawns vertical border presets (flags & 0xc),
// then conditionally fills a corner junction (flags & 0x20, draws 1 seed) and
// places a transition preset (flags & 0x1c, draws 1 seed).
pub fn fillBorderCornersAndPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel.*.eD2LevelId == .MooMooFarm) return;
    const pData = wild(pLevel);

    if (pData.dwFlags & 0xc != 0) {
        const nCol: i32 = pData.nGridCoordsWidth - 2;
        if (isGridColumnEmpty(pLevel, nCol)) {
            spawnVerticalBorderPresets(pLevel, nCol);
        }
    }

    if (pData.dwFlags & 0x20 != 0 and pData.dwFlags & 0x40 == 0) {
        const seed1 = rng.sEEDNEXT(pLevel.*.sSeed);
        pLevel.*.sSeed = seed1;
        if (seed1.nSeedLow & 1 == 0) {
            // scan row-major: outer=rows (nX), inner=cols (nY)
            var nX: i32 = 0;
            outer: while (nX < pData.nGridCoordsHeight) : (nX += 1) {
                var nY: i32 = 0;
                while (nY < pData.nGridCoordsWidth) : (nY += 1) {
                    if (spawnCornerFillPreset(pLevel, nX, nY)) break :outer;
                }
            }
        } else {
            // scan col-major: outer=rows (nY), inner=cols (nX)
            var nY: i32 = 0;
            outer: while (nY < pData.nGridCoordsHeight) : (nY += 1) {
                var nX: i32 = 0;
                while (nX < pData.nGridCoordsWidth) : (nX += 1) {
                    if (spawnCornerFillPreset(pLevel, nX, nY)) break :outer;
                }
            }
        }
    }

    if (pData.dwFlags & 0x1c != 0 and pData.dwFlags & 0x40 == 0) {
        const seed2 = rng.sEEDNEXT(pLevel.*.sSeed);
        pLevel.*.sSeed = seed2;
        const bFlip: bool = @divTrunc(seed2.nSeedLow & 3, 2) == 0;
        const nX: i32 = if ((seed2.nSeedLow & 1) == 0)
            pData.nGridCoordsWidth - (if (pData.dwFlags & 0x10 != 0) @as(i32, 4) else @as(i32, 5))
        else
            @as(i32, 3);
        const nY: i32 = if (bFlip) pData.nGridCoordsHeight - 4 else 3;
        const nPresetId: i32 = if (pLevel.*.eD2LevelId == .BloodMoor) 0x34 else 0x33;
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nX, nY, nPresetId, -1, 0);
        pData.dwFlags |= 0x40;
    }
}

// SpawnTownTransitionsAndCaves   OutWild.cpp:41 (1.14d 006803d0)
// Places road/cave/town-entry presets based on dwFlags. For level 2 (Blood Moor)
// the town-entry preset is placed maximally distant from Rogue Encampment.
pub fn SpawnTownTransitionsAndCaves(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel.*.eD2LevelId == .MooMooFarm) return;
    const pData = wild(pLevel);

    if (pData.dwFlags & 0x10 != 0) {
        const nMidCol: i32 = @divTrunc(pData.nGridCoordsWidth, 2) - 1;
        if (isGridColumnEmpty(pLevel, nMidCol)) {
            spawnVerticalBorderPresets(pLevel, nMidCol);
        }
    }
    if (pData.dwFlags & 0x80 != 0) {
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 0, 3, 1, 0);
    }
    if (pData.dwFlags & 0x100 != 0) {
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, pData.nGridCoordsWidth - 7, 0, 3, 2, 0);
    }
    if (pData.dwFlags & 0x200 != 0) {
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 1, 2, 1, 0);
    }
    if (pData.dwFlags & 0x400 != 0) {
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, pData.nGridCoordsHeight - 6, 2, 1, 0);
    }
    if (pData.dwFlags & 0x40 != 0) return;

    if (pLevel.*.eD2LevelId == .BloodMoor) {
        const pLinkedLevel = drlg.GetLevelAndAlloc(pLevel.*.pDrlg.?, .RogueEncampment);
        _ = OutPlace.SpawnPresetFarAway(
            pLevel,
            @ptrCast(&pLinkedLevel.*.sCoordinatesAndSize),
            0x34,
            -1,
            1,
            0xf,
        );
    } else {
        _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x33, -1, 1, 0xf);
    }
    pData.dwFlags |= 0x40;
}

// DRLGOUTROOM_SpawnRandomOutdoorDecorations   Drlg.cpp:6346 (1.14d 006804e0)
// Draws 1 seed. If seed & 3 == 0: calls SpawnRandomOutdoorDS1 twice. Else once,
// and if bAllowDouble draws another seed; if that seed & 1, calls again with 0x31.
pub fn spawnRandomOutdoorDecorations(
    nPresetType: i32,
    pLevel: [*c]s.D2DrlgLevelStrc,
    bAllowDouble: i32,
) void {
    const newSeed = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = newSeed;
    if (newSeed.nSeedLow & 3 == 0) {
        SpawnRandomOutdoorDS1(pLevel, nPresetType, -1);
        SpawnRandomOutdoorDS1(pLevel, nPresetType, -1);
    } else {
        SpawnRandomOutdoorDS1(pLevel, nPresetType, -1);
        if (bAllowDouble != 0) {
            const newSeed2 = rng.sEEDNEXT(pLevel.*.sSeed);
            pLevel.*.sSeed = newSeed2;
            if (newSeed2.nSeedLow & 1 != 0) {
                SpawnRandomOutdoorDS1(pLevel, 0x31, -1);
            }
        }
    }
}

// SpawnRandomOutdoorDS1   Outdoors.cpp:833 (1.14d 006745e0)
// Fisher-Yates shuffle (2×nTotalCells seed draws), then scans shuffled cells for
// ones with sGridOutdoor bit 0x80 set and tries 8 neighbor offsets from the
// binary tables. Falls through to SpawnOutdoorLevelPreset if none found.
pub fn SpawnRandomOutdoorDS1(pLevel: [*c]s.D2DrlgLevelStrc, nLvlPrestId: i32, nRand: i32) void {
    const pData = wild(pLevel);
    const nGridWidthM2: u32 = @bitCast(pData.nGridCoordsWidth - 2);
    const nTotalCells: u32 = @bitCast((pData.nGridCoordsHeight - 2) * @as(i32, @bitCast(nGridWidthM2)));
    if (nTotalCells == 0) return;

    // Store cells as interleaved [x, y] pairs (2 ints per cell)
    var aCellTable = [_][2]i32{.{ 0, 0 }} ** 513;
    {
        var i: u32 = 0;
        while (i < nTotalCells) : (i += 1) {
            aCellTable[i][0] = @intCast(i % nGridWidthM2);
            aCellTable[i][1] = @intCast(i / nGridWidthM2);
        }
    }

    // Fisher-Yates: nTotalCells iterations, 2 draws each
    var remaining: u32 = nTotalCells;
    while (remaining != 0) {
        const a = rng.randomNumberSelector(&pLevel.*.sSeed, nTotalCells);
        const b = rng.randomNumberSelector(&pLevel.*.sSeed, nTotalCells);
        remaining -= 1;
        const tx = aCellTable[a][0];
        const ty = aCellTable[a][1];
        aCellTable[a][0] = aCellTable[b][0];
        aCellTable[a][1] = aCellTable[b][1];
        aCellTable[b][0] = tx;
        aCellTable[b][1] = ty;
    }

    // Scan shuffled cells: if sGridOutdoor bit 7 is set (path cell), try 8 offsets
    var i: u32 = 0;
    while (i < nTotalCells) : (i += 1) {
        const nGridX = aCellTable[i][0] + 1;
        const nGridY = aCellTable[i][1] + 1;
        const flags: i32 = DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nGridX, nGridY);
        if (@as(i8, @bitCast(@as(u8, @truncate(@as(u32, @bitCast(flags)))))) < 0) {
            var k: usize = 0;
            while (k < 8) : (k += 1) {
                const dx: i32 = gaOutdoorsGridOffsetX[k];
                const dy: i32 = gaOutdoorsGridOffsetY[k];
                if (OutPlace.TestOutdoorLevelPreset(pLevel, nGridX + dx, nGridY + dy, nLvlPrestId, 0, 0xf) != 0) {
                    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, nGridX + dx, nGridY + dy, nLvlPrestId, nRand, 0);
                    return;
                }
            }
        }
    }

    // Fallback: regular Fisher-Yates placement
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nLvlPrestId, nRand, 0, 0xf);
}

// DRLGOUTROOM_SpawnAct1LevelPresets   Drlg.cpp:6371 (1.14d 00680580)
// Level-specific preset spawns, then always 0x1d + 0x1e for all Act-1 levels.
pub fn spawnAct1LevelPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    switch (pLevel.*.eD2LevelId) {
        .BloodMoor => {
            SpawnRandomOutdoorDS1(pLevel, 0x2e, -1);
            spawnRandomOutdoorDecorations(0x2f, pLevel, 0);
        },
        .ColdPlains => {
            spawnRandomOutdoorDecorations(0x30, pLevel, 1);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x2c, -1, 0, 0xf);
        },
        // Binary-verified (0x00680580): Stony Field — two DS1 roads, three presets, returns before shared tail.
        .StonyField => {
            SpawnRandomOutdoorDS1(pLevel, 0xa0, -1);
            SpawnRandomOutdoorDS1(pLevel, 0x2d, -1);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0xa2, -1, 0, 0xf);
            spawnRandomOutdoorDecorations(0x2f, pLevel, 1);
            spawnRandomOutdoorDecorations(0x2a, pLevel, 0);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x1f, -1, 0, 0xf);
            return;
        },
        // Binary-verified (0x00680580): Dark Wood — three presets then two deco, falls into shared tail.
        .DarkWood => {
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0xa1, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x29, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x28, -1, 0, 0xf);
            spawnRandomOutdoorDecorations(0x30, pLevel, 1);
            spawnRandomOutdoorDecorations(0x2b, pLevel, 0);
        },
        // Binary-verified (0x00680580): Black Marsh — three presets then two deco, falls into shared tail.
        .BlackMarsh => {
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0xa3, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x26, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x27, -1, 0, 0xf);
            spawnRandomOutdoorDecorations(0x2f, pLevel, 1);
            spawnRandomOutdoorDecorations(0x2a, pLevel, 0);
        },
        // Binary-verified (0x00680580): Tamoe Highland — two deco then one preset, returns before shared tail.
        .TamoeHighland => {
            spawnRandomOutdoorDecorations(0x30, pLevel, 1);
            spawnRandomOutdoorDecorations(0x2b, pLevel, 0);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x1f, -1, 0, 0xf);
            return;
        },
        // Binary-verified (0x00680580): Graveyard — 3×4 preset at anchor (1,1); returns before shared tail.
        .BurialGrounds => {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 1, 1, 0x6c, -1, 0);
            return;
        },
        // Binary-verified (0x00680580): Moo Moo Farm — five presets then shared tail.
        .MooMooFarm => {
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x32, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x2e, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x1f, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x26, -1, 0, 0xf);
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x27, -1, 0, 0xf);
        },
        else => {},
    }
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x1d, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x1e, -1, 0, 0xf);
}

// DRLGOUTROOM_SnapVertexToGrid   Drlg.cpp:6575 (1.14d 00680cc0)
// Converts an exit point (src) into a snapped grid-aligned coordinate (dst),
// relative to the level world origin. eType selects which axis is snapped and
// the constant offset added: 0/1 snap X/Y to +11, 2/3 snap X/Y to -5, 4+ copy.
fn snapVertexToGrid(pLevel: [*c]s.D2DrlgLevelStrc, pDst: *s.D2DrlgExitPointStrc, pSrc: *s.D2DrlgExitPointStrc) void {
    const nWorldX = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    const nWorldY = pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    var x = pSrc.nWorldX - nWorldX;
    var y = pSrc.nWorldY - nWorldY;
    // round-toward-zero divide by 8, *8, + constant (binary: (v + (v>>31 & 7)) >> 3)
    const snap = struct {
        fn f(v: i32, c: i32) i32 {
            const adj = v + (@as(i32, @intCast(@as(u32, @bitCast(v >> 31)) & 7)));
            return (adj >> 3) * 8 + c;
        }
    }.f;
    switch (pSrc.eType) {
        0 => x = snap(x, 0xb),
        1 => y = snap(y, 0xb),
        2 => x = snap(x, -5),
        3 => y = snap(y, -5),
        else => {},
    }
    pDst.nWorldX = x + nWorldX;
    pDst.nWorldY = y + nWorldY;
}

// DRLGOUTROOM_BuildExitPointArray   Drlg.cpp:6614 (1.14d 00680d70)
// Builds aExitPoints1 from (a) the pOrthData adjacency list — town/level links
// to eD2LevelId 1 (Rogue Encampment, per-direction offsets) or 0x1a — and then
// (b) ALWAYS a full grid scan for road-exit presets {4,5,6,7,0x18,0x19,0x1c,
// 0x33,0x34}. Each kept exit's world coords go in aExitPoints1; finally every
// exit is snapped into aExitPoints2 (the A* start positions).
fn buildExitPointArray(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    pData.nExitCount = 0;

    // (a) orth links
    var pOrth: ?*s.D2DrlgOrthStrc = pData.pOrthData;
    while (pOrth) |orth| : (pOrth = orth.pNext) {
        const pRoomExAlias = orth.pRoomEx orelse continue;
        const pAdj: *s.D2DrlgLevelStrc = @ptrCast(@alignCast(pRoomExAlias));
        const eLevelId = pAdj.eD2LevelId;
        const ax = pAdj.sCoordinatesAndSize.WorldPosition.x;
        const ay = pAdj.sCoordinatesAndSize.WorldPosition.y;
        const nIdx: usize = @intCast(pData.nExitCount);
        if (nIdx >= 6) continue;
        if (eLevelId == .RogueEncampment) {
            const ex = &pData.aExitPoints1[nIdx];
            ex.eType = @intCast(@as(u8, @truncate(@as(u32, @bitCast(orth.neDrlgDirection)))));
            switch (orth.neDrlgDirection) {
                0 => { ex.nWorldX = ax + 0x3b; ex.nWorldY = ay + 0x13; },
                1 => { ex.nWorldX = ax + 0x1d; ex.nWorldY = ay + 0x23; },
                2 => { ex.nWorldX = ax + 0x4; ex.nWorldY = ay + 0x16; },
                3 => { ex.nWorldX = ax + 0x1d; ex.nWorldY = ay + 0x3; },
                else => {},
            }
            pData.nExitCount += 1;
        } else if (eLevelId == .MonasteryGate) {
            const ex = &pData.aExitPoints1[nIdx];
            ex.nWorldX = ax + 0x1b;
            ex.nWorldY = ay + 0xd;
            ex.eType = 1;
            pData.nExitCount += 1;
        }
    }

    // (b) grid scan for road-exit presets — always runs after orth links
    const nWorldX = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    const nWorldY = pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    var nGridX: i32 = 0;
    while (nGridX < pData.nGridCoordsWidth) : (nGridX += 1) {
        var nGridY: i32 = 0;
        while (nGridY < pData.nGridCoordsHeight) : (nGridY += 1) {
            const nIdx: usize = @intCast(pData.nExitCount);
            if (nIdx >= 6) break;
            const nPreset = DrlgGrid.GetGridFlags(&pData.sGridPreset, nGridX, nGridY);
            const nOutdoorFlags: u32 = @bitCast(DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nGridX, nGridY));
            const nFlowDir: i32 = @intCast((nOutdoorFlags >> 0x10) & 0xf);
            const ex = &pData.aExitPoints1[nIdx];
            ex.nWorldX = nWorldX + nGridX * 8 + 3;
            ex.nWorldY = nWorldY + nGridY * 8 + 3;
            var eType: u8 = 4; // default = not an exit
            switch (nPreset) {
                4 => if (nFlowDir == 3) { eType = 3; },
                5 => if (nFlowDir == 3) { eType = 0; },
                6 => if (nFlowDir == 3) { eType = 1; },
                7 => if (nFlowDir == 3) { eType = 2; },
                0x18 => eType = 1,
                0x19 => eType = 0,
                0x1c => if (nFlowDir == 1 and nGridX == pData.nGridCoordsWidth - 2) { eType = 2; },
                0x33, 0x34 => eType = if (nFlowDir != 0) 1 else 0,
                else => {},
            }
            ex.eType = eType;
            if (eType != 4) pData.nExitCount += 1;
        }
    }

    // snap every exit into aExitPoints2 (A* start positions)
    var i: usize = 0;
    while (i < @as(usize, @intCast(pData.nExitCount))) : (i += 1) {
        snapVertexToGrid(pLevel, &pData.aExitPoints2[i], &pData.aExitPoints1[i]);
    }
}

// DRLGOUTROOM_FindWarpExitInColumn   Drlg.cpp:5968 (1.14d 0067fbf0)
// Scans column nX (rows 1..width-2) for the cell with preset==0x1c AND a nonzero
// outdoor flow-dir nibble; returns its grid coords, else (-1,-1).
fn findWarpExitInColumn(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, pOutX: *i32, pOutY: *i32) void {
    const pData = wild(pLevel);
    var nY: i32 = 1;
    while (nY < pData.nGridCoordsWidth - 1) : (nY += 1) {
        const nPreset = DrlgGrid.GetGridFlags(&pData.sGridPreset, nX, nY);
        const nFlags: u32 = @bitCast(DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nX, nY));
        if (nPreset == 0x1c and ((nFlags >> 0x10) & 0xf) == 1) {
            pOutX.* = nX;
            pOutY.* = nY;
            return;
        }
    }
    pOutX.* = -1;
    pOutY.* = -1;
}

// DRLGOUTROOM_ComputeExitTargetPositions   Drlg.cpp:6752 (1.14d 00681000)
// Computes each exit's target position (aExitPoints4) then snaps into aExitPoints3
// (the A* goal positions). If the level has the left-edge flag (0x10) and a warp
// column is found, exits are placed along that column. Otherwise it averages the
// exit grid positions (or grid center for a single exit) and spiral-searches for
// the first empty cell.
fn computeExitTargetPositions(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    const nWorldX = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    const nWorldY = pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    var nLeftX: i32 = -1;
    var nLeftY: i32 = -1;

    if ((pData.dwFlags & 0x10) != 0) {
        findWarpExitInColumn(pLevel, @divTrunc(pData.nGridCoordsWidth, 2) - 1, &nLeftX, &nLeftY);
    }

    if ((pData.dwFlags & 0x10) != 0 and nLeftX != -1) {
        // left-edge placement
        const nBaseX = nWorldX + 3 + nLeftX * 8;
        const nBaseY = nWorldY + 3 + nLeftY * 8;
        var i: usize = 0;
        while (i < @as(usize, @intCast(pData.nExitCount))) : (i += 1) {
            pData.aExitPoints4[i].nWorldY = nBaseY;
            if (pData.aExitPoints1[i].nWorldX > nBaseX) {
                pData.aExitPoints4[i].nWorldX = nBaseX + 8;
                pData.aExitPoints4[i].eType = 0;
            } else {
                pData.aExitPoints4[i].nWorldX = nBaseX;
                pData.aExitPoints4[i].eType = 2;
            }
        }
    } else {
        // averaged-center + spiral search
        var nExitIndex: usize = 0;
        while (nExitIndex < @as(usize, @intCast(pData.nExitCount))) : (nExitIndex += 1) {
            if (nExitIndex == 0) {
                var nCenterX: i32 = 0;
                var nCenterY: i32 = 0;
                if (pData.nExitCount == 1) {
                    nCenterX = @divTrunc(pData.nGridCoordsWidth, 2);
                    nCenterY = @divTrunc(pData.nGridCoordsHeight, 2);
                } else {
                    var sumX: i32 = 0;
                    var sumY: i32 = 0;
                    var j: usize = 0;
                    while (j < @as(usize, @intCast(pData.nExitCount))) : (j += 1) {
                        sumX += pData.aExitPoints1[j].nWorldX - nWorldX;
                        sumY += pData.aExitPoints1[j].nWorldY - nWorldY;
                    }
                    const div = pData.nExitCount * 8;
                    nCenterX = @divTrunc(sumX, div);
                    nCenterY = @divTrunc(sumY, div);
                }
                var nFoundX: i32 = 0;
                var nFoundY: i32 = 0;
                var bFound = false;
                var radius: i32 = 0;
                while (radius < 8 and !bFound) : (radius += 1) {
                    var dir: usize = 0;
                    while (dir < 4) : (dir += 1) {
                        nFoundX = gaSpiralOffsetX[dir] * radius + nCenterX;
                        nFoundY = gaSpiralOffsetY[dir] * radius + nCenterY;
                        if (nFoundX >= 0 and nFoundX < pData.nGridCoordsWidth and
                            nFoundY >= 0 and nFoundY < pData.nGridCoordsHeight)
                        {
                            if (OutPlace.isGridCellEmpty(pLevel, nFoundX, nFoundY) != 0) {
                                bFound = true;
                                break;
                            }
                        }
                    }
                }
                pData.aExitPoints4[0].nWorldX = nWorldX + nFoundX * 8 + 3;
                pData.aExitPoints4[0].nWorldY = nWorldY + nFoundY * 8 + 3;
                pData.aExitPoints4[0].eType = 4;
            } else {
                pData.aExitPoints4[nExitIndex].nWorldX = pData.aExitPoints4[0].nWorldX;
                pData.aExitPoints4[nExitIndex].nWorldY = pData.aExitPoints4[0].nWorldY;
                pData.aExitPoints4[nExitIndex].eType = 4;
            }
        }
    }

    // snap every target into aExitPoints3 (A* goal positions)
    var i: usize = 0;
    while (i < @as(usize, @intCast(pData.nExitCount))) : (i += 1) {
        snapVertexToGrid(pLevel, &pData.aExitPoints3[i], &pData.aExitPoints4[i]);
    }
}

// Road A* node pool
// Node = 10 ints: [0]FCost [1]HMin [2]GCost [3]posX [4]posY [5]stepCount
// [6]deltaIdx(into gaOutRoomPathDirectionDelta) [7]dirByte(0..3) [8]parentRef
// [9]childRef. Refs are 1-based node indices (0 = null). Node 0 = init/root.
const PATH_POOL_NODES = 900; // 0x384
const PathCtx = struct {
    pool: [PATH_POOL_NODES * 10]i32,
    nPoolIndex: i32,
    pLevel: [*c]s.D2DrlgLevelStrc,
    targetX: i32,
    targetY: i32,

    inline fn get(self: *PathCtx, idx: i32, field: usize) i32 {
        return self.pool[@as(usize, @intCast(idx)) * 10 + field];
    }
    inline fn set(self: *PathCtx, idx: i32, field: usize, v: i32) void {
        self.pool[@as(usize, @intCast(idx)) * 10 + field] = v;
    }

    fn delta(i: i32) i32 {
        return gaOutRoomPathDirectionDelta[@intCast(i)];
    }

    // DRLGPATH_GetPathDirection: returns primary direction toward (toX,toY).
    fn pathDir(fromX: i32, fromY: i32, toX: i32, toY: i32) i32 {
        const dirIdx = directionIndex(toX - fromX, toY - fromY);
        return gaPathDirectionPrimary[@intCast(dirIdx)];
    }

    // DRLGPATH_GetDirectionIndex: maps (dx,dy) to a clamped 5x5 grid index 0..24.
    fn directionIndex(dx_in: i32, dy_in: i32) i32 {
        var nDx = dx_in;
        var nDy = dy_in;
        const absDx = if (nDx < 0) -nDx else nDx;
        const absDy = if (nDy < 0) -nDy else nDy;
        if (absDx < absDy * 2) {
            if (absDx * 2 <= absDy) {
                if (nDx < 0) {
                    nDx = -1;
                    if (nDy < -1) return nDx * 5 + 10;
                    if (1 >= nDy) return nDx * 5 + 0xc + nDy;
                    return nDx * 5 + 0xc + 2;
                }
                nDx &= 1;
            }
        } else if (nDy < 0) {
            nDy = -1;
        } else {
            nDy &= 1;
        }
        if (nDx < -1) {
            nDx = -2;
        } else if (1 < nDx) {
            nDx = 2;
        }
        if (nDy < -1) return nDx * 5 + 10;
        if (1 >= nDy) return nDx * 5 + 0xc + nDy;
        return nDx * 5 + 0xc + 2;
    }

    // DRLGOUTROOM_AdvancePathDirection: cycle the current node's direction; when
    // exhausted, backtrack up the parent chain. Returns the next node index, or
    // -1 if the search has unwound past the root.
    fn advance(self: *PathCtx, nodeIdx: i32) i32 {
        var idx = nodeIdx;
        if (self.get(idx, 5) < 4) {
            self.set(idx, 6, self.get(idx, 6) + 1);
            const d = delta(self.get(idx, 6));
            self.set(idx, 7, (d + self.get(idx, 7)) & 3);
        }
        self.set(idx, 5, self.get(idx, 5) + 1);
        if (self.get(idx, 5) != 3) return idx;
        while (idx != 0) {
            idx = self.get(idx, 8) - 1; // parent
            self.set(idx, 6, self.get(idx, 6) + 1);
            const d = delta(self.get(idx, 6));
            self.set(idx, 5, self.get(idx, 5) + 1);
            self.set(idx, 7, (d + self.get(idx, 7)) & 3);
            if (self.get(idx, 5) != 3) return idx;
        }
        return -1;
    }

    // DRLGOUTROOM_ValidatePathStep: target reached / in-bounds / not a wall
    // (0x200) / not already on the current node's ancestor chain.
    fn validate(self: *PathCtx, nextX: i32, nextY: i32, nodeIdx: i32) bool {
        if (nextX == self.targetX and nextY == self.targetY) return true;
        const pData = wild(self.pLevel);
        if (!(nextX >= 0 and nextX < pData.nGridCoordsWidth and
            nextY >= 0 and nextY < pData.nGridCoordsHeight)) {
            return false;
        }
        const flags: u32 = @bitCast(DrlgGrid.GetGridFlags(&pData.sGridOutdoor, nextX, nextY));
        if (flags & 0x200 != 0) {
            return false;
        }
        var v = nodeIdx;
        while (true) {
            if (self.get(v, 3) == nextX and self.get(v, 4) == nextY) return false;
            const p = self.get(v, 8);
            if (p == 0) return true;
            v = p - 1;
        }
    }

    // DRLGOUTROOM_PathSearchStep: expand from the root until the target is
    // reached or all directions within nMaxFCost are exhausted. Returns the
    // found node index, or -1.
    fn searchStep(self: *PathCtx, nMaxFCost: i32) i32 {
        var idx: i32 = 0; // root
        while (true) {
            if (self.get(idx, 3) == self.targetX and self.get(idx, 4) == self.targetY) return idx;
            const dir = self.get(idx, 7);
            const nextX = delta(dir + 0x14) + self.get(idx, 3);
            const nextY = delta(dir + 0x10) + self.get(idx, 4);
            if (self.validate(nextX, nextY, idx)) {
                const posX = self.get(idx, 3);
                const posY = self.get(idx, 4);
                const moveCost: i32 = if (posX == nextX or posY == nextY) 2 else 3;
                const parentG = self.get(idx, 2);
                const a = if (nextX - self.targetX < 0) -(nextX - self.targetX) else nextX - self.targetX;
                var b = if (nextY - self.targetY < 0) -(nextY - self.targetY) else nextY - self.targetY;
                var hMin = a;
                if (b <= a) {
                    hMin = b;
                    if (b < a) b = a;
                }
                hMin += b * 2;
                const fCost = hMin + parentG + moveCost;
                if (fCost <= nMaxFCost) {
                    if (self.get(idx, 9) == 0) {
                        const slot = self.nPoolIndex;
                        if (slot == PATH_POOL_NODES) return -1;
                        var k: usize = 0;
                        while (k < 10) : (k += 1) self.set(slot, k, 0);
                        self.nPoolIndex += 1;
                        self.set(idx, 9, slot + 1);
                        self.set(slot, 8, idx + 1);
                    }
                    const child = self.get(idx, 9) - 1;
                    self.set(child, 1, hMin);
                    self.set(child, 0, fCost);
                    self.set(child, 2, parentG + moveCost);
                    self.set(child, 5, 0);
                    const d = pathDir(nextX, nextY, self.targetX, self.targetY);
                    const parentDirOff = self.get(child, 8) - 1; // parent idx
                    const dirHalf = @divTrunc(d, 2);
                    const group: i32 = @intCast((@as(u32, @bitCast(self.get(parentDirOff, 7) - dirHalf)) & 3));
                    self.set(child, 6, group * 4);
                    self.set(child, 7, (delta(group * 4) + dirHalf) & 3);
                    self.set(child, 3, nextX);
                    self.set(child, 4, nextY);
                    idx = child;
                    continue;
                }
            }
            const adv = self.advance(idx);
            if (adv < 0) return -1;
            idx = adv;
        }
    }
};

// DRLGOUTROOM_FindPathBetweenExits   Drlg.cpp:7184 (1.14d 006817d0)
// Runs the road A* from aExitPoints2[idx] (start) to aExitPoints3[idx] (goal),
// growing the F-cost bound from hMin*3/2 by 5 each retry until hMin+0x23. On
// success, builds the vertex chain (goal→start) into pAdjacentVertices[idx].
// For Manhattan distance ≤ 1 it short-circuits with a 2-vertex straight line.
fn findPathBetweenExits(pLevel: [*c]s.D2DrlgLevelStrc, nExitIndex: i32) bool {
    const pData = wild(pLevel);
    const nMem = pLevel.*.pDrlg.?.pMemoryPool;
    const idx: usize = @intCast(nExitIndex);
    const nWorldX = pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    const nWorldY = pLevel.*.sCoordinatesAndSize.WorldPosition.y;

    const div8 = struct {
        fn f(v: i32) i32 {
            const adj = v + (@as(i32, @intCast(@as(u32, @bitCast(v >> 31)) & 7)));
            return adj >> 3;
        }
    }.f;

    const nStartGridX = div8(pData.aExitPoints2[idx].nWorldX - nWorldX);
    const nStartGridY = div8(pData.aExitPoints2[idx].nWorldY - nWorldY);
    const nTargetX = div8(pData.aExitPoints3[idx].nWorldX - nWorldX);
    const nTargetGridY = div8(pData.aExitPoints3[idx].nWorldY - nWorldY);

    const dxRaw = nStartGridX - nTargetX;
    const dyRaw = nStartGridY - nTargetGridY;
    const adx = if (dxRaw < 0) -dxRaw else dxRaw;
    const ady = if (dyRaw < 0) -dyRaw else dyRaw;

    if (ady + adx <= 1) {
        const pv = DrlgVer.allocVertex(nMem, 0);
        pData.pAdjacentVertices[idx] = pv;
        pv.*.nPosX = nStartGridX;
        pv.*.nPosY = nStartGridY;
        const pv2 = DrlgVer.allocVertex(nMem, 0);
        pv.*.pNext = pv2;
        pv2.*.nPosX = nTargetX;
        pv2.*.nPosY = nTargetGridY;
        return true;
    }

    // init node + cost bounds
    var hMin = if (adx < ady) adx else ady; // min(|dx|,|dy|)
    const hMax = if (adx < ady) ady else adx; // max(|dx|,|dy|)
    hMin += hMax * 2;
    const byInitDir: i32 = @intCast(@as(u32, @bitCast(@divTrunc(PathCtx.pathDir(nStartGridX, nStartGridY, nTargetX, nTargetGridY), 2))) & 3);

    var ctx: PathCtx = undefined;
    ctx.pLevel = pLevel;
    ctx.targetX = nTargetX;
    ctx.targetY = nTargetGridY;

    var nMaxFCost = @divTrunc(hMin, 2) + hMin; // hMin * 3/2
    const nMaxFCostLimit = nMaxFCost + 0x23;
    while (true) {
        ctx.nPoolIndex = 1;
        // build init/root node 0
        ctx.set(0, 0, hMin); // FCost = HMin
        ctx.set(0, 1, hMin); // HMin
        ctx.set(0, 2, 0); // GCost
        ctx.set(0, 3, nStartGridX);
        ctx.set(0, 4, nStartGridY);
        ctx.set(0, 5, -1); // stepCount
        ctx.set(0, 6, 0); // deltaIdx
        ctx.set(0, 7, byInitDir);
        ctx.set(0, 8, 0); // parent = null
        ctx.set(0, 9, 0); // child = null

        const found = ctx.searchStep(nMaxFCost);
        nMaxFCost += 5;
        if (ctx.nPoolIndex > 899) return false;

        if (found >= 0) {
            var node = found;
            var pPrev: [*c]s.D2DrlgVertexStrc = null;
            while (true) {
                const pv = DrlgVer.allocVertex(nMem, 0);
                if (pData.pAdjacentVertices[idx] == null) {
                    pData.pAdjacentVertices[idx] = pv;
                } else {
                    pPrev.*.pNext = pv;
                }
                pv.*.nPosX = ctx.get(node, 3);
                pv.*.nPosY = ctx.get(node, 4);
                pPrev = pv;
                const p = ctx.get(node, 8);
                if (p == 0) break;
                node = p - 1;
            }
            return true;
        }
        if (nMaxFCost >= nMaxFCostLimit) break;
    }
    return false;
}

// Drlg_CallTable_2   Drlg.cpp:5504 (1.14d)
// Walks a vertex linked list; for each in-bounds (x,y) sets the given grid flag.
fn Drlg_CallTable_2(pGrid: [*c]s.D2DrlgGridStrc, pHead: ?*s.D2DrlgVertexStrc, nFlag: i32) void {
    var pv = pHead;
    while (pv) |v| {
        const x = v.nPosX;
        const y = v.nPosY;
        pv = v.pNext;
        if (x >= 0 and x < pGrid.*.nWidth and y >= 0 and y < pGrid.*.nHeight) {
            DrlgGrid.AlterGridFlag(pGrid, x, y, nFlag, 0);
        }
    }
}

// DRLGOUTROOM_BuildVertexPathsWithJitter   Drlg.cpp:6873 (1.14d 00681240)
// ALWAYS draws 1 seed on entry regardless of whether a path exists. If a path
// exists (pVertex != null), adjusts vertex positions; draws 2 more seeds per
// interior vertex. This is the only RNG consumer in the exit-link loop.
fn buildVertexPathsWithJitter(pLevel: [*c]s.D2DrlgLevelStrc, nPathIdx: i32) void {
    // Direction tables (static in the engine, fixed values from 1.14d binary)
    const gnDrlgLevelSeed = [4]i32{ 1, 0, -1, 0 };   // X jitter direction
    const gnDrlgLevelVersion = [4]i32{ 0, 1, 0, -1 }; // Y jitter direction

    const pData = wild(pLevel);
    // v0 = the A*'s first vertex, captured BEFORE any prepend (engine keeps this
    // local pointer through the prepend; the prepended head is NOT this vertex).
    const pV0opt = pData.pAdjacentVertices[@intCast(nPathIdx)];

    // ALWAYS draw 1 seed on entry
    const DVar2 = rng.sEEDNEXT(pLevel.*.sSeed);
    var uVar6: u32 = @as(u32, @bitCast(DVar2.nSeedLow)) & 3;
    pLevel.*.sSeed = DVar2;

    // If no path was found, return after the 1 draw
    const v0 = pV0opt orelse return;

    // Prepend a target vertex if exit type is not "center". The prepended head
    // keeps aExitPoints4 coords; v0 (below) becomes aExitPoints3.
    if (pData.aExitPoints4[@intCast(nPathIdx)].eType != 4) {
        const pHeadVertex = DrlgVer.allocVertex(pLevel.*.pDrlg.?.pMemoryPool, 0);
        pHeadVertex.*.nPosX = pData.aExitPoints4[@intCast(nPathIdx)].nWorldX;
        pHeadVertex.*.nPosY = pData.aExitPoints4[@intCast(nPathIdx)].nWorldY;
        pHeadVertex.*.pNext = v0;
        pData.pAdjacentVertices[@intCast(nPathIdx)] = pHeadVertex;
    }

    // v0 (NOT the prepended head) gets aExitPoints3 coords; jitter starts at v1.
    v0.*.nPosX = pData.aExitPoints3[@intCast(nPathIdx)].nWorldX;
    v0.*.nPosY = pData.aExitPoints3[@intCast(nPathIdx)].nWorldY;

    // Walk interior vertices (those with a next), draw 2 seeds each
    var pCur = v0.*.pNext;
    if (pCur == null) return;

    while (pCur.?.pNext != null) {
        const DVar3 = rng.sEEDNEXT(pLevel.*.sSeed);
        pLevel.*.sSeed = DVar3;
        const iDx = gnDrlgLevelSeed[uVar6];
        const DVar5 = rng.sEEDNEXT(pLevel.*.sSeed);
        pLevel.*.sSeed = DVar5;
        const iDy = gnDrlgLevelVersion[uVar6];
        uVar6 = (uVar6 + 1) & 3;

        const gx = pCur.?.nPosX * 8;
        const gy = pCur.?.nPosY * 8;
        pCur.?.nPosX = pLevel.*.sCoordinatesAndSize.WorldPosition.x + gx + 3 + (@as(i32, @intCast(DVar3.nSeedLow & 1)) + 2) * iDx;
        pCur.?.nPosY = pLevel.*.sCoordinatesAndSize.WorldPosition.y + gy + 3 + (@as(i32, @intCast(DVar5.nSeedLow & 1)) + 2) * iDy;
        pCur = pCur.?.pNext;
        if (pCur == null) return;
    }

    // Set last vertex to exit point 2 coords and append exit point 1 as terminal
    pCur.?.nPosX = pData.aExitPoints2[@intCast(nPathIdx)].nWorldX;
    pCur.?.nPosY = pData.aExitPoints2[@intCast(nPathIdx)].nWorldY;
    const pTerminal = DrlgVer.allocVertex(pLevel.*.pDrlg.?.pMemoryPool, 0);
    pTerminal.*.nPosX = pData.aExitPoints1[@intCast(nPathIdx)].nWorldX;
    pTerminal.*.nPosY = pData.aExitPoints1[@intCast(nPathIdx)].nWorldY;
    pCur.?.pNext = pTerminal;
}

// DRLGOUTROOM_LinkOutdoorRoomExits   Drlg.cpp:6942 (1.14d 00681420)
// Wires inter-level exits: build the exit array + target positions, then for
// each exit run the road A*; on success mark the path cells (sGridOutdoor 0x80)
// and jitter the vertex chain. The 0x80 marks let SpawnRandomOutdoorDS1 place
// road presets, which is what drives the per-room seed sequence.
pub fn linkOutdoorRoomExits(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    buildExitPointArray(pLevel);
    computeExitTargetPositions(pLevel);
    var nIndex: i32 = 0;
    while (nIndex < pData.nExitCount) : (nIndex += 1) {
        if (findPathBetweenExits(pLevel, nIndex)) {
            Drlg_CallTable_2(&pData.sGridOutdoor, pData.pAdjacentVertices[@intCast(nIndex)], 0x80);
            buildVertexPathsWithJitter(pLevel, nIndex);
        }
    }
}
