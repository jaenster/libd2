//! Shared DRLG enums for the maze transform. Values are FAITHFUL to the 1.14d
//! engine (same integers the recon switches on) — these only put readable names on
//! the raw constants the closure decompile left as bare ints.
//!
//! The struct fields stay i32 (structs.zig type-aliases eDrlgDirection/eD2LevelId to
//! i32, matching the rest of the closure); these enums are applied at the switch
//! sites via @enumFromInt so the blast radius stays inside the maze module.

const eD2LevelId = @import("../enums.zig").eD2LevelId;

/// LvlTypes.txt "LevelType" — the maze generator's per-type dispatch key
/// (DRLGMAZE_GenerateLevel / DRLGMAZE_PickRoomPreset switch on pLevel->nLevelType).
/// Names are descriptive (the recon switches on the raw ints below); non-exhaustive
/// so non-maze types fall through `_`.
pub const eDrlgLevelType = enum(i32) {
    act1_caves = 3,
    act1_crypt = 4,
    barracks_family = 7, // grid + grow (Barracks via the level-id tail)
    act1_jail = 8,
    act1_catacombs = 10,
    act2_sewer = 0xd,
    generic_0e = 0xe, // plain BuildRoomGrid, no special
    generic_0f = 0xf,
    act2_tombs = 0x11,
    act2_lair = 0x12,
    act2_arcane = 0x13,
    act3_durance = 0x16,
    generic_17 = 0x17,
    act3_dungeon = 0x18,
    act3_sewers = 0x19,
    river_family = 0x1c, // grow only (River of Flames via the level-id tail)
    act5_temple = 0x20,
    act5_icecaves = 0x21,
    act5_worldstone = 0x22,
    act5_baal = 0x23,
    _,

    pub inline fn of(nLevelType: i32) eDrlgLevelType {
        return @enumFromInt(nLevelType);
    }
};

/// Levels.txt "DrlgType" — how a level is generated (D2DrlgLevelStrc.eDrlgType).
pub const eDrlgType = enum(i32) {
    none = 0,
    maze = 1, // DRLGTYPE_RandomMaze
    preset = 2, // DRLGTYPE_PresetArea
    wilderness = 3, // DRLGTYPE_WildernessLevel
    _,
};

/// eD2LevelId named members for the special-case level ids the maze generators
/// branch on. (Levels.txt "Id"; faithful values.)
pub const LevelId = struct {
    // DRLGMAZE_PickRoomPreset 0xf/0x17 variant overrides. Raw Levels.txt "Id"
    // values (the engine compares the level id field directly); see Levels.txt
    // for the canonical internal name — NOT mapped to eD2LevelId in-game names,
    // which diverge for Act II (e.g. 0x3d = "Tomb 3 Treasure").
    pub const tower_lower_2: eD2LevelId = @enumFromInt(0x34); // type-0xf variant=2 (preset 0x169)
    pub const tower_lower_4: eD2LevelId = @enumFromInt(0x36); // type-0xf variant=3 (presets 0x169/0x167)
    pub const arcane_0x54: eD2LevelId = @enumFromInt(0x54); // type-0x17 override 0x296 -> 0x298
    pub const arcane_0x55: eD2LevelId = @enumFromInt(0x55); // type-0x17 override 0x295 -> 0x297

    // GenerateLevel per-level-id arms.
    pub const tomb_fixed: eD2LevelId = @enumFromInt(0x3d); // Tombs arm: fixed preset 0x1e0
    pub const act3_sewer_special: eD2LevelId = @enumFromInt(0x5c); // Act3 sewers 5x5-grid special block
    pub const barracks: eD2LevelId = @enumFromInt(0x1c); // post-switch Barracks placement
    pub const river_of_flames: eD2LevelId = @enumFromInt(0x6b); // post-switch River placement

    // Act5 ice-cave fixed-preset single levels (LevelType 0x21).
    pub const frozen_river: eD2LevelId = @enumFromInt(114); // Ice Cave 1A, def 0x40f-roll
    pub const drifter_cavern: eD2LevelId = @enumFromInt(116); // Ice Cave 2A, def 0x410
    pub const icy_cellar: eD2LevelId = @enumFromInt(119); // Ice Cave 3A, def 0x411
};
