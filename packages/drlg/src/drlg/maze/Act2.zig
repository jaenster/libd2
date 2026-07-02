//! Transform of recon/closure/Maze/Act2.cpp + Act2/Tombs.cpp
//! (D2Common::Drlg::Maze::Act2). ReplaceRoom-table special-preset generators for
//! the Act 2 dungeon families (Lair / Tombs). Arcane lives in Act2Arcane.zig;
//! Sewers in Act2Sewer.zig.

const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const Maze = @import("Maze.zig");

inline fn rr(pLevel: [*c]s.D2DrlgLevelStrc, tbl: []const s.D2DrlgReplaceRoomStrc, nRoll: *i32) void {
    Maze.ReplaceRoom(@constCast(&tbl[@intCast(nRoll.*)]), pLevel, nRoll);
}

// Lair (Act2.cpp:24, 1.14d 00672dc0)
const gaDrlgLairReplacements_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2LairN, .nDestLevelPrestId = .Act2LairPrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2LairE, .nDestLevelPrestId = .Act2LairPrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2LairS, .nDestLevelPrestId = .Act2LairPrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2LairW, .nDestLevelPrestId = .Act2LairPrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgLairReplacements_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2LairN, .nDestLevelPrestId = .Act2LairNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2LairE, .nDestLevelPrestId = .Act2LairNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2LairS, .nDestLevelPrestId = .Act2LairNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2LairW, .nDestLevelPrestId = .Act2LairNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const D2DrlgReplaceRoomStrc_006f00d8 = s.D2DrlgReplaceRoomStrc{ .nSourceLevelPrestId = .Act2LairW, .nDestLevelPrestId = .Act2LairTreasureW, .nDestPickedFile = -1, .nDirection = 2 };
const D2DrlgReplaceRoomStrc_006f00e8 = s.D2DrlgReplaceRoomStrc{ .nSourceLevelPrestId = .Act2LairS, .nDestLevelPrestId = .Act2LairTightSpotS, .nDestPickedFile = -1, .nDirection = 1 };

pub fn Lair(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    var nRoll: i32 = DVar1.nSeedLow & 3;
    pLevel.*.sSeed = DVar1;
    var pReplaceEntry: *const s.D2DrlgReplaceRoomStrc = undefined;
    if (pLevel.*.eD2LevelId == .MaggotLairLvl3) {
        Maze.ReplaceRoom(@constCast(&D2DrlgReplaceRoomStrc_006f00e8), pLevel, &nRoll);
        nRoll = 3;
        // The staff is always located in the "upper" version of the normal stairs.
        pReplaceEntry = &D2DrlgReplaceRoomStrc_006f00d8;
    } else {
        pReplaceEntry = &gaDrlgLairReplacements_A[@intCast(nRoll)];
    }
    Maze.ReplaceRoom(@constCast(pReplaceEntry), pLevel, &nRoll);
    rr(pLevel, &gaDrlgLairReplacements_B, &nRoll);
}

// Tombs::ReplaceAreas (Act2/Tombs.cpp:27, 1.14d 00672be0)
const gaDrlgReplaceAreas_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgReplaceAreas_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombWaypointN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombWaypointE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombWaypointS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombWaypointW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgAreaReplacementsB = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombChestN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombChestE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombChestS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombChestW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgReplaceAreas_C = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombLeatherarmN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombLeatherarmE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombLeatherarmS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombLeatherarmW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgReplaceAreas_D = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombCubeN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombCubeE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombCubeS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombCubeW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgReplaceAreas_E = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombTreasureN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombTreasureE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombTreasureS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombTreasureW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgReplaceAreas_F = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombTalrashaN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombTalrashaE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombTalrashaS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombTalrashaW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgReplaceAreas_G = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act2TombN, .nDestLevelPrestId = .Act2TombKaaN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act2TombE, .nDestLevelPrestId = .Act2TombKaaE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act2TombS, .nDestLevelPrestId = .Act2TombKaaS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act2TombW, .nDestLevelPrestId = .Act2TombKaaW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn TombsReplaceAreas(pLevel: [*c]s.D2DrlgLevelStrc) void {
    // Find the first room whose def >= 0x1ad (the centre orientation marker).
    var pRoomEx: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    var nCentreDef: i32 = 0;
    while (pRoomEx != null) {
        nCentreDef = Maze.getDef(pRoomEx);
        if (nCentreDef >= 0x1ad) break;
        pRoomEx = pRoomEx.*.pRoomExNext;
    }

    var nRoll: i32 = switch (nCentreDef) {
        0x1bc => 3,
        0x1bd => 1,
        0x1be => 0,
        0x1bf => 2,
        else => return, // recon halts; treat as unsupported
    };

    const lid = pLevel.*.eD2LevelId;
    if (0x36 < @intFromEnum(lid) and @intFromEnum(lid) < 0x3b) rr(pLevel, &gaDrlgReplaceAreas_A, &nRoll);
    if (lid == .HallsoftheDeadLvl2) rr(pLevel, &gaDrlgReplaceAreas_B, &nRoll);
    if (lid == .StonyTombLvl2 or lid == .ClawViperTempleLvl2) rr(pLevel, &gaDrlgAreaReplacementsB, &nRoll);
    if (0x41 < @intFromEnum(lid) and @intFromEnum(lid) < 0x49 and lid != pLevel.*.pDrlg.?.nStaffTombLevel) rr(pLevel, &gaDrlgAreaReplacementsB, &nRoll);
    if (lid == .StonyTombLvl2) rr(pLevel, &gaDrlgReplaceAreas_C, &nRoll);
    if (lid == .HallsoftheDeadLvl3) rr(pLevel, &gaDrlgReplaceAreas_D, &nRoll);
    if (lid == .StonyTombLvl2 or lid == .ClawViperTempleLvl2) rr(pLevel, &gaDrlgReplaceAreas_E, &nRoll);
    if (lid == pLevel.*.pDrlg.?.nStaffTombLevel) rr(pLevel, &gaDrlgReplaceAreas_F, &nRoll);
    if (lid != pLevel.*.pDrlg.?.nBossTombLevel) return;
    rr(pLevel, &gaDrlgReplaceAreas_G, &nRoll);
}
