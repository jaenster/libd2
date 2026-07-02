//! Act-2 OUTDOOR placement tail (recon/closure/OutDesr.cpp,
//! InitAct2OutdoorLevel @ OutDesr.cpp:265, 1.14d 0067f980).
//!
//! Faithful transform of the per-level Act-2 desert tail: cliffs, exits, fills,
//! ruins, tomb entries, secondary borders, waypoints, shrines. Field access by
//! NAME; RNG via the verified selector (rng.zig); the substitution + spawn
//! machinery lives in OutSub.zig / OutPlace.zig / Outdoors.zig. The interleave
//! ORDER per level matches the recon switch exactly so the level seed stays in
//! lock-step with the engine.

const std = @import("std");
const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const tables = @import("../tables.zig");
const DrlgGrid = @import("../DrlgGrid.zig");
const OutPlace = @import("OutPlace.zig");
const Border = @import("Border.zig");
const Outdoors = @import("Outdoors.zig");

const W = s.D2DrlgLevelDataWildernessLevel;

inline fn wild(pLevel: [*c]s.D2DrlgLevelStrc) *W {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
}

// PlacePresetVariants   OutDesr.cpp:34 (1.14d 0067f470)
// Rolls ONE variant index off pLevel->sSeed (RANDOM_RandomNumberSelector), then
// spawns each variant once round-robin starting at the rolled index. bIterateFiles
// spawns every File row of each variant; otherwise spawns the variant with file -1
// (file-tracker draw). The recon's TXT_LvlPrest_GetLine(ids[idx]) lookup before the
// loop has no seed effect; only the per-variant Files count is read here.
fn PlacePresetVariants(pLevel: [*c]s.D2DrlgLevelStrc, pLevelPrestIds: []const i32, bIterateFiles: bool) void {
    const nVariants: i32 = @intCast(pLevelPrestIds.len);
    var nRandVariantIdx: i32 = 0;
    if (nVariants >= 1) {
        nRandVariantIdx = @bitCast(rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nVariants)));
    }
    if (nVariants <= 0) return;

    var nIterCountdown: i32 = nVariants;
    while (true) {
        const idx: usize = @intCast(nRandVariantIdx);
        if (!bIterateFiles) {
            _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, pLevelPrestIds[idx], -1, 0, 0xf);
        } else {
            const pLvlPrest = tables.lvlPrestGetLine(pLevelPrestIds[idx]);
            const nFileCount = pLvlPrest.*.Files;
            var nFileIdx: i32 = 0;
            while (nFileIdx < nFileCount) : (nFileIdx += 1) {
                _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, pLevelPrestIds[idx], nFileIdx, 0, 0xf);
            }
        }
        nRandVariantIdx = @rem(nRandVariantIdx + 1, nVariants);
        nIterCountdown -= 1;
        if (nIterCountdown == 0) break;
    }
}

// DRLGOUTPLACE_PlaceAct2CanyonExitPresets   OutDesr.cpp:85 (1.14d 0067f560)
// Walks the level's inter-level orth list for the link to the Lut Gholein town
// (level 0x28); the recon's pRoomEx[1].apTiles[0x1f] deref is the linked level id
// read through the orth union (pRoomEx = D2DrlgLevelStrc* when nType==0, set in
// AllocDrlgOrth). Places the canyon exit on the side facing town. No seed.
fn PlaceAct2CanyonExitPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData = wild(pLevel);
    var pOrth = pData.pOrthData;
    while (pOrth) |o| {
        const pLinked: ?*s.D2DrlgLevelStrc = @ptrCast(@alignCast(o.pRoomEx));
        if (pLinked != null and pLinked.?.eD2LevelId == .LutGholein) break;
        pOrth = o.pNext;
    }
    const o = pOrth orelse return;
    if (o.neDrlgDirection == 3) { // DIRECTION_NORTHWEST
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, pData.nGridCoordsHeight - 1, 0x16b, -1, 0);
        return;
    }
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, pData.nGridCoordsWidth - 1, 0, 0x16a, -1, 0);
}

// PlaceCliffs   OutDesr.cpp:109 (1.14d 0067f5c0)
// Rolls one seed, picks one of 8 cliff record-groups by (seedLow & 7), then spawns
// the group's 5 preset records. Table = gaCliffWallGridOffsets .rdata @0x006f2390
// (base; symbol gaCliffWallGridOffsets @0x6f239c is the first p[0]). 8 groups x 5
// records x {presetId, fileIdx, posX, posY}. (recovered from Ghidra 1.14d.)
fn PlaceCliffs(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const nSeedLow = rng.RollRandomSeed(&pLevel.*.sSeed);
    const group: usize = @intCast(@as(u32, @bitCast(nSeedLow)) & 7);
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        const b = group * 20 + r * 4;
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, gaCliffTable[b + 2], gaCliffTable[b + 3], gaCliffTable[b + 0], gaCliffTable[b + 1], 0);
    }
}

// AddExits   OutDesr.cpp:126 (1.14d 0067f670)
fn AddExits(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const nExitPresetId: i32 = switch (pLevel.*.eD2LevelId) {
        .RockyWaste, .DryHills => 0x184,
        .FarOasis => 0x186,
        .LostCity => 0x19c,
        .ValleyofSnakes => 0x185,
        else => return,
    };
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nExitPresetId, -1, 0, 0xf);
}

// Place fills/ruins   OutDesr.cpp:164..261
fn PlaceFillsInRockyWaste(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const ids = [_]i32{ 395, 0x19b, 0x191, 0x192, 399, 0x18e, 0x193 };
    PlacePresetVariants(pLevel, &ids, false);
}
fn PlaceFillsInDryHills(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const ids = [_]i32{ 404, 0x195, 0x196, 0x197, 0x18b, 0x19b, 400, 0x18e };
    PlacePresetVariants(pLevel, ids[4..8], false);
    PlacePresetVariants(pLevel, ids[0..4], true);
}
fn PlaceFillsInFarOasis(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const ids = [_]i32{ 411, 399, 398, 403 };
    const bonus = [_]i32{395};
    PlacePresetVariants(pLevel, &ids, false);
    PlacePresetVariants(pLevel, &bonus, true);
    PlacePresetVariants(pLevel, &bonus, true);
}
fn PlaceRuinsInLostCity(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const ids = [_]i32{ 413, 0x198, 0x199, 0x19a };
    PlacePresetVariants(pLevel, &ids, false);
}
fn PlaceFillsInLostCity(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const ids = [_]i32{ 395, 400, 0x18e, 0x194, 0x195, 0x19b };
    PlacePresetVariants(pLevel, ids[0..5], false);
    PlacePresetVariants(pLevel, ids[5..6], true);
    PlacePresetVariants(pLevel, ids[5..6], true);
}
fn PlaceFillsInCanyon(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const ids = [_]i32{ 401, 0x192, 0x196, 0x197, 0x193, 0x188, 0x189 };
    PlacePresetVariants(pLevel, ids[0..5], false);
    PlacePresetVariants(pLevel, ids[5..7], true);
}

// PlaceTombEntriesInCanyon   OutDesr.cpp:235 (1.14d 0067f8d0)
// Fixed 9-record placement (no seed) from gaTombCanyonPresetOffsets .rdata
// @0x006f2610 (base; symbol @0x6f261c is the first p[0]; loop exits at 0x6f26ac).
// Same {presetId, fileIdx, posX, posY} record layout. Then a fixed 0x18a preset.
fn PlaceTombEntriesInCanyon(pLevel: [*c]s.D2DrlgLevelStrc) void {
    var r: usize = 0;
    while (r < 9) : (r += 1) {
        const b = r * 4;
        OutPlace.SpawnOutdoorLevelPresetEx(pLevel, gaTombTable[b + 2], gaTombTable[b + 3], gaTombTable[b + 0], gaTombTable[b + 1], 0);
    }
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 4, 4, 0x18a, -1, 0);
}

// InitAct2OutdoorLevel   OutDesr.cpp:265 (1.14d 0067f980)
pub fn InitAct2OutdoorLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    Border.SetOutGridLinkFlags(pLevel);
    Border.PlaceAct1245OutdoorBorders(pLevel);
    switch (pLevel.*.eD2LevelId) {
        .RockyWaste => {
            PlaceAct2CanyonExitPresets(pLevel);
            Outdoors.AddAct124SecondaryBorderSubId213(pLevel);
            AddExits(pLevel);
            Outdoors.SpawnAct12Shrines(pLevel, 5);
            PlaceFillsInRockyWaste(pLevel);
        },
        .DryHills => {
            PlaceCliffs(pLevel);
            Outdoors.AddAct124SecondaryBorderSubId213(pLevel);
            AddExits(pLevel);
            Outdoors.SpawnAct12Waypoint(pLevel);
            Outdoors.SpawnAct12Shrines(pLevel, 5);
            PlaceFillsInDryHills(pLevel);
        },
        .FarOasis => {
            PlaceCliffs(pLevel);
            Outdoors.AddAct124SecondaryBorderSubId213(pLevel);
            AddExits(pLevel);
            const ids = [_]i32{ 396, 0x18d };
            PlacePresetVariants(pLevel, &ids, false);
            Outdoors.SpawnAct12Waypoint(pLevel);
            Outdoors.SpawnAct12Shrines(pLevel, 5);
            PlaceFillsInFarOasis(pLevel);
        },
        .LostCity => {
            PlaceCliffs(pLevel);
            Outdoors.AddAct124SecondaryBorderSubId213(pLevel);
            AddExits(pLevel);
            PlaceRuinsInLostCity(pLevel);
            Outdoors.SpawnAct12Waypoint(pLevel);
            Outdoors.SpawnAct12Shrines(pLevel, 5);
            PlaceFillsInLostCity(pLevel);
        },
        .ValleyofSnakes => AddExits(pLevel),
        .CanyonofMagic => {
            PlaceTombEntriesInCanyon(pLevel);
            Outdoors.AddAct124SecondaryBorderSubId213(pLevel);
            Outdoors.SpawnAct12Shrines(pLevel, 5);
            PlaceFillsInCanyon(pLevel);
        },
        .ForgottenSands => {
            OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 4, 4, 0x18a, -1, 0);
            Outdoors.AddAct124SecondaryBorderSubId213(pLevel);
            PlaceFillsInCanyon(pLevel);
            Outdoors.SpawnAct12Shrines(pLevel, 5);
        },
        else => {},
    }
}

// gaCliffTable — gaCliffWallGridOffsets .rdata base @0x006f2390, 8 groups x 5
// records x {presetId, fileIdx, posX, posY} (160 int32, Ghidra 1.14d).
const gaCliffTable = [160]i32{
    376, 1,  0, 4,  378, -1, 2, 4,  377, -1, 4, 4,  377, -1, 6, 4,  376, 2, 8, 4,
    376, 1,  0, 4,  377, -1, 2, 4,  378, -1, 4, 4,  377, -1, 6, 4,  376, 2, 8, 4,
    376, 1,  0, 4,  377, -1, 2, 4,  377, -1, 4, 4,  378, -1, 6, 4,  376, 2, 8, 4,
    376, 2,  8, 4,  377, -1, 6, 4,  382, -1, 4, 4,  381, -1, 4, 6,  379, 2, 4, 8,
    376, 2,  8, 4,  378, -1, 6, 4,  382, -1, 4, 4,  380, -1, 4, 6,  379, 2, 4, 8,
    379, 1,  4, 0,  381, -1, 4, 2,  380, -1, 4, 4,  380, -1, 4, 6,  379, 2, 4, 8,
    379, 1,  4, 0,  380, -1, 4, 2,  381, -1, 4, 4,  380, -1, 4, 6,  379, 2, 4, 8,
    379, 1,  4, 0,  380, -1, 4, 2,  380, -1, 4, 4,  381, -1, 4, 6,  379, 2, 4, 8,
};

// gaTombTable — gaTombCanyonPresetOffsets .rdata base @0x006f2610, 9 records x
// {presetId, fileIdx, posX, posY} (36 int32, Ghidra 1.14d).
const gaTombTable = [36]i32{
    384, 0, 8, 0,  383, 2, 6, 0,  383, 1, 4, 0,  383, 0, 2, 0,  387, 0, 0, 0,
    385, 0, 0, 2,  385, 1, 0, 4,  385, 2, 0, 6,  386, 0, 0, 8,
};
