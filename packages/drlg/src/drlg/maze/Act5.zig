//! Transform of recon/closure/Maze/Act5/{Temple,IceCaves,Worldstone}.cpp
//! (D2Common::Drlg::Maze::Act5). ReplaceRoom-table special-preset generators.

const s = @import("../structs.zig");
const rng = @import("../rng.zig");
const Maze = @import("Maze.zig");

inline fn rr(pLevel: [*c]s.D2DrlgLevelStrc, tbl: []const s.D2DrlgReplaceRoomStrc, nRoll: *i32) void {
    Maze.ReplaceRoom(@constCast(&tbl[@intCast(nRoll.*)]), pLevel, nRoll);
}

// Temple::ReplaceRooms (Act5/Temple.cpp:29, 1.14d 00673000)
// Three-entry tables (direction 2 / SOUTHWEST excluded); roll is low-word % 3.
const gaDrlgRoomReplacementsA = [3]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5TempleNE, .nDestLevelPrestId = .Act5TempleNEDown, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5TempleNW, .nDestLevelPrestId = .Act5TempleNWDown, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5TempleSW, .nDestLevelPrestId = .Act5TempleSWDown, .nDestPickedFile = -1, .nDirection = 3 },
};
// Ghidra decompiled this as [3], but the engine indexes it with nRoll in {1,2,3}
// (nRollMod3 0/1/2 advanced +1 mod-4), so it has a 4th element. Element [3] read
// from .rdata @0x6f0358 (1.14d): {src=0x414, dst=0x41b, file=-1, dir=2 SOUTHWEST} —
// the SW direction the truncated [3] view dropped.
const gaDrlgRoomReplacementsB = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5TempleNE, .nDestLevelPrestId = .Act5TempleNEWaypoint, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5TempleNW, .nDestLevelPrestId = .Act5TempleNWWaypoint, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5TempleSW, .nDestLevelPrestId = .Act5TempleSWWaypoint, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5TempleSEUp, .nDestLevelPrestId = .Act5TempleSEWaypoint, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn TempleReplaceRooms(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    // nRollMod3 = low % 3 (low-word divide, 1.14d 0x673016).
    const nRollMod3: i32 = @intCast(@as(u32, @bitCast(DVar1.nSeedLow)) % 3);
    var nRoll: i32 = nRollMod3;
    if (pLevel.*.eD2LevelId != .HallsofVaught) {
        Maze.ReplaceRoom(@constCast(&gaDrlgRoomReplacementsA[@intCast(nRollMod3)]), pLevel, &nRoll);
    }
    if (pLevel.*.eD2LevelId != .HallsofPain) return;
    // recon: error-halt if no replacement advanced nRoll. Then B+nRoll. nRoll is
    // nRollMod3+1 (mod 4) so it lands in {1,2,3} — the [4] table covers all three.
    if (nRoll == nRollMod3) return;
    rr(pLevel, &gaDrlgRoomReplacementsB, &nRoll);
}

// IceCaves::ReplaceRooms (Act5/IceCaves.cpp:25, 1.14d 00673530)
const DRLG_ICECAVES_REPLACE_ONE = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5IceN, .nDestLevelPrestId = .Act5IcePrevN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5IceE, .nDestLevelPrestId = .Act5IcePrevE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5IceS, .nDestLevelPrestId = .Act5IcePrevS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5IceW, .nDestLevelPrestId = .Act5IcePrevW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_ICECAVES_REPLACE_TWO = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5IceN, .nDestLevelPrestId = .Act5IceNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5IceE, .nDestLevelPrestId = .Act5IceNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5IceS, .nDestLevelPrestId = .Act5IceNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5IceW, .nDestLevelPrestId = .Act5IceNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_ICECAVES_REPLACE_THREE = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5IceN, .nDestLevelPrestId = .Act5IceDownN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5IceE, .nDestLevelPrestId = .Act5IceDownE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5IceS, .nDestLevelPrestId = .Act5IceDownS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5IceW, .nDestLevelPrestId = .Act5IceDownW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_ICECAVES_REPLACE_FOUR = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5IceN, .nDestLevelPrestId = .Act5IceThemeN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5IceE, .nDestLevelPrestId = .Act5IceThemeE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5IceS, .nDestLevelPrestId = .Act5IceThemeS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5IceW, .nDestLevelPrestId = .Act5IceThemeW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_ICECAVES_REPLACE_FIVE = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5IceN, .nDestLevelPrestId = .Act5IceWaypointN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5IceE, .nDestLevelPrestId = .Act5IceWaypointE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5IceS, .nDestLevelPrestId = .Act5IceWaypointS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5IceW, .nDestLevelPrestId = .Act5IceWaypointW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn IceCavesReplaceRooms(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    var nRoll: i32 = DVar1.nSeedLow & 3;
    rr(pLevel, &DRLG_ICECAVES_REPLACE_ONE, &nRoll);
    rr(pLevel, &DRLG_ICECAVES_REPLACE_TWO, &nRoll);
    rr(pLevel, &DRLG_ICECAVES_REPLACE_THREE, &nRoll);
    const lid = pLevel.*.eD2LevelId;
    if (lid != .CrystalizedPassage) {
        if (lid == .GlacialTrail) {
            rr(pLevel, &DRLG_ICECAVES_REPLACE_FOUR, &nRoll);
        } else if (lid != .AncientsWay) {
            return;
        }
    }
    rr(pLevel, &DRLG_ICECAVES_REPLACE_FIVE, &nRoll);
}

// Worldstone::PutRedNextLevelAreasInPlace (Act5/Worldstone.cpp:25, 006730b0)
const DRLG_WORLDSTONE_REPLACEMENT = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5BaalN, .nDestLevelPrestId = .Act5BaalNextN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5BaalE, .nDestLevelPrestId = .Act5BaalNextE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5BaalS, .nDestLevelPrestId = .Act5BaalNextS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5BaalW, .nDestLevelPrestId = .Act5BaalNextW, .nDestPickedFile = -1, .nDirection = 2 },
};
const DRLG_WORLDSTONE_WAYPOINT_ROOMS = [4]s.D2DrlgReplaceRoomStrc{
    .{ .nSourceLevelPrestId = .Act5BaalN, .nDestLevelPrestId = .Act5BaalWaypointN, .nDestPickedFile = -1, .nDirection = 3 },
    .{ .nSourceLevelPrestId = .Act5BaalE, .nDestLevelPrestId = .Act5BaalWaypointE, .nDestPickedFile = -1, .nDirection = 0 },
    .{ .nSourceLevelPrestId = .Act5BaalS, .nDestLevelPrestId = .Act5BaalWaypointS, .nDestPickedFile = -1, .nDirection = 1 },
    .{ .nSourceLevelPrestId = .Act5BaalW, .nDestLevelPrestId = .Act5BaalWaypointW, .nDestPickedFile = -1, .nDirection = 2 },
};

pub fn WorldstonePutRed(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const DVar1 = rng.sEEDNEXT(pLevel.*.sSeed);
    pLevel.*.sSeed = DVar1;
    var nRoll: i32 = DVar1.nSeedLow & 3;
    rr(pLevel, &DRLG_WORLDSTONE_REPLACEMENT, &nRoll);
    if (pLevel.*.eD2LevelId != .WorldstoneLvl2) return;
    rr(pLevel, &DRLG_WORLDSTONE_WAYPOINT_ROOMS, &nRoll);
}
