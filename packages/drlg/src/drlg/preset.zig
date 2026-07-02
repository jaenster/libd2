//! Mechanical transform of recon/closure/Preset.cpp
//! (D2Common::Drlg::Preset). Faithful by construction; field access by NAME,
//! RNG -> rng.zig, allocs -> pool.zig, tables -> tables.zig, grid -> DrlgGrid,
//! warp -> DrlgWarp/DrlgRoom, room ops -> DrlgRoom.zig.
//!
//! Scope: the seed-consuming pipeline the maze's InitAllRoomsEx tail calls into
//! (DRLGPRESET_AllocDrlgMap + BuildArea + DRLGPRESET_BuildPresetArea) plus the
//! seed-dependent DRLGPRESET_AddPresetUnitToDrlgMap state machine. For the Act2
//! sewers (Scan=0/Pops=0) BuildPresetArea returns at the recon gate (line 1778)
//! before any DrlgFile load / AddPresetUnit, so the sewer path consumes seed only
//! through AllocDrlgMap's file-selector roll + BuildArea's AllocRoomEx calls.

const std = @import("std");
const s = @import("structs.zig");
const rng = @import("rng.zig");
const pool = @import("pool.zig");
const tables = @import("tables.zig");
const DrlgGrid = @import("DrlgGrid.zig");
const DrlgRoom = @import("DrlgRoom.zig");
const Transform = @import("Transform.zig");
const ds1mod = @import("../ds1.zig");
const presettables = @import("presettables.zig");
const ds1blob = @import("../ds1_blob.zig");
const build_options = @import("build_options");

const sEEDNEXT = rng.sEEDNEXT;

// eD2UnitType (structs.zig comment: UNIT_MONSTER=1, UNIT_OBJECT=2).
const UNIT_MONSTER: s.eD2UnitType = 1;
const UNIT_OBJECT: s.eD2UnitType = 2;
const UNIT_PLAYER: s.eD2UnitType = 0;

/// sgptDataTable->nTxtMonStatsSize (globals_drlg.cpp). The MonStats.txt row count;
/// the AddPresetUnit classId switch splits monster vs object-as-monster on it. Not
/// reached by the Act2 sewer path (AddPresetUnit only runs when Scan!=0||Pops!=0).
/// Set by the preset-level harness once MonStats is loaded.
pub var g_nTxtMonStatsSize: i32 = 0;

/// DataTbls::MonsterTbls::MONSTERTBLS_ReturnZero() — recon returns 0.
inline fn returnZero() i32 {
    return 0;
}

// LvlPrest row access
// D2DrlgMapStrc.pTxtLevelPrest is typed against structs.zig's opaque
// D2LvlPrestTxt; the real fielded row lives in tables.zig. Cast at the boundary.
inline fn prest(pDrlgMap: [*c]s.D2DrlgMapStrc) [*c]tables.D2LvlPrestTxt {
    return @ptrCast(@alignCast(pDrlgMap.*.pTxtLevelPrest));
}

// Preset.cpp:1216 DRLGPRESET_AllocDrlgMap
pub fn allocDrlgMap(pLevel: [*c]s.D2DrlgLevelStrc, nLvlPrestId: i32, pDrlgCoord: [*c]s.D2DrlgCoordStrc, pSeed: *s.D2SeedStrc) [*c]s.D2DrlgMapStrc {
    // 0x58 in the 32-bit engine; @sizeOf in the 64-bit transform (8-byte pointers +
    // embedded grid) so the trailing pPresetUnit/pPops*/pNext fields stay in-bounds.
    const pDrlgMap: [*c]s.D2DrlgMapStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pLevel.*.pDrlg.?.pMemoryPool, @sizeOf(s.D2DrlgMapStrc), ".\\DRLG\\Preset.cpp", 0x9ad)));
    @memset(@as([*]u8, @ptrCast(pDrlgMap))[0..@sizeOf(s.D2DrlgMapStrc)], 0);
    const pLvlPrest = tables.lvlPrestGetLine(nLvlPrestId);
    pDrlgMap.*.pTxtLevelPrest = @ptrCast(@alignCast(pLvlPrest));
    pDrlgMap.*.nNumber = nLvlPrestId;
    const nFiles: u32 = @bitCast(pLvlPrest.*.Files);
    var nFileSelector: u32 = undefined;
    if (@as(i32, @bitCast(nFiles)) < 1) {
        nFileSelector = 0;
    } else if (nFiles & (nFiles -% 1) == 0) { // power of two
        const newSeed = sEEDNEXT(pSeed.*);
        pSeed.* = newSeed;
        nFileSelector = (nFiles -% 1) & @as(u32, @bitCast(newSeed.nSeedLow));
    } else {
        const newSeed = sEEDNEXT(pSeed.*);
        pSeed.* = newSeed;
        nFileSelector = @as(u32, @bitCast(newSeed.nSeedLow)) % nFiles;
    }

    pDrlgMap.*.nRandomMapFileSelector = @bitCast(nFileSelector);
    pDrlgMap.*.nRealOffsetX = pDrlgCoord.*.nPosX;
    pDrlgMap.*.nRealOffsetY = pDrlgCoord.*.nPosY;
    const pLvlPrestTxt = prest(pDrlgMap);
    if (pLvlPrestTxt.*.SizeX == 0 or pLvlPrestTxt.*.SizeY == 0) {
        pDrlgMap.*.nSizeX = pDrlgCoord.*.nWidth;
        pDrlgMap.*.nSizeY = pDrlgCoord.*.nHeight;
    } else {
        pDrlgMap.*.nSizeX = pLvlPrestTxt.*.SizeX;
        pDrlgMap.*.nSizeY = pLvlPrestTxt.*.SizeY;
    }

    pDrlgMap.*.bInited = 1;
    pDrlgMap.*.pNext = pLevel.*.pDrlgMapFirst;
    pLevel.*.pDrlgMapFirst = pDrlgMap;
    return pDrlgMap;
}

// Preset.cpp:791 DRLGROOMEX_AllocRoomExTypePreset
inline fn presetRoom(pRoomEx: [*c]s.D2RoomExStrc) [*c]s.D2DrlgPresetRoomStrc {
    return @ptrCast(@alignCast(pRoomEx.*.pRoomExData));
}

pub fn allocRoomExTypePreset(pLevel: [*c]s.D2DrlgLevelStrc, pDrlgMap: [*c]s.D2DrlgMapStrc, pCoord: [*c]s.D2DrlgCoordStrc, nDT1Mask: i32, dwRoomExFlags: i32, nPickedFile: i32, pParentDrlgMap: [*c]s.D2DrlgMapStrc) [*c]s.D2RoomExStrc {
    const pRoomEx = DrlgRoom.allocRoomEx(pLevel, 2);
    pRoomEx.*.eRoomExFlags.orRaw(dwRoomExFlags);
    pRoomEx.*.nDT1Mask = nDT1Mask;
    pRoomEx.*.sCoords.WorldPosition.x = pCoord.*.nPosX;
    pRoomEx.*.sCoords.WorldPosition.y = pCoord.*.nPosY;
    pRoomEx.*.sCoords.WorldSize.x = pCoord.*.nWidth;
    pRoomEx.*.sCoords.WorldSize.y = pCoord.*.nHeight;
    const pPresetData = presetRoom(pRoomEx);
    pPresetData.*.pMap = pDrlgMap; // [2]
    pPresetData.*.nPickedFile = nPickedFile; // [3]
    pPresetData.*.nLevelPrest = @enumFromInt(prest(pDrlgMap).*.Def); // [0]
    pPresetData.*.pMazeGrid = @ptrCast(pParentDrlgMap); // [0x3b] = pParentDrlgMap
    if (pParentDrlgMap != null) {
        pParentDrlgMap.*.pDrlgFile = @ptrFromInt(@intFromPtr(pParentDrlgMap.*.pDrlgFile) | 1);
    }
    if (prest(pDrlgMap).*.Populate == 0) {
        pRoomEx.*.eRoomExFlags.noSpawn = true;
    }
    _ = DrlgRoom.AddRoomExToLevel(pLevel, pRoomEx);
    return pRoomEx;
}

// Preset.cpp:529 DRLGPRESET_CopyPresetObjects
fn copyPresetObjects(pMemory: ?*s.D2PoolManagerStrc, pSrcPresetUnits: [*c]s.D2PresetUnitStrc) [*c]s.D2PresetUnitStrc {
    // Path object: { int nCount; D2PresetPathEntry* pEntries } — copied as a raw
    // 8-byte head + the entry array. The maze/sewer path never reaches this; the
    // copy is faithful but the path entries (variable-size) are left to the DS1
    // wiring step. For now copy the 8-byte head (nCount + pointer).
    const pNew: [*c]s.D2PresetUnitStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, 8, ".\\DRLG\\Preset.cpp", 0x574)));
    const src: [*]const u8 = @ptrCast(pSrcPresetUnits);
    const dst: [*]u8 = @ptrCast(pNew);
    @memcpy(dst[0..8], src[0..8]);
    return pNew;
}

// Preset.cpp:1529 CopyPresetUnit
fn CopyPresetUnit(pMemory: ?*s.D2PoolManagerStrc, pPresetUnit: [*c]s.D2PresetUnitStrc, nX: i32, nY: i32) [*c]s.D2PresetUnitStrc {
    // 0x20 in the 32-bit engine; @sizeOf in the 64-bit transform (8-byte pointers).
    const pNewPreset: [*c]s.D2PresetUnitStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(s.D2PresetUnitStrc), ".\\DRLG\\Preset.cpp", 0x54a)));
    pNewPreset.*.nMode = 0;
    pNewPreset.*.nClassId = 0;
    pNewPreset.*.nPosX = 0;
    pNewPreset.*.pPresetUnitNext = null;
    pNewPreset.*.pPath = null;
    pNewPreset.*.eType = UNIT_PLAYER;
    pNewPreset.*.nPosY = 0;
    pNewPreset.*.nFlags = 0;
    pNewPreset.*.eType = pPresetUnit.*.eType;
    pNewPreset.*.nClassId = pPresetUnit.*.nClassId;
    pNewPreset.*.nMode = pPresetUnit.*.nMode;
    pNewPreset.*.nPosX = pPresetUnit.*.nPosX + nX;
    pNewPreset.*.nPosY = pPresetUnit.*.nPosY + nY;
    pNewPreset.*.nFlags = pPresetUnit.*.nFlags;
    if (pPresetUnit.*.pPath == null) {
        return pNewPreset;
    }
    pNewPreset.*.pPath = copyPresetObjects(pMemory, @ptrCast(@alignCast(pPresetUnit.*.pPath)));
    return pNewPreset;
}

// Preset.cpp:1584 DRLGPRESET_AddPresetUnitToDrlgMap
// Seed-dependent state machine (memory: d2-drlg-maze-addpresetunit-gap). Per the
// 64-bit finding the engine tests the 32-bit LOW word, not Ghidra's
// widened (uint64_t)seed; %3/&1/&3 below all use newSeed.nSeedLow.
pub fn addPresetUnitToDrlgMap(pMemory: ?*s.D2PoolManagerStrc, pDrlgMap: [*c]s.D2DrlgMapStrc, pSeed: *s.D2SeedStrc) void {
    var pPresetUnit: [*c]s.D2PresetUnitStrc = if (pDrlgMap.*.pDrlgFile) |f| f.pPresetUnit else null;
    var nWorldX = pDrlgMap.*.nRealOffsetX;
    var nWorldY = pDrlgMap.*.nRealOffsetY;
    Transform.CoordsRoomToWorld(&nWorldX, &nWorldY);
    while (true) {
        if (pPresetUnit == null) return;

        var bCopy = true; // fall to switchD_0066771a_caseD_ce (CopyPresetUnit)
        if (pPresetUnit.*.eType == UNIT_MONSTER) {
            const nTableSize = g_nTxtMonStatsSize;
            var nMonClassId = pPresetUnit.*.nClassId;
            if (nMonClassId < nTableSize) {
                if (nMonClassId < 0) nMonClassId = -1;
                switch (nMonClassId) {
                    0xcc, 0xcd, 0x173, 0x174 => {
                        const newSeed = sEEDNEXT(pSeed.*);
                        pSeed.* = newSeed;
                        if (@as(u32, @bitCast(newSeed.nSeedLow)) % 3 != 0) bCopy = false; // -> LAB_006676c0
                    },
                    else => {},
                }
            } else {
                if (returnZero() <= pPresetUnit.*.nClassId - nTableSize) {
                    const idx = pPresetUnit.*.nClassId - g_nTxtMonStatsSize - returnZero();
                    if (idx == 0x21) {
                        // LAB_00667687 (&3 path)
                        const newSeed = sEEDNEXT(pSeed.*);
                        pSeed.* = newSeed;
                        if (@as(u32, @bitCast(newSeed.nSeedLow)) & 3 == 0) bCopy = false;
                    } else if (idx == 0x22) {
                        const newSeed = sEEDNEXT(pSeed.*);
                        pSeed.* = newSeed;
                        if (@as(u32, @bitCast(newSeed.nSeedLow)) & 1 != 0) bCopy = false; // bInclude2 even -> skip
                    } else if (idx == 0x23) {
                        const newSeed = sEEDNEXT(pSeed.*);
                        pSeed.* = newSeed;
                        if (@as(u32, @bitCast(newSeed.nSeedLow)) & 3 != 0) bCopy = false;
                    }
                }
            }
        } else if (pPresetUnit.*.eType == UNIT_OBJECT) {
            const classId = pPresetUnit.*.nClassId;
            if (classId == 0xc4 or classId == 0x105) {
                const newSeed = sEEDNEXT(pSeed.*);
                pSeed.* = newSeed;
                if (@as(u32, @bitCast(newSeed.nSeedLow)) & 1 != 0) bCopy = false; // odd -> skip copy
            } else if (classId == 0x245) {
                // LAB_00667687 (&3 path)
                const newSeed = sEEDNEXT(pSeed.*);
                pSeed.* = newSeed;
                if (@as(u32, @bitCast(newSeed.nSeedLow)) & 3 == 0) bCopy = false;
            }
        }

        if (bCopy) {
            const pCopied = CopyPresetUnit(pMemory, pPresetUnit, nWorldX, nWorldY);
            pCopied.*.pPresetUnitNext = pDrlgMap.*.pPresetUnit;
            pDrlgMap.*.pPresetUnit = pCopied;
        }

        pPresetUnit = pPresetUnit.*.pPresetUnitNext; // LAB_006676c0
    }
}

// Preset.cpp:1159 DRLGPRESET_InitDrlgMapPopLocations
fn initDrlgMapPopLocations(nPopCount: i32, pDrlgMap: [*c]s.D2DrlgMapStrc) void {
    pDrlgMap.*.nPops = nPopCount;
    if (nPopCount <= 0) return;
    const pos = pDrlgMap.*.pPosLocation; // [*c]D2DrlgCoordStrc (4 i32 per entry)
    const idxArr = pDrlgMap.*.pPopsIndex;
    var i: usize = 0;
    while (i < @as(usize, @intCast(nPopCount))) : (i += 1) {
        const p = &pos[i];
        var nX0 = p.*.nPosX;
        const nX1 = p.*.nWidth;
        var nMinX = nX0;
        if (nX1 <= nX0) nMinX = nX1;
        var nY0 = p.*.nPosY;
        const nY1 = p.*.nHeight;
        var nMinY = nY0;
        if (nY1 <= nY0) nMinY = nY1;
        if (nX0 <= nX1) nX0 = nX1;
        if (nY0 <= nY1) nY0 = nY1;
        p.*.nPosX = pDrlgMap.*.nRealOffsetX + nMinX;
        p.*.nPosY = pDrlgMap.*.nRealOffsetY + nMinY;
        p.*.nWidth = nX0 - nMinX + 1;
        p.*.nHeight = nY0 - nMinY + 1;
        const v = idxArr[i];
        idxArr[i] = @divTrunc(v + (@as(i32, @bitCast(@as(u32, @bitCast(v)) >> 0x1f)) & 3), 4) - 1;
    }
}

// Preset.cpp:457 AllocDrlgFile (1.14d 0x665f40)
// Allocs a zeroed D2DrlgFileStrc then parses the DS1 into it (recon: the file
// cache lookup that on a miss allocates + calls ParsePresetsOfDrlgFile). We drop
// the global gpDrlgFileCache (DS1 parsing consumes no seed, so the cache only
// affects pointer identity, not DRLG output; InitializeDrlgFile already guards
// re-entry per-LvlSub and BuildPresetArea allocs fresh per level). szFile is the
// asset-relative DS1 path; an empty/"0" path leaves the file zeroed.
pub fn AllocDrlgFile(ppDrlgFile: *?*s.D2DrlgFileStrc, pMemory: ?*s.D2PoolManagerStrc, szFile: []const u8) void {
    // 0x5c in the 32-bit engine; @sizeOf in the 64-bit transform (8-byte pointers) so
    // every field — including the trailing pPresetUnit — is zeroed (else it's garbage).
    const pDrlgFile: *s.D2DrlgFileStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(s.D2DrlgFileStrc), ".\\DRLG\\Preset.cpp", 0x4e1).?));
    @memset(@as([*]u8, @ptrCast(pDrlgFile))[0..@sizeOf(s.D2DrlgFileStrc)], 0);
    ppDrlgFile.* = pDrlgFile;
    ParsePresetsOfDrlgFile(pDrlgFile, pMemory, szFile);
}

// Preset.cpp:86 ParsePresetsOfDrlgFile (1.14d 0x665950)
// THE outdoor DS1-parse keystone. The recon walks a loaded D2ArchiveStrc that the
// decompiler aliases through pListNext/pListPrev/szArchivePath; we read the same
// byte stream via ds1.zig (identical version gates, recon lines 110-453) and copy
// each layer into pool memory so it outlives the temporary parse. Populates:
//   nWidth/nHeight  — DS1 header values (tiles-1; recon 113/116)
//   nAct            — version>=10 tag field gating the subst-tag layer (recon 127)
//   pWallLayer[i]/pTileTypeLayer[i]/pFloorLayer[i]/pShadowLayer/pSubstGroupTags
//                   — int32 layer arrays at (nWidth+1)*(nHeight+1) (recon 142-217)
//   pPresetUnit     — DS1 preset-unit list w/ engine-resolved classIds (recon 218-359)
//   nSubstGroups/pSubstGroups — the substitution groups (recon 362-391); this is
//                   what flips TileSub::InitializeDrlgFile + OutSub::ApplySubstitution
//                   Group from inert (nSubstGroups==0 HALT) to live.
fn ParsePresetsOfDrlgFile(pDrlgFile: *s.D2DrlgFileStrc, pMemory: ?*s.D2PoolManagerStrc, rel: []const u8) void {
    if (rel.len == 0 or std.mem.eql(u8, rel, "0")) return; // no DS1 -> leave zeroed
    _ = presettables.ensureLoaded();
    g_nTxtMonStatsSize = presettables.mon_size;

    if (build_options.ds1_disk) {
        // Regeneration/verification path: read the DS1 straight off disk.
        var pathbuf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&pathbuf, ASSET_ROOT ++ "{s}", .{rel}) catch return;
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        // A missing asset must never change the seed stream: leave the file zeroed.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, pool.allocator, .limited(MAX_DS1)) catch return;
        defer pool.allocator.free(bytes);
        var d = ds1mod.parse(pool.allocator, bytes) catch return;
        defer d.deinit();
        fillDrlgFileFromDs1(pDrlgFile, pMemory, &d);
        return;
    }

    // Baked path: look the DS1 up in the embedded blob. A missing key must leave
    // the file zeroed (return) exactly as a missing asset would, so the seed
    // stream is unchanged.
    const rec = ds1BlobIndex().get(rel) orelse return;
    var d = ds1blob.unpack(pool.allocator, rec) catch return;
    defer d.deinit();
    fillDrlgFileFromDs1(pDrlgFile, pMemory, &d);
}

// Lazily-built index over the one embedded DS1 blob. The embedded file is
// deflate-compressed; on first use it is decompressed once into a process-lifetime
// buffer (the index slices alias it) and the header is parsed. Guarded by an
// atomic once-init so the multi-threaded verifier builds it exactly once; after
// that the map is read-only and queried freely from every worker.
var g_blobIndex: ?ds1blob.Index = null;
var g_blobRaw: ?[]u8 = null;
var g_blobState = std.atomic.Value(u8).init(0); // 0 uninit, 1 building, 2 ready
/// Unpack a DS1 by asset-relative path from the baked blob (for the collision
/// rasterizer). Uses the process-lifetime blob index; caller owns the Ds1.
pub fn unpackDs1(a: std.mem.Allocator, rel: []const u8) ?ds1mod.Ds1 {
    const rec = ds1BlobIndex().get(rel) orelse return null;
    return ds1blob.unpack(a, rec) catch null;
}

fn ds1BlobIndex() *const ds1blob.Index {
    if (g_blobState.load(.acquire) != 2) {
        if (g_blobState.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            g_blobRaw = ds1blob.decompress(std.heap.c_allocator, @import("../ds1_data.zig").bytes) catch
                @panic("d2-drlg: embedded DS1 blob failed to decompress");
            g_blobIndex = ds1blob.buildIndex(std.heap.c_allocator, g_blobRaw.?) catch
                @panic("d2-drlg: embedded DS1 blob is corrupt");
            g_blobState.store(2, .release);
        } else {
            while (g_blobState.load(.acquire) != 2) std.atomic.spinLoopHint();
        }
    }
    return &g_blobIndex.?;
}

/// Populate a (zeroed) D2DrlgFileStrc from a parsed DS1 (recon Preset.cpp:111-391).
/// Split out so the keystone field-population can be unit-tested with a synthetic
/// DS1 (the LvlSub substitution DS1 assets are not present in the repo dataset).
fn fillDrlgFileFromDs1(pDrlgFile: *s.D2DrlgFileStrc, pMemory: ?*s.D2PoolManagerStrc, d: *ds1mod.Ds1) void {
    // ds1.zig stores width/height as the ACTUAL tile counts (header+1); the recon
    // struct keeps the header values (tiles-1). nWidth+1 (InitializeDrlgFile) then
    // recovers the tile count = the layer-array stride.
    pDrlgFile.nWidth = @as(i32, @intCast(d.width)) - 1;
    pDrlgFile.nHeight = @as(i32, @intCast(d.height)) - 1;
    pDrlgFile.nAct = d.act;
    const cells: usize = d.width * d.height; // (nWidth+1)*(nHeight+1) (recon 142)

    // Wall layers: recon Preset.cpp:168-177 assigns block1->pWallLayer[i],
    // block2->pTileTypeLayer[i]; ds1.zig reads {wall, orient} in that order.
    pDrlgFile.nWallLayers = @intCast(d.wall_layers.len);
    for (d.wall_layers, 0..) |wl, i| {
        if (i >= pDrlgFile.pWallLayer.len) break;
        pDrlgFile.pWallLayer[i] = copyCells(pMemory, wl.wall, cells);
        pDrlgFile.pTileTypeLayer[i] = copyCells(pMemory, wl.orient, cells);
    }
    pDrlgFile.nFloorLayers = @intCast(d.floor_layers.len);
    for (d.floor_layers, 0..) |fl, i| {
        if (i >= pDrlgFile.pFloorLayer.len) break;
        pDrlgFile.pFloorLayer[i] = copyCells(pMemory, fl, cells);
    }
    pDrlgFile.pShadowLayer = copyCells(pMemory, d.shadow, cells); // recon 212
    if (d.subst_tags) |st| pDrlgFile.pSubstGroupTags = copyCells(pMemory, st, cells); // recon 214-217

    // Preset units (recon 218-359). Same engine-resolved classId path the preset
    // levels already validate at 35/35 — see buildPresetUnits.
    buildPresetUnits(pMemory, pDrlgFile, d.act_id, d.objects);

    // Substitution groups (recon 362-391). nSubstGroups is the keystone field.
    if (d.subst_groups.len > 0) {
        pDrlgFile.nSubstGroups = @intCast(d.subst_groups.len);
        const grp: [*]s.D2DrlgSubstGroupStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, d.subst_groups.len * @sizeOf(s.D2DrlgSubstGroupStrc), ".\\DRLG\\Preset.cpp", 0x476).?));
        for (d.subst_groups, 0..) |g, i| {
            // recon reads x,y,w,h into tBox then the 5th int into nVariantCount
            // (offset 0x14); nProbability (0x10) is left unwritten and never read.
            grp[i] = .{ .tBox = .{ .nPosX = g.x, .nPosY = g.y, .nWidth = g.w, .nHeight = g.h }, .nProbability = 0, .nVariantCount = g.unknown };
        }
        pDrlgFile.pSubstGroups = &grp[0];
    }
}

/// Copy `cells` packed DS1 cell values (raw int32) into a fresh pool allocation.
/// The substitution grids (DRLGGRID_InitGridFromTileData) read these as int32.
fn copyCells(pMemory: ?*s.D2PoolManagerStrc, src: []const ds1mod.Cell, cells: usize) ?*anyopaque {
    const dst: [*]i32 = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, cells * 4, ".\\DRLG\\Preset.cpp", 0x300).?));
    const n = @min(src.len, cells);
    for (0..n) |k| dst[k] = @bitCast(src[k].raw);
    if (n < cells) @memset(@as([*]u8, @ptrCast(dst))[n * 4 .. cells * 4], 0);
    return @ptrCast(dst);
}

/// Build pDrlgFile->pPresetUnit from the DS1 object list (recon Preset.cpp:218-359
/// switch). Monsters (kind=1) / objects (kind=2) get engine-resolved classIds via
/// presettables.zig (the transform of that switch's MonPreset/gpsPresetObjectTable
/// lookups); classId<0 drops the unit (recon line 350). Items/warps never reach a
/// seed-stepping branch so are skipped. Prepended in file order (recon line 352).
fn buildPresetUnits(pMemory: ?*s.D2PoolManagerStrc, pDrlgFile: *s.D2DrlgFileStrc, act_id: i32, objects: []const ds1mod.Object) void {
    for (objects) |o| {
        var eType: s.eD2UnitType = undefined;
        var nClassId: i32 = undefined;
        var nMode: i32 = 0;
        switch (o.kind) {
            1 => {
                eType = UNIT_MONSTER;
                nClassId = presettables.monsterClassId(act_id, o.id);
                nMode = 1;
            },
            2 => {
                eType = UNIT_OBJECT;
                nClassId = presettables.objectClassId(act_id, o.id);
            },
            else => continue, // items (4) / warps never step the seed
        }
        if (nClassId < 0) continue; // recon line 350: classId < 0 -> unit dropped

        const u: [*c]s.D2PresetUnitStrc = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, @sizeOf(s.D2PresetUnitStrc), ".\\DRLG\\DrlgRoom.cpp", 0x3b6)));
        u.*.pPath = null;
        u.*.nFlags = o.flags;
        u.*.eType = eType;
        u.*.nClassId = nClassId;
        u.*.nMode = nMode;
        u.*.nPosX = o.x;
        u.*.nPosY = o.y;
        u.*.pPresetUnitNext = pDrlgFile.pPresetUnit;
        pDrlgFile.pPresetUnit = u;
    }
}

// Preset.cpp:1731 DRLGPRESET_BuildPresetArea
pub fn buildPresetArea(pDrlgMap: [*c]s.D2DrlgMapStrc, pLevel: [*c]s.D2DrlgLevelStrc, pDrlgGrid: [*c]s.D2DrlgGridStrc, nFlagsIn: i32, bSingleRoom: bool) void {
    var nFlags = nFlagsIn;
    const pDrlg = pLevel.*.pDrlg;
    const pMemory = pDrlg.?.pMemoryPool;
    const pVisCfg = DrlgRoom.getVisArrayFromLevelId(pDrlg, pLevel.*.eD2LevelId);
    var nFlagBit: u32 = 0x10;
    var nVisIndex: i32 = 0;
    while (nVisIndex < 8) : ({
        nVisIndex += 1;
        nFlagBit *%= 2;
    }) {
        if (pVisCfg[@intCast(nVisIndex)] != .None) {
            const nWarpDestLevel = @import("DrlgWarp.zig").getWarpDestinationFromArray(pLevel, @intCast(nVisIndex));
            if (nWarpDestLevel == -1) nFlags |= @bitCast(nFlagBit);
        }
    }

    DrlgGrid.AlterAllGridFlags(pDrlgGrid, nFlags, 0);
    const pLvlPrest = prest(pDrlgMap);
    const nScanMode = pLvlPrest.*.Scan;
    const nPopsCfg = pLvlPrest.*.Pops;
    if (nScanMode == 0 and nPopsCfg == 0) {
        return; // recon Preset.cpp:1778 — the Act2 sewer gate
    }

    // Heavy DS1 path (Scan/Pops presets). AllocDrlgFile -> ParsePresetsOfDrlgFile
    // loads the DS1 and builds pDrlgFile->pPresetUnit with engine-resolved classIds
    // (recon Preset.cpp:86). AddPresetUnit then consumes the level seed once per
    // qualifying preset UNIT. The DS1 wall-layer grid scan (recon 1828-1945)
    // consumes NO seed — it only places pops/spawns from real grid data we do not
    // act on here — so the seed-affecting work is just the unit list.
    AllocDrlgFile(&pDrlgMap.*.pDrlgFile, pDrlg.?.pDS1MemPool, presetDs1Path(pDrlgMap) orelse "");
    addPresetUnitToDrlgMap(pMemory, pDrlgMap, &pLevel.*.sSeed);

    const nPopCount: i32 = 0;
    if (nPopsCfg != 0) {
        const n: usize = @intCast(nPopsCfg);
        pDrlgMap.*.pPopsIndex = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, n * 4, ".\\DRLG\\Preset.cpp", 0x8bf)));
        pDrlgMap.*.pPopsSubIndex = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, n * 4, ".\\DRLG\\Preset.cpp", 0x8c0)));
        pDrlgMap.*.pPopsOrientation = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, n * 4, ".\\DRLG\\Preset.cpp", 0x8c1)));
        pDrlgMap.*.pPosLocation = @ptrCast(@alignCast(pool.AllocServerMemory(pMemory, n * 16, ".\\DRLG\\Preset.cpp", 0x8c2)));
        @memset(@as([*]u8, @ptrCast(pDrlgMap.*.pPopsIndex))[0 .. n * 4], 0);
        @memset(@as([*]u8, @ptrCast(pDrlgMap.*.pPopsSubIndex))[0 .. n * 4], 0);
        @memset(@as([*]u8, @ptrCast(pDrlgMap.*.pPopsOrientation))[0 .. n * 4], 0);
        @memset(@as([*]u8, @ptrCast(pDrlgMap.*.pPosLocation))[0 .. n * 16], 0);
    }

    // nWallLayers == 0 -> the per-cell scan loop and the object-flag loop (recon
    // 1828-1945) are dormant; they place pops/spawns (no seed) from real DS1 grid
    // data we do not load. The seed-affecting work (AddPresetUnit) is already done.
    if (nPopsCfg != 0) {
        initDrlgMapPopLocations(nPopCount, pDrlgMap);
    }
    _ = bSingleRoom;
}

const ASSET_ROOT = "assets/tiles/";
const MAX_DS1: usize = 8 * 1024 * 1024;

/// LvlPrest File[idx] as a 0-terminated slice. Computed via explicit byte offset:
/// double-subscripting File[i][0] through the [*c] row pointer mis-strides under
/// this Zig (it treats File[i] with the whole-array stride), so address the cell
/// directly off the struct base.
inline fn fileCol(row: [*c]tables.D2LvlPrestTxt, idx: usize) []const u8 {
    const base: [*]const u8 = @ptrCast(row);
    const c = (base + @offsetOf(tables.D2LvlPrestTxt, "File") + idx * 60)[0..60];
    const len = std.mem.indexOfScalar(u8, c, 0) orelse 60;
    return c[0..len];
}

/// The DS1 to load for this preset map. Faithful selection is File[selector]
/// (AllocDrlgFile, BuildPresetArea recon 1783); an empty "0" slot is skipped to the
/// first real File — the engine's File[0]="0" placeholder convention for non-random
/// (Files=0) presets like Lut Gholein (File1="0", File2="LutW.ds1").
pub fn presetDs1Path(pDrlgMap: [*c]s.D2DrlgMapStrc) ?[]const u8 {
    const p = prest(pDrlgMap);
    const sel: usize = @intCast(pDrlgMap.*.nRandomMapFileSelector);
    if (sel < 6) {
        const f = fileCol(p, sel);
        if (f.len > 0 and !std.mem.eql(u8, f, "0")) return f;
    }
    for (0..6) |i| {
        const f = fileCol(p, i);
        if (f.len > 0 and !std.mem.eql(u8, f, "0")) return f;
    }
    return null;
}

// Preset.cpp:1964 BuildArea
pub fn BuildArea(pLevel: [*c]s.D2DrlgLevelStrc, pDrlgMap: [*c]s.D2DrlgMapStrc, nFlagsIn: i32, bSingleRoom: i32) [*c]s.D2RoomExStrc {
    var nFlags = nFlagsIn;
    var gridCellBuf: [1024]i32 = undefined;
    var gridLinkBuf: [256]i32 = undefined;
    var tmpGrid: s.D2DrlgGridStrc = undefined;

    if (prest(pDrlgMap).*.Outdoors != 0) {
        nFlags |= 0x80000;
    }

    const sx = pDrlgMap.*.nSizeX;
    const sy = pDrlgMap.*.nSizeY;
    DrlgGrid.FillGrid(&tmpGrid, (@divTrunc(sx + (@as(i32, @bitCast(@as(u32, @bitCast(sx)) >> 0x1f)) & 7), 8)) + 1, (@divTrunc(sy + (@as(i32, @bitCast(@as(u32, @bitCast(sy)) >> 0x1f)) & 7), 8)) + 1, &gridCellBuf, &gridLinkBuf);
    buildPresetArea(pDrlgMap, pLevel, &tmpGrid, nFlags, bSingleRoom != 0);
    const dt1Mask = prest(pDrlgMap).*.Dt1Mask;
    var pLastRoomEx: [*c]s.D2RoomExStrc = null;

    if (bSingleRoom == 0) {
        var y = pDrlgMap.*.nRealOffsetY;
        const xEnd = pDrlgMap.*.nSizeX + pDrlgMap.*.nRealOffsetX;
        const yEnd = pDrlgMap.*.nSizeY + y;
        var nGridRow: i32 = 0;
        if (y < yEnd) {
            while (y < yEnd) : ({
                nGridRow += 1;
                y += 8;
            }) {
                var x = pDrlgMap.*.nRealOffsetX;
                var nCol: i32 = 0;
                if (x < xEnd) {
                    while (x < xEnd) : ({
                        nCol += 1;
                        x += 8;
                    }) {
                        const xRemaining = xEnd - x;
                        var nTileWidth = xRemaining;
                        if (nTileWidth > 7) nTileWidth = 8;
                        var nTileHeight = yEnd - y;
                        if (nTileHeight > 7) nTileHeight = 8;
                        var coord: s.D2DrlgCoordStrc = .{ .nPosX = x, .nPosY = y, .nWidth = nTileWidth, .nHeight = nTileHeight };
                        const nCellFlags = DrlgGrid.GetGridFlags(&tmpGrid, nCol, nGridRow);
                        var nMapGridFlags: i32 = 0;
                        if (pDrlgMap.*.pVertices != null) {
                            nMapGridFlags = DrlgGrid.GetGridFlags(&pDrlgMap.*.pMapGrid, nCol, nGridRow);
                        }
                        if (nTileWidth != 0 and nTileHeight != 0) {
                            pLastRoomEx = allocRoomExTypePreset(pLevel, pDrlgMap, &coord, dt1Mask, nCellFlags, 0, @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(nMapGridFlags))))));
                        }
                    }
                }
            }
        }
        DrlgGrid.ResetGrid(&tmpGrid);
        return pLastRoomEx;
    }

    const nGridFlags = DrlgGrid.GetGridFlags(&tmpGrid, 0, 0);
    const pRoomEx = DrlgRoom.allocRoomEx(pLevel, 2);
    pRoomEx.*.eRoomExFlags.orRaw(nGridFlags);
    pRoomEx.*.nDT1Mask = dt1Mask;
    pRoomEx.*.sCoords.WorldPosition.x = pDrlgMap.*.nRealOffsetX;
    pRoomEx.*.sCoords.WorldPosition.y = pDrlgMap.*.nRealOffsetY;
    pRoomEx.*.sCoords.WorldSize.x = pDrlgMap.*.nSizeX;
    pRoomEx.*.sCoords.WorldSize.y = pDrlgMap.*.nSizeY;
    const pRoomExData = presetRoom(pRoomEx);
    pRoomExData.*.pMap = pDrlgMap; // [2]
    pRoomExData.*.nLevelPrest = @enumFromInt(prest(pDrlgMap).*.Def); // [0]
    pRoomExData.*.nPickedFile = 1; // [3]
    pRoomExData.*.pMazeGrid = null; // [0x3b]
    if (prest(pDrlgMap).*.Populate == 0) {
        pRoomEx.*.eRoomExFlags.noSpawn = true;
    }
    _ = DrlgRoom.AddRoomExToLevel(pLevel, pRoomEx);
    pLastRoomEx = pRoomEx;
    DrlgGrid.ResetGrid(&tmpGrid);
    return pRoomEx;
}

test "preset module references" {
    _ = allocDrlgMap;
    _ = BuildArea;
    _ = addPresetUnitToDrlgMap;
}

// Keystone validation: ParsePresetsOfDrlgFile populates nSubstGroups
// The LvlSub substitution DS1 assets (BorderCliffs.ds1 etc.) are absent from the
// repo dataset, so the keystone cannot be exercised against a real border file
// here. This builds a synthetic v14 DS1 (one wall+floor+shadow+subst-tag layer,
// one substitution group) and feeds it through ds1.parse -> fillDrlgFileFromDs1
// to prove the keystone fills the D2DrlgFileStrc the substitution subsystem reads
// (nSubstGroups>=1 + layers at (nWidth+1)*(nHeight+1)).
test "fillDrlgFileFromDs1 populates nSubstGroups + layers from a real DS1 stream" {
    const t = std.testing;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    const put = struct {
        fn i(b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: i32) !void {
            var le: [4]u8 = undefined;
            std.mem.writeInt(i32, &le, v, .little);
            try b.appendSlice(a, &le);
        }
    }.i;

    try put(&buf, t.allocator, 14); // version
    try put(&buf, t.allocator, 1); // raw width  -> 2 tiles
    try put(&buf, t.allocator, 1); // raw height -> 2 tiles
    try put(&buf, t.allocator, 1); // act_id (v>7)
    try put(&buf, t.allocator, 1); // act/tag (v>9) -> enables subst-tag layer + groups
    try put(&buf, t.allocator, 0); // numFiles (v>2)
    try put(&buf, t.allocator, 1); // numWalls (v>=4); v<16 -> numFloors=1
    for (0..4) |k| try put(&buf, t.allocator, @intCast(10 + k)); // wall block
    for (0..4) |k| try put(&buf, t.allocator, @intCast(20 + k)); // orient block
    for (0..4) |k| try put(&buf, t.allocator, @intCast(30 + k)); // floor block
    for (0..4) |k| try put(&buf, t.allocator, @intCast(40 + k)); // shadow block
    for (0..4) |k| try put(&buf, t.allocator, @intCast(50 + k)); // subst-tag block (act in {1,2})
    try put(&buf, t.allocator, 0); // numObjects (v>1)
    try put(&buf, t.allocator, 1); // numGroups (v>11 && act in {1,2}; v<18 no prefix)
    try put(&buf, t.allocator, 2); // group x
    try put(&buf, t.allocator, 3); // group y
    try put(&buf, t.allocator, 4); // group w
    try put(&buf, t.allocator, 5); // group h
    try put(&buf, t.allocator, 6); // group unknown (v>12) -> unk0x14
    try put(&buf, t.allocator, 0); // numNpcs (v>13)

    var d = try ds1mod.parse(t.allocator, buf.items);
    defer d.deinit();

    _ = presettables.ensureLoaded();
    g_nTxtMonStatsSize = presettables.mon_size;
    var file: s.D2DrlgFileStrc = std.mem.zeroes(s.D2DrlgFileStrc);
    fillDrlgFileFromDs1(&file, null, &d);

    try t.expectEqual(@as(i32, 1), file.nWidth); // header value (tiles-1)
    try t.expectEqual(@as(i32, 1), file.nHeight);
    try t.expectEqual(@as(i32, 1), file.nAct);
    try t.expectEqual(@as(i32, 1), file.nWallLayers);
    try t.expectEqual(@as(i32, 1), file.nFloorLayers);
    // THE keystone: nSubstGroups now populates -> InitializeDrlgFile no longer HALTs.
    try t.expectEqual(@as(i32, 1), file.nSubstGroups);
    try t.expect(file.pSubstGroups != null);
    const g: *s.D2DrlgSubstGroupStrc = file.pSubstGroups.?;
    try t.expectEqual(@as(i32, 2), g.tBox.nPosX);
    try t.expectEqual(@as(i32, 3), g.tBox.nPosY);
    try t.expectEqual(@as(i32, 4), g.tBox.nWidth);
    try t.expectEqual(@as(i32, 5), g.tBox.nHeight);
    try t.expectEqual(@as(i32, 6), g.nVariantCount);
    // Layers allocated at (nWidth+1)*(nHeight+1) = 4 int32 cells, raw values copied.
    try t.expect(file.pWallLayer[0] != null);
    const wall: [*]i32 = @ptrCast(@alignCast(file.pWallLayer[0]));
    const orient: [*]i32 = @ptrCast(@alignCast(file.pTileTypeLayer[0].?));
    const shadow: [*]i32 = @ptrCast(@alignCast(file.pShadowLayer.?));
    for (0..4) |k| {
        try t.expectEqual(@as(i32, @intCast(10 + k)), wall[k]);
        try t.expectEqual(@as(i32, @intCast(20 + k)), orient[k]);
        try t.expectEqual(@as(i32, @intCast(40 + k)), shadow[k]);
    }
    try t.expect(file.pSubstGroupTags != null);

    // End-to-end: the populated file drives the substitution grid init w/o HALT.
    var sub: tables.D2LvlSubTxt = std.mem.zeroes(tables.D2LvlSubTxt);
    @import("TileSub.zig").initGridsFromDrlgFile(&sub, &file);
    try t.expectEqual(@as(i32, 2), sub.pWallGrid[0].nWidth); // stride = nWidth+1
}

// Live-asset keystone: a REAL LvlSub border DS1 yields nSubstGroups>=1
// AllocDrlgFile(LvlSub.File) loads the outdoor substitution DS1 from
// assets/tiles/<File> (recon closure/Preset.cpp:110 / TileSub.cpp:42 pass File
// straight to the loader; data\global\tiles\ MPQ prefix is the extract mapping).
// assets/tiles is gitignored: if the asset isn't extracted this SKIPS, so the
// committed suite stays green without Blizzard data. Run `tools/extract_tiles`
// (now also collects LvlSub.txt) to populate it and exercise this for real.
test "AllocDrlgFile on a real LvlSub border DS1 populates nSubstGroups" {
    const t = std.testing;
    // BorderCliffs.ds1 = LvlSub row "Border - Cliffs" (File Act1/Outdoors/BorderCliffs.ds1).
    const rel = "Act1/Outdoors/BorderCliffs.ds1";
    var pathbuf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&pathbuf, ASSET_ROOT ++ "{s}", .{rel});
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    std.Io.Dir.cwd().access(io, full, .{}) catch return error.SkipZigTest;

    var pFile: ?*s.D2DrlgFileStrc = null;
    AllocDrlgFile(&pFile, null, rel);
    try t.expect(pFile != null);
    // The subsystem is inert at nSubstGroups==0 (InitializeDrlgFile HALTs); the
    // real border DS1 must carry at least one substitution group.
    try t.expect(pFile.?.nSubstGroups >= 1);
    try t.expect(pFile.?.nWallLayers >= 1);
}
