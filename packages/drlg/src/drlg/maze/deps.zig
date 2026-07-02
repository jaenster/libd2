//! Maze dependencies that live in OTHER recon translation units but are
//! needed by the maze generator. The seed-FREE geometry helpers from Drlg.cpp are
//! transformed here faithfully (they belong to Drlg.cpp but the maze is the
//! first caller); the seed-CONSUMING Preset.cpp pipeline (AllocDrlgMap/BuildArea)
//! is IMPLEMENTED in src/drlg/preset.zig — the allocDrlgMap/BuildArea wrappers
//! below are thin passthroughs to it (produce the final D2Room seeds + pickedFile).
//!
//! Pointer convention: C pointers `[*c]T`, BOOL/eEnum -> i32.

const s = @import("../structs.zig");
const DrlgRoom = @import("../DrlgRoom.zig");
const drlg = @import("../drlg.zig");

/// Drlg.cpp GetLevelAndAlloc (1.14d 00642bb0) — returns the already-built sibling
/// level (Barracks->Jail 0x1b, River->Chaos 0x6c) or allocates it. Passthrough to
/// the drlg.zig implementation (the single owner of the level list).
pub fn GetLevelAndAlloc(pDrlg: [*c]s.D2DrlgStrc, eLevel: s.eD2LevelId) [*c]s.D2DrlgLevelStrc {
    return @ptrCast(drlg.GetLevelAndAlloc(pDrlg, eLevel));
}

// eDrlgDirection values (DrlgRoom.zig local consts mirrored here).
pub const DIRECTION_SOUTHEAST: i32 = 0;
pub const DIRECTION_NORTHEAST: i32 = 1;
pub const DIRECTION_SOUTHWEST: i32 = 2;
pub const DIRECTION_NORTHWEST: i32 = 3;
pub const DIRECTION_INVALID: i32 = -1;

// Drlg.cpp geometry (seed-free)

/// Drlg.cpp:2492 (ReplaceRoomWithNewRoom). Positions pNewRoom adjacent to
/// pRoomExStrc in nDirection, then verifies no overlap with the source's orth
/// neighbours; returns the manhattan-fit result (true=placed ok). Directions
/// 0..7; the recon's duplicated `default` blocks collapse to the overlap tail.
pub fn ReplaceRoomWithNewRoom(nDirection: i32, pNewRoom: [*c]s.D2RoomExStrc, pRoomExStrc: [*c]s.D2RoomExStrc) bool {
    const pCoords: [*c]s.D2DrlgCoordsStrc = &pNewRoom.*.sCoords;
    const src = &pRoomExStrc.*.sCoords;
    var nCoordVal: i32 = undefined;
    var bSet = true;
    switch (nDirection) {
        0 => {
            pCoords.*.WorldPosition.x = src.*.WorldPosition.x - src.*.WorldSize.x;
            nCoordVal = src.*.WorldPosition.y;
        },
        1 => {
            pCoords.*.WorldPosition.x = src.*.WorldPosition.x;
            nCoordVal = src.*.WorldPosition.y - src.*.WorldSize.y;
        },
        2 => {
            pCoords.*.WorldPosition.x = src.*.WorldSize.x + src.*.WorldPosition.x;
            nCoordVal = src.*.WorldPosition.y;
        },
        3 => {
            pCoords.*.WorldPosition.x = src.*.WorldPosition.x;
            nCoordVal = src.*.WorldSize.y + src.*.WorldPosition.y;
        },
        4 => {
            pCoords.*.WorldPosition.x = src.*.WorldPosition.x - src.*.WorldSize.x;
            nCoordVal = src.*.WorldPosition.y - src.*.WorldSize.y;
        },
        5 => {
            pCoords.*.WorldPosition.x = src.*.WorldSize.x + src.*.WorldPosition.x;
            nCoordVal = src.*.WorldPosition.y - src.*.WorldSize.y;
        },
        6 => {
            pCoords.*.WorldPosition.x = src.*.WorldSize.x + src.*.WorldPosition.x;
            nCoordVal = src.*.WorldSize.y + src.*.WorldPosition.y;
        },
        7 => {
            pCoords.*.WorldPosition.x = src.*.WorldPosition.x - src.*.WorldSize.x;
            nCoordVal = src.*.WorldSize.y + src.*.WorldPosition.y;
        },
        else => {
            bSet = false;
        },
    }
    if (bSet) pNewRoom.*.sCoords.WorldPosition.y = nCoordVal;

    var pRoomData: [*c]s.D2DrlgOrthStrc = pRoomExStrc.*.pOrth;
    while (true) {
        if (pRoomData == null) {
            const fManhattanDist = DrlgRoom.ComputeRectanglesManhattanDistance(pNewRoom.*.pLevel, pNewRoom, pRoomExStrc, 0);
            return fManhattanDist != 0;
        }
        const nc = DrlgRoom.FreeRoomEx(pCoords, pRoomData.*.psCoordinatesAndSize, 0);
        if (nc == 0) break;
        pRoomData = pRoomData.*.pNext;
    }
    return false;
}

/// Drlg.cpp:282 (GetDirectionFromCoordinates).
pub fn GetDirectionFromCoordinates(pDrlgCoords: [*c]s.D2DrlgCoordsStrc, pDrlgCoords2: [*c]s.D2DrlgCoordsStrc) i32 {
    var nPos1 = pDrlgCoords.*.WorldPosition.x;
    var nPos2 = pDrlgCoords2.*.WorldPosition.x;
    if (nPos2 < nPos1) {
        if (nPos1 == pDrlgCoords2.*.WorldSize.x + nPos2) return DIRECTION_SOUTHEAST;
    } else if (nPos2 == pDrlgCoords.*.WorldSize.x + nPos1) {
        return DIRECTION_SOUTHWEST;
    }

    nPos1 = pDrlgCoords.*.WorldPosition.y;
    nPos2 = pDrlgCoords2.*.WorldPosition.y;
    if (nPos2 < nPos1) {
        if (nPos1 == pDrlgCoords2.*.WorldSize.y + nPos2) return DIRECTION_NORTHEAST;
    } else if (nPos2 == pDrlgCoords.*.WorldSize.y + nPos1) {
        return DIRECTION_NORTHWEST;
    }

    return DIRECTION_INVALID;
}

/// Drlg.cpp:460 (GetMinAndMaxCoordinatesFromLevel).
pub fn GetMinAndMaxCoordinatesFromLevel(pLevel: [*c]s.D2DrlgLevelStrc, pOutMinX: *i32, pOutMinY: *i32, pOutMaxX: *i32, pOutMaxY: *i32) void {
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    pOutMinX.* = pRoomEx.*.sCoords.WorldPosition.x;
    pOutMinY.* = pRoomEx.*.sCoords.WorldPosition.y;
    pOutMaxX.* = pRoomEx.*.sCoords.WorldSize.x + pRoomEx.*.sCoords.WorldPosition.x;
    pOutMaxY.* = pRoomEx.*.sCoords.WorldSize.y + pRoomEx.*.sCoords.WorldPosition.y;
    while (pRoomEx != null) : (pRoomEx = pRoomEx.*.pRoomExNext) {
        var nCoord = pRoomEx.*.sCoords.WorldSize.x + pRoomEx.*.sCoords.WorldPosition.x;
        if (pOutMaxX.* < nCoord) pOutMaxX.* = nCoord;
        nCoord = pRoomEx.*.sCoords.WorldPosition.x;
        if (nCoord < pOutMinX.*) pOutMinX.* = nCoord;
        nCoord = pRoomEx.*.sCoords.WorldSize.y + pRoomEx.*.sCoords.WorldPosition.y;
        if (pOutMaxY.* < nCoord) pOutMaxY.* = nCoord;
        nCoord = pRoomEx.*.sCoords.WorldPosition.y;
        if (nCoord < pOutMinY.*) pOutMinY.* = nCoord;
    }
}

/// Drlg.cpp:492 (DRLGLEVEL_AdjustRoomCoordinates). Shifts every RoomEx so the
/// level's min corner aligns with sCoordinatesAndSize. Error halts dropped
/// (validation only).
pub fn adjustRoomCoordinates(pLevel: [*c]s.D2DrlgLevelStrc) void {
    var nMinX: i32 = undefined;
    var nMinY: i32 = undefined;
    var nMaxX: i32 = undefined;
    var nMaxY: i32 = undefined;
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    GetMinAndMaxCoordinatesFromLevel(pLevel, &nMinX, &nMinY, &nMaxX, &nMaxY);
    while (pRoomEx != null) : (pRoomEx = pRoomEx.*.pRoomExNext) {
        pRoomEx.*.sCoords.WorldPosition.x += pLevel.*.sCoordinatesAndSize.WorldPosition.x - nMinX;
        pRoomEx.*.sCoords.WorldPosition.y += pLevel.*.sCoordinatesAndSize.WorldPosition.y - nMinY;
    }
}

// Preset.cpp seed-consuming pipeline (src/drlg/preset.zig)

const preset = @import("../preset.zig");

/// Preset.cpp:1216 (DRLGPRESET_AllocDrlgMap).
pub fn allocDrlgMap(pLevel: [*c]s.D2DrlgLevelStrc, nLvlPrestId: i32, pDrlgCoord: ?*anyopaque, pSeed: *s.D2SeedStrc) [*c]s.D2DrlgMapStrc {
    return preset.allocDrlgMap(pLevel, nLvlPrestId, @ptrCast(@alignCast(pDrlgCoord)), pSeed);
}

/// Preset.cpp:1964 (BuildArea).
pub fn BuildArea(pLevel: [*c]s.D2DrlgLevelStrc, pDrlgMap: [*c]s.D2DrlgMapStrc, nFlags: i32, bSingleRoom: i32) [*c]s.D2RoomExStrc {
    return preset.BuildArea(pLevel, pDrlgMap, nFlags, bSingleRoom);
}
