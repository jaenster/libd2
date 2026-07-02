//! Per-act OUTDOOR placement entry points (the InitAct{1..5}Outdoor-
//! Level tree dispatched from DRLGOUTDOOR_GenerateLevel, Outdoors.cpp:1402).
//!
//! Faithful transform of recon/closure/{Outdoors,OutWild,OutDesr,OutPlace,
//! OutSiege}.cpp. Field access by NAME; RNG via the verified selector; the spawn
//! machinery lives in OutPlace.zig.
//!
//! Transformed here so far:
//!   BuildChaosSanctuary        Outdoors.cpp:1481
//!   InitAct4OutdoorLevel       Outdoors.cpp:1520  (Chaos Sanctuary path)
//!
//! The remaining act paths (border tracing / secondary borders / waypoints /
//! shrines / road presets) are not yet wired; those levels keep the plain-grid
//! output (no per-act borders) until their trees land.

const std = @import("std");
const s = @import("../structs.zig");
const drlg = @import("../drlg.zig");
const OutPlace = @import("OutPlace.zig");
const Border = @import("Border.zig");
const OutDesr = @import("OutDesr.zig");
const Outdoors = @import("Outdoors.zig");
const OutRoom = @import("OutRoom.zig");

const W = s.D2DrlgLevelDataWildernessLevel;

inline fn wild(pLevel: [*c]s.D2DrlgLevelStrc) *W {
    return @ptrCast(@alignCast(pLevel.*.pDrlgLevelData.?));
}

// BuildChaosSanctuary   Outdoors.cpp:1481
// Stamps the 5x5 grid of 3x3-cell presets that tiles the whole 15x15 Chaos
// Sanctuary (level 0x6c). Each SpawnEx with nFileIndex=-1 rolls one file index
// off pLevel->sSeed via the per-preset round-robin tracker.
const aChaosSanctuaryPresets = [25]i32{
    0x344, 0x344, 0x344, 0x344, 0x344,
    0x344, 0x344, 0x35d, 0x344, 0x344,
    0x344, 0x35a, 0x35e, 0x35b, 0x344,
    0x344, 0x344, 0x35c, 0x344, 0x344,
    0x344, 0x344, 0x359, 0x344, 0x344,
};
pub fn BuildChaosSanctuary(pLevel: [*c]s.D2DrlgLevelStrc) void {
    var i: i32 = 0;
    while (i < 0x19) : (i += 1) {
        OutPlace.SpawnOutdoorLevelPresetEx(
            pLevel,
            @rem(i, 5) * 3,
            @divTrunc(i, 5) * 3,
            aChaosSanctuaryPresets[@intCast(i)],
            -1,
            0,
        );
    }
}

// DRLGOUTPLACE_PlaceAct4SpecialPresets   Outdoors.cpp:1467
pub fn placeAct4SpecialPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const flags = wild(pLevel).dwFlags;
    if (flags & 0x400000 != 0) OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 1, 0x31e, -1, 0);
    if (flags & 0x800000 == 0) return;
    OutPlace.SpawnOutdoorLevelPresetEx(pLevel, 0, 4, 0x31e, -1, 0);
}

// InitAct1OutdoorLevel   OutWild.cpp:87 (1.14d 006807f0)
pub fn InitAct1OutdoorLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    drlg.applyAct1WildRoadFlags(pLevel);
    const eLevelId = pLevel.*.eD2LevelId;
    if (eLevelId != .BloodMoor and eLevelId != .ColdPlains and eLevelId != .BurialGrounds) {
        Border.markBorderJunctions(pLevel);
    }
    Border.SetOutGridLinkFlags(pLevel);
    Border.PlaceAct1245OutdoorBorders(pLevel);

    // OutWild.cpp:95 — levels 2-7: interleaved secondary borders and OutRoom steps
    if (@intFromEnum(eLevelId) > 1 and @intFromEnum(eLevelId) < 8) {
        Outdoors.AddAct124SecondaryBorder(pLevel, 0, 4);
        OutRoom.fillBorderCornersAndPresets(pLevel);
        Outdoors.AddAct124SecondaryBorder(pLevel, 1, 4);
        Outdoors.AddAct124SecondaryBorder(pLevel, 2, 4);
        OutRoom.SpawnTownTransitionsAndCaves(pLevel);
        Outdoors.AddAct124SecondaryBorder(pLevel, 3, 4);
        OutRoom.linkOutdoorRoomExits(pLevel);
    }

    // OutWild.cpp:104 — Stony Field (0x27): four secondary borders back-to-back
    if (eLevelId == .MooMooFarm) {
        Outdoors.AddAct124SecondaryBorder(pLevel, 0, 4);
        Outdoors.AddAct124SecondaryBorder(pLevel, 1, 4);
        Outdoors.AddAct124SecondaryBorder(pLevel, 2, 4);
        Outdoors.AddAct124SecondaryBorder(pLevel, 3, 4);
    }

    // OutWild.cpp:110 — waypoint for levels 3-6
    if (@intFromEnum(eLevelId) > 2 and @intFromEnum(eLevelId) < 7) {
        Outdoors.SpawnAct12Waypoint(pLevel);
    }
    // OutWild.cpp:113 — shrines for levels 2-7
    if (@intFromEnum(eLevelId) > 1 and @intFromEnum(eLevelId) < 8) {
        Outdoors.SpawnAct12Shrines(pLevel, 5);
    }

    // OutWild.cpp:117 — preset spawns for ALL Act-1 outdoor levels
    OutRoom.spawnAct1LevelPresets(pLevel);
}

// InitAct2OutdoorLevel   OutDesr.cpp:265
// Fully transformed in OutDesr.zig (the whole interleaved Act-2 desert tail:
// cliffs / exits / secondary borders / waypoints / shrines / fills / ruins /
// tomb entries, in the exact recon seed-consumption order).
pub const InitAct2OutdoorLevel = OutDesr.InitAct2OutdoorLevel;

// NOTE: Act-5 outdoor generation lives in Act5.zig (OutSiege::InitAct5OutdoorLevel,
// 0x67e600) — that is what DRLGOUTDOOR_GenerateLevel dispatches to. (An earlier
// stub here was dead code and has been removed.)

// DRLGOUTDOOR_SpawnAct4OutdoorPresets   Outdoors/Act4.cpp:22 (1.14d 0067e6a0)
// .rdata tables (indexed by eLevelId, normalised to 0-based via LEA [EAX*4+0xfffffe60]):
//   gnAct4OutdoorsPresetOffsetByType  @ 0x6f22b0: 0x68→0x32C  0x69→0x331  0x6a→0x337
//   gnAct5SceneryPresetOffsetByOrientation @ 0x6f22a4: 0x68→0x33C  0x69→0x340  0x6a→0x340
const gnAct4PresetBaseA = [_]i32{ 0x32C, 0x331, 0x337 }; // index = eLevelId - 0x68
const gnAct4PresetBaseB = [_]i32{ 0x33C, 0x340, 0x340 }; // index = eLevelId - 0x68

fn spawnAct4OutdoorPresets(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const eLevelId = pLevel.*.eD2LevelId;
    if (eLevelId == .CityoftheDamned) {
        _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x32b, -1, 0, 0xf);
    }
    var nPresetBaseA: i32 = gnAct4PresetBaseA[@intCast(@intFromEnum(eLevelId) - 0x68)];
    var nPresetBaseB: i32 = gnAct4PresetBaseB[@intCast(@intFromEnum(eLevelId) - 0x68)];
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA + 1, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA + 1, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA + 2, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA + 2, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA + 3, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA + 3, -1, 0, 0xf);
    if (eLevelId == .PlainsofDespair) {
        _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, 0x336, -1, 0, 0xf);
    }
    nPresetBaseA += 4;
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseA, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB + 1, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB + 1, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB + 2, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB + 2, -1, 0, 0xf);
    nPresetBaseB += 3;
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB, -1, 0, 0xf);
    _ = OutPlace.SpawnOutdoorLevelPreset(pLevel, nPresetBaseB, -1, 0, 0xf);
}

// InitAct4OutdoorLevel   Outdoors.cpp:1520 (1.14d 0067e890)
pub fn InitAct4OutdoorLevel(pLevel: [*c]s.D2DrlgLevelStrc) void {
    const eLevelId = pLevel.*.eD2LevelId;
    // SetOutGridLinkFlags: writes inter-level link flags; no-op in the per-level harness.
    Border.SetOutGridLinkFlags(pLevel);
    if (eLevelId != .ChaosSanctuary) {
        Border.PlaceAct1245OutdoorBorders(pLevel);
    }
    if (@intFromEnum(eLevelId) <= 0x67) return;
    if (@intFromEnum(eLevelId) < 0x6b) {
        // DRLGPLACE_Adjacent4DirMirrored (Drlg.cpp:3247) is called only for level
        // 104 in ACT4_D2DrlgLevelData1 (Drlg.cpp:4385). It draws one seed and sets
        // gdwDrlgLevelPlacementFlags = 0x800000 when sNextSeed&1=1, else 0x400000.
        // Drlg.cpp:4772 then OR's that flag into level 104's pDrlgLevelData->dwFlags.
        // Levels 105/106 use fpLDE2 (no placement-flag write) so their dwFlags = 0.
        // The flag selects DRLGOUTPLACE_PlaceAct4SpecialPresets: 0x800000→(0,4),
        // 0x400000→(0,1).
        //
        // DRLGPLACE_Adjacent4DirMirrored direction 3 places level at:
        //   sNextSeed&1=1: y = prevY + prevH - levelH + 8  → flag 0x800000
        //   sNextSeed&1=0: y = prevY - 8                   → flag 0x400000
        // Deriving the flag from the actual WorldPositions is faithful because the
        // positions are the sole observable output of that seed draw.
        if (eLevelId == .OuterSteppes) {
            const myPos = pLevel.*.sCoordinatesAndSize;
            var pSearch: ?*s.D2DrlgLevelStrc = pLevel.*.pDrlg.?.pLevel;
            while (pSearch) |ps| : (pSearch = ps.pLevelNext) {
                if (ps.eD2LevelId == .PandemoniumFortress) {
                    const prevPos = ps.sCoordinatesAndSize;
                    const flag: u32 = if (myPos.WorldPosition.y == prevPos.WorldPosition.y + prevPos.WorldSize.y - myPos.WorldSize.y + 8)
                        @as(u32, 0x800000)
                    else
                        @as(u32, 0x400000);
                    wild(pLevel).dwFlags |= flag;
                    break;
                }
            }
        }
        placeAct4SpecialPresets(pLevel);
        Outdoors.AddAct124SecondaryBorder(pLevel, 1, 799);
        Outdoors.AddAct124SecondaryBorder(pLevel, 2, 799);
        Outdoors.AddAct124SecondaryBorder(pLevel, 3, 799);
        spawnAct4OutdoorPresets(pLevel);
    } else if (eLevelId == .ChaosSanctuary) {
        BuildChaosSanctuary(pLevel);
    }
}
