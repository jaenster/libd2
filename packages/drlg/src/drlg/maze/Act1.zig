//! Transform of recon/closure/Maze/Act1{,.cpp} + Act1/{Jail,Catacombs}.cpp
//! (D2Common::Drlg::Maze::Act1). ReplaceRoom-table special-preset generators for
//! the Act 1 dungeon families. Faithful by construction; tables verbatim from recon.

const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const DrlgRoom = @import("../DrlgRoom.zig");
const deps = @import("deps.zig");
const Maze = @import("Maze.zig");

inline fn rr(pLevel: [*c]s.D2DrlgLevelStrc, tbl: []const s.D2DrlgReplaceRoomStrc, nRoll: *i32) void {
    Maze.ReplaceRoom(@constCast(&tbl[@intCast(nRoll.*)]), pLevel, nRoll);
}

// Caves (Act1.cpp:24, 1.14d 00672550)
const gaDrlgCavesReplacements_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CaveN, .nDestLevelPrestId = .Act1CavePrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CaveE, .nDestLevelPrestId = .Act1CavePrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CaveS, .nDestLevelPrestId = .Act1CavePrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CaveW, .nDestLevelPrestId = .Act1CavePrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCavesReplacements_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CaveN, .nDestLevelPrestId = .Act1CaveDenOfEvilN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CaveE, .nDestLevelPrestId = .Act1CaveDenOfEvilE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CaveS, .nDestLevelPrestId = .Act1CaveDenOfEvilS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CaveW, .nDestLevelPrestId = .Act1CaveDenOfEvilW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCavesReplacements_C = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CaveN, .nDestLevelPrestId = .Act1CaveDownN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CaveE, .nDestLevelPrestId = .Act1CaveDownE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CaveS, .nDestLevelPrestId = .Act1CaveDownS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CaveW, .nDestLevelPrestId = .Act1CaveDownW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCavesReplacements_D = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CaveN, .nDestLevelPrestId = .Act1CaveColdcrowN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CaveE, .nDestLevelPrestId = .Act1CaveColdcrowE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CaveS, .nDestLevelPrestId = .Act1CaveColdcrowS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CaveW, .nDestLevelPrestId = .Act1CaveColdcrowW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCavesReplacements_E = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CaveN, .nDestLevelPrestId = .Act1CaveNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CaveE, .nDestLevelPrestId = .Act1CaveNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CaveS, .nDestLevelPrestId = .Act1CaveNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CaveW, .nDestLevelPrestId = .Act1CaveNextW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn Caves(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const sNewSeed = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = sNewSeed;
    var nRoll: i32 = sNewSeed.nSeedLow & 3;
    rr(pLevel, &gaDrlgCavesReplacements_A, &nRoll);
    const tbl: []const s.D2DrlgReplaceRoomStrc = if (pLevel.*.eD2LevelId == .DenofEvil) &gaDrlgCavesReplacements_B else &gaDrlgCavesReplacements_C;
    rr(pLevel, tbl, &nRoll);
    if (pLevel.*.eD2LevelId == .CaveLvl1) rr(pLevel, &gaDrlgCavesReplacements_D, &nRoll);
    if (pLevel.*.eD2LevelId != .UndergroundPassageLvl1) return;
    rr(pLevel, &gaDrlgCavesReplacements_E, &nRoll);
}

// Crypt (Act1.cpp:181, 1.14d 00672610)
const gaDrlgCryptReplacements_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CryptN, .nDestLevelPrestId = .Act1CryptPrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CryptE, .nDestLevelPrestId = .Act1CryptPrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CryptS, .nDestLevelPrestId = .Act1CryptPrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CryptW, .nDestLevelPrestId = .Act1CryptPrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCryptReplacements_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CryptN, .nDestLevelPrestId = .Act1CryptBonebreakN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CryptE, .nDestLevelPrestId = .Act1CryptBonebreakE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CryptS, .nDestLevelPrestId = .Act1CryptBonebreakS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CryptW, .nDestLevelPrestId = .Act1CryptBonebreakW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCryptReplacements_C = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CryptN, .nDestLevelPrestId = .Act1CryptChestN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CryptE, .nDestLevelPrestId = .Act1CryptChestE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CryptS, .nDestLevelPrestId = .Act1CryptChestS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CryptW, .nDestLevelPrestId = .Act1CryptChestW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCryptReplacements_D = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CryptN, .nDestLevelPrestId = .Act1CryptNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CryptE, .nDestLevelPrestId = .Act1CryptNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CryptS, .nDestLevelPrestId = .Act1CryptNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CryptW, .nDestLevelPrestId = .Act1CryptNextW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn Crypt(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    var nRoll: i32 = DVar1.nSeedLow & 3;
    rr(pLevel, &gaDrlgCryptReplacements_A, &nRoll);
    if (pLevel.*.eD2LevelId == .Crypt) rr(pLevel, &gaDrlgCryptReplacements_B, &nRoll);
    if (pLevel.*.eD2LevelId == .Mausoleum or pLevel.*.eD2LevelId == .MatronsDen) rr(pLevel, &gaDrlgCryptReplacements_C, &nRoll);
    if (!(0x14 < @intFromEnum(pLevel.*.eD2LevelId) and @intFromEnum(pLevel.*.eD2LevelId) < 0x19)) return;
    rr(pLevel, &gaDrlgCryptReplacements_D, &nRoll);
}

// Jail::RollRooms (Act1/Jail.cpp:24, 1.14d 006726d0)
const gaDrlgCatacombsRollRooms_E = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1JailN, .nDestLevelPrestId = .Act1JailPrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1JailE, .nDestLevelPrestId = .Act1JailPrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1JailS, .nDestLevelPrestId = .Act1JailPrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1JailW, .nDestLevelPrestId = .Act1JailPrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCatacombsRollRooms_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1JailN, .nDestLevelPrestId = .Act1JailCathN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1JailE, .nDestLevelPrestId = .Act1JailCathE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1JailS, .nDestLevelPrestId = .Act1JailCathS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1JailW, .nDestLevelPrestId = .Act1JailCathW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCatacombsRollRooms_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1JailN, .nDestLevelPrestId = .Act1JailNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1JailE, .nDestLevelPrestId = .Act1JailNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1JailS, .nDestLevelPrestId = .Act1JailNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1JailW, .nDestLevelPrestId = .Act1JailNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCatacombsRollRooms_C = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1JailN, .nDestLevelPrestId = .Act1JailWaypointN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1JailE, .nDestLevelPrestId = .Act1JailWaypointE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1JailS, .nDestLevelPrestId = .Act1JailWaypointS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1JailW, .nDestLevelPrestId = .Act1JailWaypointW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCatacombsRollRooms_D = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1JailN, .nDestLevelPrestId = .Act1JailPitspawnN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1JailE, .nDestLevelPrestId = .Act1JailPitspawnE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1JailS, .nDestLevelPrestId = .Act1JailPitspawnS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1JailW, .nDestLevelPrestId = .Act1JailPitspawnW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn JailRollRooms(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    var nRoll: i32 = DVar1.nSeedLow & 3;
    rr(pLevel, &gaDrlgCatacombsRollRooms_E, &nRoll);
    if (pLevel.*.eD2LevelId == .JailLvl1) rr(pLevel, &gaDrlgCatacombsRollRooms_C, &nRoll);
    if (pLevel.*.eD2LevelId == .JailLvl2) rr(pLevel, &gaDrlgCatacombsRollRooms_D, &nRoll);
    if (pLevel.*.eD2LevelId == .JailLvl3) {
        rr(pLevel, &gaDrlgCatacombsRollRooms_A, &nRoll);
        return;
    }
    rr(pLevel, &gaDrlgCatacombsRollRooms_B, &nRoll);
}

// Catacombs (Act1/Catacombs.cpp, 1.14d 006714d0 / 006727a0)
fn growCatacombs(dir: i32, pStartRoom: [*c]s.D2RoomExStrc) void {
    const pNewRoom = DrlgRoom.allocRoomEx(pStartRoom.*.pLevel, 2);
    const t: [*c]@import("../tables.zig").D2LvlMazeTxt = @ptrCast(@alignCast(pNewRoom.*.pLevel.?.*.pDrlgLevelData));
    pNewRoom.*.sCoords.WorldSize.x = t.*.SizeX;
    pNewRoom.*.sCoords.WorldSize.y = t.*.SizeY;
    if (!deps.ReplaceRoomWithNewRoom(dir, pNewRoom, pStartRoom)) {
        DrlgRoom.freeDrlgRoomEx(pNewRoom);
    } else {
        DrlgRoom.allocNodesForBothRoomEx(pStartRoom, pNewRoom, dir);
        Maze.pickRoomPresets(pNewRoom);
        _ = DrlgRoom.AddRoomExToLevel(pStartRoom.*.pLevel, pNewRoom);
        _ = Maze.pickRoomPreset(pStartRoom);
        _ = Maze.pickRoomPreset(pNewRoom);
    }
}

/// DRLGMAZE_ExpandCatacombsLevel (Catacombs.cpp:26). `bIsCatacombsLevel4` is a lost
/// phantom; recovered as eD2LevelId==0x22 (Catacombs 1) — the recon writes the fixed
/// preset 0x122 in this branch, and the deep golden for level 0x22 carries def 0x122
/// (while 0x23/0x24 carry the seed-branch presets 0x120/0x121).
pub fn ExpandCatacombsLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const pStartRoom: [*c]s.D2RoomExStrc = pLevel.*.pRoomExFirst;
    if (pLevel.*.eD2LevelId == .CatacombsLvl1) {
        growCatacombs(1, pStartRoom);
        growCatacombs(2, pStartRoom);
        growCatacombs(3, pStartRoom);
        growCatacombs(0, pStartRoom);
        Maze.setDef(pStartRoom, 0x122);
        Maze.setFlags(pStartRoom, Maze.getFlags(pStartRoom) | 2);
        Maze.setVariant(pStartRoom, -1);
        return;
    }
    const sNewSeed = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = sNewSeed;
    if ((sNewSeed.nSeedLow & 1) == 0) {
        growCatacombs(1, pStartRoom);
        growCatacombs(3, pStartRoom);
        Maze.setDef(pStartRoom, 0x121);
        Maze.setFlags(pStartRoom, Maze.getFlags(pStartRoom) | 2);
        Maze.setVariant(pStartRoom, -1);
        return;
    }
    growCatacombs(0, pStartRoom);
    growCatacombs(2, pStartRoom);
    Maze.setDef(pStartRoom, 0x120);
    Maze.setFlags(pStartRoom, Maze.getFlags(pStartRoom) | 2);
    Maze.setVariant(pStartRoom, -1);
}

const gaDrlgCatacombsReplacements_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CatacombsN, .nDestLevelPrestId = .Act1CatacombsNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CatacombsE, .nDestLevelPrestId = .Act1CatacombsNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CatacombsS, .nDestLevelPrestId = .Act1CatacombsNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CatacombsW, .nDestLevelPrestId = .Act1CatacombsNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgCatacombsReplacements_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1CatacombsN, .nDestLevelPrestId = .Act1CatacombsWaypointN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1CatacombsE, .nDestLevelPrestId = .Act1CatacombsWaypointE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1CatacombsS, .nDestLevelPrestId = .Act1CatacombsWaypointS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1CatacombsW, .nDestLevelPrestId = .Act1CatacombsWaypointW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn ReplaceCatacombsRooms(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const sNewSeed = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = sNewSeed;
    var nVariant: i32 = sNewSeed.nSeedLow & 3;
    rr(pLevel, &gaDrlgCatacombsReplacements_A, &nVariant);
    if (pLevel.*.eD2LevelId != .CatacombsLvl2) return;
    rr(pLevel, &gaDrlgCatacombsReplacements_B, &nVariant);
}

// Barracks (Act1/Barracks.cpp:27, 1.14d 00673120)
// gaDrlgBarracksReplacements_A/_B are [4] (one entry per exit direction). The
// connector room's preset/variant/bPickSource args (0xa7, exitVariant, 1) were
// Ghidra phantom-register drops on DRLGMAZE_AllocRoomExAndPickPreset; recovered
// from the recovered call site @0x673120. The indirect PTR_ARRAY_006f0468 dispatch
// (FindRightMost/BottomMost/LeftMost) is __fastcall(ECX=pDrlgLevelStrc) — disasm
// @0x673145 shows ECX=EDI, so it searches the BARRACKS level itself; the Jail
// level (id 0x1b) only supplies the alignment coords.
const gaDrlgBarracksReplacements_A = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1BarracksN, .nDestLevelPrestId = .Act1BarracksNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1BarracksE, .nDestLevelPrestId = .Act1BarracksNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1BarracksS, .nDestLevelPrestId = .Act1BarracksNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1BarracksW, .nDestLevelPrestId = .Act1BarracksNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const gaDrlgBarracksReplacements_B = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act1BarracksN, .nDestLevelPrestId = .Act1BarracksForgeN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act1BarracksE, .nDestLevelPrestId = .Act1BarracksForgeE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act1BarracksS, .nDestLevelPrestId = .Act1BarracksForgeS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act1BarracksW, .nDestLevelPrestId = .Act1BarracksForgeW, .nDestPickedFile = -1, .nDirection = 2 },
};

inline fn mazeTxt(pLevel: [*c]s.D2DrlgLevelStrc) [*c]@import("../tables.zig").D2LvlMazeTxt {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData));
}

/// DRLGMAZE_GenerateBarracksLayout (Act1/Barracks.cpp:27, 1.14d 00673120).
const DBG_BARRACKS = false;
pub fn GenerateBarracksLayout(pDrlgLevelStrc: [*c]s.D2DrlgLevelStrc) void {
    if (DBG_BARRACKS) {
        @import("std").debug.print("PORT barracks_entry seedLo=0x{x:0>8} roomEx={d}\n", .{ @as(u32, @bitCast(pDrlgLevelStrc.*.sSeed.nSeedLow)), pDrlgLevelStrc.*.nRoomExCount });
    }
    const pJailLevel = deps.GetLevelAndAlloc(pDrlgLevelStrc.*.pDrlg, .OuterCloister);
    // Level 0x1b (Courtyard 1) is a PRESET level, so its pDrlgLevelData is a
    // D2DrlgLevelDataPresetArea, not a maze row. The engine reads the jail-exit
    // variant from byte offset 4 of that struct, which on 32-bit is nPickedFile.
    // Read the NAMED field so the 64-bit build uses the right offset (a raw +4 /
    // mazeTxt-Rooms[0] read would hit the high half of the 8-byte pDrlgMap pointer).
    const JailPresetData = extern struct { pDrlgMap: ?*anyopaque, nPickedFile: i32 };
    const pJailPreset: *const JailPresetData = @ptrCast(@alignCast(pJailLevel.*.pDrlgLevelData));
    const nJailExitVariant: i32 = pJailPreset.*.nPickedFile;
    const pEdgeRoom: [*c]s.D2RoomExStrc = switch (nJailExitVariant) {
        0 => Maze.findRightMostRoom(pDrlgLevelStrc),
        1 => Maze.findBottomMostRoom(pDrlgLevelStrc),
        2 => Maze.findLeftMostRoom(pDrlgLevelStrc),
        else => return,
    };
    if (pEdgeRoom == null) return;
    if (DBG_BARRACKS) @import("std").debug.print("PORT T1 afterFind seedLo=0x{x:0>8} roomEx={d}\n", .{ @as(u32, @bitCast(pDrlgLevelStrc.*.sSeed.nSeedLow)), pDrlgLevelStrc.*.nRoomExCount });
    var nOffsetX: i32 = pJailLevel.*.sCoordinatesAndSize.WorldPosition.x;
    var nOffsetY: i32 = pJailLevel.*.sCoordinatesAndSize.WorldPosition.y;
    const pLvlMazeTxt = mazeTxt(pDrlgLevelStrc);
    const jailW = pJailLevel.*.sCoordinatesAndSize.WorldSize.x;
    const jailH = pJailLevel.*.sCoordinatesAndSize.WorldSize.y;
    switch (nJailExitVariant) {
        0 => {
            const pConnector = Maze.allocRoomExAndPickPreset(deps.DIRECTION_SOUTHWEST, pEdgeRoom, 0xa7, 0, 1);
            DrlgRoom.AllocDrlgOrth(pConnector, pJailLevel, deps.DIRECTION_SOUTHWEST, 0);
            nOffsetX -= pConnector.*.sCoords.WorldPosition.x + pLvlMazeTxt.*.SizeX;
            nOffsetY += @divTrunc(jailH, 2) - pConnector.*.sCoords.WorldPosition.y;
        },
        1 => {
            const pConnector = Maze.allocRoomExAndPickPreset(deps.DIRECTION_NORTHWEST, pEdgeRoom, 0xa7, 1, 1);
            DrlgRoom.AllocDrlgOrth(pConnector, pJailLevel, deps.DIRECTION_NORTHWEST, 0);
            nOffsetX += -6 + (@divTrunc(jailW, 2) - pConnector.*.sCoords.WorldPosition.x);
            nOffsetY -= pConnector.*.sCoords.WorldPosition.y + pLvlMazeTxt.*.SizeY;
        },
        2 => {
            const pConnector = Maze.allocRoomExAndPickPreset(deps.DIRECTION_SOUTHEAST, pEdgeRoom, 0xa7, 2, 1);
            DrlgRoom.AllocDrlgOrth(pConnector, pJailLevel, deps.DIRECTION_SOUTHEAST, 0);
            nOffsetX += jailW - pConnector.*.sCoords.WorldPosition.x;
            nOffsetY += 1 + (@divTrunc(jailH, 2) - pConnector.*.sCoords.WorldPosition.y);
        },
        else => unreachable,
    }
    if (DBG_BARRACKS) @import("std").debug.print("PORT T2 afterConn seedLo=0x{x:0>8} roomEx={d}\n", .{ @as(u32, @bitCast(pDrlgLevelStrc.*.sSeed.nSeedLow)), pDrlgLevelStrc.*.nRoomExCount });
    // Seed-roll picks which replacement set runs first; the SECOND ReplaceRoom
    // indexes the table with the post-advance roll (faithful to the recon ordering).
    var nRoll: i32 = nJailExitVariant;
    const DVar1 = rng.sEEDNEXT(pDrlgLevelStrc.*.sSeed);
    pDrlgLevelStrc.*.sSeed = DVar1;
    var pReplaceData: [*c]const s.D2DrlgReplaceRoomStrc = undefined;
    if ((DVar1.nSeedLow & 1) == 0) {
        Maze.ReplaceRoom(@constCast(&gaDrlgBarracksReplacements_B[@intCast(nRoll)]), pDrlgLevelStrc, &nRoll);
        pReplaceData = &gaDrlgBarracksReplacements_A[@intCast(nRoll)];
    } else {
        Maze.ReplaceRoom(@constCast(&gaDrlgBarracksReplacements_A[@intCast(nRoll)]), pDrlgLevelStrc, &nRoll);
        pReplaceData = &gaDrlgBarracksReplacements_B[@intCast(nRoll)];
    }
    Maze.ReplaceRoom(@constCast(pReplaceData), pDrlgLevelStrc, &nRoll);
    var p: [*c]s.D2RoomExStrc = pDrlgLevelStrc.*.pRoomExFirst;
    while (p != null) : (p = p.*.pRoomExNext) {
        p.*.sCoords.WorldPosition.x += nOffsetX;
        p.*.sCoords.WorldPosition.y += nOffsetY;
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
