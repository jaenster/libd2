//! Faithful Zig transform of recon/closure/DrlgRoom.cpp
//! (D2Common::Drlg::DrlgRoom). DRLG core. Conventions:
//!
//!   * structs by name from structs.zig (`const s = @import("structs.zig")`)
//!   * pointers are C pointers `[*c]T` (deref/index/arith/null match C)
//!   * RNG -> rng.zig, allocs -> pool.zig, tables -> tables.zig
//!   * cross-file calls -> `@import("Other.zig").Fn`
//!   * generators / top-level / cross-module -> LOCAL stubs below
//!   * hardcoded struct-size hex literals in allocs -> @sizeOf(s.Struct)
//!   * byte-offset / pointer-as-int artifacts resolved to named fields, cited.
//!
//! BLOCKED (honest panic-stubs, see report): the warp-tile-grid nav functions
//! that use the i32 fields `nShadows`/`nFloors` as 32-bit POINTERS (deref to a
//! struct, return as a pointer) cannot survive the 32->64-bit transform, and
//! DRLGSPAWN_GetRandomPresetSpawnPoint depends on a static spawn-group table the
//! decompiler captured only the first element of.

const std = @import("std");
const s = @import("structs.zig");
const pool = @import("pool.zig");
const rng = @import("rng.zig");
const tables = @import("tables.zig");
const forward = @import("forward.zig");
const drlg = @import("drlg.zig");

// Siblings (resolved by name; may land after this file).
const RoomTile = @import("RoomTile.zig");
const DrlgLogic = @import("DrlgLogic.zig");
const DrlgGrid = @import("DrlgGrid.zig");
const DrlgVer = @import("DrlgVer.zig");

// Enum aliases (plain ints in the recon).
const eD2LevelId = @import("../enums.zig").eD2LevelId;
const eD2UnitType = i32;
const eDrlgDirection = i32;

// Constants used by the closure.
const LEVEL_None: eD2LevelId = .None;
const UNIT_OBJECT: i32 = 2;
const UNIT_WARP: i32 = 5;
const DIRECTION_SOUTHEAST: i32 = 0;
const DIRECTION_NORTHEAST: i32 = 1;
const DIRECTION_SOUTHWEST: i32 = 2;
const DIRECTION_NORTHWEST: i32 = 3;

// Local forward stubs (NOT in forward.zig). Recon signatures preserved.

/// OWNER: Dungeon.cpp
fn Dungeon_InitRoomEx(pRoomEx: [*c]s.D2RoomExStrc) void {
    _ = pRoomEx;
    @panic("Dungeon::InitRoomEx: Phase-5 stub");
}
/// OWNER: Dungeon.cpp
fn Dungeon_GetRoomExFromRoom(pRoom: [*c]s.D2RoomStrc) [*c]s.D2RoomExStrc {
    _ = pRoom;
    @panic("Dungeon::GetRoomExFromRoom: Phase-5 stub");
}
/// OWNER: Drlg.cpp (D2Common::Drlg::FreeRoomEx — 2-arg; distinct from the
/// local 3-arg DrlgRoom::FreeRoomEx).
fn Drlg_FreeRoomEx(pRoomEx: [*c]s.D2RoomExStrc, nFlag: u32) void {
    _ = .{ pRoomEx, nFlag };
    @panic("Drlg::FreeRoomEx: Phase-5 stub");
}
/// OWNER: DrlgActMisc.cpp / Level.cpp (level allocation)
fn GetLevelAndAlloc(pDrlg: [*c]s.D2DrlgStrc, eLevel: eD2LevelId) [*c]s.D2DrlgLevelStrc {
    return @ptrCast(drlg.GetLevelAndAlloc(pDrlg, eLevel));
}
/// OWNER: Level.cpp (drlg.zig)
fn InitLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    drlg.InitLevel(pLevel);
}
/// OWNER: DrlgActMisc.cpp
fn allocDrlgLevelForAct(pDrlg: [*c]s.D2DrlgStrc, nActNo: u8) void {
    _ = .{ pDrlg, nActNo };
    @panic("allocDrlgLevelForAct: Phase-5 stub");
}
/// OWNER: DrlgRoom/Level (coordinate->room lookup)
fn GetRoomOfCoord(pLevel: [*c]s.D2DrlgLevelStrc, nX: i32, nY: i32) [*c]s.D2RoomExStrc {
    _ = .{ pLevel, nX, nY };
    @panic("GetRoomOfCoord: Phase-5 stub");
}
/// OWNER: D2Game Level.cpp
fn checkIfLevelIsTown(eLevel: eD2LevelId) i32 {
    _ = eLevel;
    @panic("checkIfLevelIsTown: cross-module stub");
}
/// OWNER: OutRoom.cpp
fn hasOutdoorBorderFlag(pRoomEx: [*c]s.D2RoomExStrc) u32 {
    _ = pRoomEx;
    @panic("hasOutdoorBorderFlag: Phase-4 stub");
}
/// OutRoom.cpp DRLGOUTROOM_AllocOutdoorRoomData (1.14d 0067d6d0). Allocates the
/// RoomEx outdoor/maze data block (0x70 in 32-bit = D2DrlgRoomExDataMazeStrc),
/// zeroed, and hangs it off pRoomExData. Landed here (OutRoom owner)
/// because DRLGROOMEX_AllocRoomEx needs it for every maze room (nPresetType=2
/// takes the truthy `if(nPresetType)` arm).
fn OutRoom_AllocOutdoorRoomData(pRoomEx: [*c]s.D2RoomExStrc) void {
    const pRoomExDataOutRoom = pool.AllocServerMemory(pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool, @sizeOf(s.D2DrlgRoomExDataMazeStrc), ".\\DRLG\\OutRoom.cpp", 0xc5);
    @memset(@as([*]u8, @ptrCast(pRoomExDataOutRoom.?))[0..@sizeOf(s.D2DrlgRoomExDataMazeStrc)], 0);
    pRoomEx.*.pRoomExData = pRoomExDataOutRoom;
}
/// OutRoom.cpp DRLGOUTROOM_FreeDrlgOutdoorRoomData (1.14d 0067d610). Frees the
/// 4 grids + vertex list of the outdoor/maze data block, then the block itself.
fn OutRoom_FreeDrlgOutdoorRoomData(pRoomEx: [*c]s.D2RoomExStrc) void {
    const pData: [*c]s.D2DrlgRoomExDataMazeStrc = @ptrCast(@alignCast(pRoomEx.*.pRoomExData));
    const pMemory = pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool;
    if (pData == null) return;
    DrlgGrid.freeGrid(pMemory, &pData.*.pOrientationGrid);
    DrlgGrid.freeGrid(pMemory, &pData.*.pWallGrid);
    DrlgGrid.freeGrid(pMemory, &pData.*.pFloorGrid);
    DrlgGrid.freeGrid(pMemory, &pData.*.pCellGrid);
    DrlgVer.freeVertices(pMemory, @ptrCast(@alignCast(&pData.*.pVertex)));
    pool.FreeServerMemory(pMemory, pData, ".\\DRLG\\OutRoom.cpp", 0xad, 0);
    pRoomEx.*.pRoomExData = null;
}
/// OWNER: Preset.cpp
fn Preset_AllocRoomExDataPresetArea(pRoomEx: [*c]s.D2RoomExStrc) void {
    // Preset.cpp:783 — alloc 0xf8 (D2DrlgPresetRoomStrc), zeroed.
    const p = pool.AllocServerMemory(pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool, @sizeOf(s.D2DrlgPresetRoomStrc), ".\\DRLG\\Preset.cpp", 0x70f);
    @memset(@as([*]u8, @ptrCast(p.?))[0..@sizeOf(s.D2DrlgPresetRoomStrc)], 0);
    pRoomEx.*.pRoomExData = p;
}
/// OWNER: Preset.cpp
fn Preset_FreeRoomExDataPresetArea(pRoomEx: [*c]s.D2RoomExStrc) void {
    // Preset.cpp:755. DRLGPRESET_FreePresetRoomGrids operates on a global grid
    // free-list (empty in the standalone port) -> omitted. Free pNavigationPoints
    // (if any) then the block.
    const pData: ?*s.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(pRoomEx.*.pRoomExData));
    const pMemory = pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool;
    if (pData == null) return;
    if (pData.?.pNavigationPoints != null) {
        pool.FreeServerMemory(pMemory, pData.?.pNavigationPoints, ".\\DRLG\\Preset.cpp", 0x6f7, 0);
    }
    pool.FreeServerMemory(pMemory, pData, ".\\DRLG\\Preset.cpp", 0x6fa, 0);
    pRoomEx.*.pRoomExData = null;
}
/// OWNER: Preset.cpp
fn Preset_GetPickedFilePathFromRoomEx(pRoomEx: [*c]s.D2RoomExStrc) [*c]u8 {
    _ = pRoomEx;
    @panic("Preset::DRLGPRESET_GetPickedFilePathFromRoomEx: Phase-4 stub");
}
/// OWNER: Preset.cpp
fn Preset_FreeDrlgPresetUnit(pMemory: ?*s.D2PoolManagerStrc, pPresetUnit: [*c]s.D2PresetUnitStrc) void {
    // Preset.cpp:1572. pPath = { count; pEntries }: free entries ptr + path head.
    const pPath = pPresetUnit.*.pPath;
    if (pPath != null) {
        const pEntriesPtr: *?*anyopaque = @ptrFromInt(@intFromPtr(pPath) + 4);
        pool.FreeServerMemory(pMemory, pEntriesPtr.*, ".\\DRLG\\Preset.cpp", 0x597, 0);
        pool.FreeServerMemory(pMemory, pPath, ".\\DRLG\\Preset.cpp", 0x598, 0);
    }
    pool.FreeServerMemory(pMemory, pPresetUnit, ".\\DRLG\\Preset.cpp", 0x56b, 0);
}

// Local helpers

/// Unrecoverable DRLG internal error (engine: Fog::ErrorManager halt). noreturn.
fn raiseError(nLine: i32) noreturn {
    std.debug.panic("DRLG unrecoverable internal error (recon 0x{x})", .{nLine});
}

/// SBORROW4(a,b): signed overflow of (a - b) (decompiler flag intrinsic).
inline fn SBORROW4(a: i32, b: i32) bool {
    return @subWithOverflow(a, b)[1] == 1;
}

/// `(char)v` truncation used in the vis-slot shift math (v is always 0..7 here).
inline fn charOf(v: u32) i32 {
    return @as(i8, @bitCast(@as(u8, @truncate(v))));
}

// Functions

/// DrlgRoom.cpp:75 (1.14d 0066ab00) — BLOCKED.
/// The warp tile grid's i32 field `nShadows` is used as a 32-bit POINTER:
/// `*(eD2LevelId*)pTileGrid->nShadows` (line 81), `*(D2DrlgOrthStrc**)nShadows`
/// and `(D2RoomExStrc*)nShadows` (lines 96-97). A pointer cannot live in an i32
/// field in the 64-bit standalone — untransformable without retyping the struct.
pub fn getWarpDestinationRoom(pRoomEx: [*c]s.D2RoomExStrc, eLevel: eD2LevelId, ppOrth: [*c]?*s.D2DrlgOrthStrc, ppRoomEx: [*c]?*s.D2RoomExStrc) [*c]s.D2RoomStrc {
    _ = .{ pRoomEx, eLevel, ppOrth, ppRoomEx };
    @panic("getWarpDestinationRoom: blocked (nShadows i32 used as 32-bit pointer)");
}

/// DrlgRoom.cpp:116 (1.14d 0066ab70). Recon param `int32_t pRoomEx` is a
/// D2RoomExStrc* pointer-as-int; +0x4c == pTileGrid, walked via pAnimTiles
/// (+0x4), +0x8 == nWalls (the "select value"). Retyped + resolved (line 118).
pub fn setAllWarpTilesSelectValue(pRoomEx: [*c]s.D2RoomExStrc, nSelectValue: u32) void {
    var pWarpTile: [*c]s.D2DrlgTileGridStrc = pRoomEx.*.pTileGrid;
    while (pWarpTile != null) : (pWarpTile = @ptrCast(@alignCast(pWarpTile.*.pAnimTiles))) {
        pWarpTile.*.nWalls = @bitCast(nSelectValue);
    }
}


/// DrlgRoom.cpp:194 (1.14d 0066ac40) — BLOCKED. Depends on the spawn-point group
/// table the decompiler captured as one-element static locals (gnDrlgRoomExMax /
/// gaSpawnPointGroupTable, accessed `*(int*)(&gaSpawnPointGroupTable + n*8)` —
/// truncated DAT_006eed88 data). Faithful translation needs the real table.
pub fn getRandomPresetSpawnPoint(nSpawnType: i32, pnOutX: [*c]i32, pnOutY: [*c]i32, pLevel: [*c]s.D2DrlgLevelStrc) void {
    _ = .{ nSpawnType, pnOutX, pnOutY, pLevel };
    @panic("getRandomPresetSpawnPoint: blocked (truncated static spawn-group table)");
}

/// DrlgRoom.cpp:290 (1.14d 0066ad80).
pub fn findWaypointRoomAndCoords(pX: [*c]i32, pY: [*c]i32, pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (true) {
        if (pRoomEx == null) return null;
        const nWaypointFlags = GetWaypointFlags(pRoomEx);
        if (nWaypointFlags != 0) break;
        pRoomEx = pRoomEx.*.pRoomExNext;
    }

    Dungeon_InitRoomEx(pRoomEx);
    var pPresetUnit: [*c]s.D2PresetUnitStrc = pRoomEx.*.pPresetUnit;
    if (pPresetUnit == null) return pRoomEx;

    while (pPresetUnit.*.eType != UNIT_OBJECT or 0x23c < pPresetUnit.*.nClassId or blk: {
        const pObjectTxt = forward.objectsGetLine(pPresetUnit.*.nClassId);
        break :blk (pObjectTxt.*.SubClass & 0x40) == 0;
    }) {
        pPresetUnit = pPresetUnit.*.pPresetUnitNext;
        if (pPresetUnit == null) return pRoomEx;
    }

    pX.* = @divTrunc(pPresetUnit.*.nPosX, 5) + pRoomEx.*.sCoords.WorldPosition.x;
    pY.* = @divTrunc(pPresetUnit.*.nPosY, 5) + pRoomEx.*.sCoords.WorldPosition.y;
    return pRoomEx;
}

/// DrlgRoom.cpp:330 (1.14d 0066ae30).
pub fn getRoomAtLevelCenterOffset(nOffsetX: i32, nOffsetY: i32, pLevel: [*c]s.D2DrlgLevelStrc) void {
    _ = GetRoomOfCoord(
        pLevel,
        @divTrunc(pLevel.*.sCoordinatesAndSize.WorldSize.x, 2) + pLevel.*.sCoordinatesAndSize.WorldPosition.x - 2 + nOffsetX,
        @divTrunc(pLevel.*.sCoordinatesAndSize.WorldSize.y, 2) + pLevel.*.sCoordinatesAndSize.WorldPosition.y - 2 + nOffsetY,
    );
}

/// DrlgRoom.cpp:339 (1.14d 0066ae70).
pub fn getRandomRoomFromLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    if (pLevel == null) {
        raiseError(0x13e);
    }
    if (pLevel.*.pRoomExFirst != null) {
        var nRandomIndex = rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(pLevel.*.nRoomExCount));
        while (nRandomIndex != 0) : (nRandomIndex -= 1) {}
        return;
    }
    raiseError(0x13f);
}

/// DrlgRoom.cpp:360 (1.14d 0066aec0).
pub fn getWarpsIdIfExists(pDrlg: [*c]s.D2DrlgStrc, eLevel: eD2LevelId) [*c]i32 {
    var pWarpsInfo: [*c]s.D2DrlgActWarpsInfoStrc = pDrlg.*.pWarpsInfo;
    while (true) {
        if (pWarpsInfo == null) {
            const pLevelDefs = tables.levelDefsGetLine(eLevel);
            return &pLevelDefs.*.Warp[0];
        }
        if (pWarpsInfo.*.nLevelId == LEVEL_None) break;
        if (eLevel == pWarpsInfo.*.nLevelId) return &pWarpsInfo.*.nWarpId[0];
        pWarpsInfo = pWarpsInfo.*.pNext;
    }
    raiseError(0x1a2);
}

/// DrlgRoom.cpp:385 (1.14d 0066af50). The recon's "returns uninitialised local"
/// was a decompiler artifact for an EAX PASSTHROUGH: TXT_LvlWarp_Setup 0x61f310
/// leaves the matched LvlWarp ROW pointer in EAX, and this function returns it —
/// CreateExitWarp 0x66e1c0 consumes it as int32_t* (row[7]/[8] = OffsetX/Y) and
/// AllocRoomTile 0x66be10 stores it at warp-node+0x10. We return the 1-based
/// LvlWarp row index (fits the node's i32 slot on 64-bit builds).
pub fn getWarpsIdIfExistsAndSetup(pLevel: [*c]s.D2DrlgLevelStrc, nIdIndex: u8, nDirection: u8) i32 {
    const pWarpIdArray = getWarpsIdIfExists(pLevel.*.pDrlg, pLevel.*.eD2LevelId);
    return tables.lvlWarpSetupIndex(pWarpIdArray[nIdIndex], nDirection);
}


/// DrlgRoom.cpp:423 (1.14d 0066afb0).
pub fn findNthVisEntryForLevel(pDrlg: [*c]s.D2DrlgStrc, eLevelIdVis: eD2LevelId, eLevelId: eD2LevelId, nOccurrenceIndex: i32) i32 {
    var nNextSlot: u8 = undefined;
    var nMatchCount: i32 = 0;
    var nVisIndex: u32 = 0;
    while (true) {
        const pVisArray = getVisArrayFromLevelId(pDrlg, eLevelIdVis);
        if (pVisArray[nVisIndex] == eLevelId) {
            if (nMatchCount == nOccurrenceIndex) return @bitCast(nVisIndex);
            nMatchCount += 1;
        }
        nNextSlot = @as(u8, @truncate(nVisIndex)) +% 1;
        nVisIndex = nNextSlot;
        if (!(nNextSlot < 8)) break;
    }
    return -1;
}

/// DrlgRoom.cpp:446 (1.14d 0066b030). The two `goto LAB_*` slot searches are
/// restructured into labeled `matched` loops; the unused room/preset scans are
/// kept faithfully (empty bodies as in the recon).
pub fn initWarpConnectionsBetweenLevels(pDrlg: [*c]s.D2DrlgStrc, nActNo: u8, eLevel: eD2LevelId, eLevelTarget: eD2LevelId) void {
    allocDrlgLevelForAct(pDrlg, nActNo);
    const pSrcLevel = GetLevelAndAlloc(pDrlg, eLevel);
    if (pSrcLevel.*.pRoomExFirst == null) InitLevel(pSrcLevel);
    const pDstLevel = GetLevelAndAlloc(pDrlg, eLevelTarget);
    if (pDstLevel.*.pRoomExFirst == null) InitLevel(pDstLevel);

    const NEG1: u32 = @bitCast(@as(i32, -1));
    var nPairIndex: i32 = 0;
    while (true) {
        var nSrcVisSlot: u32 = undefined;
        {
            const pVisArray = getVisArrayFromLevelId(pDrlg, eLevel);
            var nMatchIndex: i32 = 0;
            var slot: u32 = 0;
            var matched = false;
            while (true) {
                if (pVisArray[slot] == eLevelTarget) {
                    if (nMatchIndex == nPairIndex) {
                        matched = true;
                        break;
                    }
                    nMatchIndex += 1;
                }
                const nVisSlot: u8 = @as(u8, @truncate(slot)) +% 1;
                slot = nVisSlot;
                if (!(nVisSlot < 8)) break;
            }
            nSrcVisSlot = if (matched) slot else NEG1;
        }

        var nDstVisSlot: u32 = undefined;
        {
            const pVisArray = getVisArrayFromLevelId(pDrlg, eLevelTarget);
            var nMatchIndex: i32 = 0;
            var slot: u32 = 0;
            var matched = false;
            while (true) {
                if (pVisArray[slot] == eLevel) {
                    if (nMatchIndex == nPairIndex) {
                        matched = true;
                        break;
                    }
                    nMatchIndex += 1;
                }
                const nVisSlot: u8 = @as(u8, @truncate(slot)) +% 1;
                slot = nVisSlot;
                if (!(nVisSlot < 8)) break;
            }
            nDstVisSlot = if (matched) slot else NEG1;
        }

        if (nSrcVisSlot == NEG1) return;
        if (nDstVisSlot == NEG1) return;

        _ = getWarpsIdIfExists(pSrcLevel.*.pDrlg, pSrcLevel.*.eD2LevelId);
        _ = getWarpsIdIfExists(pDstLevel.*.pDrlg, pDstLevel.*.eD2LevelId);

        var pSrcRoomEx: [*c]s.D2RoomExStrc = null;
        {
            var p: [*c]s.D2RoomExStrc = pSrcLevel.*.pRoomExFirst;
            var found = false;
            while (p != null) : (p = p.*.pRoomExNext) {
                if (p.*.eRoomExFlags.warpSlot(@intCast(charOf(nSrcVisSlot)))) {
                    pSrcRoomEx = p;
                    found = true;
                    break;
                }
            }
            if (!found) pSrcRoomEx = null;
        }

        var pDstRoomEx: [*c]s.D2RoomExStrc = null;
        {
            var p: [*c]s.D2RoomExStrc = pDstLevel.*.pRoomExFirst;
            var found = false;
            while (p != null) : (p = p.*.pRoomExNext) {
                if (p.*.eRoomExFlags.warpSlot(@intCast(charOf(nDstVisSlot)))) {
                    pDstRoomEx = p;
                    found = true;
                    break;
                }
            }
            if (!found) pDstRoomEx = null;
        }

        Dungeon_InitRoomEx(pSrcRoomEx);
        Dungeon_InitRoomEx(pDstRoomEx);

        {
            var pPresetUnit: [*c]s.D2PresetUnitStrc = GetPresetUnits(pSrcRoomEx);
            while (pPresetUnit != null and pPresetUnit.*.eType != UNIT_WARP) : (pPresetUnit = pPresetUnit.*.pPresetUnitNext) {}
        }
        {
            var pPresetUnit: [*c]s.D2PresetUnitStrc = GetPresetUnits(pDstRoomEx);
            while (pPresetUnit != null and pPresetUnit.*.eType != UNIT_WARP) : (pPresetUnit = pPresetUnit.*.pPresetUnitNext) {}
        }

        nPairIndex += 1;
        if (7 < nPairIndex) return;
    }
}

/// DrlgRoom.cpp:552 (1.14d 0066b1f0). The `goto LAB_0066b259` is restructured
/// with a `found` flag. Return type retyped from the recon's `int` to a RoomEx
/// pointer (line 583 returns `(int)pRoomEx` — a truncated-pointer artifact).
pub fn validateWarpFlagsAgainstVis(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    if (pRoomEx == null) return null;

    while (true) {
        if (pRoomEx.*.eRoomExFlags.anyWarp()) {
            var nRoomFlagMask: u32 = 0x10;
            var nWarpIndex: u32 = 0;
            while (true) {
                if (pRoomEx.*.eRoomExFlags.warpSlot(@intCast(nWarpIndex))) {
                    var pWarpArray: [*c]i32 = undefined;
                    var found = false;
                    var pWarpsInfo: [*c]s.D2DrlgActWarpsInfoStrc = pLevel.*.pDrlg.?.pWarpsInfo;
                    while (pWarpsInfo != null) : (pWarpsInfo = pWarpsInfo.*.pNext) {
                        // D2_ASSERT(nLevelId != LEVEL_None) — no-op
                        if (pLevel.*.eD2LevelId == pWarpsInfo.*.nLevelId) {
                            pWarpArray = &pWarpsInfo.*.nWarpId[0];
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        const pLevelDef = tables.levelDefsGetLine(pLevel.*.eD2LevelId);
                        pWarpArray = &pLevelDef.*.Warp[0];
                    }
                    // LAB_0066b259:
                    if (pWarpArray[nWarpIndex] != -1) return pRoomEx;
                }

                nRoomFlagMask *= 2;
                nWarpIndex = @as(u8, @truncate(nWarpIndex)) +% 1;
                if (!((nRoomFlagMask & 0xff0) != 0)) break;
            }
        }

        pRoomEx = pRoomEx.*.pRoomExNext;
        if (pRoomEx == null) return null;
    }
}

/// DrlgRoom.cpp:607 (1.14d 0066b2b0). The `pRoomEx`/`pRandomRoomEx` locals are
/// read uninitialised in the recon (decompiler artifacts) on paths that first
/// call the blocked spawn helpers; reproduced faithfully as `undefined`.
pub fn findSpawnLocationInLevel(pDrlg: [*c]s.D2DrlgStrc, eLevel: eD2LevelId, nSpawnTypeOrMode: i32, pX: [*c]i32, pY: [*c]i32) [*c]s.D2RoomStrc {
    const pLevelDefs = tables.levelDefsGetLine(eLevel);
    pX.* = -1;
    pY.* = -1;
    const pLevel = GetLevelAndAlloc(pDrlg, eLevel);
    if (pLevel.*.pRoomExFirst == null) InitLevel(pLevel);

    if (pLevelDefs.*.Position != 0) {
        const pRoomEx: [*c]s.D2RoomExStrc = undefined;
        if (nSpawnTypeOrMode == 0xd) {
            const pFoundRoomEx = findWaypointRoomAndCoords(pX, pY, pLevel);
            Dungeon_InitRoomEx(pFoundRoomEx);
            return pFoundRoomEx.*.pRoom;
        }

        getRandomPresetSpawnPoint(nSpawnTypeOrMode, pX, pY, pLevel);
        Dungeon_InitRoomEx(pRoomEx);
        return pRoomEx.*.pRoom;
    }

    var pFoundRoomEx = findWaypointRoomAndCoords(pX, pY, pLevel);
    if (pFoundRoomEx == null) {
        pFoundRoomEx = validateWarpFlagsAgainstVis(pLevel);
        if (pFoundRoomEx == null) {
            pFoundRoomEx = GetRoomOfCoord(
                pLevel,
                @divTrunc(pLevel.*.sCoordinatesAndSize.WorldSize.x, 2) - 2 + pLevel.*.sCoordinatesAndSize.WorldPosition.x,
                @divTrunc(pLevel.*.sCoordinatesAndSize.WorldSize.y, 2) - 2 + pLevel.*.sCoordinatesAndSize.WorldPosition.y,
            );
            if (pFoundRoomEx == null) {
                const pRandomRoomEx: [*c]s.D2RoomExStrc = undefined;
                getRandomRoomFromLevel(pLevel);
                pFoundRoomEx = pRandomRoomEx;
                if (pRandomRoomEx == null) return null;
            }
        }
    }
    if (pX.* == -1 or pY.* == -1) {
        pX.* = @divTrunc(pFoundRoomEx.*.sCoords.WorldSize.x, 2) + pFoundRoomEx.*.sCoords.WorldPosition.x;
        pY.* = @divTrunc(pFoundRoomEx.*.sCoords.WorldSize.y, 2) + pFoundRoomEx.*.sCoords.WorldPosition.y;
    }

    Dungeon_InitRoomEx(pFoundRoomEx);
    return pFoundRoomEx.*.pRoom;
}

/// DrlgRoom.cpp:655 (1.14d 0066b3e0). Alloc size 0xec -> @sizeOf(D2RoomExStrc).
/// Line 660: `*(uint8_t*)&fRoomStatus = 4` after a full zero -> `fRoomStatus = 4`.
/// Debug hook: when set, each AllocRoomEx appends the level seed (low word) at
/// entry — before its two SEED_NEXT advances. Mirrors the hand-port's alloc-seed
/// stream trace so the transformed RNG order can be diffed vs the engine golden.
pub var trace_alloc_seeds: ?*std.ArrayListUnmanaged(u32) = null;

pub fn allocRoomEx(pLevel: [*c]s.D2DrlgLevelStrc, nPresetType: i32) [*c]s.D2RoomExStrc {
    if (trace_alloc_seeds) |list| list.append(pool.default_allocator, @bitCast(pLevel.*.sSeed.nSeedLow)) catch {};
    const pRoomEx: [*c]s.D2RoomExStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pLevel.*.pDrlg.?.pMemoryPool, @sizeOf(s.D2RoomExStrc), ".\\DRLG\\DrlgRoom.cpp", 0x20)));
    @memset(@as([*]u8, @ptrCast(pRoomEx))[0..@sizeOf(s.D2RoomExStrc)], 0);
    pRoomEx.*.nPresetType = nPresetType;
    pRoomEx.*.pLevel = pLevel;
    pRoomEx.*.fRoomStatus = 4; // line 660
    var sNewSeed = rng.sEEDNEXT(pLevel.*.sSeed);
    const pSeedPtr = &pRoomEx.*.sSeed;
    pLevel.*.sSeed = sNewSeed;
    pSeedPtr.*.nSeedLow = sNewSeed.nSeedLow;
    pRoomEx.*.sSeed.nSeedHigh = 0x29a;
    sNewSeed = rng.sEEDNEXT(pSeedPtr.*);
    pSeedPtr.* = sNewSeed;
    pRoomEx.*.nSeed = sNewSeed.nSeedLow;
    if ((pLevel.*.dwFlags & 0x10) != 0) {
        pRoomEx.*.eRoomExFlags.mapReveal = true;
    }
    // Recon AllocRoomEx flattened the original switch to `if(nPresetType){outdoor}
    // else if(==2){preset}` — making the preset arm dead. Faithful-to-engine: type
    // 2 (maze + preset rooms) takes the 0xf8 preset block; type 1 the outdoor block.
    if (nPresetType == 2) {
        Preset_AllocRoomExDataPresetArea(pRoomEx);
        return pRoomEx;
    } else if (nPresetType != 0) {
        OutRoom_AllocOutdoorRoomData(pRoomEx);
    }

    return pRoomEx;
}

/// DrlgRoom.cpp:686 (1.14d 0066b4c0).
pub fn FreeDrlgRoomEx(pRoomEx: [*c]s.D2RoomExStrc, nUnused: i32, eFlags: u32) void {
    pRoomEx.*.pRoom = null;
    pRoomEx.*.dwOtherFlags = @bitCast(eFlags & 1);
    if (!pRoomEx.*.eRoomExFlags.roomActive) {
        return;
    }
    Drlg_FreeRoomEx(pRoomEx, @as(u32, @intFromBool(nUnused == 0)));
}

/// DrlgRoom.cpp:698 (1.14d 0066b4f0).
pub fn freeDrlgRoomTile(pMemory: ?*s.D2PoolManagerStrc, pRoomEx: [*c]s.D2RoomExStrc) void {
    var pTileGrid: [*c]s.D2DrlgTileGridStrc = pRoomEx.*.pTileGrid;
    while (pTileGrid != null) {
        const pNextTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(@alignCast(pTileGrid.*.pAnimTiles));
        pool.FreeServerMemory(pMemory, pTileGrid, ".\\DRLG\\DrlgRoom.cpp", 0x58, 0);
        pTileGrid = pNextTileGrid;
    }
    pRoomEx.*.pTileGrid = null;
}

/// DrlgRoom.cpp:712 (1.14d 0066b530).
pub fn FreeRoomData(pMemory: ?*s.D2PoolManagerStrc, pDrlgRoomData: [*c]s.D2DrlgOrthStrc) void {
    var p = pDrlgRoomData;
    while (p != null) {
        const pNext = p.*.pNext;
        pool.FreeServerMemory(pMemory, p, ".\\DRLG\\DrlgRoom.cpp", 0xbd, 0);
        p = pNext;
    }
}

/// DrlgRoom.cpp:723 (1.14d 0066b560). Alloc 0x18 -> @sizeOf(D2DrlgOrthStrc).
pub fn allocNodesFromRoomExToRoomEx(pRoomEx: [*c]s.D2RoomExStrc, pDrlgRoomEx2: [*c]s.D2RoomExStrc, eDrlgDir: i32) void {
    var pOrthIter: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
    while (true) {
        if (pOrthIter == null) {
            const pNewOrth: [*c]s.D2DrlgOrthStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool, @sizeOf(s.D2DrlgOrthStrc), ".\\DRLG\\DrlgRoom.cpp", 0xd4)));
            pNewOrth.*.pRoomEx = null;
            pNewOrth.*.neDrlgDirection = DIRECTION_SOUTHEAST;
            pNewOrth.*.bIsDrlgTypePresetArea = 0;
            pNewOrth.*.nType = 0;
            pNewOrth.*.psCoordinatesAndSize = null;
            pNewOrth.*.pNext = null;
            pNewOrth.*.pNext = pRoomEx.*.pOrth;
            pRoomEx.*.pOrth = pNewOrth;
            pNewOrth.*.pRoomEx = pDrlgRoomEx2;
            pNewOrth.*.neDrlgDirection = eDrlgDir;
            pNewOrth.*.nType = 1;
            pNewOrth.*.psCoordinatesAndSize = &pDrlgRoomEx2.*.sCoords;
            return;
        }
        if (pOrthIter.*.pRoomEx == pDrlgRoomEx2) break;
        pOrthIter = pOrthIter.*.pNext;
    }
}

/// DrlgRoom.cpp:753 (1.14d 0066b5e0).
pub fn allocNodesForBothRoomEx(pRoomExA: [*c]s.D2RoomExStrc, pRoomExB: [*c]s.D2RoomExStrc, eDirection: i32) void {
    allocNodesFromRoomExToRoomEx(pRoomExA, pRoomExB, eDirection);
    allocNodesFromRoomExToRoomEx(pRoomExB, pRoomExA, (eDirection -% 2) & 3);
}

/// DrlgRoom.cpp:760 (1.14d 0066b610).
pub fn findReplaceAndFreeSub00VsTargetRoomEx(pMemory: ?*s.D2PoolManagerStrc, pRoomEx: [*c]s.D2RoomExStrc, pDrlgRoomExTarget: [*c]s.D2RoomExStrc) void {
    var pOrthCurrent: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
    var pOrthNext: [*c]s.D2DrlgOrthStrc = pOrthCurrent.*.pNext;
    if (pOrthCurrent.*.nType != 0 and pOrthCurrent.*.pRoomEx == pDrlgRoomExTarget) {
        pRoomEx.*.pOrth = pOrthNext;
    } else {
        var pOrthPrev = pOrthCurrent;
        if (pOrthNext == null) return;

        while (true) {
            pOrthCurrent = pOrthNext;
            if (!(pOrthCurrent.*.nType == 0 or pOrthCurrent.*.pRoomEx != pDrlgRoomExTarget)) break;
            pOrthNext = pOrthCurrent.*.pNext;
            pOrthPrev = pOrthCurrent;
            if (pOrthCurrent.*.pNext == null) return;
        }

        pOrthPrev.*.pNext = pOrthCurrent.*.pNext;
    }

    pool.FreeServerMemory(pMemory, pOrthCurrent, ".\\DRLG\\DrlgRoom.cpp", 0x115, 0);
}

/// DrlgRoom.cpp:793 (1.14d 0066b670).
pub fn findReplaceAndFreeSub00ForBothRoomEx(pMemory: ?*s.D2PoolManagerStrc, pRoomEx: [*c]s.D2RoomExStrc, pDrlgRoomExB: [*c]s.D2RoomExStrc) void {
    findReplaceAndFreeSub00VsTargetRoomEx(pMemory, pRoomEx, pDrlgRoomExB);
    findReplaceAndFreeSub00VsTargetRoomEx(pMemory, pDrlgRoomExB, pRoomEx);
}

/// DrlgRoom.cpp:800 (1.14d 0066b6a0).
pub fn compareByDirectionAndCoord(pOrth1: [*c]s.D2DrlgOrthStrc, pOrth2: [*c]s.D2DrlgOrthStrc) i32 {
    const eDir1 = pOrth1.*.neDrlgDirection;
    if (eDir1 < pOrth2.*.neDrlgDirection) return 1;
    if (pOrth2.*.neDrlgDirection != eDir1) return 0;

    switch (eDir1) {
        DIRECTION_SOUTHEAST => {
            if (pOrth1.*.psCoordinatesAndSize.?.WorldPosition.y < pOrth2.*.psCoordinatesAndSize.?.WorldPosition.y) return 1;
        },
        DIRECTION_NORTHEAST => {
            if (pOrth2.*.psCoordinatesAndSize.?.WorldPosition.x < pOrth1.*.psCoordinatesAndSize.?.WorldPosition.x) return 1;
        },
        DIRECTION_SOUTHWEST => {
            if (pOrth2.*.psCoordinatesAndSize.?.WorldPosition.y < pOrth1.*.psCoordinatesAndSize.?.WorldPosition.y) return 1;
        },
        DIRECTION_NORTHWEST => {
            if (pOrth1.*.psCoordinatesAndSize.?.WorldPosition.x < pOrth2.*.psCoordinatesAndSize.?.WorldPosition.x) return 1;
        },
        else => {},
    }

    return 0;
}

/// DrlgRoom.cpp:837 (1.14d 0066b720).
pub fn replaceSub00(pRoomEx: [*c]s.D2RoomExStrc, pOrth: [*c]s.D2DrlgOrthStrc) void {
    var bShouldInsertBefore: i32 = undefined;
    var pOrthPrev: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
    if (pOrthPrev == null) {
        pRoomEx.*.pOrth = pOrth;
        return;
    }

    var pOrthNext: [*c]s.D2DrlgOrthStrc = pOrthPrev.*.pNext;
    if (pOrthNext == null) {
        bShouldInsertBefore = compareByDirectionAndCoord(pOrth, pOrthPrev);
        if (bShouldInsertBefore != 0) {
            pOrth.*.pNext = pOrthPrev;
            pRoomEx.*.pOrth = pOrth;
            return;
        }
    } else {
        while (true) {
            const pOrthIter = pOrthNext;
            bShouldInsertBefore = compareByDirectionAndCoord(pOrth, pOrthIter);
            pOrthNext = pOrthIter;
            if (bShouldInsertBefore != 0) break;
            pOrthNext = pOrthIter.*.pNext;
            pOrthPrev = pOrthIter;
            if (pOrthNext == null) break;
        }
    }

    pOrth.*.pNext = pOrthNext;
    pOrthPrev.*.pNext = pOrth;
}

/// DrlgRoom.cpp:874 (1.14d 0066b790). Alloc 0x18 -> @sizeOf(D2DrlgOrthStrc).
pub fn AllocDrlgOrth(pRoomEx: [*c]s.D2RoomExStrc, pLevel: [*c]s.D2DrlgLevelStrc, neDrlgDirection: eDrlgDirection, bIsDrlgTypePresetArea: i32) void {
    const pNewOrth: [*c]s.D2DrlgOrthStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pLevel.*.pDrlg.?.pMemoryPool, @sizeOf(s.D2DrlgOrthStrc), ".\\DRLG\\DrlgRoom.cpp", 0x15f)));
    pNewOrth.*.pNext = null;
    pNewOrth.*.pRoomEx = @ptrCast(@alignCast(pLevel)); // union: D2DrlgLevelStrc* when nType==0
    pNewOrth.*.neDrlgDirection = neDrlgDirection;
    pNewOrth.*.bIsDrlgTypePresetArea = bIsDrlgTypePresetArea;
    pNewOrth.*.nType = 0;
    pNewOrth.*.psCoordinatesAndSize = &pLevel.*.sCoordinatesAndSize;
    replaceSub00(pRoomEx, pNewOrth);
}

/// DrlgRoom.cpp:887 (1.14d 0066b800).
pub fn isWithinDistance(pCoords: [*c]s.D2DrlgCoordsStrc, pCoords2: [*c]s.D2DrlgCoordsStrc, nSize: i32, nX: [*c]i32, nY: [*c]i32) u32 {
    var nX1 = pCoords.*.WorldPosition.x;
    var nX2 = pCoords2.*.WorldPosition.x;
    if (nX1 < nX2) {
        nX.* = nX2 - pCoords.*.WorldSize.x - nX1;
    } else {
        nX.* = nX1 - pCoords2.*.WorldSize.x - nX2;
    }

    nX1 = pCoords.*.WorldPosition.y;
    nX2 = pCoords2.*.WorldPosition.y;
    if (nX1 < nX2) {
        nY.* = nX2 - pCoords.*.WorldSize.y - nX1;
    } else {
        nY.* = nX1 - pCoords2.*.WorldSize.y - nX2;
    }
    if (!(nX.* < nSize and nY.* < nSize)) {
        return 1;
    }

    return 0;
}

/// DrlgRoom.cpp:912 (1.14d 0066b860). The recon aliases `(int*)&pCoords1Copy`
/// as the nX out-param (line 914); resolved to a discarded i32 scratch.
pub fn FreeRoomEx(pCoords1: [*c]s.D2DrlgCoordsStrc, pCoords2: [*c]s.D2DrlgCoordsStrc, nDistance: i32) i32 {
    var nXScratch: i32 = undefined;
    var nDist = nDistance;
    const nResult = isWithinDistance(pCoords1, pCoords2, nDistance, &nXScratch, &nDist);
    return @bitCast(nResult);
}

/// DrlgRoom.cpp:920 (1.14d 0066b880). The `(cond || (assign, cond))` comma
/// idioms (lines 927/933) resolve to a simple if/else distance pick.
pub fn isAdjacentOrOverlapping(pDrlgCoords: [*c]s.D2DrlgCoordsStrc, pCoordinatesAndSizeB: [*c]s.D2DrlgCoordsStrc, nMaxDist: i32) i32 {
    var nPosA = pDrlgCoords.*.WorldPosition.x;
    var nPosB = pCoordinatesAndSizeB.*.WorldPosition.x;
    var nDistX: i32 = undefined;
    if (nPosB < nPosA) {
        nDistX = nPosA - pCoordinatesAndSizeB.*.WorldSize.x - nPosB;
    } else {
        nDistX = nPosB - pDrlgCoords.*.WorldSize.x - nPosA;
    }

    nPosA = pDrlgCoords.*.WorldPosition.y;
    nPosB = pCoordinatesAndSizeB.*.WorldPosition.y;
    var nDistY: i32 = undefined;
    if (nPosB < nPosA) {
        nDistY = nPosA - pCoordinatesAndSizeB.*.WorldSize.y - nPosB;
    } else {
        nDistY = nPosB - pDrlgCoords.*.WorldSize.y - nPosA;
    }

    var bBorrow: bool = undefined;
    var bIsEqual: bool = undefined;
    if (nMaxDist == 0) {
        if (0 < nDistX) return 0;
        bBorrow = false;
        bIsEqual = nDistY == 0;
    } else {
        if (nDistX == 0 and nDistY <= nMaxDist) return 1;
        if (nDistY != 0) return 0;
        bBorrow = SBORROW4(nDistX, nMaxDist);
        nDistY = nDistX - nMaxDist;
        bIsEqual = nDistX == nMaxDist;
    }
    if (!(!bIsEqual and bBorrow == (nDistY < 0))) {
        return 1;
    }

    return 0;
}

/// DrlgRoom.cpp:964 (1.14d 0066b900).
pub fn ComputeRectanglesManhattanDistance(pLevel: [*c]s.D2DrlgLevelStrc, pRoomEx: [*c]s.D2RoomExStrc, pDrlgRoomEx2: [*c]s.D2RoomExStrc, nDistance: i32) i32 {
    var pRoomExIter: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (true) {
        if (pRoomExIter == null) return 1;
        if (pRoomExIter != pRoomEx and pRoomExIter != pDrlgRoomEx2) {
            var nDistX = pRoomEx.*.sCoords.WorldPosition.x;
            var nDistY = pRoomExIter.*.sCoords.WorldPosition.x;
            if (nDistX < nDistY) {
                nDistX = nDistY - pRoomEx.*.sCoords.WorldSize.x - nDistX;
            } else {
                nDistX = nDistX - pRoomExIter.*.sCoords.WorldSize.x - nDistY;
            }

            nDistY = pRoomEx.*.sCoords.WorldPosition.y;
            const nPosY2 = pRoomExIter.*.sCoords.WorldPosition.y;
            if (nDistY < nPosY2) {
                nDistY = nPosY2 - pRoomEx.*.sCoords.WorldSize.y - nDistY;
            } else {
                nDistY = nDistY - pRoomExIter.*.sCoords.WorldSize.y - nPosY2;
            }
            if (nDistX < nDistance and nDistY < nDistance) return 0;
        }

        pRoomExIter = pRoomExIter.*.pRoomExNext;
    }
}

/// DrlgRoom.cpp:1000 (1.14d 0066b970). Line 1005 returns the previous list head
/// as u32 (pointer-as-int artifact; callers only test truthiness).
pub fn AddRoomExToLevel(pLevelData: [*c]s.D2DrlgLevelStrc, pRoomEx: [*c]s.D2RoomExStrc) u32 {
    const pPrevFirst = pLevelData.*.pRoomExFirst;
    pRoomEx.*.pRoomExNext = pPrevFirst;
    pLevelData.*.nRoomExCount += 1;
    pLevelData.*.pRoomExFirst = pRoomEx;
    if (pPrevFirst) |p| return @truncate(@intFromPtr(p));
    return 0;
}

/// DrlgRoom.cpp:1010 (1.14d 0066b980). (called by DrlgGrid via this module.)
pub fn AreXYInsideCoordinates(pDrlgCoords: [*c]s.D2DrlgCoordsStrc, nX: i32, nY: i32) u32 {
    const nPosX = pDrlgCoords.*.WorldPosition.x;
    if (nX < nPosX) return 0;

    const nPosY = pDrlgCoords.*.WorldPosition.y;
    if (!(nPosY <= nY and nX < pDrlgCoords.*.WorldSize.x + nPosX)) return 0;

    return @intFromBool(nY < pDrlgCoords.*.WorldSize.y + nPosY);
}

/// DrlgRoom.cpp:1026 (1.14d 0066b9d0). (called by DrlgGrid via this module.)
pub fn isPointInside(pDrlgCoords: [*c]s.D2DrlgCoordsStrc, nX: i32, nY: i32) u32 {
    const nPosX = pDrlgCoords.*.WorldPosition.x;
    if (nX < nPosX) return 0;

    const nPosY = pDrlgCoords.*.WorldPosition.y;
    if (!(nPosY <= nY and nX <= pDrlgCoords.*.WorldSize.x + nPosX)) return 0;

    return @intFromBool(nY <= pDrlgCoords.*.WorldSize.y + nPosY);
}

/// DrlgRoom.cpp:1044 (1.14d 0066ba20).
pub fn checkWorldCoordsInRoomBounds(pRoomCoords: [*c]s.D2DrlgCoordsStrc, nWorldX: i32, nWorldY: i32) u32 {
    var iVar2 = pRoomCoords.*.WorldPosition.x * 5;
    if (iVar2 > nWorldX) return 0;

    var iVar1 = pRoomCoords.*.WorldSize.x;
    if (nWorldX >= iVar2 + iVar1 * 4 + iVar1) return 0;

    iVar2 = pRoomCoords.*.WorldPosition.y * 5;
    if (iVar2 > nWorldY) return 0;

    iVar1 = pRoomCoords.*.WorldSize.y;
    return @intFromBool(nWorldY < iVar2 + iVar1 * 4 + iVar1);
}

/// DrlgRoom.cpp:1066 (1.14d 0066ba70).
pub fn CheckLOSDraw(pRoomEx: [*c]s.D2RoomExStrc) u32 {
    if (pRoomEx.*.nPresetType != 0) return 1;
    if (pRoomEx.*.nPresetType == 2) return pRoomEx.*.eRoomExFlags.raw() & 0x80000;

    return 0;
}

/// DrlgRoom.cpp:1081 (1.14d 0066ba90).
pub fn isPresetWithOutdoorBorder(pRoomEx: [*c]s.D2RoomExStrc) u32 {
    if (pRoomEx.*.nPresetType == 0) return 0;

    return hasOutdoorBorderFlag(pRoomEx);
}

/// DrlgRoom.cpp:1092 (1.14d 0066baa0).
pub fn GetWaypointFlags(pRoomEx: [*c]s.D2RoomExStrc) u32 {
    return pRoomEx.*.eRoomExFlags.raw() & 0x30000;
}

/// DrlgRoom.cpp:1098 (1.14d 0066bab0).
pub fn GetLevelId(pRoomEx: [*c]s.D2RoomExStrc) eD2LevelId {
    return pRoomEx.*.pLevel.?.eD2LevelId;
}

/// DrlgRoom.cpp:1104 (1.14d 0066bac0).
pub fn getWarpDestinationLevel(pRoomEx: [*c]s.D2RoomExStrc, eLevel: eD2LevelId) eD2LevelId {
    var pOrth: ?*s.D2DrlgOrthStrc = undefined;
    var pRoomExDest: ?*s.D2RoomExStrc = undefined;
    const pRoom = getWarpDestinationRoom(pRoomEx, eLevel, &pOrth, &pRoomExDest);
    if (pRoom == null) {
        raiseError(0x25c);
    } else {
        const pDestRoomEx = Dungeon_GetRoomExFromRoom(pRoom);
        if (pDestRoomEx == null) {
            raiseError(0x25e);
        } else {
            if (pDestRoomEx.*.pLevel != null) return pDestRoomEx.*.pLevel.?.eD2LevelId;
            raiseError(0x25f);
        }
    }
}

/// DrlgRoom.cpp:1131 (1.14d 0066bb20).
pub fn GetLevelIdFromPopulatedRoomEx(pRoomEx: [*c]s.D2RoomExStrc) eD2LevelId {
    if (pRoomEx == null) {
        raiseError(0x26b);
    }
    if (!pRoomEx.*.eRoomExFlags.noSpawn) {
        return pRoomEx.*.pLevel.?.eD2LevelId;
    }

    return LEVEL_None;
}

/// DrlgRoom.cpp:1148 (1.14d 0066bb60).
pub fn HasWaypoint(pRoomEx: [*c]s.D2RoomExStrc) bool {
    if (pRoomEx != null) {
        return pRoomEx.*.eRoomExFlags.hasWaypoint();
    }

    raiseError(0x276);
}

/// DrlgRoom.cpp:1161 (1.14d 0066bba0).
pub fn GetPickedLevelPrestFilePathFromRoomEx(pRoomEx: [*c]s.D2RoomExStrc) [*c]u8 {
    if (pRoomEx.*.nPresetType != 2) {
        return @constCast("None");
    }

    return Preset_GetPickedFilePathFromRoomEx(pRoomEx);
}

/// DrlgRoom.cpp:1173 (1.14d 0066bbc0). Recon param `D2RoomExStrc* pRoomEx` is
/// the near-room COUNT (callers pass `nDrlgRoomsExNearCount` as a pointer);
/// line 1177 `(uintptr_t)&pRoomEx[-1].pStatusPrev + 3` == nCount - 1 (32-bit
/// sizeof artifact). Retyped + resolved.
pub fn ReorderNearRoomList(nCount: i32, ppRoomList: [*c]?*s.D2RoomStrc) void {
    const nListCount = nCount - 1;
    var nPassRemaining = nListCount;
    while (0 < nPassRemaining) : (nPassRemaining -= 1) {
        var nIndex: i32 = 0;
        if (0 < nListCount) {
            while (true) {
                const pRoomNext = ppRoomList[@intCast(nIndex + 1)];
                const pRoomCurrent = ppRoomList[@intCast(nIndex)];
                if (pRoomNext.?.dwUnk0x3C + pRoomNext.?.eFlags <= pRoomCurrent.?.eFlags or pRoomNext.?.dwUnk0x40 + pRoomNext.?.dwUnk0x38 <= pRoomCurrent.?.dwUnk0x38) {
                    ppRoomList[@intCast(nIndex)] = pRoomNext;
                    ppRoomList[@intCast(nIndex + 1)] = pRoomCurrent;
                }

                nIndex += 1;
                if (!(nIndex < nListCount)) break;
            }
        }
    }
}

/// DrlgRoom.cpp:1199 (1.14d 0066bc20). Near-room array (line 1234) holds
/// pointers, so the recon's `count * 4` becomes `count * @sizeOf(ptr)` (8 in
/// 64-bit). The list is stored/sorted as D2RoomStrc* then read back as RoomEx*,
/// matching the recon's casts.
pub fn DefineRoomsNear(pMemory: ?*s.D2PoolManagerStrc, pRoomEx: [*c]s.D2RoomExStrc) void {
    var apNearRoomExList: [30]?*s.D2RoomStrc = undefined;
    var pRoomExIter: [*c]s.D2RoomExStrc = pRoomEx.*.pLevel.?.pRoomExFirst;
    pRoomEx.*.nDrlgRoomsExNearCount = 0;
    while (pRoomExIter != null) {
        var nGapX = pRoomEx.*.sCoords.WorldPosition.x;
        var nGapY = pRoomExIter.*.sCoords.WorldPosition.x;
        if (nGapX < nGapY) {
            nGapX = nGapY - pRoomEx.*.sCoords.WorldSize.x - nGapX;
        } else {
            nGapX = nGapX - pRoomExIter.*.sCoords.WorldSize.x - nGapY;
        }

        nGapY = pRoomEx.*.sCoords.WorldPosition.y;
        const nPosY2 = pRoomExIter.*.sCoords.WorldPosition.y;
        if (nGapY < nPosY2) {
            nGapY = nPosY2 - pRoomEx.*.sCoords.WorldSize.y - nGapY;
        } else {
            nGapY = nGapY - pRoomExIter.*.sCoords.WorldSize.y - nPosY2;
        }
        if (nGapX < 6 and nGapY < 6) {
            const idx = pRoomEx.*.nDrlgRoomsExNearCount;
            apNearRoomExList[@intCast(idx)] = @ptrCast(pRoomExIter);
            pRoomExIter = pRoomExIter.*.pRoomExNext;
            pRoomEx.*.nDrlgRoomsExNearCount = idx + 1;
        } else {
            pRoomExIter = pRoomExIter.*.pRoomExNext;
        }
    }

    const nNearCount = pRoomEx.*.nDrlgRoomsExNearCount;
    ReorderNearRoomList(nNearCount, &apNearRoomExList[0]);
    const ppNearRooms: [*c]?*s.D2RoomExStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @intCast(nNearCount * @as(i32, @sizeOf(?*s.D2RoomExStrc))), ".\\DRLG\\DrlgRoom.cpp", 0x2cb)));
    pRoomEx.*.ppDrlgRoomsExNear = ppNearRooms;
    var nGapX: i32 = 0;
    if (0 >= pRoomEx.*.nDrlgRoomsExNearCount) {
        return;
    }

    while (true) {
        pRoomEx.*.ppDrlgRoomsExNear[@intCast(nGapX)] = @ptrCast(apNearRoomExList[@intCast(nGapX)]);
        nGapX += 1;
        if (!(nGapX < pRoomEx.*.nDrlgRoomsExNearCount)) break;
    }
}

/// DrlgRoom.cpp:1249 (1.14d 0066bcf0).
pub fn GetRoomsNearCount(pRoomEx: [*c]s.D2RoomExStrc) i32 {
    return pRoomEx.*.nDrlgRoomsExNearCount;
}

/// DrlgRoom.cpp:1255 (1.14d 0066bd00).
pub fn GetRealRoomsNearCount(pRoomEx: [*c]s.D2RoomExStrc, ppRoomList: [*c]?*s.D2RoomStrc) i32 {
    var nRealCount: i32 = 0;
    var nIndex: i32 = 0;
    if (0 < pRoomEx.*.nDrlgRoomsExNearCount) {
        while (true) {
            const pRoom = pRoomEx.*.ppDrlgRoomsExNear[@intCast(nIndex)].?.pRoom;
            if (pRoom != null) {
                ppRoomList[@intCast(nRealCount)] = pRoom;
                nRealCount += 1;
            }

            nIndex += 1;
            if (!(nIndex < pRoomEx.*.nDrlgRoomsExNearCount)) break;
        }
    }

    var iNullFill = nRealCount;
    if (nRealCount >= pRoomEx.*.nDrlgRoomsExNearCount) {
        return nRealCount;
    }

    while (true) {
        ppRoomList[@intCast(iNullFill)] = null;
        iNullFill += 1;
        if (!(iNullFill < pRoomEx.*.nDrlgRoomsExNearCount)) break;
    }

    return nRealCount;
}

/// DrlgRoom.cpp:1286 (1.14d 0066bd50). NOTE: the recon declares the scan index
/// `nIndex` INSIDE the while(true) (line 1296), which would reset it each pass;
/// lifted out to the obvious intended iteration (decompiler scoping artifact).
pub fn checkNearRoomsForTownAndSetFlag0x800000(pRoomEx: [*c]s.D2RoomExStrc) void {
    var bIsTownLevel = checkIfLevelIsTown(pRoomEx.*.pLevel.?.eD2LevelId);
    if (bIsTownLevel != 0) {
        return;
    }
    if (0 >= pRoomEx.*.nDrlgRoomsExNearCount) {
        return;
    }

    var nIndex: i32 = 0;
    while (true) {
        bIsTownLevel = checkIfLevelIsTown(pRoomEx.*.ppDrlgRoomsExNear[@intCast(nIndex)].?.pLevel.?.eD2LevelId);
        if (bIsTownLevel != 0) {
            break;
        }

        nIndex += 1;
        if (pRoomEx.*.nDrlgRoomsExNearCount <= nIndex) {
            return;
        }
    }

    pRoomEx.*.eRoomExFlags.noSpawn = true;
}

/// DrlgRoom.cpp:1316 (1.14d 0066bda0). Pointer array realloc: `count * 4` ->
/// `count * @sizeOf(ptr)` (8 in 64-bit).
pub fn resizeArrayAndAddNewNearRoom(pDrlgRoomEx: [*c]s.D2RoomExStrc, pMemory: ?*s.D2PoolManagerStrc, pRoomExStrc: [*c]s.D2RoomExStrc, pRoom: [*c]s.D2RoomExStrc) void {
    _ = pRoomExStrc;
    pDrlgRoomEx.*.nDrlgRoomsExNearCount += 1;
    const ppNewNearRooms: [*c]?*s.D2RoomExStrc = @ptrCast(@alignCast(pool.ReAllocServerMemory(pMemory, @ptrCast(pDrlgRoomEx.*.ppDrlgRoomsExNear), @intCast(pDrlgRoomEx.*.nDrlgRoomsExNearCount * @as(i32, @sizeOf(?*s.D2RoomExStrc))), ".\\DRLG\\DrlgRoom.cpp", 0x314, 0)));
    pDrlgRoomEx.*.ppDrlgRoomsExNear = ppNewNearRooms;
    if (ppNewNearRooms == null) {
        raiseError(0x315);
    }

    ppNewNearRooms[@intCast(pDrlgRoomEx.*.nDrlgRoomsExNearCount - 1)] = pRoom;
    ReorderNearRoomList(pDrlgRoomEx.*.nDrlgRoomsExNearCount, @ptrCast(pDrlgRoomEx.*.ppDrlgRoomsExNear));
}

/// DRLGROOMEX_LinkNearRoomsByVis (Drlg.cpp:1213, 1.14d 0066c2a0): for one of the
/// room's vis slots, find the destination level's matching return-vis slot (by
/// occurrence index when the warp id exists) and link via linkNearRoomByDirection
/// -- which allocRoomTile's the warp NODE onto this room's +0x4C chain. Engine
/// calls InitLevel(pDstLevel) on demand; our callers pre-generate every level of
/// the act, so a dest level without rooms just yields no link (harmless).
pub fn linkNearRoomsByVis(pMemory: ?*s.D2PoolManagerStrc, pRoomEx: [*c]s.D2RoomExStrc, srcVisSlot: u8) void {
    if (pRoomEx == null or srcVisSlot > 7) return;
    const pSrcLevel = pRoomEx.*.pLevel.?;
    const srcLevelId = pSrcLevel.*.eD2LevelId;
    const pSrcVisArray = getVisArrayFromLevelId(pSrcLevel.*.pDrlg, srcLevelId);
    const dstLevelId: eD2LevelId = pSrcVisArray[srcVisSlot];
    const pDstLevel = GetLevelAndAlloc(pSrcLevel.*.pDrlg, dstLevelId);
    const pDstVisArray = getVisArrayFromLevelId(pSrcLevel.*.pDrlg, dstLevelId);
    const warpDestLevel = @import("DrlgWarp.zig").getWarpDestinationFromArray(pSrcLevel, srcVisSlot);
    if (pDstLevel.*.pRoomExFirst == null) InitLevel(pDstLevel);

    if (warpDestLevel != -1) {
        // Occurrence-match: the Nth src-vis referencing dst pairs with the Nth
        // dst-vis referencing src.
        var nSrcOccurCountBeforeSlot: i32 = 0;
        var i: u32 = 0;
        while (i < srcVisSlot) : (i += 1) {
            if (pSrcVisArray[i] == dstLevelId) nSrcOccurCountBeforeSlot += 1;
        }
        var nDstOccurrenceIndex: i32 = 0;
        var nSlot: u32 = 0;
        while (nSlot < 8) : (nSlot += 1) {
            if (pDstVisArray[nSlot] == srcLevelId) {
                if (nSrcOccurCountBeforeSlot == nDstOccurrenceIndex) {
                    if (linkNearRoomByDirection(@intCast(nSlot), pRoomEx, pMemory, srcVisSlot, warpDestLevel, pDstLevel.*.pRoomExFirst) != 0) return;
                    break;
                }
                nDstOccurrenceIndex += 1;
            }
        }
    }
    var nSlot: u32 = 0;
    while (nSlot < 8) : (nSlot += 1) {
        if (pDstVisArray[nSlot] != srcLevelId) continue;
        if (linkNearRoomByDirection(@intCast(nSlot), pRoomEx, pMemory, srcVisSlot, warpDestLevel, pDstLevel.*.pRoomExFirst) != 0) return;
    }
}

/// DrlgRoom.cpp:1336 (1.14d 0066be10). Alloc 0x18 -> @sizeOf(D2DrlgTileGridStrc)
/// (warp node uses the first 0x18 bytes).
pub fn allocRoomTile(pLinkedRoomEx: [*c]s.D2RoomExStrc, visSlot: u8, pSrcRoomEx: [*c]s.D2RoomExStrc) void {
    const pTileGrid: [*c]s.D2DrlgTileGridStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pSrcRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool, @sizeOf(s.D2DrlgTileGridStrc), ".\\DRLG\\DrlgRoom.cpp", 0x322)));
    pTileGrid.*.pAnimTiles = null;
    pTileGrid.*.nWalls = 0;
    pTileGrid.*.nFloors = 0;
    pTileGrid.*.nShadows = 0;
    pTileGrid.*.pWallTiles = null;
    pTileGrid.*.pMapLinks = @ptrCast(@alignCast(pLinkedRoomEx));
    const nWarpId = getWarpsIdIfExistsAndSetup(pSrcRoomEx.*.pLevel, visSlot, 0x62);
    pTileGrid.*.nShadows = nWarpId;
    pTileGrid.*.nWalls = 1;
    pTileGrid.*.pAnimTiles = @ptrCast(@alignCast(pSrcRoomEx.*.pTileGrid));
    pSrcRoomEx.*.pTileGrid = pTileGrid;
}

/// DrlgRoom.cpp:1358 (1.14d 0066be80).
pub fn linkNearRoomByDirection(dstVisSlot: u8, pRoomEx: [*c]s.D2RoomExStrc, pMemory: ?*s.D2PoolManagerStrc, srcVisSlot: u8, warpDestLevel: i32, pDstRoomExIter_in: [*c]s.D2RoomExStrc) u32 {
    var pDstRoomExIter = pDstRoomExIter_in;
    var bLinkAdded: u32 = 0;
    while (true) {
        if (pDstRoomExIter == null) return bLinkAdded;
        if (pDstRoomExIter.*.eRoomExFlags.warpSlot(@intCast(dstVisSlot))) {
            if (warpDestLevel != -1) {
                resizeArrayAndAddNewNearRoom(pRoomEx, pMemory, pDstRoomExIter, pDstRoomExIter);
                allocRoomTile(pDstRoomExIter, srcVisSlot, pRoomEx);
                return 1;
            }

            var nGapX = pRoomEx.*.sCoords.WorldPosition.x;
            var nGapY = pDstRoomExIter.*.sCoords.WorldPosition.x;
            if (nGapX < nGapY) {
                nGapX = nGapY - pRoomEx.*.sCoords.WorldSize.x - nGapX;
            } else {
                nGapX = nGapX - pDstRoomExIter.*.sCoords.WorldSize.x - nGapY;
            }

            nGapY = pRoomEx.*.sCoords.WorldPosition.y;
            const nDstRoomY = pDstRoomExIter.*.sCoords.WorldPosition.y;
            if (nGapY < nDstRoomY) {
                nGapY = nDstRoomY - pRoomEx.*.sCoords.WorldSize.y - nGapY;
            } else {
                nGapY = nGapY - pDstRoomExIter.*.sCoords.WorldSize.y - nDstRoomY;
            }
            if (nGapX < 6 and nGapY < 6) {
                resizeArrayAndAddNewNearRoom(pRoomEx, pMemory, pDstRoomExIter, pDstRoomExIter);
                bLinkAdded = 1;
            }
        }

        pDstRoomExIter = pDstRoomExIter.*.pRoomExNext;
    }
}

/// DrlgRoom.cpp:1403 (1.14d 0066bf30). Alloc 0x20 -> @sizeOf(D2PresetUnitStrc).
pub fn AllocPresetUnit(pRoomEx: [*c]s.D2RoomExStrc, pMemory: ?*s.D2PoolManagerStrc, eUnitType: eD2UnitType, nMonStatsId: i32, bUseMonStatsMaybe: i32, nPosX: i32, nPosY: i32) [*c]s.D2PresetUnitStrc {
    const pPresetUnit: [*c]s.D2PresetUnitStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(s.D2PresetUnitStrc), ".\\DRLG\\DrlgRoom.cpp", 0x3b6)));
    pPresetUnit.*.pPresetUnitNext = null;
    pPresetUnit.*.pPath = null;
    pPresetUnit.*.nFlags = 0;
    pPresetUnit.*.nDbmCode = -1;
    pPresetUnit.*.eType = eUnitType;
    pPresetUnit.*.nClassId = nMonStatsId;
    pPresetUnit.*.nMode = bUseMonStatsMaybe;
    pPresetUnit.*.nPosX = nPosX;
    pPresetUnit.*.nPosY = nPosY;
    if (pRoomEx != null) {
        pPresetUnit.*.pPresetUnitNext = pRoomEx.*.pPresetUnit;
        pRoomEx.*.pPresetUnit = pPresetUnit;
        return pPresetUnit;
    }

    pPresetUnit.*.pPresetUnitNext = null;
    return pPresetUnit;
}

/// DrlgRoom.cpp:1425 (1.14d 0066bfa0).
pub fn GetPresetUnits(pRoomEx: [*c]s.D2RoomExStrc) [*c]s.D2PresetUnitStrc {
    const dwRoomExFlags = pRoomEx.*.eRoomExFlags;
    if (dwRoomExFlags.mapReveal) {
        return pRoomEx.*.pPresetUnit;
    }
    if (dwRoomExFlags.presetsSpawned) {
        return null;
    }

    pRoomEx.*.eRoomExFlags.presetsSpawned = true;
    return pRoomEx.*.pPresetUnit;
}

/// DrlgRoom.cpp:1440 (1.14d 0066bfc0).
pub fn SetRoom(pRoomEx: [*c]s.D2RoomExStrc, pRoom: [*c]s.D2RoomStrc) void {
    pRoomEx.*.pRoom = pRoom;
}

/// DrlgRoom.cpp:1446 (1.14d 0066bfd0). Recon `ColorInfo.*` flattened to the
/// direct Intensity/Red/Green/Blue fields in tables.D2LevelDefsTxt.
pub fn GetRGB_IntensityFromRoomEx(pRoomEx: [*c]s.D2RoomExStrc, nIntensity: [*c]u8, nRed: [*c]u8, nGreen: [*c]u8, nBlue: [*c]u8) void {
    const pLevelDefs = tables.levelDefsGetLine(pRoomEx.*.pLevel.?.eD2LevelId);
    nIntensity.* = @truncate(@as(u32, @bitCast(pLevelDefs.*.Intensity)));
    nRed.* = @truncate(@as(u32, @bitCast(pLevelDefs.*.Red)));
    nGreen.* = @truncate(@as(u32, @bitCast(pLevelDefs.*.Green)));
    nBlue.* = @truncate(@as(u32, @bitCast(pLevelDefs.*.Blue)));
}

/// DrlgRoom.cpp:1456 (1.14d 0066c040).
pub fn getVisArrayFromLevelId(pDrlg: [*c]s.D2DrlgStrc, eLevelId: eD2LevelId) [*c]eD2LevelId {
    var pWarpsInfo: [*c]s.D2DrlgActWarpsInfoStrc = pDrlg.*.pWarpsInfo;
    while (true) {
        if (pWarpsInfo == null) {
            const pLevelDefs = tables.levelDefsGetLine(eLevelId);
            return &pLevelDefs.*.Vis[0];
        }
        if (pWarpsInfo.*.nLevelId == LEVEL_None) break;
        if (eLevelId == pWarpsInfo.*.nLevelId) return &pWarpsInfo.*.nTargetArea[0];
        pWarpsInfo = pWarpsInfo.*.pNext;
    }
    raiseError(0x410);
}

/// DrlgRoom.cpp:1481 (1.14d 0066c0b0).
pub fn GetDrlgFromRoomEx(pRoomEx: [*c]s.D2RoomExStrc) [*c]s.D2DrlgStrc {
    if (pRoomEx == null) {
        raiseError(0x42b);
    }
    if (pRoomEx.*.pLevel == null) {
        raiseError(0x42c);
    }
    const pDrlg = pRoomEx.*.pLevel.?.pDrlg;
    if (pDrlg != null) {
        return pDrlg;
    }
    raiseError(0x42d);
}

/// DrlgRoom.cpp:1503 (1.14d 0066c100). `goto LAB_0066c1e7` restructured by
/// duplicating the nRoomExCount-- + break.
pub fn freeDrlgRoomEx(pRoomEx: [*c]s.D2RoomExStrc) void {
    const pMemory = pRoomEx.*.pLevel.?.pDrlg.?.pMemoryPool;
    freeDrlgRoomTile(pMemory, pRoomEx);
    if (pRoomEx.*.ppDrlgRoomsExNear != null) {
        pool.FreeServerMemory(pMemory, @ptrCast(pRoomEx.*.ppDrlgRoomsExNear), ".\\DRLG\\DrlgRoom.cpp", 0x69, 0);
        pRoomEx.*.nDrlgRoomsExNearCount = 0;
        pRoomEx.*.ppDrlgRoomsExNear = null;
    }
    // Faithful-to-engine (mirrors the AllocRoomEx switch): type 2 frees the preset
    // block; type 1 the outdoor block (the recon flattened this artifact too).
    if (pRoomEx.*.nPresetType == 2) {
        Preset_FreeRoomExDataPresetArea(pRoomEx);
    } else if (pRoomEx.*.nPresetType != 0) {
        OutRoom_FreeDrlgOutdoorRoomData(pRoomEx);
    }

    var pPresetIter: [*c]s.D2PresetUnitStrc = pRoomEx.*.pPresetUnit;
    while (pPresetIter != null) {
        const pPresetNext = pPresetIter.*.pPresetUnitNext;
        Preset_FreeDrlgPresetUnit(pMemory, pPresetIter);
        pPresetIter = pPresetNext;
    }

    var pOrthIter: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
    while (true) {
        const pOrthCurrent = pOrthIter;
        if (pOrthCurrent == null) break;
        pOrthIter = pOrthCurrent.*.pNext;
        if (pOrthCurrent.*.nType != 0) {
            const pLinkedRoomEx = pOrthCurrent.*.pRoomEx;
            findReplaceAndFreeSub00VsTargetRoomEx(pMemory, pRoomEx, pLinkedRoomEx);
            findReplaceAndFreeSub00VsTargetRoomEx(pMemory, pLinkedRoomEx, pRoomEx);
        }
    }

    FreeRoomData(pMemory, pRoomEx.*.pOrth);
    const pLevel = pRoomEx.*.pLevel;
    var pRoomExSearch: [*c]s.D2RoomExStrc = pLevel.?.pRoomExFirst;
    if (pRoomExSearch == pRoomEx) {
        pLevel.?.pRoomExFirst = pRoomEx.*.pRoomExNext;
        pLevel.?.nRoomExCount -= 1;
    } else {
        var pRoomExIterNext: [*c]s.D2RoomExStrc = pRoomExSearch.*.pRoomExNext;
        while (pRoomExIterNext != null) {
            const pRoomExNext: [*c]s.D2RoomExStrc = pRoomExSearch.*.pRoomExNext;
            if (pRoomExNext == pRoomEx) {
                pRoomExSearch.*.pRoomExNext = pRoomEx.*.pRoomExNext;
                pLevel.?.nRoomExCount -= 1;
                break;
            }
            pRoomExSearch = pRoomExNext;
            pRoomExIterNext = pRoomExNext.*.pRoomExNext;
        }
    }

    RoomTile.freeRoomTilesAll(pRoomEx);
    DrlgLogic.FreeDrlgCoordList(pRoomEx);
    pool.FreeServerMemory(pMemory, pRoomEx, ".\\DRLG\\DrlgRoom.cpp", 0xae, 0);
}
