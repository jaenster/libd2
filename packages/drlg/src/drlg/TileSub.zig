//! Faithful Zig transform of recon/closure/TileSub.cpp
//! (D2Common::Drlg::TileSub — secondary-border substitution-group tiling).

const std = @import("std");
const s = @import("structs.zig");
const tables = @import("tables.zig");
const preset = @import("preset.zig");
const DrlgGrid = @import("DrlgGrid.zig");
const OutSub = @import("outdoors/OutSub.zig");

const D2UnkOutdoorStrc = s.D2UnkOutdoorStrc;
const D2DrlgFileStrc = s.D2DrlgFileStrc;
const D2DrlgGridStrc = s.D2DrlgGridStrc;
const D2DrlgGridTileDataStrc = DrlgGrid.D2DrlgGridTileDataStrc;
const D2LvlSubTxt = tables.D2LvlSubTxt;

// InitializeDrlgFile overlay decode (TileSub.cpp:32, 1.14d 006704e0)
//
// The recon reinterprets the D2LvlSubTxt record AS a D2PoolManagerStrc
// (`gridInitCtx.pMemory = (D2PoolManagerStrc*)pLvlSubTxtRecord`) and derives each
// grid by BYTE-addressing into that overlay. Decoded against the actual layouts
// (Fog/D2PoolManagerStrc.h: pPools[40] @0x20, each D2PoolStrc 0x30; pSync is a
// CRITICAL_SECTION with LockCount@+4 / RecursionCount@+8 / SpinCount@+0x14;
// pBlocks@+0x28) the overlay offsets land EXACTLY on the D2LvlSubTxt grid fields
// (Drlg.h:263):
//   &pPools[1].pSync.LockCount       = 0x20+1*0x30+0x04 = 0x54  = &pTileTypeGrid[0]
//   &pPools[3].pSync.RecursionCount  = 0x20+3*0x30+0x08 = 0xB8  = &pWallGrid[1]
//   &pPools[4].pSync.SpinCount       = 0x20+4*0x30+0x14 = 0xF4  = &pFloorGrid
//   &pPools[4].pBlocks               = 0x20+4*0x30+0x28 = 0x108 = &pShadowGrid
// `pGrid + 4` (4 grids = 0x50B) from &pTileTypeGrid[0] = &pWallGrid[0]. The
// `pTileTypeLayer + nWallLayerIdx - 0xc/-0x1c` reads decode (pTileTypeLayer@0x1c,
// pWallLayer@0x2c in D2DrlgFileStrc) to pWallLayer[i] / pTileTypeLayer[i]. So the
// overlay is just named-field access; no 32-bit ABI dependence in the standalone.

/// Core of InitializeDrlgFile, split out so the overlay decode can be unit-tested
/// with a hand-built D2DrlgFileStrc (independent of the DS1 loader). Initializes
/// the LvlSub record's per-wall-layer tile-type/wall grids + floor + shadow grids
/// from the loaded DrlgFile's cell layers.
pub fn initGridsFromDrlgFile(pLvlSub: *D2LvlSubTxt, pDrlgFile: *D2DrlgFileStrc) void {
    const nGridWidth: i32 = pDrlgFile.nWidth + 1;
    var ctx: D2DrlgGridTileDataStrc = std.mem.zeroes(D2DrlgGridTileDataStrc);
    ctx.nX = 0;
    ctx.nY = 0;
    ctx.nWidth = @intCast(nGridWidth);
    ctx.nHeight = @intCast(pDrlgFile.nHeight + 1);

    if (pDrlgFile.nSubstGroups == 0) {
        // recon: Fog::ErrorManager::ERROR_UnrecoverableInternalError_Halt (line 0x2b6)
        @panic("InitializeDrlgFile: DrlgFile has no substitution groups");
    }

    // Wall layers: per layer init pWallGrid[i] (from pWallLayer[i]) and
    // pTileTypeGrid[i] (from pTileTypeLayer[i]).
    var i: i32 = 0;
    while (i < pDrlgFile.nWallLayers) : (i += 1) {
        const li: usize = @intCast(i);
        DrlgGrid.initGridFromTileData(
            null,
            &pLvlSub.pWallGrid[li],
            @ptrCast(@alignCast(pDrlgFile.pWallLayer[li])),
            &ctx,
            nGridWidth,
        );
        DrlgGrid.initGridFromTileData(
            null,
            &pLvlSub.pTileTypeGrid[li],
            @ptrCast(@alignCast(pDrlgFile.pTileTypeLayer[li])),
            &ctx,
            nGridWidth,
        );
    }

    // AlterAllGridFlags over wall grids 1..nWallLayers-1: stamp the layer index
    // into bits 18+ (recon `nWallLayerIdx << 0x12`).
    var j: i32 = 1;
    while (j < pDrlgFile.nWallLayers) : (j += 1) {
        DrlgGrid.AlterAllGridFlags(&pLvlSub.pWallGrid[@intCast(j)], j << 0x12, 0);
    }

    if (pDrlgFile.nFloorLayers != 0) {
        DrlgGrid.initGridFromTileData(
            null,
            &pLvlSub.pFloorGrid,
            @ptrCast(@alignCast(pDrlgFile.pFloorLayer[0])),
            &ctx,
            nGridWidth,
        );
    }

    if (pDrlgFile.pShadowLayer != null) {
        DrlgGrid.initGridFromTileData(
            null,
            &pLvlSub.pShadowGrid,
            @ptrCast(@alignCast(pDrlgFile.pShadowLayer)),
            &ctx,
            nGridWidth,
        );
    }
}

/// TileSub.cpp:32 (1.14d 006704e0). Loads the LvlSub record's DrlgFile (DT1/DS1)
/// then initializes its substitution grids. Idempotent: returns if already loaded.
pub fn InitializeDrlgFile(pMemory: ?*s.D2PoolManagerStrc, pLvlSub: *D2LvlSubTxt) void {
    if (pLvlSub.pDrlgFile != null) {
        return;
    }
    preset.AllocDrlgFile(&pLvlSub.pDrlgFile, pMemory, std.mem.sliceTo(&pLvlSub.File, 0));
    const pDrlgFile = pLvlSub.pDrlgFile orelse return;
    // Harness degrade: not every LvlSub substitution DS1 is extracted in the repo
    // dataset (see preset.fillDrlgFileFromDs1 note). A zeroed file (nSubstGroups==0)
    // means the asset is absent — skip grid init; DRLGOUTDOOR_ApplySubstitutionGroup
    // then no-ops without a seed draw. The engine ERROR_Halts here (initGridsFrom-
    // DrlgFile, recon line 0x2b6), which is unreachable once the asset is present.
    if (pDrlgFile.nSubstGroups == 0) return;
    initGridsFromDrlgFile(pLvlSub, pDrlgFile);
}

/// TileSub.cpp:91 (1.14d 00670750). Faithful. Iterates consecutive LvlSub rows
/// whose Type matches nLvlSubId. (Note: do-while reads (record+1).Type AFTER the
/// post-increment — preserved.)
pub fn AddSecondaryBorder(pUnkOutdoor: [*c]D2UnkOutdoorStrc) void {
    var pLvlSubTxtRecord = tables.lvlSubGetLineFromSubType(pUnkOutdoor.*.nLvlSubId);
    if (pLvlSubTxtRecord.*.Type != pUnkOutdoor.*.nLvlSubId) {
        return;
    }

    while (true) {
        const pMemory = pUnkOutdoor.*.pLevel.?.pDrlg.?.pDS1MemPool;
        const pRec: *D2LvlSubTxt = @ptrCast(pLvlSubTxtRecord);
        InitializeDrlgFile(pMemory, pRec);
        OutSub.applySubstitutionGroup(@ptrCast(pUnkOutdoor), pRec);
        pLvlSubTxtRecord += 1;
        if (!(pLvlSubTxtRecord.*.Type == pUnkOutdoor.*.nLvlSubId)) break;
    }
}

// Unit test: overlay decode (no DS1 loader)
test "initGridsFromDrlgFile decodes the LvlSub grid overlay to named fields" {
    const t = std.testing;
    // A 2x2 DS1 with one wall layer + one floor layer + a shadow layer. Layer
    // cell arrays are (nWidth+1)*(nHeight+1) per ParsePresetsOfDrlgFile (Preset.cpp).
    const W = 2;
    const H = 2;
    const stride = W + 1;
    const cells = (W + 1) * (H + 1);
    var wall: [cells]i32 = undefined;
    var tiletype: [cells]i32 = undefined;
    var floor: [cells]i32 = undefined;
    var shadow: [cells]i32 = undefined;
    for (0..cells) |k| {
        wall[k] = @intCast(k + 1);
        tiletype[k] = @intCast(k + 100);
        floor[k] = @intCast(k + 200);
        shadow[k] = @intCast(k + 300);
    }

    var file: D2DrlgFileStrc = std.mem.zeroes(D2DrlgFileStrc);
    file.nWidth = W;
    file.nHeight = H;
    file.nWallLayers = 1;
    file.nFloorLayers = 1;
    file.nSubstGroups = 1;
    file.pWallLayer[0] = @ptrCast(&wall);
    file.pTileTypeLayer[0] = @ptrCast(&tiletype);
    file.pFloorLayer[0] = @ptrCast(&floor);
    file.pShadowLayer = @ptrCast(&shadow);

    var sub: D2LvlSubTxt = std.mem.zeroes(D2LvlSubTxt);
    initGridsFromDrlgFile(&sub, &file);

    // Each grid views its layer array with stride (nWidth+1), dims (nWidth+1)x(nHeight+1).
    try t.expectEqual(@as(i32, stride), sub.pWallGrid[0].nWidth);
    try t.expectEqual(@as(i32, H + 1), sub.pWallGrid[0].nHeight);
    try t.expectEqual(@as(i32, 1), sub.pWallGrid[0].bIsSubGrid);
    // GetGridFlags(grid, nX, nY) reads pCellsFlags[pCellsRowOffsets[nY]+nX].
    try t.expectEqual(@as(i32, 1), DrlgGrid.GetGridFlags(&sub.pWallGrid[0], 0, 0));
    try t.expectEqual(@as(i32, 100), DrlgGrid.GetGridFlags(&sub.pTileTypeGrid[0], 0, 0));
    try t.expectEqual(@as(i32, 200), DrlgGrid.GetGridFlags(&sub.pFloorGrid, 0, 0));
    try t.expectEqual(@as(i32, 300), DrlgGrid.GetGridFlags(&sub.pShadowGrid, 0, 0));
}
