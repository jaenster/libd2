//! Faithful Zig transform of the D2 1.14d DRLG struct definitions.
//!
//! Mechanically transcribed from the reconstructed C++ headers at
//! ~/code/ts/ghidra-reconstruct/output/D2Common/**/*Strc.h — EXACT field order
//! and names preserved. The `/* 0x.. */` offset comments in the source are for
//! the 32-bit engine ABI; this is a STANDALONE Zig DRLG so we let Zig compute
//! offsets (pointers are 8 bytes here — self-consistent). `extern struct` keeps
//! C field order. Cross-module types the DRLG only touches via pointer are left
//! `opaque` (filled in by later phases / never dereferenced by the generator).
//!
//! Do not "improve" fields — this is a faithful 1:1 transform.

// Scalar / platform helper types (d2_platform.h)

/// Win32 POINT (long x, long y). 32-bit ABI long == 4 bytes.
pub const POINT = extern struct {
    x: i32,
    y: i32,
};

/// Win32 RECT (long left/top/right/bottom).
pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Win32 CRITICAL_SECTION (non-_WIN32 stub layout from d2_platform.h).
pub const CRITICAL_SECTION = extern struct {
    DebugInfo: ?*anyopaque,
    LockCount: i32,
    RecursionCount: i32,
    OwningThread: ?*anyopaque,
    LockSemaphore: ?*anyopaque,
    SpinCount: u32,
};

// Enum typedefs (all `typedef int ...` in the headers -> i32 aliases)

pub const eD2LevelId = @import("../enums.zig").eD2LevelId;
pub const eD2PresetId = @import("../enums.zig").eD2PresetId;
pub const eDrlgType = @import("enums.zig").eDrlgType;
pub const eDrlgLevelType = @import("enums.zig").eDrlgLevelType;
pub const eD2UnitType = i32;
pub const eDrlgDirection = i32;
pub const eD2GridCellFlags = i32;
pub const eCollisionFlags = i32;

/// D2RoomExStrc.eRoomExFlags bitfield (the canonical DRLGROOMFLAG_* bit layout).
/// Grid/room flag spaces share this u32 — nGridFlags/dwRoomFlags get OR'd in via
/// orRaw(); behaviour is faithful to the 1.14d recon (same bit values).
pub const RoomExFlags = packed struct(u32) {
    _b0: bool = false,
    inactive: bool = false, // 0x2
    _b2_3: u2 = 0,
    /// 0xff0 — 8 warp/adjacency slots (bit n == slot n).
    warpSlots: u8 = 0,
    /// 0xf000 — sub-shrine rows 1..4.
    shrineRows: u4 = 0,
    /// 0x30000 — waypoint + small-waypoint.
    waypoint: u2 = 0,
    mapReveal: bool = false, // 0x40000
    noLos: bool = false, // 0x80000   (don't draw line-of-sight)
    roomActive: bool = false, // 0x100000  (an active pRoom is attached)
    roomFreed: bool = false, // 0x200000
    portal: bool = false, // 0x400000
    noSpawn: bool = false, // 0x800000  (towns / ds1 populate=0)
    tilesLoaded: bool = false, // 0x1000000
    presetsAdded: bool = false, // 0x2000000
    presetsSpawned: bool = false, // 0x4000000  (preset units already spawned)
    animatedFloor: bool = false, // 0x8000000
    _b28_31: u4 = 0,

    pub inline fn raw(self: RoomExFlags) u32 {
        return @bitCast(self);
    }
    /// OR raw flag bits in (grid/room flag spaces share this u32).
    pub inline fn orRaw(self: *RoomExFlags, bits: i32) void {
        self.* = @bitCast(@as(u32, @bitCast(self.*)) | @as(u32, @bitCast(bits)));
    }
    /// Any warp slot set (was & 0xff0).
    pub inline fn anyWarp(self: RoomExFlags) bool {
        return self.warpSlots != 0;
    }
    /// Warp slot `slot` set (was & (1 << (slot+4))).
    pub inline fn warpSlot(self: RoomExFlags, slot: u3) bool {
        return (self.warpSlots & (@as(u8, 1) << slot)) != 0;
    }
    /// Has a waypoint (was & 0x30000).
    pub inline fn hasWaypoint(self: RoomExFlags) bool {
        return self.waypoint != 0;
    }
};

// Opaque / cross-module forward types (referenced only via pointer by the DRLG
// closure; defined in other modules or later phases).

pub const D2GameStrc = opaque {};
pub const D2UnitStrc = opaque {};
pub const D2MPQFileStrc = opaque {};
pub const D2AiGeneralStrc = opaque {};
pub const D2CoordStrc = opaque {};
pub const D2TileRecordStrc = opaque {};
pub const D2TileLibraryHashNodeStrc = opaque {};
pub const D2DrlgLevelDataList = opaque {};
/// LvlPrest.txt row (table data — leaf support).
pub const D2LvlPrestTxt = opaque {};
/// LvlMaze.txt row (table data — leaf support).
pub const D2LvlMazeTxt = opaque {};

// D2SeedStrc.h

/// 64-bit DRLG PRNG state (nSeedLow + nSeedHigh). C++ ctors/operators dropped.
pub const D2SeedStrc = extern struct {
    nSeedLow: i32,
    nSeedHigh: i32,
};

// Drlg/D2DrlgCoordsStrc.h

pub const D2DrlgCoordsStrc = extern struct {
    WorldPosition: POINT,
    WorldSize: POINT,
};

// Drlg/Preset.h (D2DrlgCoordStrc, preset data, D2PresetUnitStrc)

pub const D2DrlgCoordStrc = extern struct {
    nPosX: i32,
    nPosY: i32,
    nWidth: i32,
    nHeight: i32,
};

pub const D2DrlgRoomExDataPresetWorldCoordinatesBurialGrounds = extern struct {
    /// list of points where BloodRaven moves to
    PointsList: [6]POINT,
};

pub const D2DrlgRoomExDataPreset = extern struct {
    Def: eD2PresetId,
    field_0x4: u8,
    _pad_0x05: [235]u8,
    sWorldPointsBurialGrounds: ?*D2DrlgRoomExDataPresetWorldCoordinatesBurialGrounds,
    nWorldPointsBurialGroundsSize: i32,
};

pub const D2PresetUnitStrc = extern struct {
    /// Mode flag - 1 for monsters from monpreset.txt, 3 for items
    nMode: i32,
    /// Unit class ID - MonStats ID for monsters, Object ID for objects
    nClassId: i32,
    /// X position in world coordinates (sub-tile units)
    nPosX: i32,
    pPresetUnitNext: ?*D2PresetUnitStrc,
    /// preset path data {int nCount; D2PresetPathEntry* pEntries}
    pPath: ?*anyopaque,
    /// Unit type (UNIT_MONSTER=1, UNIT_OBJECT=2, UNIT_ITEM=4, UNIT_WARP=5)
    eType: eD2UnitType,
    /// Y position in world coordinates (sub-tile units)
    nPosY: i32,
    /// Flags bitmask (bit 0 = auto-generated object)
    nFlags: i32,
};

// Drlg/D2DrlgGridStrc.h

pub const D2DrlgGridStrc = extern struct {
    /// Array of cell flags. NULL if grid not initialized.
    pCellsFlags: [*c]eD2GridCellFlags,
    /// Array of row start offsets into pCellsFlags (one per nHeight rows).
    pCellsRowOffsets: [*c]i32,
    /// Number of cells per row (X dimension).
    nWidth: i32,
    /// Number of rows (Y dimension).
    nHeight: i32,
    /// If nonzero, pCellsFlags is shared/embedded and not freed by FreeGrid.
    bIsSubGrid: i32,
};

// Drlg/D2DrlgVertexStrc.h

pub const D2DrlgVertexStrc = extern struct {
    nPosX: i32,
    nPosY: i32,
    nDirection: u8,
    dwFlags: i32,
    pNext: ?*D2DrlgVertexStrc,
};

// Drlg/D2DrlgOrthStrc.h

pub const D2DrlgOrthStrc = extern struct {
    /// Union: D2DrlgLevelStrc* when nType==0, D2RoomExStrc* when nType==1
    pRoomEx: ?*D2RoomExStrc,
    neDrlgDirection: eDrlgDirection,
    /// BOOL: whether linked level/room is a preset area
    bIsDrlgTypePresetArea: i32,
    /// 0=level link (pRoomEx is D2DrlgLevelStrc*), 1=room link (D2RoomExStrc*)
    nType: i32,
    /// Points to sCoordinatesAndSize of linked level or sCoords of linked room
    psCoordinatesAndSize: ?*D2DrlgCoordsStrc,
    pNext: ?*D2DrlgOrthStrc,
};

// Drlg/D2DrlgReplaceRoomStrc.h

pub const D2DrlgReplaceRoomStrc = extern struct {
    nSourceLevelPrestId: eD2PresetId,
    nDestLevelPrestId: eD2PresetId,
    nDestPickedFile: i32,
    nDirection: i32,
};

// Drlg/D2DrlgRoomCoordsStrc.h

pub const D2DrlgRoomCoordsStrc = extern struct {
    dwXStart: i32,
    dwYStart: i32,
    dwXSize: i32,
    dwYSize: i32,
    sTileRect: RECT,
};

// Drlg/D2DrlgTileDataStrc.h

pub const D2DrlgTileDataStrc = extern struct {
    /// Screen X coordinate (from minimap->screen transform)
    nScreenX: i32,
    /// Screen Y coordinate
    nScreenY: i32,
    /// Tile X relative to room origin
    nPosX: i32,
    /// Tile Y relative to room origin
    nPosY: i32,
    /// Grid cell flags from DrlgCoordList
    nGridFlags: i32,
    /// Tile draw flags bitmask
    nFlags: i32,
    pTileLibraryEntry: ?*D2TileLibraryEntryStrc,
    /// Tile orientation/type (0=floor, 3=left wall, 4=right wall, 0xD=shadow)
    nTileType: i32,
    /// Next tile in linked list (or next in array when no links)
    pNext: ?*D2DrlgTileDataStrc,
    /// Bit0=lightMode, bit1=fading transparency, bit2=fading to hide
    nTransitionFlags: i32,
    nRed: u8,
    nGreen: u8,
    nBlue: u8,
    nIntensity: u8,
    /// GetTickCount() timestamp when fade animation ends
    nFadeEndTime: i32,
};

// Drlg/RoomTile.h (D2DrlgTileLinkStrc)

pub const D2DrlgTileLinkStrc = extern struct {
    /// 0 = wall type, non-zero = floor type
    bFloor: bool,
    field_0x1: u8,
    _pad_0x02: [2]u8,
    pTileData: ?*D2DrlgTileDataStrc,
    pNext: ?*D2DrlgTileLinkStrc,
};

// Drlg/DrlgAnim.h (D2DrlgAnimTileGridStrc)

pub const D2DrlgAnimTileGridStrc = extern struct {
    /// Array of tile data pointers (one per animation frame)
    ppTileData: [*c]?*D2DrlgTileDataStrc,
    nFrames: i32,
    nCurrentFrame: i32,
    /// Tile orientation/type identifier from grid
    pTileType: i32,
    pNext: ?*D2DrlgAnimTileGridStrc,
};

// Drlg/D2DrlgTileGridStrc.h

pub const D2DrlgTileGridStrc = extern struct {
    /// Linked list of tile links. In warp nodes: D2RoomExStrc* target room
    pMapLinks: ?*D2DrlgTileLinkStrc,
    /// Linked list of animated tile grids. In warp nodes: pNext
    pAnimTiles: ?*D2DrlgAnimTileGridStrc,
    /// Current wall tile write index
    nWalls: i32,
    /// Current floor tile write index
    nFloors: i32,
    /// Current shadow/roof write index. In warp nodes: warp destination ID
    nShadows: i32,
    /// Wall tile data array (0x30 bytes per element)
    pWallTiles: ?*D2DrlgTileDataStrc,
    nWallTilesMax: i32,
    pFloorTiles: ?*D2DrlgTileDataStrc,
    nFloorTilesMax: i32,
    pRoofTiles: ?*D2DrlgTileDataStrc,
    nRoofTilesMax: i32,
};

// Drlg/Drlg.h (D2DrlgRoomTilesStrc, D2TileLibraryHashStrc,
//              D2DrlgLevelLinkNodeStrc, D2DrlgLevelPlacementStrc)

pub const D2DrlgRoomTilesStrc = extern struct {
    pWallTiles: ?*D2DrlgTileDataStrc,
    nWallTilesCount: i32,
    pFloorTiles: ?*D2DrlgTileDataStrc,
    nFloorTilesCount: i32,
    pRoofTiles: ?*D2DrlgTileDataStrc,
    nRoofTilesCount: i32,
};

pub const D2TileLibraryHashStrc = extern struct {
    pNodes: [128]?*D2TileLibraryHashNodeStrc,
};

pub const D2DrlgLevelLinkNodeStrc = extern struct {
    dwData0: i32,
    dwData1: i32,
    dwData2: i32,
    pNext: ?*D2DrlgLevelLinkNodeStrc,
};

pub const D2DrlgLevelPlacementStrc = extern struct {
    sSeed: D2SeedStrc,
    aCoordsAndSize: [15]D2DrlgCoordsStrc,
    pLevelData: ?*D2DrlgLevelDataList,
    aCurrentDir: [15]i32,
    aInitialDir: [15]i32,
    aStepCounter: [15]i32,
    aFlipState: [15]i32,
    nCurrentNode: i32,
    neD2LevelId: eD2LevelId,
};

// Drlg/D2DrlgLevelDataList.h

pub const D2DrlgLevelDataEntry = extern struct {
    nfpLevelDataEntry: ?*const fn (?*D2DrlgLevelPlacementStrc) callconv(.c) i32,
    neD2LevelId: eD2LevelId,
    nNodeLevelEntryIdPrev: i32,
    nNodeLevelEntryIdNext: i32,
};

// Drlg/D2DrlgRoomExDataMazeStrc.h

pub const D2DrlgRoomExDataMazeStrc = extern struct {
    /// Orientation/shadow grid for outdoor tiles
    pOrientationGrid: D2DrlgGridStrc,
    pWallGrid: D2DrlgGridStrc,
    pFloorGrid: D2DrlgGridStrc,
    pCellGrid: D2DrlgGridStrc,
    /// D2DrlgVertexStrc* vertex linked list for path/border (typed uint8_t* in .h)
    pVertex: [*c]u8,
    /// Outdoor room flags (bit 0x80 = border)
    dwFlags: i32,
    dwFlagsEx: i32,
    field_5C: i32,
    field_60: i32,
    /// SubType from LevelDefs.txt
    nSubType: i32,
    nSubTheme: i32,
    /// Random subtheme variant picked (0-31)
    nSubThemePicked: i32,
};

// D2DrlgExitPointStrc — Drlg.h:88. 0x14 bytes; runtime exit/path scratch.
pub const D2DrlgExitPointStrc = extern struct {
    nWorldX: i32,
    nWorldY: i32,
    eType: u8,
    _pad9: [3]u8,
    field_C: i32,
    field_10: i32,
};

// D2DrlgLevelDataWildernessLevel — Drlg.h:305. pDrlgLevelData for type-3 levels
// (alloc 0x268 in the 32-bit engine; here field order+types, Zig-computed 64-bit
// offsets). The recon's GenerateLevel reaches the four grids by RAW byte offsets
// (+4/+0x18/+0x2c/+0x40); the transform uses NAMED fields per the .h layout.
pub const D2DrlgLevelDataWildernessLevel = extern struct {
    dwFlags: u32,
    sGridPreset: D2DrlgGridStrc, // +0x04 preset level ids / orientation
    sGridLink: D2DrlgGridStrc, // +0x18 vis/link flags
    sGridOutdoor: D2DrlgGridStrc, // +0x2c outdoor placement flags
    sGridMisc: D2DrlgGridStrc, // +0x40 misc outdoor flags
    pGridCoordsCellFlags: ?*eD2GridCellFlags,
    pGridCoordsRowOffsets: [*c]i32,
    nGridCoordsWidth: i32, // WorldSize.x / 8
    nGridCoordsHeight: i32, // WorldSize.y / 8
    pVertices: ?*D2DrlgVertexStrc,
    pAdjacentVertices: [6]?*D2DrlgVertexStrc,
    aExitPoints1: [6]D2DrlgExitPointStrc,
    aExitPoints2: [6]D2DrlgExitPointStrc,
    aExitPoints3: [6]D2DrlgExitPointStrc,
    aExitPoints4: [6]D2DrlgExitPointStrc,
    nExitCount: i32,
    pOrthData: ?*D2DrlgOrthStrc,
};

// D2DrlgPresetRoomStrc — DrlgGrid.h. The pRoomExData block for nPresetType==2
// rooms (alloc 0xf8). Faithful field ORDER + types (offsets are Zig-computed for
// the standalone 64-bit port). The recon overlays integer payloads onto the
// leading int fields (nLevelPrest/nPickedFile/nFlags) and stashes pParentDrlgMap
// into the pMazeGrid pointer slot (recon Preset.cpp:807, raw index 0x3b).
pub const D2DrlgPresetRoomStrc = extern struct {
    /// LvlPrest id (recon raw index [0] = Def)
    nLevelPrest: eD2PresetId,
    /// picked DS1 file index (recon raw index [1])
    nPickedFile: i32,
    /// owning DrlgMap (recon raw index [2])
    pMap: ?*D2DrlgMapStrc,
    /// room flags (recon raw index [3])
    nFlags: i32,
    pWallGrid: [4]D2DrlgGridStrc,
    pOrientationGrid: [4]D2DrlgGridStrc,
    pFloorGrid: [2]D2DrlgGridStrc,
    pCellGrid: D2DrlgGridStrc,
    /// recon raw index [0x3b]; runtime-overloaded to hold pParentDrlgMap
    pMazeGrid: ?*anyopaque,
    pNavigationPoints: ?*anyopaque,
    nNavigationPointsCount: i32,
};

// Drlg/D2DrlgFileStrc.h

pub const D2DrlgSubstGroupStrc = extern struct {
    /// Bounding box of the substitution group
    tBox: D2DrlgCoordStrc,
    /// Substitution probability/chance (DS1 version >= 13)
    nProbability: i32,
    /// Number of variants; the placement variant is rolled in [0,nVariantCount)
    /// (PlaceRandomBorderSubTiles, 1.14d 0066f8be reads substGroup+0x14).
    nVariantCount: i32,
};

pub const D2DrlgFileStrc = extern struct {
    /// DS1 act field (version >= 10). Values 1 or 2 enable tag/subst layer.
    nAct: i32,
    /// Raw loaded DS1 file buffer.
    pDS1File: ?*anyopaque,
    unk0x08: i32,
    /// DS1 width in cells
    nWidth: i32,
    /// DS1 height in cells
    nHeight: i32,
    /// Number of wall layers (1-4)
    nWallLayers: i32,
    /// Number of floor layers (1-2)
    nFloorLayers: i32,
    /// Wall orientation/direction data per wall layer
    pTileTypeLayer: [4]?*anyopaque,
    /// Wall cell/flags data per wall layer
    pWallLayer: [4]?*anyopaque,
    /// Floor cell data per floor layer
    pFloorLayer: [2]?*anyopaque,
    pShadowLayer: ?*anyopaque,
    /// Substitution group tag layer. Present when nAct is 1 or 2.
    pSubstGroupTags: ?*anyopaque,
    /// Number of substitution groups (version >= 12)
    nSubstGroups: i32,
    pSubstGroups: ?*D2DrlgSubstGroupStrc,
    /// Linked list head of preset units parsed from DS1
    pPresetUnit: ?*D2PresetUnitStrc,
    unk0x58: i32,
};

// D2RoomCoordListStrc.h

pub const D2RoomCoordListStrc = extern struct {
    pBox: D2DrlgCoordStrc,
    pRect: RECT,
    bNode: i32,
    nRoomActive: i32,
    nIndex: i32,
    pNext: ?*D2RoomCoordListStrc,
};

// D2TileLibraryEntryStrc.h

pub const D2TileLibraryEntryStrc = extern struct {
    nDirection: i32,
    nRoofHeight: i16,
    nFlags: i16,
    nHeight: i32,
    nWidth: i32,
    nHeightToBottom: i32,
    nOrientation: i32,
    nIndex: i32,
    nSubIndex: i32,
    nFrame_Rarity: i32,
    transparentColorRGB24: i32,
    dwTileFlags: [4]u8,
    dwBlockOffset_pBlock: i32,
    nBlockSize: i32,
    nBlocks: i32,
    pParent: ?*D2TileRecordStrc,
    field16_0x3c: i16,
    nCacheIndex: i16,
    nTextureCacheIndex: i32,
    field19_0x44: i32,
    /// Archive byte offset of tile block data
    dwBlockDataOffset: i32,
    nBlockDataSize: i32,
};

// D2RoomExStrc.h (D2DrlgCoordListStrc + D2RoomExStrc)

pub const D2DrlgCoordListStrc = extern struct {
    /// Bit 0: simple/single coord, Bit 1: has grids allocated
    eFlags: i32,
    /// Number of D2RoomCoordListStrc entries
    nListSize: i32,
    /// Grid for wall/orientation indices
    sOrientationGrid: D2DrlgGridStrc,
    /// Grid mapping subtile positions to coord regions
    sCoordIndexGrid: D2DrlgGridStrc,
    /// Array of room coord list entries (size = nListSize)
    pCoord: [*c]D2RoomCoordListStrc,
};

pub const D2RoomExStrc = extern struct {
    /// linked list of orthogonal room connections
    pOrth: ?*D2DrlgOrthStrc,
    /// Initial seed value
    nSeed: i32,
    /// array of near room pointers
    ppDrlgRoomsExNear: [*c]?*D2RoomExStrc,
    /// Max near rooms array capacity
    nDrlgRoomsExNearMax: i16,
    /// Room initialization flag
    bIsInit: i16,
    /// Room type
    nType: i32,
    /// Room seed (nSeedLow + nSeedHigh)
    sSeed: D2SeedStrc,
    /// Forward link in activation priority doubly-linked list
    pStatusNext: ?*D2RoomExStrc,
    /// Union: D2DrlgRoomExDataPresetStrc*(nPresetType==2) or
    /// D2DrlgRoomExDataMazeStrc*(nPresetType==1). void* in source.
    pRoomExData: ?*anyopaque,
    /// Next room in level list
    pRoomExNext: ?*D2RoomExStrc,
    /// D2DrlgRoomFlags bitmask
    eRoomExFlags: RoomExFlags,
    /// Number of near rooms
    nDrlgRoomsExNearCount: i32,
    /// Active room, NULL when not tiled
    pRoom: ?*D2RoomStrc,
    /// Room coordinates: WorldPosition.x/y, WorldSize.x/y
    sCoords: D2DrlgCoordsStrc,
    /// Room activation status/priority (0-4)
    fRoomStatus: i32,
    /// 1=RandomMaze(outdoor), 2=PresetArea
    nPresetType: i32,
    /// Warp tile grid linked list (via pAnimTiles as next ptr)
    pTileGrid: ?*D2DrlgTileGridStrc,
    /// Bitmask of DT1 tile files to load
    nDT1Mask: i32,
    /// Room tile data - holds walls/floors/shadows tile arrays
    pRoomTiles: ?*D2DrlgTileGridStrc,
    /// Parent level
    pLevel: ?*D2DrlgLevelStrc,
    /// Linked list head of preset units (monsters/objects/items)
    pPresetUnit: ?*D2PresetUnitStrc,
    /// Secondary flags field
    dwOtherFlags: i32,
    /// Logical room info / coord regions
    pDrlgCoordList: ?*D2DrlgCoordListStrc,
    /// D2TileLibraryHashStrc*[32] - tile cache slots (void* in source)
    apTiles: [32]?*anyopaque,
    /// Backward link in activation priority doubly-linked list
    pStatusPrev: ?*D2RoomExStrc,
};

// D2RoomStrc.h (D2RoomCollisionGridStrc + D2RoomStrc)

pub const D2RoomCollisionGridStrc = extern struct {
    /// Subtile world position/size + tile rect, copied from room coords
    sCoords: D2DrlgRoomCoordsStrc,
    /// Pointer to collision data array, points to &aMap[0]
    pMapStart: [*c]eCollisionFlags,
    /// Variable-length collision flag array, indexed as [y*width+x]
    aMap: [1]eCollisionFlags,
};

pub const D2RoomStrc = extern struct {
    /// Array of adjacent/near active rooms
    ppRoomList: [*c]?*D2RoomStrc,
    /// Capacity of pClients array
    nClientsMax: u32,
    /// Wall/floor/roof tile data arrays
    pRoomTiles: ?*D2DrlgRoomTilesStrc,
    /// Ticks since last client present
    nIdleTicks: i32,
    /// Back-pointer to DRLG room
    pRoomEx: ?*D2RoomExStrc,
    dwUnk0x14: i32,
    /// Linked list of pending deletions
    pDrlgDelete: ?*D2DrlgDeleteStrc,
    /// Head of unit update linked list
    pUnitUpdate: ?*D2UnitStrc,
    /// Subtile collision map
    pCollisionGrid: ?*D2RoomCollisionGridStrc,
    /// Number of entries in ppRoomList
    nRoomListCount: u32,
    /// Count of allied units
    nAllies: i32,
    /// Parent act
    pDrlgAct: ?*D2DrlgActStrc,
    dwUnk0x30: i32,
    /// Room flags: bit0=initialized, bit1=unitInactiveProcessed, bit2=updateLocked
    eFlags: i32,
    dwUnk0x38: i32,
    dwUnk0x3C: i32,
    dwUnk0x40: i32,
    dwUnk0x44: i32,
    /// Array of client pointers (D2ClientStrc*[nClientsMax]) (uint8_t* in source)
    pClients: [*c]u8,
    /// Room coordinates in subtile and tile space
    sCoords: D2DrlgRoomCoordsStrc,
    /// Room RNG seed
    sSeed: D2SeedStrc,
    /// Head of unit linked list
    pUnitList: ?*D2UnitStrc,
    /// Current number of clients in pClients array
    nClientsCount: i32,
    /// Next room in act room linked list
    pDrlgRoomNext: ?*D2RoomStrc,
};

// D2UnkOutdoorStrc.h

pub const D2UnkOutdoorStrc = extern struct {
    pLevel: ?*D2DrlgLevelStrc,
    /// Pointer into pDrlgLevelData+0x54 (bounds/coord grid)
    pCoordsGrid: ?*D2DrlgGridStrc,
    /// Pointer into pDrlgLevelData+0x04 (primary floor grid)
    pPrimaryFloorGrid: ?*D2DrlgGridStrc,
    /// Pointer into pDrlgLevelData+0x2C (wall/collision grid)
    pWallGrid: ?*D2DrlgGridStrc,
    /// Base preset ID for border lookups
    nLevelPrestId: i32,
    /// Previous border preset index; init -1, max 0x3E
    nPrevBorderPresetId: i32,
    nLvlSubId: i32,
    /// Callback: test if grid cell preset slot is free
    pfnIsPresetFree: ?*const fn (i32) callconv(.c) i32,
    /// Callback: test outdoor level preset (pointer32 in source)
    pfnTestPreset: ?*anyopaque,
    /// Callback: validate secondary border cell; NULL for Acts 1-4
    pfnValidateBorderCell: ?*anyopaque,
    /// Callback: get border preset from LvlSub; Act5 only
    pfnGetBorderPreset: ?*anyopaque,
    /// Callback: alter adjacent preset grid cells
    pfnAlterAdjacentCells: ?*anyopaque,
    /// Callback: clear a grid cell
    pfnSetBlankCell: ?*anyopaque,
    /// Callback: spawn outdoor level preset
    pfnSpawnPreset: ?*anyopaque,
};

// Drlg/D2DrlgMapStrc.h

pub const D2DrlgMapStrc = extern struct {
    /// LvlPrest ID
    nNumber: i32,
    /// Randomly selected file index from pTxtLevelPrest->Files
    nRandomMapFileSelector: i32,
    pTxtLevelPrest: ?*D2LvlPrestTxt,
    /// Loaded DS1 file data
    pDrlgFile: ?*D2DrlgFileStrc,
    /// World X position
    nRealOffsetX: i32,
    /// World Y position
    nRealOffsetY: i32,
    /// Width in tiles
    nSizeX: i32,
    /// Height in tiles
    nSizeY: i32,
    /// Vertices linked list. Non-null also acts as bHasInfo for pMapGrid.
    pVertices: ?*D2DrlgVertexStrc,
    /// Embedded grid structure
    pMapGrid: D2DrlgGridStrc,
    /// Linked list of preset units from DrlgFile
    pPresetUnit: ?*D2PresetUnitStrc,
    /// BOOL - Set to 1 during AllocDrlgMap
    bInited: i32,
    /// Number of pop locations
    nPops: i32,
    /// Array of pop tile indices [nPops]
    pPopsIndex: [*c]i32,
    /// Array of pop sub-indices [nPops]
    pPopsSubIndex: [*c]i32,
    /// Array of pop orientations [nPops]
    pPopsOrientation: [*c]i32,
    /// Array of pop location coordinates [nPops]
    pPosLocation: [*c]D2DrlgCoordStrc,
    /// Next DrlgMap in linked list
    pNext: ?*D2DrlgMapStrc,
};

// Drlg/D2DrlgLevelStrc.h (warp coords, spawn point, level)

pub const D2DrlgLevelWarpCoordinatesStrc = extern struct {
    anX: [9]i32,
    anY: [9]i32,
    nEntriesCount: i32,
};

pub const D2DrlgSpawnPointStrc = extern struct {
    nX: i32,
    nY: i32,
    nSpawnType: i32,
};

pub const D2DrlgLevelStrc = extern struct {
    eDrlgType: eDrlgType,
    dwFlags: u32,
    nRoomExCount: i32,
    nActiveCount: u32,
    pRoomExFirst: ?*D2RoomExStrc,
    /// Union: D2LvlMazeTxt*(maze), preset-area data, or wilderness data. void* in source.
    pDrlgLevelData: ?*anyopaque,
    nUnknown_018: u32,
    sCoordinatesAndSize: D2DrlgCoordsStrc,
    /// 32 spawn points, 12 bytes each
    aSpawnPoints: [32]D2DrlgSpawnPointStrc,
    pLevelNext: ?*D2DrlgLevelStrc,
    /// Head of linked list of DrlgMap entries for this level
    pDrlgMapFirst: ?*D2DrlgMapStrc,
    pDrlg: ?*D2DrlgStrc,
    nUnknown_1B8: u32,
    pAutomapEx: ?*anyopaque,
    nLevelType: eDrlgLevelType,
    sSeed: D2SeedStrc,
    /// Head of linked list of level link nodes
    pLevelLinkNodeFirst: ?*D2DrlgLevelLinkNodeStrc,
    eD2LevelId: eD2LevelId,
    dwInactiveFrames: i32,
    nSpawnPointCount: i32,
    nLastRoomExCoordsIndex: i32,
    /// Warp coordinate data: 9 X coords, 9 Y coords, and entry count
    sWarpCoordinates: D2DrlgLevelWarpCoordinatesStrc,
    pRoomExStateFlags: [*c]i32,
};

// Drlg/D2DrlgActStrc.h (tile cache, act, environment)

/// Cached tile data (sTileCache in D2DrlgActStrc) — same shape as
/// D2DrlgTileGridStrc per the source (D2DrlgTileDataStrc include + 0x30 size).
pub const D2DrlgTileDataCacheStrc = D2DrlgTileGridStrc;

pub const D2DrlgActStrc = extern struct {
    /// First level in the act (used by client)
    eLevelIdFirst: eD2LevelId,
    /// Day/night environment cycle
    pEnvironment: ?*D2DrlgEnvironmentStrc,
    /// Server-side initial level ID
    nLevelId: eD2LevelId,
    /// Map generation seed
    dwInitSeed: i32,
    /// Head of active room linked list
    pRoom: ?*D2RoomStrc,
    /// Act number (0-4)
    nActNo: u8,
    pad15: [3]u8,
    /// Cached tile data, initialized via InitCache
    sTileCache: D2DrlgTileGridStrc,
    /// DRLG act misc controller
    pDrlg: ?*D2DrlgStrc,
    /// Room allocation callback function
    pCallback: ?*const fn (?*D2RoomStrc) callconv(.c) void,
    /// BOOL - TRUE if client-side act
    bClientSide: i32,
    /// BOOL - Set to 1 when a room is allocated
    bRoomDirty: i32,
    /// BOOL - Set when DRLG delete is pending
    bDrlgDeleteIsSet: i32,
    /// Server memory pool manager
    pMemory: ?*D2PoolManagerStrc,
};

pub const D2DrlgEnvironmentStrc = extern struct {
    /// Current cycle index (0-5), wraps at 6
    nTimeIndex: i32,
    /// Current period-of-day value from environment data table
    nEnvironmentData: i32,
    /// Current tick count within the cycle phase
    nTicks: i32,
    /// Light intensity (0-255), clamped per act
    nGlobalLightIntensity: i32,
    /// GetTickCount() at allocation time
    dwInitTick: u32,
    nUnused: i32,
    nGlobalLightRed: u8,
    nGlobalLightGreen: u8,
    nGlobalLightBlue: u8,
    nPad1B: u8,
    /// Negative cosine of light angle
    fCos: f32,
    /// Previous light value, always 0.0
    fLast: f32,
    /// Sine of light angle
    fSin: f32,
    /// Current time rate multiplier from gnTimeRates table
    nTimeRate: i32,
    /// Index into gnTimeRates[] (0-2)
    nTimeRateIndex: i32,
    /// BOOL - TRUE during Tainted Sun quest eclipse
    bEclipse: i32,
    /// Last base time, used for change detection in UpdateCycleIndex
    nLastBaseTime: i32,
};

// Drlg/D2DrlgActWarpsInfoStrc.h

pub const D2DrlgActWarpsInfoStrc = extern struct {
    nLevelId: eD2LevelId,
    nTargetArea: [8]eD2LevelId,
    nWarpId: [8]i32,
    pNext: ?*D2DrlgActWarpsInfoStrc,
};

// Drlg/D2DrlgDeleteStrc.h

pub const D2DrlgDeleteStrc = extern struct {
    eUnitType: eD2UnitType,
    nUnitGUID: i32,
    pNext: ?*D2DrlgDeleteStrc,
};

// Drlg/D2DrlgWallLayerGridsStrc.h (Ghidra v628 /Diablo2/DRLG)

pub const D2DrlgWallLayerGridsStrc = extern struct {
    /// Target room being processed
    pRoomEx: ?*D2RoomExStrc,
    /// Per-wall-layer tile type grids (pDrlgGrid[0..3])
    apTileTypeGrids: [4]?*D2DrlgGridStrc,
    /// Per-wall-layer wall flag grids
    apWallGrids: [4]?*D2DrlgGridStrc,
    /// Floor flags grid for the room
    pFloorGrid: ?*D2DrlgGridStrc,
    nUnk_0x28: i32,
    /// Number of wall layers from DS1 file
    nWallLayerCount: i32,
    /// LvlDefs txt sub-type entry index
    nSubTypeLookupId: i32,
    /// Current iteration index within the sub-type set
    nSubTypeIndex: i32,
    /// Number of sub-type entries to process
    nSubTypeCount: i32,
};

// Drlg/D2DrlgStrc.h

pub const D2DrlgStrc = extern struct {
    nSeed: D2SeedStrc,
    nRoomDataGeneration: i32,
    apTileProjects: [32]?*D2TileLibraryHashStrc,
    dwFlags: u32,
    pWarpsInfo: ?*D2DrlgActWarpsInfoStrc,
    /// Act II: Horadric staff tomb level id
    nStaffTombLevel: eD2LevelId,
    nRoomInitBatchCount: u8,
    _pad099: [3]u8,
    pGame: ?*D2GameStrc,
    /// 4 RoomEx activation priority-queue sentinels
    aSubA0: [4]D2RoomExStrc,
    nDifficulty: u8,
    _pad451: [3]u8,
    pfAutoMap: ?*const fn (?*D2RoomStrc) callconv(.c) void,
    /// Unrolled act init seed (dwInitSeed param)
    dwGameLowSeed: u32,
    nActivationCountdown: u8,
    _pad45D: [3]u8,
    /// iterator for room activation loop
    pActivationIterator: ?*D2RoomExStrc,
    pDS1MemPool: ?*D2PoolManagerStrc,
    nRoomDataFreeGeneration: i32,
    pAct: ?*D2DrlgActStrc,
    /// Rolled drlg seed; used to seed each level
    dwStartSeed: u32,
    /// Act III: jungle interlink flag = seed LSB
    bJungleInterlink: i32,
    pMemoryPool: ?*D2PoolManagerStrc,
    pLevel: ?*D2DrlgLevelStrc,
    nActNo: u8,
    _pad481: [3]u8,
    /// Act II: Duriel/boss tomb level id
    nBossTombLevel: eD2LevelId,
    pfTownAutoMap: ?*const fn (eD2LevelId, i32, i32, i32) callconv(.c) void,
};

// Drlg/D2DrlgRoomExTileBucketStrc.h (Ghidra v628 /Diablo2/DRLG)

/// Per-room tile bucket overlaid on D2DrlgTileGridStrc; populated during generation. (RoomEx tile bucket)
pub const D2DrlgRoomExTileBucketStrc = extern struct {
    /// Mirrors D2DrlgTileGridStrc.pMapLinks (struct D2DrlgTileLinkStrc*)
    pMapLinks: ?*D2DrlgTileLinkStrc,
    /// Mirrors D2DrlgTileGridStrc.pAnimTiles (struct D2DrlgAnimTileGridStrc*)
    pAnimTiles: ?*D2DrlgAnimTileGridStrc,
    pNext: ?*D2DrlgRoomExTileBucketStrc,
    /// Mirrors D2DrlgTileGridStrc.nFloors — current floor tile write index
    nFloors: i32,
    /// Mirrors D2DrlgTileGridStrc.nShadows — current shadow/roof tile write index
    nShadows: i32,
    Tiles: D2DrlgRoomTilesStrc,
};

// Drlg/D2DrlgRoomExRoomTileNodeStrc.h (Ghidra v628 /Diablo2/DRLG)

/// RoomEx +0x4C roomtile/warp node; mostly opaque — only next-pointer RE'd. (RoomEx tile/warp node; runtime-only-unused by generation)
pub const D2DrlgRoomExRoomTileNodeStrc = extern struct {
    _unk_0x00: i32,
    pRoomTileNext: ?*D2DrlgRoomExRoomTileNodeStrc,
    _unk_0x08: [16]u8,
};

// Drlg/D2DrlgRoomExNearNodeStrc.h (Ghidra v628 /Diablo2/DRLG)

/// Orthogonal-like room-adjacency node for near-room tracking; populated during generation. (RoomEx adjacency node)
pub const D2DrlgRoomExNearNodeStrc = extern struct {
    pRoomEx: ?*D2RoomExStrc,
    _unk_0x04: i32,
    bIsDrlgTypePresetArea: i32,
    nNextCount: i32,
    psCoordinatesAndSize: ?*D2DrlgCoordsStrc,
    pSub00Next: ?*D2DrlgRoomExNearNodeStrc,
};

// Drlg/D2DrlgRoomAStarNodeStrc.h (Ghidra v628 /Diablo2/Drlg)

/// Outdoor A* open/closed set node; populated during generation (FindPathBetweenExits). (A* path node)
pub const D2DrlgRoomAStarNodeStrc = extern struct {
    nFCost: i16,
    nHCost: i16,
    nGCost: i16,
    nFlags: i16,
    nX: i16,
    nY: i16,
    pSeedPtr: ?*anyopaque,
    nDirection: i32,
    pParent: ?*anyopaque,
    pNext: ?*anyopaque,
};

// Drlg/D2DrlgPathNodeStrc.h (Ghidra v628 /Diablo2/Drlg)

/// Outdoor path-graph node for FindPathBetweenExits family; populated during generation. (path-graph node)
pub const D2DrlgPathNodeStrc = extern struct {
    nX: i16,
    nY: i16,
    nFCost: i16,
    nHCost: i16,
    nGCost: i16,
    nUnused0x0a: i16,
    pParent: ?*D2DrlgPathNodeStrc,
    pChildren: [8]?*D2DrlgPathNodeStrc,
    pHashNext: ?*D2DrlgPathNodeStrc,
    pSortedNext: ?*D2DrlgPathNodeStrc,
};

// Drlg/D2DrlgLevelDataPresetArea.h (Ghidra v628 /Diablo2/DRLG/LevelDataUnion_0x14)

/// Preset-area arm of the pDrlgLevelData union; populated during generation. (level-data union arm for preset areas)
pub const D2DrlgLevelDataPresetArea = extern struct {
    /// Pointer to the main DrlgMap for this preset level.
    pDrlgMap: ?*D2DrlgMapStrc,
    /// Index of the randomly picked map file variant (0-based); -1 if only one file.
    nPickedFile: i32,
};

// Drlg/D2DrlgFileCacheNodeStrc.h (Ghidra v628 /Diablo2/DRLG)

/// DS1 file LRU cache node; populated during generation (DS1 load path). (DS1 file cache node)
pub const D2DrlgFileCacheNodeStrc = extern struct {
    /// Cached DS1 filename (key)
    szName: [260]u8,
    nRefCount: u32,
    pDrlgFile: ?*D2DrlgFileStrc,
    pNext: ?*D2DrlgFileCacheNodeStrc,
};

// Drlg/D2DrlgActEnvironmentData.h (Ghidra v628 /Diablo2/DRLG)

/// Per-entry in the act day/night light-cycle table; runtime-only-unused by generation. (environment data table entry)
pub const D2DrlgActEnvironmentData = extern struct {
    nLenght: i32,
    nEnvData: i32,
    /// Packed RGB: byte[0]=R, byte[1]=G, byte[2]=B for global ambient light
    nLightColorRGB: i32,
};

// Fog/D2PoolManagerStrc.h + _unnamespaced.h (pool allocator)

pub const D2PoolBlockStrc = extern struct {
    pCommit: [*c]u8,
    pUsage: [*c]u32,
    nBlocks: usize,
    pPrev: ?*D2PoolBlockStrc,
    pNext: ?*D2PoolBlockStrc,
    pPool: ?*D2PoolStrc,
};

pub const D2PoolStrc = extern struct {
    pSync: CRITICAL_SECTION,
    nBlockSize: usize,
    nBlocks: usize,
    nSize: usize,
    nAllocBlock: usize,
    pBlocks: ?*D2PoolBlockStrc,
    pTail: ?*D2PoolBlockStrc,
};

pub const D2PoolBlockEntryStrc = extern struct {
    pBlock: ?*D2PoolBlockStrc,
    pCommit: ?*anyopaque,
};

pub const D2PoolManagerStrc = extern struct {
    /// related to pool count
    nPoolId: i32,
    pSync: CRITICAL_SECTION,
    nPools: usize,
    pPools: [40]D2PoolStrc,
    nBlocks: usize,
    nTotalBlocks: usize,
    pBlocks: ?*D2PoolBlockEntryStrc,
    pOverflow: [1023]?*u8,
    dwMemory: u32,
    szName: [32]u8,
};

// Compile-time reference check: every transformed struct is named here so
// `zig build`/`zig test` fails loudly if any type fails to resolve.

test "all DRLG structs resolve" {
    const std = @import("std");
    inline for (.{
        POINT,                                            RECT,
        CRITICAL_SECTION,                                 D2SeedStrc,
        D2DrlgCoordsStrc,                                 D2DrlgCoordStrc,
        D2DrlgRoomExDataPresetWorldCoordinatesBurialGrounds, D2DrlgRoomExDataPreset,
        D2PresetUnitStrc,                                 D2DrlgGridStrc,
        D2DrlgVertexStrc,                                 D2DrlgOrthStrc,
        D2DrlgReplaceRoomStrc,                            D2DrlgRoomCoordsStrc,
        D2DrlgTileDataStrc,                               D2DrlgTileLinkStrc,
        D2DrlgAnimTileGridStrc,                           D2DrlgTileGridStrc,
        D2DrlgRoomTilesStrc,                              D2TileLibraryHashStrc,
        D2DrlgLevelLinkNodeStrc,                          D2DrlgLevelPlacementStrc,
        D2DrlgLevelDataEntry,                             D2DrlgRoomExDataMazeStrc,
        D2DrlgSubstGroupStrc,                             D2DrlgFileStrc,
        D2RoomCoordListStrc,                              D2TileLibraryEntryStrc,
        D2DrlgCoordListStrc,                              D2RoomExStrc,
        D2RoomCollisionGridStrc,                          D2RoomStrc,
        D2UnkOutdoorStrc,                                 D2DrlgMapStrc,
        D2DrlgLevelWarpCoordinatesStrc,                   D2DrlgSpawnPointStrc,
        D2DrlgLevelStrc,                                  D2DrlgActStrc,
        D2DrlgEnvironmentStrc,                            D2DrlgActWarpsInfoStrc,
        D2DrlgDeleteStrc,                                 D2DrlgWallLayerGridsStrc,
        D2DrlgRoomExTileBucketStrc,                       D2DrlgRoomExRoomTileNodeStrc,
        D2DrlgRoomExNearNodeStrc,                         D2DrlgRoomAStarNodeStrc,
        D2DrlgPathNodeStrc,                               D2DrlgLevelDataPresetArea,
        D2DrlgFileCacheNodeStrc,                          D2DrlgActEnvironmentData,
        D2DrlgStrc,                                       D2PoolBlockStrc,
        D2PoolStrc,                                       D2PoolBlockEntryStrc,
        D2PoolManagerStrc,
    }) |T| {
        std.debug.assert(@sizeOf(T) > 0);
    }
}
