//! Transform of recon/closure/Maze/Act3.cpp + Act3/{Durance,Sewers}.cpp
//! (D2Common::Drlg::Maze::Act3). ReplaceRoom-table special-preset generators.

const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const Maze = @import("Maze.zig");

inline fn rr(pLevel: [*c]s.D2DrlgLevelStrc, tbl: []const s.D2DrlgReplaceRoomStrc, nRoll: *i32) void {
    Maze.ReplaceRoom(@constCast(&tbl[@intCast(nRoll.*)]), pLevel, nRoll);
}

// DungeonRoll (Act3.cpp:23, 1.14d 00672ea0)
const DRLG_ACT3_DUNGEON_PRESETS = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act3DungeonN, .nDestLevelPrestId = .Act3DungeonPrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act3DungeonE, .nDestLevelPrestId = .Act3DungeonPrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act3DungeonS, .nDestLevelPrestId = .Act3DungeonPrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act3DungeonW, .nDestLevelPrestId = .Act3DungeonPrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_ACT3_DUNGEON_PRESETS2 = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act3DungeonN, .nDestLevelPrestId = .Act3DungeonNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act3DungeonE, .nDestLevelPrestId = .Act3DungeonNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act3DungeonS, .nDestLevelPrestId = .Act3DungeonNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act3DungeonW, .nDestLevelPrestId = .Act3DungeonNextW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn DungeonRoll(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    var nRoll: i32 = DVar1.nSeedLow & 3;
    rr(pLevel, &DRLG_ACT3_DUNGEON_PRESETS, &nRoll);
    rr(pLevel, &DRLG_ACT3_DUNGEON_PRESETS2, &nRoll);
}

// Durance::ReplaceRooms (Act3/Durance.cpp:26, 1.14d 00672f60)
const DRLG_DURA_ENTRY = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act3MephistoN, .nDestLevelPrestId = .Act3MephistoPrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act3MephistoE, .nDestLevelPrestId = .Act3MephistoPrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act3MephistoS, .nDestLevelPrestId = .Act3MephistoPrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act3MephistoW, .nDestLevelPrestId = .Act3MephistoPrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_DURA_WAYPOINT = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act3MephistoN, .nDestLevelPrestId = .Act3MephistoWaypointN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act3MephistoE, .nDestLevelPrestId = .Act3MephistoWaypointE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act3MephistoS, .nDestLevelPrestId = .Act3MephistoWaypointS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act3MephistoW, .nDestLevelPrestId = .Act3MephistoWaypointW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_DURA_EXIT = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act3MephistoN, .nDestLevelPrestId = .Act3MephistoNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act3MephistoE, .nDestLevelPrestId = .Act3MephistoNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act3MephistoS, .nDestLevelPrestId = .Act3MephistoNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act3MephistoW, .nDestLevelPrestId = .Act3MephistoNextW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn DuranceReplaceRooms(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    var nRoll: i32 = DVar1.nSeedLow & 3;
    rr(pLevel, &DRLG_DURA_ENTRY, &nRoll);
    if (pLevel.*.eD2LevelId == .DuranceofHateLvl2) {
        rr(pLevel, &DRLG_DURA_WAYPOINT, &nRoll);
        rr(pLevel, &DRLG_DURA_EXIT, &nRoll);
    }
    if (pLevel.*.eD2LevelId != .DuranceofHateLvl1) return;
    rr(pLevel, &DRLG_DURA_EXIT, &nRoll);
}

// Sewers::ReplaceSewerRooms (Act3/Sewers.cpp:22, 1.14d 00672f00)
const DRLG_ACT3_SEWERS_REPLACE_ONE = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act3SewerN, .nDestLevelPrestId = .Act3SewerDrainN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act3SewerE, .nDestLevelPrestId = .Act3SewerDrainE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act3SewerS, .nDestLevelPrestId = .Act3SewerDrainS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act3SewerW, .nDestLevelPrestId = .Act3SewerDrainW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_ACT3_SEWERS_REPLACE_TWO = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act3SewerN, .nDestLevelPrestId = .Act3SewerChestN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act3SewerE, .nDestLevelPrestId = .Act3SewerChestE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act3SewerS, .nDestLevelPrestId = .Act3SewerChestS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act3SewerW, .nDestLevelPrestId = .Act3SewerChestW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn ReplaceSewerRooms(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const sNewSeed = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = sNewSeed;
    var nVariant: i32 = sNewSeed.nSeedLow & 3;
    rr(pLevel, &DRLG_ACT3_SEWERS_REPLACE_ONE, &nVariant);
    rr(pLevel, &DRLG_ACT3_SEWERS_REPLACE_TWO, &nVariant);
}
