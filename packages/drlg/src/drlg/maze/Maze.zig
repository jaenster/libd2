//! Mechanical transform of recon/closure/Maze.cpp (D2Common::Drlg::Maze).
//! Faithful by construction; field access by NAME, RNG -> rng.zig, allocs -> pool.zig,
//! tables -> tables.zig, core room ops -> the DrlgRoom.zig, seed-free geometry
//! + the seed-consuming Preset stubs -> deps.zig.
//!
//! pRoomExData overlay: the recon reads pRoomData[0]/[1]/[3] off the RoomEx data block
//! (a D2DrlgRoomExDataMazeStrc whose first member is pOrientationGrid : D2DrlgGridStrc).
//! Per the standalone-port plan these byte indices resolve to NAMED grid fields:
//!   pRoomData[0] = pOrientationGrid.pCellsFlags      -> def      (LvlPrest id; ptr-as-int)
//!   pRoomData[1] = pOrientationGrid.pCellsRowOffsets -> variant  (picked file; ptr-as-int)
//!   pRoomData[3] = pOrientationGrid.nHeight          -> flags    (bit1 = HAS_MAP_DS1)
//! The `>>1 & 1` HAS_MAP_DS1 idiom == (flags & 2).

const std = @import("std");
const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const pool = @import("../pool.zig");
const tables = @import("../tables.zig");
const DrlgRoom = @import("../DrlgRoom.zig");
const deps = @import("deps.zig");
const enums = @import("../enums.zig");
const eDrlgLevelType = enums.eDrlgLevelType;
const LevelId = enums.LevelId;
const Sewer = @import("Act2Sewer.zig");
const Act1 = @import("Act1.zig");
const Act2 = @import("Act2.zig");
const Act3 = @import("Act3.zig");
const Act4 = @import("Act4.zig");
const Act5 = @import("Act5.zig");

const DIRECTION_SOUTHEAST = deps.DIRECTION_SOUTHEAST; // 0
const DIRECTION_NORTHEAST = deps.DIRECTION_NORTHEAST; // 1
const DIRECTION_SOUTHWEST = deps.DIRECTION_SOUTHWEST; // 2
const DIRECTION_NORTHWEST = deps.DIRECTION_NORTHWEST; // 3
const DIRECTION_INVALID = deps.DIRECTION_INVALID; // -1

// pRoomExData (D2DrlgRoomExDataMazeStrc) named-field accessors

// nPresetType==2 rooms carry a D2DrlgPresetRoomStrc (DrlgGrid.h). The recon's raw
// pRoomData[0]/[1]/[3] integer payloads map to its leading int fields:
//   [0] nLevelPrest -> def   [1] nPickedFile -> variant   [3] nFlags -> flags
// (faithful named fields — no more aliasing onto grid pointers, which the free path
// would otherwise try to free).
inline fn roomData(pRoomEx: [*c]s.D2RoomExStrc) [*c]s.D2DrlgPresetRoomStrc {
    return @ptrCast(@alignCast(pRoomEx.*.pRoomExData));
}
pub inline fn getDef(pRoomEx: [*c]s.D2RoomExStrc) i32 {
    return @intFromEnum(roomData(pRoomEx).*.nLevelPrest);
}
pub inline fn setDef(pRoomEx: [*c]s.D2RoomExStrc, v: i32) void {
    roomData(pRoomEx).*.nLevelPrest = @enumFromInt(v);
}
pub inline fn getVariant(pRoomEx: [*c]s.D2RoomExStrc) i32 {
    return roomData(pRoomEx).*.nPickedFile;
}
pub inline fn setVariant(pRoomEx: [*c]s.D2RoomExStrc, v: i32) void {
    roomData(pRoomEx).*.nPickedFile = v;
}
pub inline fn getFlags(pRoomEx: [*c]s.D2RoomExStrc) i32 {
    return roomData(pRoomEx).*.nFlags;
}
pub inline fn setFlags(pRoomEx: [*c]s.D2RoomExStrc, v: i32) void {
    roomData(pRoomEx).*.nFlags = v;
}
pub inline fn hasMapDs1(pRoomEx: [*c]s.D2RoomExStrc) bool {
    return (getFlags(pRoomEx) & 2) != 0;
}
inline fn mazeTxt(pLevel: [*c]s.D2DrlgLevelStrc) [*c]tables.D2LvlMazeTxt {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData));
}

// DRLGMAZE_PickRoomPreset (Maze.cpp:64, 1.14d 006709b0)
// Static orientation->preset lookups (originally global data).
const gaMazePresetLookupExt = [16][2]i32{
    .{ 0x0, 0x0 },   .{ 0x0, 0x420 }, .{ 0x0, 0x41f }, .{ 0x0, 0x421 },
    .{ 0x0, 0x41e }, .{ 0x415, 0x0 }, .{ 0x414, 0x0 }, .{ 0x0, 0x0 },
    .{ 0x0, 0x41d }, .{ 0x413, 0x0 }, .{ 0x412, 0x0 }, .{ 0x0, 0x0 },
    .{ 0x0, 0x422 }, .{ 0x0, 0x0 },   .{ 0x0, 0x0 },   .{ 0x0, 0x0 },
};
const gaMazePresetLookup = [16][3]i32{
    .{ 0x0, 0x0, 0x0 },       .{ 0x0, 0x0, 0x0 },       .{ 0x0, 0x0, 0x0 },       .{ 0x0, 0x0, 0x0 },
    .{ 0x0, 0x0, 0x0 },       .{ 0x164, 0x168, 0x293 }, .{ 0x163, 0x167, 0x294 }, .{ 0x0, 0x0, 0x0 },
    .{ 0x0, 0x0, 0x0 },       .{ 0x165, 0x169, 0x295 }, .{ 0x162, 0x166, 0x296 }, .{ 0x0, 0x0, 0x0 },
    .{ 0x0, 0x0, 0x0 },       .{ 0x0, 0x0, 0x0 },       .{ 0x0, 0x0, 0x0 },       .{ 0x0, 0x0, 0x0 },
};

/// DRLGMAZE_PickRoomPreset (Maze.cpp:64). Resolves the orientation-bitmask preset
/// id for a room from its orth directions + level-type base, writes def/variant,
/// and clears HAS_MAP_DS1. The recon's lost `_bPickSourcePreset` register param is
/// the build-time bResetFlag=1 (CLEAR bit1) used by every call site here.
pub fn pickRoomPreset(pRoomEx: [*c]s.D2RoomExStrc) [*c]s.D2RoomExStrc {
    var nPresetIndex: i32 = 0;
    var nVariant: i32 = -1;
    var pOrth: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
    while (pOrth != null) : (pOrth = pOrth.*.pNext) {
        switch (pOrth.*.neDrlgDirection) {
            DIRECTION_SOUTHEAST => nPresetIndex |= 1,
            DIRECTION_NORTHEAST => nPresetIndex |= 8,
            DIRECTION_SOUTHWEST => nPresetIndex |= 2,
            DIRECTION_NORTHWEST => nPresetIndex |= 4,
            else => {},
        }
    }

    const pMap = pRoomEx.*.pLevel.?;
    const idx: usize = @intCast(nPresetIndex & 0xf);
    // Preset BASE offsets per level type (arbitrary LvlPrest table bases, faithful
    // to DRLGMAZE_PickRoomPreset 1.14d 006709b0).
    switch (pMap.*.nLevelType) {
        .act1_caves => nPresetIndex += 0x34,
        .act1_crypt => nPresetIndex += 0x6c,
        .barracks_family => nPresetIndex += 0xa7,
        .act1_jail => nPresetIndex += 0xcd,
        .act1_catacombs => nPresetIndex += 0x101,
        .act2_sewer => nPresetIndex += 0x12d,
        .generic_0e => nPresetIndex = gaMazePresetLookup[idx][0],
        .generic_0f => {
            nPresetIndex = gaMazePresetLookup[idx][1];
            if (pMap.*.eD2LevelId == LevelId.tower_lower_2 and nPresetIndex == 0x169) nVariant = 2;
            if (pMap.*.eD2LevelId == LevelId.tower_lower_4 and (nPresetIndex == 0x169 or nPresetIndex == 0x167)) nVariant = 3;
        },
        .act2_tombs => nPresetIndex += 0x19d,
        .act2_lair => nPresetIndex += 0x1e1,
        .act2_arcane => nPresetIndex += 0x1fd,
        .act3_durance => nPresetIndex += 0x2f1,
        .generic_17 => {
            nPresetIndex = gaMazePresetLookup[idx][2];
            if (pMap.*.eD2LevelId == LevelId.arcane_0x54 and nPresetIndex == 0x296) nPresetIndex = 0x298;
            if (pMap.*.eD2LevelId == LevelId.arcane_0x55 and nPresetIndex == 0x295) {
                nPresetIndex = 0x297;
                setDef(pRoomEx, nPresetIndex);
                setVariant(pRoomEx, nVariant);
                setFlags(pRoomEx, getFlags(pRoomEx) & -3);
                return pRoomEx;
            }
        },
        .act3_dungeon => nPresetIndex += 0x298,
        .act3_sewers => nPresetIndex += 0x2c0,
        .river_family => nPresetIndex += 0x344,
        .act5_temple => nPresetIndex = gaMazePresetLookupExt[idx][0],
        .act5_icecaves => {
            // Maze.cpp:214 — Var1 = DRLGMAZE_IsPresetSingleFile(pMap); if(Var1==0) +0x3ea.
            // For grid-built ice-cave maze rooms the preset is multi-file (Files>1), so
            // IsPresetSingleFile (Drlg.cpp:2474, 1.14d 00670810) is 0 here and the base
            // 0x3ea is always added. The FrozenRiver/DrifterCavern/IcyCellar single-file
            // rooms never reach PickRoomPreset (they get fixed defs in GenerateLevel).
            nPresetIndex += 0x3ea;
        },
        .act5_worldstone => nPresetIndex += 0x422,
        .act5_baal => nPresetIndex = gaMazePresetLookupExt[idx][1],
        else => @panic("pickRoomPreset: unknown level type"),
    }

    if (nPresetIndex == 0) return pRoomEx;
    setDef(pRoomEx, nPresetIndex);
    setVariant(pRoomEx, nVariant);
    setFlags(pRoomEx, getFlags(pRoomEx) & -3); // _bPickSourcePreset==1 -> clear bit1
    return pRoomEx;
}

/// DRLGMAZE_FindAndReplacePreset (Maze.cpp:248). Finds the first non-locked room
/// whose def == nPresetId, rewrites def/variant and locks (|=2) or unlocks (&=-3).
pub fn findAndReplacePreset(pLevel: [*c]s.D2DrlgLevelStrc, nPresetId: i32, nNewPresetId: i32, nNewArg1: i32, nEnableFlag: i32) [*c]s.D2RoomExStrc {
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (true) {
        if (pRoomEx == null) return null;
        if (!hasMapDs1(pRoomEx) and getDef(pRoomEx) == nPresetId) break;
        pRoomEx = pRoomEx.*.pRoomExNext;
    }
    setDef(pRoomEx, nNewPresetId);
    setVariant(pRoomEx, nNewArg1);
    if (nEnableFlag != 0) {
        setFlags(pRoomEx, getFlags(pRoomEx) & -3);
    } else {
        setFlags(pRoomEx, getFlags(pRoomEx) | 2);
    }
    return pRoomEx;
}

/// DRLGMAZE_PickRoomPresets (Maze.cpp:277). Merge step: connect pRoomEx to nearby
/// non-locked rooms when the neighbour's seed roll < Merge threshold.
pub fn pickRoomPresets(pRoomEx: [*c]s.D2RoomExStrc) void {
    if (hasMapDs1(pRoomEx)) return;
    const pMazeTxt = mazeTxt(pRoomEx.*.pLevel);
    var pNeighbor: [*c]s.D2RoomExStrc = pRoomEx.*.pLevel.?.*.pRoomExFirst;
    while (pNeighbor != null) : (pNeighbor = pNeighbor.*.pRoomExNext) {
        if (pNeighbor != pRoomEx and !hasMapDs1(pNeighbor)) {
            var nDeltaX: i32 = 0;
            var nDeltaY: i32 = 0;
            const bWithin = DrlgRoom.isWithinDistance(&pRoomEx.*.sCoords, &pNeighbor.*.sCoords, 1, &nDeltaX, &nDeltaY);
            if (bWithin == 0 and nDeltaX != nDeltaY) {
                var bConnected = false;
                var pOrth: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
                while (pOrth != null) : (pOrth = pOrth.*.pNext) {
                    if (pOrth.*.pRoomEx == pNeighbor) {
                        bConnected = true;
                        break;
                    }
                }
                if (!bConnected) {
                    const sNewSeed = rng.sEEDNEXT(pNeighbor.*.sSeed);
                    pNeighbor.*.sSeed = sNewSeed;
                    // Roll = newSeedLow % 1000 — the engine divides ONLY the 32-bit low
                    // word (1.14d 0x670d16: MUL 0x10624dd3 / SHR EDX,6 / IMUL 0x3e8 /
                    // SUB ECX = newLow%1000). Ghidra mis-widened this to (uint64_t)sNewSeed
                    // in Maze.cpp:305; the full-64-bit modulo over-links (extra merges).
                    const nRoll: i32 = @intCast(@as(u32, @bitCast(sNewSeed.nSeedLow)) % 1000);
                    if (nRoll < pMazeTxt.*.Merge) {
                        const nDirection = deps.GetDirectionFromCoordinates(&pNeighbor.*.sCoords, &pRoomEx.*.sCoords);
                        if (nDirection != DIRECTION_INVALID) {
                            DrlgRoom.allocNodesForBothRoomEx(pNeighbor, pRoomEx, nDirection);
                            _ = pickRoomPreset(pNeighbor);
                        }
                    }
                }
            }
        }
    }
}

/// AllocateRoomEx (Maze.cpp:325).
pub fn AllocateRoomEx(pSourceRoom: [*c]s.D2RoomExStrc, nNeighborDir: i32, nDirection: i32, bPickPresets: i32) [*c]s.D2RoomExStrc {
    _ = nDirection;
    const pNew = DrlgRoom.allocRoomEx(pSourceRoom.*.pLevel, 2);
    const pMaze = mazeTxt(pNew.*.pLevel);
    pNew.*.sCoords.WorldSize.x = pMaze.*.SizeX;
    pNew.*.sCoords.WorldSize.y = pMaze.*.SizeY;
    if (!deps.ReplaceRoomWithNewRoom(nNeighborDir, pNew, pSourceRoom)) {
        DrlgRoom.freeDrlgRoomEx(pNew);
        return null;
    }
    DrlgRoom.allocNodesForBothRoomEx(pSourceRoom, pNew, nNeighborDir);
    if (bPickPresets != 0) pickRoomPresets(pNew);
    _ = DrlgRoom.AddRoomExToLevel(pSourceRoom.*.pLevel, pNew);
    return pNew;
}

/// DRLGMAZE_AllocRoomExAndPickPreset (Maze.cpp:348). Allocates a room in eDir off
/// pRoomExStrc and assigns it a FIXED preset. Ghidra lost the three register/stack
/// params (`nPresetIndex`, `nVariant`, `_bShouldPickSourcePreset` show as phantom
/// locals); recovered from the engine call sites (1.14d 0x672984 PUSH 0x14d, 0x672a89
/// PUSH 0x150). The new room is LOCKED with that fixed def/variant — it is NOT
/// re-derived via DRLGMAZE_PickRoomPreset (the recon writes pRoomData[0]/[1] directly).
pub fn allocRoomExAndPickPreset(eDir: i32, pRoomExStrc: [*c]s.D2RoomExStrc, nPresetIndex: i32, nVariant: i32, bPickSource: i32) [*c]s.D2RoomExStrc {
    const pNewRoom = DrlgRoom.allocRoomEx(pRoomExStrc.*.pLevel, 2);
    const pMaze = mazeTxt(pNewRoom.*.pLevel);
    pNewRoom.*.sCoords.WorldSize.x = pMaze.*.SizeX;
    pNewRoom.*.sCoords.WorldSize.y = pMaze.*.SizeY;
    if (!deps.ReplaceRoomWithNewRoom(eDir, pNewRoom, pRoomExStrc)) {
        DrlgRoom.freeDrlgRoomEx(pNewRoom);
        return null;
    }
    DrlgRoom.allocNodesForBothRoomEx(pRoomExStrc, pNewRoom, eDir);
    _ = DrlgRoom.AddRoomExToLevel(pRoomExStrc.*.pLevel, pNewRoom);
    if (bPickSource != 0) _ = pickRoomPreset(pRoomExStrc);
    setFlags(pNewRoom, getFlags(pNewRoom) | 2);
    setDef(pNewRoom, nPresetIndex);
    setVariant(pNewRoom, nVariant);
    return pNewRoom;
}

/// ReplaceRoomWith (Maze.cpp:407). Finds the first non-locked room, grows a new
/// room off it in nDirection, locks it with (nPresetIndex,nVariant).
pub fn ReplaceRoomWith(nDirection: i32, nPresetIndex: i32, nVariant: i32, pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    var pNewRoom: [*c]s.D2RoomExStrc = null;
    while (true) {
        if (pRoomEx == null) return pNewRoom;
        if (!hasMapDs1(pRoomEx)) {
            pNewRoom = DrlgRoom.allocRoomEx(pRoomEx.*.pLevel, 2);
            const pMaze = mazeTxt(pNewRoom.*.pLevel);
            pNewRoom.*.sCoords.WorldSize.x = pMaze.*.SizeX;
            pNewRoom.*.sCoords.WorldSize.y = pMaze.*.SizeY;
            if (!deps.ReplaceRoomWithNewRoom(nDirection, pNewRoom, pRoomEx)) {
                DrlgRoom.freeDrlgRoomEx(pNewRoom);
                pNewRoom = null;
            } else {
                DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pNewRoom, nDirection);
                _ = DrlgRoom.AddRoomExToLevel(pRoomEx.*.pLevel, pNewRoom);
                _ = pickRoomPreset(pRoomEx);
                setFlags(pNewRoom, getFlags(pNewRoom) | 2);
                setDef(pNewRoom, nPresetIndex);
                setVariant(pNewRoom, nVariant);
            }
            if (pNewRoom != null) return pNewRoom;
        }
        pRoomEx = pRoomEx.*.pRoomExNext;
    }
}

/// DRLGMAZE_BuildRoomGrid (Maze.cpp:448). Builds the initial nGridSize x nGridSize
/// ring of connected rooms off pRoomExFirst (four edge passes).
pub fn buildRoomGrid(nGridSize: i32, pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pFirstRoom: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    var pRoomEx: [*c]s.D2RoomExStrc = pFirstRoom;
    var pNewRoom: [*c]s.D2RoomExStrc = pFirstRoom;

    var nRemaining = nGridSize - 1;
    if (nRemaining > 0) {
        while (true) {
            pRoomEx = DrlgRoom.allocRoomEx(pNewRoom.*.pLevel, 2);
            const t = mazeTxt(pRoomEx.*.pLevel);
            pRoomEx.*.sCoords.WorldSize.x = t.*.SizeX;
            pRoomEx.*.sCoords.WorldSize.y = t.*.SizeY;
            if (!deps.ReplaceRoomWithNewRoom(1, pRoomEx, pNewRoom)) {
                DrlgRoom.freeDrlgRoomEx(pRoomEx);
                pRoomEx = null;
            } else {
                DrlgRoom.allocNodesForBothRoomEx(pNewRoom, pRoomEx, 1);
                pickRoomPresets(pRoomEx);
                _ = DrlgRoom.AddRoomExToLevel(pNewRoom.*.pLevel, pRoomEx);
                _ = pickRoomPreset(pNewRoom);
                _ = pickRoomPreset(pRoomEx);
            }
            nRemaining -= 1;
            pNewRoom = pRoomEx;
            if (nRemaining == 0) break;
        }
    }

    nRemaining = nGridSize - 1;
    if (nRemaining > 0) {
        while (true) {
            pNewRoom = DrlgRoom.allocRoomEx(pRoomEx.*.pLevel, 2);
            const t = mazeTxt(pNewRoom.*.pLevel);
            pNewRoom.*.sCoords.WorldSize.x = t.*.SizeX;
            pNewRoom.*.sCoords.WorldSize.y = t.*.SizeY;
            if (!deps.ReplaceRoomWithNewRoom(0, pNewRoom, pRoomEx)) {
                DrlgRoom.freeDrlgRoomEx(pNewRoom);
                pRoomEx = null;
            } else {
                DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pNewRoom, 0);
                pickRoomPresets(pNewRoom);
                _ = DrlgRoom.AddRoomExToLevel(pRoomEx.*.pLevel, pNewRoom);
                _ = pickRoomPreset(pRoomEx);
                _ = pickRoomPreset(pNewRoom);
                pRoomEx = pNewRoom;
            }
            nRemaining -= 1;
            if (nRemaining == 0) break;
        }
    }

    nRemaining = nGridSize - 1;
    if (nRemaining > 0) {
        while (true) {
            pNewRoom = DrlgRoom.allocRoomEx(pRoomEx.*.pLevel, 2);
            const t = mazeTxt(pNewRoom.*.pLevel);
            pNewRoom.*.sCoords.WorldSize.x = t.*.SizeX;
            pNewRoom.*.sCoords.WorldSize.y = t.*.SizeY;
            if (!deps.ReplaceRoomWithNewRoom(3, pNewRoom, pRoomEx)) {
                DrlgRoom.freeDrlgRoomEx(pNewRoom);
                pRoomEx = null;
            } else {
                DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pNewRoom, 3);
                pickRoomPresets(pNewRoom);
                _ = DrlgRoom.AddRoomExToLevel(pRoomEx.*.pLevel, pNewRoom);
                _ = pickRoomPreset(pRoomEx);
                _ = pickRoomPreset(pNewRoom);
                pRoomEx = pNewRoom;
            }
            nRemaining -= 1;
            if (nRemaining == 0) break;
        }
    }

    var nLast = nGridSize - 2;
    if (nLast > 0) {
        while (true) {
            pNewRoom = DrlgRoom.allocRoomEx(pRoomEx.*.pLevel, 2);
            const t = mazeTxt(pNewRoom.*.pLevel);
            pNewRoom.*.sCoords.WorldSize.x = t.*.SizeX;
            pNewRoom.*.sCoords.WorldSize.y = t.*.SizeY;
            if (!deps.ReplaceRoomWithNewRoom(2, pNewRoom, pRoomEx)) {
                DrlgRoom.freeDrlgRoomEx(pNewRoom);
                pRoomEx = null;
            } else {
                DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pNewRoom, 2);
                pickRoomPresets(pNewRoom);
                _ = DrlgRoom.AddRoomExToLevel(pRoomEx.*.pLevel, pNewRoom);
                _ = pickRoomPreset(pRoomEx);
                _ = pickRoomPreset(pNewRoom);
                pRoomEx = pNewRoom;
            }
            nLast -= 1;
            if (nLast == 0) break;
        }
    }

    DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pFirstRoom, 2);
    _ = pickRoomPreset(pRoomEx);
    _ = pickRoomPreset(pFirstRoom);
}

/// GetRandomRoomExFromLevel (Maze.cpp:559). Picks a random room; the inlined
/// pow2/modulo seed advance == RANDOM_RandomNumberSelector.
pub fn GetRandomRoomExFromLevel(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    const nCount = pLevel.*.nRoomExCount;
    var nSel: u32 = 0;
    if (nCount >= 1) {
        // Recon (Maze.cpp:559) inlines the pick: advance the level seed, then
        //   pow2:     (count-1) & sSeed.nSeedLow
        //   non-pow2: sSeed % count
        // Ghidra widened the non-pow2 modulo to the full 64-bit state ((uint64_t)sSeed),
        // but the engine takes it on the 32-bit LOW word (the deep golden + the verified
        // hand-port both require low%count here — 64-bit picks a different room with the
        // SAME seed advance, silently diverging the layout). Use the low word.
        const sNew = rng.sEEDNEXT(pLevel.*.sSeed);
        pLevel.*.sSeed = sNew;
        const low: u32 = @bitCast(sNew.nSeedLow);
        const count: u32 = @bitCast(nCount);
        nSel = if (count & (count -% 1) == 0) low & (count -% 1) else low % count;
    }
    var pRoom: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (nSel != 0) : (nSel -= 1) pRoom = pRoom.*.pRoomExNext;
    return pRoom;
}

/// ActualLevelGeneration (Maze.cpp:590). Grows the level to its room count.
pub fn ActualLevelGeneration(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pMazeTxt = mazeTxt(pLevel);
    const nDiff: usize = pLevel.*.pDrlg.?.nDifficulty;
    const aRooms: [3]i32 = pMazeTxt.*.Rooms;
    var nRooms: i32 = aRooms[nDiff];
    if (pLevel.*.eD2LevelId == pLevel.*.pDrlg.?.nStaffTombLevel) nRooms *= 3;
    if (pLevel.*.eD2LevelId == pLevel.*.pDrlg.?.nBossTombLevel) nRooms *= 2;

    while (pLevel.*.nRoomExCount < nRooms) {
        const pRoomEx = GetRandomRoomExFromLevel(pLevel);
        const nSeed = rng.sEEDNEXT(pRoomEx.*.sSeed);
        const nRandDirection: i32 = nSeed.nSeedLow & 3;
        pRoomEx.*.sSeed = nSeed;
        if (!hasMapDs1(pRoomEx)) {
            const pRoomExNew = DrlgRoom.allocRoomEx(pRoomEx.*.pLevel, 2);
            const t = mazeTxt(pRoomExNew.*.pLevel);
            pRoomExNew.*.sCoords.WorldSize.x = t.*.SizeX;
            pRoomExNew.*.sCoords.WorldSize.y = t.*.SizeY;
            if (!deps.ReplaceRoomWithNewRoom(nRandDirection, pRoomExNew, pRoomEx)) {
                DrlgRoom.freeDrlgRoomEx(pRoomExNew);
            } else {
                DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pRoomExNew, nRandDirection);
                pickRoomPresets(pRoomExNew);
                _ = DrlgRoom.AddRoomExToLevel(pRoomEx.*.pLevel, pRoomExNew);
                _ = pickRoomPreset(pRoomEx);
                _ = pickRoomPreset(pRoomExNew);
            }
        }
    }
}

/// DRLGMAZE_CanPlaceRoomInDirection (Maze.cpp:818). Test-places a room in eDir;
/// returns nonzero if it fits (the test room is freed). NOTE: consumes seed via
/// the test DRLGROOMEX_AllocRoomEx — part of the faithful seed stream.
pub fn canPlaceRoomInDirection(eDir: i32, pRoomEx: [*c]s.D2RoomExStrc) u32 {
    if (hasMapDs1(pRoomEx)) return 0;
    var pOrth: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
    while (true) {
        if (pOrth == null) {
            const pTestRoom = DrlgRoom.allocRoomEx(pRoomEx.*.pLevel, 2);
            const t = mazeTxt(pTestRoom.*.pLevel);
            pTestRoom.*.sCoords.WorldSize.x = t.*.SizeX;
            pTestRoom.*.sCoords.WorldSize.y = t.*.SizeY;
            if (deps.ReplaceRoomWithNewRoom(eDir, pTestRoom, pRoomEx)) {
                DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pTestRoom, eDir);
                _ = DrlgRoom.AddRoomExToLevel(pRoomEx.*.pLevel, pTestRoom);
                _ = pickRoomPreset(pTestRoom);
                DrlgRoom.freeDrlgRoomEx(pTestRoom);
                return 1;
            }
            DrlgRoom.freeDrlgRoomEx(pTestRoom);
            return 0;
        }
        if (pOrth.*.neDrlgDirection == eDir) break;
        pOrth = pOrth.*.pNext;
    }
    return 0;
}

/// DRLGMAZE_FindTopMostRoom (Maze.cpp:861).
pub fn findTopMostRoom(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    var pTopMost: [*c]s.D2RoomExStrc = null;
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (pRoomEx != null) : (pRoomEx = pRoomEx.*.pRoomExNext) {
        if (pTopMost == null or pRoomEx.*.sCoords.WorldPosition.y < pTopMost.*.sCoords.WorldPosition.y) {
            if (canPlaceRoomInDirection(DIRECTION_NORTHEAST, pRoomEx) != 0) pTopMost = pRoomEx;
        }
    }
    return pTopMost;
}

/// DRLGMAZE_FindLeftMostRoom (Maze.cpp:879).
pub fn findLeftMostRoom(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    var pLeftMost: [*c]s.D2RoomExStrc = null;
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (pRoomEx != null) : (pRoomEx = pRoomEx.*.pRoomExNext) {
        if (pLeftMost == null or pRoomEx.*.sCoords.WorldPosition.x < pLeftMost.*.sCoords.WorldPosition.x) {
            if (canPlaceRoomInDirection(DIRECTION_SOUTHEAST, pRoomEx) != 0) pLeftMost = pRoomEx;
        }
    }
    return pLeftMost;
}

/// DRLGMAZE_FindRightMostRoom (Maze.cpp:897).
pub fn findRightMostRoom(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    var pRightMost: [*c]s.D2RoomExStrc = null;
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (pRoomEx != null) : (pRoomEx = pRoomEx.*.pRoomExNext) {
        if (pRightMost == null or pRightMost.*.sCoords.WorldPosition.x < pRoomEx.*.sCoords.WorldPosition.x) {
            if (canPlaceRoomInDirection(DIRECTION_SOUTHWEST, pRoomEx) != 0) pRightMost = pRoomEx;
        }
    }
    return pRightMost;
}

/// DRLGMAZE_FindBottomMostRoom (Maze.cpp:915).
pub fn findBottomMostRoom(pLevel: [*c]s.D2DrlgLevelStrc) [*c]s.D2RoomExStrc {
    var pBottomMost: [*c]s.D2RoomExStrc = null;
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (pRoomEx != null) : (pRoomEx = pRoomEx.*.pRoomExNext) {
        if (pBottomMost == null or pBottomMost.*.sCoords.WorldPosition.y < pRoomEx.*.sCoords.WorldPosition.y) {
            if (canPlaceRoomInDirection(DIRECTION_NORTHWEST, pRoomEx) != 0) pBottomMost = pRoomEx;
        }
    }
    return pBottomMost;
}

/// ReplaceRoom (Maze.cpp:935). Replaces a source-preset room with a dest preset,
/// or grows one if none exists; advances *pRoll (mod 4, signed) when provided.
const DBG_BARRACKS_REPLACE = false;
pub fn ReplaceRoom(pDrlgReplaceRoom: [*c]s.D2DrlgReplaceRoomStrc, pLevel: [*c]s.D2DrlgLevelStrc, pRoll: ?*i32) void {
    if (DBG_BARRACKS_REPLACE and pLevel.*.eD2LevelId == .Barracks) {
        @import("std").debug.print("PORT barracks_replace roomEx={d} seedLo=0x{x:0>8}\n", .{ pLevel.*.nRoomExCount, @as(u32, @bitCast(pLevel.*.sSeed.nSeedLow)) });
    }
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    const nDestPresetId = @intFromEnum(pDrlgReplaceRoom.*.nDestLevelPrestId);
    const nDestPickedFile = pDrlgReplaceRoom.*.nDestPickedFile;
    while (true) {
        if (pRoomEx == null) {
            _ = ReplaceRoomWith(pDrlgReplaceRoom.*.nDirection, nDestPresetId, nDestPickedFile, pLevel);
            advanceRoll(pRoll);
            return;
        }
        if (!hasMapDs1(pRoomEx) and getDef(pRoomEx) == @intFromEnum(pDrlgReplaceRoom.*.nSourceLevelPrestId)) {
            setFlags(pRoomEx, getFlags(pRoomEx) | 2);
            setDef(pRoomEx, nDestPresetId);
            setVariant(pRoomEx, nDestPickedFile);
            advanceRoll(pRoll);
            return;
        }
        pRoomEx = pRoomEx.*.pRoomExNext;
    }
}

inline fn advanceRoll(pRoll: ?*i32) void {
    const p = pRoll orelse return;
    // recon: nNext = (*pRoll + 1) & 0x80000003; if(<0) nNext = (nNext-1 | -4)+1;  (== +1 mod 4)
    var nNext: i32 = @bitCast(@as(u32, @bitCast(p.* + 1)) & 0x80000003);
    if (nNext < 0) nNext = (@as(i32, @bitCast(@as(u32, @bitCast(nNext - 1)) | 0xFFFFFFFC))) + 1;
    p.* = nNext;
}

/// ForAllButDenOfEvil (Maze.cpp:983). Seed-driven "+15" special-preset
/// replacement (the ScanReplaceSpecial step that produces the out-of-range Defs).
pub fn ForAllButDenOfEvil(pLevel: [*c]s.D2DrlgLevelStrc) void {
    var nFirstFileOffset: i32 = undefined;
    switch (pLevel.*.nLevelType) {
        .act1_caves => nFirstFileOffset = 0x34,
        .act1_crypt => nFirstFileOffset = 0x6c,
        .barracks_family => nFirstFileOffset = 0xa7,
        .act1_jail => nFirstFileOffset = 0xcd,
        .act1_catacombs => nFirstFileOffset = 0x101,
        .act2_sewer => nFirstFileOffset = 0x12d,
        .act2_tombs => nFirstFileOffset = 0x19d,
        .act3_durance => nFirstFileOffset = 0x2f1,
        .act3_dungeon => nFirstFileOffset = 0x298,
        .act3_sewers => nFirstFileOffset = 0x2c0,
        else => return,
    }
    if (pLevel.*.eD2LevelId == .DenofEvil) return;

    var aShuffleTable: [16]i32 = undefined;
    aShuffleTable[8] = 8;
    var DVar2 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar2;
    // % 15 on the 32-bit low word only (1.14d 0x6736a5: MUL 0x88888889 / SHR EDX,3
    // = unsigned 32-bit /15 of the new low word). Ghidra mis-widened to 64-bit.
    aShuffleTable[0xf] = @intCast(@as(u32, @bitCast(DVar2.nSeedLow)) % 0xf);
    var nTargetCount = @divTrunc(pLevel.*.nRoomExCount, 5) + 1;
    aShuffleTable[0] = 0;
    aShuffleTable[1] = 1;
    aShuffleTable[2] = 2;
    aShuffleTable[3] = 3;
    aShuffleTable[4] = 4;
    aShuffleTable[5] = 5;
    aShuffleTable[6] = 6;
    aShuffleTable[7] = 7;
    aShuffleTable[9] = 9;
    aShuffleTable[10] = 10;
    aShuffleTable[0xb] = 0xb;
    aShuffleTable[0xc] = 0xc;
    aShuffleTable[0xd] = 0xd;
    aShuffleTable[0xe] = 0xe;
    if (nTargetCount < 3) nTargetCount = 2;

    var nMaxTries = pLevel.*.nRoomExCount * 2;
    var nShuffleCount: i32 = 0xf;
    var nShufflePos: i32 = 0;
    while (true) {
        DVar2 = rng.sEEDNEXT(pLevel.*.sSeed);
        pLevel.*.sSeed = DVar2;
        const DVar3 = rng.sEEDNEXT(pLevel.*.sSeed);
        pLevel.*.sSeed = DVar3;
        const nSwapTemp = nShuffleCount - 1;
        nShuffleCount = nSwapTemp;
        const nIdx2: usize = @intCast(@as(u32, @bitCast(DVar2.nSeedLow)) % 0xf);
        const nIdx3: usize = @intCast(@as(u32, @bitCast(DVar3.nSeedLow)) % 0xf);
        const tmp = aShuffleTable[nIdx2];
        aShuffleTable[nIdx2] = aShuffleTable[nIdx3];
        aShuffleTable[nIdx3] = tmp;
        nShufflePos = aShuffleTable[0xf];
        if (nSwapTemp == 0) break;
    }

    while (nTargetCount != 0 and nMaxTries != 0) : (nMaxTries -= 1) {
        const nTargetDef = aShuffleTable[@intCast(nShufflePos)] + nFirstFileOffset;
        aShuffleTable[0xf] = nTargetDef + 0xf;
        var pDVar1: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
        while (pDVar1 != null) : (pDVar1 = pDVar1.*.pRoomExNext) {
            if (!hasMapDs1(pDVar1) and getDef(pDVar1) == nTargetDef) {
                setFlags(pDVar1, getFlags(pDVar1) | 2);
                nTargetCount -= 1;
                setDef(pDVar1, aShuffleTable[0xf]);
                setVariant(pDVar1, -1);
                break;
            }
        }
        nShufflePos += 1;
        // recon: nShufflePos %= 15 via signed magic divide
        const prod: i64 = @as(i64, nShufflePos) * 0x77777777;
        const q: i32 = @as(i32, @truncate(prod >> 0x20)) - nShufflePos;
        nShufflePos += ((q >> 3) - (q >> 0x1f)) * 0xf;
    }
}

/// gaMazeLevelTypeCaseTable (globals_drlg.cpp:208). Maps level type -> preset case.
const gaMazeLevelTypeCaseTable = [40]u8{
    0xf4, 0x39, 0x67, 0x0,  0x0,
    0x1,  0xf,  0xf,  0x2,  0x3,
    0xf,  0x4,  0xf,  0xf,  0x5,
    0xf,  0xf,  0xf,  0x6,  0x7,
    0xf,  0xf,  0xf,  0x8,  0xf,
    0x9,  0xa,  0xf,  0xf,  0xb,
    0xf,  0xf,  0xf,  0xf,  0xc,
    0xd,  0xe,  0xcc, 0xcc, 0xcc,
};

/// case -> base preset Def (the recon's `pSelectedOffset` immediates).
fn mazePresetBaseForCase(caseVal: u8) ?i32 {
    return switch (caseVal) {
        0x0 => 0x34,
        0x1 => 0x6c,
        0x2 => 0xa7,
        0x3 => 0xcd,
        0x4 => 0x101,
        0x5 => 0x12d,
        0x6 => 0x19d,
        0x7 => 0x1e1,
        0x8 => 0x2f1,
        0x9 => 0x298,
        0xa => 0x2c0,
        0xb => 0x344,
        0xc => 0x3ea,
        0xd => 0x422,
        0xe => 0x41c,
        else => null, // 0xf: no random pick
    };
}

/// DRLGMAZE_SelectRandomPresetFile (Maze.cpp:1090). For nPresetFile==-1 (the maze
/// rooms — PickRoomPreset leaves variant=-1 for sewers) it picks a DS1 file variant
/// for the room: if the room's LvlPrest Def falls inside its level-type preset group
/// [base, base+4 ints) it draws RANDOM_RandomNumberSelector(seed, Files) once per
/// distinct Def (cached in pLevelLinkNodeFirst) — a real seed consumer. pState[2]'s
/// truncated-pointer deref is replaced with named pDrlgMap field access (64-bit).
pub fn selectRandomPresetFile(nPresetFile: i32, pLevel: [*c]s.D2DrlgLevelStrc, pDrlgMap: [*c]s.D2DrlgMapStrc) i32 {
    if (nPresetFile != -1) {
        pDrlgMap.*.nRandomMapFileSelector = nPresetFile; // pState[1]
        return nPresetFile;
    }
    const pLvlPrest = tables.lvlPrestGetLine(pDrlgMap.*.nNumber);
    const nFirstFile = pLvlPrest.*.Def; // *(int*)pState[2]
    const nLevelType = @intFromEnum(pLevel.*.nLevelType);
    if (nLevelType - 3 >= 0x21) return nLevelType - 3;
    const caseVal = gaMazeLevelTypeCaseTable[@intCast(nLevelType + 1)];
    const base = mazePresetBaseForCase(caseVal) orelse return 0;
    if (base >= nFirstFile) return base;
    // Recon's `pSelectedOffset + 4` is int* POINTER arithmetic (+4 elems = +16
    // bytes), not scalar +4 — Game.exe 1.14d @006738c0:
    //   nResult = pSelectedOffset + 4, nFirstFile < (int)(pSelectedOffset + 4)
    // The closure Maze.cpp:1162 keeps the int* type; transforming it as scalar +4
    // (the emitter byteoffset bug) wrongly early-returns defs in [base+4, base+16),
    // skipping their RANDOM_RandomNumberSelector seed roll.
    if (nFirstFile >= base + 16) return base + 16;

    var pNode: [*c]s.D2DrlgLevelLinkNodeStrc = pLevel.*.pLevelLinkNodeFirst;
    var found = false;
    while (pNode != null) : (pNode = pNode.*.pNext) {
        if (pNode.*.dwData0 == nFirstFile) {
            found = true;
            break;
        }
    }
    if (!found) {
        const nFileCount = pLvlPrest.*.Files; // ((int*)pState[2])[0x10]
        pNode = @ptrCast(@alignCast(pool.AllocServerMemory(pLevel.*.pDrlg.?.pMemoryPool, @sizeOf(s.D2DrlgLevelLinkNodeStrc), ".\\DRLG\\Maze.cpp", 0x780)));
        pNode.*.dwData0 = nFirstFile;
        pNode.*.dwData1 = nFileCount;
        pNode.*.dwData2 = @bitCast(rng.randomNumberSelector(&pLevel.*.sSeed, @bitCast(nFileCount)));
        pNode.*.pNext = pLevel.*.pLevelLinkNodeFirst;
        pLevel.*.pLevelLinkNodeFirst = pNode;
    }
    const nPicked = @mod(pNode.*.dwData2 + 1, pNode.*.dwData1);
    pNode.*.dwData2 = nPicked;
    pDrlgMap.*.nRandomMapFileSelector = nPicked; // pState[1]
    return nPicked;
}

/// GenerateWolrdstoneAndTombs (Maze.cpp:748, 1.14d 006718c0). Builds the 3-room
/// starter spine (rolling direction off the level seed) then writes the level-type
/// terminal preset id (0x11 Tombs / 0x22 Worldstone) onto the root room.
const gnMazeRoomCountX = [4]struct { nX: i32, nY: i32 }{
    .{ .nX = 0x1bf, .nY = 0x433 },
    .{ .nX = 0x1bc, .nY = 0x435 },
    .{ .nX = 0x1be, .nY = 0x434 },
    .{ .nX = 0x1bd, .nY = 0x432 },
};
pub fn GenerateWolrdstoneAndTombs(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pRoomExStrc: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    const sNextSeed = rng.sEEDNEXT(pLevel.*.sSeed);
    var nRollValue: i32 = sNextSeed.nSeedLow & 3;
    pLevel.*.sSeed = sNextSeed;
    var nLoopCount: i32 = 3;
    while (true) {
        const pNew = DrlgRoom.allocRoomEx(pRoomExStrc.*.pLevel, 2);
        const t = mazeTxt(pNew.*.pLevel);
        pNew.*.sCoords.WorldSize.x = t.*.SizeX;
        pNew.*.sCoords.WorldSize.y = t.*.SizeY;
        if (!deps.ReplaceRoomWithNewRoom(nRollValue, pNew, pRoomExStrc)) {
            DrlgRoom.freeDrlgRoomEx(pNew);
        } else {
            DrlgRoom.allocNodesForBothRoomEx(pRoomExStrc, pNew, nRollValue);
            pickRoomPresets(pNew);
            _ = DrlgRoom.AddRoomExToLevel(pRoomExStrc.*.pLevel, pNew);
            _ = pickRoomPreset(pRoomExStrc);
            _ = pickRoomPreset(pNew);
        }
        // nRollValue = (nRollValue + 1) mod 4 (signed &0x80000003 idiom).
        nRollValue = @bitCast(@as(u32, @bitCast(nRollValue + 1)) & 0x80000003);
        if (nRollValue < 0) nRollValue = (@as(i32, @bitCast(@as(u32, @bitCast(nRollValue - 1)) | 0xFFFFFFFC))) + 1;
        nLoopCount -= 1;
        if (nLoopCount == 0) break;
    }
    const idx: usize = @intCast(nRollValue);
    if (pLevel.*.nLevelType == .act2_tombs) {
        setDef(pRoomExStrc, gnMazeRoomCountX[idx].nX);
        setFlags(pRoomExStrc, getFlags(pRoomExStrc) | 2);
        setVariant(pRoomExStrc, -1);
    } else if (pLevel.*.nLevelType == .act5_worldstone) {
        setDef(pRoomExStrc, gnMazeRoomCountX[idx].nY);
        setFlags(pRoomExStrc, getFlags(pRoomExStrc) | 2);
        setVariant(pRoomExStrc, -1);
    }
}

/// InitAllRoomsEx (Game.exe 1.14d @ 00673a60). Allocates a DrlgMap + builds ONE
/// area room then relinks adjacency per orth, then frees the input RoomEx. Calls
/// the SEED-CONSUMING Preset pipeline (deps).
///
/// NOTE: BuildArea is called ONCE before the orth loop — the loop only relinks
/// adjacency (DRLGROOMEX_AllocNodesForBothRoomEx) per orth. The closure snapshot
/// recon/closure/Maze.cpp:1210 wrongly hoists BuildArea inside the loop (a stale
/// decompiler artifact: the loop-invariant pRoomEx_00 sunk into the loop body).
/// The authoritative Ghidra decompile (session 62fbfe69, InitAllRoomsEx @
/// 00673a60) places BuildArea above the loop — one alloc per ROOM, not per orth.
pub fn InitAllRoomsEx(pRoomEx: [*c]s.D2RoomExStrc, pLevel: [*c]s.D2DrlgLevelStrc) void {
    const nLvlPrestId = getDef(pRoomEx);
    const pDrlgMap = deps.allocDrlgMap(pLevel, nLvlPrestId, @ptrCast(&pRoomEx.*.sCoords), &pLevel.*.sSeed);
    _ = selectRandomPresetFile(getVariant(pRoomEx), pLevel, pDrlgMap);
    const bSingleRoom: i32 = if (pRoomEx.*.sCoords.WorldSize.x < 0xd and pRoomEx.*.sCoords.WorldSize.y < 0xd) 1 else 0;
    const pRoomEx_00 = deps.BuildArea(pLevel, pDrlgMap, 0, bSingleRoom);
    var pOrth: [*c]s.D2DrlgOrthStrc = pRoomEx.*.pOrth;
    while (pOrth != null) : (pOrth = pOrth.*.pNext) {
        if (pOrth.*.nType == 1) {
            DrlgRoom.allocNodesForBothRoomEx(pRoomEx_00, pOrth.*.pRoomEx, pOrth.*.neDrlgDirection);
        }
    }
    DrlgRoom.freeDrlgRoomEx(pRoomEx);
}

/// DRLGMAZE_GenerateLevel (Maze.cpp:1229). Full per-level-type dispatch + the
/// seed-consuming InitAllRoomsEx (Preset pipeline) tail. Returns 1 when the level
/// type/id is transformed; returns 0 (after allocating only the root room) for the
/// not-yet-transformed arms (Arcane 0x13, Baal 0x23, Barracks/River specials) so
/// the harness records a room-count mismatch instead of crashing.
pub fn generateLevel(pLevel: [*c]s.D2DrlgLevelStrc) i32 {
    if (!generateRoomLayout(pLevel)) return 0;
    var pSearchRoom: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (pSearchRoom != null) {
        const pNextRoom = pSearchRoom.*.pRoomExNext;
        InitAllRoomsEx(pSearchRoom, pLevel);
        pSearchRoom = pNextRoom;
    }
    return 1;
}

/// Act3 sewers special (Maze.cpp:1338, levelId 0x5c / Sewers of Kurast extra). The
/// type-0x19 arm for the one level that builds a 5x5 grid and rewrites four fixed
/// preset markers before ReplaceSewerRooms. Returns false if the 0x2c5 anchor room
/// is never found (recon error-halt).
fn act3SewerSpecial0x5c(pLevel: [*c]s.D2DrlgLevelStrc) bool {
    buildRoomGrid(5, pLevel);
    // Find the 0x2c5 anchor; if present rewrite the four fixed markers in order.
    var found = false;
    var pRoomIter: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (pRoomIter != null) : (pRoomIter = pRoomIter.*.pRoomExNext) {
        if (!hasMapDs1(pRoomIter) and getDef(pRoomIter) == 0x2c5) {
            setFlags(pRoomIter, getFlags(pRoomIter) | 2);
            setDef(pRoomIter, 0x2df);
            setVariant(pRoomIter, -1);
            found = true;
            break;
        }
    }
    if (!found) return false;
    rewriteMarker(pLevel, 0x2c6, 0x2e0) catch return false;
    rewriteMarker(pLevel, 0x2c9, 0x2e1) catch return false;
    rewriteMarker(pLevel, 0x2ca, 0x2e2) catch return false;
    ActualLevelGeneration(pLevel);
    Act3.ReplaceSewerRooms(pLevel);
    return true;
}

fn rewriteMarker(pLevel: [*c]s.D2DrlgLevelStrc, srcDef: i32, dstDef: i32) !void {
    var p: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    while (p != null) : (p = p.*.pRoomExNext) {
        if (!hasMapDs1(p) and getDef(p) == srcDef) {
            setFlags(p, getFlags(p) | 2);
            setDef(p, dstDef);
            setVariant(p, -1);
            return;
        }
    }
    return error.MarkerNotFound;
}

/// DRLGMAZE_ExpandRoomsWithPresets (Maze.cpp:632, 1.14d 00671320). Snapshots the
/// room list, then grows a fixed-preset marker room off every original room (except
/// pSkipRoom) in all 8 directions, each locked to nDefaultPresetId. Ghidra dropped
/// the two stack params (nDefaultPresetId@stack:0x4, pSkipRoom@stack:0x8) -> phantom
/// locals; recovered via set_custom_signature + the call sites: SetupBaalChamber
/// @0x671430 pushes (0x344, NULL), GenerateRiverOfFlames @0x673320 pushes
/// (0x344, pLastConnectorRoom).
pub fn expandRoomsWithPresets(pLevel: [*c]s.D2DrlgLevelStrc, nDefaultPresetId: i32, pSkipRoom: [*c]s.D2RoomExStrc) void {
    const pMemPool = pLevel.*.pDrlg.?.pMemoryPool;
    const nRoomCount: usize = @intCast(pLevel.*.nRoomExCount);
    if (nRoomCount == 0) return;
    const pRoomPtrArray: [*]([*c]s.D2RoomExStrc) = @ptrCast(@alignCast(pool.AllocServerMemory(pMemPool, nRoomCount * @sizeOf([*c]s.D2RoomExStrc), ".\\DRLG\\Maze.cpp", 0x271)));
    var pRoomIter: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    var i: usize = 0;
    while (i < nRoomCount) : (i += 1) {
        pRoomPtrArray[i] = pRoomIter;
        pRoomIter = pRoomIter.*.pRoomExNext;
    }
    i = 0;
    while (i < nRoomCount) : (i += 1) {
        if (pRoomPtrArray[i] != pSkipRoom) {
            var nDir: i32 = 0;
            while (nDir < 8) : (nDir += 1) {
                const pRoom = pRoomPtrArray[i];
                const pExpanded = DrlgRoom.allocRoomEx(pRoom.*.pLevel, 2);
                const t = mazeTxt(pExpanded.*.pLevel);
                pExpanded.*.sCoords.WorldSize.x = t.*.SizeX;
                pExpanded.*.sCoords.WorldSize.y = t.*.SizeY;
                if (!deps.ReplaceRoomWithNewRoom(nDir, pExpanded, pRoom)) {
                    DrlgRoom.freeDrlgRoomEx(pExpanded);
                } else {
                    DrlgRoom.allocNodesForBothRoomEx(pRoom, pExpanded, nDir);
                    _ = DrlgRoom.AddRoomExToLevel(pRoom.*.pLevel, pExpanded);
                    setFlags(pExpanded, getFlags(pExpanded) | 2);
                    setDef(pExpanded, nDefaultPresetId);
                    setVariant(pExpanded, -1);
                }
            }
        }
    }
    pool.FreeServerMemory(pMemPool, @ptrCast(pRoomPtrArray), ".\\DRLG\\Maze.cpp", 0x288, 0);
}

/// gaBaalChamberPresets (globals_drlg, 1.14d .rdata 0x6ef828; verified byte-for-byte).
/// 4 directions x 2 chambers x {preset, dir, variant}.
const gaBaalChamberPresets = [24]i32{
    0x41e, 1, 0, 0x41d, 3, 1,
    0x41e, 1, 1, 0x41d, 3, 0,
    0x41f, 0, 1, 0x420, 2, 0,
    0x41f, 0, 0, 0x420, 2, 1,
};

/// SetupBaalChamber (Maze.cpp:699, 1.14d 00671430). Throne of Destruction: rolls a
/// direction 0-3 off the root room's seed, grows two fixed-preset chambers, then
/// expands. The two AllocRoomExAndPickPreset calls' preset/variant/bPickSource args
/// were Ghidra phantom-register drops; recovered (after fixing the callee signature)
/// from the recovered call site @0x671430 — preset=col0, eDir=col1, variant=col2,
/// bPickSource=1 — plus ExpandRoomsWithPresets(0x344, NULL).
pub fn SetupBaalChamber(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    const sNewSeed = rng.sEEDNEXT(pRoomEx.*.sSeed);
    const nDir: usize = @intCast(sNewSeed.nSeedLow & 3);
    pRoomEx.*.sSeed = sNewSeed;
    _ = allocRoomExAndPickPreset(gaBaalChamberPresets[nDir * 6 + 1], pRoomEx, gaBaalChamberPresets[nDir * 6 + 0], gaBaalChamberPresets[nDir * 6 + 2], 1);
    _ = allocRoomExAndPickPreset(gaBaalChamberPresets[nDir * 6 + 4], pRoomEx, gaBaalChamberPresets[nDir * 6 + 3], gaBaalChamberPresets[nDir * 6 + 5], 1);
    expandRoomsWithPresets(pLevel, 0x344, null);
}

// Act2 Arcane Sanctuary (RollArcaneTypePath @0x6719f0)
// Cleaned Ghidra decompile (session 62fbfe69, Game.exe v626): nRoomPtrs retyped to
// D2RoomExStrc*[60], pArmRoomWalker to D2RoomExStrc** — the prior "mangled
// pointer-arith" was (a) direction math `(arm+k)%4` (the &pRoomBranchB[-1].pStatusPrev+2
// idiom resolves to (arm+3)-236+232+2 = (arm+1)%4 since struct size 236 / pStatusPrev
// offset 232 vanish mod 4) and (b) a byte-walker aliasing the room-pointer array
// (pArmRoomWalker = &nRoomPtrs[-2], so pArmRoomWalker[9]=slot7, [0xd]=slot11).

/// One Arcane room placement (the repeated block in RollArcaneTypePath): alloc a
/// RoomEx, size it from the level maze txt, place it adjacent to pParent in
/// nDirection. On overlap-fail free it and return null; on success link both rooms,
/// pick presets, add to the level, and return it.
fn arcanePlaceRoom(pParent: [*c]s.D2RoomExStrc, nDirection: i32) [*c]s.D2RoomExStrc {
    const pNewRoom = DrlgRoom.allocRoomEx(pParent.*.pLevel, 2);
    const t = mazeTxt(pNewRoom.*.pLevel);
    pNewRoom.*.sCoords.WorldSize.x = t.*.SizeX;
    pNewRoom.*.sCoords.WorldSize.y = t.*.SizeY;
    if (!deps.ReplaceRoomWithNewRoom(nDirection, pNewRoom, pParent)) {
        DrlgRoom.freeDrlgRoomEx(pNewRoom);
        return null;
    }
    DrlgRoom.allocNodesForBothRoomEx(pParent, pNewRoom, nDirection);
    pickRoomPresets(pNewRoom);
    _ = DrlgRoom.AddRoomExToLevel(pParent.*.pLevel, pNewRoom);
    _ = pickRoomPreset(pParent);
    _ = pickRoomPreset(pNewRoom);
    return pNewRoom;
}

/// RollArcaneTypePath (Maze.cpp:1317, 1.14d 006719f0). Rolls an initial direction
/// off the level seed, then for each of 4 arms builds a fixed 15-room tree off the
/// start room (slots 8 & 12 are unstored "leaf" rooms). Finally each placed room's
/// variant (nPickedFile, pRoomExData+4) is set to its facing = (arm + initialDir)%4
/// and the start room is tagged with facing 4.
pub fn RollArcaneTypePath(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pStartRoom = pLevel.*.pRoomExFirst;
    const seedRoll = rng.sEEDNEXT(pLevel.*.sSeed);
    const nInitialDir: i32 = seedRoll.nSeedLow & 3;
    pLevel.*.sSeed = seedRoll;

    // 4 arms x 15 room slots (matches the engine's 60-pointer stack array).
    var slots = [_][*c]s.D2RoomExStrc{null} ** 60;

    var arm: i32 = 0;
    while (arm < 4) : (arm += 1) {
        const base: usize = @intCast(arm * 15);
        const dArm = arm & 3;
        const dArm1 = (arm + 1) & 3;
        const dArm2 = (arm + 2) & 3;
        const dArm3 = (arm + 3) & 3;
        slots[base + 0] = arcanePlaceRoom(pStartRoom, dArm);
        slots[base + 1] = arcanePlaceRoom(slots[base + 0], dArm);
        slots[base + 2] = arcanePlaceRoom(slots[base + 1], dArm3);
        slots[base + 3] = arcanePlaceRoom(slots[base + 2], dArm);
        slots[base + 4] = arcanePlaceRoom(slots[base + 3], dArm);
        slots[base + 5] = arcanePlaceRoom(slots[base + 4], dArm);
        slots[base + 6] = arcanePlaceRoom(slots[base + 5], dArm);
        slots[base + 7] = arcanePlaceRoom(slots[base + 6], dArm1);
        _ = arcanePlaceRoom(slots[base + 7], dArm); // leaf -> slot 8 stays null
        slots[base + 9] = arcanePlaceRoom(slots[base + 7], dArm1);
        slots[base + 10] = arcanePlaceRoom(slots[base + 9], dArm2);
        slots[base + 11] = arcanePlaceRoom(slots[base + 10], dArm2);
        _ = arcanePlaceRoom(slots[base + 11], dArm3); // leaf -> slot 12 stays null
        slots[base + 13] = arcanePlaceRoom(slots[base + 11], dArm2);
        slots[base + 14] = arcanePlaceRoom(slots[base + 13], dArm2);
    }

    // Facing pass: each placed room's variant = (slot/15 + initialDir) % 4.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const r = slots[i];
        if (r != null) {
            const facing = (@as(i32, @intCast(i / 15)) + nInitialDir) & 3;
            setVariant(r, facing);
        }
    }
    setVariant(pStartRoom, 4);
}

/// PickSummonerLocation (Maze.cpp:1318, 1.14d 00672e50). Rolls 0-3 off the level
/// seed and replaces the matching marker room with the Summoner/ancient placement.
/// Table values are the .rdata AncientPickLocation array (faithful).
const gaAncientPickLocation = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2ArcaneN, .nDestLevelPrestId = .Act2ArcaneSummonerN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2ArcaneE, .nDestLevelPrestId = .Act2ArcaneSummonerE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2ArcaneS, .nDestLevelPrestId = .Act2ArcaneSummonerS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2ArcaneW, .nDestLevelPrestId = .Act2ArcaneSummonerW, .nDestPickedFile = -1, .nDirection = 2 },
};
pub fn PickSummonerLocation(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    var nRoll: i32 = DVar1.nSeedLow & 3;
    ReplaceRoom(@constCast(&gaAncientPickLocation[@intCast(nRoll)]), pLevel, &nRoll);
}

/// The RoomEx-layer phase of DRLGMAZE_GenerateLevel (recon Maze.cpp:1256 switch) —
/// root room + per-type dispatch + the per-level-id placement (Barracks/River or
/// DRLGLEVEL_AdjustRoomCoordinates) + ForAllButDenOfEvil. Returns false for the
/// not-yet-transformed arms. Split out so the validation harness can inspect the
/// RoomEx list (coords/def/type) before the Preset stage.
pub fn generateRoomLayout(pLevel: [*c]s.D2DrlgLevelStrc) bool {
    const pRoomEx = DrlgRoom.allocRoomEx(pLevel, 2);
    const t = mazeTxt(pRoomEx.*.pLevel);
    const nSizeX = t.*.SizeX;
    pRoomEx.*.sCoords.WorldSize.x = nSizeX;
    pRoomEx.*.sCoords.WorldSize.y = t.*.SizeY;
    pRoomEx.*.sCoords.WorldPosition.x = @divTrunc(pLevel.*.sCoordinatesAndSize.WorldSize.x - nSizeX, 2) + pLevel.*.sCoordinatesAndSize.WorldPosition.x;
    pRoomEx.*.sCoords.WorldPosition.y = @divTrunc(pLevel.*.sCoordinatesAndSize.WorldSize.y - pRoomEx.*.sCoords.WorldSize.y, 2) + pLevel.*.sCoordinatesAndSize.WorldPosition.y;
    _ = DrlgRoom.AddRoomExToLevel(pLevel, pRoomEx);

    const lid = pLevel.*.eD2LevelId;
    switch (pLevel.*.nLevelType) {
        .act1_caves => {
            ActualLevelGeneration(pLevel);
            Act1.Caves(pLevel);
        },
        .act1_crypt => {
            ActualLevelGeneration(pLevel);
            Act1.Crypt(pLevel);
        },
        .barracks_family => { // grid + grow
            buildRoomGrid(2, pLevel);
            ActualLevelGeneration(pLevel);
        },
        .river_family => ActualLevelGeneration(pLevel), // grow only
        .act1_jail => {
            buildRoomGrid(2, pLevel);
            ActualLevelGeneration(pLevel);
            Act1.JailRollRooms(pLevel);
        },
        .act1_catacombs => {
            Act1.ExpandCatacombsLevel(pLevel);
            ActualLevelGeneration(pLevel);
            Act1.ReplaceCatacombsRooms(pLevel);
        },
        .act2_sewer => {
            buildRoomGrid(2, pLevel);
            ActualLevelGeneration(pLevel);
            Sewer.generateSewerLevel(pLevel);
        },
        .generic_0e, .generic_0f, .generic_17 => buildRoomGrid(2, pLevel), // plain grid (no special)
        .act2_tombs => {
            if (lid == LevelId.tomb_fixed) {
                setFlags(pRoomEx, getFlags(pRoomEx) | 2);
                setDef(pRoomEx, 0x1e0);
                setVariant(pRoomEx, -1);
            } else {
                GenerateWolrdstoneAndTombs(pLevel);
                ActualLevelGeneration(pLevel);
                Act2.TombsReplaceAreas(pLevel);
            }
        },
        .act2_lair => {
            buildRoomGrid(2, pLevel);
            ActualLevelGeneration(pLevel);
            Act2.Lair(pLevel);
        },
        // Arcane Sanctuary (Maze.cpp:1316). 4-arm/15-room spoke builder + Summoner
        // marker placement. Decompile cleaned in Ghidra (see RollArcaneTypePath).
        .act2_arcane => {
            RollArcaneTypePath(pLevel);
            PickSummonerLocation(pLevel);
        },
        .act3_durance => {
            buildRoomGrid(2, pLevel);
            ActualLevelGeneration(pLevel);
            Act3.DuranceReplaceRooms(pLevel);
        },
        .act3_dungeon => {
            buildRoomGrid(2, pLevel);
            ActualLevelGeneration(pLevel);
            Act3.DungeonRoll(pLevel);
        },
        .act3_sewers => {
            if (lid != LevelId.act3_sewer_special) {
                buildRoomGrid(2, pLevel);
                ActualLevelGeneration(pLevel);
                Act3.ReplaceSewerRooms(pLevel);
            } else {
                if (!act3SewerSpecial0x5c(pLevel)) return false;
            }
        },
        .act5_temple => { // no ActualLevelGeneration
            buildRoomGrid(2, pLevel);
            Act5.TempleReplaceRooms(pLevel);
        },
        .act5_icecaves => {
            switch (lid) {
                LevelId.frozen_river => {
                    const nVariant = rng.getModuloFromSeed(&pRoomEx.*.pLevel.?.*.sSeed, 2);
                    const p = pLevel.*.pRoomExFirst;
                    setFlags(p, getFlags(p) | 2);
                    setDef(p, 0x40f - @as(i32, @bitCast(nVariant)));
                    setVariant(p, -1);
                },
                LevelId.drifter_cavern => {
                    const p = pLevel.*.pRoomExFirst;
                    setFlags(p, getFlags(p) | 2);
                    setDef(p, 0x410);
                    setVariant(p, -1);
                },
                LevelId.icy_cellar => {
                    const p = pLevel.*.pRoomExFirst;
                    setFlags(p, getFlags(p) | 2);
                    setDef(p, 0x411);
                    setVariant(p, -1);
                },
                else => {
                    buildRoomGrid(2, pLevel);
                    ActualLevelGeneration(pLevel);
                    Act5.IceCavesReplaceRooms(pLevel);
                },
            }
        },
        .act5_worldstone => {
            GenerateWolrdstoneAndTombs(pLevel);
            ActualLevelGeneration(pLevel);
            Act5.WorldstonePutRed(pLevel);
        },
        .act5_baal => SetupBaalChamber(pLevel),
        else => return false,
    }

    // Per-level-id final placement (Maze.cpp:1484). Barracks/River do their OWN
    // coordinate translation + bbox (aligning to the Jail/Chaos sibling level);
    // every other level falls back to DRLGLEVEL_AdjustRoomCoordinates.
    if (lid == LevelId.barracks) {
        Act1.GenerateBarracksLayout(pLevel);
    } else if (lid == LevelId.river_of_flames) {
        Act4.GenerateRiverOfFlames(pLevel);
    } else {
        deps.adjustRoomCoordinates(pLevel);
    }
    ForAllButDenOfEvil(pLevel);
    return true;
}

test "maze module references" {
    _ = pickRoomPreset;
    _ = generateLevel;
}
