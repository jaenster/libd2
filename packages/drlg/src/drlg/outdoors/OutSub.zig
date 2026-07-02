//! Faithful transform of the DRLG outdoor SUBSTITUTION-GROUP placement
//! (recon/closure/Drlg.cpp DRLGOUTDOOR_ApplySubstitutionGroup / PlaceRandom-
//! BorderSubTiles, Outdoors.cpp ValidateSubTilePlacement / ApplySubTileToGrid).
//!
//! Driven by TileSub::AddSecondaryBorder once InitializeDrlgFile has loaded the
//! LvlSub DrlgFile. ApplySubstitutionGroup is cleanly decompiled and transformed
//! here; the inner placement (PlaceRandomBorderSubTiles + Validate/ApplySubTile-
//! ToGrid) is gated on a Ghidra register/type-recovery pass — see the stub note.

const std = @import("std");
const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const tables = @import("../tables.zig");
const DrlgGrid = @import("../DrlgGrid.zig");
const OutPlace = @import("OutPlace.zig");

const D2LvlSubTxt = tables.D2LvlSubTxt;

// Callback pointer types — the D2UnkOutdoorStrc pfn fields hold these (set by the
// caller, e.g. DRLGOUTROOM_PlaceAct5SecondaryBorder). @TypeOf preserves each
// target's calling convention across the @ptrCast round-trip through ?*anyopaque.
const ValidateBorderCellFn = @TypeOf(&OutPlace.validateSecondaryBorderCell);
const TestPresetFn = @TypeOf(&OutPlace.TestOutdoorLevelPreset);
const IsPresetFreeFn = @TypeOf(&OutPlace.isGridCellPresetFree);
const GetBorderPresetFn = @TypeOf(&OutPlace.getSecondaryBorderPresetFromLvlSub);
const AlterCellFn = @TypeOf(&OutPlace.AlterAdjacentPresetGridCells);
const SpawnPresetFn = @TypeOf(&OutPlace.SpawnOutdoorLevelPresetEx);

/// DRLGOUTDOOR_ApplySubstitutionGroup (Drlg.cpp:1983, 1.14d 0066f990).
/// Cleanly decompiled — faithful transform. Consumes ONE seed draw off
/// pLevel->sSeed (RANDOM_RandomNumberSelector, low-word per rng.zig) to pick the
/// start substitution group when BordType==0, then walks the groups round-robin,
/// placing each via PlaceRandomBorderSubTiles and stopping after the first
/// success for BordType==0.
pub fn applySubstitutionGroup(pUnkOutdoor: *s.D2UnkOutdoorStrc, pLvlSub: *D2LvlSubTxt) void {
    const pFile = pLvlSub.pDrlgFile orelse return;
    const nModulo: i32 = pFile.nSubstGroups;
    if (nModulo == 0) {
        return;
    }
    if (pUnkOutdoor.nPrevBorderPresetId == -1) {
        pUnkOutdoor.nPrevBorderPresetId = 0x3e;
    }
    var nRandStartGroup: i32 = 0;
    if (pLvlSub.BordType == 0) {
        nRandStartGroup = @bitCast(rng.randomNumberSelector(&pUnkOutdoor.pLevel.?.sSeed, @bitCast(nModulo)));
    }
    if (nModulo <= 0) {
        return;
    }

    const groups: [*]s.D2DrlgSubstGroupStrc = @ptrCast(pFile.pSubstGroups.?);
    var nGroupIter: i32 = 0;
    while (true) {
        const idx: usize = @intCast(@mod(nRandStartGroup + nGroupIter, nModulo));
        const bPlaced = PlaceRandomBorderSubTiles(pUnkOutdoor, pLvlSub, &groups[idx]);
        if (bPlaced != 0 and pLvlSub.BordType == 0) {
            return;
        }
        nGroupIter += 1;
        if (!(nGroupIter < nModulo)) break;
    }
}

// Recovered placement signatures (Ghidra 1.14d, set_custom_signature)
//
// The three inner fns mistype their LvlSub param as D2DrlgLevelDataWildernessLevel*
// because [param+0x4c] reads as gridCellSize — but in D2LvlSubTxt 0x4c=GridSize,
// 0x50=pDrlgFile, 0xa4=pWallGrid[0], 0xf4=pFloorGrid, and every body access lands
// on those LvlSub fields, so the param is pLvlSub (D2LvlSubTxt*). The callbacks are
// __fastcall (pLevel in ECX, first index in EDX, remaining args on stack); the
// register args were dropped by the decompiler and recovered from the disassembly.
// Corrected signatures (re-decompiled clean):
//   PlaceRandomBorderSubTiles  @0066f690  __stdcall RET 0xc
//     (pOutdoorCtx [stack+4], pLvlSub [stack+8], pRect=&substGroup.tBox [stack+c]).
//     The recon `(int)(intptr_t)pRect * h` is a wrong-int*-type artifact: the real
//     op (0066f6f1 area) is pRect[2]*GridSize / pRect[3]*GridSize (tBox w/h * GridSize).
//   ValidateSubTilePlacement   @0066f3b0  EDI + 4 stdcall stack, RET 0x10
//     (pOutdoorCtx [EDI], nBaseGridX [stack+4], nBaseGridY [stack+8],
//      pSubRect=&tBox [stack+c], pSubLvl [stack+10]).
//   ApplySubTileToGrid         @0066f520  __stdcall RET 0x18
//     (nBaseX [stack+4], nBaseY [stack+8], pOutdoorCtx [stack+c],
//      pCoords=&tBox [stack+10], pLvlSub [stack+14], nOffset [stack+18]).

/// DRLGOUTDOOR_ValidateSubTilePlacement (Outdoors.cpp:74, 1.14d 0066f3b0). For each
/// cell of the substitution-group box, reads the LvlSub wall/floor grids and the
/// outdoor primary-floor grid, then runs the border-validation callback. Returns
/// false on the first rejected cell, true if every cell passes. Consumes NO seed.
fn ValidateSubTilePlacement(
    pOutdoorCtx: *s.D2UnkOutdoorStrc,
    nBaseGridX: i32,
    nBaseGridY: i32,
    pSubRect: *s.D2DrlgCoordStrc,
    pSubLvl: *D2LvlSubTxt,
) bool {
    const pLevel = pOutdoorCtx.pLevel.?;
    const nGridStride = pSubLvl.GridSize;
    var dy: i32 = 0;
    while (dy < pSubRect.nHeight) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < pSubRect.nWidth) : (dx += 1) {
            const floorFlag: u32 = if (pSubLvl.pDrlgFile.?.nFloorLayers == 0) 0 else @bitCast(DrlgGrid.GetGridFlags(&pSubLvl.pFloorGrid, pSubRect.nPosX + dx, pSubRect.nPosY + dy));
            const wallFlag: u32 = if (pSubLvl.pDrlgFile.?.nWallLayers == 0) 0 else @bitCast(DrlgGrid.GetGridFlags(&pSubLvl.pWallGrid[0], pSubRect.nPosX + dx, pSubRect.nPosY + dy));
            const cellY = pSubLvl.GridSize * dy + (nBaseGridY - @rem(nBaseGridY, nGridStride));
            const cellX = pSubLvl.GridSize * dx + (nBaseGridX - @rem(nBaseGridX, nGridStride));
            const nSubTileFlags = DrlgGrid.GetGridFlags(pOutdoorCtx.pPrimaryFloorGrid.?, cellX, cellY);

            if (pOutdoorCtx.pfnValidateBorderCell) |pfn| {
                const f: ValidateBorderCellFn = @ptrCast(@alignCast(pfn));
                if (f(@ptrCast(pLevel), cellX, cellY, nSubTileFlags, @bitCast(floorFlag), wallFlag) == 0) return false;
            } else if (wallFlag & 1 != 0) {
                const nIdx: i32 = @as(i32, @bitCast((wallFlag >> 8) & 0xff)) - 1;
                if (nIdx != pOutdoorCtx.nPrevBorderPresetId and pOutdoorCtx.nLevelPrestId + nIdx != nSubTileFlags) return false;
                const f: IsPresetFreeFn = @ptrCast(@alignCast(pOutdoorCtx.pfnIsPresetFree.?));
                if (f(@ptrCast(pLevel), cellX, cellY) == 0) return false;
            } else if (floorFlag & 2 != 0) {
                const f: TestPresetFn = @ptrCast(@alignCast(pOutdoorCtx.pfnTestPreset.?));
                if (f(@ptrCast(pLevel), cellX, cellY, 0, 0, 0) == 0) return false;
            }
        }
    }
    return true;
}

/// DRLGOUTDOOR_ApplySubTileToGrid (Outdoors.cpp:147, 1.14d 0066f520). Stamps the
/// substitution-group cells into the outdoor grids via the border callbacks
/// (wall -> spawn border preset, floor 0x2 -> alter adjacent, else -> blank).
/// Consumes NO seed. nOffset shifts the box X by the chosen variant.
fn ApplySubTileToGrid(
    nBaseX: i32,
    nBaseY: i32,
    pOutdoorCtx: *s.D2UnkOutdoorStrc,
    pCoords: *s.D2DrlgCoordStrc,
    pLvlSub: *D2LvlSubTxt,
    nOffset: i32,
) void {
    const pLevel = pOutdoorCtx.pLevel.?;
    const nWorldX = pCoords.nPosX + nOffset;
    const nWorldY = pCoords.nPosY;
    const nGridStride = pLvlSub.GridSize;
    var nRow: i32 = 0;
    while (nRow < pCoords.nHeight) : (nRow += 1) {
        var nCol: i32 = 0;
        while (nCol < pCoords.nWidth) : (nCol += 1) {
            const uWallFlags: u32 = if (pLvlSub.pDrlgFile.?.nWallLayers == 0) 0 else @bitCast(DrlgGrid.GetGridFlags(&pLvlSub.pWallGrid[0], nCol + nWorldX, nRow + nWorldY));
            const uFloorFlags: u32 = if (pLvlSub.pDrlgFile.?.nFloorLayers == 0) 0 else @bitCast(DrlgGrid.GetGridFlags(&pLvlSub.pFloorGrid, nCol + nWorldX, nRow + nWorldY));
            const cellY = pLvlSub.GridSize * nRow + (nBaseY - @rem(nBaseY, nGridStride));
            const cellX = pLvlSub.GridSize * nCol + (nBaseX - @rem(nBaseX, nGridStride));

            if (uWallFlags & 1 == 0) {
                if (uFloorFlags & 2 == 0) {
                    const f: AlterCellFn = @ptrCast(@alignCast(pOutdoorCtx.pfnSetBlankCell.?));
                    f(@ptrCast(pLevel), cellX, cellY);
                } else {
                    const f: AlterCellFn = @ptrCast(@alignCast(pOutdoorCtx.pfnAlterAdjacentCells.?));
                    f(@ptrCast(pLevel), cellX, cellY);
                }
            } else {
                const uWall8: u32 = (uWallFlags >> 8) & 0xff;
                const nWallMainIndex: i32 = @as(i32, @bitCast(uWall8)) - 1;
                const nPresetId: i32 = if (pOutdoorCtx.pfnGetBorderPreset) |pfn| blk: {
                    const f: GetBorderPresetFn = @ptrCast(@alignCast(pfn));
                    break :blk f(@ptrCast(pLevel), @bitCast((uWallFlags >> 0x14) & 0x3f), @bitCast(uWall8));
                } else pOutdoorCtx.nLevelPrestId + nWallMainIndex;
                if (nPresetId != -5 and nWallMainIndex != pOutdoorCtx.nPrevBorderPresetId) {
                    const f: SpawnPresetFn = @ptrCast(@alignCast(pOutdoorCtx.pfnSpawnPreset.?));
                    f(@ptrCast(pLevel), cellX, cellY, nPresetId, 0, 1);
                }
            }
        }
    }
}

/// DRLGOUTDOOR_PlaceRandomBorderSubTiles (Drlg.cpp:1848, 1.14d 0066f690). Builds
/// the candidate-position list for the substitution box, Fisher-Yates-shuffles it
/// (two seed draws per step off pLevel->sSeed via RANDOM_RandomNumberSelector),
/// then places at the first position that validates — rolling one variant draw on
/// success. Returns 1 when a placement is committed for a stop-on-first BordType.
pub fn PlaceRandomBorderSubTiles(
    pUnkOutdoor: *s.D2UnkOutdoorStrc,
    pLvlSub: *D2LvlSubTxt,
    pSubstGroup: *s.D2DrlgSubstGroupStrc,
) u32 {
    const pRect = &pSubstGroup.tBox;
    const pLevel = pUnkOutdoor.pLevel.?;
    // recon Drlg.cpp:1862 `isNotBaseLvlSub = !nLvlSubId` — the value is TRUE iff
    // nLvlSubId == 0 (the decompiler's name is inverted). Drives posIterInit and
    // strictCornerLimit; was wrongly keyed on `!= 1` (latent: Act2/Act5 have
    // dwFlags&0xc == 0 so it never manifested, but it broke Act1 0x27 ids 2/3).
    const isNotBaseLvlSub = pUnkOutdoor.nLvlSubId != 1;
    const eLvl = @intFromEnum(pLevel.eD2LevelId);
    const bMidActLevel = (eLvl >= 2 and eLvl <= 7);

    // posIterInit: base LvlSub on an interior tile (dwFlags & 0xc) shrinks the run.
    var posIterInit: i32 = 1;
    if (!isNotBaseLvlSub) {
        const pWild: *const s.D2DrlgLevelDataWildernessLevel = @ptrCast(@alignCast(pLevel.pDrlgLevelData.?));
        if ((pWild.dwFlags & 0xc) != 0) posIterInit = -1;
    }

    const posW = (pUnkOutdoor.pCoordsGrid.?.nWidth - pRect.nWidth * pLvlSub.GridSize) + posIterInit;
    const posH = (pUnkOutdoor.pCoordsGrid.?.nHeight - pRect.nHeight * pLvlSub.GridSize) + 1;
    const totalPositions: i32 = posH * posW;
    if (totalPositions == 0) return 0;

    const strictCornerLimit: bool = !isNotBaseLvlSub and bMidActLevel and posW <= 5 and posH <= 5;

    var aPositions: [513][2]i32 = undefined;
    if (totalPositions > 0) {
        // Enumerate the (col,row) candidate grid (col = idx%posW, row = idx/posW).
        var posIndex: i32 = 0;
        while (posIndex < totalPositions) : (posIndex += 1) {
            const tileRow = @divTrunc(posIndex, posW);
            const tileCol = @rem(posIndex, posW);
            aPositions[@intCast(posIndex)] = .{ tileCol, tileRow };
        }
        // Fisher-Yates: two seed draws per step, swap the two indexed pairs.
        var remaining: i32 = totalPositions;
        while (remaining > 0) : (remaining -= 1) {
            const a = rng.randomNumberSelector(&pLevel.sSeed, @bitCast(totalPositions));
            const b = rng.randomNumberSelector(&pLevel.sSeed, @bitCast(totalPositions));
            const tmp = aPositions[a];
            aPositions[a] = aPositions[b];
            aPositions[b] = tmp;
        }
    }

    var posIter: i32 = 0;
    if (totalPositions <= 0) return 0;
    while (posIter < totalPositions) : (posIter += 1) {
        const pos = aPositions[@intCast(posIter)];
        if (strictCornerLimit and pos[0] == 2 and pos[1] == 2) continue;
        if (ValidateSubTilePlacement(pUnkOutdoor, pos[0], pos[1], pRect, pLvlSub)) {
            const randVar = rng.randomNumberSelector(&pLevel.sSeed, @bitCast(pSubstGroup.nVariantCount));
            const nOffset = (pRect.nWidth + 1) * (@as(i32, @bitCast(randVar)) + 1);
            ApplySubTileToGrid(pos[0], pos[1], pUnkOutdoor, pRect, pLvlSub, nOffset);
            if (pLvlSub.BordType == 0 or pLvlSub.BordType == 1) return 1;
        }
    }
    return 0;
}

test "ApplySubstitutionGroup: nSubstGroups==0 is an early no-op (no seed draw)" {
    var file: s.D2DrlgFileStrc = std.mem.zeroes(s.D2DrlgFileStrc);
    file.nSubstGroups = 0;
    var sub: D2LvlSubTxt = std.mem.zeroes(D2LvlSubTxt);
    sub.pDrlgFile = &file;
    var level: s.D2DrlgLevelStrc = std.mem.zeroes(s.D2DrlgLevelStrc);
    level.sSeed = .{ .nSeedLow = 0x12345678, .nSeedHigh = 0 };
    var ctx: s.D2UnkOutdoorStrc = std.mem.zeroes(s.D2UnkOutdoorStrc);
    ctx.pLevel = &level;
    ctx.nPrevBorderPresetId = -1;
    applySubstitutionGroup(&ctx, &sub);
    // No groups -> immediate return, seed untouched, prev-border left at -1.
    try std.testing.expectEqual(@as(i32, 0x12345678), level.sSeed.nSeedLow);
    try std.testing.expectEqual(@as(i32, -1), ctx.nPrevBorderPresetId);
}
