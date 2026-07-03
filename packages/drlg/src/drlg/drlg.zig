//! Mechanical transform of the TOP DRLG orchestration in
//! recon/closure/Drlg.cpp (+ the two type-init helpers in Preset.cpp / Maze.cpp).
//! Faithful by construction: field access by NAME, RNG -> rng.zig, allocs -> pool.zig,
//! tables -> tables.zig, the per-level generators -> the maze/preset modules.
//!
//! Transformed (cite recon Drlg.cpp unless noted):
//!   DRLG_ApplyRoomExStateFlags                   Drlg.cpp:349
//!   DRLGWARP_InitLevelWarpCoordinates            Drlg.cpp:374
//!   InitLevel                                    Drlg.cpp:431  (the type dispatch)
//!   DRLGLEVEL_SetLevelSizeAndAlignVsDependentLevel  Drlg.cpp:935
//!   DRLGACTMISC_AllocDrlgLevel                   Drlg.cpp:797
//!   GetLevelAndAlloc                             Drlg.cpp:838
//!   DRLG_AllocDrlgActMisc                        Drlg.cpp:968
//!   DRLGMAZE_InitializeLevel                     Maze.cpp:1221
//!   DRLGLEVEL_InitializeWithPresetArea           Preset.cpp:1489
//!   DRLGPRESET_InitializeRoomEx                  Preset.cpp:2077
//!
//! STUBBED (runtime subsystems irrelevant to DRLG room layout, or not done):
//!   DRLGACTMISC_LoadTileProjects / InitializeSubA0  (DT1 load + activation queue)
//!   DRLGACTMISC_AllocDrlgLevelForAct                (outdoor inter-level placement)
//!   DRLGLEVEL_InitializeWithWildernessLevel / GenerateLevel (type 3 wilderness)

const std = @import("std");
const s = @import("structs.zig");
const rng = @import("rng.zig");
const pool = @import("pool.zig");
const tables = @import("tables.zig");
const Maze = @import("maze/Maze.zig");
const mdeps = @import("maze/deps.zig");
const preset = @import("preset.zig");
const DrlgRoom = @import("DrlgRoom.zig");
const DrlgWarp = @import("DrlgWarp.zig");
const actmod = @import("../act.zig");
const acttbl = @import("../tables.zig");
const Transform = @import("Transform.zig");
const Outdoors = @import("outdoors/Outdoors.zig");

const D2SeedStrc = s.D2SeedStrc;
const eD2LevelId = s.eD2LevelId;

const LEVEL_None: eD2LevelId = .None;
const ACT_I: u8 = 0;
const ACT_II: u8 = 1;
const ACT_III: u8 = 2;
const ACT_IV: u8 = 3;
const ACT_V: u8 = 4;

// eD2DrlgType from LevelDefs.txt DrlgType: 1=Maze, 2=Preset, 3=Wilderness.

/// The 8-byte preset-level data block (D2DrlgLevelDataPresetArea): pDrlgMap +
/// nPickedFile. The recon reads it as uint*[0]/[1]; here it is a named struct.
pub const D2DrlgLevelDataPresetArea = extern struct {
    pDrlgMap: ?*s.D2DrlgMapStrc,
    nPickedFile: i32,
};

/// Faithful DRLGLEVEL_ParseLevelData pass-2 preset overrides for Act I (1.14d
/// 006772c0): both write a PresetArea level's nPickedFile from a placement
/// direction, overwriting the InitializeWithPresetArea selector pick.
///   - Rogue Encampment (town, level 1): nPickedFile = its own placement dir, so
///     the town faces Blood Moor (the neighbour it was placed against).
///   - Outer Cloister (Courtyard, level 0x1b): jail-exit variant (only for a
///     Black-Marsh placement dir of 1 or 3) that also drives the Barracks layout.
/// The picks recompute the placement independently from `tb`/`seed`, matching the
/// pristine ACT_I placement seed the engine copies into its private state.
pub fn applyAct1PresetPicks(pDrlg: [*c]s.D2DrlgStrc, tb: *const acttbl.Tables, seed: u32) void {
    const pTown = GetLevelAndAlloc(pDrlg, .RogueEncampment);
    if (pTown.pDrlgLevelData) |pd| {
        const pp: *D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
        pp.nPickedFile = actmod.act1TownPick(tb, seed);
    }
    if (actmod.act1CourtyardPick(tb, seed)) |pick| {
        const pCourt = GetLevelAndAlloc(pDrlg, .OuterCloister);
        if (pCourt.pDrlgLevelData) |pd| {
            const pp: *D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
            pp.nPickedFile = pick;
        }
    }
}

/// Faithful DRLGLEVEL_ParseLevelData pass-2 preset override for Act II (1.14d
/// 006772c0, `eD2LevelId == 0x28` branch): Lut Gholein's nPickedFile is taken from
/// aCurrentDir[node+1] (the placement direction of Rocky Waste, placed after the
/// town), overwriting the InitializeWithPresetArea selector pick. That selects the
/// town DS1 (File2=LutW / File3=LutN) and the AUTOMAP_RevealTownCallback sprite half.
pub fn applyAct2PresetPicks(pDrlg: [*c]s.D2DrlgStrc, tb: *const acttbl.Tables, seed: u32) void {
    const pTown = GetLevelAndAlloc(pDrlg, .LutGholein);
    if (pTown.pDrlgLevelData) |pd| {
        const pp: *D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
        pp.nPickedFile = actmod.act2TownPick(tb, seed);
    }
}

// DRLG_ApplyRoomExStateFlags — Drlg.cpp:349 (1.14d 00642390)
pub fn applyRoomExStateFlags(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (!(pLevel.*.nRoomExCount != 0 and pLevel.*.pRoomExStateFlags != null)) return;
    var pRoomEx: ?*s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    if (pRoomEx == null) return;
    var stateFlagOffset: usize = 0;
    while (true) {
        const pStateFlag: [*c]i32 = @ptrFromInt(@intFromPtr(pLevel.*.pRoomExStateFlags) + stateFlagOffset);
        stateFlagOffset += 4;
        if (pStateFlag.* != 0) pRoomEx.?.dwOtherFlags |= 1;
        pRoomEx = pRoomEx.?.pRoomExNext;
        if (pRoomEx == null) break;
    }
}

// DRLGWARP_InitLevelWarpCoordinates — Drlg.cpp:374 (1.14d 006423d0)
// Pure post-processing (no RNG): fills sWarpCoordinates from warp-flagged rooms.
// Locals 0-initialised to avoid the Ghidra uninitialised-read artifacts.
pub fn initLevelWarpCoordinates(pLevel: [*c]s.D2DrlgLevelStrc) void {
    var pRoomEx: ?*s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    var foundWarpRoom = false;
    while (true) {
        if (pRoomEx == null) return;
        const flags: u32 = @bitCast(pRoomEx.?.eRoomExFlags);
        if (flags & 0x30000 != 0) foundWarpRoom = true;

        var doEmit = false;
        if (flags & 0xff0 == 0) {
            if (foundWarpRoom) doEmit = true;
        } else if (foundWarpRoom) {
            doEmit = true;
        } else {
            var roomFlagMask: u32 = 0x10;
            var warpIndex: u8 = 0;
            while (true) {
                if (flags & roomFlagMask != 0) {
                    const dest = DrlgWarp.getWarpDestinationFromArray(pLevel, warpIndex);
                    if (dest != -1) {
                        doEmit = true;
                        break;
                    }
                }
                roomFlagMask *%= 2;
                warpIndex +%= 1;
                if (roomFlagMask & 0xff0 == 0) break;
            }
        }

        if (doEmit) {
            const wc: *s.D2DrlgLevelWarpCoordinatesStrc = @ptrCast(&pLevel.*.sWarpCoordinates);
            const idx: usize = @intCast(wc.nEntriesCount);
            if (idx >= wc.anX.len) return; // engine's fixed warp-coord cache cap
            var x: i32 = @divTrunc(pRoomEx.?.sCoords.WorldSize.x, 2) + pRoomEx.?.sCoords.WorldPosition.x;
            var y: i32 = @divTrunc(pRoomEx.?.sCoords.WorldSize.y, 2) + pRoomEx.?.sCoords.WorldPosition.y;
            Transform.CoordsRoomToWorld(&x, &y);
            wc.anX[idx] = x;
            wc.anY[idx] = y;
            wc.nEntriesCount += 1;
            foundWarpRoom = false;
        }

        pRoomEx = pRoomEx.?.pRoomExNext;
    }
}

// InitLevel — Drlg.cpp:431 (1.14d 006424a0)
// The per-level dispatch by eDrlgType. (Ghidra artifact noted in recon: the
// original test was `drlgType == 1`, not `drlgType`.)
pub fn InitLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    pLevel.*.sSeed.nSeedLow = @bitCast(pLevel.*.pDrlg.?.dwStartSeed +% @as(u32, @bitCast(@intFromEnum(pLevel.*.eD2LevelId))));
    pLevel.*.sSeed.nSeedHigh = 0x29a;
    const drlgType = pLevel.*.eDrlgType;
    if (drlgType == .maze) {
        _ = Maze.generateLevel(pLevel);
    } else if (drlgType == .preset) {
        initializeRoomEx(pLevel);
        applyRoomExStateFlags(pLevel);
        initLevelWarpCoordinates(pLevel);
        return;
    } else if (drlgType == .wilderness) {
        Outdoors.generateLevel(pLevel);
        applyRoomExStateFlags(pLevel);
        initLevelWarpCoordinates(pLevel);
        return;
    }
    applyRoomExStateFlags(pLevel);
    initLevelWarpCoordinates(pLevel);
}

// DRLGLEVEL_SetLevelSizeAndAlignVsDependentLevel — Drlg.cpp:935 (00642d10)
pub fn setLevelSizeAndAlignVsDependentLevel(pDrlg: [*c]s.D2DrlgStrc, pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pLevelDef = tables.levelDefsGetLine(pLevel.*.eD2LevelId);
    const nDependLevelId: eD2LevelId = @enumFromInt(pLevelDef.*.Depend);
    const diff: usize = @intCast(pDrlg.*.nDifficulty);
    const szx: [3]i32 = pLevelDef.*.SizeX;
    const szy: [3]i32 = pLevelDef.*.SizeY;
    pLevel.*.sCoordinatesAndSize.WorldSize.x = szx[diff];
    pLevel.*.sCoordinatesAndSize.WorldSize.y = szy[diff];
    var nRealOffsetX: i32 = 0;
    var nRealOffsetY: i32 = 0;
    if (nDependLevelId != .None) {
        var pLevelDepend: ?*s.D2DrlgLevelStrc = pDrlg.*.pLevel;
        var found = false;
        while (pLevelDepend) |pd| : (pLevelDepend = pd.pLevelNext) {
            if (pd.eD2LevelId == nDependLevelId) {
                found = true;
                break;
            }
        }
        const dep = if (found) pLevelDepend.? else allocDrlgLevel(pDrlg, nDependLevelId);
        nRealOffsetX = dep.sCoordinatesAndSize.WorldPosition.x;
        nRealOffsetY = dep.sCoordinatesAndSize.WorldPosition.y;
    }
    pLevel.*.sCoordinatesAndSize.WorldPosition.x = pLevelDef.*.OffsetX + nRealOffsetX;
    pLevel.*.sCoordinatesAndSize.WorldPosition.y = pLevelDef.*.OffsetY + nRealOffsetY;
}

// DRLGMAZE_InitializeLevel — Maze.cpp:1221 (006739c0)
// Sets pDrlgLevelData = the LvlMaze row, then aligns. We COPY the row (the shared
// table row must not be mutated across levels/seeds).
fn initializeLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pLvlMazeTxt = tables.lvlMazeFindLineByLevelId(pLevel.*.eD2LevelId);
    const copy: [*c]tables.D2LvlMazeTxt = @ptrCast(@alignCast(pool.AllocServerMemory(
        pLevel.*.pDrlg.?.pMemoryPool,
        @sizeOf(tables.D2LvlMazeTxt),
        ".\\DRLG\\Maze.cpp",
        0x4b3,
    )));
    copy.* = pLvlMazeTxt.*;
    pLevel.*.pDrlgLevelData = copy;
    setLevelSizeAndAlignVsDependentLevel(pLevel.*.pDrlg, pLevel);
}

// DRLGLEVEL_InitializeWithPresetArea — Preset.cpp:1489 (006674a0)
fn initializeWithPresetArea(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData: *D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pool.AllocServerMemory(
        pLevel.*.pDrlg.?.pMemoryPool,
        @sizeOf(D2DrlgLevelDataPresetArea),
        ".\\DRLG\\Preset.cpp",
        0xaf9,
    )));
    const pLvlPrest = tables.lvlPrestFindLineByLevelId(pLevel.*.eD2LevelId);
    pLevel.*.pDrlgLevelData = pData;
    pData.pDrlgMap = null;
    pData.nPickedFile = 0;
    if (pLvlPrest != null and pLvlPrest.*.Files != 0) {
        const nRandomFile = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(pLvlPrest.*.Files));
        pData.nPickedFile = @bitCast(nRandomFile);
        setLevelSizeAndAlignVsDependentLevel(pLevel.*.pDrlg, pLevel);
        return;
    }
    pData.nPickedFile = -1;
    setLevelSizeAndAlignVsDependentLevel(pLevel.*.pDrlg, pLevel);
}

// DRLGPRESET_InitializeRoomEx — Preset.cpp:2077 (006681b0)
// Type-2 InitLevel arm: roll the map file, then BuildArea tiles the preset.
fn initializeRoomEx(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pData: *D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
    const pLvlPrest = tables.lvlPrestFindLineByLevelId(pLevel.*.eD2LevelId);
    const pDrlgMap = preset.allocDrlgMap(
        pLevel,
        pLvlPrest.*.Def,
        @ptrCast(&pLevel.*.sCoordinatesAndSize),
        &pLevel.*.sSeed,
    );
    pData.pDrlgMap = pDrlgMap;
    if (pData.nPickedFile == -1) {
        pData.nPickedFile = pDrlgMap.*.nRandomMapFileSelector;
    } else {
        pDrlgMap.*.nRandomMapFileSelector = pData.nPickedFile;
    }
    _ = preset.BuildArea(pLevel, pDrlgMap, 0, 0);
    // autoMap callbacks omitted (pfAutoMap/pfTownAutoMap are null in headless gen).
}

// DRLGACTMISC_AllocDrlgLevel — Drlg.cpp:797 (00642ae0)
pub fn allocDrlgLevel(pDrlg: [*c]s.D2DrlgStrc, eLevel: eD2LevelId) *s.D2DrlgLevelStrc {
    const pLevel: *s.D2DrlgLevelStrc = @ptrCast(@alignCast(pool.AllocServerMemory(
        pDrlg.*.pMemoryPool,
        @sizeOf(s.D2DrlgLevelStrc),
        ".\\DRLG\\Drlg.cpp",
        0x1a8,
    )));
    @memset(@as([*]u8, @ptrCast(pLevel))[0..@sizeOf(s.D2DrlgLevelStrc)], 0);
    pLevel.pDrlg = pDrlg;
    pLevel.eD2LevelId = eLevel;
    const pLevelDefs = tables.levelDefsGetLine(eLevel);
    pLevel.nLevelType = pLevelDefs.*.LevelType;
    pLevel.eDrlgType = pLevelDefs.*.DrlgType;
    if (pDrlg.*.dwFlags & 1 != 0) pLevel.dwFlags |= 0x10;
    pLevel.sSeed.nSeedLow = @bitCast(pDrlg.*.dwStartSeed +% @as(u32, @bitCast(@intFromEnum(eLevel))));
    pLevel.sSeed.nSeedHigh = 0x29a;
    switch (pLevel.eDrlgType) {
        .maze => initializeLevel(pLevel),
        .preset => initializeWithPresetArea(pLevel),
        .wilderness => Outdoors.initializeWithWildernessLevel(pLevel),
        else => {},
    }
    pLevel.pLevelNext = pDrlg.*.pLevel;
    pDrlg.*.pLevel = pLevel;
    return pLevel;
}

// GetLevelAndAlloc — Drlg.cpp:838 (00642bb0)
pub fn GetLevelAndAlloc(pDrlg: [*c]s.D2DrlgStrc, eLevelId: eD2LevelId) *s.D2DrlgLevelStrc {
    var pLevel: ?*s.D2DrlgLevelStrc = pDrlg.*.pLevel;
    while (pLevel) |pl| {
        if (pl.eD2LevelId == eLevelId) return pl;
        pLevel = pl.pLevelNext;
    }
    return allocDrlgLevel(pDrlg, eLevelId);
}

// DRLG_AllocDrlgActMisc — Drlg.cpp:968 (00642da0)
// Allocates the act's pDrlg, rolls dwStartSeed, and (Act II) the staff/boss tomb
// levels. The Act II tomb roll uses the 32-bit low word for the %7 (engine
// @0x642e.., not Ghidra's widened 64-bit divide — same modulo-widening artifact
// found in the maze room-pick/merge rolls).
//   DRLGACTMISC_LoadTileProjects / InitializeSubA0 / AllocDrlgLevelForAct are
//   stubbed (DT1 load + activation queue + outdoor placement — not room layout).
pub fn allocDrlgActMisc(
    pDrlg: [*c]s.D2DrlgStrc,
    nActNo: u8,
    dwInitSeed: u32,
    nTownLevelId: eD2LevelId,
    dwFlags: u32,
    nDifficulty: u8,
) *s.D2DrlgStrc {
    @memset(@as([*]u8, @ptrCast(pDrlg))[0..@sizeOf(s.D2DrlgStrc)], 0);
    pDrlg.*.nActNo = nActNo;
    pDrlg.*.nSeed.nSeedLow = @bitCast(dwInitSeed);
    pDrlg.*.nSeed.nSeedHigh = 0x29a;
    var DVar1 = rng.sEEDNEXT(pDrlg.*.nSeed);
    const seedLow = DVar1.nSeedLow;
    pDrlg.*.dwGameLowSeed = dwInitSeed;
    pDrlg.*.dwFlags = dwFlags;
    pDrlg.*.nDifficulty = nDifficulty;
    pDrlg.*.nSeed = DVar1;
    pDrlg.*.dwStartSeed = @bitCast(seedLow);

    if (nActNo == ACT_II) {
        var nStaffLevelOffset: u32 = 0;
        var nBossOffset: u32 = 0;
        while (true) {
            // uSeedProduct = D2_SEED_NEXT(DVar1); nRandVal = its low word.
            const prod = rng.sEEDNEXT(DVar1);
            const nRandVal: u32 = @bitCast(prod.nSeedLow);
            nStaffLevelOffset = nRandVal % 7;
            // DVar1 = D2_SEED_NEXT_VAL(uSeedProduct) = advance once more.
            DVar1 = rng.sEEDNEXT(prod);
            nBossOffset = @as(u32, @bitCast(DVar1.nSeedLow)) % 7;
            if (nStaffLevelOffset != nBossOffset) break;
        }
        pDrlg.*.nSeed = DVar1;
        pDrlg.*.nStaffTombLevel = @enumFromInt(@as(i32, @bitCast(nStaffLevelOffset)) + 0x42);
        pDrlg.*.nBossTombLevel = @enumFromInt(@as(i32, @bitCast(nBossOffset)) + 0x42);
    } else if (nActNo == ACT_III) {
        DVar1 = rng.sEEDNEXT(DVar1);
        pDrlg.*.nSeed = DVar1;
        pDrlg.*.bJungleInterlink = DVar1.nSeedLow & 1;
    }

    // STUB: DRLGACTMISC_LoadTileProjects(pDrlg); InitializeSubA0(pDrlg);
    // STUB: DRLGACTMISC_AllocDrlgLevelForAct(pDrlg, nActNo); (outdoor placement)

    if (nTownLevelId == LEVEL_None) return pDrlg;

    var pLevel: ?*s.D2DrlgLevelStrc = pDrlg.*.pLevel;
    while (pLevel) |pl| {
        if (pl.eD2LevelId == nTownLevelId) {
            InitLevel(pl);
            return pDrlg;
        }
        pLevel = pl.pLevelNext;
    }
    const town = allocDrlgLevel(pDrlg, nTownLevelId);
    InitLevel(town);
    return pDrlg;
}

// Act-level warp graph + inter-level adjacency (orth)
// The wilderness border junctions need pOrthData, which is built by
// DRLGLEVEL_AllocDrlgLevelFromLevelIdToLevelId from the DYNAMIC adjacency stored in
// pDrlg->pWarpsInfo (NOT the static Levels.txt Vis/Warp). That dynamic graph is laid
// down by DRLGLEVEL_ParseLevelData (Drlg.cpp:3813-3826): for each placement-list
// entry it wires its prev/next chain neighbour as a borderless seam (warpId = -1)
// via DRLGACT_AllocWarpsInfo + DRLGACT_SetWarpConnection. The placement RNG only
// sets coordinates (fed from the goldens here), so we replay just the warp-wiring
// topology from the static per-act lists below, then build the orths.

// One placement-list entry — only the fields the warp wiring reads: the level id
// and the SAME-LIST node indices of its prev/next chain neighbours (-1 = none).
// Extracted faithfully from the ACT*_D2DrlgLevelData* initializers in Drlg.cpp
// (3916-4760); the fpLevelDataEntry/placement halves are irrelevant to the graph.
const LevelDataEntry = struct { id: eD2LevelId, prev: i32, next: i32 };

const ACT1_LIST1 = [_]LevelDataEntry{
    .{ .id = .StonyField, .prev = -1, .next = -1 },  .{ .id = .ColdPlains, .prev = 0, .next = -1 },
    .{ .id = .BloodMoor, .prev = 1, .next = -1 },   .{ .id = .RogueEncampment, .prev = 2, .next = -1 },
    .{ .id = .BurialGrounds, .prev = 1, .next = -1 },  .{ .id = .None, .prev = -1, .next = -1 },
};
const ACT1_LIST2 = [_]LevelDataEntry{
    .{ .id = .MooMooFarm, .prev = -1, .next = -1 }, .{ .id = .MonasteryGate, .prev = -1, .next = -1 },
    .{ .id = .TamoeHighland, .prev = 1, .next = -1 },   .{ .id = .BlackMarsh, .prev = 2, .next = -1 },
    .{ .id = .DarkWood, .prev = 3, .next = -1 },   .{ .id = .None, .prev = -1, .next = -1 },
};
const ACT2_LIST1 = [_]LevelDataEntry{
    .{ .id = .LutGholein, .prev = -1, .next = -1 }, .{ .id = .RockyWaste, .prev = 0, .next = -1 },
    .{ .id = .DryHills, .prev = 1, .next = -1 },  .{ .id = .FarOasis, .prev = 2, .next = -1 },
    .{ .id = .LostCity, .prev = 3, .next = -1 },  .{ .id = .ValleyofSnakes, .prev = 4, .next = -1 },
    .{ .id = .None, .prev = -1, .next = -1 },
};
const ACT2_LIST2 = [_]LevelDataEntry{
    .{ .id = .CanyonofMagic, .prev = -1, .next = -1 }, .{ .id = .None, .prev = -1, .next = -1 },
};
const ACT4_LIST1 = [_]LevelDataEntry{
    .{ .id = .PandemoniumFortress, .prev = -1, .next = -1 }, .{ .id = .OuterSteppes, .prev = 0, .next = -1 },
    .{ .id = .PlainsofDespair, .prev = 1, .next = -1 },  .{ .id = .CityoftheDamned, .prev = 2, .next = -1 },
    .{ .id = .None, .prev = -1, .next = -1 },
};
const ACT4_LIST2 = [_]LevelDataEntry{
    .{ .id = .ChaosSanctuary, .prev = -1, .next = -1 }, .{ .id = .None, .prev = -1, .next = -1 },
};
// Act IV (nActNo==3) still wires prev/next warps in ParseLevelData (only Act V skips).
const ALL_LISTS = [_][]const LevelDataEntry{ &ACT1_LIST1, &ACT1_LIST2, &ACT2_LIST1, &ACT2_LIST2, &ACT4_LIST1, &ACT4_LIST2 };

// Inter-level adjacency (orth) ranges per act, from DRLGACTMISC_AllocDrlgLevelForAct
// (Drlg.cpp:4768/4773/4783/4789). Each act calls
// DRLGLEVEL_AllocDrlgLevelFromLevelIdToLevelId(pDrlg, eLevel, nLevelIdStart) over the
// inclusive id span below (LEVEL_* values: LvlTbls / d2_enums.h). Act III's adjacency
// is built inside OutPlace::DRLGActMisc_InitAct3 (a separate outdoors subsystem); Act V
// uses DRLGACT_SetWarpConnectionsBetweenTwoAreas (coordinate-adjacency, not yet wired).
const OrthRange = struct { start: eD2LevelId, end: eD2LevelId };
const ACT_ORTH_RANGES = [_]OrthRange{
    .{ .start = .RogueEncampment, .end = .BurialGrounds }, //  Act I: RogueEncampment..BurialGrounds
    .{ .start = .LutGholein, .end = .CanyonofMagic }, // Act II: LutGholein..CanyonOfTheMagi
    .{ .start = .PandemoniumFortress, .end = .CityoftheDamned }, // Act IV: ThePandemoniumFortress..CityOfTheDamned
    .{ .start = .FrigidHighlands, .end = .ArreatPlateau }, // Act V: FrigidHighlands..ArreatPlateau
};

// DRLGACT_AllocWarpsInfo — Drlg.cpp:648 (1.14d 006428a0)
// Find (by level id) or create the per-level warp-info node, initialising a fresh
// node's nTargetArea/nWarpId from the static Levels.txt Vis/Warp columns.
fn allocWarpsInfo(pDrlg: [*c]s.D2DrlgStrc, eLevel: eD2LevelId) *s.D2DrlgActWarpsInfoStrc {
    var pExisting: ?*s.D2DrlgActWarpsInfoStrc = pDrlg.*.pWarpsInfo;
    while (pExisting) |pe| {
        if (pe.nLevelId == eLevel) return pe;
        pExisting = pe.pNext;
    }
    const pLevelDefs = tables.levelDefsGetLine(eLevel);
    const pInfo: *s.D2DrlgActWarpsInfoStrc = @ptrCast(@alignCast(pool.AllocServerMemory(
        pDrlg.*.pMemoryPool,
        @sizeOf(s.D2DrlgActWarpsInfoStrc),
        ".\\DRLG\\Drlg.cpp",
        0x3e0,
    )));
    pInfo.nLevelId = eLevel;
    pInfo.nTargetArea = pLevelDefs.*.Vis;
    pInfo.nWarpId = pLevelDefs.*.Warp;
    pInfo.pNext = pDrlg.*.pWarpsInfo;
    pDrlg.*.pWarpsInfo = pInfo;
    return pInfo;
}

// DRLGACT_SetWarpConnection — Drlg.cpp:689 (1.14d 00642920)
// If eLevel already occupies a nTargetArea slot, update its warp id; otherwise (when
// nWarpInfoIndex==-1) drop it into the first slot that is empty (nTargetArea==0) and
// warp-free (nWarpId==-1). The recon's fake-struct walk + pWarpIdPtr[-8..3] reaches
// are just plain index-by-i over the parallel arrays.
fn setWarpConnection(pInfo: *s.D2DrlgActWarpsInfoStrc, eLevel: eD2LevelId, nWarpId: i32, nWarpInfoIndex: i32) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (pInfo.nTargetArea[i] == eLevel) {
            pInfo.nWarpId[i] = nWarpId;
            return;
        }
    }
    var idx = nWarpInfoIndex;
    if (nWarpInfoIndex == -1) {
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            if (pInfo.nTargetArea[k] == .None and pInfo.nWarpId[k] == -1) {
                idx = @intCast(k);
                break;
            }
        }
    }
    pInfo.nTargetArea[@intCast(idx)] = eLevel;
    pInfo.nWarpId[@intCast(idx)] = nWarpId;
}

// The prev/next warp-wiring half of DRLGLEVEL_ParseLevelData (Drlg.cpp:3746-3826),
// stripped of the placement-RNG coordinate assignment (coords come from the goldens).
// Walks the static list in order; for every entry, wires its prev/next chain
// neighbour as a bidirectional borderless seam (warpId = -1). Act V (nActNo==4) skips
// this — it wires adjacency by coordinates (SetWarpConnectionsBetweenTwoAreas).
fn parseLevelDataWarps(pDrlg: [*c]s.D2DrlgStrc, list: []const LevelDataEntry) void {
    if (pDrlg.*.nActNo == ACT_V) return;
    for (list) |entry| {
        const eCur = entry.id;
        if (eCur == .None) break;
        const ePrev: eD2LevelId = if (entry.prev == -1) .None else list[@intCast(entry.prev)].id;
        const eNext: eD2LevelId = if (entry.next == -1) .None else list[@intCast(entry.next)].id;
        _ = GetLevelAndAlloc(pDrlg, eCur);
        if (ePrev != .None) {
            const a = allocWarpsInfo(pDrlg, eCur);
            const b = allocWarpsInfo(pDrlg, ePrev);
            setWarpConnection(a, ePrev, -1, -1);
            setWarpConnection(b, eCur, -1, -1);
        }
        if (eNext != .None) {
            const a = allocWarpsInfo(pDrlg, eCur);
            const b = allocWarpsInfo(pDrlg, eNext);
            setWarpConnection(a, eNext, -1, -1);
            setWarpConnection(b, eCur, -1, -1);
        }
    }
}

// DRLGLEVEL_AllocDrlgLevelFromLevelIdToLevelId — Drlg.cpp:3881 (00677680)
// For each level id in [nLevelIdStart, eLevel] that is a wilderness level
// (eDrlgType==3), walk its 8-entry Vis[]/Warp[] (LevelDefs.txt): every Vis slot
// that is set AND whose parallel Warp slot is -1 is a *borderless* adjacency — a
// wilderness->wilderness seam, not a warp door. Build a level-link orth into the
// wilderness level's pOrthData for it, with the seam direction derived from the
// two levels' world rects. Those orths are what DRLGVER_CreateRoomVertices later
// turns into junction vertices (dwFlags&1) so the border placement knits the seams.
//   The recon's `(D2RoomExStrc*)&pLevelData->pOrthData` aliases the pOrthData head
//   onto a RoomEx whose pOrth field is at offset 0 — faithful in Zig because pOrth
//   IS the first field of D2RoomExStrc. The `nWarpOffset + (int)pVisArray` idiom is
//   the parallel Warp[] element at the same index, so we index both arrays by i.
pub fn allocDrlgLevelFromLevelIdToLevelId(
    pDrlg: [*c]s.D2DrlgStrc,
    eLevel: eD2LevelId,
    nLevelIdStart: eD2LevelId,
) void {
    var nCurI: i32 = @intFromEnum(nLevelIdStart);
    while (nCurI <= @intFromEnum(eLevel)) : (nCurI += 1) {
        const nCur: eD2LevelId = @enumFromInt(nCurI);
        const pCurLevel = GetLevelAndAlloc(pDrlg, nCur);
        if (pCurLevel.eDrlgType != .wilderness) continue;
        const pVisArray = DrlgRoom.getVisArrayFromLevelId(pDrlg, nCur);
        const pWarpIds = DrlgRoom.getWarpsIdIfExists(pDrlg, nCur);
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            if (pVisArray[i] != .None and pWarpIds[i] == -1) {
                const pData: *s.D2DrlgLevelDataWildernessLevel =
                    @ptrCast(@alignCast(pCurLevel.pDrlgLevelData.?));
                const pAdj = GetLevelAndAlloc(pCurLevel.pDrlg, pVisArray[i]);
                const eDirection = mdeps.GetDirectionFromCoordinates(
                    &pCurLevel.sCoordinatesAndSize,
                    &pAdj.sCoordinatesAndSize,
                );
                // The two rects share no exact edge -> no seam. In the engine every
                // Vis/warp-linked wilderness pair is placed edge-adjacent, so this never
                // fires for a level generated in its own act; it only guards levels reached
                // outside their act (single-level render of a level whose act wasn't set up
                // — its neighbours have no seed-placed coords), whose GetDirectionFromCoordinates
                // is DIRECTION_INVALID. Building an orth from an INVALID direction would leave
                // neDrlgDirection out of [0,3] and crash CreateVerticesFromEdges. Mirror the
                // coordinate-adjacency builder (SetWarpConnectionsBetweenTwoAreas), which
                // likewise skips INVALID seams.
                if (eDirection == mdeps.DIRECTION_INVALID) continue;
                // (D2RoomExStrc*)&pData->pOrthData : pOrth is field 0 of D2RoomExStrc.
                const pFakeRoomEx: [*c]s.D2RoomExStrc = @ptrCast(@alignCast(&pData.pOrthData));
                DrlgRoom.AllocDrlgOrth(
                    pFakeRoomEx,
                    pAdj,
                    eDirection,
                    @intFromBool(pAdj.eDrlgType == .preset),
                );
            }
        }
    }
}

// DRLGACT_SetWarpConnectionsBetweenTwoAreas (Drlg.cpp ~4750, Act V path). Walks
// every pair of wilderness levels in [startId, endId] and, when their world-rects
// share an exact edge (GetDirectionFromCoordinates != INVALID), builds an orth in
// each direction via AllocDrlgOrth — the coordinate-based adjacency Act V uses
// instead of the Vis/Warp table used by Acts I/II/IV.
fn buildActVCoordOrths(pDrlg: [*c]s.D2DrlgStrc, startId: eD2LevelId, endId: eD2LevelId) void {
    var aI: i32 = @intFromEnum(startId);
    while (aI <= @intFromEnum(endId)) : (aI += 1) {
        const a: eD2LevelId = @enumFromInt(aI);
        const pA = GetLevelAndAlloc(pDrlg, a);
        if (pA.eDrlgType != .wilderness) continue;
        var bI: i32 = aI + 1;
        while (bI <= @intFromEnum(endId)) : (bI += 1) {
            const b: eD2LevelId = @enumFromInt(bI);
            const pB = GetLevelAndAlloc(pDrlg, b);
            if (pB.eDrlgType != .wilderness) continue;
            const dirAtoB = mdeps.GetDirectionFromCoordinates(&pA.sCoordinatesAndSize, &pB.sCoordinatesAndSize);
            if (dirAtoB == mdeps.DIRECTION_INVALID) continue;
            const dirBtoA = mdeps.GetDirectionFromCoordinates(&pB.sCoordinatesAndSize, &pA.sCoordinatesAndSize);
            const pDataA: *s.D2DrlgLevelDataWildernessLevel = @ptrCast(@alignCast(pA.pDrlgLevelData.?));
            const pDataB: *s.D2DrlgLevelDataWildernessLevel = @ptrCast(@alignCast(pB.pDrlgLevelData.?));
            const pFakeA: [*c]s.D2RoomExStrc = @ptrCast(@alignCast(&pDataA.pOrthData));
            const pFakeB: [*c]s.D2RoomExStrc = @ptrCast(@alignCast(&pDataB.pOrthData));
            DrlgRoom.AllocDrlgOrth(pFakeA, pB, @intCast(dirAtoB), @intFromBool(pB.eDrlgType == .preset));
            DrlgRoom.AllocDrlgOrth(pFakeB, pA, @intCast(dirBtoA), @intFromBool(pA.eDrlgType == .preset));
        }
    }
}

// Act V wilderness level range for coordinate-based orth building. Includes all
// Act V outdoor wilderness levels (DrlgType==3): Bloody Foothills (111) through
// Icy Cellar (117). Non-wilderness levels in the range are skipped by DRLGTYPE check.
const ACT_V_WILD_START: eD2LevelId = .FrigidHighlands;
const ACT_V_WILD_END: eD2LevelId = .FrozenTundra;

// Builds the inter-level wilderness adjacency (pOrthData) for every act's id span.
// Faithful subset of DRLGACTMISC_AllocDrlgLevelForAct: the per-act
// DRLGLEVEL_AllocDrlgLevelFromLevelIdToLevelId calls. Must run AFTER every level's
// sCoordinatesAndSize is established (so GetDirectionFromCoordinates sees the real
// seam) and BEFORE the wilderness InitLevel/border placement reads pOrthData.
pub fn buildInterLevelOrths(pDrlg: [*c]s.D2DrlgStrc) void {
    // First lay the dynamic warp graph (pWarpsInfo) the orths read from.
    for (ALL_LISTS) |list| {
        parseLevelDataWarps(pDrlg, list);
    }
    for (ACT_ORTH_RANGES) |r| {
        allocDrlgLevelFromLevelIdToLevelId(pDrlg, r.end, r.start);
    }
    // Act V uses coordinate-based adjacency (SetWarpConnectionsBetweenTwoAreas).
    buildActVCoordOrths(pDrlg, ACT_V_WILD_START, ACT_V_WILD_END);
}

// DRLG_ApplyAct1WildRoadFlags — ACT1_fpLevelDataFn2_A (00677180)
// Sets wilderness dwFlags road/transition bits from the gaWildernessLevelSeedOffsets
// lookup table (0x6f1258-0x6f13BF, 3 entries × 5 rules × 6 ints). Each rule
// checks the level id against a match/exclusion pair and a (dir0,dir1) pair
// derived from the placement-graph direction for the level's node and next node.
// Called at the top of InitAct1OutdoorLevel to mirror ParseLevelData's pre-gen call.
//
// gaWildernessLevelSeedOffsets table (binary-verified at 0x6f1258):
const road_flag_table = [3][5][6]i32{
    // Entry 0
    .{
        .{ 0, 2, 3, 1, 0, 0x04 },
        .{ 0, 2, 3, 2, 3, 0x04 },
        .{ 0, 3, 17, 2, 1, 0x08 },
        .{ 0, 3, 17, 3, 0, 0x08 },
        .{ 0, 3, 17, 1, 1, 0x10 },
    },
    // Entry 1
    .{
        .{ 0, 3, 17, 3, 3, 0x10 },
        .{ 2, 0, 0, 0, 0, 0x08 },
        .{ 2, 0, 0, 2, 2, 0x08 },
        .{ 2, 0, 0, 3, 0, 0x08 },
        .{ 2, 0, 0, 3, 2, 0x08 },
    },
    // Entry 2
    .{
        .{ 2, 0, 0, 0, 1, 0x400 },
        .{ 2, 0, 0, 1, 1, 0x400 },
        .{ 2, 0, 0, 2, 1, 0x200 },
        .{ 2, 0, 0, 2, 2, 0x80 },
        .{ 2, 0, 0, 3, 2, 0x100 },
    },
};

fn inferDirectionFromCoords(curr: s.D2DrlgCoordsStrc, prev: s.D2DrlgCoordsStrc) i32 {
    const cx = curr.WorldPosition.x + @divTrunc(curr.WorldSize.x, 2);
    const cy = curr.WorldPosition.y + @divTrunc(curr.WorldSize.y, 2);
    const px = prev.WorldPosition.x + @divTrunc(prev.WorldSize.x, 2);
    const py = prev.WorldPosition.y + @divTrunc(prev.WorldSize.y, 2);
    const dx = cx - px;
    const dy = cy - py;
    const adx = if (dx < 0) -dx else dx;
    const ady = if (dy < 0) -dy else dy;
    if (ady >= adx) return if (dy >= 0) 0 else 2;
    return if (dx < 0) 1 else 3;
}

fn dirForNode(list: []const LevelDataEntry, nodeIdx: usize, pDrlg: [*c]s.D2DrlgStrc) i32 {
    if (nodeIdx >= list.len) return -1;
    const entry = list[nodeIdx];
    if (entry.id == .None) return -1;
    if (entry.prev == -1) return -1;
    const prevId = list[@intCast(entry.prev)].id;
    var pCurr: ?*s.D2DrlgLevelStrc = null;
    var pPrev: ?*s.D2DrlgLevelStrc = null;
    var pl: ?*s.D2DrlgLevelStrc = pDrlg.*.pLevel;
    while (pl) |l| : (pl = l.pLevelNext) {
        if (l.eD2LevelId == entry.id) pCurr = l;
        if (l.eD2LevelId == prevId) pPrev = l;
    }
    if (pCurr == null or pPrev == null) return -1;
    return inferDirectionFromCoords(pCurr.?.sCoordinatesAndSize, pPrev.?.sCoordinatesAndSize);
}

pub fn applyAct1WildRoadFlags(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel.*.eDrlgType != .wilderness) return;
    const lvlId = pLevel.*.eD2LevelId;
    const pDrlg = pLevel.*.pDrlg.?;
    const pData: *s.D2DrlgLevelDataWildernessLevel = @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));

    const all_lists = [_][]const LevelDataEntry{ &ACT1_LIST1, &ACT1_LIST2 };
    for (all_lists) |list| {
        var nodeIdx: usize = std.math.maxInt(usize);
        for (list, 0..) |entry, i| {
            if (entry.id == .None) break;
            if (entry.id == lvlId) { nodeIdx = i; break; }
        }
        if (nodeIdx == std.math.maxInt(usize)) continue;

        const dir0 = dirForNode(list, nodeIdx, pDrlg);
        const dir1 = dirForNode(list, nodeIdx + 1, pDrlg);

        for (road_flag_table) |entry| {
            for (entry) |rule| {
                const matchId = rule[0];
                const exc1    = rule[1];
                const exc2    = rule[2];
                const d0      = rule[3];
                const d1      = rule[4];
                const flag    = rule[5];
                if ((@intFromEnum(lvlId) == matchId or matchId == 0) and
                    @intFromEnum(lvlId) != exc1 and @intFromEnum(lvlId) != exc2 and
                    dir0 == d0 and dir1 == d1)
                {
                    pData.dwFlags |= @intCast(flag);
                }
            }
        }
        return;
    }
}

