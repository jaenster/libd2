//! d2-render — the automap + DT1-tile-art render layer, extracted out of d2-drlg.
//!
//! This is a PURE post-generation consumer: it drives d2-drlg's byte-exact
//! generation pipeline (act build, per-level room/DS1 materialization) and turns the
//! output into two visual products:
//!   - faithful AUTOMAP sprite cells (AutoMap.txt lookups → DC6 frames), and
//!   - real DT1 PIXEL tile art (materialized floor/wall/roof bitmaps).
//! Generation stays in d2-drlg; this package never mutates the generated world.
//!
//! Drlg internals are reached through `d2-drlg`'s `gen` surface + a few `pub`
//! helpers — see d2-drlg/src/lib.zig. Types that cross the generation boundary
//! (dt1/dt1pix/ds1/materialize) MUST come from `d2drlg.gen` so identities match.

const std = @import("std");
const d2drlg = @import("d2-drlg");

// The moved sprite-lookup + blob accessor files (local to this package).
const automap_mod = @import("automap.zig");

// Public generation API consumed here.
const Ctx = d2drlg.Ctx;
const Difficulty = d2drlg.Difficulty;
const generateActObjects = d2drlg.generateActObjects;

// Generation-internal modules (identity-stable singletons inside the d2-drlg graph).
const abi = d2drlg.gen.abi;
const fog = d2drlg.gen.fog;
const dpool = d2drlg.gen.dpool;
const dtables = d2drlg.gen.dtables;
const act_mod = d2drlg.gen.act;
const drlg = d2drlg.gen.drlg;
const preset = d2drlg.gen.preset;
const presettables = d2drlg.gen.presettables;
const materialize = d2drlg.gen.materialize;
const objects_mod = d2drlg.gen.objects;
const dt1 = d2drlg.gen.dt1;
const dt1pix = d2drlg.gen.dt1pix;
const dt1blob = d2drlg.gen.dt1_blob;
const dt1pix_data = d2drlg.gen.dt1pix_data;
const ds1 = d2drlg.gen.ds1;

// Shared gen helpers kept in drlg (used by both collision generation and render).
const SUB = d2drlg.SUB;
const roomWindow = d2drlg.roomWindow;
const roomPMap = d2drlg.roomPMap;
const appendOutdoorShrines = d2drlg.appendOutdoorShrines;
const OutdoorShrine = d2drlg.OutdoorShrine;

// ── Automap (faithful sprite-based render data) ────────────────────────────────

/// One automap cell: a DC6 frame to blit at a world TILE position. `wall` tiles
/// get the engine's +extra vertical offset. The web/native renderer projects
/// (tx,ty) isometrically and blits `frame` from the act's automap DC6 layer.
pub const AutomapCell = struct { frame: i32, tx: i32, ty: i32, wall: bool };

pub const LevelAutomap = struct {
    level_id: i32,
    layer: u8, // automap DC6 layer index: 0 MaxiMap, 1 Act2Map, 2 Act4Map, 3 ExTnMap
    cells: []AutomapCell,
};

pub const ActAutomapResult = struct {
    levels: []LevelAutomap,
    pub fn deinit(self: *ActAutomapResult, alloc: std.mem.Allocator) void {
        for (self.levels) |l| alloc.free(l.cells);
        alloc.free(self.levels);
    }
};

/// Automap DC6 layer. The (expansion) MaxiMap.dc6 is the shared tile sheet for ALL
/// acts — every act's AutoMap.txt Cel numbers are global MaxiMap frame indices
/// (verified: acts I-V frames all resolve in MaxiMap, none in the Act2/Act4/ExTn
/// sheets, which are supplemental/UI). So tiles always come from layer 0.
/// AUTOMAP_RevealTownCallback (fTownAutoMap, 1.14d 0x004591a0): the three expansion-
/// era towns (Lut Gholein, Pandemonium Fortress, Harrogath) are NOT revealed via the
/// per-tile GetRandomCellNo/AutoMap.txt path like the Act-I/III towns — their AutoMap.txt
/// rows are (deliberately) sparse. Instead the engine blits a fixed rectangular montage
/// of large town-sprite frames from a dedicated per-town DC6 sheet (Act2Map / Act4Map /
/// ExTnMap), one frame per grid cell. Frame size == step size exactly (verified from the
/// DC6 headers), offsets 0, so the montage tiles seamlessly. `layer` selects the sheet
/// (1=act2map, 2=act4map, 3=extnmap in the wasm layer table).
const TownReveal = struct {
    layer: u8,
    rows: i32,
    cols: i32,
    step_x: i32,
    step_y: i32,
    /// grid frame indices to skip (drawn-empty holes in the montage); Lut Gholein only.
    skip: []const u32,
};

// gaLuthGoleinTownCells (1.14d .data 0x006d6608), 0xffffffff-terminated: montage cells
// left blank so the irregular town outline shows through the 4x5 bounding grid.
const lut_town_skip = [_]u32{ 0, 10, 15, 16, 19, 20, 25, 30, 35, 36, 39 };

fn townReveal(level_id: i32) ?TownReveal {
    return switch (level_id) {
        40 => .{ .layer = 1, .rows = 4, .cols = 5, .step_x = 160, .step_y = 100, .skip = &lut_town_skip },
        103 => .{ .layer = 2, .rows = 2, .cols = 2, .step_x = 136, .step_y = 90, .skip = &.{} },
        109 => .{ .layer = 3, .rows = 2, .cols = 3, .step_x = 180, .step_y = 170, .skip = &.{} },
        else => null,
    };
}

/// Emit the RevealTownCallback montage cells for a special town. `picked_file` is the
/// town's nPickedFile (Lut Gholein: ==1 → sprite frames 0..19, else 20..39; the other
/// two towns always start at frame 0). Cells are positioned by centering the montage on
/// the town's world-tile centre and inverse-projecting each frame's grid pixel back to
/// tile coords, so the shared iso renderer (wx=(tx-ty)*8, wy=(tx+ty)*4) reproduces the
/// rectangular montage at the town's world location. `c` is the town's world coords.
fn appendTownReveal(
    out: *std.ArrayListUnmanaged(AutomapCell),
    alloc: std.mem.Allocator,
    tr: TownReveal,
    c: act_mod.Coords,
    picked_file: i32,
) !void {
    const base: i32 = if (tr.layer == 1 and picked_file != 1) 20 else 0;
    // Town world-tile centre → world pixel (same iso basis as the renderer).
    const cx: f64 = @floatFromInt(c.x + @divTrunc(c.w, 2));
    const cy: f64 = @floatFromInt(c.y + @divTrunc(c.h, 2));
    const cpx = (cx - cy) * 8.0;
    const cpy = (cx + cy) * 4.0;
    const gw: f64 = @floatFromInt(tr.cols * tr.step_x);
    const gh: f64 = @floatFromInt(tr.rows * tr.step_y);
    var row: i32 = 0;
    while (row < tr.rows) : (row += 1) {
        var col: i32 = 0;
        while (col < tr.cols) : (col += 1) {
            const cell: u32 = @intCast(base + row * tr.cols + col);
            var skipped = false;
            for (tr.skip) |s| {
                if (s == cell) skipped = true;
            }
            if (skipped) continue;
            // Frame top-left pixel, montage centred on the town centre.
            const px = cpx - gw / 2.0 + @as(f64, @floatFromInt(col * tr.step_x));
            const py = cpy - gh / 2.0 + @as(f64, @floatFromInt(row * tr.step_y));
            // Inverse iso: tx-ty = px/8, tx+ty = py/4.
            const diff = px / 8.0;
            const sum = py / 4.0;
            const tx: i32 = @intFromFloat(@round((sum + diff) / 2.0));
            const ty: i32 = @intFromFloat(@round((sum - diff) / 2.0));
            try out.append(alloc, .{ .frame = @intCast(cell), .tx = tx, .ty = ty, .wall = false });
        }
    }
}

fn actAutomapLayer(act_no: i32) u8 {
    _ = act_no;
    return 0;
}


/// Generate an act and emit the faithful automap cells for every level: per placed
/// floor/wall tile, look up automap.txt on (LevelType, DT1 orientation, index,
/// subindex) → a DC6 frame, positioned at the tile's world coords. Mirrors the
/// engine's AUTOMAP_RevealRoom (floor tiles then wall tiles). `pick` chooses the
/// random cel variant deterministically (0 = Cel1). GATE-SAFE post-gen consumer.
pub fn generateActAutomap(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
) !ActAutomapResult {
    // Seeded object population (self-contained: own pool/act build). Its populate-fn
    // spawns (preset==false) are the real shrines/wells that the automap must show;
    // preset==true entries (DS1 presets + outdoor LvlSub shrines) are already handled
    // below, so we skip them here to avoid double-emitting.
    var objres = try generateActObjects(ctx, out_alloc, act_no, seed, diff);
    defer objres.deinit(out_alloc);

    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache();

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) drlg.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    if (act_no == 1) drlg.applyAct2PresetPicks(&pDrlg, &ctx.act, seed);
    drlg.buildInterLevelOrths(&pDrlg);

    var amt = try automap_mod.AutomapTable.load(ctx.gpa);
    defer amt.deinit();
    var objtbl = try objects_mod.load(ctx.gpa);
    defer objtbl.deinit();
    const layer = actAutomapLayer(act_no);

    var out: std.ArrayListUnmanaged(LevelAutomap) = .empty;
    errdefer {
        for (out.items) |l| out_alloc.free(l.cells);
        out.deinit(out_alloc);
    }
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);
        const tlv = ctx.act.level(lid) orelse continue;
        const level_type: i32 = @intCast(tlv.lvl_type);

        var cells: std.ArrayListUnmanaged(AutomapCell) = .empty;
        errdefer cells.deinit(out_alloc);
        // Dedup object markers by world position+cel: the shared level DS1 is windowed
        // per room and adjacent windows overlap on their boundary, so a boundary object
        // (e.g. the Barracks Malus) would otherwise be emitted once per touching room.
        var obj_seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer obj_seen.deinit(out_alloc);

        // Expansion-era towns (Lut Gholein / Pandemonium / Harrogath) are revealed by
        // AUTOMAP_RevealTownCallback (a fixed town-sprite montage), NOT the per-tile
        // GetRandomCellNo path — their AutoMap.txt rows are sparse by design. Emit the
        // montage cells from the town DC6 sheet and skip the tile/object scan entirely.
        if (townReveal(lid)) |tr| {
            const town_picked: i32 = if (act_no == 1) act_mod.act2TownPick(&ctx.act, seed) else 0;
            try appendTownReveal(&cells, out_alloc, tr, act.coords(&ctx.act, lid), town_picked);
            try out.append(out_alloc, .{ .level_id = lid, .layer = tr.layer, .cells = try cells.toOwnedSlice(out_alloc) });
            continue;
        }

        var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
        while (pr) |p| : (pr = p.pRoomExNext) {
            const pmap = roomPMap(p) orelse continue; // DS1 rooms (preset/maze/border)
            var d = preset.unpackDs1(out_alloc, preset.presetDs1Path(pmap) orelse continue) orelse continue;
            defer d.deinit();
            const win = roomWindow(p, pmap);
            const ds1w: i32 = @intCast(d.width);
            const ds1h: i32 = @intCast(d.height);
            const base_x = p.sCoords.WorldPosition.x;
            const base_y = p.sCoords.WorldPosition.y;

            var wy: i32 = 0;
            while (wy <= win.size_y) : (wy += 1) {
                const dsy = win.off_y + wy;
                if (dsy < 0 or dsy >= ds1h) continue;
                var wx: i32 = 0;
                while (wx <= win.size_x) : (wx += 1) {
                    const dsx = win.off_x + wx;
                    if (dsx < 0 or dsx >= ds1w) continue;
                    const idx: usize = @intCast(dsy * ds1w + dsx);
                    const tx = base_x + wx;
                    const ty = base_y + wy;
                    // Floor tiles: orientation 0.
                    for (d.floor_layers) |fl| {
                        if (idx >= fl.len) continue;
                        const raw = fl[idx].raw;
                        if (raw & 0x00ff_ffff == 0) continue;
                        const main: i32 = @intCast((raw >> 20) & 0x3f);
                        const sub: i32 = @intCast((raw >> 8) & 0xff);
                        const frame = amt.lookup(level_type, 0, main, sub, 0);
                        if (frame >= 0) try cells.append(out_alloc, .{ .frame = frame, .tx = tx, .ty = ty, .wall = false });
                    }
                    // Wall tiles: orientation from the paired orient cell's prop1.
                    for (d.wall_layers) |wl| {
                        if (idx >= wl.wall.len or idx >= wl.orient.len) continue;
                        const raw = wl.wall[idx].raw;
                        if (raw & 0x00ff_ffff == 0) continue;
                        const orient: i32 = wl.orient[idx].prop1;
                        const main: i32 = @intCast((raw >> 20) & 0x3f);
                        const sub: i32 = @intCast((raw >> 8) & 0xff);
                        const frame = amt.lookup(level_type, orient, main, sub, 0);
                        if (frame >= 0) try cells.append(out_alloc, .{ .frame = frame, .tx = tx, .ty = ty, .wall = orient > 0xf });
                    }
                }
            }
            // Object/shrine markers (Charon MapReveal DrawPresets): DS1 preset objects
            // (kind==2) carry an objects.txt row id -> AutoMap cel (Shrine 310, waypoint
            // stones 314, ...). The DS1 is the shared LEVEL file windowed per room, so
            // emit each object only for the room whose window contains it (same window
            // bounds as the tile loops) to avoid duplicating it across rooms.
            for (d.objects) |o| {
                if (o.kind != 2) continue;
                // The DS1 object id is NOT the objects.txt row — the engine resolves
                // it via the preset-object table (same map buildPresetUnits uses).
                // Looking up objects.txt with the raw id hits random rows -> phantom
                // shrines/wells/pillars. classId<0 = no object placed here.
                const class_id = presettables.objectClassId(d.act_id, o.id);
                if (class_id < 0) continue;
                const cel = objtbl.lookup(class_id);
                if (cel < 0) continue;
                // Skip the "décor flood" cels: 310 is shared by 93 shrine/dummy/caged
                // object classes and 309 by 14 well classes — these are decorative
                // preset objects (e.g. Baal-chamber crystals) that the VANILLA automap
                // does not persistently mark (only a maphack draws every preset). Keep
                // the meaningful low-share cels: waypoints (307), cairn stones (314),
                // inifuss (313), seals (306), chests (318), tomes (427), quest objects.
                if (cel == 310 or cel == 309) continue;
                const otx = @divFloor(o.x, 5); // subtiles -> DS1 tile
                const oty = @divFloor(o.y, 5);
                if (otx < win.off_x or otx > win.off_x + win.size_x) continue;
                if (oty < win.off_y or oty > win.off_y + win.size_y) continue;
                const mtx = base_x + (otx - win.off_x);
                const mty = base_y + (oty - win.off_y);
                if (mtx >= 0 and mty >= 0) {
                    const okey = (@as(u64, @intCast(mtx & 0xffffff)) << 40) | (@as(u64, @intCast(mty & 0xffffff)) << 16) | @as(u64, @intCast(cel & 0xffff));
                    if ((try obj_seen.getOrPut(out_alloc, okey)).found_existing) continue;
                }
                try cells.append(out_alloc, .{ .frame = cel, .tx = mtx, .ty = mty, .wall = false });
            }
        }
        // Seeded outdoor shrines/wells (SpawnAct12Shrines -> LvlSub Type-5 substitution).
        // These are REAL spawned objects, not DS1-preset décor, so emit their automap
        // cel unconditionally (the 310/309 skip above only suppresses preset-décor flood).
        var shrines: std.ArrayListUnmanaged(OutdoorShrine) = .empty;
        defer shrines.deinit(out_alloc);
        try appendOutdoorShrines(pLevel, &shrines, out_alloc);
        for (shrines.items) |sh| {
            const cel = objtbl.lookup(sh.class_id);
            if (cel < 0) continue;
            try cells.append(out_alloc, .{ .frame = cel, .tx = @divFloor(sh.x, 5), .ty = @divFloor(sh.y, 5), .wall = false });
        }
        // Seeded populate-fn spawns (OBJECT_PopulateRoomObjects → Fn3/Fn6/Fn7 chest &
        // quest scatter, …). preset==true entries (DS1 presets + outdoor LvlSub shrines)
        // are already emitted above. placeholder_pos==true spawns (Fn2 shrine, Fn8 well:
        // spawn-point placement unmodeled) are SKIPPED here — emitting them at their
        // room-center placeholder would fake positions and, because the engine's
        // per-level spawn capacity throttle (OBJECTRGN_CheckPointsCapacity) is not
        // modeled, flood the map (~1 per eligible room). We only mark spawns whose
        // position is faithfully modeled AND whose objects.txt AutoMap cel is set
        // (chest 318 / gidbinn 315 / tome 427 / …). Dedup by tile position + cel.
        for (objres.levels) |lo| {
            if (lo.level_id != lid) continue;
            for (lo.objs) |o| {
                if (o.preset or o.placeholder_pos) continue;
                const cel = objtbl.lookup(o.class_id);
                if (cel <= 0) continue;
                const mtx = @divFloor(o.x, 5);
                const mty = @divFloor(o.y, 5);
                if (mtx >= 0 and mty >= 0) {
                    const okey = (@as(u64, @intCast(mtx & 0xffffff)) << 40) | (@as(u64, @intCast(mty & 0xffffff)) << 16) | @as(u64, @intCast(cel & 0xffff));
                    if ((try obj_seen.getOrPut(out_alloc, okey)).found_existing) continue;
                }
                try cells.append(out_alloc, .{ .frame = cel, .tx = mtx, .ty = mty, .wall = false });
            }
        }
        try out.append(out_alloc, .{ .level_id = lid, .layer = layer, .cells = try cells.toOwnedSlice(out_alloc) });
    }
    return .{ .levels = try out.toOwnedSlice(out_alloc) };
}

// ---------------------------------------------------------------------------
// Real isometric tile renderer (DT1 pixel art). Materializes the actual game
// floor/wall graphics for a generated level into a de-duplicated set of RGBA
// tile bitmaps plus a back-to-front placement list, for the web TileMapCanvas.
// This is a ground-truth VISUAL of what the DRLG produced (not the automap
// sprite abstraction). Additive; shares generateActAutomap's room-window logic.
// ---------------------------------------------------------------------------

/// RE-derived per-tile screen anchor. The engine computes a tile's screen origin
/// (D2DrlgTileDataStrc.nScreenX/nScreenY) IDENTICALLY for floors and walls via
/// DRLGROOMTILE_FillTileData 0x66dde0 / DRLGROOMTILE_CreateWallTileData 0x66dc50,
/// both calling CoordsMiniMapToScreen 0x643310 with (wx, wy+1):
///   nScreenX = (wx - (wy+1))*80        = (tx-ty)*80 - 80
///   nScreenY = ((wx + wy+1)*80 >> 1)+40 = (tx+ty)*40 + 80
/// then blits each DT1 block at (nScreenX + block.x, nScreenY + block.y). Floors
/// and walls SHARE this anchor — a wall rises purely via its negative block.y, so
/// no per-type Y offset exists (verified: DrawFloorByViewAndFloor 0x4de730 vs the
/// WALL2 pass both add pTile->nScreenY). We fold the block origin (bb.x0,bb.y0)
/// into placement, so the anchor here is just the -80 / +80 constants. (The absolute
/// value is cosmetically irrelevant — the web reframes via min/max — but matching
/// the engine keeps floor/wall/roof vertically consistent.)
pub const TILE_ANCHOR_X: i32 = -80;
pub const TILE_ANCHOR_Y: i32 = 80;

/// Draw passes, in engine DRAW_WORLD order (floors -> walls -> [units] -> roofs):
/// DrawFloorByViewAndFloor 0x4de730, the WALL2 wall pass, then DRAW_WORLD_Roofs
/// 0x4dea70. Within a pass we paint back-to-front by GLOBAL world depth (tx+ty).
/// Objects (Phase 3, not drawn yet) are NOT a trailing pass: a future object at
/// world depth D must interleave with WALLS by depth (D2 keys its per-cell draw
/// grid on depth, drawing a cell's wall then the units standing in front of it),
/// so give objects pass == PASS_WALL and sort them into the wall list by depth
/// rather than appending them after all walls.
const PASS_FLOOR: u8 = 0;
const PASS_WALL: u8 = 1;
const PASS_ROOF: u8 = 2;

// Floor-only draw offsets. FLOOR_X_FIX stays 0: the engine's DrawGroundTile
// (0x5132c0) blits floors at nScreenX-0x50 INSTEAD of folding the tile's block
// bounding box, whereas here we already fold each tile's own block origin (bb.x0)
// into off[0] for every class uniformly. Re-applying -0x50 on top double-counts
// and skews floors one 80px iso tile-step west of the walls on the same cell; with
// 0, floors and walls share the identical anchor and line up by construction.
// FLOOR_Y_NUDGE stays 0: the engine draws floors at nScreenY directly (no floor-only
// Y term; walls add their block.y on top, roofs add roofY). Any nonzero nudge lifts
// floors off the wall bases + the collision grid — floors must share the anchor.
const FLOOR_X_FIX: i32 = 0;
const FLOOR_Y_NUDGE: i32 = 0;

/// Screen (sx,sy) for one placed tile — the single source of truth for tile
/// placement, shared by generateActTiles / generateActTilesAll / renderDs1Tiles
/// (was duplicated). roof-pass tiles get the roofY vertical-Z lift; floors get
/// the ground-tile X fix + the up-nudge.
fn tileScreenXY(pass: u8, roof: bool, roofy: i32, tx: i32, ty: i32, off: [2]i32) [2]i32 {
    const fx: i32 = if (pass == PASS_FLOOR) FLOOR_X_FIX else 0;
    const fy: i32 = if (pass == PASS_FLOOR) FLOOR_Y_NUDGE else 0;
    const roof_lift: i32 = if (roof) roofy else 0;
    return .{
        (tx - ty) * 80 + TILE_ANCHOR_X + fx + off[0],
        (tx + ty) * 40 + TILE_ANCHOR_Y + fy + off[1] - roof_lift,
    };
}

pub const TilePixel = struct { rgba: []u8, w: u32, h: u32 };
pub const TilePlacement = struct { tile_id: u32, sx: i32, sy: i32, wall: bool, roof: bool };
pub const LevelTiles = struct {
    level_id: i32,
    tiles: []TilePixel,
    placements: []TilePlacement,
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    pub fn deinit(self: *LevelTiles, a: std.mem.Allocator) void {
        for (self.tiles) |t| a.free(t.rgba);
        a.free(self.tiles);
        a.free(self.placements);
    }
};

// Baked DT1 PIXEL blob (raw DT1 bytes for Act1 dungeon tilesets), decompressed +
// indexed once per process (mirrors dt1Index).
var g_dt1pix_raw: ?[]u8 = null;
var g_dt1pix_index: ?dt1blob.Index = null;
fn dt1pixIndex(a: std.mem.Allocator) *const dt1blob.Index {
    if (g_dt1pix_index == null) {
        g_dt1pix_raw = dt1blob.decompress(a, dt1pix_data.bytes) catch @panic("d2-drlg: DT1 pixel blob decompress failed");
        g_dt1pix_index = dt1blob.buildIndex(a, g_dt1pix_raw.?) catch @panic("d2-drlg: DT1 pixel blob corrupt");
    }
    return &g_dt1pix_index.?;
}

// Runtime DT1 registry: raw DT1 bytes handed in from JS (URL-fetched), keyed by
// lowercased rel path (the LvlTypes File form). This lets the browser stream in
// ANY act's tilesets on demand instead of relying on the ~8 MB baked Act1 blob.
// Consulted before the baked blob by dt1Bytes(); cleared between acts.
var g_dt1_registry: std.StringHashMapUnmanaged([]u8) = .empty;

/// Register (copy) one raw DT1 file's bytes under its rel path. Replaces any
/// existing entry for that path. `a` must be the process-stable allocator.
pub fn dt1RegisterFile(a: std.mem.Allocator, rel_path: []const u8, data: []const u8) !void {
    const key = try a.alloc(u8, rel_path.len);
    errdefer a.free(key);
    for (rel_path, 0..) |ch, i| key[i] = std.ascii.toLower(ch);
    const val = try a.dupe(u8, data);
    errdefer a.free(val);
    const gop = try g_dt1_registry.getOrPut(a, key);
    if (gop.found_existing) {
        a.free(key);
        a.free(gop.value_ptr.*);
    }
    gop.value_ptr.* = val;
}

/// Drop every registered DT1 (call before loading a different act's tilesets).
pub fn dt1ClearRegistry(a: std.mem.Allocator) void {
    var it = g_dt1_registry.iterator();
    while (it.next()) |e| {
        a.free(e.key_ptr.*);
        a.free(e.value_ptr.*);
    }
    g_dt1_registry.clearAndFree(a);
}

// Raw DT1 bytes for a rel path: JS registry first (any act), then the baked blob.
fn dt1Bytes(a: std.mem.Allocator, fpath: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    if (fpath.len <= buf.len) {
        for (fpath, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        if (g_dt1_registry.get(buf[0..fpath.len])) |v| return v;
    }
    return dt1pixIndex(a).get(fpath);
}

/// The unique DT1 file rel paths every level of `act_no` references (LvlTypes File
/// columns; seed-independent). The browser fetches these, registers them via
/// dt1RegisterFile, then calls generateActTilesAll. Caller owns the outer slice
/// (the path slices are borrowed from the embedded tables — stable for the Ctx).
pub fn actDt1Files(ctx: *Ctx, out_alloc: std.mem.Allocator, act_no: i32) ![][]const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer files.deinit(out_alloc);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(out_alloc);

    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        const lv = ctx.act.levelAtRow(row) orelse continue;
        if (lv.act != act_no) continue;
        const tlv = ctx.act.level(@intCast(lv.id)) orelse continue;
        var fbuf: [32][]const u8 = undefined;
        const nf = ctx.act.typeFiles(tlv.lvl_type, &fbuf);
        for (fbuf[0..nf]) |f| {
            if (seen.contains(f)) continue;
            try seen.put(out_alloc, f, {});
            try files.append(out_alloc, f);
        }
    }
    return files.toOwnedSlice(out_alloc);
}

/// Materialize the real DT1 tile art for a single level of `act_no`. Returns null
/// if the level has no tiles whose DT1 set is present in the (Act1-only) pixel
/// blob. Caller owns the result (deinit with `out_alloc`).
pub fn generateActTiles(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
    target_level_id: i32,
    palette: []const u8,
) !?LevelTiles {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache();

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) {
        if (act_mod.act1CourtyardPick(&ctx.act, seed)) |pick| {
            const pCourt = drlg.GetLevelAndAlloc(&pDrlg, .OuterCloister);
            if (pCourt.pDrlgLevelData) |pd| {
                const pp: *drlg.D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
                pp.nPickedFile = pick;
            }
        }
    }
    drlg.buildInterLevelOrths(&pDrlg);

    const tlv = ctx.act.level(target_level_id) orelse return null;

    // Load this level's DT1 pixel libraries (LvlTypes File1..32).
    var files: [32][]const u8 = undefined;
    const nf = ctx.act.typeFiles(tlv.lvl_type, &files);
    var dts: std.ArrayListUnmanaged(dt1pix.Dt1Pix) = .empty;
    defer {
        for (dts.items) |*d| d.deinit();
        dts.deinit(out_alloc);
    }
    // Collision-variant DT1s (same files/order) drive the wilderness tile
    // materialization (tilegen picks against the collision tile library); their
    // picked identities are then resolved back into `dts` for the pixel art.
    var cdts: std.ArrayListUnmanaged(dt1.Dt1) = .empty;
    defer {
        for (cdts.items) |*d| d.deinit();
        cdts.deinit(out_alloc);
    }
    for (files[0..nf]) |f| {
        // Runtime registry first (any act's URL-fetched DT1), then the baked Act1 blob.
        const rec = dt1Bytes(ctx.gpa, f) orelse continue;
        const d = dt1pix.parse(out_alloc, rec) catch continue;
        try dts.append(out_alloc, d);
        if (dt1.parse(out_alloc, rec)) |cd| try cdts.append(out_alloc, cd) else |_| {}
    }
    if (dts.items.len == 0) return null;

    const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(target_level_id));
    drlg.InitLevel(pLevel);

    // De-dup decoded tiles by (dtIndex, orient, main, sub). `palette` (768 B,G,R)
    // is supplied by the caller (the wasm layer pulls it from the automap blob).
    var tile_map: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer tile_map.deinit(out_alloc);
    var tiles: std.ArrayListUnmanaged(TilePixel) = .empty;
    errdefer {
        for (tiles.items) |t| out_alloc.free(t.rgba);
        tiles.deinit(out_alloc);
    }
    // ox/oy per unique tile, kept parallel to `tiles` for screen placement.
    var tile_off: std.ArrayListUnmanaged([2]i32) = .empty;
    defer tile_off.deinit(out_alloc);
    // roofY (vertical-Z lift) per unique tile, parallel to `tiles`.
    var tile_roofy: std.ArrayListUnmanaged(i32) = .empty;
    defer tile_roofy.deinit(out_alloc);

    const Place = struct { tile_id: u32, tx: i32, ty: i32, pass: u8, roof: bool, depth: i32, ord: u32 };
    var places: std.ArrayListUnmanaged(Place) = .empty;
    defer places.deinit(out_alloc);

    const resolve = struct {
        fn f(
            a: std.mem.Allocator,
            dts_items: []dt1pix.Dt1Pix,
            pal_: []const u8,
            tmap: *std.AutoHashMapUnmanaged(u64, u32),
            tlist: *std.ArrayListUnmanaged(TilePixel),
            tofflist: *std.ArrayListUnmanaged([2]i32),
            troofy: *std.ArrayListUnmanaged(i32),
            orient: i32,
            main: i32,
            sub: i32,
        ) !?u32 {
            for (dts_items, 0..) |*d, di| {
                if (d.find(orient, main, sub)) |t| {
                    if (t.blocks.len == 0) return null;
                    const key = (@as(u64, @intCast(di)) << 40) |
                        (@as(u64, @bitCast(@as(i64, orient))) & 0xff) << 32 |
                        (@as(u64, @bitCast(@as(i64, main))) & 0xffff) << 16 |
                        (@as(u64, @bitCast(@as(i64, sub))) & 0xffff);
                    if (tmap.get(key)) |id| return id;
                    const r = dt1pix.renderTileAlloc(a, d, t, pal_) catch return null;
                    const id: u32 = @intCast(tlist.items.len);
                    try tlist.append(a, .{ .rgba = r.rgba, .w = r.w, .h = r.h });
                    try tofflist.append(a, .{ r.ox, r.oy });
                    try troofy.append(a, t.roof_y);
                    try tmap.put(a, key, id);
                    return id;
                }
            }
            return null;
        }
    }.f;

    const nLevelType: i32 = @intFromEnum(pLevel.nLevelType);
    var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
    while (pr) |p| : (pr = p.pRoomExNext) {
        const pmap = roomPMap(p) orelse {
            // Wilderness FLOOR room (no preset DS1): materialize its grass/cliff
            // tiles procedurally (RoomTile InitRoomTiles path) so it isn't a hole.
            if (!p.eRoomExFlags.noLos) continue;
            const placed = materialize.outdoorFloorRoomTiles(out_alloc, cdts.items, p.sCoords.WorldSize.x, p.sCoords.WorldSize.y, nLevelType, target_level_id, p.nSeed, materialize.outdoorOverlayFor(pLevel, p)) catch continue;
            defer out_alloc.free(placed);
            const base_x = p.sCoords.WorldPosition.x;
            const base_y = p.sCoords.WorldPosition.y;
            for (placed) |pt| {
                const id = (try resolve(out_alloc, dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, pt.orient, pt.main, pt.sub)) orelse continue;
                const is_roof = pt.orient == 15;
                const pass: u8 = if (pt.pass == 0) PASS_FLOOR else if (is_roof) PASS_ROOF else PASS_WALL;
                const tx = base_x + pt.pos_x;
                const ty = base_y + pt.pos_y;
                try places.append(out_alloc, .{ .tile_id = id, .tx = tx, .ty = ty, .pass = pass, .roof = is_roof, .depth = tx + ty, .ord = @intCast(places.items.len) });
            }
            continue;
        };
        var d = preset.unpackDs1(out_alloc, preset.presetDs1Path(pmap) orelse continue) orelse continue;
        defer d.deinit();
        const win = roomWindow(p, pmap);
        const ds1w: i32 = @intCast(d.width);
        const ds1h: i32 = @intCast(d.height);
        const base_x = p.sCoords.WorldPosition.x;
        const base_y = p.sCoords.WorldPosition.y;

        var wy: i32 = 0;
        while (wy <= win.size_y) : (wy += 1) {
            const dsy = win.off_y + wy;
            if (dsy < 0 or dsy >= ds1h) continue;
            var wx: i32 = 0;
            while (wx <= win.size_x) : (wx += 1) {
                const dsx = win.off_x + wx;
                if (dsx < 0 or dsx >= ds1w) continue;
                const idx: usize = @intCast(dsy * ds1w + dsx);
                const tx = base_x + wx;
                const ty = base_y + wy;
                // Floors: orientation 0.
                for (d.floor_layers) |fl| {
                    if (idx >= fl.len) continue;
                    const raw = fl[idx].raw;
                    if (raw & 0x00ff_ffff == 0) continue;
                    const main: i32 = @intCast((raw >> 20) & 0x3f);
                    const sub: i32 = @intCast((raw >> 8) & 0xff);
                    const id = (try resolve(out_alloc, dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, 0, main, sub)) orelse continue;
                    try places.append(out_alloc, .{ .tile_id = id, .tx = tx, .ty = ty, .pass = PASS_FLOOR, .roof = false, .depth = tx + ty, .ord = @intCast(places.items.len) });
                }
                // Walls + roofs: orientation from the paired orient cell's prop1.
                // orient 0=floor, 1-14/16+=walls, 15=roof/dome (elevated via roofY).
                for (d.wall_layers) |wl| {
                    if (idx >= wl.wall.len or idx >= wl.orient.len) continue;
                    const raw = wl.wall[idx].raw;
                    if (raw & 0x00ff_ffff == 0) continue;
                    const orient: i32 = wl.orient[idx].prop1;
                    const main: i32 = @intCast((raw >> 20) & 0x3f);
                    const sub: i32 = @intCast((raw >> 8) & 0xff);
                    const id = (try resolve(out_alloc, dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, orient, main, sub)) orelse continue;
                    // Roof classification = DS1 wall orientation 15 alone. DRAW_WORLD_Roofs
                    // (0x4dea70) lifts ONLY the roof-layer pass by roofY; FillTileData/
                    // CreateWallTileData (0x66dde0/0x66dc50) anchor floors AND walls identically
                    // (CoordsMiniMapToScreen(wx,wy+1)+0x28), no lift. Don't key off roof_y != 0 —
                    // that's the lift AMOUNT, not the class (in every 1.14d DT1 roof_y != 0 iff
                    // orientation == 15 anyway).
                    const is_roof = orient == 15;
                    // Faithful to DRLGROOMTILE_CreateWallTileData (0x66dc50): a type-3 lower
                    // wall auto-spawns a paired type-4 shadow/base at the SAME cell, looked up
                    // with the SAME main/sub (GetTileLibraryEntry(pRoomEx,4,nGridFlags) decodes
                    // main = bits20-25, sub = bits8-15 of the wall cell). Emit the shadow first
                    // so it draws behind its lower wall.
                    if (orient == 3) {
                        if (try resolve(out_alloc, dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, 4, main, sub)) |sid| {
                            try places.append(out_alloc, .{ .tile_id = sid, .tx = tx, .ty = ty, .pass = PASS_WALL, .roof = false, .depth = tx + ty, .ord = @intCast(places.items.len) });
                        }
                    }
                    try places.append(out_alloc, .{
                        .tile_id = id,
                        .tx = tx,
                        .ty = ty,
                        .pass = if (is_roof) PASS_ROOF else PASS_WALL,
                        .roof = is_roof,
                        .depth = tx + ty,
                        .ord = @intCast(places.items.len),
                    });
                }
            }
        }
    }

    // Draw order (engine DRAW_WORLD): floors -> walls -> roofs, each back-to-front
    // by global world depth (tx+ty).
    const lessThan = struct {
        fn f(_: void, a: Place, b: Place) bool {
            if (a.pass != b.pass) return a.pass < b.pass;
            if (a.depth != b.depth) return a.depth < b.depth;
            return a.ord < b.ord;
        }
    }.f;
    std.mem.sort(Place, places.items, {}, lessThan);

    var placements = try out_alloc.alloc(TilePlacement, places.items.len);
    errdefer out_alloc.free(placements);
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (places.items, 0..) |pl, i| {
        const off = tile_off.items[pl.tile_id];
        const t = tiles.items[pl.tile_id];
        const xy = tileScreenXY(pl.pass, pl.roof, tile_roofy.items[pl.tile_id], pl.tx, pl.ty, off);
        const sx = xy[0];
        const sy = xy[1];
        placements[i] = .{ .tile_id = pl.tile_id, .sx = sx, .sy = sy, .wall = pl.pass == PASS_WALL, .roof = pl.roof };
        min_x = @min(min_x, sx);
        min_y = @min(min_y, sy);
        max_x = @max(max_x, sx + @as(i32, @intCast(t.w)));
        max_y = @max(max_y, sy + @as(i32, @intCast(t.h)));
    }
    if (places.items.len == 0) {
        min_x = 0;
        min_y = 0;
        max_x = 1;
        max_y = 1;
    }

    return LevelTiles{
        .level_id = target_level_id,
        .tiles = try tiles.toOwnedSlice(out_alloc),
        .placements = placements,
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
    };
}

/// Render a RAW standalone DS1 (not from the DRLG generation pipeline) into the
/// same TilePixel/TilePlacement form as generateActTiles. Tiles resolve against
/// EVERY currently-registered DT1 (dt1RegisterFile). The DS1 is treated as one
/// room at world origin (0,0); the floor/wall/roof projection + back-to-front
/// sort mirror generateActTiles exactly. `palette` is the 768-byte B,G,R act
/// palette. Returns null if the DS1 is unparseable or no DT1s are registered.
pub fn renderDs1Tiles(out_alloc: std.mem.Allocator, ds1_bytes: []const u8, palette: []const u8) !?LevelTiles {
    var parsed = ds1.parse(out_alloc, ds1_bytes) catch return null;
    defer parsed.deinit();

    // Pixel DT1 libraries: every registered raw DT1 (the caller streams the
    // level's tileset in via dt1RegisterFile before calling this).
    var dts: std.ArrayListUnmanaged(dt1pix.Dt1Pix) = .empty;
    defer {
        for (dts.items) |*d| d.deinit();
        dts.deinit(out_alloc);
    }
    var reg_it = g_dt1_registry.valueIterator();
    while (reg_it.next()) |v| {
        const d = dt1pix.parse(out_alloc, v.*) catch continue;
        try dts.append(out_alloc, d);
    }
    if (dts.items.len == 0) return null;

    var tile_map: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer tile_map.deinit(out_alloc);
    var tiles: std.ArrayListUnmanaged(TilePixel) = .empty;
    errdefer {
        for (tiles.items) |t| out_alloc.free(t.rgba);
        tiles.deinit(out_alloc);
    }
    var tile_off: std.ArrayListUnmanaged([2]i32) = .empty;
    defer tile_off.deinit(out_alloc);
    var tile_roofy: std.ArrayListUnmanaged(i32) = .empty;
    defer tile_roofy.deinit(out_alloc);

    const Place = struct { tile_id: u32, tx: i32, ty: i32, pass: u8, roof: bool, depth: i32, ord: u32 };
    var places: std.ArrayListUnmanaged(Place) = .empty;
    defer places.deinit(out_alloc);

    const resolve = struct {
        fn f(
            a: std.mem.Allocator,
            dts_items: []dt1pix.Dt1Pix,
            pal_: []const u8,
            tmap: *std.AutoHashMapUnmanaged(u64, u32),
            tlist: *std.ArrayListUnmanaged(TilePixel),
            tofflist: *std.ArrayListUnmanaged([2]i32),
            troofy: *std.ArrayListUnmanaged(i32),
            orient: i32,
            main: i32,
            sub: i32,
        ) !?u32 {
            for (dts_items, 0..) |*d, di| {
                if (d.find(orient, main, sub)) |t| {
                    if (t.blocks.len == 0) return null;
                    const key = (@as(u64, @intCast(di)) << 40) |
                        (@as(u64, @bitCast(@as(i64, orient))) & 0xff) << 32 |
                        (@as(u64, @bitCast(@as(i64, main))) & 0xffff) << 16 |
                        (@as(u64, @bitCast(@as(i64, sub))) & 0xffff);
                    if (tmap.get(key)) |id| return id;
                    const r = dt1pix.renderTileAlloc(a, d, t, pal_) catch return null;
                    const id: u32 = @intCast(tlist.items.len);
                    try tlist.append(a, .{ .rgba = r.rgba, .w = r.w, .h = r.h });
                    try tofflist.append(a, .{ r.ox, r.oy });
                    try troofy.append(a, t.roof_y);
                    try tmap.put(a, key, id);
                    return id;
                }
            }
            return null;
        }
    }.f;

    const ds1w: i32 = @intCast(parsed.width);
    const ds1h: i32 = @intCast(parsed.height);
    var wy: i32 = 0;
    while (wy < ds1h) : (wy += 1) {
        var wx: i32 = 0;
        while (wx < ds1w) : (wx += 1) {
            const idx: usize = @intCast(wy * ds1w + wx);
            const tx = wx;
            const ty = wy;
            for (parsed.floor_layers) |fl| {
                if (idx >= fl.len) continue;
                const raw = fl[idx].raw;
                if (raw & 0x00ff_ffff == 0) continue;
                const main: i32 = @intCast((raw >> 20) & 0x3f);
                const sub: i32 = @intCast((raw >> 8) & 0xff);
                const id = (try resolve(out_alloc, dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, 0, main, sub)) orelse continue;
                try places.append(out_alloc, .{ .tile_id = id, .tx = tx, .ty = ty, .pass = PASS_FLOOR, .roof = false, .depth = tx + ty, .ord = @intCast(places.items.len) });
            }
            for (parsed.wall_layers) |wl| {
                if (idx >= wl.wall.len or idx >= wl.orient.len) continue;
                const raw = wl.wall[idx].raw;
                if (raw & 0x00ff_ffff == 0) continue;
                const orient: i32 = wl.orient[idx].prop1;
                const main: i32 = @intCast((raw >> 20) & 0x3f);
                const sub: i32 = @intCast((raw >> 8) & 0xff);
                const id = (try resolve(out_alloc, dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, orient, main, sub)) orelse continue;
                const is_roof = orient == 15;
                if (orient == 3) {
                    if (try resolve(out_alloc, dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, 4, main, sub)) |sid| {
                        try places.append(out_alloc, .{ .tile_id = sid, .tx = tx, .ty = ty, .pass = PASS_WALL, .roof = false, .depth = tx + ty, .ord = @intCast(places.items.len) });
                    }
                }
                try places.append(out_alloc, .{ .tile_id = id, .tx = tx, .ty = ty, .pass = if (is_roof) PASS_ROOF else PASS_WALL, .roof = is_roof, .depth = tx + ty, .ord = @intCast(places.items.len) });
            }
        }
    }

    const lessThan = struct {
        fn f(_: void, a: Place, b: Place) bool {
            if (a.pass != b.pass) return a.pass < b.pass;
            if (a.depth != b.depth) return a.depth < b.depth;
            return a.ord < b.ord;
        }
    }.f;
    std.mem.sort(Place, places.items, {}, lessThan);

    var placements = try out_alloc.alloc(TilePlacement, places.items.len);
    errdefer out_alloc.free(placements);
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (places.items, 0..) |pl, i| {
        const off = tile_off.items[pl.tile_id];
        const t = tiles.items[pl.tile_id];
        const xy = tileScreenXY(pl.pass, pl.roof, tile_roofy.items[pl.tile_id], pl.tx, pl.ty, off);
        const sx = xy[0];
        const sy = xy[1];
        placements[i] = .{ .tile_id = pl.tile_id, .sx = sx, .sy = sy, .wall = pl.pass == PASS_WALL, .roof = pl.roof };
        min_x = @min(min_x, sx);
        min_y = @min(min_y, sy);
        max_x = @max(max_x, sx + @as(i32, @intCast(t.w)));
        max_y = @max(max_y, sy + @as(i32, @intCast(t.h)));
    }
    if (places.items.len == 0) {
        min_x = 0;
        min_y = 0;
        max_x = 1;
        max_y = 1;
    }

    return LevelTiles{
        .level_id = 0,
        .tiles = try tiles.toOwnedSlice(out_alloc),
        .placements = placements,
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
    };
}

// One placement in the combined act-tiles view: like TilePlacement but tagged
// with its owning level (so the web can dim non-selected levels).
pub const ActTilePlacement = struct { tile_id: u32, sx: i32, sy: i32, level_id: i32, wall: bool, roof: bool, depth: i32, sub_x: i32, sub_y: i32 };

/// Every level of an act rendered with real DT1 art into ONE shared world-pixel
/// space (same iso projection as the single-level path), so adjacent levels sit
/// where they connect in-game. Tiles are de-duplicated across the WHOLE act.
pub const ActTiles = struct {
    tiles: []TilePixel,
    placements: []ActTilePlacement,
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    pub fn deinit(self: *ActTiles, a: std.mem.Allocator) void {
        for (self.tiles) |t| a.free(t.rgba);
        a.free(self.tiles);
        a.free(self.placements);
    }
};

/// Materialize the real DT1 tile art for EVERY level of `act_no` in one shared
/// world-coordinate space. Only levels whose DT1 set is present in the baked pixel
/// blob (Act1 dungeons) contribute tiles; the rest are silently skipped. Caller
/// owns the result (deinit with `out_alloc`).
pub fn generateActTilesAll(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
    palette: []const u8,
) !ActTiles {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache();

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) {
        if (act_mod.act1CourtyardPick(&ctx.act, seed)) |pick| {
            const pCourt = drlg.GetLevelAndAlloc(&pDrlg, .OuterCloister);
            if (pCourt.pDrlgLevelData) |pd| {
                const pp: *drlg.D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
                pp.nPickedFile = pick;
            }
        }
    }
    drlg.buildInterLevelOrths(&pDrlg);

    // Global DT1 set (loaded once per file path, shared by every level).
    var dts: std.ArrayListUnmanaged(dt1pix.Dt1Pix) = .empty;
    defer {
        for (dts.items) |*d| d.deinit();
        dts.deinit(out_alloc);
    }
    var dt_by_path: std.StringHashMapUnmanaged(u32) = .empty;
    defer dt_by_path.deinit(out_alloc);

    // Global de-duplicated tile atlas + parallel per-tile screen offset.
    var tile_map: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer tile_map.deinit(out_alloc);
    var tiles: std.ArrayListUnmanaged(TilePixel) = .empty;
    errdefer {
        for (tiles.items) |t| out_alloc.free(t.rgba);
        tiles.deinit(out_alloc);
    }
    var tile_off: std.ArrayListUnmanaged([2]i32) = .empty;
    defer tile_off.deinit(out_alloc);
    var tile_roofy: std.ArrayListUnmanaged(i32) = .empty;
    defer tile_roofy.deinit(out_alloc);

    const Place = struct { tile_id: u32, tx: i32, ty: i32, pass: u8, roof: bool, depth: i32, level_id: i32, ord: u32 };
    var places: std.ArrayListUnmanaged(Place) = .empty;
    defer places.deinit(out_alloc);

    // Resolve a tile identity within a specific level's ordered DT1 index list.
    // The dedup key mixes the GLOBAL dt index so identical identities in different
    // tilesets keep their distinct art.
    const resolve = struct {
        fn f(
            a: std.mem.Allocator,
            all: []dt1pix.Dt1Pix,
            lvl_dts: []const u32,
            pal_: []const u8,
            tmap: *std.AutoHashMapUnmanaged(u64, u32),
            tlist: *std.ArrayListUnmanaged(TilePixel),
            tofflist: *std.ArrayListUnmanaged([2]i32),
            troofy: *std.ArrayListUnmanaged(i32),
            orient: i32,
            main: i32,
            sub: i32,
        ) !?u32 {
            for (lvl_dts) |gi| {
                const d = &all[gi];
                if (d.find(orient, main, sub)) |t| {
                    if (t.blocks.len == 0) return null;
                    const key = (@as(u64, gi) << 40) |
                        (@as(u64, @bitCast(@as(i64, orient))) & 0xff) << 32 |
                        (@as(u64, @bitCast(@as(i64, main))) & 0xffff) << 16 |
                        (@as(u64, @bitCast(@as(i64, sub))) & 0xffff);
                    if (tmap.get(key)) |id| return id;
                    const r = dt1pix.renderTileAlloc(a, d, t, pal_) catch return null;
                    const id: u32 = @intCast(tlist.items.len);
                    try tlist.append(a, .{ .rgba = r.rgba, .w = r.w, .h = r.h });
                    try tofflist.append(a, .{ r.ox, r.oy });
                    try troofy.append(a, t.roof_y);
                    try tmap.put(a, key, id);
                    return id;
                }
            }
            return null;
        }
    }.f;

    for (ids.items) |lid| {
        const tlv = ctx.act.level(lid) orelse continue;
        var files: [32][]const u8 = undefined;
        const nf = ctx.act.typeFiles(tlv.lvl_type, &files);

        // Map this level's File columns to global dt indices (load-once).
        var lvl_dts: std.ArrayListUnmanaged(u32) = .empty;
        defer lvl_dts.deinit(out_alloc);
        for (files[0..nf]) |fpath| {
            if (dt_by_path.get(fpath)) |gi| {
                try lvl_dts.append(out_alloc, gi);
                continue;
            }
            const rec = dt1Bytes(ctx.gpa, fpath) orelse continue;
            const d = dt1pix.parse(out_alloc, rec) catch continue;
            const gi: u32 = @intCast(dts.items.len);
            try dts.append(out_alloc, d);
            try dt_by_path.put(out_alloc, fpath, gi);
            try lvl_dts.append(out_alloc, gi);
        }
        if (lvl_dts.items.len == 0) continue;

        // Collision-variant DT1s for this level (drives wilderness materialization).
        var cdts: std.ArrayListUnmanaged(dt1.Dt1) = .empty;
        defer {
            for (cdts.items) |*d| d.deinit();
            cdts.deinit(out_alloc);
        }
        for (files[0..nf]) |fpath| {
            const rec = dt1Bytes(ctx.gpa, fpath) orelse continue;
            if (dt1.parse(out_alloc, rec)) |cd| try cdts.append(out_alloc, cd) else |_| {}
        }

        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);
        const nLevelType: i32 = @intFromEnum(pLevel.nLevelType);

        var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
        while (pr) |p| : (pr = p.pRoomExNext) {
            const pmap = roomPMap(p) orelse {
                // Wilderness FLOOR room: materialize procedural tiles (see single-level path).
                if (!p.eRoomExFlags.noLos) continue;
                const placed = materialize.outdoorFloorRoomTiles(out_alloc, cdts.items, p.sCoords.WorldSize.x, p.sCoords.WorldSize.y, nLevelType, lid, p.nSeed, materialize.outdoorOverlayFor(pLevel, p)) catch continue;
                defer out_alloc.free(placed);
                const bx = p.sCoords.WorldPosition.x;
                const by = p.sCoords.WorldPosition.y;
                for (placed) |pt| {
                    const id = (try resolve(out_alloc, dts.items, lvl_dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, pt.orient, pt.main, pt.sub)) orelse continue;
                    const is_roof = pt.orient == 15;
                    const pass: u8 = if (pt.pass == 0) PASS_FLOOR else if (is_roof) PASS_ROOF else PASS_WALL;
                    const tx = bx + pt.pos_x;
                    const ty = by + pt.pos_y;
                    try places.append(out_alloc, .{ .tile_id = id, .tx = tx, .ty = ty, .pass = pass, .roof = is_roof, .depth = tx + ty, .level_id = lid, .ord = @intCast(places.items.len) });
                }
                continue;
            };
            var dd = preset.unpackDs1(out_alloc, preset.presetDs1Path(pmap) orelse continue) orelse continue;
            defer dd.deinit();
            const win = roomWindow(p, pmap);
            const ds1w: i32 = @intCast(dd.width);
            const ds1h: i32 = @intCast(dd.height);
            const base_x = p.sCoords.WorldPosition.x;
            const base_y = p.sCoords.WorldPosition.y;

            var wy: i32 = 0;
            while (wy <= win.size_y) : (wy += 1) {
                const dsy = win.off_y + wy;
                if (dsy < 0 or dsy >= ds1h) continue;
                var wx: i32 = 0;
                while (wx <= win.size_x) : (wx += 1) {
                    const dsx = win.off_x + wx;
                    if (dsx < 0 or dsx >= ds1w) continue;
                    const idx: usize = @intCast(dsy * ds1w + dsx);
                    const tx = base_x + wx;
                    const ty = base_y + wy;
                    for (dd.floor_layers) |fl| {
                        if (idx >= fl.len) continue;
                        const raw = fl[idx].raw;
                        if (raw & 0x00ff_ffff == 0) continue;
                        const main: i32 = @intCast((raw >> 20) & 0x3f);
                        const sub: i32 = @intCast((raw >> 8) & 0xff);
                        const id = (try resolve(out_alloc, dts.items, lvl_dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, 0, main, sub)) orelse continue;
                        try places.append(out_alloc, .{ .tile_id = id, .tx = tx, .ty = ty, .pass = PASS_FLOOR, .roof = false, .depth = tx + ty, .level_id = lid, .ord = @intCast(places.items.len) });
                    }
                    for (dd.wall_layers) |wl| {
                        if (idx >= wl.wall.len or idx >= wl.orient.len) continue;
                        const raw = wl.wall[idx].raw;
                        if (raw & 0x00ff_ffff == 0) continue;
                        const orient: i32 = wl.orient[idx].prop1;
                        const main: i32 = @intCast((raw >> 20) & 0x3f);
                        const sub: i32 = @intCast((raw >> 8) & 0xff);
                        const id = (try resolve(out_alloc, dts.items, lvl_dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, orient, main, sub)) orelse continue;
                        // Roof classification = DS1 wall orientation 15 alone (see the single-level
                        // path). roof_y != 0 iff orientation == 15 in every 1.14d DT1, so the roofY
                        // lift below is confined to the roof pass exactly as DRAW_WORLD_Roofs does.
                        const is_roof = orient == 15;
                        // Faithful to DRLGROOMTILE_CreateWallTileData (0x66dc50): a type-3 lower
                        // wall auto-spawns a paired type-4 shadow/base at the SAME cell, looked up
                        // with the SAME main/sub. Emit the shadow first so it draws behind the wall.
                        if (orient == 3) {
                            if (try resolve(out_alloc, dts.items, lvl_dts.items, palette, &tile_map, &tiles, &tile_off, &tile_roofy, 4, main, sub)) |sid| {
                                try places.append(out_alloc, .{ .tile_id = sid, .tx = tx, .ty = ty, .pass = PASS_WALL, .roof = false, .depth = tx + ty, .level_id = lid, .ord = @intCast(places.items.len) });
                            }
                        }
                        try places.append(out_alloc, .{
                            .tile_id = id,
                            .tx = tx,
                            .ty = ty,
                            .pass = if (is_roof) PASS_ROOF else PASS_WALL,
                            .roof = is_roof,
                            .depth = tx + ty,
                            .level_id = lid,
                            .ord = @intCast(places.items.len),
                        });
                    }
                }
            }
        }
    }

    // Global painter order across the WHOLE act (engine DRAW_WORLD): floors ->
    // walls -> roofs, each back-to-front by (tx+ty) so neighbouring levels overlap
    // correctly.
    const lessThan = struct {
        fn f(_: void, a: Place, b: Place) bool {
            if (a.pass != b.pass) return a.pass < b.pass;
            if (a.depth != b.depth) return a.depth < b.depth;
            return a.ord < b.ord;
        }
    }.f;
    std.mem.sort(Place, places.items, {}, lessThan);

    var placements = try out_alloc.alloc(ActTilePlacement, places.items.len);
    errdefer out_alloc.free(placements);
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (places.items, 0..) |pl, i| {
        const off = tile_off.items[pl.tile_id];
        const t = tiles.items[pl.tile_id];
        const sx = (pl.tx - pl.ty) * 80 + TILE_ANCHOR_X + off[0];
        // Only roof-pass tiles (orient 15) get the roofY vertical lift; walls/floors never do.
        const roof_lift: i32 = if (pl.roof) tile_roofy.items[pl.tile_id] else 0;
        const sy = (pl.tx + pl.ty) * 40 + TILE_ANCHOR_Y + off[1] - roof_lift;
        // World SUBTILE center of the tile cell (tile*5 + half), for light sampling.
        placements[i] = .{ .tile_id = pl.tile_id, .sx = sx, .sy = sy, .level_id = pl.level_id, .wall = pl.pass == PASS_WALL, .roof = pl.roof, .depth = pl.depth, .sub_x = pl.tx * SUB + 2, .sub_y = pl.ty * SUB + 2 };
        min_x = @min(min_x, sx);
        min_y = @min(min_y, sy);
        max_x = @max(max_x, sx + @as(i32, @intCast(t.w)));
        max_y = @max(max_y, sy + @as(i32, @intCast(t.h)));
    }
    if (places.items.len == 0) {
        min_x = 0;
        min_y = 0;
        max_x = 1;
        max_y = 1;
    }

    return ActTiles{
        .tiles = try tiles.toOwnedSlice(out_alloc),
        .placements = placements,
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
    };
}
