//! Transform of recon/closure/Maze/Act4/RiverOfFlames.cpp
//! (D2Common::Drlg::Maze::Act4::RiverOfFlames).

const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const DrlgRoom = @import("../DrlgRoom.zig");
const deps = @import("deps.zig");
const Maze = @import("Maze.zig");

inline fn mazeTxt(pLevel: [*c]s.D2DrlgLevelStrc) [*c]@import("../tables.zig").D2LvlMazeTxt {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData));
}

// gaDrlgRiverOfFlamesReplacements[2] (RiverOfFlames.cpp:29, recon verbatim).
const gaDrlgRiverOfFlamesReplacements = [2]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act4LavaW, .nDestLevelPrestId = .Act4LavaForgeW, .nDestPickedFile = -1, .nDirection = 2 },
    .{ .nSourceLevelPrestId = .Act4LavaE, .nDestLevelPrestId = .Act4LavaForgeE, .nDestPickedFile = -1, .nDirection = 0 },
};

/// DRLGMAZE_GenerateRiverOfFlames (Act4/RiverOfFlames.cpp:27, 1.14d 00673320).
/// Two connector rooms grown off the bottom/top-most maze rooms (preset 0x354 then
/// 0x357, variant -1, bPickSource=1 — Ghidra phantom-register drops on
/// DRLGMAZE_AllocRoomExAndPickPreset, recovered from the recovered call site
/// @0x673320), then two manual 0x358 rooms, an orth into the Chaos Sanctuary
/// (id 0x6c), a seed-rolled replacement, ExpandRoomsWithPresets(0x344, pLastRoom),
/// and a translate aligning the river to the Chaos Sanctuary.
pub fn GenerateRiverOfFlames(pDrlgLevelStrc: [*c]s.D2DrlgLevelStrc) void {
    const pDrlg = pDrlgLevelStrc.*.pDrlg.?;
    if (pDrlg.nActNo == 4) return;
    const pChaosLevel = deps.GetLevelAndAlloc(pDrlgLevelStrc.*.pDrlg, .ChaosSanctuary);

    var pNewRoom: [*c]s.D2RoomExStrc = Maze.findBottomMostRoom(pDrlgLevelStrc);
    if (pNewRoom == null) return;
    _ = Maze.allocRoomExAndPickPreset(deps.DIRECTION_NORTHWEST, pNewRoom, 0x354, -1, 1);
    pNewRoom = Maze.findTopMostRoom(pDrlgLevelStrc);
    if (pNewRoom == null) return;
    pNewRoom = Maze.allocRoomExAndPickPreset(deps.DIRECTION_NORTHEAST, pNewRoom, 0x357, -1, 1);
    if (pNewRoom == null) return;

    const pRoomEx: [*c]s.D2RoomExStrc = DrlgRoom.allocRoomEx(pNewRoom.*.pLevel, 2);
    var t = mazeTxt(pRoomEx.*.pLevel);
    pRoomEx.*.sCoords.WorldSize.x = t.*.SizeX;
    pRoomEx.*.sCoords.WorldSize.y = t.*.SizeY;
    if (!deps.ReplaceRoomWithNewRoom(1, pRoomEx, pNewRoom)) {
        DrlgRoom.freeDrlgRoomEx(pRoomEx);
        return;
    }
    DrlgRoom.allocNodesForBothRoomEx(pNewRoom, pRoomEx, 1);
    _ = DrlgRoom.AddRoomExToLevel(pNewRoom.*.pLevel, pRoomEx);
    Maze.setFlags(pRoomEx, Maze.getFlags(pRoomEx) | 2);
    Maze.setDef(pRoomEx, 0x358);
    Maze.setVariant(pRoomEx, -1);

    pNewRoom = DrlgRoom.allocRoomEx(pRoomEx.*.pLevel, 2);
    t = mazeTxt(pNewRoom.*.pLevel);
    pNewRoom.*.sCoords.WorldSize.x = t.*.SizeX;
    pNewRoom.*.sCoords.WorldSize.y = t.*.SizeY;
    if (!deps.ReplaceRoomWithNewRoom(1, pNewRoom, pRoomEx)) {
        DrlgRoom.freeDrlgRoomEx(pNewRoom);
        return;
    }
    DrlgRoom.allocNodesForBothRoomEx(pRoomEx, pNewRoom, 1);
    _ = DrlgRoom.AddRoomExToLevel(pRoomEx.*.pLevel, pNewRoom);
    Maze.setFlags(pNewRoom, Maze.getFlags(pNewRoom) | 2);
    Maze.setDef(pNewRoom, 0x358);
    Maze.setVariant(pNewRoom, -1);

    DrlgRoom.AllocDrlgOrth(pNewRoom, pChaosLevel, deps.DIRECTION_NORTHEAST, 0);
    const nHeight = pChaosLevel.*.sCoordinatesAndSize.WorldSize.y;
    const nRoomPosY = pNewRoom.*.sCoords.WorldPosition.y;
    const nRoomSizeX = pNewRoom.*.sCoords.WorldSize.x;
    const nChaosLevelY = pChaosLevel.*.sCoordinatesAndSize.WorldPosition.y;
    const nRoomPosX = pNewRoom.*.sCoords.WorldPosition.x;
    const nChaosLevelX = pChaosLevel.*.sCoordinatesAndSize.WorldPosition.x;

    const DVar1 = rng.sEEDNEXT(pDrlgLevelStrc.*.sSeed);
    pDrlgLevelStrc.*.sSeed = DVar1;
    Maze.ReplaceRoom(@constCast(&gaDrlgRiverOfFlamesReplacements[@intCast(DVar1.nSeedLow & 1)]), pDrlgLevelStrc, null);
    Maze.expandRoomsWithPresets(pDrlgLevelStrc, 0x344, pNewRoom);

    var p: [*c]s.D2RoomExStrc = pDrlgLevelStrc.*.pRoomExFirst;
    while (p != null) : (p = p.*.pRoomExNext) {
        p.*.sCoords.WorldPosition.x += (nRoomSizeX * 2 - nRoomPosX) + nChaosLevelX;
        p.*.sCoords.WorldPosition.y += (nHeight - nRoomPosY) + nChaosLevelY;
    }
    var nMinX: i32 = 0;
    var nMinY: i32 = 0;
    var nMaxX: i32 = 0;
    var nMaxY: i32 = 0;
    deps.GetMinAndMaxCoordinatesFromLevel(pDrlgLevelStrc, &nMinX, &nMinY, &nMaxX, &nMaxY);
    pDrlgLevelStrc.*.sCoordinatesAndSize.WorldPosition.x = nMinX;
    pDrlgLevelStrc.*.sCoordinatesAndSize.WorldPosition.y = nMinY;
    pDrlgLevelStrc.*.sCoordinatesAndSize.WorldSize.x = nMaxX - nMinX;
    pDrlgLevelStrc.*.sCoordinatesAndSize.WorldSize.y = nMaxY - nMinY;
}
