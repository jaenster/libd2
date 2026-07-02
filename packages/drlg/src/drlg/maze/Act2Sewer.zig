//! Transform of recon/closure/Maze/Act2/Sewer.cpp
//! (D2Common::Drlg::Maze::Act2::Sewer). The special-preset replacement
//! (ScanReplaceSpecial) for the Act 2 Sewers; produces the out-of-range Defs.

const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const DrlgRoom = @import("../DrlgRoom.zig");
const deps = @import("deps.zig");
const Maze = @import("Maze.zig");

const DIRECTION_NORTHEAST = deps.DIRECTION_NORTHEAST; // 1
const DIRECTION_SOUTHEAST = deps.DIRECTION_SOUTHEAST; // 0
const DIRECTION_SOUTHWEST = deps.DIRECTION_SOUTHWEST; // 2

// Static replacement tables (originally global data) — Sewer.cpp:29..158.
const gaDrlgSewerAreaReplacements = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2SewerN, .nDestLevelPrestId = .Act2SewerPrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2SewerE, .nDestLevelPrestId = .Act2SewerPrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2SewerS, .nDestLevelPrestId = .Act2SewerPrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2SewerW, .nDestLevelPrestId = .Act2SewerPrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgSewerReplacements_C = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2SewerN, .nDestLevelPrestId = .Act2SewerNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2SewerE, .nDestLevelPrestId = .Act2SewerNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2SewerS, .nDestLevelPrestId = .Act2SewerNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2SewerW, .nDestLevelPrestId = .Act2SewerNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgSewerReplacements_D = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2SewerN, .nDestLevelPrestId = .Act2SewerWaypointN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2SewerE, .nDestLevelPrestId = .Act2SewerWaypointE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2SewerS, .nDestLevelPrestId = .Act2SewerWaypointS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2SewerW, .nDestLevelPrestId = .Act2SewerWaypointW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgSewerReplacements_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2SewerN, .nDestLevelPrestId = .Act2SewerRadamentSLairN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2SewerE, .nDestLevelPrestId = .Act2SewerRadamentSLairE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2SewerS, .nDestLevelPrestId = .Act2SewerRadamentSLairS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2SewerW, .nDestLevelPrestId = .Act2SewerRadamentSLairW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgSewerReplacements_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2SewerN, .nDestLevelPrestId = .Act2SewerChestN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2SewerE, .nDestLevelPrestId = .Act2SewerChestE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2SewerS, .nDestLevelPrestId = .Act2SewerChestS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2SewerW, .nDestLevelPrestId = .Act2SewerChestW, .nDestPickedFile = -1, .nDirection = 2 },
};

// Helper mirroring the recon's "alloc room, size from maze txt, place in dir,
// connect+pick or free" block that appears repeatedly in the 0x2f arm.
fn growRoom(dir: i32, pSrc: [*c]s.D2RoomExStrc) [*c]s.D2RoomExStrc {
    const pNew = DrlgRoom.allocRoomEx(pSrc.*.pLevel, 2);
    const t: [*c]@import("../tables.zig").D2LvlMazeTxt = @ptrCast(@alignCast(pNew.*.pLevel.?.*.pDrlgLevelData));
    pNew.*.sCoords.WorldSize.x = t.*.SizeX;
    pNew.*.sCoords.WorldSize.y = t.*.SizeY;
    if (!deps.ReplaceRoomWithNewRoom(dir, pNew, pSrc)) {
        DrlgRoom.freeDrlgRoomEx(pNew);
        return null;
    }
    DrlgRoom.allocNodesForBothRoomEx(pSrc, pNew, dir);
    Maze.pickRoomPresets(pNew);
    _ = DrlgRoom.AddRoomExToLevel(pSrc.*.pLevel, pNew);
    _ = Maze.pickRoomPreset(pSrc);
    _ = Maze.pickRoomPreset(pNew);
    return pNew;
}

/// DRLGMAZE_GenerateSewerLevel (Sewer.cpp:27, 1.14d 00672810).
pub fn generateSewerLevel(pDrlgLevelStrc: [*c]s.D2DrlgLevelStrc) void {
    var sNewSeed = rng.sEEDNEXT(pDrlgLevelStrc.*.sSeed);
    pDrlgLevelStrc.*.sSeed = sNewSeed;
    const nDirection: i32 = (sNewSeed.nSeedLow & 1) * 2 | DIRECTION_NORTHEAST;
    sNewSeed = rng.sEEDNEXT(pDrlgLevelStrc.*.sSeed);
    pDrlgLevelStrc.*.sSeed = sNewSeed;
    var nVariant: i32 = sNewSeed.nSeedLow & 3;

    switch (pDrlgLevelStrc.*.eD2LevelId) {
        .A2SewersLvl1 => {
            var pNewRoom = Maze.findTopMostRoom(pDrlgLevelStrc);
            var pTempRoom = growRoom(1, pNewRoom);
            pNewRoom = growRoom(1, pTempRoom);
            // 1.14d 0x672984: PUSH 0x14d (fixed preset id) -> AllocRoomExAndPickPreset.
            _ = Maze.allocRoomExAndPickPreset(DIRECTION_SOUTHEAST, pNewRoom, 0x14d, -1, 1);

            pNewRoom = Maze.findRightMostRoom(pDrlgLevelStrc);
            pTempRoom = growRoom(2, pNewRoom);
            pNewRoom = growRoom(2, pTempRoom);
            // 1.14d 0x672a89: PUSH 0x150 (fixed preset id) -> AllocRoomExAndPickPreset.
            pNewRoom = Maze.allocRoomExAndPickPreset(nDirection, pNewRoom, 0x150, -1, 1);

            // Final appended room in nDirection off pNewRoom (no PickRoomPresets).
            const pRoomEx = DrlgRoom.allocRoomEx(pNewRoom.*.pLevel, 2);
            const t: [*c]@import("../tables.zig").D2LvlMazeTxt = @ptrCast(@alignCast(pRoomEx.*.pLevel.?.*.pDrlgLevelData));
            pRoomEx.*.sCoords.WorldSize.x = t.*.SizeX;
            pRoomEx.*.sCoords.WorldSize.y = t.*.SizeY;
            if (!deps.ReplaceRoomWithNewRoom(nDirection, pRoomEx, pNewRoom)) {
                DrlgRoom.freeDrlgRoomEx(pRoomEx);
            } else {
                DrlgRoom.allocNodesForBothRoomEx(pNewRoom, pRoomEx, nDirection);
                _ = DrlgRoom.AddRoomExToLevel(pNewRoom.*.pLevel, pRoomEx);
                _ = Maze.pickRoomPreset(pRoomEx);
            }

            Maze.ReplaceRoom(@constCast(&gaDrlgSewerReplacements_C[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
        },
        .A2SewersLvl2 => {
            Maze.ReplaceRoom(@constCast(&gaDrlgSewerAreaReplacements[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
            Maze.ReplaceRoom(@constCast(&gaDrlgSewerReplacements_D[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
            Maze.ReplaceRoom(@constCast(&gaDrlgSewerReplacements_C[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
        },
        .A2SewersLvl3 => {
            Maze.ReplaceRoom(@constCast(&gaDrlgSewerAreaReplacements[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
            Maze.ReplaceRoom(@constCast(&gaDrlgSewerReplacements_A[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
        },
        .AncientTunnels => {
            Maze.ReplaceRoom(@constCast(&gaDrlgSewerAreaReplacements[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
            Maze.ReplaceRoom(@constCast(&gaDrlgSewerReplacements_B[@intCast(nVariant)]), pDrlgLevelStrc, &nVariant);
        },
        else => {},
    }
}
